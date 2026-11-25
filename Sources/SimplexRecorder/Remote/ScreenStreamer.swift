import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

/// Streams one display as low-latency H.264 (hardware encoder).
///
/// Packet layout (before encryption):
///   [flags u8: bit0 = keyframe][pts µs u64][width u16][height u16]
///   if keyframe: [spsLen u16][sps][ppsLen u16][pps]
///   [AVCC data: 4-byte length-prefixed NAL units]
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        var displayID: CGDirectDisplayID
        var maxWidth: Int = 1920
        var fps: Int = 30
        var kbps: Int = 6000
        var showCursor = true
    }

    var onPacket: ((Data, Bool) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private let queue = DispatchQueue(label: "com.simplex.remote.stream", qos: .userInteractive)
    private var size: (w: Int, h: Int) = (0, 0)
    private var forceKeyframe = true
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime: TimeInterval = 0
    private var refreshTimer: DispatchSourceTimer?

    private(set) var isRunning = false

    func start(_ options: Options) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) ?? content.displays.first else {
            throw ReplayEngineError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        var w = Int(CGFloat(display.width) * scale), h = Int(CGFloat(display.height) * scale)
        let maxW = max(640, options.maxWidth)
        if max(w, h) > maxW {
            let factor = Double(maxW) / Double(max(w, h))
            w = Int(Double(w) * factor)
            h = Int(Double(h) * factor)
        }
        w &= ~1
        h &= ~1
        size = (w, h)

        encoder = try makeEncoder(width: w, height: h, fps: options.fps, kbps: options.kbps)

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 4
        config.showsCursor = options.showCursor
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
        forceKeyframe = true
        startRefreshTimer()
        DiagnosticsLog.write("remote: streaming display \(options.displayID) at \(w)x\(h) @\(options.fps)fps \(options.kbps)kbps")
    }

    func stop() async {
        isRunning = false
        refreshTimer?.cancel()
        refreshTimer = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            if let encoder {
                VTCompressionSessionInvalidate(encoder)
            }
            encoder = nil
            lastFrame = nil
        }
    }

    func requestKeyframe() {
        queue.async { self.forceKeyframe = true }
    }

    var dimensions: (Int, Int) { size }

    // MARK: Encoder

    private func makeEncoder(width: Int, height: Int, fps: Int, kbps: Int) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw ReplayEngineError.encoderFailed(status) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 4))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 4))
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// ScreenCaptureKit only delivers frames when something changes. Re-send the last
    /// frame now and then so a freshly joined viewer gets a picture right away.
    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lastFrame else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastFrameTime > 1.5 || self.forceKeyframe {
                self.encode(frame, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    // MARK: Capture

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastFrame = pixelBuffer
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        encode(pixelBuffer, pts: sampleBuffer.presentationTimeStamp)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let encoder else { return }
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            forceKeyframe = false
        }
        let (w, h) = size
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            guard let packet = Self.packet(from: sample, width: w, height: h) else { return }
            self.onPacket?(packet.data, packet.keyframe)
        }
    }

    private static func packet(from sample: CMSampleBuffer, width: Int, height: Int) -> (data: Data, keyframe: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = sample.formatDescription else { return nil }
        let keyframe = ReplayBuffer.isKeyframe(sample)
        var out = Data()
        out.reserveCapacity(CMBlockBufferGetDataLength(block) + 64)
        out.append(keyframe ? 1 : 0)
        var pts = UInt64(max(0, sample.presentationTimeStamp.seconds * 1_000_000)).bigEndian
        withUnsafeBytes(of: &pts) { out.append(contentsOf: $0) }
        appendU16(&out, UInt16(clamping: width))
        appendU16(&out, UInt16(clamping: height))

        if keyframe {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer else { return nil }
                appendU16(&out, UInt16(clamping: length))
                out.append(pointer, count: length)
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        out.append(contentsOf: bytes)
        return (out, keyframe)
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        DiagnosticsLog.write("remote: stream stopped: \(error)")
        onStop?(error)
    }
}
