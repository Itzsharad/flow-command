import Foundation

/// A saved voice shortcut: say the phrase, the steps run.
struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var phrase: String
    var steps: String

    static let examples: [Routine] = [
        Routine(phrase: "morning setup", steps: "open Gmail, open my calendar, open GoHighLevel"),
        Routine(phrase: "new chat", steps: "open claude.ai, click New chat"),
    ]

    /// "morning setup", "run morning setup", "do my morning setup routine" all match.
    static func match(_ text: String, in routines: [Routine]) -> Routine? {
        var said = WakeMatcher.words(text)
        let filler: Set<String> = ["run", "do", "start", "my", "the", "routine", "please", "okay", "ok", "now"]
        said.removeAll { filler.contains($0) }
        let s = said.joined(separator: " ")
        guard !s.isEmpty else { return nil }
        var best: (Routine, Int)?
        for r in routines {
            let p = WakeMatcher.words(r.phrase).filter { !filler.contains($0) }.joined(separator: " ")
            guard !p.isEmpty, !r.steps.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let d = WakeMatcher.distance(s, p)
            if d <= max(1, p.count / 6), best == nil || d < best!.1 { best = (r, d) }
        }
        return best?.0
    }
}
