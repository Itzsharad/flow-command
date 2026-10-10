import Foundation

/// The free brain: Google's Gemini Flash through its OpenAI-compatible endpoint.
/// Each turn it sees the current screenshot and replies with ONE action as JSON.
struct GeminiClient {
    var apiKey: String
    var model: String

    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!

    enum GeminiError: LocalizedError {
        case http(Int, String)
        case badReply
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg):
                if code == 429 { return "The free AI limit is used up for the moment. Wait a minute and try again — or add a Claude key in Settings." }
                if code == 401 || code == 403 || msg.lowercased().contains("api key") { return "Your Google AI key was rejected. Check it in Settings." }
                if code == 404 { return "That Gemini model isn't available on your key. Pick another in Settings." }
                return "AI error \(code): \(msg)"
            case .badReply: return "The AI's reply didn't make sense. Try saying it a different way."
            }
        }
    }

    private func request(_ body: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        var req = URLRequest(url: GeminiClient.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
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
