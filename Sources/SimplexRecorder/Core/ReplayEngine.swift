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
    var cropTitleBar: Bool
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
    private var audioFilter: SCContentFilter?
    private var audioConfig: CaptureConfig?
    private var audioIncludesMic = false
    private var lastAudioPacket = Date.distantPast
    private var lastAudioRestart = Date.distantPast
    private var audioRestarting = false
    private var audioOffset: CMTime?
    private var micOffset: CMTime?
    private var audioPackets = 0
    private var audioPeak: Float = 0
    private var encoder: VTCompressionSession?
    private let videoQueue = DispatchQueue(label: "com.simplex.recorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.simplex.recorder.audio", qos: .userInitiated)
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private let stateLock = NSLock()
    private var _isRunning = false

    private(set) var outputSize: CGSize = .zero
    /// Current video filter/config – reused for screenshots and live window updates.
    private var videoFilter: SCContentFilter?
    private var videoConfig: SCStreamConfiguration?
    private var windowMode = false
    private var windowCrop = false
    private var displayPointSize: CGSize = .zero
    private var lastWindowSize: CGSize = .zero
    /// Title bar height of a standard macOS window in points.
    private static let titleBarHeight: CGFloat = 28
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
        if let game {
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == game.pid && $0.windowLayer == 0
                    && $0.frame.width >= 100 && $0.frame.height >= 100
            }
            mainWindow = candidates.first { game.windowID != 0 && $0.windowID == game.windowID }
                ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        let display = Self.display(for: mainWindow?.frame, in: content.displays)
        let displayScale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)

        let filter: SCContentFilter
        let gameApp = game.flatMap { g in content.applications.first { $0.processID == g.pid } }
        var width: Int
        var height: Int
        var sourceRect: CGRect?
        windowMode = false

        if config.target == .gameWindow, let window = mainWindow {
            // Only the game window, independent of where it sits on screen. The output is a
            // fixed canvas with the display's aspect ratio: fullscreen fills it exactly,
            // smaller windows are scaled up (letterboxed if the aspect differs). Resizing the
            // window never restarts the capture, so the replay buffer stays intact.
            filter = SCContentFilter(desktopIndependentWindow: window)
            windowMode = true
            windowCrop = config.cropTitleBar
            displayPointSize = display.frame.size
            lastWindowSize = window.frame.size
            width = Int((display.frame.width * displayScale).rounded())
            height = Int((display.frame.height * displayScale).rounded())
            sourceRect = cropRect(for: window.frame.size)
        } else if config.target != .fullDisplay, let app = gameApp {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            width = Int((display.frame.width * displayScale).rounded())
            height = Int((display.frame.height * displayScale).rounded())
        } else {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            width = Int((display.frame.width * displayScale).rounded())
            height = Int((display.frame.height * displayScale).rounded())
        }

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
            try await startStream(filter: filter, width: width, height: height, fps: fps,
                                  config: config, sourceRect: sourceRect)
        } catch {
            VTCompressionSessionInvalidate(encoder)
            throw error
        }

        audioQueue.sync {
            self.audioOffset = nil
            self.micOffset = nil
            self.audioPackets = 0
            self.audioPeak = 0
        }
        DiagnosticsLog.write("video stream started \(width)x\(height) @\(fps)fps target=\(config.target.rawValue) window=\(mainWindow.map { "\($0.windowID) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-") crop=\(sourceRect.map { "\($0)" } ?? "none") game=\(game?.name ?? "-")")
        if config.captureSystemAudio || config.captureMicrophone {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            let audioFilter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            do {
                try await startAudioStream(filter: audioFilter, config: config, includeMicrophone: config.captureMicrophone)
                DiagnosticsLog.write("audio stream started (system: \(config.captureSystemAudio), mic: \(config.captureMicrophone))")
            } catch where config.captureMicrophone {
                DiagnosticsLog.write("audio stream with mic failed: \(error) – retrying without mic")
                do {
                    try await startAudioStream(filter: audioFilter, config: config, includeMicrophone: false)
                    DiagnosticsLog.write("audio stream started without mic")
                } catch {
                    DiagnosticsLog.write("audio stream failed: \(error)")
                }
            } catch {
                DiagnosticsLog.write("audio stream failed: \(error)")
            }
        }

        videoQueue.sync { self.encoder = encoder }
        outputSize = CGSize(width: width, height: height)
        setRunning(true)
    }

    private func startStream(filter: SCContentFilter, width: Int, height: Int, fps: Int,
                             config: CaptureConfig, sourceRect: CGRect?) async throws {
        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.queueDepth = 8
        sc.showsCursor = config.showCursor
        sc.scalesToFit = true
        sc.preservesAspectRatio = true
        sc.backgroundColor = .black
        sc.capturesAudio = false
        if let sourceRect { sc.sourceRect = sourceRect }

        let stream = SCStream(filter: filter, configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.scStream = stream
        self.videoFilter = filter
        self.videoConfig = sc
    }

    /// Window crop (title bar removed), in window-local points. Nil = whole window.
    private func cropRect(for windowSize: CGSize) -> CGRect? {
        guard windowMode, windowCrop else { return nil }
        // Fullscreen windows have no title bar.
        let isFullscreen = windowSize.width >= displayPointSize.width - 1
            && windowSize.height >= displayPointSize.height - 1
        guard !isFullscreen, windowSize.height > Self.titleBarHeight * 3 else { return nil }
        return CGRect(x: 0, y: Self.titleBarHeight,
                      width: windowSize.width, height: windowSize.height - Self.titleBarHeight)
    }

    /// Called when the game window was resized or toggled fullscreen: adjusts the crop
    /// live, without restarting the stream.
    func updateWindowGeometry(size: CGSize) async {
        guard windowMode, isRunning, let stream = scStream, let current = videoConfig,
              abs(size.width - lastWindowSize.width) > 2 || abs(size.height - lastWindowSize.height) > 2 else { return }
        lastWindowSize = size
        guard windowCrop else { return }
        let sc = Self.copy(current)
        sc.sourceRect = cropRect(for: size) ?? CGRect(origin: .zero, size: size)
        do {
            try await stream.updateConfiguration(sc)
            videoConfig = sc
            DiagnosticsLog.write("window resized to \(Int(size.width))x\(Int(size.height)) – crop updated")
        } catch {
            DiagnosticsLog.write("updateConfiguration failed: \(error)")
        }
    }

    /// Full-resolution still of what is currently captured.
    func screenshot() async throws -> CGImage {
        guard let filter = videoFilter, let current = videoConfig else { throw ReplayEngineError.noDisplay }
        let sc = Self.copy(current)
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.showsCursor = current.showsCursor
        if windowMode {
            // Native window resolution instead of the (letterboxed) video canvas.
            let crop = cropRect(for: lastWindowSize)
            let size = crop?.size ?? lastWindowSize
            let scale = CGFloat(filter.pointPixelScale)
            sc.width = max(64, Int(size.width * scale))
            sc.height = max(64, Int(size.height * scale))
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: sc)
    }

    private static func copy(_ c: SCStreamConfiguration) -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.width = c.width
        sc.height = c.height
        sc.minimumFrameInterval = c.minimumFrameInterval
        sc.pixelFormat = c.pixelFormat
        sc.queueDepth = c.queueDepth
        sc.showsCursor = c.showsCursor
        sc.scalesToFit = c.scalesToFit
        sc.preservesAspectRatio = c.preservesAspectRatio
        sc.backgroundColor = c.backgroundColor
        sc.capturesAudio = c.capturesAudio
        sc.sourceRect = c.sourceRect
        return sc
    }

    private func startAudioStream(filter: SCContentFilter, config: CaptureConfig, includeMicrophone: Bool) async throws {
        let sc = SCStreamConfiguration()
        // Video is required by ScreenCaptureKit but unused here – keep it as tiny as possible.
        sc.width = 128
        sc.height = 72
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
        self.audioFilter = filter
        self.audioConfig = config
        self.audioIncludesMic = includeMicrophone
        self.lastAudioPacket = Date()
    }

    /// Watchdog, called about once per second: restarts the audio stream if it stopped
    /// or has not delivered anything for a while.
    func checkAudioHealth() {
        guard isRunning, !audioRestarting, let filter = audioFilter, let config = audioConfig,
              config.captureSystemAudio || config.captureMicrophone else { return }
        let silentFor = Date().timeIntervalSince(lastAudioPacket)
        let stopped = audioStream == nil
        guard stopped || silentFor > 8 else { return }
        guard Date().timeIntervalSince(lastAudioRestart) > 15 else { return }
        lastAudioRestart = Date()
        audioRestarting = true
        DiagnosticsLog.write("audio watchdog: \(stopped ? "stream stopped" : "no audio for \(Int(silentFor)) s") – restarting audio stream")
        let old = audioStream
        audioStream = nil
        let includeMic = audioIncludesMic
        Task {
            if let old { try? await old.stopCapture() }
            do {
                try await self.startAudioStream(filter: filter, config: config, includeMicrophone: includeMic)
                DiagnosticsLog.write("audio watchdog: restarted")
            } catch {
                DiagnosticsLog.write("audio watchdog: restart failed: \(error)")
            }
            self.audioRestarting = false
        }
    }

    func stop() async {
        setRunning(false)
        if let stream = scStream {
            try? await stream.stopCapture()
        }
        audioFilter = nil
        audioConfig = nil
        if let stream = audioStream {
            try? await stream.stopCapture()
        }
        scStream = nil
        audioStream = nil
        videoFilter = nil
        videoConfig = nil
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

    /// Copies the PCM data into memory we own (ScreenCaptureKit may recycle its audio
    /// buffers, which would leave silence/garbage in a long-lived ring buffer) and moves
    /// the timestamps onto the host clock used by the video, if they differ.
    private func alignedToHostClock(_ sample: CMSampleBuffer, offset: inout CMTime?) -> CMSampleBuffer? {
        if offset == nil {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let diff = CMTimeSubtract(now, sample.presentationTimeStamp)
            offset = abs(diff.seconds) > 1.0 ? diff : .zero
            if let fmt = sample.formatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                DiagnosticsLog.write("first audio packet: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags), \(asbd.mBitsPerChannel) bit, frames \(CMSampleBufferGetNumSamples(sample)), clock offset \(String(format: "%.3f", diff.seconds)) s")
            }
        }
        let copy = AudioCopy.deepCopy(sample, offset: offset ?? .zero)
        if let copy {
            audioPackets += 1
            lastAudioPacket = Date()
            audioPeak = max(audioPeak, AudioCopy.peak(of: copy))
            if audioPackets % 1500 == 0 { // ~ every 30 s
                DiagnosticsLog.write("audio: \(audioPackets) packets, peak level \(String(format: "%.4f", audioPeak))\(audioPeak < 0.0001 ? " (STILLE)" : "")")
                audioPeak = 0
            }
        } else if audioPackets == 0 {
            DiagnosticsLog.write("audio copy failed")
        }
        return copy
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
            DiagnosticsLog.write("audio stream stopped: \(error)")
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
