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
        var keyIndices: [Int] = []
        for index in firstSameFormat..<video.count where ReplayBuffer.isKeyframe(video[index]) {
            keyIndices.append(index)
        }
        guard let firstKey = keyIndices.first else { throw ClipExportError.noVideo }
        var clipStart: Int = firstKey
        for index in keyIndices where CMTimeCompare(video[index].presentationTimeStamp, desiredStart) <= 0 {
            clipStart = index
        }
        let clipVideo: [CMSampleBuffer] = Array(video[clipStart..<video.count])
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

        // Audio and video normally share the host clock. If they don't overlap at all,
        // shift the audio so its newest sample lines up with the newest video frame.
        let firstVideoPTS = video[firstSameFormat].presentationTimeStamp
        let audioSource = alignAudio(snapshot.audio, firstVideo: firstVideoPTS, lastVideo: endPTS)
        let micSource = alignAudio(snapshot.mic, firstVideo: firstVideoPTS, lastVideo: endPTS)

        let clipAudio = audioSource.filter(inRange)
        let clipMic = micSource.filter(inRange)
        let audioInput = makeAudioInput(for: clipAudio)
        let micInput = makeAudioInput(for: clipMic)

        guard writer.startWriting() else {
            throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "Start fehlgeschlagen")
        }
        writer.startSession(atSourceTime: startPTS)

        // Feed every track independently – the writer does the interleaving itself.
        // (Feeding all tracks from one loop can deadlock: the writer pauses one track
        // until the others catch up.)
        let group = DispatchGroup()
        feed(videoInput, samples: clipVideo, writer: writer, group: group, label: "video")
        if let audioInput { feed(audioInput, samples: clipAudio, writer: writer, group: group, label: "audio") }
        if let micInput { feed(micInput, samples: clipMic, writer: writer, group: group, label: "mic") }

        let timeout = max(30.0, Double(clipVideo.count) / 30.0)
        if group.wait(timeout: .now() + timeout) == .timedOut {
            writer.cancelWriting()
            throw ClipExportError.timeout
        }
        if writer.status == .failed {
            throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "unbekannt")
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        if semaphore.wait(timeout: .now() + 30) == .timedOut { throw ClipExportError.timeout }
        guard writer.status == .completed else {
            throw ClipExportError.writerFailed(writer.error?.localizedDescription ?? "Status \(writer.status.rawValue)")
        }
        return CMTimeSubtract(endPTS, startPTS).seconds
    }
    private final class FeedState {
        var index = 0
        var done = false
    }

    private static func feed(_ input: AVAssetWriterInput, samples: [CMSampleBuffer],
                             writer: AVAssetWriter, group: DispatchGroup, label: String) {
        group.enter()
        let state = FeedState()
        let queue = DispatchQueue(label: "com.simplex.recorder.export.\(label)")
        input.requestMediaDataWhenReady(on: queue) {
            guard !state.done else { return }
            while input.isReadyForMoreMediaData {
                if state.index >= samples.count || writer.status != .writing {
                    state.done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                if !input.append(samples[state.index]) {
                    state.done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                state.index += 1
            }
        }
    }

    private static func alignAudio(_ samples: [CMSampleBuffer], firstVideo: CMTime, lastVideo: CMTime) -> [CMSampleBuffer] {
        guard let firstAudio = samples.first?.presentationTimeStamp,
              let lastAudio = samples.last?.presentationTimeStamp else { return samples }
        let slack = CMTime(seconds: 5, preferredTimescale: 600)
        let overlaps = CMTimeCompare(lastAudio, CMTimeSubtract(firstVideo, slack)) >= 0
            && CMTimeCompare(firstAudio, CMTimeAdd(lastVideo, slack)) <= 0
        if overlaps { return samples }
        let offset = CMTimeSubtract(lastVideo, lastAudio)
        return samples.compactMap { retimed($0, offset: offset) }
    }

    static func retimed(_ sample: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<infos.count {
            infos[i].presentationTimeStamp = CMTimeAdd(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeAdd(infos[i].decodeTimeStamp, offset)
            }
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: count, sampleTimingArray: &infos,
                                                           sampleBufferOut: &output)
        return status == noErr ? output : nil
    }
}
