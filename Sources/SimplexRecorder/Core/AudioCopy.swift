import Foundation
import CoreMedia
import AudioToolbox

enum AudioCopy {
    /// Creates an independent copy of a PCM sample buffer (own memory), optionally
    /// shifting its presentation time by `offset`.
    static func deepCopy(_ source: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        guard let format = source.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let frames = CMSampleBufferGetNumSamples(source)
        guard frames > 0 else { return nil }

        // 1. Read the source AudioBufferList.
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            source, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, listSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            source, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock)
        guard status == noErr else { return nil }

        // 2. New, empty sample buffer with the same format and (shifted) timing.
        let pts = offset == .zero ? source.presentationTimeStamp
                                  : CMTimeAdd(source.presentationTimeStamp, offset)
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                      makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                      sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &output)
        guard status == noErr, let output else { return nil }

        // 3. Copies the bytes into a freshly allocated block buffer.
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            output, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: list)
        guard status == noErr else { return nil }
        return output
    }

    /// Peak absolute sample value (Float32 PCM only, otherwise 1 = "unknown, assume sound").
    static func peak(of sample: CMSampleBuffer) -> Float {
        guard let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sample) else { return 1 }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return 1 }
        let count = length / MemoryLayout<Float>.size
        var peak: Float = 0
        pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
            var i = 0
            while i < count {
                peak = max(peak, abs(floats[i]))
                i += 4
            }
        }
        return peak
    }
}
