import AVFoundation
import Foundation
import WhisperKit

/// Accent-accurate speech: keeps the last minute of microphone audio (16 kHz mono) and turns
/// what you said into text with OpenAI's Whisper model, running entirely on this Mac.
/// Apple's recogniser is still used for the live preview and the wake phrase.
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    enum State: Equatable {
        case off, notInstalled, downloading(Double), preparing, ready, failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    static let variant = "large-v3-v20240930_turbo_632MB"
    static let sizeLabel = "630 MB"
    /// Words people say that Whisper should spell this way.
    static let vocabulary = "Flow Command, Claude, claude.ai, ChatGPT, Gmail, GoHighLevel, GitHub, Chrome, Safari, WhatsApp, Notion, Canva, YouTube."

    private var kit: WhisperKit?
    private var promptTokens: [Int]?
    private var preparing = false

    // Audio ring buffer, written on the audio thread.
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 16_000 * 60)
    private var written = 0               // total samples ever written
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var isReady: Bool { state == .ready && AppSettings.shared.whisperEnabled }

    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowCommand/models", isDirectory: true)
    }

    // MARK: Setup

    /// Downloads the model once (about 630 MB), then loads it. Safe to call repeatedly.
    func prepare() {
        guard AppSettings.shared.whisperEnabled else { onMain { self.state = .off }; return }
        guard !preparing, kit == nil else { return }
        preparing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.load()
        }
    }

    private func load() async {
        defer { preparing = false }
        let d = UserDefaults.standard
        do {
            try FileManager.default.createDirectory(at: Transcriber.modelsDir, withIntermediateDirectories: true)
            var folder = d.string(forKey: "whisperFolder").flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            if folder == nil {
                onMain { self.state = .downloading(0) }
                let url = try await WhisperKit.download(variant: Transcriber.variant, downloadBase: Transcriber.modelsDir) { p in
                    let f = p.fractionCompleted
                    onMain { self.state = .downloading(f) }
                }
                folder = url.path
                d.set(url.path, forKey: "whisperFolder")
            }
            onMain { self.state = .preparing }
            let config = WhisperKitConfig(downloadBase: Transcriber.modelsDir, modelFolder: folder,
                                          verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
            let k = try await WhisperKit(config)
            if let tok = k.tokenizer {
                promptTokens = tok.encode(text: " " + Transcriber.vocabulary).filter { $0 < tok.specialTokens.specialTokenBegin }
            }
            kit = k
            onMain { self.state = .ready }
        } catch {
            onMain { self.state = .failed(error.localizedDescription) }
        }
    }

    /// Deletes the model (frees the disk space).
    func remove() {
        kit = nil
        UserDefaults.standard.removeObject(forKey: "whisperFolder")
        try? FileManager.default.removeItem(at: Transcriber.modelsDir)
        onMain { self.state = AppSettings.shared.whisperEnabled ? .notInstalled : .off }
    }

    // MARK: Audio (called from the microphone thread)

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard kit != nil else { return }   // only once Whisper is ready (keeps the microphone path light)
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter = converter else { return }
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let data = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        lock.lock()
        for i in 0..<n { ring[(written + i) % ring.count] = data[i] }
        written += n
        lock.unlock()
    }

    /// A position in the audio stream, optionally a little in the past.
    func mark(secondsBack: Double = 0) -> Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, written - Int(secondsBack * 16_000))
    }

    /// The audio from `mark` until now.
    func samples(from mark: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = max(mark, written - ring.count, 0)
        guard written > start else { return [] }
        return (start..<written).map { ring[$0 % ring.count] }
    }

    // MARK: Transcription

    /// Returns nil when Whisper isn't ready or heard nothing useful (the caller then uses Apple's text).
    func transcribe(_ audio: [Float]) async -> String? {
        guard let kit = kit, audio.count > 16_000 / 3 else { return nil }
        let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0,
                                      skipSpecialTokens: true, withoutTimestamps: true,
                                      promptTokens: promptTokens)
        guard let results = try? await kit.transcribe(audioArray: audio, decodeOptions: options) else { return nil }
        return Transcriber.tidy(results.map(\.text).joined(separator: " "))
    }

    /// Removes Whisper's markers ("[BLANK_AUDIO]", "(music)") and the phrases it invents on silence.
    static func tidy(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)|<\\|[^|]*\\|>", with: " ", options: .regularExpression)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        let invented = ["", "thank you", "thanks for watching", "thank you for watching", "you", "bye", "okay"]
        if invented.contains(bare) { return nil }
        if bare == vocabulary.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .")) { return nil }
        // "Open Chrome." → "Open Chrome" (keeps "claude.ai" intact)
        while let last = t.last, ".!?".contains(last) { t.removeLast() }
        return t.isEmpty ? nil : t
    }
}
