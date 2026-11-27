import AppKit
import AVFoundation
import Combine
import CryptoKit

struct ServerStorage: Equatable {
    var used: Int64 = 0
    var limit: Int64 = 0
    var count = 0
    var diskFree: Int64 = 0
    var enabled = true
}

/// A local clip that also lives on the server.
struct UploadRecord: Codable, Equatable {
    var id: String
    var link: String
    var server: String
}

/// Where a clip is, from the gallery's point of view.
enum CloudState: Equatable {
    case local
    case queued
    case uploading(Double)
    case uploaded
    case failed(String)
}

private struct UploadFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    /// Client errors (wrong password, storage full …) are not worth retrying.
    var isPermanent: Bool { (400..<500).contains(status) && status != 408 && status != 429 || status == 507 }
}

/// Keeps the clip folder and the user's own server in sync:
/// - every clip is uploaded automatically (new ones right away, older ones in the background),
/// - a clip deleted on the server (web app, iPhone) is moved to the trash on the Mac as well,
/// - a clip deleted on the Mac is removed from the server.
/// Uploads run two at a time, identical files are detected by their SHA-256 and never sent twice.
@MainActor
final class ClipUploader: ObservableObject {
    static let shared = ClipUploader()

    @Published private(set) var progress: [URL: Double] = [:]
    @Published private(set) var storage: ServerStorage?
    @Published private(set) var lastError: String?
    @Published private(set) var records: [String: UploadRecord] = [:]
    @Published private(set) var queued: [URL] = []
    @Published private(set) var failed: [URL: String] = [:]
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false

    private struct Job {
        let url: URL
        let game: String
        let announce: Bool
    }

    private var jobs: [Job] = []
    private var running = 0
    private let maxParallel = 2
    private var started = false
    private var storageFull = false
    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?

    private let recordsKey = "uploadedClips.v2"
    private let legacyLinksKey = "uploadedClipLinks"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3 * 3600
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {
        loadRecords()
    }

    // MARK: Records

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func loadRecords() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([String: UploadRecord].self, from: data) {
            records = decoded
        }
        // Links from version 1.0 ("…/c/{id}") → records.
        if let legacy = d.dictionary(forKey: legacyLinksKey) as? [String: String], !legacy.isEmpty {
            for (path, link) in legacy where records[path] == nil {
                guard let url = URL(string: link) else { continue }
                var base = URLComponents(url: url, resolvingAgainstBaseURL: false)
                base?.path = ""
                records[path] = UploadRecord(id: url.lastPathComponent, link: link,
                                             server: base?.url?.absoluteString ?? "")
            }
            d.removeObject(forKey: legacyLinksKey)
            saveRecords()
        }
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    func record(for url: URL) -> UploadRecord? { records[Self.key(url)] }
    func link(for url: URL) -> String? { record(for: url)?.link }

    func state(for url: URL) -> CloudState {
        if let p = progress[url] { return .uploading(p) }
        if record(for: url) != nil { return .uploaded }
        if queued.contains(url) { return .queued }
        if let error = failed[url] { return .failed(error) }
        return .local
    }

    var isAvailable: Bool {
        let c = RemoteConfig.shared
        return c.uploadEnabled && c.isConfigured && c.httpBaseURL != nil
    }

    private var currentServer: String { RemoteConfig.shared.httpBaseURL?.absoluteString ?? "" }

    /// Clips of the library that are on the current server.
    var uploadedCount: Int {
        let server = currentServer
        return AppState.shared.library.clips.filter { records[Self.key($0.url)]?.server == server }.count
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        // New/changed clips in the folder → upload what is missing.
        AppState.shared.library.$clips
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.backfill() }
            .store(in: &cancellables)

        // Server settings changed → sync with the (new) server.
        RemoteConfig.shared.objectWillChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.sync() } }
            .store(in: &cancellables)

        let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        timer.tolerance = 20
        syncTimer = timer

        Task { await sync() }
    }

    // MARK: Upload

    /// Upload requested by the user (or a freshly saved clip): copies the link when done.
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
        failed[url] = nil
        if let index = jobs.firstIndex(where: { $0.url == url }) {
            // Already waiting in the background queue → move it to the front, now with feedback.
            jobs.remove(at: index)
        } else if progress[url] != nil {
            return
        }
        storageFull = false
        jobs.insert(Job(url: url, game: game, announce: true), at: 0)
        if !queued.contains(url) { queued.append(url) }
        OverlayHUD.shared.show(symbol: "icloud.and.arrow.up", title: "Clip wird hochgeladen …",
                               subtitle: url.lastPathComponent, tint: .systemBlue, sticky: true)
        pump()
    }

    func retryFailed() {
        let urls = Array(failed.keys)
        failed.removeAll()
        storageFull = false
        for url in urls { enqueue(url, game: Self.game(for: url), announce: false) }
    }

    private func enqueue(_ url: URL, game: String, announce: Bool) {
        guard record(for: url) == nil, !queued.contains(url), progress[url] == nil else { return }
        jobs.append(Job(url: url, game: game, announce: announce))
        queued.append(url)
        pump()
    }

    /// Uploads every clip of the library that is not on the server yet.
    func backfill() {
        guard isAvailable, RemoteConfig.shared.autoUpload, !storageFull else { return }
        let cutoff = Date().addingTimeInterval(-15) // still being written
        for clip in AppState.shared.library.clips where clip.date < cutoff && failed[clip.url] == nil {
            enqueue(clip.url, game: clip.game, announce: false)
        }
    }

    private func pump() {
        while running < maxParallel, !storageFull, !jobs.isEmpty {
            let job = jobs.removeFirst()
            guard FileManager.default.fileExists(atPath: job.url.path) else {
                queued.removeAll { $0 == job.url }
                continue
            }
            running += 1
            Task {
                await run(job)
                running -= 1
                pump()
            }
        }
    }

    private func run(_ job: Job) async {
        let url = job.url
        progress[url] = 0
        defer {
            progress[url] = nil
            queued.removeAll { $0 == url }
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let record = try await performUpload(url, game: job.game)
                records[Self.key(url)] = record
                saveRecords()
                failed[url] = nil
                if job.announce {
                    if RemoteConfig.shared.copyLinkAfterUpload {
                        copy(record.link)
                    } else {
                        OverlayHUD.shared.show(symbol: "checkmark.icloud.fill", title: "Clip hochgeladen",
                                               subtitle: record.link, tint: .systemGreen)
                    }
                }
                Task { await refreshStorage() }
                return
            } catch {
                let failure = error as? UploadFailure
                if failure?.status == 507 { storageFull = true }
                let permanent = failure?.isPermanent ?? false
                if !permanent && attempt < 3 && !Task.isCancelled {
                    DiagnosticsLog.write("upload attempt \(attempt) failed: \(error) – retrying")
                    try? await Task.sleep(for: .seconds(Double(attempt * attempt) * 3))
                    continue
                }
                lastError = error.localizedDescription
                failed[url] = error.localizedDescription
                DiagnosticsLog.write("upload failed: \(error)")
                if job.announce || storageFull {
                    OverlayHUD.shared.show(symbol: "exclamationmark.icloud.fill",
                                           title: storageFull ? "Server-Speicher voll" : "Hochladen fehlgeschlagen",
                                           subtitle: error.localizedDescription, tint: .systemOrange)
                }
                return
            }
        }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        OverlayHUD.shared.show(symbol: "link", title: "Link kopiert – einfach in Discord einfügen",
                               subtitle: link, tint: .systemGreen)
    }

    func copyLink(for url: URL) {
        if let link = link(for: url) { copy(link) }
    }

    private func authorized(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(RemoteConfig.shared.serverPassword)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performUpload(_ source: URL, game: String) async throws -> UploadRecord {
        guard let base = RemoteConfig.shared.httpBaseURL else { throw URLError(.badURL) }
        let server = base.absoluteString

        // 1. Fingerprint – if the server already has this exact file we are done instantly.
        let sha = try await Self.sha256(source)
        progress[source] = 0.03
        var check = authorized(base.appendingPathComponent("api/clips/hash/\(sha)"))
        check.timeoutInterval = 20
        if let (data, response) = try? await session.data(for: check),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let id = json["id"] as? String, let share = json["shareUrl"] as? String {
            DiagnosticsLog.write("upload skipped, already on server: \(source.lastPathComponent)")
            return UploadRecord(id: id, link: share, server: server)
        }

        // 2. H.264 so the clip plays everywhere (Discord, Chrome, Windows).
        let prepared = try await Self.prepareForSharing(source) { [weak self] p in
            Task { @MainActor in self?.progress[source] = 0.03 + p * 0.32 }
        }
        defer { if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) } }

        // Preview image in parallel to the upload.
        let thumbTask = Task.detached(priority: .utility) { await Self.thumbnail(prepared.url) }

        // 3. Upload (streamed from disk).
        var request = authorized(base.appendingPathComponent("api/clips"), method: "POST")
        request.timeoutInterval = 300
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        let created = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        request.setValue(enc(source.deletingPathExtension().lastPathComponent), forHTTPHeaderField: "X-Clip-Name")
        request.setValue(enc(game), forHTTPHeaderField: "X-Clip-Game")
        request.setValue(enc(RemoteConfig.shared.computerName), forHTTPHeaderField: "X-Clip-Mac")
        request.setValue(enc(RemoteConfig.shared.macID), forHTTPHeaderField: "X-Clip-Source")
        request.setValue(sha, forHTTPHeaderField: "X-Clip-Hash")
        request.setValue(String(format: "%.3f", created.timeIntervalSince1970), forHTTPHeaderField: "X-Clip-Created")
        request.setValue(String(format: "%.2f", prepared.duration), forHTTPHeaderField: "X-Clip-Duration")
        request.setValue("\(Int(prepared.size.width))", forHTTPHeaderField: "X-Clip-Width")
        request.setValue("\(Int(prepared.size.height))", forHTTPHeaderField: "X-Clip-Height")

        let delegate = UploadProgressDelegate { [weak self] p in
            Task { @MainActor in self?.progress[source] = 0.35 + p * 0.6 }
        }
        let (data, response) = try await session.upload(for: request, fromFile: prepared.url, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 201, let id = json["id"] as? String, let share = json["shareUrl"] as? String else {
            thumbTask.cancel()
            throw UploadFailure(status: status, message: (json["error"] as? String) ?? "Server antwortet mit \(status)")
        }

        // 4. Preview image (share page, Discord embed, web app, iPhone gallery).
        if json["duplicate"] as? Bool != true, let jpeg = await thumbTask.value {
            var thumb = authorized(base.appendingPathComponent("api/clips/\(id)/thumb"), method: "POST")
            thumb.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            _ = try? await session.upload(for: thumb, from: jpeg)
        }
        DiagnosticsLog.write("uploaded \(source.lastPathComponent) → \(share)")
        return UploadRecord(id: id, link: share, server: server)
    }

    // MARK: Sync with the server

    /// Pulls the server's clip list: clips deleted there are moved to the trash here too.
    func sync() async {
        guard isAvailable, !syncing, let base = RemoteConfig.shared.httpBaseURL else { return }
        syncing = true
        defer { syncing = false }
        var request = authorized(base.appendingPathComponent("api/clips"))
        request.timeoutInterval = 25
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clips = json["clips"] as? [[String: Any]] else { return }

        let server = base.absoluteString
        let onServer = Set(clips.compactMap { $0["id"] as? String })
        let deleted = Set(json["deleted"] as? [String] ?? [])
        if let s = json["storage"] as? [String: Any] { applyStorage(s) }

        var trash: [URL] = []
        var changed = false
        for (path, record) in records where record.server == server && !onServer.contains(record.id) {
            records[path] = nil
            changed = true
            // Only clips the server reports as deleted – a reset server never wipes the Mac.
            if deleted.contains(record.id), RemoteConfig.shared.syncDeletions,
               FileManager.default.fileExists(atPath: path) {
                trash.append(URL(fileURLWithPath: path))
            }
        }
        if changed { saveRecords() }
        lastSync = Date()

        if !trash.isEmpty {
            DiagnosticsLog.write("sync: \(trash.count) clip(s) deleted on the server → trash")
            NSWorkspace.shared.recycle(trash) { _, _ in
                Task { @MainActor in AppState.shared.refreshLibrary() }
            }
            OverlayHUD.shared.show(symbol: "trash.fill",
                                   title: trash.count == 1 ? "Clip auch am Mac gelöscht" : "\(trash.count) Clips auch am Mac gelöscht",
                                   subtitle: "Auf dem Server entfernt · liegt im Papierkorb", tint: .systemPink)
        } else {
            backfill()
        }
    }

    /// Deletes clips on the server and the Mac (to the trash).
    func deleteEverywhere(_ clips: [Clip]) {
        let library = AppState.shared.library
        var serverIDs: [(base: URL, id: String)] = []
        for clip in clips {
            jobs.removeAll { $0.url == clip.url }
            queued.removeAll { $0 == clip.url }
            if let record = record(for: clip.url) {
                records[Self.key(clip.url)] = nil
                if let base = URL(string: record.server) { serverIDs.append((base, record.id)) }
            }
            library.moveToTrash(clip)
        }
        saveRecords()
        guard !serverIDs.isEmpty else { return }
        Task {
            for entry in serverIDs {
                let request = authorized(entry.base.appendingPathComponent("api/clips/\(entry.id)"), method: "DELETE")
                _ = try? await session.data(for: request)
            }
            await refreshStorage()
        }
    }

    /// Removes a clip only from the Mac; it stays on the server (and in the web app/iPhone).
    func deleteLocalOnly(_ clip: Clip) {
        jobs.removeAll { $0.url == clip.url }
        queued.removeAll { $0 == clip.url }
        records[Self.key(clip.url)] = nil
        saveRecords()
        AppState.shared.library.moveToTrash(clip)
    }

    func refreshStorage() async {
        guard isAvailable, let base = RemoteConfig.shared.httpBaseURL else { return }
        var request = authorized(base.appendingPathComponent("api/storage"))
        request.timeoutInterval = 20
        guard let (data, _) = try? await session.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        applyStorage(json)
    }

    private func applyStorage(_ json: [String: Any]) {
        func i(_ k: String) -> Int64 { (json[k] as? NSNumber)?.int64Value ?? 0 }
        let s = ServerStorage(used: i("used"), limit: i("limit"), count: Int(i("count")),
                              diskFree: i("diskFree"), enabled: json["enabled"] as? Bool ?? true)
        storage = s
        let wasFull = storageFull
        storageFull = s.limit > 0 && s.used >= s.limit
        if wasFull && !storageFull { pump() }
    }

    var webAppURL: URL? { RemoteConfig.shared.httpBaseURL }

    private static func game(for url: URL) -> String {
        AppState.shared.library.clips.first { $0.url == url }?.game ?? "Clips"
    }

    // MARK: Media helpers

    struct Prepared {
        let url: URL
        let isTemporary: Bool
        let duration: Double
        let size: CGSize
    }

    nonisolated static func sha256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    nonisolated static func prepareForSharing(_ url: URL, progress: @escaping (Double) -> Void) async throws -> Prepared {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw UploadFailure(status: 0, message: "Keine Videospur gefunden")
        }
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        if isH264 {
            progress(1)
            return Prepared(url: url, isTemporary: false, duration: duration, size: natural)
        }

        // Hardware H.264 encoder – capped at 1080p so the file stays small and uploads fast.
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
            throw export.error ?? UploadFailure(status: 0, message: "Umwandlung fehlgeschlagen")
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
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
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
