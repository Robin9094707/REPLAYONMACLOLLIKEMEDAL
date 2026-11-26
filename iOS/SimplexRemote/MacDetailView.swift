import SwiftUI
import LocalAuthentication

struct MacDetailView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.dismiss) private var dismiss
    let mac: PairedMac

    @AppStorage("displayMode") private var modeRaw = DisplayMode.mirror.rawValue
    @AppStorage("streamQuality") private var qualityRaw = StreamQuality.balanced.rawValue
    @AppStorage("quickActions") private var quickActionsRaw = QuickAction.defaultSelection.map(\.rawValue).joined(separator: ",")
    @State private var session: RemoteSession?
    @State private var confirmAction: QuickAction?
    @State private var showPasswordSheet = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var showAllApps = false
    @State private var hasUnlockPassword = false

    private var mode: DisplayMode { DisplayMode(rawValue: modeRaw) ?? .mirror }
    private var quality: StreamQuality { StreamQuality(rawValue: qualityRaw) ?? .balanced }
    private var quickActions: [QuickAction] {
        quickActionsRaw.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
    }

    var body: some View {
        let status = store.statuses[mac.id]
        let online = store.isOnline(mac)
        ScrollView {
            VStack(spacing: 18) {
                hero(status, online: online)
                if online, let status {
                    if !status.trusted { PermissionBanner(mac: mac) }
                    gauges(status)
                    if status.locked { unlockCard }
                    connectCard(status)
                    actionsGrid
                    appsCard(status)
                    infoCard(status)
                } else {
                    offlineCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background { AuroraBackground() }
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Umbenennen", systemImage: "pencil") { newName = mac.name; showRename = true }
                    Button("Mac-Passwort für Face ID …", systemImage: "faceid") { showPasswordSheet = true }
                    Divider()
                    Button("Mac entfernen", systemImage: "trash", role: .destructive) {
                        store.remove(mac)
                        dismiss()
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fullScreenCover(item: $session) { session in
            RemoteView(session: session)
        }
        .sheet(isPresented: $showPasswordSheet, onDismiss: refreshUnlock) { UnlockPasswordSheet(mac: mac) }
        .alert("Umbenennen", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Sichern") { store.rename(mac, to: newName) }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(confirmAction?.title ?? "", isPresented: Binding(
            get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
            if let action = confirmAction {
                Button(action.title, role: .destructive) { store.action(action, on: mac) }
            }
        } message: {
            Text(confirmAction == .quitAll ? "Alle Apps außer Simplex Suite werden beendet." : "Bist du sicher?")
        }
        .onAppear(perform: refreshUnlock)
        .onDisappear { if session == nil { store.detach(mac) } }
    }

    private func refreshUnlock() { hasUnlockPassword = Keychain.hasUnlockPassword(macID: mac.id) }

    // MARK: Sections

    private func hero(_ status: MacStatus?, online: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: modelSymbol(status?.model ?? ""))
                .font(.system(size: 54, weight: .light))
                .symbolEffect(.pulse, isActive: status?.streaming ?? false)
            HStack(spacing: 8) {
                PulseDot(color: online ? .green : .gray, active: online)
                Text(online ? "Online · seit \(status?.uptimeText ?? "–")" : "Offline")
                    .font(.subheadline.weight(.medium))
            }
            if let status, online {
                Text("\(status.model) · \(status.os)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func gauges(_ status: MacStatus) -> some View {
        VStack(spacing: 14) {
            HStack {
                RingGauge(value: status.cpu, color: .blue, symbol: "cpu", label: "\(Int(status.cpu * 100))%", caption: "CPU")
                Spacer()
                RingGauge(value: status.memFraction, color: .purple, symbol: "memorychip",
                          label: status.mem.bytesText, caption: "RAM")
                Spacer()
                RingGauge(value: status.temp.map { $0 / 105 } ?? 0.3, color: .orange, symbol: "thermometer.medium",
                          label: status.temperatureText, caption: "Temperatur")
                Spacer()
                RingGauge(value: status.diskUsedFraction, color: .green, symbol: "internaldrive",
                          label: status.diskFree.bytesText, caption: "frei")
            }
            let history = store.cpuHistory[mac.id] ?? []
            if history.count > 2 {
                ZStack {
                    SparklineShape(values: history)
                        .stroke(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 44)
                .animation(.easeOut, value: history.count)
            }
            if let battery = status.battery {
                HStack {
                    Image(systemName: status.charging ? "battery.100.bolt" : "battery.75")
                    Text("Akku \(battery) %\(status.charging ? " · lädt" : "")")
                    Spacer()
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassCard()
    }

    private var unlockCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac ist gesperrt").font(.headline)
                Text(hasUnlockPassword ? "Mit Face ID entsperren" : "Passwort einmal hinterlegen, dann per Face ID")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if hasUnlockPassword {
                    Task {
                        if await store.unlock(mac) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                } else {
                    showPasswordSheet = true
                }
            } label: {
                Image(systemName: "faceid").font(.title2).frame(width: 52, height: 52)
            }
            .glass(in: Circle(), tint: .orange, interactive: true)
        }
        .padding(16)
        .glassCard(tint: .orange)
    }

    private func connectCard(_ status: MacStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fernsteuerung").font(.headline)
            HStack(spacing: 10) {
                ForEach(DisplayMode.allCases) { m in
                    let available = m == .mirror || status.virtualDisplays
                    Button {
                        withAnimation(.spring) { modeRaw = m.rawValue }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: m.symbol).font(.title3)
                            Text(m.title).font(.caption2.weight(.semibold)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                           tint: mode == m ? .purple : nil, interactive: true)
                    .opacity(available ? 1 : 0.4)
                    .disabled(!available)
                }
            }
            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
            Picker("Qualität", selection: $qualityRaw) {
                ForEach(StreamQuality.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Button {
                guard status.control else {
                    store.toast = "Fernsteuerung ist am Mac ausgeschaltet"
                    return
                }
                let s = RemoteSession(mac: mac, store: store, mode: mode, quality: quality)
                session = s
            } label: {
                Label("Verbinden", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .glassCapsule(tint: .purple)
        }
        .padding(18)
        .glassCard()
    }

    private var actionsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schnellaktionen").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                ForEach(quickActions) { action in
                    Button {
                        if action.needsConfirmation { confirmAction = action } else { store.action(action, on: mac) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: action.symbol).font(.system(size: 20, weight: .semibold))
                            Text(action.title).font(.system(size: 10, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .foregroundStyle(action.isDestructive ? Color.red : Color.white)
                    }
                    .buttonStyle(.plain)
                    .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                }
            }
        }
        .padding(18)
        .glassCard()
    }

    private func appsCard(_ status: MacStatus) -> some View {
        let apps = showAllApps ? status.apps : Array(status.apps.prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Aktive Apps").font(.headline)
                Text("\(status.apps.count)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                    .glassCapsule(interactive: false)
                Spacer()
                Button("Alle beenden", systemImage: "xmark.circle.fill") { confirmAction = .quitAll }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    Text(app.name).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(Int(app.cpu)) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(app.mem.bytesText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).frame(width: 28)
                    } else {
                        Button {
                            store.quitApp(app, on: mac)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.red.opacity(0.85))
                        }
                        .frame(width: 28)
                    }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    if !app.isProtected {
                        Button("Beenden", systemImage: "xmark") { store.quitApp(app, on: mac) }
                        Button("Sofort beenden", systemImage: "bolt.fill", role: .destructive) { store.quitApp(app, on: mac, force: true) }
                    }
                }
            }
            if status.apps.count > 6 {
                Button(showAllApps ? "Weniger" : "Alle \(status.apps.count) anzeigen") {
                    withAnimation(.spring) { showAllApps.toggle() }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .glassCard()
    }

    private func infoCard(_ status: MacStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.clipping {
                Label(status.game.map { "Clipping aktiv – \($0)" } ?? "Clipping aktiv", systemImage: "record.circle")
                    .foregroundStyle(.red)
            } else if !status.clipStatus.isEmpty {
                Label(status.clipStatus, systemImage: "gamecontroller")
            }
            Label("Simplex Suite \(status.version)", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
            Label("Ende-zu-Ende verschlüsselt", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard()
    }

    private var offlineCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Mac ist offline").font(.title3.bold())
            Text("Sobald der Mac eingeschaltet und angemeldet ist, verbindet sich Simplex Suite automatisch.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            if case .failed(let message) = store.serverState(for: mac) {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}

extension RemoteSession: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

// MARK: - Unlock password

struct UnlockPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mac: PairedMac
    @State private var password = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anmeldepasswort des Macs", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Wird nur auf diesem iPhone im Schlüsselbund gespeichert und mit Face ID geschützt. Beim Entsperren wird es verschlüsselt an deinen Mac gesendet und dort in den Sperrbildschirm getippt.")
                }
                if Keychain.hasUnlockPassword(macID: mac.id) {
                    Section {
                        Button("Gespeichertes Passwort löschen", role: .destructive) {
                            Keychain.deleteUnlockPassword(macID: mac.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Entsperren mit Face ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if Keychain.saveUnlockPassword(password, macID: mac.id) { dismiss() }
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}

/// Shown when the Mac can't inject input because Accessibility is missing.
struct PermissionBanner: View {
    @EnvironmentObject private var store: MacStore
    let mac: PairedMac

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Steuerung am Mac blockiert").font(.headline)
                Text("Simplex Suite braucht am Mac die Berechtigung „Bedienungshilfen“ – sonst ignoriert macOS Klicks und Tasten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Am Mac öffnen") {
                store.send(["t": "action", "a": "openAccessibility"], to: mac)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassCapsule(tint: .yellow)
        }
        .padding(16)
        .glassCard(tint: .yellow)
    }
}
