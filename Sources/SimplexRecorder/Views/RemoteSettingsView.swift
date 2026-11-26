import SwiftUI
import AppKit
import VirtualDisplayBridge

struct RemoteSettingsView: View {
    @ObservedObject private var config = RemoteConfig.shared
    @ObservedObject private var agent = RemoteAgent.shared
    @ObservedObject private var uploader = ClipUploader.shared
    @State private var showPassword = false
    @State private var copied = false
    @State private var draftServer = RemoteConfig.shared.serverURL
    @State private var draftPassword = RemoteConfig.shared.serverPassword
    @State private var trusted = AXIsProcessTrusted()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(stateColor.opacity(0.15)).frame(width: 44, height: 44)
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(stateColor)
                            .symbolEffect(.pulse, isActive: agent.state == .connecting)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote-Zugang: \(agent.state.title)").font(.headline)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { config.enabled }, set: { config.enabled = $0; agent.applyConfig() }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            Section {
                TextField("Server-Adresse", text: $draftServer, prompt: Text("https://remote.deine-domain.de"))
                HStack {
                    if showPassword {
                        TextField("Server-Passwort", text: $draftPassword)
                    } else {
                        SecureField("Server-Passwort", text: $draftPassword)
                    }
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                TextField("Name dieses Macs", text: $config.computerName)
                HStack {
                    Spacer()
                    Button("Speichern & verbinden") {
                        config.serverURL = draftServer
                        config.serverPassword = draftPassword
                        config.enabled = true
                        agent.applyConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftServer.isEmpty || draftPassword.isEmpty)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Das Passwort steht beim Start des Servers in der Konsole und in der Datei simplex_relay.json. Der Server leitet nur weiter: Bild, Eingaben und Passwörter sind Ende-zu-Ende verschlüsselt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 18) {
                    Group {
                        if config.isConfigured, let image = config.qrImage(size: 200) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                        } else {
                            RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1))
                                .frame(width: 200, height: 200)
                                .overlay(Text("Erst Server eintragen").font(.caption).foregroundStyle(.secondary))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("iPhone koppeln").font(.headline)
                        Text("1. Simplex Remote auf dem iPhone öffnen\n2. „Mac hinzufügen“ tippen\n3. Diesen QR-Code scannen – fertig.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(copied ? "Kopiert ✓" : "Kopplungs-Link kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(config.pairingLink, forType: .string)
                            copied = true
                        }
                        .disabled(!config.isConfigured)
                        Button("Neuen Schlüssel erzeugen …", role: .destructive) {
                            let alert = NSAlert()
                            alert.messageText = "Neuen Schlüssel erzeugen?"
                            alert.informativeText = "Alle gekoppelten iPhones verlieren den Zugriff und müssen den QR-Code neu scannen."
                            alert.addButton(withTitle: "Neu erzeugen")
                            alert.addButton(withTitle: "Abbrechen")
                            if alert.runModal() == .alertFirstButtonReturn {
                                config.regenerateKey()
                                agent.reconnectNow()
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Kopplung")
            }

            Section {
                Toggle("Clips auf diesen Server hochladen können", isOn: $config.uploadEnabled)
                if config.uploadEnabled {
                    Toggle("Jeden neuen Clip automatisch hochladen", isOn: $config.autoUpload)
                    Toggle("Danach Link in die Zwischenablage kopieren", isOn: $config.copyLinkAfterUpload)
                    if let storage = uploader.storage {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Server-Speicher").font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(storage.used.formattedBytes) von \(storage.limit.formattedBytes) · \(storage.count) Clips")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(storage.used), total: Double(max(storage.limit, 1)))
                            Text("Auf der Server-Festplatte frei: \(storage.diskFree.formattedBytes)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Clips teilen")
            } footer: {
                Text("Hochgeladene Clips bekommen einen Link, den jeder im Browser ohne Anmeldung abspielen kann – Discord & Co. zeigen ihn direkt als Video. HEVC-Clips werden dafür automatisch in H.264 umgewandelt. Geteilte Clips sind nicht Ende-zu-Ende verschlüsselt. Verwalten und löschen kannst du sie in der iPhone-App.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task { await uploader.refreshStorage() }

            Section {
                PermissionRow(title: "Bedienungshilfen",
                              detail: "Pflicht für Maus, Tastatur und viele Schnellaktionen vom iPhone.",
                              granted: trusted, actionTitle: "Erlauben …") {
                    GameWindowAssistant.resetTrust()
                    GameWindowAssistant.requestTrust()
                    GameWindowAssistant.openAccessibilitySettings()
                }
                Toggle("Fernsteuerung erlauben (Bildschirm, Maus, Tastatur, Aktionen)", isOn: $config.allowControl)
                Toggle("Entsperren per Face ID vom iPhone erlauben", isOn: $config.allowUnlock)
                LabeledContent("Virtueller Zweitbildschirm") {
                    Text(SXVirtualDisplay.isSupported() ? "Verfügbar" : "Nicht verfügbar")
                        .foregroundStyle(SXVirtualDisplay.isSupported() ? Color.green : Color.secondary)
                }
            } header: {
                Text("Berechtigungen")
            } footer: {
                Text("Für die Steuerung braucht die Suite „Bedienungshilfen“, für das Bild „Bildschirmaufnahme“. Entsperren funktioniert, solange du angemeldet bist und der Bildschirm nur gesperrt ist. Nach einem Neustart kann macOS mit FileVault erst nach der Anmeldung Apps starten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.computerName) { _, _ in agent.reconnectNow() }
        .onReceive(refresh) { _ in trusted = AXIsProcessTrusted() }
    }

    private var stateColor: Color {
        switch agent.state {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .off: return .secondary
        }
    }

    private var subtitle: String {
        switch agent.state {
        case .connected:
            if agent.streaming { return "📱 Bildschirm wird übertragen (\(agent.streamMode == "mirror" ? "gespiegelt" : "iPhone als Bildschirm"))" }
            if agent.attachedClients > 0 { return "\(agent.attachedClients) iPhone verbunden" }
            if agent.watchingClients > 0 { return "\(agent.watchingClients) iPhone schaut zu (Live-Daten)" }
            return "Bereit – dein iPhone kann sich jederzeit verbinden"
        case .off: return "Ausgeschaltet"
        default: return config.serverURL
        }
    }
}
