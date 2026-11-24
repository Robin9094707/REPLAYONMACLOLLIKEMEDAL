import AppKit
import SwiftUI

/// Small floating toast ("Clip gespeichert") shown on top of everything – also over
/// fullscreen games. It never steals focus and is not captured (this app is excluded
/// from every capture, and window captures only see the game window).
@MainActor
final class OverlayHUD {
    static let shared = OverlayHUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model = HUDModel()

    /// Big animated card: "Clipping aktiv" when a game starts.
    func showHero(title: String, subtitle: String, detail: String) {
        model.hero = true
        model.title = title
        model.subtitle = subtitle
        model.detail = detail
        model.appeared = false
        present(duration: 3.6)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { model.appeared = true }
    }

    func show(symbol: String, title: String, subtitle: String?, tint: NSColor, sticky: Bool = false) {
        model.hero = false
        model.appeared = true
        model.symbol = symbol
        model.title = title
        model.subtitle = subtitle
        model.tint = Color(nsColor: tint)
        model.pulse.toggle()
        present(duration: sticky ? 8 : 2.2)
    }

    private func present(duration: Double) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none // keep it out of any screen recording
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        // Screen with the mouse = the one the player is looking at.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 40))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var symbol = "checkmark.circle.fill"
    @Published var title = ""
    @Published var subtitle: String?
    @Published var tint: Color = .green
    @Published var pulse = false
    @Published var hero = false
    @Published var detail = ""
    @Published var appeared = true
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        Group {
            if model.hero { hero } else { toast }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var toast: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(model.tint)
                .symbolEffect(.bounce, value: model.pulse)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 14, weight: .semibold))
                if let subtitle = model.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .padding(6)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.red.opacity(0.7), lineWidth: 3)
                    .frame(width: 34, height: 34)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.9 : 1).opacity(expanded ? 0 : 0.9)
                    } animation: { _ in .easeOut(duration: 1.3) }
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.35), .red],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 22, height: 22)
                    .shadow(color: .red.opacity(0.8), radius: 8)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(model.subtitle ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 420, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.25, blue: 0.95).opacity(0.35),
                                                  Color(red: 0.95, green: 0.25, blue: 0.4).opacity(0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .scaleEffect(model.appeared ? 1 : 0.82, anchor: .top)
        .offset(y: model.appeared ? 0 : -24)
        .padding(10)
    }
}
