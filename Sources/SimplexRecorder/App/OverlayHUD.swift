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

    func show(symbol: String, title: String, subtitle: String?, tint: NSColor, sticky: Bool = false) {
        model.symbol = symbol
        model.title = title
        model.subtitle = subtitle
        model.tint = Color(nsColor: tint)
        model.pulse.toggle()

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
            try? await Task.sleep(for: .seconds(sticky ? 8 : 2.2))
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
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
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 48))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var symbol = "checkmark.circle.fill"
    @Published var title = ""
    @Published var subtitle: String?
    @Published var tint: Color = .green
    @Published var pulse = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
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
        .environment(\.colorScheme, .dark)
    }
}
