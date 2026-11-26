import Foundation
import CryptoKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Frame kinds on the wire: [kind][AES-GCM sealed box]. The relay only looks at the kind.
enum RemoteKind: UInt8 {
    case control = 0x01
    case video = 0x02
    case status = 0x03
}

/// End-to-end encryption between Mac and iPhone. The key never leaves the two devices
/// (it travels inside the pairing QR code), so the relay server cannot read anything.
struct RemoteCrypto {
    let key: SymmetricKey

    func seal(_ kind: RemoteKind, _ payload: Data) -> Data? {
        guard let box = try? AES.GCM.seal(payload, using: key), let combined = box.combined else { return nil }
        var out = Data(capacity: combined.count + 1)
        out.append(kind.rawValue)
        out.append(combined)
        return out
    }

    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

/// Remote settings (server, password) plus the device identity and secret key.
@MainActor
final class RemoteConfig: ObservableObject {
    static let shared = RemoteConfig()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "remote.enabled") } }
    @Published var serverURL: String { didSet { d.set(serverURL, forKey: "remote.server") } }
    @Published var serverPassword: String { didSet { d.set(serverPassword, forKey: "remote.password") } }
    @Published var computerName: String { didSet { d.set(computerName, forKey: "remote.name") } }
    @Published var allowControl: Bool { didSet { d.set(allowControl, forKey: "remote.allowControl") } }
    @Published var allowUnlock: Bool { didSet { d.set(allowUnlock, forKey: "remote.allowUnlock") } }
    @Published var uploadEnabled: Bool { didSet { d.set(uploadEnabled, forKey: "remote.uploadEnabled") } }
    @Published var autoUpload: Bool { didSet { d.set(autoUpload, forKey: "remote.autoUpload") } }
    @Published var copyLinkAfterUpload: Bool { didSet { d.set(copyLinkAfterUpload, forKey: "remote.copyLink") } }
    @Published private(set) var macID: String
    @Published private(set) var keyData: Data

    private static var keyFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SimplexSuite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("remote-key")
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["remote.enabled": false, "remote.allowControl": true, "remote.allowUnlock": true,
                              "remote.uploadEnabled": true, "remote.autoUpload": false, "remote.copyLink": true])
        uploadEnabled = d.bool(forKey: "remote.uploadEnabled")
        autoUpload = d.bool(forKey: "remote.autoUpload")
        copyLinkAfterUpload = d.bool(forKey: "remote.copyLink")
        enabled = d.bool(forKey: "remote.enabled")
        serverURL = d.string(forKey: "remote.server") ?? ""
        serverPassword = d.string(forKey: "remote.password") ?? ""
        computerName = d.string(forKey: "remote.name") ?? (Host.current().localizedName ?? "Mac")
        allowControl = d.bool(forKey: "remote.allowControl")
        allowUnlock = d.bool(forKey: "remote.allowUnlock")
        if let id = d.string(forKey: "remote.macID") {
            macID = id
        } else {
            let id = UUID().uuidString
            d.set(id, forKey: "remote.macID")
            macID = id
        }
        if let data = try? Data(contentsOf: Self.keyFile), data.count == 32 {
            keyData = data
        } else {
            keyData = Self.generateKey()
        }
    }

    private static func generateKey() -> Data {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? data.write(to: keyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return data
    }

    /// New key: every paired iPhone has to scan the QR code again.
    func regenerateKey() {
        keyData = Self.generateKey()
    }

    var crypto: RemoteCrypto { RemoteCrypto(key: SymmetricKey(data: keyData)) }

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !serverPassword.isEmpty }

    /// https://example.com (for the clip API).
    var httpBaseURL: URL? {
        var raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw) else { return nil }
        switch comps.scheme?.lowercased() {
        case "http", "ws": comps.scheme = "http"
        default: comps.scheme = "https"
        }
        comps.path = ""
        return comps.url
    }

    /// https://example.com → wss://example.com/ws (keeps a custom port/path).
    var webSocketURL: URL? {
        var raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw) else { return nil }
        switch comps.scheme?.lowercased() {
        case "http", "ws": comps.scheme = "ws"
        default: comps.scheme = "wss"
        }
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/ws" }
        return comps.url
    }

    /// Everything the iPhone needs, as a link (also encoded in the QR code).
    var pairingLink: String {
        let payload: [String: String] = [
            "s": serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "p": serverPassword,
            "m": macID,
            "k": keyData.base64EncodedString(),
            "n": computerName,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "simplexremote://pair?d=\(b64)"
    }

    func qrImage(size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(pairingLink.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
