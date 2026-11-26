import SwiftUI

/// Full-screen remote control: Mac screen, gestures, keyboard bar and the quick menu.
struct RemoteView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: RemoteSession
    @AppStorage("quickActions") private var quickActionsRaw = QuickAction.defaultSelection.map(\.rawValue).joined(separator: ",")
    @State private var menuOpen = false
    @State private var toolbarHidden = false
    @State private var confirmAction: QuickAction?

    private var quickActions: [QuickAction] {
        quickActionsRaw.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteSurface(session: session)
                .ignoresSafeArea()

            if session.connecting {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(session.mode == .mirror ? "Verbinde mit \(session.mac.name) …" : "Richte iPhone-Bildschirm ein …")
                        .font(.headline)
                }
                .padding(28)
                .glassCard()
                .transition(.scale.combined(with: .opacity))
            }

            VStack {
                if !toolbarHidden { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                if store.statuses[session.mac.id]?.trusted == false {
                    PermissionBanner(mac: session.mac).padding(.top, 6)
                }
                Spacer()
                if session.keyboardVisible { keyBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(.horizontal, 12)

            quickMenu
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.connecting)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.keyboardVisible)
        .confirmationDialog(confirmAction?.title ?? "", isPresented: Binding(
            get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
            if let action = confirmAction {
                Button(action.title, role: .destructive) { store.action(action, on: session.mac) }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
            }
            .glass(in: Circle(), interactive: true)

            Menu {
                Picker("Steuerung", selection: $session.inputMode) {
                    ForEach(InputMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Anzeige", selection: Binding(get: { session.mode }, set: { session.mode = $0; session.requestStream() })) {
                    ForEach(DisplayMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Qualität", selection: Binding(get: { session.quality }, set: { session.quality = $0; session.requestStream() })) {
                    ForEach(StreamQuality.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Zwischenablage automatisch übernehmen", isOn: $session.autoClipboard)
                Button("Zoom zurücksetzen", systemImage: "arrow.down.right.and.arrow.up.left") { session.surface.resetZoom() }
                Button("Bild neu laden", systemImage: "arrow.clockwise") { session.requestStream() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.inputMode.symbol)
                    Text(session.mac.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 40)
            }
            .glassCapsule()

            Spacer()

            if session.net.kbps > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "cellularbars", variableValue: Double(session.net.quality) / 3)
                        .foregroundStyle(session.net.quality >= 2 ? Color.green : (session.net.quality == 1 ? Color.orange : Color.red))
                    Text(session.net.text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .padding(.horizontal, 10).frame(height: 32)
                .glassCapsule(interactive: false)
                .transition(.opacity)
            }

            Button { session.sendClipboard() } label: {
                Image(systemName: "doc.on.clipboard").frame(width: 40, height: 40)
            }
            .glass(in: Circle(), interactive: true)

            Button { session.toggleKeyboard() } label: {
                Image(systemName: session.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard").frame(width: 40, height: 40)
            }
            .glass(in: Circle(), tint: session.keyboardVisible ? .purple : nil, interactive: true)

            Button { withAnimation { toolbarHidden = true } } label: {
                Image(systemName: "chevron.up").frame(width: 40, height: 40)
            }
            .glass(in: Circle(), interactive: true)
        }
        .foregroundStyle(.white)
        .padding(.top, 6)
    }

    // MARK: Special keys

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["cmd", "ctrl", "alt", "shift"], id: \.self) { m in
                    keyButton(modifierLabel(m), active: session.activeModifiers.contains(m)) { session.toggleModifier(m) }
                }
                Divider().frame(height: 24)
                keyButton("esc") { session.press("esc") }
                keyButton("⇥") { session.press("tab") }
                keyButton("←") { session.press("left") }
                keyButton("↑") { session.press("up") }
                keyButton("↓") { session.press("down") }
                keyButton("→") { session.press("right") }
                keyButton("⌫") { session.press("backspace") }
                keyButton("⌦") { session.press("delete") }
                keyButton("↩") { session.press("return") }
                keyButton("⌘C") { session.press("c", modifiers: ["cmd"]) }
                keyButton("⌘V") { session.press("v", modifiers: ["cmd"]) }
                keyButton("⌘Z") { session.press("z", modifiers: ["cmd"]) }
                keyButton("⌘⇥") { session.press("tab", modifiers: ["cmd"]) }
                ForEach(1...12, id: \.self) { n in keyButton("F\(n)") { session.press("f\(n)") } }
            }
            .padding(8)
        }
        .glassCapsule(interactive: false)
        .padding(.bottom, 4)
    }

    private func modifierLabel(_ m: String) -> String {
        ["cmd": "⌘", "ctrl": "⌃", "alt": "⌥", "shift": "⇧"][m] ?? m
    }

    private func keyButton(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(minWidth: 40, minHeight: 36)
                .padding(.horizontal, 4)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.purple.opacity(0.8) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Quick menu

    private var quickMenu: some View {
        VStack {
            if toolbarHidden {
                HStack {
                    Spacer()
                    Button { withAnimation { toolbarHidden = false } } label: {
                        Image(systemName: "chevron.down").frame(width: 36, height: 36)
                    }
                    .glass(in: Circle(), interactive: true)
                    .padding(.trailing, 12)
                }
            }
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if menuOpen {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .trailing, spacing: 8) {
                                ForEach(Array(quickActions.enumerated()), id: \.element) { index, action in
                                    Button {
                                        if action.needsConfirmation { confirmAction = action } else { store.action(action, on: session.mac) }
                                        withAnimation(.spring) { menuOpen = false }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(action.title).font(.subheadline.weight(.semibold))
                                            Image(systemName: action.symbol).frame(width: 22)
                                        }
                                        .foregroundStyle(action.isDestructive ? Color.red : Color.white)
                                        .padding(.horizontal, 16).padding(.vertical, 11)
                                    }
                                    .buttonStyle(.plain)
                                    .glassCapsule()
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity)
                                            .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.025)),
                                        removal: .opacity))
                                }
                            }
                        }
                        .frame(maxHeight: 420)
                    }
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { menuOpen.toggle() }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Image(systemName: menuOpen ? "xmark" : "bolt.fill")
                            .font(.system(size: 20, weight: .bold))
                            .rotationEffect(.degrees(menuOpen ? 90 : 0))
                            .frame(width: 58, height: 58)
                            .foregroundStyle(.white)
                    }
                    .glass(in: Circle(), tint: .purple, interactive: true)
                }
                .padding(.trailing, 16)
                .padding(.bottom, session.keyboardVisible ? 70 : 24)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("quickActions") private var quickActionsRaw = QuickAction.defaultSelection.map(\.rawValue).joined(separator: ",")
    @State private var selected: [QuickAction] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selected) { action in
                        Label(action.title, systemImage: action.symbol)
                    }
                    .onMove { selected.move(fromOffsets: $0, toOffset: $1); persist() }
                    .onDelete { selected.remove(atOffsets: $0); persist() }
                } header: {
                    Text("Schnellmenü (Reihenfolge ziehen)")
                } footer: {
                    Text("Erscheint in der Fernsteuerung hinter dem ⚡️-Knopf und in der Mac-Ansicht.")
                }
                Section("Hinzufügen") {
                    ForEach(QuickAction.allCases.filter { !selected.contains($0) }) { action in
                        Button {
                            withAnimation { selected.append(action) }
                            persist()
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                    }
                }
                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Label("Alle Verbindungen sind Ende-zu-Ende verschlüsselt (AES-GCM).", systemImage: "lock.shield")
                        .font(.footnote)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear {
                selected = quickActionsRaw.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
            }
        }
    }

    private func persist() {
        quickActionsRaw = selected.map(\.rawValue).joined(separator: ",")
    }
}
