import Foundation
import CryptoKit
import Security
import LocalAuthentication

// MARK: - Pairing

struct PairedMac: Codable, Identifiable, Hashable {
    let id: String          // mac id
    var name: String
    var server: String
    var addedAt: Date = Date()

    var serverKey: String { server.lowercased() }
}

struct PairingPayload {
    let server: String
    let password: String
    let macID: String
    let key: Data
    let name: String

    /// Parses "simplexremote://pair?d=<base64url json>" (also accepts the raw base64 part).
    init?(link: String) {
        var raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: raw), let d = comps.queryItems?.first(where: { $0.name == "d" })?.value {
            raw = d
        }
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        guard let data = Data(base64Encoded: raw),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let server = json["s"], let password = json["p"], let mac = json["m"],
              let keyB64 = json["k"], let key = Data(base64Encoded: keyB64), key.count == 32 else { return nil }
        self.server = server
        self.password = password
        self.macID = mac
        self.key = key
        self.name = json["n"] ?? "Mac"
    }
}

// MARK: - Live status

struct AppUsage: Identifiable, Hashable {
    let pid: Int
    let name: String
    let bundle: String
    let cpu: Double
    let mem: Double
    let isProtected: Bool
    var id: Int { pid }
}

struct MacStatus {
    var name = ""
    var model = ""
    var os = ""
    var uptime = 0
    var cpu = 0.0
    var mem = 0.0
    var memTotal = 1.0
    var temp: Double?
    var thermal = ""
    var diskFree = 0.0
    var diskTotal = 1.0
    var battery: Int?
    var charging = false
    var locked = false
    var clipping = false
    var clipStatus = ""
    var game: String?
    var streaming = false
    var control = true
    var virtualDisplays = false
    var version = ""
    var apps: [AppUsage] = []
    var receivedAt = Date()

    init() {}

    init(json: [String: Any]) {
        func d(_ k: String) -> Double { (json[k] as? NSNumber)?.doubleValue ?? 0 }
        name = json["name"] as? String ?? ""
        model = json["model"] as? String ?? ""
        os = json["os"] as? String ?? ""
        uptime = Int(d("uptime"))
        cpu = d("cpu")
        mem = d("mem")
        memTotal = max(1, d("memTotal"))
        temp = (json["temp"] as? NSNumber)?.doubleValue
        thermal = json["thermal"] as? String ?? ""
        diskFree = d("diskFree")
        diskTotal = max(1, d("diskTotal"))
        battery = (json["battery"] as? NSNumber)?.intValue
        charging = json["charging"] as? Bool ?? false
        locked = json["locked"] as? Bool ?? false
        clipping = json["clipping"] as? Bool ?? false
        clipStatus = json["clipStatus"] as? String ?? ""
        game = json["game"] as? String
        streaming = json["streaming"] as? Bool ?? false
        control = json["control"] as? Bool ?? true
        virtualDisplays = json["virtualDisplays"] as? Bool ?? false
        version = json["version"] as? String ?? ""
        apps = (json["apps"] as? [[String: Any]] ?? []).map {
            AppUsage(pid: ($0["pid"] as? NSNumber)?.intValue ?? 0,
                     name: $0["name"] as? String ?? "",
                     bundle: $0["bundle"] as? String ?? "",
                     cpu: ($0["cpu"] as? NSNumber)?.doubleValue ?? 0,
                     mem: ($0["mem"] as? NSNumber)?.doubleValue ?? 0,
                     isProtected: $0["protected"] as? Bool ?? false)
        }
    }

    var memFraction: Double { mem / memTotal }
    var diskUsedFraction: Double { 1 - diskFree / diskTotal }

    var uptimeText: String {
        let days = uptime / 86_400, hours = (uptime % 86_400) / 3600, minutes = (uptime % 3600) / 60
        if days > 0 { return "\(days) T \(hours) Std" }
        if hours > 0 { return "\(hours) Std \(minutes) Min" }
        return "\(minutes) Min"
    }

    var temperatureText: String {
        if let temp { return "\(Int(temp.rounded()))°" }
        return thermal.isEmpty ? "–" : thermal
    }
}

struct Presence {
    var online = false
    var since: Date?
    var lastSeen: Date?
}

// MARK: - Quick actions

enum QuickAction: String, CaseIterable, Identifiable, Codable {
    case quitAll, saveClip, screenshot, lock, displayOff, playPause, volUp, volDown, mute,
         missionControl, launcher, spotlight, appSwitcher, copy, paste, undo, closeWindow,
         quitFrontApp, maximize, longClip, togglePause, sleep, restart, shutdown, next, previous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quitAll: return "Alle Apps beenden"
        case .saveClip: return "Clip speichern"
        case .longClip: return "Langer Clip"
        case .screenshot: return "Screenshot"
        case .lock: return "Sperren"
        case .displayOff: return "Display aus"
        case .playPause: return "Play/Pause"
        case .next: return "Weiter"
        case .previous: return "Zurück"
        case .volUp: return "Lauter"
        case .volDown: return "Leiser"
        case .mute: return "Stumm"
        case .missionControl: return "Mission Control"
        case .launcher: return "App-Starter"
        case .spotlight: return "Spotlight"
        case .appSwitcher: return "App wechseln"
        case .copy: return "Kopieren"
        case .paste: return "Einfügen"
        case .undo: return "Rückgängig"
        case .closeWindow: return "Fenster schließen"
        case .quitFrontApp: return "App beenden"
        case .maximize: return "Fenster füllen"
        case .togglePause: return "Clipping an/aus"
        case .sleep: return "Ruhezustand"
        case .restart: return "Neustart"
        case .shutdown: return "Ausschalten"
        }
    }

    var symbol: String {
        switch self {
        case .quitAll: return "xmark.circle.fill"
        case .saveClip: return "scissors"
        case .longClip: return "film"
        case .screenshot: return "camera.fill"
        case .lock: return "lock.fill"
        case .displayOff: return "display"
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .previous: return "backward.fill"
        case .volUp: return "speaker.wave.3.fill"
        case .volDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .missionControl: return "rectangle.3.group"
        case .launcher: return "square.grid.3x3.fill"
        case .spotlight: return "magnifyingglass"
        case .appSwitcher: return "square.on.square"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .undo: return "arrow.uturn.backward"
        case .closeWindow: return "macwindow.badge.plus"
        case .quitFrontApp: return "xmark.app"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .togglePause: return "record.circle"
        case .sleep: return "moon.zzz.fill"
        case .restart: return "arrow.clockwise"
        case .shutdown: return "power"
        }
    }

    var needsConfirmation: Bool { [.quitAll, .restart, .shutdown, .sleep].contains(self) }
    var isDestructive: Bool { [.quitAll, .restart, .shutdown, .quitFrontApp].contains(self) }

    static let defaultSelection: [QuickAction] = [
        .quitAll, .saveClip, .screenshot, .launcher, .missionControl, .playPause, .volUp, .volDown, .lock, .copy, .paste,
    ]
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.simplex.remote"

    static func set(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    // Mac login password, protected by Face ID.
    private static func unlockAccount(_ macID: String) -> String { "unlock-\(macID)" }

    static func saveUnlockPassword(_ password: String, macID: String) -> Bool {
        delete(unlockAccount(macID))
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: unlockAccount(macID),
                                    kSecAttrAccessControl as String: access,
                                    kSecValueData as String: Data(password.utf8)]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func hasUnlockPassword(macID: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: unlockAccount(macID),
                                    kSecUseAuthenticationContext as String: context]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Triggers Face ID.
    static func loadUnlockPassword(macID: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = "Mac entsperren"
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                            kSecAttrService as String: service,
                                            kSecAttrAccount as String: unlockAccount(macID),
                                            kSecReturnData as String: true,
                                            kSecUseAuthenticationContext as String: context]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess, let data = result as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func deleteUnlockPassword(macID: String) { delete(unlockAccount(macID)) }
}

// MARK: - Crypto (identical to the Mac side)

enum RemoteKind: UInt8 {
    case control = 0x01
    case video = 0x02
    case status = 0x03
}

struct RemoteCrypto {
    let key: SymmetricKey

    init(keyData: Data) { key = SymmetricKey(data: keyData) }

    func seal(_ kind: RemoteKind, _ payload: Data) -> Data? {
        guard let box = try? AES.GCM.seal(payload, using: key), let combined = box.combined else { return nil }
        var out = Data([kind.rawValue])
        out.append(combined)
        return out
    }

    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
