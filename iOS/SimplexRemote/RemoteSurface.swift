import UIKit
import AVFoundation
import CoreMedia
import SwiftUI

/// Decodes the Mac's H.264 packets and shows them in an AVSampleBufferDisplayLayer.
final class VideoDecoder {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private let queue = DispatchQueue(label: "com.simplex.remote.decode", qos: .userInteractive)
    var onSize: ((CGSize) -> Void)?
    var needsKeyframe: (() -> Void)?
    /// Called on the main thread after a frame was handed to the display (sequence number, keyframe).
    var onFrame: ((UInt64, Bool) -> Void)?
    private var lastSize: CGSize = .zero
    private var waitingForKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func reset() {
        queue.async {
            self.format = nil
            self.waitingForKeyframe = true
            DispatchQueue.main.async { self.layer.sampleBufferRenderer.flush() }
        }
    }

    func decode(_ packet: Data) {
        queue.async { self.process(packet) }
    }

    private func process(_ packet: Data) {
        let bytes = [UInt8](packet)
        guard bytes.count > 13 else { return }
        let keyframe = bytes[0] & 1 == 1
        var seq: UInt64 = 0
        for i in 1...8 { seq = seq << 8 | UInt64(bytes[i]) }
        let width = Int(bytes[9]) << 8 | Int(bytes[10])
        let height = Int(bytes[11]) << 8 | Int(bytes[12])
        var index = 13

        if keyframe {
            func readBlock() -> [UInt8]? {
                guard index + 2 <= bytes.count else { return nil }
                let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                index += 2
                guard index + length <= bytes.count else { return nil }
                defer { index += length }
                return Array(bytes[index..<(index + length)])
            }
            guard let sps = readBlock(), let pps = readBlock() else { return }
            var newFormat: CMVideoFormatDescription?
            sps.withUnsafeBufferPointer { spsPtr in
                pps.withUnsafeBufferPointer { ppsPtr in
                    let pointers: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
                }
            }
            if let newFormat { format = newFormat }
            waitingForKeyframe = false
        }
        guard let format, !waitingForKeyframe, index < bytes.count else { return }

        let size = CGSize(width: width, height: height)
        if size != lastSize {
            lastSize = size
            DispatchQueue.main.async { self.onSize?(size) }
        }

        let length = bytes.count - index
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        bytes.withUnsafeBufferPointer { buffer in
            _ = CMBlockBufferReplaceDataBytes(with: buffer.baseAddress! + index, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async {
            let renderer = self.layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                self.queue.async { self.waitingForKeyframe = true }
                self.needsKeyframe?()
                return
            }
            renderer.enqueue(sample)
            self.onFrame?(seq, keyframe)
        }
    }
}

// MARK: - Touch surface

enum InputMode: String, CaseIterable, Identifiable {
    case touch, trackpad
    var id: String { rawValue }
    var title: String { self == .touch ? "Touch" : "Trackpad" }
    var symbol: String { self == .touch ? "hand.tap" : "rectangle.and.hand.point.up.left" }
}

/// Shows the Mac screen and turns gestures into mouse events.
final class RemoteSurfaceView: UIView, UIGestureRecognizerDelegate {
    let decoder = VideoDecoder()
    var send: (([String: Any]) -> Void)?
    var mode: InputMode = .touch
    var sensitivity: CGFloat = 1.6
    private var videoSize = CGSize(width: 16, height: 9)
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var lastMoveSent: TimeInterval = 0
    private var pendingRel: CGPoint = .zero
    let keyInput = KeyInputView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(decoder.layer)
        decoder.onSize = { [weak self] size in
            self?.videoSize = size
            self?.setNeedsLayout()
        }
        addSubview(keyInput)
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decoder.layer.frame = bounds
        applyZoom()
        CATransaction.commit()
    }

    private func applyZoom() {
        decoder.layer.setAffineTransform(CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: zoom, y: zoom))
    }

    func resetZoom() {
        zoom = 1
        offset = .zero
        UIView.animate(withDuration: 0.25) { self.applyZoom() }
    }

    /// Rect of the video inside the layer (aspect fit), in layer coordinates.
    private var contentRect: CGRect {
        AVMakeRect(aspectRatio: videoSize, insideRect: decoder.layer.bounds)
    }

    private func normalized(_ point: CGPoint) -> (Double, Double) {
        let p = decoder.layer.convert(point, from: layer)
        let rect = contentRect
        return (Double((p.x - rect.minX) / rect.width), Double((p.y - rect.minY) / rect.height))
    }

    private func mouse(_ action: String, at point: CGPoint?, extra: [String: Any] = [:]) {
        var msg: [String: Any] = ["t": "mouse", "a": action]
        if let point, mode == .touch {
            let (x, y) = normalized(point)
            msg["x"] = x
            msg["y"] = y
        }
        extra.forEach { msg[$0.key] = $0.value }
        send?(msg)
    }

    // MARK: Gestures
    //
    // Touch mode = the Mac behaves like a real touchscreen:
    //   tap → click · double tap → double click · drag → click-and-drag (move windows, select)
    //   press & hold → right click · two fingers → scroll (with momentum) · pinch → zoom
    // Trackpad mode = relative pointer like a laptop trackpad.

    private var lastPan: CGPoint = .zero
    private var scrollVelocity: CGPoint = .zero
    private var momentumLink: CADisplayLink?
    private var lastMomentumTime: CFTimeInterval = 0
    private var dragActive = false

    private func setupGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 12
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for g in [doubleTap, tap, twoFingerTap, longPress, pan, scroll, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            g.delaysTouchesBegan = false
            addGestureRecognizer(g)
        }
        pan.require(toFail: longPress)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()   // a new touch stops a flick, like on iOS
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        mouse("click", at: p)
        ripple(at: p)
        haptic(.light)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        mouse("dclick", at: p)
        ripple(at: p)
        haptic(.light)
    }

    @objc private func rightTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        mouse("rclick", at: p, extra: ["b": "right"])
        ripple(at: p, color: .systemOrange)
        haptic(.medium)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch mode {
        case .touch:
            // Press & hold = right click (like Windows touch).
            if g.state == .began {
                mouse("rclick", at: p, extra: ["b": "right"])
                ripple(at: p, color: .systemOrange)
                haptic(.heavy)
            }
        case .trackpad:
            // Hold, then move = drag.
            switch g.state {
            case .began:
                dragActive = true
                mouse("down", at: nil)
                haptic(.heavy)
                lastPan = p
            case .changed:
                relMove(CGPoint(x: p.x - lastPan.x, y: p.y - lastPan.y))
                lastPan = p
            default:
                flushRel()
                mouse("up", at: nil)
                dragActive = false
            }
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch mode {
        case .touch:
            switch g.state {
            case .began:
                // Press where the finger first touched, then drag.
                let t = g.translation(in: self)
                let origin = CGPoint(x: p.x - t.x, y: p.y - t.y)
                mouse("move", at: origin)
                mouse("down", at: origin)
                dragActive = true
                throttledMove(p, force: true)
            case .changed:
                throttledMove(p)
            default:
                mouse("move", at: p)
                mouse("up", at: p)
                dragActive = false
            }
        case .trackpad:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            relMove(t)
            if g.state == .ended || g.state == .cancelled { flushRel() }
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if zoom > 1.01 {
            // Zoomed in: two fingers move the magnified view.
            offset.x += t.x
            offset.y += t.y
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyZoom()
            CATransaction.commit()
            return
        }
        let point: CGPoint? = (g.state == .began && mode == .touch) ? g.location(in: self) : nil
        mouse("scroll", at: point, extra: ["dx": Double(t.x * 2), "dy": Double(t.y * 2)])
        if g.state == .ended {
            let v = g.velocity(in: self)
            if hypot(v.x, v.y) > 250 { startMomentum(v) }
        }
    }

    /// Keep scrolling after a flick, slowing down like iOS does.
    private func startMomentum(_ velocity: CGPoint) {
        stopMomentum()
        scrollVelocity = velocity
        lastMomentumTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumStep))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumStep() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastMomentumTime, 0.05)
        lastMomentumTime = now
        scrollVelocity.x *= pow(0.12, dt)   // ~ iOS deceleration
        scrollVelocity.y *= pow(0.12, dt)
        guard hypot(scrollVelocity.x, scrollVelocity.y) > 30 else { return stopMomentum() }
        send?(["t": "mouse", "a": "scroll", "dx": Double(scrollVelocity.x * dt * 2), "dy": Double(scrollVelocity.y * dt * 2)])
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed, g.numberOfTouches == 2 else { return }
        let center = g.location(in: self)
        let newZoom = min(max(zoom * g.scale, 1), 5)
        let factor = newZoom / zoom
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        // Keep the point under the fingers fixed while zooming (layer scales around its center).
        offset.x = (offset.x - (center.x - mid.x)) * factor + (center.x - mid.x)
        offset.y = (offset.y - (center.y - mid.y)) * factor + (center.y - mid.y)
        zoom = newZoom
        if zoom <= 1.01 { zoom = 1; offset = .zero }
        g.scale = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyZoom()
        CATransaction.commit()
    }

    private func throttledMove(_ p: CGPoint, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastMoveSent > 1.0 / 120.0 else { return }
        lastMoveSent = now
        mouse("move", at: p)
    }

    private func relMove(_ delta: CGPoint) {
        pendingRel.x += delta.x * sensitivity
        pendingRel.y += delta.y * sensitivity
        let now = CACurrentMediaTime()
        guard now - lastMoveSent > 1.0 / 120.0 else { return }
        flushRel()
    }

    private func flushRel() {
        guard pendingRel != .zero else { return }
        lastMoveSent = CACurrentMediaTime()
        send?(["t": "mouse", "a": "rel", "dx": Double(pendingRel.x), "dy": Double(pendingRel.y)])
        pendingRel = .zero
    }

    /// Instant visual feedback where the finger touched (masks network latency).
    private func ripple(at point: CGPoint, color: UIColor = .white) {
        let size: CGFloat = 44
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
        ring.position = point
        ring.fillColor = color.withAlphaComponent(0.25).cgColor
        ring.strokeColor = color.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ring.removeFromSuperlayer() }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Keyboard

/// Invisible view that receives the on-screen keyboard and hardware keyboard input.
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((String, [String]) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark

    func insertText(_ text: String) {
        if text == "\n" { onKey?("return", []) } else { onText?(text) }
    }

    func deleteBackward() { onKey?("backspace", []) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var mods: [String] = []
            if key.modifierFlags.contains(.command) { mods.append("cmd") }
            if key.modifierFlags.contains(.control) { mods.append("ctrl") }
            if key.modifierFlags.contains(.alternate) { mods.append("alt") }
            if key.modifierFlags.contains(.shift) { mods.append("shift") }
            if let name = Self.specialKeys[key.keyCode] {
                onKey?(name, mods)
                handled = true
            } else if mods.contains(where: { $0 != "shift" }) {
                let ch = key.charactersIgnoringModifiers.lowercased()
                if !ch.isEmpty {
                    onKey?(ch, mods)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private static let specialKeys: [UIKeyboardHIDUsage: String] = [
        .keyboardReturnOrEnter: "return", .keyboardTab: "tab", .keyboardEscape: "esc",
        .keyboardDeleteOrBackspace: "backspace", .keyboardDeleteForward: "delete",
        .keyboardLeftArrow: "left", .keyboardRightArrow: "right", .keyboardUpArrow: "up", .keyboardDownArrow: "down",
        .keyboardHome: "home", .keyboardEnd: "end", .keyboardPageUp: "pageup", .keyboardPageDown: "pagedown",
        .keyboardF1: "f1", .keyboardF2: "f2", .keyboardF3: "f3", .keyboardF4: "f4", .keyboardF5: "f5",
        .keyboardF6: "f6", .keyboardF7: "f7", .keyboardF8: "f8", .keyboardF9: "f9", .keyboardF10: "f10",
        .keyboardF11: "f11", .keyboardF12: "f12",
    ]
}

/// SwiftUI wrapper.
struct RemoteSurface: UIViewRepresentable {
    let session: RemoteSession

    func makeUIView(context: Context) -> RemoteSurfaceView {
        let view = session.surface
        return view
    }

    func updateUIView(_ uiView: RemoteSurfaceView, context: Context) {
        uiView.mode = session.inputMode
    }
}
