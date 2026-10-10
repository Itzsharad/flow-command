import AppKit
import Foundation

/// `FlowCommand --selftest` — checks the logic that doesn't need a person at the Mac.
/// Run by the GitHub build before anything is published.
enum SelfTest {
    private static var failures: [String] = []

    private static func check(_ cond: Bool, _ name: String) {
        if !cond { failures.append(name) }
    }

    static func run() -> Int32 {
        let exists: (String) -> Bool = { ["safari", "google chrome", "chrome", "notes"].contains($0) }

        // Local intents
        check(LocalIntents.parse("Open Safari", appExists: exists) == .openApp("safari"), "open app")
        check(LocalIntents.parse("go to the chrome", appExists: exists) == .openApp("chrome"), "go to the chrome")
        check(LocalIntents.parse("Go to claude.ai", appExists: exists) == .openURL("claude.ai"), "domain")
        check(LocalIntents.parse("open claude dot ai", appExists: exists) == .openURL("claude.ai"), "spoken domain")
        check(LocalIntents.parse("open GoHighLevel", appExists: exists) == .openURL("app.gohighlevel.com"), "site name")
        check(LocalIntents.parse("Google best CRM for coaches", appExists: exists) == .search("best crm for coaches"), "search")
        check(LocalIntents.parse("Type Hello, see you Monday", appExists: exists) == .type("Hello, see you Monday"), "type keeps casing")
        check(LocalIntents.parse("new tab", appExists: exists) == .keys("cmd+t", label: "New tab"), "new tab")
        check(LocalIntents.parse("open chrome and go to claude.ai", appExists: exists) == nil, "multi-step goes to AI")
        check(LocalIntents.parse("open my crm thing", appExists: exists) == nil, "unknown app goes to AI")
        check(LocalIntents.parse("sign up on GitHub", appExists: exists) == nil, "task goes to AI")

        // Wake phrase
        check(WakeMatcher.match("flow command activate", phrase: "Flow Command, activate") == [], "wake exact")
        check(WakeMatcher.match("hey flow commander activate open chrome", phrase: "Flow Command, activate") == ["open", "chrome"], "wake fuzzy + carry")
        check(WakeMatcher.match("i was talking about the flow of water", phrase: "Flow Command, activate") == nil, "no false wake")
        check(WakeMatcher.match("activate", phrase: "Flow Command, activate") == nil, "partial phrase doesn't wake")

        // Yes / no — "no" must always win
        check(WakeMatcher.yesNo("yes go ahead") == true, "yes")
        check(WakeMatcher.yesNo("no don't send it") == false, "no wins")
        check(WakeMatcher.yesNo("yeah no wait") == false, "mixed is no")
        check(WakeMatcher.yesNo("hmm") == nil, "unclear")
        check(WakeMatcher.isStop("stop stop"), "stop word")
        check(!WakeMatcher.isStop("open the stopwatch"), "stopwatch isn't stop")

        // Keys
        if let (code, flags) = try? Computer.parseCombo("cmd+shift+t") {
            check(code == 17 && flags.contains(.maskCommand) && flags.contains(.maskShift), "combo cmd+shift+t")
        } else { check(false, "combo parse") }
        check((try? Computer.parseCombo("Return"))?.0 == 36, "Return key")
        check((try? Computer.parseCombo("ctrl+c"))?.1.contains(.maskControl) == true, "ctrl is control")
        check((try? Computer.parseCombo("hyper+x")) == nil, "unknown modifier rejected")

        // Screenshot sizing stays inside API limits
        let s = Computer.targetSize(points: CGSize(width: 1440, height: 900))
        check(s.width == 1366 && s.height <= 1366, "screenshot size")
        check(Computer.targetSize(points: CGSize(width: 1280, height: 800)) == CGSize(width: 1280, height: 800), "no upscale")

        // API message shapes
        let r = ClaudeClient.toolResult(id: "t1", text: "OK", computer: true)
        check(r["toolset_name"] as? String == "computer", "computer results carry toolset_name")
        check(ClaudeClient.toolResult(id: "t2", text: "OK", computer: false)["toolset_name"] == nil, "custom results don't")
        var msgs: [[String: Any]] = []
        for i in 0..<5 {
            msgs.append(["role": "user", "content": [ClaudeClient.imageResult(id: "i\(i)", jpeg: Data([1, 2, 3]))]])
        }
        let pruned = ClaudeClient.pruneImages(msgs, keep: 3)
        let imageCount = pruned.reduce(0) { n, m in
            n + ((m["content"] as? [[String: Any]])?.filter {
                (($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" }) ?? false
            }.count ?? 0)
        }
        check(imageCount == 3, "keeps newest 3 screenshots")
        check(JSONSerialization.isValidJSONObject(["tools": [ClaudeClient.computerToolset] + ClaudeClient.customTools]), "tools are valid JSON")

        // Hotkey settings round-trip
        let spec = HotKeySpec(kind: .key, keyCode: 96, modifiers: 0, label: "F5")
        let back = try? JSONDecoder().decode(HotKeySpec.self, from: JSONEncoder().encode(spec))
        check(back == spec, "hotkey saves")

        let out = failures.isEmpty ? "SELFTEST OK\n" : "SELFTEST FAILED: " + failures.joined(separator: ", ") + "\n"
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }
}
