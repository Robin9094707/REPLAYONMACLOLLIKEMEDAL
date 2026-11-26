import AppKit
import AVKit
import SwiftUI

/// Built-in clip player with Medal-style trimming, sharing and upload.
@MainActor
final class ClipEditor: NSObject, NSWindowDelegate {
    static let shared = ClipEditor()
    private var windows: [URL: NSWindow] = [:]

    func open(_ url: URL, game: String) {
        if let existing = windows[url] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = ClipEditorModel(url: url, game: game)
        let controller = NSHostingController(rootView: ClipEditorView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = url.deletingPathExtension().lastPathComponent
        window.setContentSize(NSSize(width: 960, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[url] = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.player.play()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.first(where: { $0.value === window }) else { return }
        (window.contentViewController as? NSHostingController<ClipEditorView>)?.rootView.model.player.pause()
        windows[entry.key] = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let anyVisible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

@MainActor
final class ClipEditorModel: ObservableObject {
    let url: URL
    let game: String
    let player: AVPlayer
    weak var playerView: AVPlayerView?
    @Published var exporting = false
    @Published var message: String?
    @Published var duration: Double = 0

    init(url: URL, game: String) {
        self.url = url
        self.game = game
        self.player = AVPlayer(url: url)
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration) { self.duration = d.seconds }
        }
    }

    func trim() {
        guard let view = playerView, view.canBeginTrimming else { return }
        view.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor in self?.exportTrimmed() }
        }
    }

    private func exportTrimmed() {
        guard let item = player.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard CMTimeCompare(end, start) > 0 else { return }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let base = url.deletingPathExtension().lastPathComponent
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base) (geschnitten).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(base) (geschnitten \(n)).mp4")
            n += 1
        }
        export.outputURL = target
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: start, end: end)
        export.shouldOptimizeForNetworkUse = true
        exporting = true
        let output = target
        export.exportAsynchronously {
            Task { @MainActor in
                self.exporting = false
                if export.status == .completed {
                    let seconds = Int(CMTimeSubtract(end, start).seconds.rounded())
                    self.message = "✓ Gespeichert: \(output.lastPathComponent) (\(seconds) s)"
                    OverlayHUD.shared.show(symbol: "scissors", title: "Clip zugeschnitten",
                                           subtitle: "\(seconds) Sekunden", tint: .systemGreen)
                    AppState.shared.refreshLibrary()
                    ClipEditor.shared.open(output, game: self.game)
                } else {
                    self.message = "Zuschneiden fehlgeschlagen: \(export.error?.localizedDescription ?? "unbekannt")"
                }
            }
        }
    }
}

struct ClipEditorView: View {
    @ObservedObject var model: ClipEditorModel
    @ObservedObject private var uploader = ClipUploader.shared

    var body: some View {
        VStack(spacing: 0) {
            PlayerContainer(model: model)
                .background(Color.black)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.game.isEmpty ? "Clip" : model.game).font(.headline)
                    Text(model.message ?? model.url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.exporting { ProgressView().controlSize(.small) }
                Button {
                    model.trim()
                } label: {
                    Label("Zuschneiden", systemImage: "scissors")
                }
                .keyboardShortcut("t", modifiers: .command)
                if uploader.isAvailable {
                    if let progress = uploader.progress[model.url] {
                        ProgressView(value: progress).frame(width: 90)
                    } else {
                        Button {
                            uploader.upload(model.url, game: model.game)
                        } label: {
                            Label(uploader.link(for: model.url) == nil ? "Hochladen & Link" : "Link kopieren",
                                  systemImage: "link.icloud")
                        }
                    }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.url])
                } label: {
                    Label("Im Finder", systemImage: "folder")
                }
                ShareLink(item: model.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// AVPlayerView (with the system trimming UI) inside SwiftUI.
struct PlayerContainer: NSViewRepresentable {
    let model: ClipEditorModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = true
        view.allowsPictureInPicturePlayback = true
        model.playerView = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
