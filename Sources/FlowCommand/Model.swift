import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Colours (match the design)

enum Theme {
    static let accent = Color(hex: 0x5B3DF5)
    static let accentInk = Color(hex: 0x4A2FE0)
    static let accentSoft = Color(hex: 0xEEEBFF)
    static let ink = Color(hex: 0x17171C)
    static let muted = Color(hex: 0x55555F)
    static let faint = Color(hex: 0x6A6A75)
    static let rail = Color(hex: 0xF5F5F8)
    static let hairline = Color(hex: 0xE4E4EA)
    static let success = Color(hex: 0x1F8A4C)
    static let warn = Color(hex: 0xB4530A)
    static let danger = Color(hex: 0xE5484D)
    static let panel = Color(hex: 0x16161C)
    static let panelSoft = Color(hex: 0x24242E)
    static let panelText = Color(hex: 0xD9DAE6)
    static let violetLight = Color(hex: 0x8B74FF)
    static let green = Color(hex: 0x4ADE80)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Run on the main thread (all UI state changes go through this).
func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

// MARK: - Hold-to-talk key

/// Either one modifier key (e.g. right ⌘), several modifiers held together, or a normal key.
struct HotKeySpec: Codable, Equatable {
    enum Kind: String, Codable { case modifierKey, modifierCombo, key }
    var kind: Kind
    var keyCode: UInt16 = 0
    var modifiers: UInt = 0       // device-independent NSEvent modifier flags
    var label: String

    static let rightCommand = HotKeySpec(kind: .modifierKey, keyCode: 54, label: "right ⌘")
}

/// Device-dependent bits for telling left/right modifier keys apart.
enum ModifierKeys {
    static let deviceBit: [UInt16: UInt] = [
        54: 0x10, 55: 0x08,        // right / left command
        61: 0x40, 58: 0x20,        // right / left option
        62: 0x2000, 59: 0x01,      // right / left control
        60: 0x04, 56: 0x02,        // right / left shift
    ]
    static let names: [UInt16: String] = [
        54: "right ⌘", 55: "left ⌘", 61: "right ⌥", 58: "left ⌥",
        62: "right ⌃", 59: "left ⌃", 60: "right ⇧", 56: "left ⇧", 63: "fn",
    ]
    static let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    static func label(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("fn") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Settings (saved automatically)

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    @Published var onboardingStep: Int { didSet { d.set(onboardingStep, forKey: "setupStep") } }
    @Published var wakeEnabled: Bool { didSet { d.set(wakeEnabled, forKey: "wakeEnabled") } }
    @Published var wakePhrase: String { didSet { d.set(wakePhrase, forKey: "wakePhrase") } }
    @Published var holdKeyEnabled: Bool { didSet { d.set(holdKeyEnabled, forKey: "holdKeyEnabled") } }
    @Published var holdKey: HotKeySpec { didSet { save(holdKey, "holdKey") } }
    @Published var sleepAfter: Int { didSet { d.set(sleepAfter, forKey: "sleepAfter") } }   // seconds, 0 = never
    @Published var privateMode: Bool { didSet { d.set(privateMode, forKey: "privateMode") } }
    @Published var askBeforeSend: Bool { didSet { d.set(askBeforeSend, forKey: "askBeforeSend") } }
    @Published var askBeforePay: Bool { didSet { d.set(askBeforePay, forKey: "askBeforePay") } }
    @Published var askBeforeDelete: Bool { didSet { d.set(askBeforeDelete, forKey: "askBeforeDelete") } }
    @Published var askBeforePost: Bool { didSet { d.set(askBeforePost, forKey: "askBeforePost") } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    /// "gemini" (free) or "claude" (paid)
    @Published var brain: String { didSet { d.set(brain, forKey: "brain") } }
    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    /// App name used for websites ("" = system default browser)
    @Published var browser: String { didSet { d.set(browser, forKey: "browser") } }
    /// Whisper (accent-accurate, on this Mac) understands instructions; Apple's recogniser only listens for the wake phrase.
    @Published var whisperEnabled: Bool { didSet { d.set(whisperEnabled, forKey: "whisperEnabled") } }
    /// Saved voice shortcuts: say the phrase, the steps run.
    @Published var routines: [Routine] { didSet { save(routines, "routines") } }
    @Published var hasAPIKey: Bool = false
    @Published var hasGeminiKey: Bool = false

    init() {
        d.register(defaults: [
            "onboarded": false, "onboardingStep": 0, "wakeEnabled": true,
            "wakePhrase": "Flow Command, activate", "holdKeyEnabled": true, "sleepAfter": 30,
            "privateMode": false, "askBeforeSend": true, "askBeforePay": true,
            "askBeforeDelete": true, "askBeforePost": true, "sounds": true,
            "model": "claude-sonnet-5-5", "brain": "gemini", "geminiModel": "gemini-3.8-flash",
            "browser": Computer.findApp(named: "google chrome") != nil ? "Google Chrome" : "",
            "whisperEnabled": true,
        ])
        onboarded = d.bool(forKey: "onboarded")
        onboardingStep = d.integer(forKey: "setupStep")
        wakeEnabled = d.bool(forKey: "wakeEnabled")
        wakePhrase = d.string(forKey: "wakePhrase") ?? "Flow Command, activate"
        holdKeyEnabled = d.bool(forKey: "holdKeyEnabled")
        if let data = d.data(forKey: "holdKey"), let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            holdKey = spec
        } else {
            holdKey = .rightCommand
        }
        sleepAfter = d.integer(forKey: "sleepAfter")
        privateMode = d.bool(forKey: "privateMode")
        askBeforeSend = d.bool(forKey: "askBeforeSend")
        askBeforePay = d.bool(forKey: "askBeforePay")
        askBeforeDelete = d.bool(forKey: "askBeforeDelete")
        askBeforePost = d.bool(forKey: "askBeforePost")
        sounds = d.bool(forKey: "sounds")
        model = d.string(forKey: "model") ?? "claude-sonnet-5-5"
        brain = d.string(forKey: "brain") ?? "gemini"
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-3.8-flash"
        browser = d.string(forKey: "browser") ?? ""
        whisperEnabled = d.bool(forKey: "whisperEnabled")
        if let data = d.data(forKey: "routines"), let list = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = list
        } else {
            routines = Routine.examples
        }
        // Remember *whether* keys exist without reading the Keychain at every launch (which makes macOS ask).
        if d.object(forKey: "hasClaudeKey") == nil { d.set(!(Keychain.get("anthropic") ?? "").isEmpty, forKey: "hasClaudeKey") }
        if d.object(forKey: "hasGeminiKeyFlag") == nil { d.set(!(Keychain.get("gemini") ?? "").isEmpty, forKey: "hasGeminiKeyFlag") }
        hasAPIKey = d.bool(forKey: "hasClaudeKey")
        hasGeminiKey = d.bool(forKey: "hasGeminiKeyFlag")
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    var apiKey: String? {
        get { Keychain.get("anthropic") }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, account: "anthropic") } else { Keychain.delete("anthropic") }
            hasAPIKey = !(newValue ?? "").isEmpty
            d.set(hasAPIKey, forKey: "hasClaudeKey")
        }
    }

    var geminiKey: String? {
        get { Keychain.get("gemini") }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, account: "gemini") } else { Keychain.delete("gemini") }
            hasGeminiKey = !(newValue ?? "").isEmpty
            d.set(hasGeminiKey, forKey: "hasGeminiKeyFlag")
        }
    }

    /// The browser websites open in, if it's installed.
    var preferredBrowser: String? {
        browser.isEmpty || Computer.findApp(named: browser) == nil ? nil : browser
    }
}

// MARK: - Keychain (API key is stored here, never in plain files)

enum Keychain {
    static let service = "com.sharad.flowcommand"

    static func set(_ value: String, account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - History of tasks

struct TaskRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var instruction: String
    var outcome: String
    var ok: Bool
}

final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [TaskRecord] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowCommand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([TaskRecord].self, from: data) {
            items = list
        }
    }

    func add(_ r: TaskRecord) {
        onMain {
            self.items.insert(r, at: 0)
            if self.items.count > 200 { self.items.removeLast(self.items.count - 200) }
            if let data = try? JSONEncoder().encode(self.items) { try? data.write(to: self.url) }
        }
    }
}

// MARK: - Sounds

enum Sound {
    static func play(_ name: String) {
        guard AppSettings.shared.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
