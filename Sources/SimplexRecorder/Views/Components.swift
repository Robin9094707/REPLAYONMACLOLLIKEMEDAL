import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Status header

struct StatusHeader: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: state.menuBarSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: state.isRecording)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.statusLine).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.saveClip()
            } label: {
                Label("Clip speichern", systemImage: "scissors")
            }
            .controlSize(.large)
            .disabled(!state.canSaveClip)
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch state.status {
        case .recording: return .red
        case .paused: return .orange
        case .needsPermission, .error: return .yellow
        default: return .secondary
        }
    }

    private var subtitle: String {
        switch state.status {
        case .recording:
            return "Die letzten \(settings.replayDuration) s werden mit \(settings.clipHotKey.displayString) gespeichert · Puffer \(Int(state.bufferedSeconds)) s"
        case .waitingForGame:
            return "Startet automatisch, sobald ein Spiel läuft (z. B. Minecraft)."
        case .paused:
            return "Fortsetzen mit \(settings.pauseHotKey.displayString) oder über das Menü."
        case .needsPermission:
            return "Erlaube die Bildschirmaufnahme in den Systemeinstellungen."
        default:
            return ""
        }
    }
}

// MARK: - Permission row

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(actionTitle, action: action)
            } else {
                Text("Erlaubt").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hotkey recorder

struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Tasten drücken … (⎋ = Abbrechen)" : combo.displayString)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(minWidth: 150)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        AppState.shared.suspendHotKeys()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                stop()
                return nil
            }
            if mods.isEmpty && !KeyCombo.isFunctionKey(event.keyCode) {
                // Plain letters would fire while typing in-game chat – require a modifier.
                NSSound.beep()
                return nil
            }
            combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue,
                             keyLabel: KeyCombo.label(for: event))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            AppState.shared.registerHotKeys()
        }
    }
}

// MARK: - Storage bar

struct StorageBar: View {
    let info: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let total = max(Double(info.total), 1)
                let clipsW = geo.size.width * Double(info.clipsBytes) / total
                let otherW = geo.size.width * Double(info.otherBytes) / total
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: max(clipsW, info.clipsBytes > 0 ? 3 : 0))
                    Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: otherW)
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.secondary.opacity(0.25)))

            HStack(spacing: 16) {
                legend(color: .accentColor, title: "Clips", value: info.clipsBytes)
                legend(color: .secondary.opacity(0.55), title: "Andere Daten", value: info.otherBytes)
                legend(color: .secondary.opacity(0.15), title: "Frei", value: info.available)
                Spacer()
                Text("Gesamt \(info.total.formattedBytes)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(color: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("\(title): \(value.formattedBytes)").font(.caption)
        }
    }
}

// MARK: - App icon helper

struct AppBadge: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.25, blue: 0.95), Color(red: 0.95, green: 0.25, blue: 0.4)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "record.circle")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}
