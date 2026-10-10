import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

/// macOS permissions. Nothing here is ever requested automatically —
/// only when the user clicks the matching button during setup or in Settings.
enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var control: Bool { AXIsProcessTrusted() }

    static func requestMicrophoneAndSpeech(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            SFSpeechRecognizer.requestAuthorization { status in
                onMain { done(micOK && status == .authorized) }
            }
        }
    }

    static func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestControl() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case speech = "Privacy_SpeechRecognition"
        case screen = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
