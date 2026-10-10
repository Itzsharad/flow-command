import Foundation

/// Simple instructions handled instantly on this Mac — no AI, no screenshots, nothing sent anywhere.
enum LocalIntent: Equatable {
    case openApp(String)
    case openURL(String)
    case search(String)
    case keys(String, label: String)
    case type(String)
    case scroll(String)
}

enum LocalIntents {
    static let sites: [String: String] = [
        "gmail": "mail.google.com", "google mail": "mail.google.com",
        "youtube": "youtube.com", "google": "google.com",
        "claude": "claude.ai", "claude ai": "claude.ai", "chatgpt": "chatgpt.com", "chat gpt": "chatgpt.com",
        "github": "github.com", "git hub": "github.com",
        "gohighlevel": "app.gohighlevel.com", "go high level": "app.gohighlevel.com",
        "high level": "app.gohighlevel.com", "ghl": "app.gohighlevel.com",
        "google drive": "drive.google.com", "drive": "drive.google.com",
        "google docs": "docs.google.com", "google sheets": "sheets.google.com",
        "google calendar": "calendar.google.com", "linkedin": "linkedin.com",
        "instagram": "instagram.com", "facebook": "facebook.com", "twitter": "x.com", "x": "x.com",
        "notion": "notion.so", "canva": "canva.com",
    ]

    static func clean(_ s: String) -> String {
        var t = s.lowercased()
        for ch in [",", "!", "?", ";", "\u{201C}", "\u{201D}", "\""] { t = t.replacingOccurrences(of: ch, with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .")).replacingOccurrences(of: "  ", with: " ")
        // spoken domains: "claude dot ai" -> "claude.ai"
        t = t.replacingOccurrences(of: " dot ", with: ".")
        for filler in ["please ", "can you ", "could you ", "hey "] where t.hasPrefix(filler) { t = String(t.dropFirst(filler.count)) }
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func looksLikeDomain(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return !s.contains(" ") && parts.count >= 2 && (parts.last?.count ?? 0) >= 2
    }

    /// Returns nil when the instruction needs the AI brain (anything multi-step or on-screen).
    static func parse(_ raw: String, appExists: (String) -> Bool = { Computer.findApp(named: $0) != nil }) -> LocalIntent? {
        let t = clean(raw)
        if t.isEmpty { return nil }
        // Anything with "and"/"then" is multi-step: let the AI handle it.
        if t.contains(" and ") || t.contains(" then ") { return nil }

        switch t {
        case "new tab", "open a new tab", "open new tab": return .keys("cmd+t", label: "New tab")
        case "close tab", "close this tab", "close the tab": return .keys("cmd+w", label: "Close tab")
        case "new window", "open a new window", "open new window": return .keys("cmd+n", label: "New window")
        case "press enter", "hit enter", "press return", "send it", "enter": return .keys("Return", label: "Press Enter")
        case "go back", "back": return .keys("cmd+[", label: "Go back")
        case "refresh", "reload", "refresh the page", "reload the page": return .keys("cmd+r", label: "Refresh")
        case "copy", "copy that", "copy this": return .keys("cmd+c", label: "Copy")
        case "paste", "paste that", "paste it": return .keys("cmd+v", label: "Paste")
        case "undo", "undo that": return .keys("cmd+z", label: "Undo")
        case "select all": return .keys("cmd+a", label: "Select all")
        case "scroll down", "scroll up": return .scroll(t == "scroll down" ? "down" : "up")
        default: break
        }

        for prefix in ["search google for ", "google search ", "search for ", "google "] where t.hasPrefix(prefix) {
            let query = String(t.dropFirst(prefix.count))
            return query.isEmpty ? nil : .search(query)
        }

        for prefix in ["type ", "write "] where t.hasPrefix(prefix) {
            // keep the user's original casing for typed text
            let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = original.range(of: prefix.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .anchored]) {
                let text = original[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
                return text.isEmpty ? nil : .type(text)
            }
        }

        for prefix in ["go to ", "open ", "launch ", "start ", "visit ", "switch to "] where t.hasPrefix(prefix) {
            var target = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            for suffix in [" app", " website", " site", " in chrome", " in safari"] where target.hasSuffix(suffix) {
                target = String(target.dropLast(suffix.count))
            }
            if target.hasPrefix("the ") { target = String(target.dropFirst(4)) }
            if target.isEmpty { return nil }
            if looksLikeDomain(target) { return .openURL(target) }
            if let site = sites[target] { return .openURL(site) }
            if prefix != "visit ", appExists(target) { return .openApp(target) }
            return nil
        }
        return nil
    }
}

/// Detects the wake phrase in speech, tolerating small mistakes ("flow commander activate").
enum WakeMatcher {
    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// If the phrase is in the text, returns the words spoken after it (possibly empty). Otherwise nil.
    static func match(_ text: String, phrase: String) -> [String]? {
        let t = words(text), p = words(phrase)
        guard !p.isEmpty, t.count >= p.count else { return nil }
        let target = p.joined(separator: " ")
        for start in 0...(t.count - p.count) {
            for extra in [0, 1] where start + p.count + extra <= t.count {
                let window = t[start..<(start + p.count + extra)].joined(separator: " ")
                let d = distance(window, target)
                if Double(d) <= max(2, Double(target.count) * 0.18) {
                    return Array(t[(start + p.count + extra)...])
                }
            }
        }
        return nil
    }

    static func isStop(_ text: String) -> Bool {
        let w = words(text)
        return w.contains("stop") || w.contains("cancel") || (w.contains("never") && w.contains("mind"))
    }

    static func isSleep(_ text: String) -> Bool {
        let t = words(text).joined(separator: " ")
        return t.contains("go to sleep") || (t.hasSuffix("sleep") && (t.contains("flow") || t.count < 12))
            || t.contains("that s all") || t.contains("thats all")
    }

    /// "No" always wins over "yes" ("no, don't send" must never count as approval).
    static func yesNo(_ text: String) -> Bool? {
        let w = words(text)
        if w.contains(where: { ["no", "nope", "don", "dont", "wait", "cancel", "stop", "not"].contains($0) }) { return false }
        if w.contains(where: { ["yes", "yeah", "yep", "sure", "ok", "okay", "continue", "done", "approve", "go"].contains($0) }) { return true }
        return nil
    }
}
