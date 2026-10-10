import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The "hands and eyes": screenshots, mouse and keyboard.
final class Computer {
    static let shared = Computer()

    /// Multiply a screenshot pixel coordinate by this to get a screen point.
    private(set) var scale: Double = 1
    private(set) var shotSize = CGSize(width: 1366, height: 854)

    // MARK: Screenshot

    enum ShotError: LocalizedError {
        case noDisplay, encode
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display found"
            case .encode: return "Couldn't encode the screenshot"
            }
        }
    }

    /// Long edge of the screenshot sent to the AI (keeps it fast and inside the API limits).
    static let maxLongEdge: Double = 1366

    static func targetSize(points: CGSize) -> CGSize {
        let long = max(points.width, points.height)
        let s = min(1.0, maxLongEdge / long)
        return CGSize(width: (points.width * s).rounded(), height: (points.height * s).rounded())
    }

    /// Captures the main display, hiding Flow Command's own windows. Returns JPEG data.
    func screenshot() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw ShotError.noDisplay }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let points = CGSize(width: display.width, height: display.height)
        let target = Computer.targetSize(points: points)
        let config = SCStreamConfiguration()
        config.width = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        scale = Double(points.width) / Double(target.width)
        shotSize = target
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw ShotError.encode }
        return data
    }

    func toScreen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }

    // MARK: Mouse

    func currentMouse() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
    }

    func click(at p: CGPoint?, button: CGMouseButton = .left, count: Int = 1, flags: CGEventFlags = []) {
        let point = p ?? currentMouse()
        if p != nil { move(to: point) }
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .right: return (.rightMouseDown, .rightMouseUp)
            case .center: return (.otherMouseDown, .otherMouseUp)
            default: return (.leftMouseDown, .leftMouseUp)
            }
        }()
        for i in 1...max(1, count) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.flags = flags
                e.post(tap: .cghidEventTap)
                usleep(15_000)
            }
        }
    }

    func mouseButton(down: Bool) {
        let p = currentMouse()
        CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func drag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags = []) {
        move(to: a)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?.post(tap: .cghidEventTap)
        let steps = 12
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func scroll(direction: String, amount: Int, at p: CGPoint?) {
        if let p = p { move(to: p) }
        let lines = Int32(max(1, amount) * 3)
        var dy: Int32 = 0, dx: Int32 = 0
        switch direction {
        case "up": dy = lines
        case "down": dy = -lines
        case "left": dx = lines
        case "right": dx = -lines
        default: break
        }
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
            "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, "backspace": 51,
            "delete": 117, "forwarddelete": 117, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "page_up": 116, "pageup": 116, "prior": 116,
            "page_down": 121, "pagedown": 121, "next": 121,
            "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44, "semicolon": 41,
            "apostrophe": 39, "bracketleft": 33, "bracketright": 30, "backslash": 42, "grave": 50,
            "shift": 56, "ctrl": 59, "control": 59, "alt": 58, "option": 58, "cmd": 55, "command": 55,
            "super": 55, "meta": 55, "fn": 63, "capslock": 57,
        ]
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fkeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()

    /// Turns "cmd+shift+t" or "ctrl+c" into modifier flags; returns nil for unknown modifier names.
    static func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "cmd", "command", "super", "meta", "win": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "alt", "option", "opt": return .maskAlternate
        case "shift": return .maskShift
        case "fn": return .maskSecondaryFn
        default: return nil
        }
    }

    static func flags(from text: String?) -> CGEventFlags {
        guard let text = text, !text.isEmpty else { return [] }
        var f: CGEventFlags = []
        for p in text.split(separator: "+") { if let m = modifierFlag(String(p)) { f.insert(m) } }
        return f
    }

    enum KeyError: LocalizedError {
        case unknown(String)
        var errorDescription: String? { if case .unknown(let k) = self { return "Unknown key: \(k)" }; return nil }
    }

    /// Parses "ctrl+shift+Tab" style text into (keyCode, flags).
    static func parseCombo(_ text: String) throws -> (CGKeyCode, CGEventFlags) {
        let parts = text.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { throw KeyError.unknown(text) }
        var flags: CGEventFlags = []
        for p in parts.dropLast() {
            guard let m = modifierFlag(p) else { throw KeyError.unknown(p) }
            flags.insert(m)
        }
        guard let code = keyCodes[last.lowercased()] else { throw KeyError.unknown(last) }
        return (code, flags)
    }

    func press(_ combo: String, repeatCount: Int = 1) throws {
        let (code, flags) = try Computer.parseCombo(combo)
        for _ in 0..<max(1, min(repeatCount, 100)) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
                usleep(12_000)
            }
            usleep(25_000)
        }
    }

    func hold(_ combo: String, seconds: Double) throws {
        let (code, flags) = try Computer.parseCombo(combo)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(useconds_t(min(max(seconds, 0), 10) * 1_000_000))
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    /// Types any text (including emoji and accents) without depending on the keyboard layout.
    func type(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let end = min(start + 20, units.count)
                var chunk = Array(units[start..<end])
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(8_000)
                start = end
            }
            if i < lines.count - 1 { try? press("Return") }
        }
    }

    // MARK: Apps and websites (no screen reading needed)

    static func findApp(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let aliases = ["chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code"]
        let target = aliases[wanted] ?? wanted
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                if item.dropLast(4).lowercased() == target { return URL(fileURLWithPath: dir).appendingPathComponent(item) }
            }
        }
        return nil
    }

    @discardableResult
    func openApp(_ name: String) -> Bool {
        guard let url = Computer.findApp(named: name) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return true
    }

    static func normalizeURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    @discardableResult
    func openURL(_ raw: String, browser: String? = nil) -> Bool {
        guard let url = Computer.normalizeURL(raw) else { return false }
        if let browser = browser, let app = Computer.findApp(named: browser) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
