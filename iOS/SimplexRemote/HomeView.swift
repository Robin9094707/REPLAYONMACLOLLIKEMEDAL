import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: MacStore
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if store.macs.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(store.macs.enumerated()), id: \.element.id) { index, mac in
                            NavigationLink(value: mac) {
                                MacCard(mac: mac)
                            }
                            .buttonStyle(.plain)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 30)
                            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.08), value: appeared)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
            .background { AuroraBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PairedMac.self) { mac in
                MacDetailView(mac: mac)
            }
            .sheet(isPresented: $showAdd) { AddMacView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { appeared = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meine Macs").font(.system(size: 34, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glass(in: Circle(), interactive: true)
            Button { showAdd = true } label: {
                Image(systemName: "plus").font(.system(size: 19, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .glass(in: Circle(), tint: .purple, interactive: true)
        }
        .foregroundStyle(.white)
        .padding(.top, 12)
    }

    private var subtitle: String {
        let online = store.macs.filter { store.isOnline($0) }.count
        return store.macs.isEmpty ? "Noch kein Mac gekoppelt" : "\(online) von \(store.macs.count) online"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64, weight: .light))
            Text("Mac koppeln").font(.title2.bold())
            Text("Öffne auf deinem Mac Simplex Suite → Einstellungen → Remote und scanne den QR-Code.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                showAdd = true
            } label: {
                Label("QR-Code scannen", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 26).padding(.vertical, 14)
            }
            .glassCapsule(tint: .purple)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.top, 40)
    }
}

// MARK: - Mac card

struct MacCard: View {
    @EnvironmentObject private var store: MacStore
    let mac: PairedMac

    var body: some View {
        let status = store.statuses[mac.id]
        let online = store.isOnline(mac)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: modelSymbol(status?.model ?? ""))
                    .font(.system(size: 26, weight: .medium))
                    .frame(width: 52, height: 52)
                    .glass(in: RoundedRectangle(cornerRadius: 15, style: .continuous), tint: online ? .green : nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mac.name).font(.title3.bold()).lineLimit(1)
                    HStack(spacing: 6) {
                        PulseDot(color: online ? .green : .gray, active: online)
                        Text(statusLine(status, online: online)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if status?.locked == true && online {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            if online, let status {
                HStack(spacing: 0) {
                    miniStat("cpu", "\(Int(status.cpu * 100))%", "CPU", .blue)
                    miniStat("memorychip", "\(Int(status.memFraction * 100))%", "RAM", .purple)
                    miniStat("thermometer.medium", status.temperatureText, "Temp", .orange)
                    if let battery = status.battery {
                        miniStat(status.charging ? "battery.100.bolt" : "battery.75", "\(battery)%", "Akku", .green)
                    } else {
                        miniStat("internaldrive", status.diskFree.bytesText, "frei", .green)
                    }
                }
                if status.clipping || status.streaming {
                    HStack(spacing: 8) {
                        if status.clipping {
                            Label(status.game.map { "Clipping · \($0)" } ?? "Clipping aktiv", systemImage: "record.circle")
                                .foregroundStyle(.red)
                        }
                        if status.streaming {
                            Label("Fernsteuerung aktiv", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.blue)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 28)
        .contentShape(RoundedRectangle(cornerRadius: 28))
    }

    private func miniStat(_ symbol: String, _ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusLine(_ status: MacStatus?, online: Bool) -> String {
        if online, let status { return "Online · läuft seit \(status.uptimeText)" }
        if online { return "Online" }
        if let seen = store.presence[mac.id]?.lastSeen {
            return "Offline · zuletzt \(seen.relativeGerman)"
        }
        switch store.serverState(for: mac) {
        case .failed(let message): return message
        case .connecting: return "Verbinde mit Server …"
        default: return "Offline"
        }
    }
}

func modelSymbol(_ model: String) -> String {
    let m = model.lowercased()
    if m.contains("macbook") { return "laptopcomputer" }
    if m.contains("imac") { return "desktopcomputer" }
    if m.contains("macmini") || m.contains("mac mini") { return "macmini" }
    if m.contains("macpro") || m.contains("studio") { return "macstudio" }
    return "laptopcomputer"
}
