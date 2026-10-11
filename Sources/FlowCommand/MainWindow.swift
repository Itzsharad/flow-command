import AppKit
import ServiceManagement
import SwiftUI

struct MainWindowView: View {
    enum Tab: String { case history = "History", routines = "Routines", popup = "Pop-up style", settings = "Settings" }
    @State var tab: Tab = .settings
    @ObservedObject var listener = Listener.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "mic").foregroundColor(.white).font(.system(size: 14, weight: .semibold)))
                    Text("Flow Command").font(.system(size: 16, weight: .semibold))
                }.padding(.leading, 8).padding(.bottom, 18)
                navItem(.history, "clock")
                navItem(.routines, "bolt")
                navItem(.popup, "sparkles")
                navItem(.settings, "slider.horizontal.3")
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).font(.system(size: 14, weight: .semibold))
                    }
                    Text(AppSettings.shared.wakeEnabled ? "Say “\(AppSettings.shared.wakePhrase)”" : "Hold \(AppSettings.shared.holdKey.label) to talk")
                        .font(.system(size: 13)).foregroundColor(Color(hex: 0x5E5E6A))
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            }
            .padding(EdgeInsets(top: 44, leading: 14, bottom: 20, trailing: 14))
            .frame(width: 230).frame(maxHeight: .infinity)
            .background(Theme.rail)
            .overlay(Rectangle().fill(Color(hex: 0xECECF1)).frame(width: 1), alignment: .trailing)

            ScrollView {
                Group {
                    switch tab {
                    case .history: HistoryView()
                    case .routines: RoutinesView()
                    case .popup: PopupStyleView()
                    case .settings: SettingsView()
                    }
                }
                .padding(EdgeInsets(top: 40, leading: 36, bottom: 36, trailing: 36))
                .frame(maxWidth: 820, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
        .frame(minWidth: 900, minHeight: 640)
        .foregroundColor(Theme.ink)
        .preferredColorScheme(.light)
    }

    private var statusText: String {
        switch listener.mode {
        case .awake, .holding: return "Listening"
        case .asleep: return "Ready"
        case .off: return AppSettings.shared.holdKeyEnabled ? "Ready" : "Off"
        }
    }

    private var statusColor: Color { listener.mode == .awake || listener.mode == .holding ? Theme.danger : Theme.success }

    private func navItem(_ t: Tab, _ icon: String) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(t.rawValue).font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(tab == t ? Color.white : .clear)
                .shadow(color: .black.opacity(tab == t ? 0.08 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct HistoryView: View {
    @ObservedObject var history = History.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History").font(.system(size: 26, weight: .semibold))
            Text("Everything you've asked it to do, newest first. Stored only on this Mac.").font(.system(size: 14)).foregroundColor(Color(hex: 0x5E5E6A))
            if history.items.isEmpty {
                Text("Nothing yet — wake it up and give it a task.").font(.system(size: 15)).foregroundColor(Theme.muted).padding(.top, 20)
            }
            VStack(spacing: 0) {
                ForEach(history.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(item.ok ? Theme.success : Theme.warn).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("“\(item.instruction)”").font(.system(size: 15, weight: .semibold))
                            Text(item.outcome).font(.system(size: 13)).foregroundColor(Color(hex: 0x5E5E6A))
                        }
                        Spacer()
                        Text(item.date, style: .relative).font(.system(size: 12)).foregroundColor(Theme.faint)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    Divider()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            .opacity(history.items.isEmpty ? 0 : 1)
        }
    }
}

struct RoutinesView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var account = Account.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Routines").font(.system(size: 26, weight: .semibold))
            Text("Say the phrase and all the steps run. Write steps the way you'd say them, separated by commas — for example “open Gmail, open my calendar, click Compose”.")
                .font(.system(size: 14)).foregroundColor(Color(hex: 0x5E5E6A)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach($settings.routines) { $r in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("When I say").font(.system(size: 12)).foregroundColor(Theme.faint)
                            TextField("morning setup", text: $r.phrase).textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Do this").font(.system(size: 12)).foregroundColor(Theme.faint)
                            TextField("open Gmail, open my calendar", text: $r.steps).textFieldStyle(.roundedBorder)
                        }
                        Button {
                            settings.routines.removeAll { $0.id == r.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundColor(Theme.muted).padding(.top, 26)
                            .help("Delete this routine")
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    Divider()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            if account.isPro || settings.routines.count < Account.freeRoutines {
                Button("+ Add a routine") { settings.routines.append(Routine(phrase: "", steps: "")) }
            } else {
                HStack(spacing: 10) {
                    Text("Free includes \(Account.freeRoutines) routines. Pro gives you unlimited.").font(.system(size: 13)).foregroundColor(Theme.muted)
                    Button("Upgrade to Pro") { account.openUpgrade() }
                }
            }
            Text("Tip: routines with simple steps run instantly and free. Steps like “click New chat” work instantly in Chrome once it's made instant in Settings › Websites.")
                .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var recording = false
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var checking = false
    @State private var tick = 0
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @ObservedObject private var whisper = Transcriber.shared
    @ObservedObject private var account = Account.shared
    @State private var licenseDraft = ""
    @State private var licenseMessage: String?
    @State private var activating = false
    @State private var browserMessage: String?
    @State private var settingUpBrowser = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.system(size: 26, weight: .semibold))

            if Account.serverEnabled { planSection }

            section("Waking it up") {
                row("Wake phrase") {
                    Toggle44(on: $settings.wakeEnabled)
                }
                if settings.wakeEnabled {
                    TextField("Flow Command, activate", text: $settings.wakePhrase).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                }
                row("Hold-to-talk key") {
                    Toggle44(on: $settings.holdKeyEnabled)
                }
                if settings.holdKeyEnabled {
                    HStack(spacing: 10) {
                        Text(recording ? "Press any key or combination…" : settings.holdKey.label)
                            .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).frame(height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: 0xDAD5F5)))
                        Button(recording ? "Cancel" : "Record new key") {
                            if recording { HotKeys.shared.cancelRecording(); recording = false; return }
                            recording = true
                            HotKeys.shared.record { spec in settings.holdKey = spec; recording = false }
                        }
                    }
                }
                row("Go back to sleep after") {
                    Picker("", selection: $settings.sleepAfter) {
                        Text("30 sec").tag(30); Text("2 min").tag(120); Text("Never").tag(0)
                    }.pickerStyle(.segmented).frame(width: 240).labelsHidden()
                }
            }

            section("Understanding your voice") {
                row("Accent-accurate speech (Whisper, runs on your Mac)") {
                    Toggle44(on: $settings.whisperEnabled)
                }
                if settings.whisperEnabled {
                    HStack(spacing: 10) {
                        switch whisper.state {
                        case .ready:
                            Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                            Text("Ready — understands Indian and other accents, offline").font(.system(size: 13))
                        case .downloading(let f):
                            ProgressView(value: f).frame(width: 160)
                            Text("Downloading the speech model (\(Transcriber.sizeLabel)) — \(Int(f * 100))%").font(.system(size: 13))
                        case .preparing:
                            ProgressView().controlSize(.small)
                            Text("Getting it ready — the first time takes a minute or two").font(.system(size: 13))
                        case .failed(let m):
                            Image(systemName: "exclamationmark.circle.fill").foregroundColor(Theme.warn)
                            Text("Couldn't set it up: \(m)").font(.system(size: 13)).lineLimit(2)
                            Button("Try again") { Transcriber.shared.prepare() }
                        case .notInstalled, .off:
                            Text("Needs a one-time download (\(Transcriber.sizeLabel)).").font(.system(size: 13))
                            Button("Download") { Transcriber.shared.prepare() }
                        }
                    }
                    Text("Until it's ready, Apple's built-in recognition is used. The wake phrase always uses Apple's, so it reacts instantly.")
                        .font(.system(size: 12)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Safety — always check with me before it…") {
                row("Sends a message or email") { Toggle44(on: $settings.askBeforeSend) }
                row("Buys something or makes a payment") { Toggle44(on: $settings.askBeforePay) }
                row("Deletes anything") { Toggle44(on: $settings.askBeforeDelete) }
                row("Posts or publishes publicly") { Toggle44(on: $settings.askBeforePost) }
                HStack(spacing: 8) {
                    Image(systemName: "lock").foregroundColor(Theme.muted)
                    Text("Passwords, codes and captchas are always handed to you.").font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                Text("Stop it anytime: say “stop”, press Esc, or click Stop on the panel.").font(.system(size: 13)).foregroundColor(Theme.muted)
            }

            section("Websites") {
                row("Open websites in") {
                    Picker("", selection: $settings.browser) {
                        ForEach(SettingsView.browsers, id: \.self) { b in
                            if b.isEmpty || Computer.findApp(named: b) != nil { Text(b.isEmpty ? "My default browser" : b).tag(b) }
                        }
                    }.labelsHidden().frame(width: 220)
                }
                Text("“Open Claude” opens claude.ai here. Say “open Claude app” for the desktop app.").font(.system(size: 13)).foregroundColor(Theme.muted)
                if Browser.chromium[settings.browser] != nil {
                    let _ = tick
                    HStack(spacing: 10) {
                        Image(systemName: Browser.ready ? "bolt.circle.fill" : "bolt.circle").foregroundColor(Browser.ready ? Theme.success : Theme.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Browser.ready ? "Instant clicking is on" : "Make \(settings.browser) instant").font(.system(size: 14, weight: .semibold))
                            Text("Clicks buttons and fills forms directly — no screenshots, about 10× faster.").font(.system(size: 12)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        if !Browser.ready {
                            Button(settingUpBrowser ? "Turning on…" : "Turn on") {
                                settingUpBrowser = true
                                Task { @MainActor in
                                    browserMessage = await Browser.setUp(settings.browser)
                                    settingUpBrowser = false
                                    tick += 1
                                }
                            }.disabled(settingUpBrowser)
                        }
                    }
                    if let m = browserMessage { Text(m).font(.system(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                }
            }

            section("AI brain — for bigger tasks") {
                Text("Simple commands and chains (“open Chrome, go to claude.ai, type hello and press enter”) always run instantly on your Mac, free. The AI brain is only used for tasks that need to look at the screen.")
                    .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                row("Private mode (no AI, nothing leaves this Mac)") { Toggle44(on: $settings.privateMode) }
                if !settings.privateMode && Account.serverEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(Theme.success)
                        Text("Flow Command AI is included. Nothing to set up.").font(.system(size: 14))
                    }
                    if account.isPro {
                        DisclosureGroup("Advanced: use your own Claude key instead") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Use Claude for AI tasks", isOn: Binding(get: { settings.brain == "claude" }, set: { settings.brain = $0 ? "claude" : "gemini" }))
                                keyRow(saved: settings.hasAPIKey, placeholder: "Anthropic API key (sk-ant-…)") { key in
                                    let err = await ClaudeClient.verify(key: key, model: settings.model)
                                    if err == nil { await MainActor.run { settings.apiKey = key } }
                                    return err
                                } remove: { settings.apiKey = nil }
                                if let m = keyMessage { Text(m).font(.system(size: 12)).foregroundColor(m.hasPrefix("✓") ? Theme.success : Theme.danger) }
                            }.padding(.top, 8)
                        }.font(.system(size: 13))
                    }
                }
                if !settings.privateMode && !Account.serverEnabled {
                    Picker("", selection: $settings.brain) {
                        Text("Free — Google Gemini").tag("gemini")
                        Text("Claude — paid, most capable").tag("claude")
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)

                    if settings.brain == "gemini" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Get your free key (2 minutes, no card):").font(.system(size: 13, weight: .semibold))
                            Text("1. Open aistudio.google.com/apikey and sign in with Google\n2. Click “Create API key” and copy it\n3. Paste it below and click Save")
                                .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            Link("Open Google AI Studio →", destination: URL(string: "https://aistudio.google.com/apikey")!).font(.system(size: 13))
                        }
                        keyRow(saved: settings.hasGeminiKey, placeholder: "Google AI key (AIza…)") { key in
                            let err = await GeminiClient.verify(key: key, model: settings.geminiModel)
                            if err == nil { await MainActor.run { settings.geminiKey = key } }
                            return err
                        } remove: { settings.geminiKey = nil }
                        Text("Free tier: limited requests per minute, and Google may use free-tier requests (including screenshots of the task) to improve its products — avoid using it on screens with sensitive information, or switch to Claude.")
                            .font(.system(size: 12)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    } else {
                        keyRow(saved: settings.hasAPIKey, placeholder: "Anthropic API key (sk-ant-…)") { key in
                            let err = await ClaudeClient.verify(key: key, model: settings.model)
                            if err == nil { await MainActor.run { settings.apiKey = key } }
                            return err
                        } remove: { settings.apiKey = nil }
                        row("Model") {
                            Picker("", selection: $settings.model) {
                                Text("Sonnet 5.5 — fast (recommended)").tag("claude-sonnet-5-5")
                                Text("Opus 5.5 — most capable").tag("claude-opus-5-5")
                                Text("Haiku 5.5 — cheapest").tag("claude-haiku-5-5")
                            }.labelsHidden().frame(width: 280)
                        }
                        Text("Billed per task to your Anthropic account. Screenshots of the task are sent to Anthropic.").font(.system(size: 12)).foregroundColor(Theme.faint)
                    }
                    if let m = keyMessage { Text(m).font(.system(size: 12)).foregroundColor(m.hasPrefix("✓") ? Theme.success : Theme.danger) }
                }
            }

            section("Permissions") {
                let _ = tick
                permRow("Microphone & speech", Permissions.microphone && Permissions.speech) {
                    if AVAuthDenied.any { Permissions.open(.microphone) } else { Permissions.requestMicrophoneAndSpeech { _ in tick += 1; Listener.shared.start() } }
                }
                permRow("See your screen (only for AI tasks)", Permissions.screen) { Permissions.requestScreen(); Permissions.open(.screen) }
                permRow("Click and type", Permissions.control) { Permissions.requestControl(); Permissions.open(.accessibility) }
            }

            section("General") {
                row("Sounds") { Toggle44(on: $settings.sounds) }
                row("Open when my Mac starts") {
                    Toggle("", isOn: Binding(get: { loginOn }, set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        loginOn = SMAppService.mainApp.status == .enabled
                    })).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }
                Button("Run setup again") {
                    settings.onboarded = false
                    settings.onboardingStep = 0
                    AppDelegate.shared?.showOnboarding()
                }
            }
        }
        .onReceive(timer) { _ in tick += 1 }
        .onChange(of: settings.wakeEnabled) { _ in Listener.shared.reconfigure() }
        .onChange(of: settings.holdKeyEnabled) { _ in Listener.shared.reconfigure() }
        .onChange(of: settings.whisperEnabled) { on in if on { Transcriber.shared.prepare() } }
    }

    private var planSection: some View {
        section("Your plan") {
            HStack(spacing: 10) {
                Image(systemName: account.plan == .pro ? "crown.fill" : "sparkles").foregroundColor(Theme.accent)
                Text(account.summary).font(.system(size: 15, weight: .semibold))
                Spacer()
                if account.plan != .pro {
                    Button("Upgrade to Pro") { account.openUpgrade() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            if account.plan == .free, let l = account.limit {
                ProgressView(value: Double(min(account.used, l)), total: Double(l)).tint((account.left ?? 0) <= 3 ? Theme.warn : Theme.accent)
                Text("Resets every Monday. Instant commands like “open Chrome and go to claude.ai” are always free and unlimited.")
                    .font(.system(size: 12)).foregroundColor(Theme.faint)
            }
            if account.plan == .trial {
                Text("You have everything in Pro during your trial (7 days or 30 AI tasks). After it, Free gives you \(Account.freeWeekly) AI tasks a week, \(Account.freeRoutines) routines and 4 buddies and worlds.")
                    .font(.system(size: 12)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            if account.hasLicense {
                HStack {
                    Text("License active on this computer.").font(.system(size: 13)).foregroundColor(Theme.muted)
                    Spacer()
                    Button("Remove from this computer") { Task { await account.removeLicense() } }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Have a license key? Paste it here", text: $licenseDraft).textFieldStyle(.roundedBorder)
                    Button(activating ? "Checking…" : "Activate") {
                        activating = true
                        Task {
                            let err = await account.activate(licenseDraft)
                            await MainActor.run {
                                activating = false
                                licenseMessage = err ?? "✓ Pro is on. Thank you!"
                                if err == nil { licenseDraft = "" }
                            }
                        }
                    }.disabled(licenseDraft.isEmpty || activating)
                }
                Text("One license works on 2 computers, for example your Mac and your Windows PC.").font(.system(size: 12)).foregroundColor(Theme.faint)
            }
            if let m = licenseMessage { Text(m).font(.system(size: 12)).foregroundColor(m.hasPrefix("✓") ? Theme.success : Theme.danger) }
        }
    }

    static let browsers = ["Google Chrome", "Safari", "Arc", "Brave Browser", "Microsoft Edge", "Firefox", ""]

    private func keyRow(saved: Bool, placeholder: String, save: @escaping (String) async -> String?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            SecureField(saved ? "Key saved ✓ — paste a new one to replace" : placeholder, text: $keyDraft).textFieldStyle(.roundedBorder)
            Button(checking ? "Checking…" : "Save") {
                let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                checking = true
                Task {
                    let err = await save(key)
                    await MainActor.run {
                        checking = false
                        if let err = err { keyMessage = err } else { keyDraft = ""; keyMessage = "✓ Key works — saved in your Keychain" }
                    }
                }
            }.disabled(keyDraft.isEmpty || checking)
            if saved { Button("Remove") { remove(); keyMessage = "Removed" } }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            c()
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 14)); Spacer(); c() }
    }

    private func permRow(_ label: String, _ ok: Bool, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundColor(ok ? Theme.success : Theme.warn)
            Text("\(label) — \(ok ? "allowed" : "off")").font(.system(size: 14))
            Spacer()
            if !ok { Button("Turn on", action: fix) }
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject var account = Account.shared
    @ObservedObject var listener = Listener.shared
    @ObservedObject var agent = Agent.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(listener.mode == .awake || listener.mode == .holding ? Theme.danger : Theme.success).frame(width: 8, height: 8)
                    Text(title).font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }
            Text(settings.wakeEnabled ? "Say “\(settings.wakePhrase)”" : "Hold \(settings.holdKey.label) to talk")
                .font(.system(size: 12)).foregroundColor(.secondary)
            if Account.serverEnabled {
                HStack {
                    Text(account.summary).font(.system(size: 12)).foregroundColor(account.plan == .free && (account.left ?? 1) <= 3 ? Theme.warn : .secondary)
                    Spacer()
                    if account.plan == .free || account.plan == .trial {
                        Button("Upgrade") { account.openUpgrade() }.foregroundColor(Theme.accent).font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            if let p = listener.problem {
                Text(p).font(.system(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if !settings.onboarded {
                Button("Finish setup…") { AppDelegate.shared?.showOnboarding() }
            } else if listener.mode == .awake {
                Button("Go to sleep") { listener.sleep() }
            } else {
                Button("Wake up now") { listener.wakeNow() }
            }
            if agent.isBusy { Button("Stop current task") { agent.stop() } }
            Divider()
            Button("Open Flow Command…") { AppDelegate.shared?.showMain() }
            Button("Quit Flow Command") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 280)
    }

    private var title: String {
        if agent.isBusy { return "Working…" }
        switch listener.mode {
        case .awake, .holding: return "Listening"
        case .asleep: return "Ready — asleep"
        case .off: return settings.onboarded ? "Ready" : "Setup not finished"
        }
    }
}
