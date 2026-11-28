import SwiftUI
import PoljeNieukCore

/// Float → Int for display. Never traps on NaN/inf (that would take the whole window down).
@inline(__always) func ri(_ v: Float) -> Int {
    guard v.isFinite else { return 0 }
    return Int(min(max(v, -1e9), 1e9))
}

/// Finite-or-zero for anything that ends up as a size.
@inline(__always) func fin(_ v: Float) -> Float { v.isFinite ? v : 0 }

/// Live values from the audio thread, polled ~20 times a second.
struct ReadoutView: View {
    let kind: String
    let node: DSPNode?
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    let spec: ModuleSpec

    var body: some View {
        switch kind {
        case "looper", "sampler", "stretch":
            if let node, let b = node as? SampleBufferNode {
                VStack(spacing: 4) {
                    LiveView(signature: {
                        LiveSig.readouts(node, 12, steps: 100) &* 3 &+ (model.isRunning ? 1 : 2) &+ b.contentVersion &* 7
                    }) {
                        if model.isRunning { bufferStatus(node) } else { idleStatus(b) }
                    }
                        .font(Theme.mono)
                        .frame(height: 14)
                    WaveformView(node: node, buffer: b, model: model, patchNode: patchNode, spec: spec)
                }
                .padding(.vertical, 3)
            }
        case "keys":
            if let k = node as? KeysNode { KeysView(node: k, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "seq":
            if let n = node as? SeqNode { SeqView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "turing":
            if let t = node as? TuringNode { TuringView(node: t, model: model).padding(.vertical, 4) }
        case "roll":
            if let n = node as? RollNode { GridEditor(kind: .roll(n), model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "drums":
            // 3 pt top/bottom = the port rows' padding, so lane k sits exactly beside outlet k
            if let n = node as? DrumsNode { GridEditor(kind: .drums(n), model: model, patchNode: patchNode).padding(.vertical, 3) }
        case "comp":
            if let node { CompView(node: node) }
        case "lfo":
            if let node { LFOView(node: node, patchNode: patchNode) }
        case "chord":
            if let n = node { ChordView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "wave":
            if let w = node as? WavetableNode { WaveDrawView(node: w, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "scope":
            if let s = node as? ScopeNode { ScopeView(node: s, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "drumsynth":
            if let n = node as? DrumSynthNode { DrumSynthView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "rack":
            if let n = node as? RackNode { RackView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "slider", "knob":
            if let node {
                ControlsView(style: kind == "slider" ? .slider : .knob, node: node, model: model, patchNode: patchNode)
                    .padding(.vertical, 4)
            }
        case "peq":
            if let node {
                EQCurveView(node: node, sampleRate: model.host.sampleRate, model: model, patchNode: patchNode, spec: spec)
                    .padding(.vertical, 4)
            }
        default:
            liveBody
        }
    }

    /// Audio off: the module isn't running, so describe the buffer itself.
    func idleStatus(_ b: SampleBufferNode) -> some View {
        let secs = Double(b.waveLength) / max(model.host.sampleRate, 1)
        return HStack(spacing: 6) {
            Text(b.waveLength > 0 ? "loaded — audio off" : "empty — REC or load").foregroundStyle(Theme.dim)
            Spacer()
            Text(String(format: "%.2fs", secs)).foregroundStyle(Theme.dim).font(Theme.monoSmall)
        }
    }

    @ViewBuilder private func bufferStatus(_ node: DSPNode) -> some View {
        let r = node.readouts
        switch kind {
        case "looper":
            let state = min(max(ri(r[0]), 0), 6)
            let names = ["empty", "armed", "REC", "play", "DUB", "stop", "REC→"]
            let isRec = state == 2 || state == 4 || state == 6
            HStack(spacing: 6) {
                Text(names[state]).foregroundStyle(isRec ? Theme.rec : Theme.text)
                Spacer()
                Text(String(format: "%.2fs", fin(r[2]))).foregroundStyle(Theme.dim).font(Theme.monoSmall)
            }
        case "sampler":
            let st = ri(r[0])
            HStack(spacing: 6) {
                Text(st == 1 ? "REC" : st == 2 ? "\(ri(r[2])) slices" : "empty — REC or load")
                    .foregroundStyle(st == 1 ? Theme.rec : Theme.text)
                if st == 2 { Text("▸ \(ri(r[3]))").foregroundStyle(Theme.dim) }
                if st == 2 && ri(r[4]) == 3 { Text("stopped").foregroundStyle(Theme.dim) }
                Spacer()
                Text(String(format: "%.2fs", fin(r[1]))).foregroundStyle(Theme.dim).font(Theme.monoSmall)
            }
        default: // stretch
            let st = ri(r[0])
            HStack(spacing: 6) {
                Text(st == 1 ? "REC" : st == 2 ? "stretching" : "empty — REC or load")
                    .foregroundStyle(st == 1 ? Theme.rec : Theme.text)
                Spacer()
                Text(String(format: "%.2fs", fin(r[1]))).foregroundStyle(Theme.dim).font(Theme.monoSmall)
            }
        }
    }

    var liveBody: some View {
        // the readout text and small displays: drawn natively, only when their numbers change
        let sig: () -> Int = { [node, patchNode, model] in
            LiveSig.readouts(node, 24, steps: 200) &+ LiveSig.patch(patchNode) &* 3 &+ (model.isRunning ? 1 : 0)
        }
        return Group {
            if kind == "clock" {
                VStack(alignment: .leading, spacing: 3) {
                    LiveCanvas(signature: sig) { ctx, size in drawLive(ctx, size) }
                        .frame(height: 14)
                    TransportButtons(model: model)
                }
            } else {
                LiveCanvas(signature: sig) { ctx, size in drawLive(ctx, size) }
            }
        }
    }

    /// One line of text at the left / right of a readout.
    func text(_ ctx: LiveGC, _ s: String, _ x: CGFloat, _ y: CGFloat, _ c: Color, size: CGFloat = 11, right: Bool = false) {
        ctx.draw(LiveText(s, size: size, color: c), at: CGPoint(x: x, y: y), anchor: right ? .trailing : .leading)
    }

    func drawLive(_ ctx: LiveGC, _ size: CGSize) {
        guard let node else { text(ctx, "—", 0, size.height / 2, Theme.dim); return }
        let r = node.readouts, w = size.width, mid = size.height / 2
        switch kind {
        case "clock":
            let src = r[3] > 0.5 ? (r[2] > 0.5 ? "EXT" : "EXT --") : "INT"
            text(ctx, src, 0, mid, Theme.dim)
            text(ctx, String(format: "%.1f bpm", r[0]), CGFloat(src.count) * 6.6 + 6, mid, Theme.text)
            for b in 0..<4 {
                let x = w - CGFloat(4 - b) * 9 + 1
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: mid - 3, width: 6, height: 6)),
                         with: .color(ri(r[1]) == b && r[2] > 0.5 ? Theme.text : Theme.faint))
            }
        case "grain":
            text(ctx, "grains \(ri(r[0]))", 0, mid, Theme.text)
            if r[1] > 0.5 { text(ctx, "frozen", w, mid, Theme.text, right: true) }
        case "rec":
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: mid - 4, width: 8, height: 8)), with: .color(r[1] > 0.5 ? Theme.rec : Theme.faint))
            text(ctx, r[1] > 0.5 ? "REC" : "idle", 14, mid, r[1] > 0.5 ? Theme.rec : Theme.dim)
            text(ctx, timeString(r[0]), w, mid, Theme.text, right: true)
        case "comp", "limit":
            text(ctx, "GR", 0, mid, Theme.dim)
            let label = String(format: "%4.1f", r[0])
            let barX: CGFloat = 20, barW = max(w - barX - 34, 4)
            drawGainReduction(ctx, CGRect(x: barX, y: mid - 2, width: barW, height: 4), fin(r[0]))
            text(ctx, label, w, mid, Theme.text, size: 9, right: true)
        case "repeat":
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: mid - 3.5, width: 7, height: 7)), with: .color(r[0] > 0.5 ? Theme.text : Theme.faint))
            text(ctx, r[0] > 0.5 ? "repeating" : "waiting", 13, mid, r[0] > 0.5 ? Theme.text : Theme.dim)
        case "gain", "mix", "smix":
            drawMeter(ctx, CGRect(x: 0, y: mid - 5, width: w, height: 4), r[0])
            drawMeter(ctx, CGRect(x: 0, y: mid + 1, width: w, height: 4), r[1])
        default:
            break
        }
    }

    func timeString(_ s: Float) -> String {
        let t = max(ri(s), 0)
        return String(format: "%02d:%02d.%d", t / 60, t % 60, max(ri((fin(s) - Float(t)) * 10), 0))
    }
}

/// Classic green / yellow / red level meter (dB scale, -60…0).
struct Meter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(fin(level), 1e-5))
            let f = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.row)
                Rectangle().fill(LinearGradient(stops: [
                    .init(color: Theme.meterGreen, location: 0),
                    .init(color: Theme.meterGreen, location: 0.7),
                    .init(color: Theme.meterYellow, location: 0.88),
                    .init(color: Theme.meterRed, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
                .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * f) }
            }
        }
        .frame(height: 4)
    }
}

/// Meter for one hardware channel of in/out.
struct ChannelMeter: View {
    let node: DSPNode?
    let channel: Int
    var body: some View {
        LiveCanvas(signature: { LiveSig.q(node.map { $0.readouts[min(channel, DSPNode.readoutCount - 1)] } ?? 0, 60) }, every: 2) { ctx, size in
            drawMeter(ctx, CGRect(origin: .zero, size: size), node.map { $0.readouts[min(channel, DSPNode.readoutCount - 1)] } ?? 0)
        }
        .frame(height: 4)
    }
}

struct GainReduction: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .trailing) {
                Rectangle().fill(Theme.row)
                Rectangle().fill(Theme.meterYellow).frame(width: g.size.width * CGFloat(min(max(fin(db) / 24, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct ProgressBar: View {
    let value: CGFloat
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.row)
                Rectangle().fill(color.opacity(0.85)).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}



/// ▶ ❚❚ ■ on the clock box. Pause holds the beat where it is; stop also rewinds, so ▶ starts everything
/// from its first step.
struct TransportButtons: View {
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    var body: some View {
        HStack(spacing: 1) {
            button("play.fill", .play, "Play")
            button("pause.fill", .pause, "Pause: the beat holds where it is")
            button("stop.fill", .stop, "Stop: hold and go back to the start")
        }
    }
    func button(_ icon: String, _ t: GraphHost.Transport, _ help: String) -> some View {
        let on = model.transport == t
        return Button { model.setTransport(t) } label: {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
                .foregroundStyle(on ? Theme.text : Theme.dim.opacity(0.7))
                .frame(width: 18, height: 16)
                .background(on ? Theme.fill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Classic green / yellow / red level meter (dB scale, -60…0), drawn natively.
func drawMeter(_ ctx: LiveGC, _ rect: CGRect, _ level: Float) {
    let db = 20 * log10(max(fin(level), 1e-5))
    let f = CGFloat(min(max((db + 60) / 60, 0), 1))
    ctx.fill(Path(rect), with: .color(Theme.row))
    ctx.fillGradient(rect, [(Theme.meterGreen, 0), (Theme.meterGreen, 0.7), (Theme.meterYellow, 0.88), (Theme.meterRed, 1)], upTo: f)
}

/// Compressor / limiter gain reduction: grows from the right.
func drawGainReduction(_ ctx: LiveGC, _ rect: CGRect, _ db: Float) {
    ctx.fill(Path(rect), with: .color(Theme.row))
    let w = rect.width * CGFloat(min(max(db / 24, 0), 1))
    ctx.fill(Path(CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height)), with: .color(Theme.meterYellow))
}
