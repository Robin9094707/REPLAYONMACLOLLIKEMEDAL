import AppKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices

/// Window previews when hovering an app in the Dock (like on Windows' taskbar).
/// Event-driven: a global mouse-moved monitor that only does work while the cursor is in
/// the Dock area. Thumbnails are single ScreenCaptureKit screenshots, no running stream.
@MainActor
final class DockPreview {
    static let shared = DockPreview()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var panel: NSPanel?
    private let model = DockPreviewModel()
    private var hoverPID: pid_t?
    private var hoverTask: Task<Void, Never>?
    private var lastCheck: TimeInterval = 0
    private var dockOrientation = "bottom"

    func update() {
        let enabled = SuiteSettings.shared.dockPreviews && AXIsProcessTrusted() && Permissions.hasScreenRecording
        if enabled, globalMonitor == nil {
            dockOrientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
                Task { @MainActor in DockPreview.shared.mouseMoved() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                Task { @MainActor in DockPreview.shared.mouseMoved() }
                return event
            }
        } else if !enabled, let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
            hidePanel()
        }
    }

    // MARK: Hover detection

    private func mouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck > 0.08 else { return }
        lastCheck = now
        let mouse = NSEvent.mouseLocation

        // Over the preview itself → keep it open.
        if let panel, panel.isVisible, panel.frame.insetBy(dx: -6, dy: -6).contains(mouse) { return }

        guard isInDockArea(mouse) else {
            if panel?.isVisible == true || hoverPID != nil { cancelHover() }
            return
        }
        guard let hit = dockApp(at: mouse) else {
            cancelHover()
            return
        }
        let pid = hit.pid
        let itemFrame = hit.frame
        guard pid != hoverPID else { return }
        hoverPID = pid
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(panel?.isVisible == true ? 60 : 380))
            guard !Task.isCancelled, self.hoverPID == pid else { return }
            await self.showPreview(pid: pid, itemFrame: itemFrame)
        }
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverPID = nil
        hidePanel()
    }

    private func isInDockArea(_ mouse: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return false }
        let f = screen.frame, v = screen.visibleFrame
        switch dockOrientation {
        case "left": return mouse.x <= max(v.minX, f.minX + 4) + 2
        case "right": return mouse.x >= min(v.maxX, f.maxX - 4) - 2
        default: return mouse.y <= max(v.minY, f.minY + 4) + 2
        }
    }

    /// Running app under the cursor in the Dock plus the Dock item's frame (Cocoa coordinates).
    private func dockApp(at mouse: NSPoint) -> (pid: pid_t, frame: CGRect)? {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(mouse.x), Float(primary - mouse.y), &element) == .success,
              let element else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == "AXApplicationDockItem" else { return nil }
        var urlValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue)
        guard let nsURL = urlValue as? NSURL else { return nil }
        let url = nsURL as URL
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
        }) else { return nil }

        var frame = CGRect.zero
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let posValue, let sizeValue {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &s)
            frame = CGRect(x: p.x, y: primary - p.y - s.height, width: s.width, height: s.height)
        }
        return (pid: app.processIdentifier, frame: frame)
    }

    // MARK: Preview

    private func showPreview(pid: pid_t, itemFrame: CGRect) async {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let windows = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 }
            .prefix(6)
        guard !windows.isEmpty else {
            hidePanel()
            return
        }
        var items: [DockPreviewItem] = []
        for window in windows {
            let config = SCStreamConfiguration()
            let scale = min(1.0, 360.0 / max(window.frame.width, 1))
            config.width = max(2, Int(window.frame.width * scale * 2))
            config.height = max(2, Int(window.frame.height * scale * 2))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            items.append(DockPreviewItem(id: window.windowID, title: window.title ?? "", image: image,
                                         frame: window.frame, pid: pid))
        }
        guard hoverPID == pid else { return }
        model.appName = app.localizedName ?? ""
        model.items = items
        presentPanel(near: itemFrame, count: items.count)
    }

    private func presentPanel(near item: CGRect, count: Int) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let width = CGFloat(count) * 232 + 24
        let height: CGFloat = 196
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: item.midX, y: item.midY), $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var origin: NSPoint
        switch dockOrientation {
        case "left": origin = NSPoint(x: item.maxX + 8, y: item.midY - height / 2)
        case "right": origin = NSPoint(x: item.minX - width - 8, y: item.midY - height / 2)
        default: origin = NSPoint(x: item.midX - width / 2, y: item.maxY + 8)
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - width - 8)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - height)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DockPreviewView(model: model) { item in
            DockPreview.shared.focus(item)
        })
        return panel
    }

    // MARK: Actions

    func focus(_ item: DockPreviewItem) {
        hidePanel()
        hoverPID = nil
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        let axApp = AXUIElementCreateApplication(item.pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            let match = windows.first { window in
                var pos: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success, let pos else { return false }
                var p = CGPoint.zero
                AXValueGetValue(pos as! AXValue, .cgPoint, &p)
                return abs(p.x - item.frame.minX) < 4 && abs(p.y - item.frame.minY) < 4
            }
            if let match {
                AXUIElementPerformAction(match, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
        app.activate()
    }

    func close(_ item: DockPreviewItem) {
        let axApp = AXUIElementCreateApplication(item.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var pos: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success, let pos else { continue }
            var p = CGPoint.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            guard abs(p.x - item.frame.minX) < 4 && abs(p.y - item.frame.minY) < 4 else { continue }
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
               let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
        model.items.removeAll { $0.id == item.id }
        if model.items.isEmpty { hidePanel() }
    }
}

struct DockPreviewItem: Identifiable {
    let id: CGWindowID
    let title: String
    let image: CGImage?
    let frame: CGRect
    let pid: pid_t
}

@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var items: [DockPreviewItem] = []
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    let onSelect: (DockPreviewItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.items) { item in
                DockPreviewTile(item: item, onSelect: onSelect)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

struct DockPreviewTile: View {
    let item: DockPreviewItem
    let onSelect: (DockPreviewItem) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(item.title.isEmpty ? "Fenster" : item.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if hovering {
                    Button {
                        DockPreview.shared.close(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Fenster schließen")
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let image = item.image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "macwindow").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 208, height: 140)
        }
        .padding(6)
        .frame(width: 224)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(item) }
    }
}
