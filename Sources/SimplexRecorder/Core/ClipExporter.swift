import Foundation
import AVFoundation
import CoreMedia

enum ClipExportError: LocalizedError {
    case noVideo
    case writerFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Im Puffer ist noch kein Videomaterial."
        case .writerFailed(let message): return "Clip konnte nicht geschrieben werden: \(message)"
        case .timeout: return "Zeitüberschreitung beim Schreiben des Clips."
        }
    }
}

/// Writes the buffered samples to an .mp4 file.
/// Video is copied without re-encoding (instant), audio is encoded to AAC.
enum ClipExporter {
    /// Returns the duration of the written clip in seconds. Blocking – call off the main thread.
    static func writeClip(snapshot: ReplayBuffer.Snapshot, duration: Double, to url: URL) throws -> Double {
        let video = snapshot.video
        guard let last = video.last, let format = last.formatDescription else { throw ClipExportError.noVideo }

        // Only use the trailing run of samples that share the current format
        // (resolution/codec may have changed after a restart of the capture).
        var firstSameFormat = video.count - 1
        while firstSameFormat > 0,
              CMFormatDescriptionEqual(video[firstSameFormat - 1].formatDescription, otherFormatDescription: format) {
            firstSameFormat -= 1
        }

        let endPTS = last.presentationTimeStamp
        let desiredStart = CMTimeSubtract(endPTS, CMTime(seconds: duration, preferredTimescale: 600))
        let keyIndices = (firstSameFormat..<video.count).filter { ReplayBuffer.isKeyframe(video[$0]) }
        guard let firstKey = keyIndices.first else { throw ClipExportError.noVideo }
        let startIndex = keyIndices.last(where: { CMTimeCompare(video[$0].presentationTimeStamp, desiredStart) <= 0 }) ?? firstKey
        let clipVideo = Array(video[startIndex...])
        let startPTS = clipVideo[0].presentationTimeStamp

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ClipExportError.writerFailed("Videospur") }
        writer.add(videoInput)

        func inRange(_ sample: CMSampleBuffer) -> Bool {
            let pts = sample.presentationTimeStamp
            return CMTimeCompare(pts, startPTS) >= 0 && CMTimeCompare(pts, endPTS) <= 0
        }

        func makeAudioInput(for samples: [CMSampleBuffer]) -> AVAssetWriterInput? {
            guard let first = samples.first, let audioFormat = first.formatDescription else { return nil }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
            let sampleRate = asbd?.mSampleRate ?? 48_000
            let channels = max(1, min(Int(asbd?.mChannelsPerFrame ?? 2), 2))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            return input
        }

        let clipAudio = snapshot.audio.filter(inRange)
        let clipMic = snapshot.mic.filter(inRange)
        let audioInput = makeAudioInput(for: clipAudio)
        let micInput = makeAudioInput(for: clipMic)

        struct Item {
            let sample: CMSampleBuffer
            let input: AVAssetWriterInput
            let time: Double
        }
        var items: [Item] = clipVideo.map { Item(sample: $0, input: videoInput, time: $0.presentationTimeStamp.seconds) }
        if let audioInput {
            items += clipAudio.map { Item(sample: $0, input: audioInput, time: $0.presentationTimeStamp.seconds) }
        }
        if let micInput {
            items += clipMic.map { Item(sample: $0, input: micInput, time: $0.presentationTimeStamp.seconds) }
        }
        items.sort { $0.time < $1.time }

        guard writer.startWriting() else {
            throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "Start fehlgeschlagen")
        }
        writer.startSession(atSourceTime: startPTS)

        for item in items {
            let deadline = Date().addingTimeInterval(10)
            while !item.input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "unbekannt")
                }
                if Date() > deadline { writer.cancelWriting(); throw ClipExportError.timeout }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !item.input.append(item.sample) {
                if writer.status == .failed {
                    throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "unbekannt")
                }
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        if semaphore.wait(timeout: .now() + 30) == .timedOut { throw ClipExportError.timeout }
        guard writer.status == .completed else {
            throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "Status \(writer.status.rawValue)")
        }
        return CMTimeSubtract(endPTS, startPTS).seconds
    }
}
