import AppKit
import AVFoundation
import Foundation
import Speech

/// A small private log on this Mac (~/Library/Logs/FlowCommand). Never contains what you said — only events.
/// "Copy diagnostics" in the menu bar puts it on the clipboard so it can be shared when something breaks.
enum Log {
    private static let queue = DispatchQueue(label: "fc.log")
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/FlowCommand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flowcommand.log")
    }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date()))  \(line)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
            // keep it small
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 300_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(150_000).write(to: url)
            }
        }
    }

    static func tail(_ lines: Int = 120) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "(no log yet)" }
        return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Everything useful for fixing a problem, as plain text.
    static func diagnostics() -> String {
        let s = AppSettings.shared, l = Listener.shared
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let input = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        var out = [
            "Flow Command diagnostics",
            "app \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "mic permission: \(mic.rawValue) (3 = allowed) · speech permission: \(speech.rawValue) (3 = allowed)",
            "control permission: \(Permissions.control) · screen: \(Permissions.screen)",
            "microphone: \(input)",
            "speech: available \(rec?.isAvailable ?? false), on-device \(rec?.supportsOnDeviceRecognition ?? false)",
            "listener mode: \(l.mode) · problem: \(l.problem ?? "none")",
            "wake phrase on: \(s.wakeEnabled) · hold key on: \(s.holdKeyEnabled) (\(s.holdKey.label))",
            "whisper: \(s.whisperEnabled) · \(Transcriber.shared.state)",
            "plan: \(Account.shared.summary)",
            "---- recent events ----",
        ]
        out.append(tail())
        return out.joined(separator: "\n")
    }

    static func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }
}
