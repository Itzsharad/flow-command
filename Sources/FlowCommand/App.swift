import AppKit
import AVFoundation
import Speech
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        // Never start the app if launched with helper-style arguments.
        if args.dropFirst().contains(where: { $0 == "-c" || $0 == "-m" }) { exit(0) }
        FlowCommandApp.main()
    }
}

struct FlowCommandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var listener = Listener.shared
    @ObservedObject var agent = Agent.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if agent.isBusy { return "waveform.circle.fill" }
        switch listener.mode {
        case .awake, .holding: return "mic.fill"
        case .asleep, .off: return "mic"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var lockHandle: FileHandle?
    private var servicesStarted = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.launchedAtLogin = AppDelegate.readLoginLaunch()
        // Only one copy may ever run.
        if !SingleInstance.acquire() {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0 != NSRunningApplication.current }) {
                other.activate()
            }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LivePanelController.shared.install()
        let s = AppSettings.shared
        // After an update macOS may forget the microphone permission — send people back to that step.
        let micUnknown = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        if s.onboarded && micUnknown {
            s.onboarded = false
            s.onboardingStep = 1
        }
        if s.onboarded {
            startServices()
            // Opened by you (installer, Finder, Spotlight) — not at login: show the window so you know it's running.
            if CommandLine.arguments.contains("--welcome") || !AppDelegate.launchedAtLogin { showMain() }
        } else {
            showOnboarding()
        }
    }

    /// Clicking the app again in Finder, Spotlight or Launchpad while it's running opens its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppSettings.shared.onboarded { showMain() } else { showOnboarding() }
        return true
    }

    /// macOS marks apps it starts at login; anything else was opened by the person.
    static var launchedAtLogin = false
    private static func readLoginLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Start listening and watching for the hotkey. Only ever called after setup (or on its "Try it" step).
    func startServices() {
        let listener = Listener.shared, agent = Agent.shared, keys = HotKeys.shared
        if !servicesStarted {
            servicesStarted = true
            listener.onInstruction = { agent.handle($0) }
            listener.onStopWord = { agent.stop() }
            listener.isBusy = { agent.isBusy }
            listener.onSleep = { agent.resetConversation() }
            listener.onNotReady = { [weak self] why in self?.showCantHear(why) }
            // Your talk key is also the off switch:
            //  • pressed while a task runs → stops it and goes to sleep
            //  • pressed while awake (woken by voice) → goes to sleep right away
            //  • otherwise → hold to talk, let go to send
            var swallowRelease = false
            keys.onHoldDown = {
                Log.write("key down · busy=\(agent.isBusy) mode=\(listener.mode)")
                if agent.isBusy {
                    agent.stop(); listener.sleep(); swallowRelease = true
                } else if listener.mode == .awake {
                    listener.sleep(); Sound.play("Pop"); swallowRelease = true
                } else {
                    listener.holdBegan()
                }
            }
            keys.onHoldUp = {
                if swallowRelease { swallowRelease = false; return }
                listener.holdEnded()
            }
            keys.onEscape = {
                if agent.isBusy { agent.stop() } else if listener.mode == .awake { listener.sleep() }
            }
        }
        listener.ensurePermissionsAndStart()
        Log.write("services start · control=\(Permissions.control) holdKey=\(AppSettings.shared.holdKeyEnabled) \(AppSettings.shared.holdKey.label)")
        if Permissions.control { keys.start() }
        Transcriber.shared.prepare()   // downloads the accent-accurate speech model once, in the background
        Task { await Account.shared.refresh() }
    }

    private var cantHearShowing = false
    /// A clear message instead of silence when it can't listen.
    func showCantHear(_ why: String) {
        guard !cantHearShowing else { return }
        cantHearShowing = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Flow Command can't hear you yet"
        alert.informativeText = why
        let needsPermission = !(Permissions.microphone && Permissions.speech)
        alert.addButton(withTitle: needsPermission ? "Fix it" : "Try again")
        alert.addButton(withTitle: "Close")
        let r = alert.runModal()
        cantHearShowing = false
        guard r == .alertFirstButtonReturn else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined || SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            Listener.shared.ensurePermissionsAndStart()
        } else if needsPermission {
            Permissions.open(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .speech : .microphone)
        } else {
            Listener.shared.shutdown()
            Listener.shared.ensurePermissionsAndStart()
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(onFinish: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.startServices()
                self?.showMain()
            })
            onboardingWindow = makeWindow(view, size: NSSize(width: 820, height: 560), title: "Welcome to Flow Command", resizable: false)
        }
        present(onboardingWindow)
    }

    func showMain() {
        if mainWindow == nil {
            mainWindow = makeWindow(MainWindowView(), size: NSSize(width: 1040, height: 720), title: "Flow Command", resizable: true)
        }
        present(mainWindow)
    }

    private func makeWindow<V: View>(_ view: V, size: NSSize, title: String, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }

    /// Running straight from the .dmg (or a quarantined copy) makes macOS permissions not stick.
    static var runningFromInstaller: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("AppTranslocation")
    }

    /// Some permissions only take effect after reopening. Reopens once, cleanly.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// A lock file that only one running copy can hold.
enum SingleInstance {
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowCommand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(".running.lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
