import AppKit
import ApplicationServices
import Foundation

/// Instant web control: reads the buttons, links and fields on the current page as text and
/// clicks them directly inside the browser — no screenshots, no mouse guessing.
/// Works in Chrome (and Brave / Edge); needs Chrome's "Allow JavaScript from Apple Events".
enum Browser {
    struct Element: Equatable {
        var id: Int
        var kind: String
        var text: String
        var value: String
        var inView: Bool
    }

    struct Page {
        var title: String
        var url: String
        var elements: [Element]
    }

    enum BridgeError: LocalizedError {
        case notRunning, jsOff, notAllowed, stale, other(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: return "The browser isn't open."
            case .jsOff: return "Chrome needs one setting turned on: View › Developer › Allow JavaScript from Apple Events."
            case .notAllowed: return "Flow Command isn't allowed to control the browser. Turn it on in System Settings › Privacy & Security › Automation."
            case .stale: return "The page changed."
            case .other(let m): return m
            }
        }
    }

    /// Chromium browsers that understand `execute … javascript`.
    static let chromium: [String: String] = [
        "Google Chrome": "com.google.Chrome", "Brave Browser": "com.brave.Browser", "Microsoft Edge": "com.microsoft.edgemac",
    ]

    /// The browser to drive: the user's chosen one if it's Chromium, else a Chromium browser that's in front.
    static var target: String? {
        if let b = AppSettings.shared.preferredBrowser, chromium[b] != nil { return b }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let name = chromium.first(where: { $0.value == front })?.key { return name }
        return nil
    }

    static func isRunning(_ name: String) -> Bool {
        guard let id = chromium[name] else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Last known state, shown in Settings.
    static var ready: Bool {
        get { UserDefaults.standard.bool(forKey: "browserBridgeReady") }
        set { UserDefaults.standard.set(newValue, forKey: "browserBridgeReady") }
    }

    // MARK: Running JavaScript in the page

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @MainActor
    static func runJS(_ js: String, in browser: String) throws -> String {
        guard isRunning(browser) else { throw BridgeError.notRunning }
        let src = """
        tell application \(appleScriptString(browser))
            tell active tab of front window to execute javascript \(appleScriptString(js))
        end tell
        """
        guard let script = NSAppleScript(source: src) else { throw BridgeError.other("Couldn't prepare the browser command.") }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err = err {
            let num = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Browser error \(num)"
            if num == -1743 || num == -1744 { throw BridgeError.notAllowed }
            if msg.localizedCaseInsensitiveContains("javascript") { ready = false; throw BridgeError.jsOff }
            if num == -1728 || num == -1719 { throw BridgeError.other("No browser window is open.") }
            throw BridgeError.other(msg)
        }
        ready = true
        return out.stringValue ?? ""
    }

    static func js(_ js: String) async throws -> String {
        guard let b = target else { throw BridgeError.notRunning }
        return try await MainActor.run { try runJS(js, in: b) }
    }

    @MainActor
    static func activate() {
        guard let b = target, let id = chromium[b] else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    /// Waits until the new page has loaded (up to ~6 seconds).
    static func waitForLoad() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        for _ in 0..<18 {
            if let state = try? await js("document.readyState"), state == "complete" { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: Reading the page

    /// Lists the visible interactive elements and numbers them (the numbers stay valid until the page changes).
    static let outlineJS = #"""
    (function(){
      var W=innerWidth,H=innerHeight;
      var sel='a[href],button,input:not([type=hidden]),textarea,select,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=radio],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[contenteditable=""],[contenteditable=true],[onclick]';
      var all=[];
      function collect(doc){ try { all=all.concat(Array.prototype.slice.call(doc.querySelectorAll(sel))); } catch(e){} }
      collect(document);
      var frames=document.querySelectorAll('iframe');
      for(var f=0;f<frames.length;f++){ try{ if(frames[f].contentDocument) collect(frames[f].contentDocument);}catch(e){} }
      var seen=new Set(), list=[];
      for(var i=0;i<all.length;i++){
        var el=all[i]; if(seen.has(el)) continue; seen.add(el);
        var r=el.getBoundingClientRect(); if(r.width<2||r.height<2) continue;
        var st=getComputedStyle(el); if(st.visibility==='hidden'||st.display==='none'||st.opacity==='0') continue;
        if(el.disabled) continue;
        var tag=el.tagName.toLowerCase(), role=el.getAttribute('role');
        var kind=role||(tag==='input'?'input:'+(el.type||'text'):tag);
        var field=/^(input|textarea|select|textbox|searchbox|combobox)/.test(kind)||el.isContentEditable;
        var lab='';
        if(field){
          var l=el.labels&&el.labels[0]?el.labels[0].innerText:'';
          lab=el.getAttribute('aria-label')||el.placeholder||l||el.title||el.name||'';
        } else {
          var img=el.querySelector&&el.querySelector('img[alt]');
          lab=el.getAttribute('aria-label')||el.innerText||el.value||el.title||(img?img.alt:'')||'';
        }
        lab=String(lab).replace(/\s+/g,' ').trim().slice(0,80);
        if(!lab&&!field) continue;
        var val=field?String(el.isContentEditable?el.innerText:(el.value||'')).replace(/\s+/g,' ').slice(0,60):'';
        if(kind.indexOf('password')>=0) val=val?'••••':'';
        var inView=r.bottom>0&&r.top<H&&r.right>0&&r.left<W;
        list.push({el:el,k:kind,t:lab,v:val,in:inView,y:r.top});
      }
      list.sort(function(a,b){ return (b.in-a.in)||(a.y-b.y); });
      list=list.slice(0,220);
      window.__fc=list.map(function(x){return x.el;});
      return JSON.stringify({title:document.title,url:location.href,items:list.map(function(x,i){return {i:i,k:x.k,t:x.t,v:x.v,in:x.in};})});
    })()
    """#

    static func outline() async throws -> Page {
        let raw = try await js(outlineJS)
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.other("Couldn't read the page.")
        }
        let items = (obj["items"] as? [[String: Any]] ?? []).map {
            Element(id: ($0["i"] as? NSNumber)?.intValue ?? 0, kind: $0["k"] as? String ?? "",
                    text: $0["t"] as? String ?? "", value: $0["v"] as? String ?? "",
                    inView: ($0["in"] as? Bool) ?? false)
        }
        return Page(title: obj["title"] as? String ?? "", url: obj["url"] as? String ?? "", elements: items)
    }

    /// The page as short text lines for the AI: `[12] button "Sign up"`.
    static func describe(_ page: Page) -> String {
        var lines = ["Page: \(page.title) — \(page.url)"]
        for e in page.elements {
            var line = "[\(e.id)] \(e.kind) \"\(e.text)\""
            if !e.value.isEmpty { line += " = \"\(e.value)\"" }
            if !e.inView { line += " (below)" }
            lines.append(line)
        }
        if page.elements.isEmpty { lines.append("(no buttons, links or fields found)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Acting on the page

    static func click(_ id: Int) async throws {
        let r = try await js("""
        (function(i){var el=(window.__fc||[])[i]; if(!el||!el.isConnected) return 'stale';
        el.scrollIntoView({block:'center',inline:'center'});
        var r=el.getBoundingClientRect(), o={bubbles:true,cancelable:true,view:window,clientX:r.left+r.width/2,clientY:r.top+r.height/2};
        try{el.dispatchEvent(new PointerEvent('pointerdown',o));}catch(e){} el.dispatchEvent(new MouseEvent('mousedown',o));
        if(el.focus) el.focus();
        try{el.dispatchEvent(new PointerEvent('pointerup',o));}catch(e){} el.dispatchEvent(new MouseEvent('mouseup',o));
        el.click(); return 'ok';})(\(id))
        """)
        if r == "stale" { throw BridgeError.stale }
    }

    /// Focuses a field (selecting what's in it, so typing replaces it).
    static func focus(_ id: Int) async throws {
        let r = try await js("""
        (function(i){var el=(window.__fc||[])[i]; if(!el||!el.isConnected) return 'stale';
        el.scrollIntoView({block:'center'}); el.focus(); if(el.click) el.click();
        if(el.select) el.select(); return 'ok';})(\(id))
        """)
        if r == "stale" { throw BridgeError.stale }
    }

    /// Best match for "sign up" among the page's elements (exact, then starts-with, then contains; visible first).
    static func bestMatch(_ query: String, in elements: [Element]) -> Element? {
        let q = WakeMatcher.words(query).joined(separator: " ")
        guard !q.isEmpty else { return nil }
        func score(_ e: Element) -> Int {
            let t = WakeMatcher.words(e.text).joined(separator: " ")
            guard !t.isEmpty else { return 0 }
            var s = 0
            if t == q { s = 100 }
            else if t.hasPrefix(q + " ") || t.hasPrefix(q) { s = 70 }
            else if (" " + t + " ").contains(" " + q + " ") { s = 55 }
            else if t.contains(q) { s = 40 }
            else if WakeMatcher.distance(t, q) <= max(1, q.count / 6) { s = 45 }
            else { return 0 }
            if e.inView { s += 10 }
            if ["button", "a", "link", "input:submit", "input:button", "tab", "menuitem"].contains(e.kind) { s += 3 }
            return s - min(10, max(0, t.count - q.count) / 8)
        }
        let best = elements.map { ($0, score($0)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        return best?.0
    }

    /// Instant "click sign up": finds it by text and clicks it. Returns the clicked label.
    static func clickText(_ query: String) async throws -> String? {
        let page = try await outline()
        guard let e = bestMatch(query, in: page.elements) else { return nil }
        try await click(e.id)
        return e.text
    }

    // MARK: One-click setup

    /// Turns on Chrome's View › Developer › Allow JavaScript from Apple Events by pressing the menu item.
    /// Also triggers macOS's "Flow Command wants to control Chrome" question the first time.
    @MainActor
    static func setUp(_ browser: String = "Google Chrome") async -> String? {
        guard let bundle = chromium[browser] else { return "Pick Chrome, Brave or Edge as your browser first." }
        if !isRunning(browser) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else { return "\(browser) isn't installed." }
            for _ in 0..<20 where !isRunning(browser) { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if (try? runJS("1+1", in: browser)) == "2" { ready = true; return nil }
        _ = pressMenu(app: bundle, path: ["View", "Developer", "Allow JavaScript from Apple Events"])
        try? await Task.sleep(nanoseconds: 800_000_000)
        do {
            if try runJS("1+1", in: browser) == "2" { ready = true; return nil }
            return "Something went wrong. Try again."
        } catch BridgeError.jsOff {
            return "In \(browser), open the View menu › Developer › click “Allow JavaScript from Apple Events”. Then try again."
        } catch {
            return error.localizedDescription
        }
    }

    /// Presses a menu item by its titles (only if it isn't ticked already). Needs click-and-type permission.
    static func pressMenu(app bundle: String, path: [String]) -> Bool {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else { return false }
        let root = AXUIElementCreateApplication(pid)
        func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func title(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute) as? String) ?? "" }
        guard let barObj = attr(root, kAXMenuBarAttribute) else { return false }
        var current = barObj as! AXUIElement
        for (i, name) in path.enumerated() {
            // menu bar items / menu items hold their submenu as the single child
            var items = children(current)
            if items.count == 1, (attr(items[0], kAXRoleAttribute) as? String) == kAXMenuRole { items = children(items[0]) }
            guard let match = items.first(where: { title($0).caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            if i == path.count - 1 {
                let mark = attr(match, kAXMenuItemMarkCharAttribute) as? String
                if let m = mark, !m.isEmpty { return true }   // already on
                return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
            }
            current = match
        }
        return false
    }
}
