import Foundation

/// Tiny append-only log at ~/Library/Logs/SimplexRecorder/recorder.log
/// (open it via Settings › Allgemein › Diagnose or the Console app).
enum DiagnosticsLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SimplexRecorder/recorder.log")
    }

    private static let queue = DispatchQueue(label: "com.simplex.recorder.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("SimplexRecorder: %@", message)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the file small: start over above 2 MB.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
