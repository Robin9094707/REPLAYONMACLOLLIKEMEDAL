import Foundation
import CoreMedia

/// Thread-safe ring buffer holding the last N seconds of *encoded* video
/// plus raw PCM audio. Lives entirely in RAM – nothing is written to disk
/// until a clip is saved, which keeps SSD wear and energy use low.
final class ReplayBuffer {
    struct Snapshot {
        let video: [CMSampleBuffer]
        let audio: [CMSampleBuffer]
        let mic: [CMSampleBuffer]
        var isEmpty: Bool { video.isEmpty }
    }

    private let lock = NSLock()
    private var video: [CMSampleBuffer] = []
    private var audio: [CMSampleBuffer] = []
    private var mic: [CMSampleBuffer] = []
    private var videoBytes = 0
    private var _maxSeconds: Double = 33
    private var audioAppendCounter = 0

    var maxSeconds: Double {
        get { locked { _maxSeconds } }
        set { locked { _maxSeconds = max(5, newValue) } }
    }

    var bufferedSeconds: Double {
        locked {
            guard let first = video.first, let last = video.last else { return 0 }
            return max(0, last.presentationTimeStamp.seconds - first.presentationTimeStamp.seconds)
        }
    }

    /// Seconds of system audio currently buffered (diagnostics).
    var audioSeconds: Double {
        locked {
            guard let first = audio.first, let last = audio.last else { return 0 }
            return max(0, last.presentationTimeStamp.seconds - first.presentationTimeStamp.seconds)
        }
    }

    var approximateBytes: Int {
        locked {
            let audioBytes = (audio.count + mic.count) * 8_192
            return videoBytes + audioBytes
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        locked {
            video.append(sample)
            videoBytes += sample.totalSampleSize
            if Self.isKeyframe(sample) { trimLocked() }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        locked {
            audio.append(sample)
            audioAppendCounter += 1
            if audioAppendCounter % 64 == 0 { trimAudioLocked() }
        }
    }

    func appendMicrophone(_ sample: CMSampleBuffer) {
        locked {
            mic.append(sample)
            audioAppendCounter += 1
            if audioAppendCounter % 64 == 0 { trimAudioLocked() }
        }
    }

    func snapshot() -> Snapshot {
        locked { Snapshot(video: video, audio: audio, mic: mic) }
    }

    func clear() {
        locked {
            video.removeAll()
            audio.removeAll()
            mic.removeAll()
            videoBytes = 0
        }
    }

    // MARK: Helpers

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as NSArray?,
              let first = attachments.firstObject as? NSDictionary else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        return true
    }

    private func trimLocked() {
        guard let last = video.last else { return }
        let cutoff = last.presentationTimeStamp.seconds - _maxSeconds
        var dropCount = 0
        for (index, sample) in video.enumerated() {
            if sample.presentationTimeStamp.seconds > cutoff { break }
            if Self.isKeyframe(sample) { dropCount = index }
        }
        if dropCount > 0 {
            for sample in video[0..<dropCount] { videoBytes -= sample.totalSampleSize }
            video.removeFirst(dropCount)
        }
        trimAudioLocked()
    }

    private func trimAudioLocked() {
        let latestAudio = max(audio.last?.presentationTimeStamp.seconds ?? 0,
                              mic.last?.presentationTimeStamp.seconds ?? 0)
        // Trim on the audio's own timeline only – never relative to video timestamps.
        let cutoff = latestAudio - _maxSeconds - 2
        if let index = audio.firstIndex(where: { $0.presentationTimeStamp.seconds >= cutoff }) {
            if index > 0 { audio.removeFirst(index) }
        } else {
            audio.removeAll()
        }
        if let index = mic.firstIndex(where: { $0.presentationTimeStamp.seconds >= cutoff }) {
            if index > 0 { mic.removeFirst(index) }
        } else {
            mic.removeAll()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
