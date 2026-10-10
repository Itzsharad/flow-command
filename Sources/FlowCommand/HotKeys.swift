import AppKit

/// Watches the keyboard for the hold-to-talk key and Esc.
/// Uses listen-only monitors: it can never block or swallow your typing.
final class HotKeys {
    static let shared = HotKeys()

    var onHoldDown: (() -> Void)?
    var onHoldUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var held = false
    private var recorder: ((HotKeySpec) -> Void)?
    private var recPeak: NSEvent.ModifierFlags = []
    private var recFirstModifier: UInt16?
    private let settings = AppSettings.shared

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        held = false
    }

    /// Next key (or key combination) the user presses becomes the hold-to-talk key.
    func record(_ done: @escaping (HotKeySpec) -> Void) {
        recPeak = []
        recFirstModifier = nil
        recorder = done
        start()
    }

    func cancelRecording() { recorder = nil }

    private func finishRecording(_ spec: HotKeySpec) {
        let done = recorder
        recorder = nil
        onMain { done?(spec) }
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(ModifierKeys.all)

        if recorder != nil {
            switch e.type {
            case .flagsChanged:
                if recFirstModifier == nil, !mods.isEmpty { recFirstModifier = e.keyCode }
                recPeak.formUnion(mods)
                if mods.isEmpty, !recPeak.isEmpty {
                    let count = [NSEvent.ModifierFlags.command, .option, .control, .shift, .function].filter { recPeak.contains($0) }.count
                    if count == 1, let code = recFirstModifier {
                        finishRecording(HotKeySpec(kind: .modifierKey, keyCode: code, label: ModifierKeys.names[code] ?? "modifier"))
                    } else {
                        finishRecording(HotKeySpec(kind: .modifierCombo, modifiers: recPeak.rawValue, label: ModifierKeys.label(for: recPeak)))
                    }
                }
            case .keyDown where !e.isARepeat:
                if e.keyCode == 53 { recorder = nil; return }   // Esc cancels recording
                let name = keyName(e)
                let prefix = mods.isEmpty ? "" : ModifierKeys.label(for: mods) + " "
                finishRecording(HotKeySpec(kind: .key, keyCode: e.keyCode, modifiers: mods.rawValue, label: prefix + name))
            default:
                break
            }
            return
        }

        if e.type == .keyDown, e.keyCode == 53, !e.isARepeat { onMain { self.onEscape?() } }

        guard settings.holdKeyEnabled else { return }
        let spec = settings.holdKey
        var down: Bool?
        switch spec.kind {
        case .modifierKey:
            guard e.type == .flagsChanged, e.keyCode == spec.keyCode else { break }
            if spec.keyCode == 63 {
                down = mods.contains(.function)
            } else if let bit = ModifierKeys.deviceBit[spec.keyCode] {
                down = (e.modifierFlags.rawValue & bit) != 0
            }
        case .modifierCombo:
            guard e.type == .flagsChanged else { break }
            down = mods.rawValue == spec.modifiers
        case .key:
            if e.type == .keyDown, e.keyCode == spec.keyCode, !e.isARepeat, mods.rawValue == spec.modifiers { down = true }
            if e.type == .keyUp, e.keyCode == spec.keyCode { down = false }
        }
        guard let isDown = down, isDown != held else { return }
        held = isDown
        onMain { isDown ? self.onHoldDown?() : self.onHoldUp?() }
    }

    private func keyName(_ e: NSEvent) -> String {
        let special: [UInt16: String] = [49: "space", 36: "return", 48: "tab", 51: "delete", 122: "F1", 120: "F2",
                                         99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
                                         109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let s = special[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "key").uppercased()
    }
}
