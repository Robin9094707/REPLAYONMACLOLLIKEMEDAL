import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Gallery (Medal-style)

private enum ClipScope: String, CaseIterable, Identifiable {
    case all = "Alle"
    case cloud = "Auf dem Server"
    case local = "Nur am Mac"
    var id: String { rawValue }
}

private struct ClipSection: Identifiable {
    let title: String
    var clips: [Clip]
    var id: String { title }
}

private struct GameCount: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

private enum ClipSort: String, CaseIterable, Identifiable {
    case newest = "Neueste zuerst"
    case oldest = "Älteste zuerst"
    case largest = "Größte zuerst"
    var id: String { rawValue }
}

struct ClipsView: View {
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var uploader = ClipUploader.shared
    @State private var search = ""
    @State private var gameFilter = "Alle"
    @State private var scope: ClipScope = .all
    @State private var sort: ClipSort = .newest
    @State private var pendingDelete: Clip?

    private var games: [GameCount] {
        var counts: [String: Int] = [:]
        for clip in library.clips { counts[clip.game, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { GameCount(name: $0.key, count: $0.value) }
    }

    private var filtered: [Clip] {
        let result = library.clips.filter { clip in
            guard gameFilter == "Alle" || clip.game == gameFilter else { return false }
            guard search.isEmpty || clip.name.localizedCaseInsensitiveContains(search)
                    || clip.game.localizedCaseInsensitiveContains(search) else { return false }
            switch scope {
            case .all: return true
            case .cloud: return uploader.record(for: clip.url) != nil
            case .local: return uploader.record(for: clip.url) == nil
            }
        }
        switch sort {
        case .newest: return result.sorted { $0.date > $1.date }
        case .oldest: return result.sorted { $0.date < $1.date }
        case .largest: return result.sorted { $0.size > $1.size }
        }
    }

    private var sections: [ClipSection] {
        guard sort != .largest else { return [ClipSection(title: "", clips: filtered)] }
        var result: [ClipSection] = []
        for clip in filtered {
            let title = Self.dayTitle(clip.date)
            if result.last?.title == title {
                result[result.count - 1].clips.append(clip)
            } else {
                result.append(ClipSection(title: title, clips: [clip]))
            }
        }
        return result
    }

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Heute" }
        if cal.isDateInYesterday(date) { return "Gestern" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 99
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        if days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d. MMMM" : "d. MMMM yyyy"
        }
        return f.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 420), spacing: 18)],
                                          alignment: .leading, spacing: 20) {
                                    ForEach(section.clips) { clip in
                                        ClipCard(clip: clip, onDelete: { pendingDelete = clip })
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 14)
                            } header: {
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20).padding(.vertical, 8)
                                        .background(.bar)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .onAppear {
            AppState.shared.refreshLibrary()
            Task { await uploader.sync() }
        }
        .confirmationDialog("Clip überall löschen?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let clip = pendingDelete {
                Button("Überall löschen", role: .destructive) { uploader.deleteEverywhere([clip]) }
                if uploader.record(for: clip.url) != nil {
                    Button("Nur vom Mac entfernen") { uploader.deleteLocalOnly(clip) }
                }
            }
        } message: {
            Text("Der Clip wird am Mac in den Papierkorb gelegt und vom Server, aus der Web-Galerie und vom iPhone entfernt. Geteilte Links funktionieren danach nicht mehr.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Clips").font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("\(filtered.count) · \(filtered.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Suchen", text: $search).textFieldStyle(.plain).frame(width: 170)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Menu {
                    Picker("Sortierung", selection: $sort) {
                        ForEach(ClipSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sortierung")
                Button { AppState.shared.openClipFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Clip-Ordner öffnen")
            }
            HStack(spacing: 10) {
                Picker("", selection: $scope) {
                    ForEach(ClipScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("Alle", count: library.clips.count)
                        ForEach(games) { chip($0.name, count: $0.count) }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private func chip(_ name: String, count: Int) -> some View {
        let on = gameFilter == name
        return Button {
            withAnimation(.snappy(duration: 0.2)) { gameFilter = name }
        } label: {
            HStack(spacing: 5) {
                Text(name).lineLimit(1)
                Text("\(count)").foregroundStyle(on ? Color.white.opacity(0.75) : Color.secondary)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(on ? AnyShapeStyle(LinearGradient.simplex) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient.simplex)
                    .frame(width: 78, height: 78)
                    .shadow(color: Color.purple.opacity(0.45), radius: 22, y: 10)
                Image(systemName: "play.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            }
            Text(library.clips.isEmpty ? "Noch keine Clips" : "Keine Treffer").font(.title2.weight(.bold))
            Text(library.clips.isEmpty
                 ? "Starte ein Spiel und drücke \(settings.clipHotKey.displayString) – die letzten \(settings.replayDuration) Sekunden landen hier und automatisch auf deinem Server."
                 : "Ändere den Filter oder den Suchbegriff.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if uploader.isAvailable {
                let uploading = uploader.progress.count
                let waiting = max(0, uploader.queued.count - uploading)
                Image(systemName: uploading > 0 ? "icloud.and.arrow.up" : "checkmark.icloud.fill")
                    .foregroundStyle(uploading > 0 ? Color.accentColor : Color.green)
                    .symbolEffect(.pulse, isActive: uploading > 0)
                Group {
                    if uploading > 0 {
                        Text("Lädt hoch … \(uploading) aktiv\(waiting > 0 ? " · \(waiting) wartend" : "")")
                    } else {
                        Text("\(uploader.uploadedCount) von \(library.clips.count) Clips auf dem Server")
                    }
                }
                .font(.caption.weight(.medium))
                if !uploader.failed.isEmpty {
                    Button("\(uploader.failed.count) fehlgeschlagen – erneut") { uploader.retryFailed() }
                        .buttonStyle(.link).font(.caption)
                }
                if let s = uploader.storage {
                    Text("· Server \(s.used.formattedBytes) von \(s.limit.formattedBytes)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = uploader.webAppURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Web-Galerie", systemImage: "safari") }
                        .buttonStyle(.borderless).font(.caption.weight(.semibold))
                }
                Button { Task { await uploader.sync() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(uploader.syncing ? 360 : 0))
                        .animation(uploader.syncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: uploader.syncing)
                }
                .buttonStyle(.borderless).help("Mit dem Server abgleichen")
            } else {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                Text("Kein Server eingerichtet – Einstellungen → Remote").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Doppelklick: abspielen & schneiden").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

extension LinearGradient {
    static let simplex = LinearGradient(colors: [Color(red: 0.49, green: 0.36, blue: 1.0), Color(red: 1.0, green: 0.30, blue: 0.55)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Card

struct ClipCard: View {
    let clip: Clip
    var onDelete: () -> Void = {}
    @ObservedObject private var uploader = ClipUploader.shared
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    @State private var hovering = false
    @State private var previewing = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "film").font(.title2).foregroundStyle(.tertiary))
                    }
                }
                if previewing {
                    HoverVideoPreview(url: clip.url).transition(.opacity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                overlayBadges
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? AnyShapeStyle(LinearGradient.simplex) : AnyShapeStyle(Color.primary.opacity(0.08)),
                              lineWidth: hovering ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.12), radius: hovering ? 16 : 5, y: hovering ? 10 : 3)
            .scaleEffect(hovering ? 1.015 : 1)
            .offset(y: hovering ? -2 : 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(clip.game) · \(clip.date.formatted(.relative(presentation: .named))) · \(clip.size.formattedBytes)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { previewing = true } }
                }
            } else {
                previewing = false
            }
        }
        .onTapGesture(count: 2) { ClipEditor.shared.open(clip.url, game: clip.game) }
        .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
        .contextMenu { menu }
        .task(id: clip.url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: clip.url)
            duration = await ThumbnailCache.shared.duration(for: clip.url)
        }
    }

    private var overlayBadges: some View {
        VStack {
            HStack(alignment: .top) {
                cloudBadge
                Spacer()
                if hovering {
                    HStack(spacing: 6) {
                        if uploader.isAvailable {
                            iconButton(uploader.link(for: clip.url) == nil ? "icloud.and.arrow.up" : "link",
                                       help: uploader.link(for: clip.url) == nil ? "Hochladen & Link kopieren" : "Link kopieren") {
                                uploader.upload(clip.url, game: clip.game)
                            }
                        }
                        iconButton("scissors", help: "Abspielen & schneiden") {
                            ClipEditor.shared.open(clip.url, game: clip.game)
                        }
                        iconButton("trash", help: "Überall löschen", action: onDelete)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            Spacer()
            HStack {
                if hovering && !previewing {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                        .padding(7).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if let duration {
                    Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(8)
    }

    @ViewBuilder
    private var cloudBadge: some View {
        switch uploader.state(for: clip.url) {
        case .uploaded:
            badge("checkmark.icloud.fill", tint: .green, help: "Auf dem Server – Link kopieren über Rechtsklick")
        case .uploading(let p):
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, p)).stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: p)
            }
            .frame(width: 16, height: 16)
            .padding(5).background(.black.opacity(0.55), in: Circle())
            .help("Wird hochgeladen … \(Int(p * 100)) %")
        case .queued:
            badge("clock.arrow.circlepath", tint: .white, help: "Wartet auf den Upload")
        case .failed(let message):
            badge("exclamationmark.icloud.fill", tint: .orange, help: "Upload fehlgeschlagen: \(message)")
        case .local:
            if uploader.isAvailable {
                badge("icloud.slash", tint: .white.opacity(0.8), help: "Nur am Mac")
            }
        }
    }

    private func badge(_ symbol: String, tint: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
            .help(help)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Abspielen & schneiden") { ClipEditor.shared.open(clip.url, game: clip.game) }
        if uploader.isAvailable {
            if let link = uploader.link(for: clip.url) {
                Button("Link kopieren") { uploader.copyLink(for: clip.url) }
                if let url = URL(string: link) {
                    Button("Im Browser öffnen") { NSWorkspace.shared.open(url) }
                }
            } else {
                Button("Hochladen & Link kopieren") { uploader.upload(clip.url, game: clip.game) }
            }
        }
        Button("Mit QuickTime öffnen") { NSWorkspace.shared.open(clip.url) }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
        Button("Datei kopieren (für Discord & Co.)") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([clip.url as NSURL])
        }
        Divider()
        Button("Überall löschen …", role: .destructive, action: onDelete)
    }
}

// MARK: - Muted looping preview while hovering

struct HoverVideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.play(url)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.stop()
    }

    final class PreviewView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func play(_ url: URL) {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            playerLayer.player = queue
            queue.play()
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            playerLayer.player = nil
            player = nil
            looper = nil
        }
    }
}
