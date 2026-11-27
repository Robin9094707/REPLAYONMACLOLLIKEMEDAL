import AppKit
import AVKit
import SwiftUI

/// Built-in clip player and editor (Medal-style): filmstrip timeline with trim handles,
/// looping preview of the selection, one-click "cut & share".
@MainActor
final class ClipEditor: NSObject, NSWindowDelegate {
    static let shared = ClipEditor()
    private var windows: [URL: NSWindow] = [:]
    private var models: [URL: ClipEditorModel] = [:]
    private var keyMonitor: Any?

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
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.055, alpha: 1)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = url.deletingPathExtension().lastPathComponent
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[url] = window
        models[url] = model
        installKeyMonitor()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.play()
    }

    /// Space, I/O, ←/→, F, J/K/L – only while an editor window is key and no text field is edited.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  let entry = self.windows.first(where: { $0.value === window }),
                  let model = self.models[entry.key] else { return event }
            if window.firstResponder is NSTextView { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ", "k": model.togglePlay()
            case "i": model.setIn()
            case "o": model.setOut()
            case "f": window.toggleFullScreen(nil)
            case "l": model.step(seconds: 5)
            case "j": model.step(seconds: -5)
            default:
                switch Int(event.keyCode) {
                case 123: model.step(seconds: event.modifierFlags.contains(.shift) ? -5 : -1 / 30)
                case 124: model.step(seconds: event.modifierFlags.contains(.shift) ? 5 : 1 / 30)
                default: return event
                }
            }
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.first(where: { $0.value === window }) else { return }
        models[entry.key]?.teardown()
        models[entry.key] = nil
        windows[entry.key] = nil
        if windows.isEmpty, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let anyVisible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func close(_ url: URL) {
        windows[url]?.close()
    }
}

// MARK: - Model

@MainActor
final class ClipEditorModel: ObservableObject {
    let url: URL
    let game: String
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var current: Double = 0
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1
    @Published var muted = false
    @Published var frames: [NSImage] = []
    @Published var exporting = false
    @Published var exportProgress: Double = 0
    @Published var message: String?
    @Published var size: CGSize = .zero

    private var timeObserver: Any?
    private var scrubbing = false

    init(url: URL, game: String) {
        self.url = url
        self.game = game
        self.player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        Task { await load() }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            duration = max(d.seconds, 0)
            outPoint = duration
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            size = natural
        }
        // Filmstrip for the timeline.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 14
        var images: [NSImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                images.append(NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height)))
                if images.count % 4 == 0 || i == count - 1 { frames = images }
            }
        }
        frames = images
    }

    private func tick(_ t: Double) {
        guard t.isFinite, !scrubbing else { return }
        current = t
        // Loop inside the selection like Medal.
        if isPlaying && duration > 0 && t >= outPoint - 0.03 {
            seek(inPoint)
            player.rate = rate
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    func play() {
        if current >= outPoint - 0.05 || current < inPoint - 0.05 { seek(inPoint) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(_ t: Double) {
        let clamped = min(max(t, 0), duration)
        current = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(_ t: Double, ended: Bool) {
        scrubbing = !ended
        seek(t)
    }

    func step(seconds: Double) {
        if isPlaying { pause() }
        seek(current + seconds)
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
    }

    func toggleMute() {
        muted.toggle()
        player.isMuted = muted
    }

    func setIn() { inPoint = min(current, max(0, outPoint - 0.5)) }
    func setOut() { outPoint = max(current, min(duration, inPoint + 0.5)) }
    func resetSelection() { inPoint = 0; outPoint = duration }

    var hasSelection: Bool { duration > 0 && (inPoint > 0.05 || outPoint < duration - 0.05) }
    var selectionLength: Double { max(0, outPoint - inPoint) }

    // MARK: Export

    /// Saves the selection as a new clip next to the original; optionally uploads it right away.
    func exportSelection(thenUpload: Bool) {
        guard !exporting else { return }
        guard hasSelection else {
            if thenUpload { ClipUploader.shared.upload(url, game: game) }
            return
        }
        let start = CMTime(seconds: inPoint, preferredTimescale: 600)
        let end = CMTime(seconds: outPoint, preferredTimescale: 600)
        let asset = AVURLAsset(url: url)
        // Frame-exact cut (re-encode, hardware). Starting at 0 a fast passthrough copy is exact as well.
        let preset = inPoint < 0.05 ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return }
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
        exportProgress = 0
        message = nil
        pause()
        let output = target
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.exportProgress = Double(export.progress)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        export.exportAsynchronously {
            Task { @MainActor in
                poll.cancel()
                self.exporting = false
                if export.status == .completed {
                    let seconds = Int(CMTimeSubtract(end, start).seconds.rounded())
                    self.message = "Gespeichert: \(output.lastPathComponent) (\(seconds) s)"
                    OverlayHUD.shared.show(symbol: "scissors", title: "Clip geschnitten",
                                           subtitle: "\(seconds) Sekunden", tint: .systemGreen)
                    AppState.shared.refreshLibrary()
                    if thenUpload {
                        ClipUploader.shared.upload(output, game: self.game)
                    }
                    ClipEditor.shared.open(output, game: self.game)
                } else {
                    self.message = "Schneiden fehlgeschlagen: \(export.error?.localizedDescription ?? "unbekannt")"
                }
            }
        }
    }
}

// MARK: - View

struct ClipEditorView: View {
    @ObservedObject var model: ClipEditorModel
    @ObservedObject private var uploader = ClipUploader.shared
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                Color.black
                PlayerSurface(player: model.player)
                    .onTapGesture { model.togglePlay() }
                if !model.isPlaying && !model.exporting {
                    Button { model.play() } label: {
                        Image(systemName: "play.fill").font(.system(size: 30, weight: .bold))
                            .frame(width: 74, height: 74)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if model.exporting {
                    VStack(spacing: 12) {
                        ProgressView(value: model.exportProgress).frame(width: 220).tint(.white)
                        Text("Wird geschnitten … \(Int(model.exportProgress * 100)) %").font(.callout.weight(.semibold))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 18)
            .animation(.spring(response: 0.3), value: model.isPlaying)

            VStack(spacing: 14) {
                transport
                TrimTimeline(model: model)
                actions
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 18)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.035, green: 0.035, blue: 0.055))
        .frame(minWidth: 720, minHeight: 520)
        .confirmationDialog("Clip überall löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Überall löschen", role: .destructive) {
                if let clip = AppState.shared.library.clips.first(where: { $0.url == model.url }) {
                    uploader.deleteEverywhere([clip])
                } else {
                    NSWorkspace.shared.recycle([model.url])
                }
                ClipEditor.shared.close(model.url)
            }
        } message: {
            Text("Der Clip wird am Mac in den Papierkorb gelegt und vom Server, aus der Web-Galerie und vom iPhone entfernt.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.game.isEmpty ? "CLIP" : model.game.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(LinearGradient.simplex)
                Text(model.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            cloudPill
        }
        .padding(.leading, 84).padding(.trailing, 18)
        .frame(height: 52)
    }

    @ViewBuilder
    private var cloudPill: some View {
        switch uploader.state(for: model.url) {
        case .uploaded:
            pill("checkmark.icloud.fill", "Auf dem Server", tint: .green)
        case .uploading(let p):
            pill("icloud.and.arrow.up", "Lädt hoch … \(Int(p * 100)) %", tint: .accentColor)
        case .queued:
            pill("clock", "Wartet auf Upload", tint: .secondary)
        case .failed:
            pill("exclamationmark.icloud.fill", "Upload fehlgeschlagen", tint: .orange)
        case .local:
            if uploader.isAvailable { pill("icloud.slash", "Nur am Mac", tint: .secondary) }
        }
    }

    private func pill(_ symbol: String, _ text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain).help("Abspielen/Pause (Leertaste)")
            Text("\(Self.time(model.current)) / \(Self.time(model.duration))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            if model.hasSelection {
                Text("Auswahl \(Self.time(model.selectionLength))")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(LinearGradient.simplex, in: Capsule())
                Button("Zurücksetzen") { withAnimation(.snappy) { model.resetSelection() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Menu {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { r in
                    Button(r == 1 ? "Normal" : String(format: "%.2gx", r)) { model.setRate(Float(r)) }
                }
            } label: {
                Text(model.rate == 1 ? "1x" : String(format: "%.2gx", model.rate))
                    .font(.system(size: 12, weight: .bold))
            }
            .menuStyle(.borderlessButton).fixedSize().help("Geschwindigkeit")
            iconButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: "Ton an/aus") { model.toggleMute() }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Vollbild (F)") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { model.exportSelection(thenUpload: true) } label: {
                Label(model.hasSelection ? "Schneiden & Link kopieren" : (uploader.link(for: model.url) == nil ? "Hochladen & Link kopieren" : "Link kopieren"),
                      systemImage: model.hasSelection ? "scissors" : "link")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(LinearGradient.simplex, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.purple.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(model.exporting || (!uploader.isAvailable && !model.hasSelection))
            .keyboardShortcut(.return, modifiers: .command)

            if model.hasSelection {
                secondary("Als neuen Clip speichern", "square.and.arrow.down") { model.exportSelection(thenUpload: false) }
                    .disabled(model.exporting)
                    .keyboardShortcut("s", modifiers: .command)
            }
            secondary("Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
            ShareLink(item: model.url) {
                Label("Teilen", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("I/O: Anfang/Ende · ←/→: Bild · J/L: 5 s").font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.55))
            }
            .buttonStyle(.plain).help("Überall löschen")
        }
    }

    private func secondary(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 36)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain).help(help)
    }

    static func time(_ t: Double) -> String {
        guard t.isFinite else { return "0:00.0" }
        let tenths = Int((t * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - Timeline

struct TrimTimeline: View {
    @ObservedObject var model: ClipEditorModel
    private let height: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(model.duration, 0.001)
            let xIn = CGFloat(model.inPoint / d) * w
            let xOut = CGFloat(model.outPoint / d) * w
            let xNow = CGFloat(model.current / d) * w

            ZStack(alignment: .topLeading) {
                // Filmstrip
                HStack(spacing: 0) {
                    if model.frames.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.06))
                    } else {
                        ForEach(Array(model.frames.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(model.frames.count), height: height)
                                .clipped()
                        }
                    }
                }
                .frame(width: w, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Outside the selection
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, xIn), height: height)
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, w - xOut), height: height)
                    .offset(x: xOut)

                // Selection frame
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LinearGradient.simplex, lineWidth: 3)
                    .frame(width: max(14, xOut - xIn), height: height)
                    .offset(x: xIn)
                    .allowsHitTesting(false)

                // Playhead
                Capsule().fill(Color.white)
                    .frame(width: 3, height: height + 12)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .offset(x: xNow - 1.5, y: -6)
                    .allowsHitTesting(false)

                handle(left: true).offset(x: xIn - 7)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in
                            let t = Double(v.location.x / w) * d
                            model.inPoint = min(max(0, t), max(0, model.outPoint - 0.5))
                            model.scrub(model.inPoint, ended: false)
                        }
                        .onEnded { _ in model.scrub(model.inPoint, ended: true) })
                handle(left: false).offset(x: xOut - 7)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in
                            let t = Double(v.location.x / w) * d
                            model.outPoint = max(min(d, t), min(d, model.inPoint + 0.5))
                            model.scrub(model.outPoint, ended: false)
                        }
                        .onEnded { _ in model.scrub(model.inPoint, ended: true) })
            }
            .frame(width: w, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: "timeline")
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in model.scrub(Double(min(max(0, v.location.x), w) / w) * d, ended: false) }
                .onEnded { v in model.scrub(Double(min(max(0, v.location.x), w) / w) * d, ended: true) })
        }
        .frame(height: height)
        .padding(.vertical, 6)
    }

    private func handle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .frame(width: 14, height: height)
            .overlay(
                Capsule().fill(Color.black.opacity(0.45)).frame(width: 3, height: 20)
            )
            .shadow(color: .black.opacity(0.5), radius: 4)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help(left ? "Anfang (I)" : "Ende (O)")
    }
}

// MARK: - Player surface (no system controls – ours are below)

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
