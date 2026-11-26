import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ClipsView: View {
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var settings: AppSettings
    @State private var search = ""
    @State private var gameFilter = "Alle"

    private var games: [String] {
        ["Alle"] + Array(Set(library.clips.map(\.game))).sorted()
    }

    private var filtered: [Clip] {
        library.clips.filter { clip in
            (gameFilter == "Alle" || clip.game == gameFilter)
                && (search.isEmpty || clip.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Spiel", selection: $gameFilter) {
                    ForEach(games, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 200)
                TextField("Suchen", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    AppState.shared.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Neu laden")
                Button {
                    AppState.shared.openClipFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Clip-Ordner öffnen")
            }
            .padding(12)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("Noch keine Clips").font(.title3.weight(.semibold))
                    Text("Starte ein Spiel und drücke \(settings.clipHotKey.displayString), um die letzten \(settings.replayDuration) Sekunden zu speichern.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { clip in
                            ClipCard(clip: clip)
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            HStack {
                Text("\(filtered.count) Clips · \(filtered.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Doppelklick: abspielen · Ziehen: z. B. direkt in Discord")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { AppState.shared.refreshLibrary() }
    }
}

struct ClipCard: View {
    let clip: Clip
    @ObservedObject private var uploader = ClipUploader.shared
    @EnvironmentObject private var library: ClipLibrary
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipped()

                if let duration {
                    Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
                if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 4) {
                if uploader.link(for: clip.url) != nil {
                    Image(systemName: "link.icloud.fill").font(.caption2).foregroundStyle(Color.accentColor)
                        .help("Auf dem Server – Rechtsklick → Link kopieren")
                }
                if let p = uploader.progress[clip.url] {
                    ProgressView(value: p).controlSize(.mini).frame(width: 40)
                }
                Text(clip.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Text(clip.game).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(clip.size.formattedBytes).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(clip.url) }
        .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Abspielen") { NSWorkspace.shared.open(clip.url) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            if ClipUploader.shared.isAvailable {
                Button(ClipUploader.shared.link(for: clip.url) == nil ? "Hochladen & Link kopieren" : "Link kopieren") {
                    ClipUploader.shared.upload(clip.url, game: clip.game)
                }
            }
            Button("Kopieren (zum Einfügen in Discord & Co.)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([clip.url as NSURL])
            }
            Divider()
            Button("In den Papierkorb legen", role: .destructive) { library.moveToTrash(clip) }
        }
        .task(id: clip.url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: clip.url)
            duration = await ThumbnailCache.shared.duration(for: clip.url)
        }
    }
}
