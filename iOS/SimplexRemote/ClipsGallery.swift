import SwiftUI
import AVKit

struct ServerClip: Identifiable, Hashable {
    let id: String
    let name: String
    let game: String
    let mac: String
    let duration: Double
    let size: Double
    let created: Date
    let views: Int
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

/// Clips that were uploaded to the user's own server(s).
@MainActor
final class ClipsStore: ObservableObject {
    @Published var clips: [ServerClip] = []
    @Published var storage: [String: ServerStorage] = [:]
    @Published var loading = false
    @Published var error: String?

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

    static func baseURL(_ server: String) -> URL? {
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw) else { return nil }
        comps.scheme = (comps.scheme?.lowercased() == "http" || comps.scheme?.lowercased() == "ws") ? "http" : "https"
        comps.path = ""
        return comps.url
    }

    func load(macs: [PairedMac]) async {
        loading = true
        error = nil
        var all: [ServerClip] = []
        for (server, password) in servers(from: macs) {
            guard let base = Self.baseURL(server) else { continue }
            var request = URLRequest(url: base.appendingPathComponent("api/clips"))
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    error = code == 404 ? "Server unterstützt noch keine Clips – relay.py aktualisieren" : "Server antwortet mit \(code)"
                    continue
                }
                all += (json["clips"] as? [[String: Any]] ?? []).compactMap { ServerClip(json: $0, server: server) }
                if let s = json["storage"] as? [String: Any] {
                    func d(_ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? 0 }
                    storage[server] = ServerStorage(used: d("used"), limit: max(1, d("limit")),
                                                    count: Int(d("count")), diskFree: d("diskFree"))
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        clips = all.sorted { $0.created > $1.created }
        loading = false
    }

    func delete(_ clip: ServerClip, macs: [PairedMac]) async {
        guard let password = servers(from: macs).first(where: { $0.server == clip.server })?.password,
              let base = Self.baseURL(clip.server) else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/clips/\(clip.id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        if let (_, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            withAnimation(.spring) { clips.removeAll { $0.id == clip.id } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load(macs: macs)
        }
    }
}

// MARK: - Gallery

struct ClipsGalleryView: View {
    @EnvironmentObject private var macStore: MacStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ClipsStore()
    @State private var filter = "Alle"
    @State private var selected: ServerClip?

    private var games: [String] { ["Alle"] + Array(Set(store.clips.map(\.title))).sorted() }
    private var visible: [ServerClip] { store.clips.filter { filter == "Alle" || $0.title == filter } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    storageCard
                    if games.count > 2 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(games, id: \.self) { game in
                                    Button(game) { withAnimation(.spring) { filter = game } }
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .glassCapsule(tint: filter == game ? .purple : nil)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if visible.isEmpty && !store.loading {
                        VStack(spacing: 10) {
                            Image(systemName: "film.stack").font(.system(size: 48, weight: .light))
                            Text("Noch keine Clips auf dem Server").font(.headline)
                            Text("Am Mac: Einstellungen → Remote → „Clips teilen“ – oder in der Clip-Galerie Rechtsklick → „Hochladen & Link kopieren“.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity)
                        .glassCard()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(visible) { clip in
                            Button { selected = clip } label: { ClipTile(clip: clip) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
                .readableWidth(900)
            }
            .scrollIndicators(.hidden)
            .background { AuroraBackground() }
            .refreshable { await store.load(macs: macStore.macs) }
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if store.loading { ProgressView() }
                }
            }
            .task { await store.load(macs: macStore.macs) }
            .sheet(item: $selected) { clip in
                ClipPlayerView(clip: clip) {
                    Task { await store.delete(clip, macs: macStore.macs) }
                }
            }
        }
    }

    private var storageCard: some View {
        let used = store.storage.values.reduce(0) { $0 + $1.used }
        let limit = store.storage.values.reduce(0) { $0 + $1.limit }
        let free = store.storage.values.reduce(0) { $0 + $1.diskFree }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.purple)
                Text("Server-Speicher").font(.headline)
                Spacer()
                Text("\(store.clips.count) Clips").font(.subheadline).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(1, used / max(limit, 1))))
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(used.bytesText) von \(limit.bytesText) belegt").font(.caption)
                Spacer()
                Text("Festplatte frei: \(free.bytesText)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassCard()
    }
}

struct ClipTile: View {
    let clip: ServerClip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: clip.thumbURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.white.opacity(0.06))
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipped()
                Text(clip.durationText)
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(clip.created.relativeGerman) · \(clip.size.bytesText)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassCard(cornerRadius: 22)
    }
}

// MARK: - Player

struct ClipPlayerView: View {
    let clip: ServerClip
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(clip.title).font(.title3.bold())
                        Text("\(clip.created.formatted(date: .long, time: .shortened)) · \(clip.durationText) · \(clip.size.bytesText)")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !clip.mac.isEmpty {
                            Label(clip.mac, systemImage: "desktopcomputer").font(.footnote).foregroundStyle(.secondary)
                        }
                        Label("\(clip.views) Aufrufe", systemImage: "eye").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        ShareLink(item: clip.shareURL, subject: Text(clip.title), message: Text(clip.title)) {
                            Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .glassCapsule(tint: .purple)
                        Button {
                            UIPasteboard.general.url = clip.shareURL
                            copied = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label(copied ? "Kopiert" : "Link", systemImage: copied ? "checkmark" : "link")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .glassCapsule()
                    }
                    .foregroundStyle(.white)
                    .font(.subheadline.weight(.semibold))

                    Text("Der Link läuft in jedem Browser ohne Anmeldung – Discord, WhatsApp & Co. zeigen ihn direkt als Video an.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Vom Server löschen", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .glassCapsule(tint: .red)
                    .foregroundStyle(.white)
                }
                .padding(18)
                .readableWidth(760)
            }
            .background { AuroraBackground() }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear {
                let p = AVPlayer(url: clip.url)
                p.automaticallyWaitsToMinimizeStalling = false
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
            .confirmationDialog("Clip vom Server löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("Der Link funktioniert danach nicht mehr.")
            }
        }
    }
}
