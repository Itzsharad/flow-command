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
        let exists: (String) -> Bool = { ["safari", "google chrome", "chrome", "notes", "claude"].contains($0) }

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

        // Websites vs apps, and chains that run without any AI
        check(LocalIntents.parse("open Claude", appExists: exists) == .openURL("claude.ai"), "claude opens the website")
        check(LocalIntents.parse("open cloud", appExists: exists) == .openURL("claude.ai"), "misheard cloud = claude")
        check(LocalIntents.parse("open the Claude app", appExists: exists) == .openApp("claude"), "claude app opens the app")
        check(LocalIntents.parseChain("Open Chrome, go to claude.ai, type Hello there and press enter", appExists: exists) ==
              [.openApp("chrome"), .openURL("claude.ai"), .type("Hello there"), .keys("Return", label: "Press Enter")], "chain")
        check(LocalIntents.parseChain("open chrome and open a new tab", appExists: exists) ==
              [.openApp("chrome"), .keys("cmd+t", label: "New tab")], "chain with and")
        check(LocalIntents.parseChain("type milk and eggs", appExists: exists) == [.type("milk and eggs")], "typed text keeps its 'and'")
        check(LocalIntents.parseChain("open GoHighLevel and switch to the Attractclient account", appExists: exists) == nil, "screen task goes to AI")

        // Free brain replies
        check(GeminiClient.parseAction("```json\n{\"action\": \"click\", \"x\": 500, \"y\": 250}\n```")?["action"] as? String == "click", "gemini json in fences")
        check(GeminiClient.parseAction("I think we should click") == nil, "gemini non-json rejected")
        let p = Computer.shared.fromNormalized(500, 500)
        check(abs(p.x - 683) < 1 && abs(p.y - 427) < 1, "0-1000 coordinates map to the screen")

        // Natural phrasing without "and"
        check(LocalIntents.parse("go to the search box", appExists: exists) == .keys("cmd+l", label: "Address bar"), "search box")
        check(LocalIntents.parse("click Claude AI", appExists: exists) == .openURL("claude.ai"), "click a site")
        check(LocalIntents.parseChain("go to the search box click claude AI", appExists: exists) ==
              [.keys("cmd+l", label: "Address bar"), .openURL("claude.ai")], "chain without and")
        check(LocalIntents.parseChain("open chrome open new tab type hello world", appExists: exists) ==
              [.openApp("chrome"), .keys("cmd+t", label: "New tab"), .type("hello world")], "spoken chain")

        // Waits longer when you pause mid-sentence
        check(Listener.pauseNeeded(after: "go to the search bar and") > 3, "waits after 'and'")
        check(Listener.pauseNeeded(after: "open chrome") < 2, "normal pause")

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

        // Click by text on web pages
        check(LocalIntents.parse("click sign up", appExists: exists) == .click("sign up"), "click by text")
        check(LocalIntents.parse("click on the Contacts tab", appExists: exists) == .click("contacts"), "click strips 'the' and 'tab'")
        check(LocalIntents.parse("click sign up and type hello", appExists: exists) == nil, "click with 'and' isn't one step")
        check(LocalIntents.parseChain("go to github.com and click sign up", appExists: exists) ==
              [.openURL("github.com"), .click("sign up")], "open then click")
        check(GeminiClient.localIntents(from: [["action": "click", "text": "New chat"]]) == [.click("New chat")], "planner click")
        let els = [
            Browser.Element(id: 0, kind: "a", text: "Sign in", value: "", inView: true),
            Browser.Element(id: 1, kind: "a", text: "Sign up for GitHub", value: "", inView: false),
            Browser.Element(id: 2, kind: "button", text: "Sign up", value: "", inView: true),
            Browser.Element(id: 3, kind: "input:email", text: "Email address", value: "", inView: true),
        ]
        check(Browser.bestMatch("sign up", in: els)?.id == 2, "best match exact")
        check(Browser.bestMatch("email", in: els)?.id == 3, "best match field")
        check(Browser.bestMatch("checkout", in: els) == nil, "no match")
        check(Browser.appleScriptString("say \"hi\" \\n") == "\"say \\\"hi\\\" \\\\n\"", "applescript escaping")
        check(Browser.describe(Browser.Page(title: "T", url: "u", elements: [els[2]])).contains("[2] button \"Sign up\""), "page outline text")

        // Routines
        let routines = [Routine(phrase: "morning setup", steps: "open gmail"), Routine(phrase: "new chat", steps: "open claude.ai")]
        check(Routine.match("morning setup", in: routines)?.phrase == "morning setup", "routine exact")
        check(Routine.match("run my morning set up routine", in: routines)?.phrase == "morning setup", "routine fuzzy")
        check(Routine.match("open morning news", in: routines) == nil, "routine no false match")

        // Whisper text clean-up
        check(Transcriber.tidy(" Open Chrome and go to claude.ai.") == "Open Chrome and go to claude.ai", "whisper trailing period")
        check(Transcriber.tidy("[BLANK_AUDIO]") == nil, "whisper blank")
        check(Transcriber.tidy("Thank you.") == nil, "whisper silence phrase")
        check(Listener.dropWakePhrase("Flow Command, activate. Open Chrome", phrase: "Flow Command, activate") == "Open Chrome", "drop wake phrase")
        check(Listener.dropWakePhrase("Open Chrome", phrase: "Flow Command, activate") == "Open Chrome", "no wake phrase to drop")

        // Pop-up styles
        check(PanelHTML.styles.count >= 20, "all buddies and worlds listed")
        check(PanelHTML.styles.contains { $0.key == "galaxy" && $0.group == "world" }, "galaxy is a world")
        check(PanelHTML.styles.contains { $0.key == "kitty" && $0.group == "walk" }, "kitty is a buddy")
        let page = PanelHTML.page(mode: "live", buddy: "kitty")
        check(page.contains("fc.render") || page.contains("render: render"), "pop-up page has its renderer")
        check(!page.contains("__MODE__") && !page.contains("__BUDDY__"), "pop-up page filled in")
        check(JSONSerialization.isValidJSONObject(["phase": "working", "steps": [["text": "a", "state": "done"]], "level": 0.5]), "pop-up state is JSON")

        // Plans
        let soon = Date().addingTimeInterval(9 * 86400 - 60)
        check(Account.summary(plan: .trial, used: 0, limit: nil, trialEndsAt: soon, serverEnabled: true) == "Pro trial: 9 days left", "trial summary")
        check(Account.summary(plan: .trial, used: 0, limit: nil, trialEndsAt: soon, serverEnabled: true, trialLeft: 22) == "Pro trial: 9 days or 22 AI tasks left", "trial summary with tasks")
        check(Account.summary(plan: .free, used: 4, limit: 15, trialEndsAt: nil, serverEnabled: true) == "11 of 15 free AI tasks left this week", "free summary")
        check(Account.summary(plan: .pro, used: 99, limit: nil, trialEndsAt: nil, serverEnabled: true).hasPrefix("Pro"), "pro summary")
        check(Account.styleAllowed("kitty", pro: false) && !Account.styleAllowed("dragon", pro: false) && Account.styleAllowed("dragon", pro: true), "free styles")
        check(Account.hash("a").count == 64, "device id is a hash")
        check(PanelHTML.page(mode: "preview", buddy: "galaxy", locked: ["dragon"]).contains("[\"dragon\"]"), "locked styles reach the picker")

        // Hotkey settings round-trip
        let spec = HotKeySpec(kind: .key, keyCode: 96, modifiers: 0, label: "F5")
        let back = try? JSONDecoder().decode(HotKeySpec.self, from: JSONEncoder().encode(spec))
        check(back == spec, "hotkey saves")

        let out = failures.isEmpty ? "SELFTEST OK\n" : "SELFTEST FAILED: " + failures.joined(separator: ", ") + "\n"
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }
}
