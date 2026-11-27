import SwiftUI
import AVKit
import Photos

extension Notification.Name {
    /// The relay reported that clips were added/changed/deleted.
    static let simplexClipsChanged = Notification.Name("simplexClipsChanged")
}

struct ServerClip: Identifiable, Hashable {
    let id: String
    let name: String
    let game: String
    let mac: String
    let duration: Double
    let size: Double
    let created: Date
    let views: Int
    let width: Int
    let height: Int
    let url: URL
    let shareURL: URL
    let thumbURL: URL?
    let server: String

    init?(json: [String: Any], server: String) {
        guard let id = json["id"] as? String,
              let url = (json["url"] as? String).flatMap(URL.init(string:)),
              let share = (json["shareUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? "Clip"
        self.game = json["game"] as? String ?? ""
        self.mac = json["mac"] as? String ?? ""
        self.duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
        self.size = (json["size"] as? NSNumber)?.doubleValue ?? 0
        self.created = Date(timeIntervalSince1970: (json["created"] as? NSNumber)?.doubleValue ?? 0)
        self.views = (json["views"] as? NSNumber)?.intValue ?? 0
        self.width = (json["width"] as? NSNumber)?.intValue ?? 1920
        self.height = (json["height"] as? NSNumber)?.intValue ?? 1080
        self.url = url
        self.shareURL = share
        self.thumbURL = (json["thumbUrl"] as? String).flatMap(URL.init(string:))
        self.server = server
    }

    var title: String { game.isEmpty ? name : game }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}

struct ServerStorage {
    var used = 0.0
    var limit = 1.0
    var count = 0
    var diskFree = 0.0
}

// MARK: - Store

/// Clips on the user's own server(s). Shared, cached on disk and kept live through the relay,
/// so the gallery opens instantly and deletions show up everywhere.
@MainActor
final class ClipsStore: ObservableObject {
    static let shared = ClipsStore()

    @Published var clips: [ServerClip] = []
    @Published var storage: [String: ServerStorage] = [:]
    @Published var loading = false
    @Published var error: String?

    private var macs: [PairedMac] = []
    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("clips-cache.json")
    }

    private init() {
        // Thumbnails and share pages are cacheable – keep them on disk between launches.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        if let data = try? Data(contentsOf: Self.cacheURL),
           let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            clips = entries.compactMap { entry in
                guard let server = entry["server"] as? String, let clip = entry["clip"] as? [String: Any] else { return nil }
                return ServerClip(json: clip, server: server)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .simplexClipsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    /// Server address → password (taken from the paired Macs).
    func servers(from macs: [PairedMac]) -> [(server: String, password: String)] {
        var seen = Set<String>()
        var result: [(server: String, password: String)] = []
        for mac in macs where !seen.contains(mac.serverKey) {
            guard let pw = Keychain.get("server-\(mac.id)").flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            seen.insert(mac.serverKey)
            result.append((server: mac.server, password: pw))
        }
        return result
    }

    nonisolated static func baseURL(_ server: String) -> URL? {
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw) else { return nil }
        comps.scheme = (comps.scheme?.lowercased() == "http" || comps.scheme?.lowercased() == "ws") ? "http" : "https"
        comps.path = ""
        return comps.url
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await load(macs: macs)
        }
    }

    func load(macs: [PairedMac]) async {
        self.macs = macs
        loading = true
        defer { loading = false }
        let servers = servers(from: macs)
        typealias Fetch = (server: String, clips: [[String: Any]], storage: ServerStorage?, error: String?)
        let results: [Fetch] = await withTaskGroup(of: Fetch.self) { group in
            for (server, password) in servers {
                group.addTask {
                    guard let base = ClipsStore.baseURL(server) else { return (server, [], nil, nil) }
                    var request = URLRequest(url: base.appendingPathComponent("api/clips"))
                    request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 20
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard code == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                            return (server, [], nil, code == 404 ? "Server unterstützt noch keine Clips – relay.py aktualisieren" : "Server antwortet mit \(code)")
                        }
                        var storage: ServerStorage?
                        if let s = json["storage"] as? [String: Any] {
                            func d(_ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? 0 }
                            storage = ServerStorage(used: d("used"), limit: max(1, d("limit")), count: Int(d("count")), diskFree: d("diskFree"))
                        }
                        return (server, json["clips"] as? [[String: Any]] ?? [], storage, nil)
                    } catch {
                        return (server, [], nil, error.localizedDescription)
                    }
                }
            }
            var all: [Fetch] = []
            for await r in group { all.append(r) }
            return all
        }

        var all: [ServerClip] = []
        var cache: [[String: Any]] = []
        var firstError: String?
        var anySuccess = false
        for r in results {
            if let e = r.error { firstError = firstError ?? e; continue }
            anySuccess = true
            if let s = r.storage { storage[r.server] = s }
            for json in r.clips {
                if let clip = ServerClip(json: json, server: r.server) {
                    all.append(clip)
                    cache.append(["server": r.server, "clip": json])
                }
            }
        }
        error = firstError
        guard anySuccess || servers.isEmpty else { return } // offline: keep the cached list
        let sorted = all.sorted { $0.created > $1.created }
        if sorted.map(\.id) != clips.map(\.id) || sorted != clips {
            withAnimation(.snappy) { clips = sorted }
        }
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    /// Deletes on the server – the relay then tells the Mac (moves it to the trash) and the web app.
    func delete(_ targets: [ServerClip], macs: [PairedMac]) async {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        withAnimation(.snappy) { clips.removeAll { ids.contains($0.id) } }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let credentials = servers(from: macs)
        for (server, group) in Dictionary(grouping: targets, by: \.server) {
            guard let password = credentials.first(where: { $0.server == server })?.password,
                  let base = Self.baseURL(server) else { continue }
            var request = URLRequest(url: base.appendingPathComponent("api/clips/delete"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": group.map(\.id)])
            let response = try? await URLSession.shared.data(for: request)
            if (response?.1 as? HTTPURLResponse)?.statusCode == 404 {
                // Server 1.1 has no bulk delete – one by one.
                for clip in group {
                    var single = URLRequest(url: base.appendingPathComponent("api/clips/\(clip.id)"))
                    single.httpMethod = "DELETE"
                    single.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
                    _ = try? await URLSession.shared.data(for: single)
                }
            }
        }
        await load(macs: macs)
    }
}

// MARK: - Shared actions

@MainActor
enum ClipActions {
    /// Downloads the clip and stores it in the photo library.
    static func saveToPhotos(_ clip: ServerClip) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "Kein Zugriff auf Fotos" }
        do {
            let (temp, _) = try await URLSession.shared.download(from: clip.url)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(clip.id).mp4")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
            try? FileManager.default.removeItem(at: file)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return "In Fotos gesichert"
        } catch {
            return "Sichern fehlgeschlagen"
        }
    }

    static func copyLink(_ clip: ServerClip) {
        UIPasteboard.general.url = clip.shareURL
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private func dayTitle(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Heute" }
    if cal.isDateInYesterday(date) { return "Gestern" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 99
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = days < 7 ? "EEEE" : (cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d. MMMM" : "d. MMMM yyyy")
    return f.string(from: date)
}

private struct DaySection: Identifiable {
    let title: String
    var clips: [ServerClip]
    var id: String { title }
}

// MARK: - Gallery (like the Photos app)

struct ClipsGalleryView: View {
    @EnvironmentObject private var macStore: MacStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ClipsStore.shared
    @State private var filter = "Alle"
    @State private var viewerStart: ServerClip?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @AppStorage("clipsZoom") private var zoom = 1
    @State private var toast: String?

    /// Target tile width per zoom level (pinch to change).
    private let tileWidths: [CGFloat] = [380, 175, 118, 86]
    private let spacing: CGFloat = 3

    private var games: [String] {
        var counts: [String: Int] = [:]
        for clip in store.clips { counts[clip.title, default: 0] += 1 }
        return ["Alle"] + counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private var visible: [ServerClip] { store.clips.filter { filter == "Alle" || $0.title == filter } }

    private var sections: [DaySection] {
        var result: [DaySection] = []
        for clip in visible {
            let title = dayTitle(clip.created)
            if result.last?.title == title { result[result.count - 1].clips.append(clip) }
            else { result.append(DaySection(title: title, clips: [clip])) }
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 2 * horizontalPadding(geo.size.width)
            let target = tileWidths[min(max(zoom, 0), tileWidths.count - 1)]
            let perRow = max(1, Int((width + spacing) / (target + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: perRow)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if games.count > 2 { chips }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                    if visible.isEmpty && !store.loading {
                        emptyState
                    }
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: spacing) {
                                    ForEach(section.clips) { clip in
                                        tile(clip, perRow: perRow)
                                    }
                                }
                                .padding(.bottom, 14)
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .glassCapsule(interactive: false)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding(geo.size.width))
                .padding(.bottom, selecting ? 110 : 40)
            }
            .scrollIndicators(.hidden)
            .background { AuroraBackground() }
            .refreshable { await store.load(macs: macStore.macs) }
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        if value.magnification > 1.15 { zoom = max(0, zoom - 1) }
                        else if value.magnification < 0.87 { zoom = min(tileWidths.count - 1, zoom + 1) }
                    }
                }
            )
            .overlay(alignment: .bottom) { if selecting { selectionBar } }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassCapsule(interactive: false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
        }
        .foregroundStyle(.white)
        .task { await store.load(macs: macStore.macs) }
        .fullScreenCover(item: $viewerStart) { start in
            ClipViewer(clips: visible, startID: start.id)
                .environmentObject(macStore)
        }
        .confirmationDialog("\(selection.count) Clips löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Überall löschen", role: .destructive) {
                let targets = store.clips.filter { selection.contains($0.id) }
                selection.removeAll()
                selecting = false
                Task { await store.delete(targets, macs: macStore.macs) }
            }
        } message: {
            Text("Die Clips werden vom Server, aus der Web-Galerie und vom Mac entfernt. Links funktionieren danach nicht mehr.")
        }
    }

    private func horizontalPadding(_ width: CGFloat) -> CGFloat { width > 700 ? 24 : 10 }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clips").font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if store.loading { ProgressView().tint(.white) }
            Button {
                withAnimation(.snappy) {
                    selecting.toggle()
                    selection.removeAll()
                }
            } label: {
                Text(selecting ? "Fertig" : "Auswählen").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 40)
            }
            .glassCapsule(tint: selecting ? .purple : nil)
            if !selecting {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                }
                .glass(in: Circle(), interactive: true)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 6)
    }

    private var subtitle: String {
        let used = store.storage.values.reduce(0) { $0 + $1.used }
        let limit = store.storage.values.reduce(0) { $0 + $1.limit }
        let count = "\(store.clips.count) Clips"
        return limit > 1 ? "\(count) · \(used.bytesText) von \(limit.bytesText)" : count
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(games, id: \.self) { game in
                    Button { withAnimation(.snappy) { filter = game } } label: {
                        Text(game).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .glassCapsule(tint: filter == game ? .purple : nil)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                Image(systemName: "play.fill").font(.system(size: 30, weight: .bold))
            }
            Text("Noch keine Clips auf dem Server").font(.headline)
            Text("Jeder Clip, den du am Mac speicherst, landet automatisch hier.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, 6)
    }

    private func tile(_ clip: ServerClip, perRow: Int) -> some View {
        let selected = selection.contains(clip.id)
        let large = perRow <= 2
        return Button {
            if selecting {
                if selected { selection.remove(clip.id) } else { selection.insert(clip.id) }
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                viewerStart = clip
            }
        } label: {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { CachedImage(url: clip.thumbURL) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: large ? 56 : 30)
                }
                .overlay(alignment: .bottomLeading) {
                    if large {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(clip.name).font(.system(size: perRow == 1 ? 16 : 12, weight: .bold)).lineLimit(1)
                            Text(clip.game.isEmpty ? clip.created.relativeGerman : "\(clip.game) · \(clip.created.relativeGerman)")
                                .font(.system(size: perRow == 1 ? 13 : 10, weight: .medium)).opacity(0.75).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.bottom, 6)
                        .padding(.trailing, 44)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(clip.durationText)
                        .font(.system(size: large ? 11 : 9, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.purple : Color.black.opacity(0.3))
                            .padding(6)
                    }
                }
                .overlay {
                    if selected { Rectangle().fill(.white.opacity(0.18)) }
                }
                .clipShape(RoundedRectangle(cornerRadius: perRow >= 3 ? 4 : 10, style: .continuous))
                .scaleEffect(selected ? 0.94 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ShareLink(item: clip.shareURL, subject: Text(clip.title)) { Label("Teilen", systemImage: "square.and.arrow.up") }
            Button { ClipActions.copyLink(clip); show("Link kopiert") } label: { Label("Link kopieren", systemImage: "link") }
            Button {
                Task { show(await ClipActions.saveToPhotos(clip)) }
            } label: { Label("In Fotos sichern", systemImage: "square.and.arrow.down") }
            Divider()
            Button(role: .destructive) {
                Task { await store.delete([clip], macs: macStore.macs) }
            } label: { Label("Überall löschen", systemImage: "trash") }
        } preview: {
            ZStack(alignment: .bottomLeading) {
                CachedImage(url: clip.thumbURL).frame(width: 340, height: 191).clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name).font(.headline)
                    Text("\(clip.title) · \(clip.durationText) · \(clip.size.bytesText)").font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
            .foregroundStyle(.white)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                selection = Set(visible.map(\.id))
            } label: {
                Text("Alle").font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 46)
            }
            .glassCapsule()
            Text(selection.isEmpty ? "Clips auswählen" : "\(selection.count) ausgewählt")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            Button(role: .destructive) { confirmDelete = true } label: {
                Image(systemName: "trash").font(.system(size: 17, weight: .semibold)).frame(width: 46, height: 46)
            }
            .glass(in: Circle(), tint: .red, interactive: true)
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.5 : 1)
        }
        .padding(10)
        .glassCapsule(interactive: false)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func show(_ text: String) {
        withAnimation(.spring) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.spring) { if toast == text { toast = nil } }
        }
    }
}

// MARK: - Full-screen viewer

/// Owns one AVPlayer per page; only the visible page plays.
@MainActor
final class ViewerPlayer: ObservableObject {
    let url: URL
    @Published private(set) var player: AVQueuePlayer?
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var buffering = true
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    var scrubbing = false

    init(url: URL, duration: Double) {
        self.url = url
        self.duration = duration
    }

    func activate(muted: Bool) {
        if player == nil {
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 3
            let queue = AVQueuePlayer()
            queue.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: queue, templateItem: item)
            timeObserver = queue.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, !self.scrubbing else { return }
                    self.current = time.seconds.isFinite ? time.seconds : 0
                    if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                }
            }
            statusObservation = queue.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
                let status = p.timeControlStatus
                Task { @MainActor in self?.buffering = status == .waitingToPlayAtSpecifiedRate }
            }
            player = queue
        }
        player?.isMuted = muted
        player?.play()
        isPlaying = true
    }

    func deactivate() {
        player?.pause()
        isPlaying = false
    }

    func teardown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(_ t: Double, precise: Bool) {
        current = t
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.15, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func setMuted(_ muted: Bool) { player?.isMuted = muted }
}

/// Keeps track of the page that is currently on screen.
@MainActor
final class ViewerController: ObservableObject {
    @Published var active: ViewerPlayer?
    @Published var muted = false
}

struct ClipViewer: View {
    @EnvironmentObject private var macStore: MacStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ClipsStore.shared
    @StateObject private var controller = ViewerController()
    @State private var clips: [ServerClip]
    @State private var currentID: String
    @State private var controlsVisible = true
    @State private var dragOffset: CGSize = .zero
    @State private var zoomed = false
    @State private var confirmDelete = false
    @State private var toast: String?
    @State private var hideTask: Task<Void, Never>?

    init(clips: [ServerClip], startID: String) {
        _clips = State(initialValue: clips)
        _currentID = State(initialValue: startID)
    }

    private var current: ServerClip? { clips.first { $0.id == currentID } }
    private var dismissProgress: Double { min(1.0, Double(abs(dragOffset.height)) / 300.0) }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissProgress * 0.8).ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(clips) { clip in
                    ViewerPage(clip: clip, active: clip.id == currentID, zoomed: zoomed, controller: controller)
                        .tag(clip.id)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset.height)
            .scaleEffect(1 - dismissProgress * 0.25)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { zoomed.toggle() }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                scheduleHide()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
                        dragOffset = CGSize(width: 0, height: value.translation.height)
                    }
                    .onEnded { value in
                        if abs(dragOffset.height) > 130 || abs(value.predictedEndTranslation.height) > 420 {
                            close()
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = .zero }
                        }
                    }
            )

            if controlsVisible && dragOffset == .zero {
                controls.transition(.opacity)
            }

            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCapsule(interactive: false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .background(ClearBackground())
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            scheduleHide()
        }
        .onDisappear {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        .onChange(of: currentID) { _, _ in
            zoomed = false
            UISelectionFeedbackGenerator().selectionChanged()
            scheduleHide()
        }
        .onReceive(store.$clips) { latest in
            // Deleted elsewhere (Mac, web app) → drop it here too.
            let ids = Set(latest.map(\.id))
            let remaining = clips.filter { ids.contains($0.id) }
            guard remaining.count != clips.count else { return }
            if remaining.isEmpty { dismiss(); return }
            if !ids.contains(currentID), let index = clips.firstIndex(where: { $0.id == currentID }) {
                let next = remaining[min(index, remaining.count - 1)]
                currentID = next.id
            }
            clips = remaining
        }
        .confirmationDialog("Clip überall löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Überall löschen", role: .destructive) { deleteCurrent() }
        } message: {
            Text("Er wird vom Server, aus der Web-Galerie und vom Mac entfernt. Der Link funktioniert danach nicht mehr.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { close() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).frame(width: 42, height: 42)
                }
                .glass(in: Circle(), interactive: true)
                if let clip = current {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(clip.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                        Text("\(clip.game.isEmpty ? "Clip" : clip.game) · \(clip.created.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 6)
                }
                Spacer()
                if let index = clips.firstIndex(where: { $0.id == currentID }), clips.count > 1 {
                    Text("\(index + 1)/\(clips.count)").font(.caption.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 10).frame(height: 30)
                        .glassCapsule(interactive: false)
                }
                Button {
                    controller.muted.toggle()
                    controller.active?.setMuted(controller.muted)
                } label: {
                    Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 42, height: 42)
                }
                .glass(in: Circle(), interactive: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            Spacer()

            if let active = controller.active {
                PlaybackBar(player: active) { scheduleHide() }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if let clip = current {
                HStack(spacing: 10) {
                    ShareLink(item: clip.shareURL, subject: Text(clip.title), message: Text(clip.name)) {
                        Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).frame(height: 48)
                    }
                    .glassCapsule(tint: .purple)
                    actionButton("link") { ClipActions.copyLink(clip); flash("Link kopiert") }
                    actionButton("square.and.arrow.down") {
                        flash("Wird gesichert …")
                        Task { flash(await ClipActions.saveToPhotos(clip)) }
                    }
                    actionButton(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { zoomed.toggle() }
                    }
                    actionButton("trash", tint: .red) { confirmDelete = true }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: 620)
            }
        }
    }

    private func actionButton(_ symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 48, height: 48)
        }
        .glass(in: Circle(), tint: tint, interactive: true)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, controller.active?.isPlaying == true, !confirmDelete else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func flash(_ text: String) {
        withAnimation(.spring) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring) { if toast == text { toast = nil } }
        }
    }

    private func close() {
        controller.active?.deactivate()
        dismiss()
    }

    private func deleteCurrent() {
        guard let clip = current, let index = clips.firstIndex(of: clip) else { return }
        var remaining = clips
        remaining.remove(at: index)
        if remaining.isEmpty {
            dismiss()
        } else {
            withAnimation(.snappy) {
                currentID = remaining[min(index, remaining.count - 1)].id
                clips = remaining
            }
        }
        Task { await store.delete([clip], macs: macStore.macs) }
    }
}

/// One page: poster image, then the video as soon as it is the visible page.
private struct ViewerPage: View {
    let clip: ServerClip
    let active: Bool
    let zoomed: Bool
    let controller: ViewerController
    @StateObject private var model: ViewerPlayer

    init(clip: ServerClip, active: Bool, zoomed: Bool, controller: ViewerController) {
        self.clip = clip
        self.active = active
        self.zoomed = zoomed
        self.controller = controller
        _model = StateObject(wrappedValue: ViewerPlayer(url: clip.url, duration: clip.duration))
    }

    var body: some View {
        ZStack {
            Color.black
            CachedImage(url: clip.thumbURL)
                .aspectRatio(CGFloat(max(clip.width, 1)) / CGFloat(max(clip.height, 1)), contentMode: zoomed ? .fill : .fit)
            PlayerLayerView(player: model.player, fill: zoomed)
            if active && model.buffering {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .clipped()
        .onAppear { if active { start() } }
        .onDisappear { model.teardown() }
        .onChange(of: active) { _, isActive in
            if isActive { start() } else { model.deactivate() }
        }
    }

    private func start() {
        model.activate(muted: controller.muted)
        controller.active = model
    }
}

/// Play/pause + scrubber for the visible clip.
private struct PlaybackBar: View {
    @ObservedObject var player: ViewerPlayer
    var onInteraction: () -> Void
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
                onInteraction()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold)).frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .glass(in: Circle(), interactive: true)

            Text(time(dragValue ?? player.current)).font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                let d = max(player.duration, 0.01)
                let value = dragValue ?? player.current
                let x = CGFloat(min(max(value / d, 0), 1)) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: dragValue == nil ? 5 : 9)
                    Capsule().fill(.white).frame(width: max(5, x), height: dragValue == nil ? 5 : 9)
                    Circle().fill(.white).frame(width: dragValue == nil ? 14 : 22, height: dragValue == nil ? 14 : 22)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .offset(x: x - (dragValue == nil ? 7 : 11))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = Double(min(max(v.location.x / geo.size.width, 0), 1)) * d
                        if dragValue == nil { UISelectionFeedbackGenerator().selectionChanged() }
                        dragValue = t
                        player.scrubbing = true
                        player.seek(t, precise: false)
                        onInteraction()
                    }
                    .onEnded { v in
                        let t = Double(min(max(v.location.x / geo.size.width, 0), 1)) * d
                        player.seek(t, precise: true)
                        player.scrubbing = false
                        withAnimation(.spring(response: 0.25)) { dragValue = nil }
                    })
                .animation(.spring(response: 0.25), value: dragValue == nil)
            }
            .frame(height: 44)

            Text(time(player.duration)).font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassCapsule(interactive: false)
        .frame(maxWidth: 760)
    }

    private func time(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayerLayer without any system chrome (our own controls sit on top).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    let fill: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            view.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Lets the drag-to-dismiss reveal the gallery behind the full-screen cover.
private struct ClearBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { view.superview?.superview?.backgroundColor = .clear }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
