import AppKit
import ServiceManagement
import SwiftUI

struct MainWindowView: View {
    enum Tab: String { case history = "History", settings = "Settings" }
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
                    if tab == .history { HistoryView() } else { SettingsView() }
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

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var recording = false
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var tick = 0
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.system(size: 26, weight: .semibold))

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

            section("AI brain") {
                row("Private mode (nothing leaves this Mac)") { Toggle44(on: $settings.privateMode) }
                Text(settings.privateMode
                     ? "Simple commands only in this version — multi-step tasks are off."
                     : "Multi-step tasks use Claude. Screenshots of the task are sent to Anthropic; billed to your API account.")
                    .font(.system(size: 13)).foregroundColor(Theme.muted)
                if !settings.privateMode {
                    HStack(spacing: 8) {
                        SecureField(settings.hasAPIKey ? "Key saved — paste a new one to replace" : "Anthropic API key", text: $keyDraft).textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                let err = await ClaudeClient.verify(key: key, model: settings.model)
                                await MainActor.run {
                                    if let err = err { keyMessage = err } else { settings.apiKey = key; keyDraft = ""; keyMessage = "✓ Saved" }
                                }
                            }
                        }.disabled(keyDraft.isEmpty)
                        if settings.hasAPIKey { Button("Remove") { settings.apiKey = nil; keyMessage = "Removed" } }
                    }
                    if let m = keyMessage { Text(m).font(.system(size: 12)).foregroundColor(m.hasPrefix("✓") ? Theme.success : Theme.muted) }
                    row("Model") {
                        Picker("", selection: $settings.model) {
                            Text("Sonnet 5.5 — fast (recommended)").tag("claude-sonnet-5-5")
                            Text("Opus 5.5 — most capable").tag("claude-opus-5-5")
                            Text("Haiku 5.5 — cheapest").tag("claude-haiku-5-5")
                        }.labelsHidden().frame(width: 280)
                    }
                }
            }

            section("Permissions") {
                let _ = tick
                permRow("Microphone & speech", Permissions.microphone && Permissions.speech) { Permissions.open(.microphone) }
                permRow("See your screen", Permissions.screen) { Permissions.requestScreen(); Permissions.open(.screen) }
                permRow("Click and type", Permissions.control) { Permissions.requestControl() }
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
