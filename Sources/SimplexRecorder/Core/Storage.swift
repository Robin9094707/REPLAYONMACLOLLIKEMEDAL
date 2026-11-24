import AppKit
import AVFoundation

// MARK: - Disk / volume info

struct StorageInfo: Equatable {
    var volumeName: String
    var volumePath: String
    var total: Int64
    var available: Int64
    var clipsBytes: Int64
    var clipCount: Int
    var isInternal: Bool
    var isMounted: Bool

    var otherBytes: Int64 { max(0, total - available - clipsBytes) }
}

@MainActor
final class StorageMonitor: ObservableObject {
    @Published private(set) var info: StorageInfo?

    func refresh(folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            let info = StorageMonitor.compute(folder: folder)
            Task { @MainActor in
                if self.info != info { self.info = info }
            }
        }
    }

    nonisolated static func compute(folder: URL) -> StorageInfo {
        let fm = FileManager.default
        var isMounted = true
        let components = folder.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            isMounted = fm.fileExists(atPath: "/Volumes/\(components[2])")
        }

        var probe = folder
        while !fm.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }

        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeURLKey,
        ]
        let values = try? probe.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        var available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        if available <= 0 { available = Int64(values?.volumeAvailableCapacity ?? 0) }

        var clipsBytes: Int64 = 0
        var clipCount = 0
        if isMounted, let enumerator = fm.enumerator(at: folder,
                                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard ext == "mp4" || ext == "mov" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                clipsBytes += Int64(size)
                clipCount += 1
            }
        }

        return StorageInfo(
            volumeName: values?.volumeName ?? (components.count >= 3 ? components[2] : "Mac"),
            volumePath: values?.volume?.path ?? "/",
            total: total,
            available: available,
            clipsBytes: clipsBytes,
            clipCount: clipCount,
            isInternal: values?.volumeIsInternal ?? true,
            isMounted: isMounted)
    }

    /// External, user-visible volumes (USB/Thunderbolt drives).
    nonisolated static func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard url.path.hasPrefix("/Volumes/") else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsInternal == false && values?.volumeIsBrowsable != false
        }
    }
}

// MARK: - Clip library

struct Clip: Identifiable, Hashable {
    let url: URL
    let name: String
    let game: String
    let date: Date
    let size: Int64
    var id: URL { url }
}

@MainActor
final class ClipLibrary: ObservableObject {
    @Published private(set) var clips: [Clip] = []

    func reload(folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            let clips = ClipLibrary.scan(folder)
            Task { @MainActor in self.clips = clips }
        }
    }

    nonisolated static func scan(_ folder: URL) -> [Clip] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [Clip] = []
        let rootPath = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "mp4" || ext == "mov" else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let game = parent.path == rootPath ? "Clips" : parent.lastPathComponent
            result.append(Clip(url: url,
                               name: url.deletingPathExtension().lastPathComponent,
                               game: game,
                               date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                               size: Int64(values?.fileSize ?? 0)))
        }
        return result.sorted { $0.date > $1.date }
    }

    func moveToTrash(_ clip: Clip) {
        NSWorkspace.shared.recycle([clip.url]) { _, _ in
            Task { @MainActor in self.clips.removeAll { $0.id == clip.id } }
        }
    }

    /// Deletes the oldest clips until the folder is below `maxBytes`.
    /// Deletes permanently – the trash of an external drive would not free any space.
    nonisolated static func enforceLimit(folder: URL, maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        var clips = scan(folder)
        var total = clips.reduce(Int64(0)) { $0 + $1.size }
        while total > maxBytes, let oldest = clips.popLast() {
            if (try? FileManager.default.removeItem(at: oldest.url)) != nil {
                total -= oldest.size
            }
        }
    }
}

// MARK: - Thumbnails

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]
    private var durations: [URL: Double] = [:]

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        guard let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        let image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        cache[url] = image
        return image
    }

    func duration(for url: URL) async -> Double? {
        if let cached = durations[url] { return cached }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        durations[url] = duration.seconds
        return duration.seconds
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
