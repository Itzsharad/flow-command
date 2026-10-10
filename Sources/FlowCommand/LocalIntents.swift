import Foundation

/// Simple instructions handled instantly on this Mac — no AI, no screenshots, nothing sent anywhere.
enum LocalIntent: Equatable {
    case openApp(String)
    case openURL(String)
    case search(String)
    case keys(String, label: String)
    case type(String)
    case scroll(String)

    var label: String {
        switch self {
        case .openApp(let n): return "Opening \(n.capitalized)"
        case .openURL(let u): return "Going to \(u)"
        case .search(let q): return "Searching Google for “\(q)”"
        case .keys(_, let l): return l
        case .type(let t): return "Typing “\(t.prefix(40))\(t.count > 40 ? "…" : "")”"
        case .scroll(let d): return "Scrolling \(d)"
        }
    }
}

enum LocalIntents {
    static let sites: [String: String] = [
        "gmail": "mail.google.com", "google mail": "mail.google.com", "my email": "mail.google.com", "email": "mail.google.com",
        "youtube": "youtube.com", "google": "google.com",
        "claude": "claude.ai", "claude ai": "claude.ai", "cloud": "claude.ai", "clod": "claude.ai", "claud": "claude.ai",
        "chatgpt": "chatgpt.com", "chat gpt": "chatgpt.com", "gpt": "chatgpt.com",
        "github": "github.com", "git hub": "github.com",
        "gohighlevel": "app.gohighlevel.com", "go high level": "app.gohighlevel.com",
        "high level": "app.gohighlevel.com", "highlevel": "app.gohighlevel.com", "ghl": "app.gohighlevel.com", "my crm": "app.gohighlevel.com",
        "google drive": "drive.google.com", "drive": "drive.google.com",
        "google docs": "docs.google.com", "google sheets": "sheets.google.com",
        "google calendar": "calendar.google.com", "calendar": "calendar.google.com", "my calendar": "calendar.google.com",
        "linkedin": "linkedin.com", "instagram": "instagram.com", "facebook": "facebook.com",
        "twitter": "x.com", "x": "x.com", "notion": "notion.so", "canva": "canva.com", "whatsapp": "web.whatsapp.com",
        "new doc": "docs.new", "new google doc": "docs.new", "new sheet": "sheets.new", "new spreadsheet": "sheets.new",
    ]

    static func clean(_ s: String) -> String {
        var t = s.lowercased()
        for ch in [",", "!", "?", ";", "\u{201C}", "\u{201D}", "\""] { t = t.replacingOccurrences(of: ch, with: " ") }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // spoken domains: "claude dot ai" -> "claude.ai"
        t = t.replacingOccurrences(of: " dot ", with: ".")
        for filler in ["okay ", "ok ", "please ", "can you ", "could you ", "hey ", "now ", "and "] where t.hasPrefix(filler) {
            t = String(t.dropFirst(filler.count))
        }
        if t.hasSuffix(" please") { t = String(t.dropLast(7)) }
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func looksLikeDomain(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return !s.contains(" ") && parts.count >= 2 && (parts.last?.count ?? 0) >= 2
    }

    static let freeTextPrefixes = ["type ", "write ", "search google for ", "google search ", "search for ", "google "]

    /// A whole instruction: one step or several ("open chrome, go to claude.ai and type hello").
    /// Returns nil when any part needs the AI brain.
    static func parseChain(_ raw: String, appExists: (String) -> Bool = { Computer.findApp(named: $0) != nil }) -> [LocalIntent]? {
        if let one = parse(raw, appExists: appExists) { return [one] }
        var parts: [String] = []
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let seps = [", and then ", " and then ", ", then ", " then ", ", and ", " and ", ", "]
        while !rest.isEmpty && parts.count < 9 {
            let c = clean(rest)
            if freeTextPrefixes.contains(where: { c.hasPrefix($0) }) {
                // everything after "type …" is the text — except a trailing "and press enter"
                for tail in [" and press enter", " and hit enter", " and send it", " and send", " then press enter", ", press enter"] {
                    if let r = rest.range(of: tail, options: [.caseInsensitive, .backwards, .anchored]) {
                        parts.append(String(rest[..<r.lowerBound]))
                        parts.append("press enter")
                        rest = ""
                        break
                    }
                }
                if !rest.isEmpty { parts.append(rest); rest = "" }
                break
            }
            var best: Range<String.Index>?
            for sep in seps {
                if let r = rest.range(of: sep, options: .caseInsensitive), best == nil || r.lowerBound < best!.lowerBound { best = r }
            }
            guard let cut = best else { parts.append(rest); break }
            parts.append(String(rest[..<cut.lowerBound]))
            rest = String(rest[cut.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [LocalIntent] = []
        for p in parts {
            if let i = parse(p, appExists: appExists) { out.append(i); continue }
            // try splitting where a new command starts without "and"
            let pieces = verbSplit(p)
            guard pieces.count >= 2 else { return nil }
            for piece in pieces {
                guard let i = parse(piece, appExists: appExists) else { return nil }
                out.append(i)
            }
        }
        return out.count >= 2 ? out : nil
    }

    static let commandStarts = ["open ", "go to ", "click on ", "click ", "type ", "write ", "search for ", "search google for ",
                                "google ", "press ", "hit ", "new tab", "close tab", "launch ", "visit ", "scroll "]

    /// "go to the search box click claude ai" → ["go to the search box", "click claude ai"].
    /// Everything after "type"/"write"/"search" stays together (it's the text).
    static func verbSplit(_ raw: String) -> [String] {
        let lower = raw.lowercased()
        var cuts: [String.Index] = []
        for verb in commandStarts {
            var from = lower.index(after: lower.startIndex)
            while from < lower.endIndex, let r = lower.range(of: " " + verb, range: from..<lower.endIndex) {
                cuts.append(lower.index(after: r.lowerBound))
                from = r.upperBound
            }
        }
        let free = ["type ", "write ", "search for ", "search google for ", "google "]
        var pieces: [String] = []
        var start = raw.startIndex
        for cut in Set(cuts).sorted() where cut > start {
            let piece = String(raw[start..<cut]).trimmingCharacters(in: .whitespaces)
            if free.contains(where: { piece.lowercased().hasPrefix($0) }) { break }   // keep typed text whole
            // "open new tab" contains two starts ("open", "new tab") — don't leave a bare verb on its own
            if ["open", "go to", "click", "click on", "launch", "visit", "press", "hit"].contains(piece.lowercased()) { continue }
            pieces.append(piece)
            start = cut
        }
        pieces.append(String(raw[start...]).trimmingCharacters(in: .whitespaces))
        return pieces.filter { !$0.isEmpty }
    }

    /// One simple instruction, or nil.
    static func parse(_ raw: String, appExists: (String) -> Bool = { Computer.findApp(named: $0) != nil }) -> LocalIntent? {
        let t = clean(raw)
        if t.isEmpty { return nil }

        switch t {
        case "new tab", "open a new tab", "open new tab", "open tab": return .keys("cmd+t", label: "New tab")
        case "close tab", "close this tab", "close the tab": return .keys("cmd+w", label: "Close tab")
        case "new window", "open a new window", "open new window", "new chrome window", "open a new chrome window", "open new chrome window":
            return .keys("cmd+n", label: "New window")
        case "new incognito window", "open incognito", "open an incognito window", "incognito":
            return .keys("cmd+shift+n", label: "New incognito window")
        case "close window", "close this window", "close the window": return .keys("cmd+shift+w", label: "Close window")
        case "press enter", "hit enter", "press return", "send it", "send", "enter", "submit": return .keys("Return", label: "Press Enter")
        case "go back", "back": return .keys("cmd+[", label: "Go back")
        case "go forward", "forward": return .keys("cmd+]", label: "Go forward")
        case "refresh", "reload", "refresh the page", "reload the page", "refresh page": return .keys("cmd+r", label: "Refresh")
        case "copy", "copy that", "copy this": return .keys("cmd+c", label: "Copy")
        case "paste", "paste that", "paste it": return .keys("cmd+v", label: "Paste")
        case "undo", "undo that": return .keys("cmd+z", label: "Undo")
        case "select all": return .keys("cmd+a", label: "Select all")
        case "address bar", "go to the address bar", "go to address bar", "search bar", "go to the search bar", "click the search bar":
            return .keys("cmd+l", label: "Address bar")
        case "next tab", "switch tab": return .keys("ctrl+Tab", label: "Next tab")
        case "previous tab": return .keys("ctrl+shift+Tab", label: "Previous tab")
        case "scroll down", "scroll up": return .scroll(t == "scroll down" ? "down" : "up")
        default: break
        }

        // "go to the search box", "click the address bar", "search bar" … → focus the address bar
        let barWords = t.replacingOccurrences(of: "go to ", with: "").replacingOccurrences(of: "click on ", with: "")
            .replacingOccurrences(of: "click ", with: "").replacingOccurrences(of: "the ", with: "")
        if ["search box", "search bar", "search field", "address bar", "url bar", "address box", "url box"].contains(barWords) {
            return .keys("cmd+l", label: "Address bar")
        }

        // "click (on) Claude AI" — clicking a well-known site means opening it
        for prefix in ["click on ", "click "] where t.hasPrefix(prefix) {
            var target = String(t.dropFirst(prefix.count))
            if target.hasPrefix("the ") { target = String(target.dropFirst(4)) }
            if looksLikeDomain(target) { return .openURL(target) }
            if let site = sites[target] { return .openURL(site) }
            return nil
        }

        for prefix in ["search google for ", "google search ", "search for ", "google "] where t.hasPrefix(prefix) {
            let query = String(t.dropFirst(prefix.count))
            return query.isEmpty ? nil : .search(query)
        }

        for prefix in ["type ", "write "] where t.hasPrefix(prefix) {
            // keep the user's original casing for typed text
            let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = prefix.trimmingCharacters(in: .whitespaces)
            if let r = original.range(of: word, options: .caseInsensitive) {
                let text = original[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
                return text.isEmpty ? nil : .type(text)
            }
        }

        // Anything still containing "and"/"then" is multi-step: parseChain splits it, or the AI handles it.
        if t.contains(" and ") || t.contains(" then ") { return nil }

        for prefix in ["go to ", "open up ", "open ", "launch ", "start ", "visit ", "switch to ", "bring up ", "show me "] where t.hasPrefix(prefix) {
            var target = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            var wantsApp = false, wantsSite = false
            if target.hasPrefix("the ") { target = String(target.dropFirst(4)) }
            for suffix in [" desktop app", " app", " application"] where target.hasSuffix(suffix) {
                target = String(target.dropLast(suffix.count)); wantsApp = true
            }
            for suffix in [" website", " site", " web", " in chrome", " in safari", " in the browser", " on chrome"] where target.hasSuffix(suffix) {
                target = String(target.dropLast(suffix.count)); wantsSite = true
            }
            target = target.trimmingCharacters(in: .whitespaces)
            if target.isEmpty { return nil }
            if wantsApp, appExists(target) { return .openApp(target) }
            if looksLikeDomain(target) { return .openURL(target) }
            if let site = sites[target] { return .openURL(site) }
            if !wantsSite, prefix != "visit ", appExists(target) { return .openApp(target) }
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
