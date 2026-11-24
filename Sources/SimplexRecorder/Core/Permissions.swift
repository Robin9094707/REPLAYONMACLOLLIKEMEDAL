import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications
import ScreenCaptureKit

enum Permissions {
    /// Set once ScreenCaptureKit actually worked. CGPreflightScreenCaptureAccess() is cached
    /// per process and keeps saying "no" after you granted access until the app restarts.
    private static var screenRecordingConfirmed = false

    static var hasScreenRecording: Bool { screenRecordingConfirmed || CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Asks ScreenCaptureKit directly – reflects a freshly granted permission without restart.
    static func probeScreenRecording() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screenRecordingConfirmed = true
            return true
        } catch {
            return false
        }
    }

    /// Removes the (possibly stale) entry for this app from the privacy database.
    /// Needed after updates: the app is only ad-hoc signed, so macOS treats every new
    /// build as a different app and the old switch in System Settings no longer applies.
    static func resetScreenRecordingPermission() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.simplex.recorder"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        screenRecordingConfirmed = false
    }

    /// Full repair: reset entry → ask again → open System Settings.
    static func repairScreenRecording() {
        resetScreenRecordingPermission()
        if !requestScreenRecording() { openScreenRecordingSettings() }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.preference.notifications")
    }

    static func notificationsAuthorized(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
