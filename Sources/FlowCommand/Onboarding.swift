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
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(ok ? Theme.success : Theme.warn).frame(width: 8, height: 8).padding(.top, 5)
            Text(ok ? okText : waitText).font(.system(size: 14)).foregroundColor(ok ? Theme.success : Color(hex: 0x5E5E6A))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Toggle44: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("", isOn: $on).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
    }
}

/// True when the user previously said "Don't allow" (macOS won't ask again; they must use System Settings).
enum AVAuthDenied {
    static var any: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied || SFSpeechRecognizer.authorizationStatus() == .denied
    }
}

// MARK: - Setup: Welcome → Microphone → Click & type → How to wake it → Done

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var agent = Agent.shared
    @ObservedObject var listener = Listener.shared
    var onFinish: () -> Void

    @State private var tick = 0
    @State private var recording = false
    @State private var startAtLogin = true
    @ObservedObject private var whisper = Transcriber.shared
    @State private var browserMessage: String?
    @State private var settingUpBrowser = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let railLabels = ["Microphone", "Click & type", "How to wake it"]

    private var step: Int {
        get { min(settings.onboardingStep, 4) }
        nonmutating set { settings.onboardingStep = newValue }
    }

    var body: some View {
        Group {
            if step == 0 { welcome }
            else if step >= 4 { done }
            else {
                HStack(spacing: 0) {
                    rail
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Step \(step) of 3").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accentInk).padding(.bottom, 14)
                        if AppDelegate.runningFromInstaller {
                            Text("You're running Flow Command from the installer disk. Quit it, drag it into Applications and open it from there — otherwise macOS permissions won't stick.")
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
            Text("Say “Flow Command, activate” and tell it what to do — open apps and sites, type, click and get things done.")
                .font(.system(size: 17)).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 560).padding(.bottom, 32)
            PrimaryButton(title: "Get started  →") { step = 1 }
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 13))
                Text("Nothing is switched on yet. You'll approve each permission yourself.")
            }.font(.system(size: 14)).foregroundColor(Color(hex: 0x5E5E6A)).padding(.top, 28)
            Spacer()
            Divider()
            Text("Takes about a minute · 3 short steps").font(.system(size: 13)).foregroundColor(Theme.faint).frame(height: 48)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: micStep
        case 2: controlStep
        default: wakeStep
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
            header("mic", "Let Flow Command hear you", "One click — macOS will show two quick pop-ups. Click Allow on both.")
            CheckLine(text: "It only acts on what you say after the wake phrase or while you hold your key")
            CheckLine(text: "The menu bar icon fills in whenever it's listening")
            StatusLine(ok: ok, okText: "Allowed", waitText: AVAuthDenied.any ? "Blocked earlier — click the button to open Settings and turn it on." : "Not allowed yet").padding(.top, 6)
        }
    }

    private var controlStep: some View {
        let ok = tick >= 0 && Permissions.control
        return VStack(alignment: .leading, spacing: 12) {
            header("cursorarrow.click.2", "Let it click and type for you", "This is the one switch macOS makes you flip yourself — same as Wispr Flow. It lets Flow Command type, press keys and click when you ask.")
            VStack(alignment: .leading, spacing: 10) {
                Text("A settings window opens → turn on Flow Command → come back").font(.system(size: 13)).foregroundColor(Theme.faint)
                HStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "mic").foregroundColor(.white).font(.system(size: 14)))
                    Text("FlowCommand").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Capsule().fill(Theme.accent).frame(width: 40, height: 24).overlay(Circle().fill(.white).frame(width: 20, height: 20), alignment: .trailing).padding(.trailing, 2)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(.white)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
            }
            .padding(16).frame(maxWidth: 470).background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFAFAFC)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            StatusLine(ok: ok, okText: "Allowed", waitText: "Waiting — this screen moves on by itself once it's on. Already on? Remove the old FlowCommand entry with –, then turn on the new one.")
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var wakeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How do you want to wake it?").font(.system(size: 26, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                card(on: settings.wakeEnabled) {
                    HStack {
                        Label("Wake phrase", systemImage: "waveform").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Toggle44(on: $settings.wakeEnabled)
                    }
                    TextField("Flow Command, activate", text: $settings.wakePhrase).textFieldStyle(.roundedBorder).font(.system(size: 14))
                }
                card(on: settings.holdKeyEnabled) {
                    HStack {
                        Label("Hold a key", systemImage: "keyboard").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Toggle44(on: $settings.holdKeyEnabled)
                    }
                    HStack(spacing: 8) {
                        Text(recording ? "Press any key…" : settings.holdKey.label)
                            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xDAD5F5)))
                        Button(recording ? "Cancel" : "Change") {
                            if recording { HotKeys.shared.cancelRecording(); recording = false; return }
                            recording = true
                            HotKeys.shared.record { spec in settings.holdKey = spec; recording = false }
                        }.buttonStyle(.plain).foregroundColor(Theme.accentInk).font(.system(size: 13))
                    }
                }
            }
            // Live test
            VStack(alignment: .leading, spacing: 8) {
                Text("Try it now").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.faint)
                Text(settings.wakeEnabled
                     ? "Say “\(settings.wakePhrase)”, pause, then “open Chrome and go to google.com”"
                     : "Hold \(settings.holdKey.label), say “open Chrome and go to google.com”, let go")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink))
                liveStatus
            }
            .padding(.top, 4)
        }
        .onAppear { AppDelegate.shared?.startServices() }
    }

    @ViewBuilder private var liveStatus: some View {
        if let problem = listener.problem {
            Text(problem).font(.system(size: 13)).foregroundColor(Theme.danger)
        } else {
            switch agent.phase {
            case .done: StatusLine(ok: true, okText: "It worked — \(agent.result)", waitText: "")
            case .failed: Text(agent.result).font(.system(size: 13)).foregroundColor(Theme.warn)
            case .working, .confirm, .handoff: StatusLine(ok: false, okText: "", waitText: "Working on it — watch the panel in the corner…")
            case .idle:
                if listener.mode == .awake || listener.mode == .holding {
                    StatusLine(ok: true, okText: listener.live.isEmpty ? "Listening…" : "Heard: “\(listener.live)”", waitText: "")
                } else {
                    StatusLine(ok: false, okText: "", waitText: "Waiting for you to speak…")
                }
            }
        }
    }

    private func card<C: View>(on: Bool, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10, content: c)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? Color(hex: 0xF7F5FF) : .white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Theme.accent : Theme.hairline, lineWidth: on ? 1.5 : 1))
            .opacity(on ? 1 : 0.7)
    }

    private var done: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle().fill(Color(hex: 0xE7F6EC)).frame(width: 64, height: 64)
                .overlay(Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundColor(Theme.success)).padding(.bottom, 18)
            Text("You're all set").font(.system(size: 32, weight: .semibold)).padding(.bottom, 8)
            Text("Flow Command lives in your menu bar, top right of your screen.").font(.system(size: 16)).foregroundColor(Theme.muted).padding(.bottom, 24)
            HStack(spacing: 10) {
                tip("Instant & free", "“Open Chrome, go to claude.ai, type hello and press enter”")
                tip("Bigger tasks", "Add the free AI brain in Settings when you want it")
                tip("Stop anytime", "Say “stop” or press Esc")
            }.frame(maxWidth: 600).padding(.bottom, 16)
            boosts.frame(maxWidth: 600).padding(.bottom, 16)
            Toggle("Open Flow Command when I start my Mac", isOn: $startAtLogin).toggleStyle(.checkbox).font(.system(size: 15))
            Spacer()
            PrimaryButton(title: "Done") {
                if startAtLogin { try? SMAppService.mainApp.register() }
                settings.onboarded = true
                onFinish()
            }.padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    /// Two optional speed-ups, shown on the last screen.
    private var boosts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic").foregroundColor(Theme.accentInk).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accent-accurate speech").font(.system(size: 14, weight: .semibold))
                    Text(whisperText).font(.system(size: 12)).foregroundColor(Theme.muted)
                }
                Spacer()
                if case .downloading(let f) = whisper.state { ProgressView(value: f).frame(width: 90) }
                if whisper.state == .ready { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success) }
            }
            if let b = settings.preferredBrowser, Browser.chromium[b] != nil {
                let _ = tick
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").foregroundColor(Theme.accentInk).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make \(b) instant").font(.system(size: 14, weight: .semibold))
                        Text(browserMessage ?? "Clicks buttons directly instead of looking at screenshots — about 10× faster.")
                            .font(.system(size: 12)).foregroundColor(browserMessage == nil ? Theme.muted : Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if Browser.ready {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                    } else {
                        Button(settingUpBrowser ? "Turning on…" : "Turn on") {
                            settingUpBrowser = true
                            Task { @MainActor in
                                browserMessage = await Browser.setUp(b)
                                settingUpBrowser = false
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }.disabled(settingUpBrowser)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFAFAFC)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private var whisperText: String {
        switch whisper.state {
        case .ready: return "Ready — runs on your Mac, works offline"
        case .downloading(let f): return "Downloading in the background (\(Transcriber.sizeLabel)) — \(Int(f * 100))%. You can use Flow Command meanwhile."
        case .preparing: return "Almost ready — getting the model set up"
        case .failed(let m): return "Will retry later (\(m))"
        case .notInstalled, .off: return "Downloads in the background (\(Transcriber.sizeLabel)) once setup finishes"
        }
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
            primaryForStep
        }
    }

    @ViewBuilder private var primaryForStep: some View {
        let _ = tick
        switch step {
        case 1:
            if Permissions.microphone && Permissions.speech { PrimaryButton(title: "Continue") { step = 2 } }
            else if AVAuthDenied.any { PrimaryButton(title: "Open System Settings") { Permissions.open(.microphone) } }
            else { PrimaryButton(title: "Allow microphone") { Permissions.requestMicrophoneAndSpeech { ok in tick += 1; if ok { step = 2 } } } }
        case 2:
            if Permissions.control { PrimaryButton(title: "Continue") { step = 3 } }
            else {
                HStack(spacing: 10) {
                    Button("Skip for now") { step = 3 }.buttonStyle(.plain).foregroundColor(Theme.muted).font(.system(size: 14)).padding(.trailing, 4)
                    PrimaryButton(title: "Open settings") { Permissions.requestControl(); Permissions.open(.accessibility) }
                }
            }
        default:
            PrimaryButton(title: "Finish", enabled: settings.wakeEnabled || settings.holdKeyEnabled) {
                HotKeys.shared.cancelRecording(); recording = false; step = 4
            }
        }
    }

    private func autoAdvance() {
        if step == 2, Permissions.control {
            step = 3
            HotKeys.shared.start()
            NSApp.activate(ignoringOtherApps: true)   // bring setup back to the front
        }
    }
}
