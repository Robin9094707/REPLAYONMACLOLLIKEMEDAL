import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Classic screen recording (start → stop) of a whole display or a selected region,
/// written straight to an .mp4 with system audio. Independent of the replay buffer.
@MainActor
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var isRegion = false

    private var stream: SCStream?
    private var output: RecordingOutput?
    private var fileURL: URL?

    var elapsedText: String {
        guard let startedAt else { return "0:00" }
        let s = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func toggle() {
        if isRecording { Task { await stop() } } else { startFullScreen() }
    }

    func startFullScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        Task { await start(screen: screen, region: nil) }
    }

    func startRegion() {
        RegionSelector.shared.select { [weak self] screen, rect in
            Task { await self?.start(screen: screen, region: rect) }
        }
    }

    /// `region` is in the screen's local coordinates (points, top-left origin).
    func start(screen: NSScreen, region: CGRect?) async {
        guard !isRecording else { return }
        guard Permissions.hasScreenRecording else {
            OverlayHUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Bildschirmaufnahme nicht erlaubt",
                                   subtitle: "Einstellungen → Allgemein → Berechtigungen", tint: .systemOrange)
            return
        }
        let settings = AppSettings.shared
        do {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)

            let area = region ?? CGRect(origin: .zero, size: display.frame.size)
            var width = Int(area.width * scale), height = Int(area.height * scale)
            if let maxHeight = settings.resolution.maxHeight, height > maxHeight {
                width = Int(Double(width) * Double(maxHeight) / Double(height))
                height = maxHeight
            }
            width = max(64, width & ~1)
            height = max(64, height & ~1)

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            if region != nil { config.sourceRect = area }
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 8
            config.showsCursor = true
            config.capturesAudio = settings.captureSystemAudio
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let url = try makeFileURL(region: region != nil)
            let output = try RecordingOutput(url: url, width: width, height: height, fps: settings.fps,
                                             bitrateMbps: settings.bitrateMbps, hevc: settings.codec == .hevc,
                                             audio: settings.captureSystemAudio)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if settings.captureSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.output = output
            self.fileURL = url
            isRegion = region != nil
            startedAt = Date()
            isRecording = true
            if region != nil { RegionSelector.shared.showFrame(screen: screen, rect: area) }
            NSSound(named: NSSound.Name("Tink"))?.play()
            OverlayHUD.shared.show(symbol: "record.circle.fill", title: "Aufnahme läuft",
                                   subtitle: "Stoppen mit \(settings.recordHotKey.displayString) oder im Menü", tint: .systemRed)
            DiagnosticsLog.write("screen recording started \(width)x\(height) region=\(region.map { "\($0)" } ?? "full")")
        } catch {
            DiagnosticsLog.write("screen recording failed: \(error)")
            OverlayHUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Aufnahme fehlgeschlagen",
                                   subtitle: error.localizedDescription, tint: .systemOrange)
        }
    }

    func stop() async {
        guard isRecording, let stream, let output, let url = fileURL else { return }
        isRecording = false
        RegionSelector.shared.hideFrame()
        try? await stream.stopCapture()
        let ok = await output.finish()
        self.stream = nil
        self.output = nil
        startedAt = nil
        if ok {
            NSSound(named: NSSound.Name(AppSettings.shared.clipSound))?.play()
            OverlayHUD.shared.show(symbol: "checkmark.circle.fill", title: "Aufnahme gespeichert",
                                   subtitle: url.lastPathComponent, tint: .systemGreen)
            if AppSettings.shared.showNotifications {
                NotificationManager.shared.notify(title: "Bildschirmaufnahme gespeichert", body: url.lastPathComponent, fileURL: url)
            }
            AppState.shared.refreshLibrary()
            if RemoteConfig.shared.autoUpload {
                ClipUploader.shared.upload(url, game: "Bildschirmaufnahme")
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            OverlayHUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Aufnahme fehlgeschlagen",
                                   subtitle: "Es wurde kein Bild empfangen", tint: .systemOrange)
        }
    }

    private func makeFileURL(region: Bool) throws -> URL {
        var base = AppSettings.shared.saveFolderURL
        let comps = base.standardizedFileURL.pathComponents
        if comps.count >= 3, comps[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/\(comps[2])") {
            base = AppSettings.defaultSaveFolder
        }
        base.appendPathComponent("Aufnahmen", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return base.appendingPathComponent("\(region ? "Bereich" : "Bildschirm") \(f.string(from: Date())).mp4")
    }
}

/// Receives ScreenCaptureKit samples and writes them with AVAssetWriter (real-time).
final class RecordingOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.simplex.screenrecorder", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var startTime = CMTime.zero
    private var frames = 0

    init(url: URL, width: Int, height: Int, fps: Int, bitrateMbps: Double, hevc: Bool, audio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let video: [String: Any] = [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        if audio {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        super.init()
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, writer.status == .writing else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !sessionStarted {
                startTime = sample.presentationTimeStamp
                writer.startSession(atSourceTime: startTime)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sample)
                frames += 1
            }
        } else if type == .audio, sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData,
                  CMTimeCompare(sample.presentationTimeStamp, startTime) >= 0 {
            audioInput.append(sample)
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.sessionStarted, self.frames > 0, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }
                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed)
                }
            }
        }
    }
}

// MARK: - Region selection

/// Fullscreen overlay: drag a rectangle to choose what to record.
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()
    private var window: NSWindow?
    private var frameWindow: NSWindow?
    private var completion: ((NSScreen, CGRect) -> Void)?
    private var keyMonitor: Any?

    func select(_ completion: @escaping (NSScreen, CGRect) -> Void) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        self.completion = completion
        // A key-capable panel so Esc reaches us.
        let window = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: RegionSelectionView(
            onDone: { [weak self] rect in self?.finish(screen: screen, rect: rect) },
            onCancel: { [weak self] in self?.cancel() }))
        window.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
        self.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }   // Esc
            return event
        }
    }

    private func close() {
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    private func finish(screen: NSScreen, rect: CGRect) {
        close()
        guard rect.width > 40, rect.height > 40 else { return }
        completion?(screen, rect)
        completion = nil
    }

    private func cancel() {
        close()
        completion = nil
    }

    /// Thin red frame around the recorded region (not part of the recording – this app is excluded).
    func showFrame(screen: NSScreen, rect: CGRect) {
        let cocoa = CGRect(x: screen.frame.minX + rect.minX - 3, y: screen.frame.maxY - rect.maxY - 3,
                           width: rect.width + 6, height: rect.height + 6)
        let window = NSWindow(contentRect: cocoa, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
        window.orderFrontRegardless()
        frameWindow = window
    }

    func hideFrame() {
        frameWindow?.orderOut(nil)
        frameWindow = nil
    }
}

struct RegionSelectionView: View {
    let onDone: (CGRect) -> Void
    let onCancel: () -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35)
                    .mask {
                        Rectangle()
                            .overlay(alignment: .topLeading) {
                                if let rect {
                                    Rectangle().frame(width: rect.width, height: rect.height)
                                        .offset(x: rect.minX, y: rect.minY)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                    }
                if let rect {
                    Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text("\(Int(rect.width)) × \(Int(rect.height))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: rect.minX, y: max(0, rect.minY - 28))
                } else {
                    VStack(spacing: 8) {
                        Text("Bereich zum Aufnehmen aufziehen").font(.title2.bold())
                        Text("Loslassen startet die Aufnahme · Esc bricht ab").foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { _ in
                        if let rect { onDone(rect) } else { onCancel() }
                    })
        }
        .ignoresSafeArea()
    }
}
