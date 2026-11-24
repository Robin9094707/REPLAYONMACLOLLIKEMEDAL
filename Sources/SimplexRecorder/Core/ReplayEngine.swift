import Foundation
import ScreenCaptureKit
import VideoToolbox
import AVFoundation
import CoreMedia

struct CaptureConfig: Equatable {
    var fps: Int
    var bitrateMbps: Double
    var codec: VideoCodecChoice
    var maxHeight: Int?
    var captureSystemAudio: Bool
    var captureMicrophone: Bool
    var showCursor: Bool
    var target: CaptureTarget
}

enum ReplayEngineError: LocalizedError {
    case noDisplay
    case encoderFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Kein Bildschirm zum Aufnehmen gefunden."
        case .encoderFailed(let status): return "Video-Encoder konnte nicht gestartet werden (\(status))."
        }
    }
}

/// Captures the game with ScreenCaptureKit, encodes it with the hardware
/// encoder (VideoToolbox) and feeds the result into the in-memory `ReplayBuffer`.
final class ReplayEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    let buffer = ReplayBuffer()

    private var scStream: SCStream?
    /// Separate audio-only stream for the *whole* system sound (excluding this app).
    /// Per-app audio attribution is unreliable for games launched through launchers
    /// (e.g. Minecraft Java runs in a `java` child process of the launcher).
    private var audioStream: SCStream?
    private var audioOffset: CMTime?
    private var micOffset: CMTime?
    private var encoder: VTCompressionSession?
    private let videoQueue = DispatchQueue(label: "com.simplex.recorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.simplex.recorder.audio", qos: .userInitiated)
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private let stateLock = NSLock()
    private var _isRunning = false

    private(set) var outputSize: CGSize = .zero
    var onUnexpectedStop: ((Error) -> Void)?

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); _isRunning = value; stateLock.unlock()
    }

    // MARK: Start / Stop

    func start(game: DetectedGame?, config: CaptureConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw ReplayEngineError.noDisplay }

        var mainWindow: SCWindow?
        if let pid = game?.pid {
            mainWindow = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        let display = Self.display(for: mainWindow?.frame, in: content.displays)

        let filter: SCContentFilter
        let pointSize: CGSize
        let gameApp = game.flatMap { g in content.applications.first { $0.processID == g.pid } }

        if config.target == .gameWindow, let window = mainWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = window.frame.size
        } else if config.target != .fullDisplay, let app = gameApp {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            pointSize = display.frame.size
        } else {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            pointSize = display.frame.size
        }

        let scale = CGFloat(filter.pointPixelScale)
        var width = Int((pointSize.width * scale).rounded())
        var height = Int((pointSize.height * scale).rounded())
        if let maxHeight = config.maxHeight, height > maxHeight {
            width = Int((Double(width) * Double(maxHeight) / Double(height)).rounded())
            height = maxHeight
        }
        if config.codec == .h264, width > 4096 {
            height = Int((Double(height) * 4096.0 / Double(width)).rounded())
            width = 4096
        }
        width = max(64, width & ~1)
        height = max(64, height & ~1)

        let fps = max(1, config.fps)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let encoder = try makeEncoder(width: width, height: height, fps: fps, config: config)

        do {
            try await startStream(filter: filter, width: width, height: height, fps: fps, config: config)
        } catch {
            VTCompressionSessionInvalidate(encoder)
            throw error
        }

        audioQueue.sync {
            self.audioOffset = nil
            self.micOffset = nil
        }
        if config.captureSystemAudio || config.captureMicrophone {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            let audioFilter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            do {
                try await startAudioStream(filter: audioFilter, config: config, includeMicrophone: config.captureMicrophone)
            } catch where config.captureMicrophone {
                // Microphone permission missing or device busy – retry without it.
                try? await startAudioStream(filter: audioFilter, config: config, includeMicrophone: false)
            } catch {
                NSLog("SimplexRecorder: audio stream failed: \(error)")
            }
        }

        videoQueue.sync { self.encoder = encoder }
        outputSize = CGSize(width: width, height: height)
        setRunning(true)
    }

    private func startStream(filter: SCContentFilter, width: Int, height: Int, fps: Int,
                             config: CaptureConfig) async throws {
        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.queueDepth = 6
        sc.showsCursor = config.showCursor
        sc.scalesToFit = true
        sc.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.scStream = stream
    }

    private func startAudioStream(filter: SCContentFilter, config: CaptureConfig, includeMicrophone: Bool) async throws {
        let sc = SCStreamConfiguration()
        // Video is required by ScreenCaptureKit but unused here – keep it as tiny as possible.
        sc.width = 32
        sc.height = 32
        sc.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        sc.queueDepth = 3
        sc.showsCursor = false
        sc.capturesAudio = config.captureSystemAudio
        sc.sampleRate = 48_000
        sc.channelCount = 2
        sc.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            sc.captureMicrophone = includeMicrophone
        }
        let stream = SCStream(filter: filter, configuration: sc, delegate: self)
        // A screen output avoids "output not found" log spam; its frames are ignored.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        if config.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if #available(macOS 15.0, *), includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.audioStream = stream
    }

    func stop() async {
        setRunning(false)
        if let stream = scStream {
            try? await stream.stopCapture()
        }
        if let stream = audioStream {
            try? await stream.stopCapture()
        }
        scStream = nil
        audioStream = nil
        teardownEncoder()
    }

    private func teardownEncoder() {
        videoQueue.sync {
            if let encoder = self.encoder {
                VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(encoder)
            }
            self.encoder = nil
        }
    }

    // MARK: Encoder

    private func makeEncoder(width: Int, height: Int, fps: Int, config: CaptureConfig) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let codecType = config.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { throw ReplayEngineError.encoderFailed(status) }

        let bitrate = Int(config.bitrateMbps * 1_000_000)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        // One keyframe per second → clips can start (almost) exactly N seconds back.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0))
        let profile = config.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            if stream === audioStream { return }
            handleVideo(sampleBuffer)
        } else if type == .audio {
            if let fixed = alignedToHostClock(sampleBuffer, offset: &audioOffset) {
                buffer.appendAudio(fixed)
            }
        } else if #available(macOS 15.0, *), type == .microphone {
            if let fixed = alignedToHostClock(sampleBuffer, offset: &micOffset) {
                buffer.appendMicrophone(fixed)
            }
        }
    }

    /// Video timestamps are on the host clock. Should an audio stream use a different
    /// timebase, shift it once so both line up (measured on the first sample).
    private func alignedToHostClock(_ sample: CMSampleBuffer, offset: inout CMTime?) -> CMSampleBuffer? {
        if offset == nil {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let diff = CMTimeSubtract(now, sample.presentationTimeStamp)
            offset = abs(diff.seconds) > 1.0 ? diff : .zero
            if offset != .zero {
                NSLog("SimplexRecorder: audio clock offset \(diff.seconds)s – correcting")
            }
        }
        guard let value = offset, value != .zero else { return sample }
        return ClipExporter.retimed(sample, offset: value)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let encoder else { return }

        let buffer = self.buffer
        VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: frameDuration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, encoded in
            guard status == noErr, let encoded else { return }
            buffer.appendVideo(encoded)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stream === audioStream {
            // Losing audio is not fatal – the video keeps running.
            NSLog("SimplexRecorder: audio stream stopped: \(error)")
            audioStream = nil
            return
        }
        let wasRunning = isRunning
        setRunning(false)
        if let audio = audioStream {
            audioStream = nil
            Task { try? await audio.stopCapture() }
        }
        videoQueue.async {
            if let encoder = self.encoder {
                VTCompressionSessionInvalidate(encoder)
            }
            self.encoder = nil
        }
        if wasRunning { onUnexpectedStop?(error) }
    }

    // MARK: Helpers

    private static func display(for frame: CGRect?, in displays: [SCDisplay]) -> SCDisplay {
        if let frame {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let match = displays.first(where: { $0.frame.contains(center) }) { return match }
            let best = displays.max { a, b in
                let ia = a.frame.intersection(frame), ib = b.frame.intersection(frame)
                return ia.width * ia.height < ib.width * ib.height
            }
            if let best { return best }
        }
        let mainID = CGMainDisplayID()
        return displays.first { $0.displayID == mainID } ?? displays[0]
    }
}
