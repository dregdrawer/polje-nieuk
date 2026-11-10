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
    @ObservedObject var model: AppModel
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
            if let node { TuringView(node: node, model: model).padding(.vertical, 4) }
        case "roll":
            if let n = node as? RollNode { GridEditor(kind: .roll(n), model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "drums":
            // 3 pt top/bottom = the port rows' padding, so lane k sits exactly beside outlet k
            if let n = node as? DrumsNode { GridEditor(kind: .drums(n), model: model, patchNode: patchNode).padding(.vertical, 3) }
        case "comp":
            if let node { CompView(node: node) }
        case "lfo":
            if let node { LFOView(node: node, patchNode: patchNode) }
        case "drumsynth":
            if let n = node as? DrumSynthNode { DrumSynthView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "rack":
            if let n = node as? RackNode { RackView(node: n, model: model, patchNode: patchNode).padding(.vertical, 4) }
        case "segments":
            if let node {
                LiveCanvas(signature: { LiveSig.readouts(node, 4, steps: 64) &+ LiveSig.patch(patchNode) }) { ctx, size in
                    let n = SegmentsLayout.count(patchNode.params["count"] ?? 1)
                    let active = ri(node.readouts[1]), v = CGFloat(min(max(fin(node.readouts[0]) / 0.8, 0), 1))
                    let w = size.width / CGFloat(n)
                    for k in 0..<n {
                        let r = CGRect(x: CGFloat(k) * w + 1, y: 0, width: w - 2, height: size.height)
                        ctx.fill(Path(r), with: .color(k == active ? Theme.text.opacity(0.18) : Theme.row))
                        let t = SegmentsLayout.types[clampTypeIndex(patchNode.params["t\(k + 1)"] ?? 0)]
                        ctx.draw(Text(t).font(Theme.monoSmall).foregroundColor(Theme.dim), at: CGPoint(x: r.midX, y: 8))
                        if k == active {
                            ctx.fill(Path(CGRect(x: r.minX, y: size.height - v * (size.height - 16), width: r.width, height: v * (size.height - 16))),
                                     with: .color(Theme.text.opacity(0.7)))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
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
    private func idleStatus(_ b: SampleBufferNode) -> some View {
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

    private var liveBody: some View {
        // the readout text and small displays: only when their numbers change
        LiveView(signature: { LiveSig.readouts(node, 24, steps: 200) &+ LiveSig.patch(patchNode) &* 3 &+ (model.isRunning ? 1 : 0) }) {
            content
        }
        .font(Theme.mono)
    }

    @ViewBuilder private var content: some View {
        if let node {
            let r = node.readouts
            switch kind {
            case "clock":
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r[3] > 0.5 ? (r[2] > 0.5 ? "EXT" : "EXT --") : "INT").foregroundStyle(Theme.dim)
                        Text(String(format: "%.1f bpm", r[0])).foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            ForEach(0..<4, id: \.self) { b in
                                Circle()
                                    .fill(ri(r[1]) == b && r[2] > 0.5 ? Theme.text : Theme.faint)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                    TransportButtons(model: model)
                }
            case "grain":
                HStack {
                    Text("grains \(ri(r[0]))").foregroundStyle(Theme.text)
                    Spacer()
                    if r[1] > 0.5 { Text("frozen").foregroundStyle(Theme.text) }
                }
            case "rec":
                HStack {
                    Circle().fill(r[1] > 0.5 ? Theme.rec : Theme.faint).frame(width: 8, height: 8)
                    Text(r[1] > 0.5 ? "REC" : "idle").foregroundStyle(r[1] > 0.5 ? Theme.rec : Theme.dim)
                    Spacer()
                    Text(timeString(r[0])).foregroundStyle(Theme.text)
                }
            case "comp", "limit":
                HStack(spacing: 6) {
                    Text("GR").foregroundStyle(Theme.dim)
                    GainReduction(db: fin(r[0]))
                    Text(String(format: "%4.1f", r[0])).foregroundStyle(Theme.text).font(Theme.monoSmall)
                }
            case "repeat":
                HStack {
                    Circle().fill(r[0] > 0.5 ? Theme.text : Theme.faint).frame(width: 7, height: 7)
                    Text(r[0] > 0.5 ? "repeating" : "waiting").foregroundStyle(r[0] > 0.5 ? Theme.text : Theme.dim)
                    Spacer()
                }
            case "gain", "mix":
                VStack(spacing: 2) { Meter(level: r[0]); Meter(level: r[1]) }
            default:
                EmptyView()
            }
        } else {
            Text("—").foregroundStyle(Theme.dim)
        }
    }

    private func timeString(_ s: Float) -> String {
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

/// Meter for one hardware channel of in~/out~.
struct ChannelMeter: View {
    let node: DSPNode?
    let channel: Int
    var body: some View {
        LiveView(signature: { LiveSig.q(node.map { $0.readouts[min(channel, DSPNode.readoutCount - 1)] } ?? 0, 60) }, every: 2) {
            Meter(level: node.map { $0.readouts[min(channel, DSPNode.readoutCount - 1)] } ?? 0)
        }
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

@inline(__always) func clampTypeIndex(_ v: Float) -> Int { v.isFinite ? min(max(Int(v.rounded()), 0), SegmentsLayout.types.count - 1) : 0 }


/// ▶ ❚❚ ■ on the clock box. Pause holds the beat where it is; stop also rewinds, so ▶ starts everything
/// from its first step.
struct TransportButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 1) {
            button("play.fill", .play, "Play")
            button("pause.fill", .pause, "Pause: the beat holds where it is")
            button("stop.fill", .stop, "Stop: hold and go back to the start")
        }
    }
    private func button(_ icon: String, _ t: GraphHost.Transport, _ help: String) -> some View {
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
