import Foundation

/// Minimal client for the Anthropic Messages API with the computer-use toolset.
struct ClaudeClient {
    var apiKey: String
    var model: String

    enum APIError: LocalizedError {
        case http(Int, String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg):
                if code == 401 { return "Your Anthropic API key was rejected. Check it in Settings." }
                if code == 429 { return "The AI is busy (rate limit). Try again in a moment." }
                if code == 529 { return "The AI is overloaded right now. Try again shortly." }
                return "AI error \(code): \(msg)"
            case .badResponse: return "Unexpected reply from the AI."
            }
        }
    }

    static let computerToolset: [String: Any] = [
        "type": "computer_toolset_20260801",
        "configs": ["zoom": ["enabled": false]],
    ]

    static let customTools: [[String: Any]] = [
        [
            "name": "open_app",
            "description": "Open or switch to a Mac app by name (e.g. \"Google Chrome\", \"Safari\", \"Notes\"). Faster and more reliable than clicking the Dock.",
            "input_schema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "open_url",
            "description": "Open a website. Optionally name the browser (\"Google Chrome\", \"Safari\"); otherwise the default browser is used. Prefer this over typing into the address bar.",
            "input_schema": ["type": "object",
                             "properties": ["url": ["type": "string"], "browser": ["type": "string"]],
                             "required": ["url"]],
        ],
        [
            "name": "ask_user",
            "description": "Pause and ask the user. kind=\"confirm\": get a yes/no before a risky action (show exactly what will happen). kind=\"handoff\": the user must do something themselves (password, verification code, captcha, payment details, a choice only they can make); they will say continue when done.",
            "input_schema": ["type": "object",
                             "properties": ["kind": ["type": "string", "enum": ["confirm", "handoff"]],
                                            "message": ["type": "string"]],
                             "required": ["kind", "message"]],
        ],
    ]

    func send(system: String, messages: [[String: Any]]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "tools": [ClaudeClient.computerToolset] + ClaudeClient.customTools,
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.badResponse }
        guard code == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
            throw APIError.http(code, msg)
        }
        return json
    }

    /// Cheap check that a key works.
    static func verify(key: String, model: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return nil }
            if code == 401 { return "That key was rejected." }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((json?["error"] as? [String: Any])?["message"] as? String) ?? "Error \(code)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Building messages

    static func toolResult(id: String, text: String, isError: Bool = false, computer: Bool) -> [String: Any] {
        var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]
        if isError { r["is_error"] = true }
        if computer { r["toolset_name"] = "computer" }
        return r
    }

    static func imageResult(id: String, jpeg: Data) -> [String: Any] {
        [
            "type": "tool_result", "tool_use_id": id, "toolset_name": "computer",
            "content": [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                     "data": jpeg.base64EncodedString()]]],
        ]
    }

    /// Keeps only the newest `keep` screenshots in the history (older ones become a short note) so tasks stay fast and cheap.
    static func pruneImages(_ messages: [[String: Any]], keep: Int = 3) -> [[String: Any]] {
        var remaining = keep
        var out = messages
        for mi in stride(from: out.count - 1, through: 0, by: -1) {
            guard var content = out[mi]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for ci in stride(from: content.count - 1, through: 0, by: -1) {
                guard content[ci]["type"] as? String == "tool_result",
                      let inner = content[ci]["content"] as? [[String: Any]],
                      inner.contains(where: { $0["type"] as? String == "image" }) else { continue }
                if remaining > 0 {
                    remaining -= 1
                } else {
                    content[ci]["content"] = [["type": "text", "text": "[older screenshot removed]"]]
                    changed = true
                }
            }
            if changed { out[mi]["content"] = content }
        }
        return out
    }
}
