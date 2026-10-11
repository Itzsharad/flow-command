import AVFoundation
import Foundation
import Speech

/// Passes microphone audio to the current speech request (called on the audio thread).
private final class AudioBox {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    var wantsLevel = false

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request?.endAudio(); request = r; lock.unlock()
    }

    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); request?.append(b); lock.unlock()
    }
}

/// The "ears". Speech is turned into text on this Mac (Apple on-device recognition).
/// Asleep: only listens for the wake phrase. Awake: every pause ends an instruction.
final class Listener: ObservableObject {
    static let shared = Listener()

    enum Mode: Equatable { case off, asleep, awake, holding }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var live = ""
    @Published private(set) var level: Float = 0
    @Published var problem: String?

    var onInstruction: ((String) -> Void)?
    var onWake: (() -> Void)?
    var onSleep: (() -> Void)?
    var onStopWord: (() -> Void)?
    /// While the agent is waiting for "yes"/"no"/"continue" it intercepts what you say.
    var replyInterceptor: ((String) -> Bool)?
    var isBusy: () -> Bool = { false }

    private let settings = AppSettings.shared
    private let engine = AVAudioEngine()
    private let box = AudioBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var current = ""
    private var carry = ""
    private var lastChange = Date()
    private var lastActivity = Date()
    private var taskStarted = Date()
    private var ticker: Timer?
    private var engineRunning = false
    private var quickFailures = 0
    private var started = false
    /// Falls back to Apple's online recognition when on-device speech isn't installed (no Dictation setup needed).
    private var useServer = false
    /// Where the current instruction's audio starts (for Whisper), and whether it begins with the wake phrase.
    private var audioMark = 0
    private var audioHasWakePhrase = false
    @Published private(set) var understanding = false

    var pending: String { (carry + " " + current).trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Lifecycle

    func start() {
        guard !started else { reconfigure(); return }
        Log.write("listener start · mic=\(Permissions.microphone) speech=\(Permissions.speech)")
        guard Permissions.microphone, Permissions.speech else {
            problem = "Microphone or speech permission is off."
            return
        }
        started = true
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        Log.write("recognizer available=\(recognizer?.isAvailable ?? false) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        if let r = recognizer, !r.supportsOnDeviceRecognition {
            if settings.privateMode {
                problem = "On-device speech isn't installed. Turn on Dictation in System Settings › Keyboard, or turn off Private mode."
            } else {
                useServer = true
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        reconfigure()
    }

    func shutdown() {
        ticker?.invalidate(); ticker = nil
        stopEngine()
        mode = .off
        started = false
    }

    /// Call after settings change.
    func reconfigure() {
        guard started else { return }
        if settings.wakeEnabled {
            if !engineRunning { startEngine() }
            if mode == .off { mode = .asleep }
        } else if mode == .asleep || mode == .off {
            stopEngine()
            mode = .off
        }
    }

    /// Something happened (a task finished) — restart the go-back-to-sleep timer.
    func touch() { lastActivity = Date() }

    // MARK: Waking and sleeping

    func wakeNow() {
        guard started else { return }
        if !engineRunning { startEngine() }
        carry = ""; live = ""
        audioMark = Transcriber.shared.mark(secondsBack: 0.3)
        audioHasWakePhrase = false
        mode = .awake
        lastActivity = Date()
        box.wantsLevel = true
        restartRecognition()
        Sound.play("Pop")
        onWake?()
    }

    func sleep() {
        carry = ""; live = ""
        box.wantsLevel = false
        level = 0
        if settings.wakeEnabled {
            mode = .asleep
            restartRecognition()
        } else {
            mode = .off
            stopEngine()
        }
        onSleep?()
    }

    func holdBegan() {
        Log.write("hold began · started=\(started) mode=\(mode)")
        guard started, mode != .holding else { return }
        if !engineRunning { startEngine() }
        carry = ""; live = ""
        audioMark = Transcriber.shared.mark(secondsBack: 0.3)
        audioHasWakePhrase = false
        mode = .holding
        lastActivity = Date()
        box.wantsLevel = true
        restartRecognition()
        Sound.play("Pop")
    }

    func holdEnded() {
        Log.write("hold ended · heard \(pending.count) chars")
        guard mode == .holding else { return }
        // give the recogniser a moment to finish the last word
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.mode == .holding else { return }
            self.submit()
            if !self.isBusy() { self.sleep() } else { self.mode = self.settings.wakeEnabled ? .asleep : .off }
        }
    }

    // MARK: Audio

    private func startEngine() {
        guard !engineRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Log.write("mic format \(format.sampleRate)Hz \(format.channelCount)ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone found."
            return
        }
        input.removeTap(onBus: 0)
        let box = self.box
        let whisper = Transcriber.shared
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            box.append(buffer)
            whisper.feed(buffer)
            guard box.wantsLevel, let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = min(1, sqrt(sum / Float(n)) * 12)
            DispatchQueue.main.async { self?.level = rms }
        }
        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
            Log.write("mic running")
            restartRecognition()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            Log.write("mic start failed: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        task?.cancel(); task = nil
        box.set(nil)
        guard engineRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engineRunning = false
    }

    private func restartRecognition() {
        task?.cancel(); task = nil
        current = ""
        generation += 1
        let gen = generation
        guard engineRunning, let rec = recognizer, rec.isAvailable else {
            Log.write("recognition not started · engine=\(engineRunning) available=\(recognizer?.isAvailable ?? false)")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition && !useServer { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = false
        req.contextualStrings = [settings.wakePhrase, "Claude", "GoHighLevel", "Attractclient", "ChatGPT", "GitHub"]
        box.set(req)
        taskStarted = Date()
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                if let result = result { self.heard(result.bestTranscription.formattedString) }
                let ended = error != nil || (result?.isFinal ?? false)
                guard ended else { return }
                if let e = error as NSError? { Log.write("recognition ended: \(e.domain) \(e.code) \(e.localizedDescription) · server=\(self.useServer)") }
                if self.mode == .awake || self.mode == .holding { self.carry = self.pending; self.current = "" }
                // Back off if the recogniser keeps failing straight away (never spin).
                if Date().timeIntervalSince(self.taskStarted) < 1.5 {
                    self.quickFailures += 1
                } else {
                    self.quickFailures = 0
                }
                if self.quickFailures >= 2, !self.useServer, !self.settings.privateMode {
                    self.useServer = true          // on-device model missing: switch quietly
                    self.quickFailures = 0
                }
                if self.quickFailures >= 5 {
                    self.problem = "Speech recognition isn't responding. Check your internet connection, or turn on Dictation in System Settings › Keyboard, then restart Flow Command."
                    return
                }
                let delay = self.quickFailures > 0 ? 1.0 * Double(self.quickFailures) : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, gen == self.generation else { return }
                    self.restartRecognition()
                }
            }
        }
    }

    // MARK: Understanding

    private func heard(_ text: String) {
        if text != current {
            current = text
            lastChange = Date()
        }
        switch mode {
        case .asleep:
            if let rest = WakeMatcher.match(text, phrase: settings.wakePhrase) {
                Log.write("wake phrase heard")
                let carried = rest.joined(separator: " ")
                wakeNow()
                if !carried.isEmpty {
                    // The instruction started in the same breath as the wake phrase — include that audio.
                    audioMark = Transcriber.shared.mark(secondsBack: min(8, Date().timeIntervalSince(taskStarted)))
                    audioHasWakePhrase = true
                }
                carry = carried
                live = carried
                lastChange = Date()
            } else if Date().timeIntervalSince(taskStarted) > 50 {
                restartRecognition()
            }
        case .awake, .holding:
            lastActivity = Date()
            live = pending
            if isBusy(), WakeMatcher.isStop(pending) {
                carry = ""; live = ""
                restartRecognition()
                onStopWord?()
            }
        case .off:
            break
        }
    }

    private func tick() {
        guard mode == .awake else { return }
        let p = pending
        if !p.isEmpty, Date().timeIntervalSince(lastChange) > Listener.pauseNeeded(after: p) {
            submit()
        } else if p.isEmpty, !isBusy(), replyInterceptor == nil, settings.sleepAfter > 0,
                  Date().timeIntervalSince(lastActivity) > Double(settings.sleepAfter) {
            sleep()
        }
    }

    /// How long a pause ends an instruction. Longer when the sentence clearly isn't finished ("…and", "…to the").
    static func pauseNeeded(after text: String) -> Double {
        let last = WakeMatcher.words(text).last ?? ""
        let unfinished = ["and", "then", "to", "the", "a", "an", "of", "for", "in", "on", "with", "into", "type", "write",
                          "search", "open", "go", "click", "my", "at", "from", "about", "so", "but", "or", "is", "that"]
        return unfinished.contains(last) ? 3.5 : 1.8
    }

    private func submit() {
        let p = pending
        Log.write("submit · \(p.count) chars, whisper ready=\(Transcriber.shared.isReady)")
        let whisper = Transcriber.shared
        let audio = whisper.isReady ? whisper.samples(from: audioMark) : []
        let hadWake = audioHasWakePhrase
        audioMark = whisper.mark()
        audioHasWakePhrase = false
        carry = ""; live = ""
        restartRecognition()
        guard !p.isEmpty || audio.count > 16_000 else { return }
        lastActivity = Date()
        // Quick replies (yes / no / stop / sleep) use the instant text.
        if !p.isEmpty {
            if let intercept = replyInterceptor, intercept(p) { return }
            if isBusy() {
                if WakeMatcher.isStop(p) { onStopWord?() }
                return
            }
            if WakeMatcher.isSleep(p) { sleep(); return }
        } else if isBusy() || replyInterceptor != nil {
            return
        }
        guard !audio.isEmpty else { onInstruction?(p); return }
        // The instruction itself: Whisper's more accurate text (falls back to the instant text).
        understanding = true
        live = p
        let phrase = settings.wakePhrase
        Task {
            var text = await whisper.transcribe(audio)
            if let t = text, hadWake { text = Listener.dropWakePhrase(t, phrase: phrase) }
            await MainActor.run {
                self.understanding = false
                self.live = ""
                let final = (text?.isEmpty == false ? text! : p)
                guard !final.isEmpty else { return }
                self.onInstruction?(final)
            }
        }
    }

    /// "Flow Command, activate. Open Chrome" → "Open Chrome" (keeps the original casing).
    static func dropWakePhrase(_ text: String, phrase: String) -> String {
        guard let rest = WakeMatcher.match(text, phrase: phrase) else { return text }
        guard !rest.isEmpty else { return "" }
        // Find where the remaining words start in the original text.
        let tokens = text.split(whereSeparator: { $0 == " " }).map(String.init)
        let skipWords = WakeMatcher.words(text).count - rest.count
        var i = 0
        while i < tokens.count, WakeMatcher.words(tokens[0..<i].joined(separator: " ")).count < skipWords { i += 1 }
        let keep = tokens[i...].joined(separator: " ")
        return keep.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
    }
}
