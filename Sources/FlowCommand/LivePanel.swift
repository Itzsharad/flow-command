import AppKit
import Combine
import SwiftUI
import WebKit

/// A web view that reacts to the first click even though the panel never takes focus.
final class PanelWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pop-up in the bottom-right corner while it's listening or working.
/// Drawn as a small web page so the buddies and worlds animate smoothly. It never takes focus.
final class LivePanelController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = LivePanelController()
    private var panel: NSPanel?
    private var web: PanelWebView?
    private var ready = false
    private var pending = false
    private var size = NSSize(width: 404, height: 260)
    private var bag = Set<AnyCancellable>()
    private var doneTitle = "Done"
    private var lastPhase: Agent.Phase = .idle
    private var ticker: Timer?

    func install() {
        guard panel == nil else { return }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "fc")
        let w = PanelWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        w.loadHTMLString(PanelHTML.page(mode: "live", buddy: AppSettings.shared.popupStyle), baseURL: nil)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false          // the page draws its own soft shadow
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = w
        panel = p
        web = w

        Agent.shared.objectWillChange.merge(with: Listener.shared.objectWillChange, AppSettings.shared.objectWillChange, Account.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRender() }
            .store(in: &bag)
        // keeps the timer ticking while a task runs
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if Agent.shared.phase == .working { self?.scheduleRender() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        scheduleRender()
    }

    /// Many changes arrive at once (the microphone level updates constantly) — draw at most ~20 times a second.
    func scheduleRender() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pending = false
            self?.render()
        }
    }

    private var shouldShow: Bool {
        let agent = Agent.shared, l = Listener.shared
        return agent.phase != .idle || l.mode == .awake || l.mode == .holding || l.understanding
    }

    private func render() {
        guard let p = panel, let w = web else { return }
        guard shouldShow else { p.orderOut(nil); lastPhase = Agent.shared.phase; return }
        if ready, let data = try? JSONSerialization.data(withJSONObject: LivePanelController.state(doneTitle: &doneTitle, lastPhase: &lastPhase)),
           let json = String(data: data, encoding: .utf8) {
            w.evaluateJavaScript("window.fc && fc.render(\(json))", completionHandler: nil)
        }
        place()
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func place() {
        guard let p = panel else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // the page has transparent margins for its shadow and for the buddy walking on top
        let frame = NSRect(x: screen.maxX - size.width - 2, y: screen.minY + 2, width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    /// Everything the page needs to draw the current moment.
    static func state(doneTitle: inout String, lastPhase: inout Agent.Phase) -> [String: Any] {
        let a = Agent.shared, l = Listener.shared, s = AppSettings.shared
        var phase = "listening", title = "Listening — what should I do?"
        switch a.phase {
        case .idle:
            if l.understanding { phase = "understanding"; title = "Understanding…" }
            else if l.mode == .holding { phase = "holding"; title = "Listening — let go when you're done" }
        case .working: phase = "working"; title = "Working"
        case .confirm: phase = "confirm"; title = "Check with you"
        case .handoff: phase = "handoff"; title = "Your turn"
        case .done:
            phase = "done"
            if lastPhase != .done {
                let secs = Date().timeIntervalSince(a.startedAt)
                let n = a.steps.count
                doneTitle = n > 1 ? String(format: "Done — %d steps in %.1fs", n, secs) : String(format: "Done in %.1fs", secs)
            }
            title = doneTitle
        case .failed:
            phase = "failed"; title = a.result == "Stopped." ? "Stopped" : "Didn’t finish"
        }
        lastPhase = a.phase
        let steps: [[String: String]] = a.steps.map { st in
            ["text": st.text, "state": st.state == .done ? "done" : st.state == .failed ? "failed" : "current"]
        }
        return [
            "phase": phase, "title": title, "live": l.live, "instruction": a.instruction,
            "steps": steps, "status": a.status, "question": a.question, "result": a.result,
            "fix": a.fix?.title ?? "", "level": Double(l.level),
            "elapsed": Date().timeIntervalSince(a.startedAt),
            "holdKey": s.holdKeyEnabled ? s.holdKey.label : "Esc",
            "buddy": Account.shared.allowedStyle(s.popupStyle),
        ]
    }

    // Buttons on the pop-up
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let agent = Agent.shared
        switch action {
        case "size":
            if let w = (body["w"] as? NSNumber)?.doubleValue, let h = (body["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
                let new = NSSize(width: ceil(w), height: ceil(h))
                if new != size { size = new; place() }
            }
        case "stop": agent.stop()
        case "yes": agent.respond(true)
        case "no": agent.respond(false)
        case "fix": agent.fix?.perform()
        default: break
        }
    }
}

// MARK: - Settings: pick the pop-up's buddy or world (live preview)

struct PopupStylePreview: NSViewRepresentable {
    @ObservedObject var settings = AppSettings.shared

    final class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String,
                  let key = body["key"] as? String, let style = PanelHTML.styles.first(where: { $0.key == key }) else { return }
            if action == "buddy" { AppSettings.shared.popupStyle = key; return }
            guard action == "locked" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let alert = NSAlert()
                alert.messageText = "\(style.name) comes with Pro"
                alert.informativeText = "Free includes Classic, Kitty, Pup and Galaxy. Pro unlocks every buddy and world, plus unlimited AI tasks and routines."
                alert.addButton(withTitle: "Upgrade to Pro")
                alert.addButton(withTitle: "Not now")
                if alert.runModal() == .alertFirstButtonReturn { Account.shared.openUpgrade() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "fc")
        let w = PanelWebView(frame: .zero, configuration: config)
        w.setValue(false, forKey: "drawsBackground")
        w.loadHTMLString(PanelHTML.page(mode: "preview", buddy: Account.shared.allowedStyle(settings.popupStyle),
                                        locked: Account.shared.lockedStyles), baseURL: nil)
        return w
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "fc")
    }
}

struct PopupStyleView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var account = Account.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pop-up style").font(.system(size: 26, weight: .semibold))
            Text("Make the pop-up yours. Buddies walk along the top; worlds live inside. They react while it listens, works and finishes, and say hi when you click them.")
                .font(.system(size: 14)).foregroundColor(Color(hex: 0x5E5E6A)).fixedSize(horizontal: false, vertical: true)
            PopupStylePreview()
                .id(account.isPro)
                .frame(height: 620)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.rail))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 8) {
                Image(systemName: "camera").foregroundColor(Theme.accentInk)
                Text("Love your setup? Screen-record it, post it and tag @sharad.builds. We repost the best ones.")
                    .font(.system(size: 13)).foregroundColor(Theme.muted)
            }
        }
    }
}
