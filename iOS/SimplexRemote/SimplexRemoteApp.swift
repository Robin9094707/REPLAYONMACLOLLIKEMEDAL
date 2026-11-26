import SwiftUI

@main
struct SimplexRemoteApp: App {
    @StateObject private var store = MacStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    @State private var pendingPairing: PairingPayload?

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .opacity(showSplash ? 0 : 1)
                    .scaleEffect(showSplash ? 0.96 : 1)
                if showSplash {
                    SplashView()
                        .transition(.opacity.combined(with: .scale(scale: 1.08)))
                }
                if let toast = store.toast {
                    VStack {
                        Text(toast)
                            .multilineTextAlignment(.center)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .glassCapsule()
                            .padding(.top, 8)
                            .padding(.horizontal, 20)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AuroraBackground() }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .onAppear {
                store.connectAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { showSplash = false }
                }
            }
            .onOpenURL { url in
                if let payload = PairingPayload(link: url.absoluteString) {
                    let mac = store.add(payload)
                    store.toast = "✓ \(mac.name) hinzugefügt"
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.connectAll()
            case .background: store.disconnectAll()
            default: break
            }
        }
    }
}

struct SplashView: View {
    @State private var appear = false
    @State private var glow = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.purple.opacity(0.7), .clear], center: .center, startRadius: 5, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .scaleEffect(glow ? 1.15 : 0.7)
                    .opacity(glow ? 1 : 0.3)
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 76, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .padding(36)
                    .glass(in: Circle())
                    .scaleEffect(appear ? 1 : 0.4)
                    .rotation3DEffect(.degrees(appear ? 0 : -40), axis: (x: 1, y: 0, z: 0))
            }
            VStack(spacing: 6) {
                Text("Simplex Remote")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Dein Mac. Überall.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 20)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) { appear = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
