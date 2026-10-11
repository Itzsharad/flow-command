import SwiftUI

/// The plain native pop-up (always works). Used for the Classic style and whenever the animated one isn't ready.
struct NativePanelView: View {
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var listener: Listener

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch agent.phase {
            case .idle: listening
            case .working: working
            case .confirm: question(title: "Check with you", tint: Theme.violetLight, yes: "Yes, do it", no: "No")
            case .handoff: question(title: "Your turn", tint: Color(hex: 0xF5A524), yes: "Continue", no: "Stop")
            case .done, .failed: finished
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(borderColor, lineWidth: 1.5))
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var borderColor: Color {
        switch agent.phase {
        case .confirm: return Theme.violetLight
        case .handoff: return Color(hex: 0xF5A524)
        default: return .white.opacity(0.06)
        }
    }

    private func dot(_ c: Color) -> some View {
        Circle().fill(c).frame(width: 10, height: 10).overlay(Circle().stroke(c.opacity(0.35), lineWidth: 4))
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                dot(listener.understanding ? Theme.violetLight : Theme.danger)
                Text(listener.understanding ? "Understanding…"
                     : listener.mode == .holding ? "Listening — let go when you're done" : "Listening — what should I do?")
                    .font(.system(size: 15, weight: .semibold))
            }
            Waveform(level: listener.level)
            if !listener.live.isEmpty {
                Text("“\(listener.live)”").font(.system(size: 15)).foregroundColor(Theme.panelText).lineLimit(3)
            } else {
                Text("Try: “Open Chrome and go to GoHighLevel”").font(.system(size: 13)).foregroundColor(Color(hex: 0xA9ADC4))
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 10) { dot(Theme.violetLight); Text("Working").font(.system(size: 15, weight: .semibold)) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(agent.startedAt))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 13).monospacedDigit()).foregroundColor(Color(hex: 0xA9ADC4))
                }
            }
            Text("“\(agent.instruction)”").font(.system(size: 14)).foregroundColor(Theme.panelText)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelSoft))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(agent.steps) { step in
                    HStack(spacing: 10) {
                        stepIcon(step.state)
                        Text(step.text).font(.system(size: 14, weight: step.state == .current ? .semibold : .regular)).lineLimit(2)
                    }
                }
                if !agent.status.isEmpty {
                    Text(agent.status).font(.system(size: 13)).foregroundColor(Color(hex: 0xA9ADC4))
                }
            }
            HStack(spacing: 10) {
                Button(action: { agent.stop() }) {
                    Text("Stop").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.danger))
                }.buttonStyle(.plain)
                Text("or press Esc / say “stop”").font(.system(size: 12)).foregroundColor(Color(hex: 0xA9ADC4)).fixedSize()
            }
        }
    }

    @ViewBuilder private func stepIcon(_ s: Agent.Step.State) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.green).frame(width: 16)
        case .current: ProgressView().controlSize(.mini).frame(width: 16).colorScheme(.dark)
        case .failed: Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.danger).frame(width: 16)
        }
    }

    private func question(title: String, tint: Color, yes: String, no: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: agent.phase == .handoff ? "lock" : "questionmark.circle").foregroundColor(tint)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(tint)
            }
            Text(agent.question).font(.system(size: 14)).foregroundColor(Theme.panelText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: { agent.respond(true) }) {
                    Text(yes).font(.system(size: 14, weight: .semibold)).foregroundColor(agent.phase == .handoff ? Theme.ink : .white)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).fill(agent.phase == .handoff ? Color.white : Theme.accent))
                }.buttonStyle(.plain)
                Button(action: { agent.respond(false) }) {
                    Text(no).font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: 0x3A3A46)))
                }.buttonStyle(.plain)
            }
            Text("Or just say “yes” or “no”.").font(.system(size: 12)).foregroundColor(Color(hex: 0xA9ADC4))
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(agent.phase == .done ? Theme.success : Theme.warn).frame(width: 28, height: 28)
                    Image(systemName: agent.phase == .done ? "checkmark" : "exclamationmark").font(.system(size: 13, weight: .bold))
                }
                Text(agent.result).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            }
            if let fix = agent.fix {
                Button(action: { fix.perform() }) {
                    Text(fix.title).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.accent))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct Waveform: View {
    var level: Float
    private let shape: [CGFloat] = [0.35, 0.65, 1.0, 0.55, 0.85, 0.45, 0.75, 0.3, 0.6, 0.4, 0.7, 0.5]
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(shape.enumerated()), id: \.offset) { _, f in
                Capsule().fill(Color.white).frame(width: 4, height: max(5, 34 * f * CGFloat(min(1, level * 1.4) + 0.08)))
            }
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
