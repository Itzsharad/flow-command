import Foundation

/// The free brain: Google's Gemini Flash through its OpenAI-compatible endpoint.
/// Each turn it sees the current screenshot and replies with ONE action as JSON.
struct GeminiClient {
    var apiKey: String
    var model: String
    /// Either Google directly (your own key) or Flow Command's usage server (included AI).
    var url: URL = GeminiClient.endpoint
    var extraHeaders: [String: String] = [:]

    /// The included AI brain: goes through Flow Command's server, which counts tasks and holds the key.
    static func flowAI(task: String) -> GeminiClient? {
        guard let base = Account.serverURL else { return nil }
        return GeminiClient(apiKey: "", model: AppSettings.shared.geminiModel, url: base.appendingPathComponent("v1/ai"),
                            extraHeaders: ["X-FC-Device": Account.shared.deviceID, "X-FC-Task": task])
    }

    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!

    enum GeminiError: LocalizedError {
        case http(Int, String)
        case badReply
        case limit(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg):
                if code == 429 { return "The free AI limit is used up for the moment. Wait a minute and try again — or add a Claude key in Settings." }
                if code == 401 || code == 403 || msg.lowercased().contains("api key") { return "Your Google AI key was rejected. Check it in Settings." }
                if code == 404 { return "That Gemini model isn't available on your key. Pick another in Settings." }
                return "AI error \(code): \(msg)"
            case .badReply: return "The AI's reply didn't make sense. Try saying it a different way."
            case .limit(let m): return m
            }
        }
    }

    /// Sends a request. When Google says it's busy (503/500/429), waits and tries again,
    /// then switches to another Flash model that's available on the key — so a busy model doesn't stop the task.
    private func request(_ body: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        var models: [String] = [body["model"] as? String ?? model]
        var lastError: Error = GeminiError.badReply
        var triedFallbacks = false
        var i = 0
        while i < models.count {
            var b = body
            b["model"] = models[i]
            for attempt in 0..<3 {
                do {
                    let obj = try await send(b, timeout: timeout)
                    if i > 0 { Log.write("AI: \(models[0]) busy, used \(models[i])") }
                    return obj
                } catch GeminiError.http(let code, let msg) where [429, 500, 503].contains(code) {
                    lastError = GeminiError.http(code, msg)
                    Log.write("AI busy (\(code)) on \(models[i]), attempt \(attempt + 1)")
                    if Task.isCancelled { throw lastError }
                    try? await Task.sleep(nanoseconds: UInt64([1.2, 2.5, 0][attempt] * 1_000_000_000))
                } catch GeminiError.limit(let msg) where msg.contains("busy") {
                    lastError = GeminiError.limit(msg)
                    try? await Task.sleep(nanoseconds: UInt64([1.5, 3.0, 0][attempt] * 1_000_000_000))
                }
            }
            // still busy: try other Flash models on this key (only with your own key; the server picks its own)
            if !triedFallbacks, extraHeaders.isEmpty {
                triedFallbacks = true
                models += await GeminiClient.fallbackModels(key: apiKey, excluding: models[0])
            }
            i += 1
        }
        if case GeminiError.http(let code, _) = lastError, [429, 500, 503].contains(code) {
            throw GeminiError.limit(code == 429
                ? "Google's free AI limit is used up for the moment. Wait a minute and try again."
                : "Google's AI is very busy right now. I tried a few times and other models too. Try again in a minute.")
        }
        throw lastError
    }

    private static var cachedFallbacks: [String]?
    /// Other Flash models this key can use, newest first (asked from Google once).
    static func fallbackModels(key: String, excluding: String) async -> [String] {
        if let c = cachedFallbacks { return c.filter { $0 != excluding } }
        var found: [String] = []
        if let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                found = list.compactMap { ($0["id"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                    .filter { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("audio") && !$0.contains("live") }
                    .sorted(by: >)
            }
        }
        if found.isEmpty { found = ["gemini-flash-latest", "gemini-flash-lite-latest"] }
        cachedFallbacks = Array(found.prefix(3))
        return cachedFallbacks!.filter { $0 != excluding }
    }

    private func send(_ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        if !extraHeaders.isEmpty, let h = http { Account.shared.update(from: h) }
        if !extraHeaders.isEmpty, code != 200 {
            // Flow Command's server explains itself in plain words
            let msg = GeminiClient.errorMessage(json)
            if code == 402 { throw GeminiError.limit(msg) }
            throw GeminiError.limit(msg == "unknown" ? "The AI had a problem. Try again." : msg)
        }
        guard code == 200, let obj = json as? [String: Any] else {
            throw GeminiError.http(code, GeminiClient.errorMessage(json))
        }
        return obj
    }

    static func errorMessage(_ json: Any?) -> String {
        if let d = json as? [String: Any], let e = d["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let a = json as? [[String: Any]], let e = a.first?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return "unknown"
    }

    static func replyText(_ obj: [String: Any]) -> String? {
        guard let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    /// Pulls the first {...} object out of a reply (tolerates ```json fences and chatter).
    static func parseAction(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["action"] is String else { return nil }
        return obj
    }

    func nextAction(system: String, text: String, jpeg: Data) async throws -> [String: Any] {
        func body(_ extra: String) -> [String: Any] {
            [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": [
                        ["type": "text", "text": text + extra],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                    ]],
                ],
            ]
        }
        for attempt in 0..<2 {
            let obj = try await request(body(attempt == 0 ? "" : "\n\nIMPORTANT: reply with ONLY one JSON object."))
            if let t = GeminiClient.replyText(obj), let action = GeminiClient.parseAction(t) { return action }
        }
        throw GeminiError.badReply
    }

    /// Text-only turn for driving a web page from its element list (no screenshot, ~1 second).
    func nextPageAction(system: String, text: String) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let obj = try await request([
                "model": model, "temperature": 0.1, "max_tokens": 1000,
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": text + (attempt == 0 ? "" : "\n\nIMPORTANT: reply with ONLY one JSON object.")]],
            ], timeout: 30)
            if let t = GeminiClient.replyText(obj), let action = GeminiClient.parseAction(t) { return action }
        }
        throw GeminiError.badReply
    }

    /// Fast path (~1 second, text only, no screenshot): turn a spoken instruction into simple steps
    /// the Mac can run instantly. Returns nil steps when the task truly needs to look at the screen.
    func plan(_ instruction: String) async throws -> [[String: Any]]? {
        let system = """
        You turn a spoken Mac instruction into simple steps, when that's possible WITHOUT looking at the screen.
        The text is speech-to-text: fix obvious mistakes ("cloud"/"clod" usually means Claude → claude.ai).
        Step actions:
        - {"action":"open_app","app":"Google Chrome"}
        - {"action":"open_url","url":"claude.ai"}          (opens a website in the browser — use this for "click X" when X is a website)
        - {"action":"keys","keys":"cmd+t"}                  (macOS shortcuts: cmd+t new tab, cmd+n new window, cmd+w close tab, cmd+l address bar, cmd+r reload, Return)
        - {"action":"type","text":"…"}                      (types into whatever is focused)
        - {"action":"search","query":"…"}                    (Google search)
        - {"action":"click","text":"Sign up"}               (clicks a button or link on the current WEB PAGE by its exact visible text)
        Reply with ONLY JSON: {"needs_screen": false, "steps": [ … ]}
        Use click only when you're confident of the button's text (like "Sign up", "Log in", "New chat", "Compose").
        If doing it needs to read or choose something on the page (picking an item, filling a form, switching accounts), or needs clicks outside a web page, reply {"needs_screen": true, "steps": []}.
        """
        let obj = try await request([
            "model": model, "temperature": 0, "max_tokens": 500,
            "messages": [["role": "system", "content": system], ["role": "user", "content": instruction]],
        ], timeout: 20)
        guard let text = GeminiClient.replyText(obj),
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (json["needs_screen"] as? Bool) == true { return nil }
        let steps = json["steps"] as? [[String: Any]] ?? []
        return steps.isEmpty ? nil : steps
    }

    /// Converts planned steps into local actions; nil if anything is unknown.
    static func localIntents(from steps: [[String: Any]]) -> [LocalIntent]? {
        var out: [LocalIntent] = []
        for st in steps {
            switch st["action"] as? String ?? "" {
            case "open_app":
                guard let a = st["app"] as? String, Computer.findApp(named: a) != nil else { return nil }
                out.append(.openApp(a))
            case "open_url":
                guard let u = st["url"] as? String, Computer.normalizeURL(u) != nil else { return nil }
                out.append(.openURL(u.replacingOccurrences(of: "https://", with: "")))
            case "keys":
                guard let k = st["keys"] as? String, (try? Computer.parseCombo(k)) != nil else { return nil }
                out.append(.keys(k, label: "Pressing \(k)"))
            case "type":
                guard let t = st["text"] as? String, !t.isEmpty else { return nil }
                out.append(.type(t))
            case "search":
                guard let q = st["query"] as? String, !q.isEmpty else { return nil }
                out.append(.search(q))
            case "click":
                guard let t = st["text"] as? String, !t.isEmpty else { return nil }
                out.append(.click(t))
            default:
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    static func verify(key: String, model: String) async -> String? {
        let c = GeminiClient(apiKey: key, model: model)
        do {
            _ = try await c.request(["model": model, "max_tokens": 5,
                                     "messages": [["role": "user", "content": "Reply with OK"]]], timeout: 30)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
