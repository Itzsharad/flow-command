import AppKit
import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Shared bits

struct PrimaryButton: View {
    var title: String
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 24).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(enabled ? Theme.accent : Theme.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct SecondaryButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14)).foregroundColor(Theme.ink)
                .padding(.horizontal, 14).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xD6D6DE)))
        }.buttonStyle(.plain)
    }
}

struct CheckLine: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.success).frame(width: 20)
            Text(text).font(.system(size: 15)).foregroundColor(Color(hex: 0x2A2A33)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusLine: View {
    var ok: Bool
    var okText: String
    var waitText: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ok ? Theme.success : Theme.warn).frame(width: 8, height: 8)
            Text(ok ? okText : waitText).font(.system(size: 14)).foregroundColor(ok ? Theme.success : Color(hex: 0x5E5E6A))
        }
    }
}

struct Toggle44: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("", isOn: $on).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var agent = Agent.shared
    @ObservedObject var listener = Listener.shared
    var onFinish: () -> Void

    @State private var tick = 0
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var checkingKey = false
    @State private var recording = false
    @State private var startAtLogin = true
    @State private var triedTask = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let railLabels = ["Microphone", "See your screen", "Control your Mac", "How to wake it", "AI brain", "Try it"]

    private var step: Int {
        get { settings.onboardingStep }
        nonmutating set { settings.onboardingStep = newValue }
    }

    var body: some View {
        Group {
            if step == 0 { welcome }
            else if step >= 7 { done }
            else {
                HStack(spacing: 0) {
                    rail
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Step \(step) of 6").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accentInk).padding(.bottom, 14)
                        if AppDelegate.runningFromInstaller {
                            Text("You're running Flow Command from the installer disk. Quit it, drag it into Applications, eject the installer and open it from Applications — otherwise macOS permissions won't stick.")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
                        }
                        content
                        Spacer(minLength: 12)
                        footer
                    }
                    .padding(EdgeInsets(top: 52, leading: 44, bottom: 28, trailing: 44))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(width: 820, height: 560)
        .background(Color.white)
        .foregroundColor(Theme.ink)
        .preferredColorScheme(.light)
        .onReceive(timer) { _ in tick += 1; autoAdvance() }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETUP").font(.system(size: 12, weight: .semibold)).kerning(0.7).foregroundColor(Theme.faint)
                .padding(.leading, 8).padding(.bottom, 8)
            ForEach(Array(OnboardingView.railLabels.enumerated()), id: \.offset) { i, label in
                let n = i + 1
                HStack(spacing: 12) {
                    ZStack {
                        if n < step {
                            Circle().fill(Theme.success)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                        } else if n == step {
                            Circle().fill(Theme.accent)
                            Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        } else {
                            Circle().stroke(Color(hex: 0xC9C9D3), lineWidth: 1.5)
                            Text("\(n)").font(.system(size: 12)).foregroundColor(Theme.muted)
                        }
                    }.frame(width: 24, height: 24)
                    Text(label).font(.system(size: 15, weight: n == step ? .semibold : .regular))
                        .foregroundColor(n <= step ? Theme.ink : Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(n == step ? Color.white : Color.clear)
                    .shadow(color: .black.opacity(n == step ? 0.08 : 0), radius: 1, y: 1))
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 56, leading: 16, bottom: 24, trailing: 16))
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.rail)
        .overlay(Rectangle().fill(Color(hex: 0xECECF1)).frame(width: 1), alignment: .trailing)
    }

    // MARK: Screens

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 22).fill(Theme.accent).frame(width: 88, height: 88)
                    .overlay(Image(systemName: "mic").font(.system(size: 36, weight: .medium)).foregroundColor(.white))
                Image(systemName: "bolt.fill").font(.system(size: 18)).foregroundColor(Color(hex: 0xFFD25A)).padding(10)
            }.padding(.bottom, 28)
            Text("Your Mac, run by your voice.").font(.system(size: 38, weight: .semibold)).padding(.bottom, 14)
            Text("Say “Flow Command, activate” and tell it what to do. It sees your screen and clicks, types and navigates for you — in any app, on any website.")
                .font(.system(size: 17)).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 560).padding(.bottom, 32)
            PrimaryButton(title: "Get started  →") { step = 1 }
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 13))
                Text("Nothing is switched on yet. You'll approve each permission yourself.")
            }.font(.system(size: 14)).foregroundColor(Color(hex: 0x5E5E6A)).padding(.top, 28)
            Spacer()
            Divider()
            Text("Setup takes about two minutes · 6 short steps").font(.system(size: 13)).foregroundColor(Theme.faint).frame(height: 48)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: micStep
        case 2: screenStep
        case 3: controlStep
        case 4: wakeStep
        case 5: brainStep
        default: tryStep
        }
    }

    private func header(_ icon: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 16).fill(Theme.accentSoft).frame(width: 56, height: 56)
                .overlay(Image(systemName: icon).font(.system(size: 24)).foregroundColor(Theme.accentInk)).padding(.bottom, 18)
            Text(title).font(.system(size: 28, weight: .semibold)).padding(.bottom, 10)
            Text(body).font(.system(size: 16)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading).padding(.bottom, 20)
        }
    }

    private var micStep: some View {
        let ok = tick >= 0 && Permissions.microphone && Permissions.speech
        return VStack(alignment: .leading, spacing: 12) {
            header("mic", "Let Flow Command hear you", "So it can hear your wake phrase and your instructions. macOS will ask you twice — microphone and speech recognition.")
            CheckLine(text: "Speech is turned into text on this Mac")
            CheckLine(text: "The menu bar icon glows whenever it's awake")
            CheckLine(text: "You can switch it off anytime in Settings")
            StatusLine(ok: ok, okText: "Allowed", waitText: "Not allowed yet").padding(.top, 6)
        }
    }

    private var screenStep: some View {
        let ok = tick >= 0 && Permissions.screen
        return VStack(alignment: .leading, spacing: 12) {
            header("display", "Let it see your screen", "To find buttons and fields it looks at your screen — only while doing a task you gave it.")
            CheckLine(text: "Never records video — one snapshot per step")
            CheckLine(text: "In Private mode snapshots never leave your Mac")
            StatusLine(ok: ok, okText: "Allowed", waitText: "Turn on Flow Command in the list, then click Continue. macOS may ask to quit & reopen — that's fine, setup picks up here.")
                .padding(.top, 6)
        }
    }

    private var controlStep: some View {
        let ok = tick >= 0 && Permissions.control
        return VStack(alignment: .leading, spacing: 12) {
            header("cursorarrow.click.2", "Let it click and type for you", "macOS calls this “Accessibility”. It lets Flow Command move the mouse, click and type — only while doing a task you gave it.")
            VStack(alignment: .leading, spacing: 10) {
                Text("System Settings  ›  Privacy & Security  ›  Accessibility").font(.system(size: 12)).foregroundColor(Theme.faint)
                HStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "mic").foregroundColor(.white).font(.system(size: 14)))
                    Text("FlowCommand").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Capsule().fill(Theme.accent).frame(width: 40, height: 24).overlay(Circle().fill(.white).frame(width: 20, height: 20), alignment: .trailing).padding(.trailing, 2)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(.white)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                Text("Turn on this switch, then come back here.").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.accentInk)
            }
            .padding(16).frame(maxWidth: 470).background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFAFAFC)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            StatusLine(ok: ok, okText: "Allowed", waitText: "Waiting — this screen moves on by itself once it's on.")
            if !ok {
                Text("Already on but still waiting? That switch may belong to an older copy. Select FlowCommand in the list, click –, then click Open System Settings again and turn on the new entry. Or click “Already on — reopen”.")
                    .font(.system(size: 12)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    private var wakeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How do you want to wake it?").font(.system(size: 28, weight: .semibold))
            Text("Use one or both. Once it's awake, just keep talking — it does each thing you say.")
                .font(.system(size: 15)).foregroundColor(Theme.muted).padding(.bottom, 6)
            card(on: settings.wakeEnabled) {
                HStack {
                    Label("Say a wake phrase", systemImage: "waveform").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Toggle44(on: $settings.wakeEnabled)
                }
                HStack {
                    Text("Phrase").font(.system(size: 14)).foregroundColor(Theme.muted)
                    TextField("Flow Command, activate", text: $settings.wakePhrase).textFieldStyle(.roundedBorder).font(.system(size: 15))
                }
                Text("To put it to sleep: “go to sleep” — or it naps after 30 seconds of quiet.").font(.system(size: 13)).foregroundColor(Theme.faint)
            }
            card(on: settings.holdKeyEnabled) {
                HStack {
                    Label("Hold any key", systemImage: "keyboard").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Toggle44(on: $settings.holdKeyEnabled)
                }
                HStack(spacing: 10) {
                    Text(recording ? "Press any key or combination…" : settings.holdKey.label)
                        .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: 0xDAD5F5)))
                    Button(recording ? "Cancel" : "Record a different key") {
                        if recording { HotKeys.shared.cancelRecording(); recording = false; return }
                        recording = true
                        HotKeys.shared.record { spec in settings.holdKey = spec; recording = false }
                    }.buttonStyle(.plain).foregroundColor(Theme.accentInk).font(.system(size: 14))
                }
            }
        }
    }

    private func card<C: View>(on: Bool, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10, content: c)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? Color(hex: 0xF7F5FF) : .white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Theme.accent : Theme.hairline, lineWidth: on ? 1.5 : 1))
            .opacity(on ? 1 : 0.7)
    }

    private var brainStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose its brain").font(.system(size: 28, weight: .semibold))
            Text("Simple things (open apps and sites, type, shortcuts) always run on your Mac. For multi-step tasks:")
                .font(.system(size: 15)).foregroundColor(Theme.muted)
            card(on: !settings.privateMode) {
                    HStack { Text("Smart — uses Claude").font(.system(size: 16, weight: .semibold)); Spacer(); if !settings.privateMode { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent) } }
                    Text("Does almost anything. Sends screenshots of the task to Anthropic; small cost per task on your API account.")
                        .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    if !settings.privateMode {
                        HStack(spacing: 8) {
                            SecureField(settings.hasAPIKey ? "Key saved — paste a new one to replace" : "Paste your Anthropic API key (sk-ant-…)", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                            Button(checkingKey ? "Checking…" : "Save") { saveKey() }.disabled(keyDraft.isEmpty || checkingKey)
                        }
                        HStack {
                            if let m = keyMessage { Text(m).font(.system(size: 12)).foregroundColor(m.hasPrefix("✓") ? Theme.success : Theme.danger) }
                            Spacer()
                            Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.system(size: 12))
                        }
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture { settings.privateMode = false }
            card(on: settings.privateMode) {
                    HStack { Text("Private — stays on this Mac").font(.system(size: 16, weight: .semibold)); Spacer(); if settings.privateMode { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent) } }
                    Text("Nothing leaves your Mac. In this first version it handles simple commands only; multi-step tasks come in a later update.")
                        .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .onTapGesture { settings.privateMode = true }
        }
    }

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give it your first task").font(.system(size: 28, weight: .semibold)).padding(.bottom, 4)
            if settings.wakeEnabled {
                bubble("First", "“\(settings.wakePhrase)”")
            } else {
                bubble("First", "Hold \(settings.holdKey.label) and speak")
            }
            bubble("Then", "“Open Safari and go to google.com”")
            if let problem = listener.problem {
                Text(problem).font(.system(size: 13)).foregroundColor(Theme.danger)
            }
            Group {
                switch agent.phase {
                case .done:
                    StatusLine(ok: true, okText: "It worked — \(agent.result)", waitText: "")
                case .failed:
                    Text(agent.result).font(.system(size: 14)).foregroundColor(Theme.warn)
                case .working, .confirm, .handoff:
                    StatusLine(ok: false, okText: "", waitText: "Working on it — watch the panel in the corner…")
                case .idle:
                    StatusLine(ok: listener.mode == .awake, okText: "Awake — say your task", waitText: listener.mode == .holding ? "Listening…" : "Waiting for you to speak…")
                }
            }.padding(.top, 6)
        }
        .onAppear { AppDelegate.shared?.startServices() }
    }

    private func bubble(_ tag: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(tag).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.faint).frame(width: 44, alignment: .leading)
            Text(text).font(.system(size: 18, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink))
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle().fill(Color(hex: 0xE7F6EC)).frame(width: 64, height: 64)
                .overlay(Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundColor(Theme.success)).padding(.bottom, 18)
            Text("You're all set").font(.system(size: 32, weight: .semibold)).padding(.bottom, 8)
            Text("Flow Command now lives in your menu bar, top right of your screen.").font(.system(size: 16)).foregroundColor(Theme.muted).padding(.bottom, 24)
            HStack(spacing: 10) {
                tip("Wake it", settings.wakeEnabled ? "“\(settings.wakePhrase)”" : "Hold \(settings.holdKey.label)")
                tip("Just talk", "“Open GoHighLevel and switch accounts”")
                tip("Stop anytime", "Say “stop” or press Esc")
            }.frame(maxWidth: 560).padding(.bottom, 20)
            Toggle("Open Flow Command when I start my Mac", isOn: $startAtLogin).toggleStyle(.checkbox).font(.system(size: 15))
            Spacer()
            PrimaryButton(title: "Open Flow Command") {
                if startAtLogin { try? SMAppService.mainApp.register() }
                settings.onboarded = true
                onFinish()
            }.padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(body).font(.system(size: 13)).foregroundColor(Color(hex: 0x5E5E6A)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    // MARK: Footer + actions

    private var footer: some View {
        HStack {
            Button("Back") { step = max(0, step - 1) }.buttonStyle(.plain).foregroundColor(Theme.muted).font(.system(size: 15))
            Spacer()
            if step == 6 {
                Button("Skip") { step = 7 }.buttonStyle(.plain).foregroundColor(Theme.muted).font(.system(size: 15)).padding(.trailing, 14)
            }
            primaryForStep
        }
    }

    @ViewBuilder private var primaryForStep: some View {
        let _ = tick
        switch step {
        case 1:
            if Permissions.microphone && Permissions.speech { PrimaryButton(title: "Continue") { step = 2 } }
            else if AVAuthDenied.any { PrimaryButton(title: "Open System Settings") { Permissions.open(.microphone) } }
            else { PrimaryButton(title: "Allow microphone") { Permissions.requestMicrophoneAndSpeech { _ in tick += 1 } } }
        case 2:
            if Permissions.screen { PrimaryButton(title: "Continue") { step = 3 } }
            else {
                HStack(spacing: 10) {
                    SecondaryButton(title: "I turned it on — reopen") { AppDelegate.relaunch() }
                    PrimaryButton(title: "Allow screen access") { Permissions.requestScreen(); Permissions.open(.screen) }
                }
            }
        case 3:
            if Permissions.control { PrimaryButton(title: "Continue") { step = 4 } }
            else {
                HStack(spacing: 10) {
                    SecondaryButton(title: "Already on — reopen") { AppDelegate.relaunch() }
                    PrimaryButton(title: "Open System Settings") { Permissions.requestControl(); Permissions.open(.accessibility) }
                }
            }
        case 4:
            PrimaryButton(title: "Continue", enabled: settings.wakeEnabled || settings.holdKeyEnabled) {
                HotKeys.shared.cancelRecording(); recording = false; step = 5
            }
        case 5:
            PrimaryButton(title: "Continue", enabled: settings.privateMode || settings.hasAPIKey) { step = 6 }
        default:
            PrimaryButton(title: "Finish setup") { step = 7 }
        }
    }

    private func autoAdvance() {
        if step == 3, Permissions.control { step = 4 }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingKey = true
        keyMessage = nil
        Task {
            let err = await ClaudeClient.verify(key: key, model: settings.model)
            await MainActor.run {
                checkingKey = false
                if let err = err {
                    keyMessage = err
                } else {
                    settings.apiKey = key
                    keyDraft = ""
                    keyMessage = "✓ Key works and is saved in your Keychain."
                }
            }
        }
    }
}

/// True when the user previously said "Don't allow" (macOS won't ask again; they must use System Settings).
enum AVAuthDenied {
    static var any: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied || SFSpeechRecognizer.authorizationStatus() == .denied
    }
}
