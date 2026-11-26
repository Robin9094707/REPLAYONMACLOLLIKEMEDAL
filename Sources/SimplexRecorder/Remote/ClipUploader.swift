import AppKit
import AVFoundation

struct ServerStorage: Equatable {
    var used: Int64 = 0
    var limit: Int64 = 0
    var count = 0
    var diskFree: Int64 = 0
    var enabled = true
}

/// Uploads clips to the user's own relay server and returns a public share link
/// (plays in any browser and embeds in Discord/WhatsApp).
@MainActor
final class ClipUploader: ObservableObject {
    static let shared = ClipUploader()

    @Published private(set) var progress: [URL: Double] = [:]
    @Published private(set) var storage: ServerStorage?
    @Published private(set) var lastError: String?

    private let linksKey = "uploadedClipLinks"

    /// Local file path → share link of clips that were already uploaded.
    var links: [String: String] {
        UserDefaults.standard.dictionary(forKey: linksKey) as? [String: String] ?? [:]
    }

    func link(for url: URL) -> String? { links[url.path] }

    private func remember(_ link: String, for url: URL) {
        var all = links
        all[url.path] = link
        UserDefaults.standard.set(all, forKey: linksKey)
        objectWillChange.send()
    }

    var isAvailable: Bool {
        let c = RemoteConfig.shared
        return c.uploadEnabled && c.isConfigured && c.httpBaseURL != nil
    }

    // MARK: Upload

    func upload(_ url: URL, game: String) {
        guard isAvailable else {
            OverlayHUD.shared.show(symbol: "icloud.slash", title: "Kein Server eingerichtet",
                                   subtitle: "Einstellungen → Remote", tint: .systemOrange)
            return
        }
        if let existing = link(for: url) {
            copy(existing)
            return
        }
        guard progress[url] == nil else { return }
        progress[url] = 0
        OverlayHUD.shared.show(symbol: "icloud.and.arrow.up", title: "Clip wird hochgeladen …",
                               subtitle: url.lastPathComponent, tint: .systemBlue, sticky: true)
        Task {
            do {
                let link = try await performUpload(url, game: game)
                progress[url] = nil
                remember(link, for: url)
                if RemoteConfig.shared.copyLinkAfterUpload {
                    copy(link)
                } else {
                    OverlayHUD.shared.show(symbol: "checkmark.icloud.fill", title: "Clip hochgeladen",
                                           subtitle: link, tint: .systemGreen)
                }
                await refreshStorage()
            } catch {
                progress[url] = nil
                lastError = error.localizedDescription
                DiagnosticsLog.write("upload failed: \(error)")
                OverlayHUD.shared.show(symbol: "exclamationmark.icloud.fill", title: "Hochladen fehlgeschlagen",
                                       subtitle: error.localizedDescription, tint: .systemOrange)
            }
        }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        OverlayHUD.shared.show(symbol: "link", title: "Link kopiert – einfach in Discord einfügen",
                               subtitle: link, tint: .systemGreen)
    }

    private func performUpload(_ source: URL, game: String) async throws -> String {
        guard let base = RemoteConfig.shared.httpBaseURL else { throw URLError(.badURL) }
        let password = RemoteConfig.shared.serverPassword

        // 1. H.264 so the clip plays everywhere (Discord, Chrome, Windows).
        let prepared = try await Self.prepareForSharing(source) { [weak self] p in
            Task { @MainActor in self?.progress[source] = p * 0.4 }
        }
        defer { if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) } }

        // 2. Upload.
        var request = URLRequest(url: base.appendingPathComponent("api/clips"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        request.setValue(enc(source.deletingPathExtension().lastPathComponent), forHTTPHeaderField: "X-Clip-Name")
        request.setValue(enc(game), forHTTPHeaderField: "X-Clip-Game")
        request.setValue(enc(RemoteConfig.shared.computerName), forHTTPHeaderField: "X-Clip-Mac")
        request.setValue(String(format: "%.2f", prepared.duration), forHTTPHeaderField: "X-Clip-Duration")
        request.setValue("\(Int(prepared.size.width))", forHTTPHeaderField: "X-Clip-Width")
        request.setValue("\(Int(prepared.size.height))", forHTTPHeaderField: "X-Clip-Height")

        let delegate = UploadProgressDelegate { [weak self] p in
            Task { @MainActor in self?.progress[source] = 0.4 + p * 0.55 }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: prepared.url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 201, let id = json["id"] as? String, let share = json["shareUrl"] as? String else {
            throw NSError(domain: "Simplex", code: status, userInfo: [NSLocalizedDescriptionKey:
                (json["error"] as? String) ?? "Server antwortet mit \(status)"])
        }

        // 3. Preview image (for the share page, Discord embed and the iPhone gallery).
        if let jpeg = await Self.thumbnail(prepared.url) {
            var thumb = URLRequest(url: base.appendingPathComponent("api/clips/\(id)/thumb"))
            thumb.httpMethod = "POST"
            thumb.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
            thumb.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.upload(for: thumb, from: jpeg)
        }
        DiagnosticsLog.write("uploaded \(source.lastPathComponent) → \(share)")
        return share
    }

    // MARK: Server storage

    func refreshStorage() async {
        guard isAvailable, let base = RemoteConfig.shared.httpBaseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/storage"))
        request.setValue("Bearer \(RemoteConfig.shared.serverPassword)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        func i(_ k: String) -> Int64 { (json[k] as? NSNumber)?.int64Value ?? 0 }
        storage = ServerStorage(used: i("used"), limit: i("limit"), count: Int(i("count")),
                                diskFree: i("diskFree"), enabled: json["enabled"] as? Bool ?? true)
    }

    // MARK: Media helpers

    struct Prepared {
        let url: URL
        let isTemporary: Bool
        let duration: Double
        let size: CGSize
    }

    nonisolated static func prepareForSharing(_ url: URL, progress: @escaping (Double) -> Void) async throws -> Prepared {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Simplex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Videospur gefunden"])
        }
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        if isH264 {
            progress(1)
            return Prepared(url: url, isTemporary: false, duration: duration, size: natural)
        }

        let preset = natural.height > 1100 ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            return Prepared(url: url, isTemporary: false, duration: duration, size: natural)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("simplex-share-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        poll.cancel()
        guard export.status == .completed else {
            throw export.error ?? NSError(domain: "Simplex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Umwandlung fehlgeschlagen"])
        }
        let scale = min(1, 1080 / max(natural.height, 1))
        return Prepared(url: out, isTemporary: true, duration: duration,
                        size: CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded()))
    }

    nonisolated static func thumbnail(_ url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        guard let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: result.image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void
    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
