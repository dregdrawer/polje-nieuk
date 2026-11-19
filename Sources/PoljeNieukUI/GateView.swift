import SwiftUI
import PoljeNieukCore

/// tgate~'s screen: the step pattern (tap a step on / off; drag across empty steps to paint them on; drag
/// right from a lit step to tie the next ones to it, so the gate stays open), the gate's shape drawn over it at
/// the current tempo, the step playing now, and ready-made patterns.
struct TranceGateView: View {
    let node: TranceGateNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State private var drag: (start: Int, mode: Int, moved: Bool)?     // mode 1 paint on, 2 tie, 0 paint off

    private var len: Int { min(max(Int((patchNode.params["len"] ?? 16).rounded()), 1), TranceGateNode.steps) }
    private var cols: Int { len <= 16 ? 16 : TranceGateNode.steps }
    private let presetsH: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                LiveCanvas(signature: {
                    var h = model.isRunning ? Int(node.readouts[0]) : -1
                    LiveSig.mix(&h, LiveSig.floats(node.pattern, TranceGateNode.steps))
                    LiveSig.mix(&h, LiveSig.patch(patchNode))
                    LiveSig.mix(&h, LiveSig.q(node.readouts[1], 30))
                    return h
                }) { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in edit(v, geo.size) }
                        .onEnded { v in finish(v, geo.size) }
                )
            }
            HStack(spacing: 3) {
                ForEach(TranceGateNode.presets, id: \.self) { name in
                    Button { apply(name) } label: {
                        Text(name).font(Theme.monoSmall).foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.row).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: presetsH)
        }
    }

    // MARK: editing

    private func col(_ x: CGFloat, _ w: CGFloat) -> Int { min(max(Int(x / max(w, 1) * CGFloat(cols)), 0), cols - 1) }

    private func edit(_ v: DragGesture.Value, _ size: CGSize) {
        let k = col(v.location.x, size.width)
        if drag == nil {
            let s = col(v.startLocation.x, size.width)
            let cur = node.pattern[s]
            // from an empty step: paint steps on. From a lit one: drag right to tie the next ones to it
            drag = (s, cur > 0.5 ? 2 : 1, false)
            if cur < 0.5 { node.pattern[s] = 1 }
        }
        guard var d = drag else { return }
        if abs(v.translation.width) > 4 || abs(v.translation.height) > 4 { d.moved = true }
        drag = d
        guard d.moved else { return }
        switch d.mode {
        case 1: node.pattern[k] = node.pattern[k] > 0.5 ? node.pattern[k] : 1
        case 2: if k > d.start { for j in (d.start + 1)...k { node.pattern[j] = 2 } }
        default: break
        }
    }

    private func finish(_ v: DragGesture.Value, _ size: CGSize) {
        if let d = drag, !d.moved, d.mode == 2 {
            node.pattern[d.start] = 0                // a tap on a lit step switches it off
            // the steps tied to it now start a gate of their own
            var j = d.start + 1
            while j < TranceGateNode.steps && node.pattern[j] > 1.5 { node.pattern[j] = 1; break }
            _ = j
        }
        drag = nil
        commit()
    }

    private func commit() {
        model.setData(patchNode.id, "steps", (0..<TranceGateNode.steps).map { node.pattern[$0] })
        model.scheduleAutosave()
    }

    private func apply(_ name: String) {
        let cur = (0..<TranceGateNode.steps).map { node.pattern[$0] }
        let p = TranceGateNode.preset(name, current: cur)
        for k in 0..<TranceGateNode.steps { node.pattern[k] = p[k] }
        commit()
    }

    // MARK: drawing

    private func draw(_ ctx: LiveGC, _ size: CGSize) {
        let n = cols, w = size.width / CGFloat(n), h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        let cur = model.isRunning ? Int(node.readouts[0]) : -1
        for k in 0..<n {
            let x = CGFloat(k) * w
            if k == cur { ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: h)), with: .color(Theme.text.opacity(0.12))) }
            let v = node.pattern[k]
            guard v > 0.5 else { continue }
            // tied steps join the one before (no gap); a step that opens the gate has a gap on its left
            let gap: CGFloat = v > 1.5 ? 0 : 1.5
            ctx.fill(Path(CGRect(x: x + gap, y: h * 0.12, width: w - gap, height: h * 0.76)),
                     with: .color(Theme.fill))
        }
        // beat lines every 4 steps
        for k in stride(from: 4, to: n, by: 4) {
            ctx.fill(Path(CGRect(x: CGFloat(k) * w, y: 0, width: 0.5, height: h)), with: .color(Theme.faint))
        }
        // the gate's shape over the pattern, at the current tempo
        ctx.stroke(envelopePath(size, n, w), with: .color(Theme.text), lineWidth: 1.4)
        // steps past the length don't play
        if len < n {
            let x0 = CGFloat(len) * w
            ctx.fill(Path(CGRect(x: x0, y: 0, width: size.width - x0, height: h)), with: .color(Theme.box.opacity(0.7)))
            ctx.fill(Path(CGRect(x: x0 - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.text.opacity(0.6)))
        }
    }

    /// The envelope the gate makes (same rules as the engine), sampled across the shown steps.
    private func envelopePath(_ size: CGSize, _ n: Int, _ w: CGFloat) -> Path {
        let p = patchNode.params
        let spec = ModuleRegistry.spec("tgate")!
        func val(_ key: String) -> Float { p[key] ?? spec.params[spec.paramIndex(key)!].def }
        let bpm = max(Float(model.bpm), 20)
        let stepSec = Float(Divisions.beats(val("div"))) * 60 / bpm
        let per = 24
        let dt = stepSec / Float(per)
        let aInc: Float = val("att") > 0.05 ? dt / (val("att") * 0.001) : 1
        let dMul = expf(-5 * dt / max(val("dec") * 0.001, dt))
        let sus = val("sus"), rMul = expf(-5 * dt / max(val("rel") * 0.001, dt)), gl = val("glen")
        var env: Float = 0, stage = 0, open = false          // stage: 0 idle 1 attack 2 decay 3 sustain 4 release
        var path = Path()
        let top = size.height * 0.08, span = size.height * 0.84
        for k in 0..<min(n, len) {
            let v = node.pattern[k]
            if v > 1.5 && open {} else if v > 0.5 { open = true; stage = 1 } else { if open { stage = 4 }; open = false }
            for s in 0..<per {
                if open && Float(s) / Float(per) >= gl && gl < 0.999 && node.pattern[(k + 1) % len] < 1.5 { open = false; stage = 4 }
                switch stage {
                case 1: env += aInc; if env >= 1 { env = 1; stage = 2 }
                case 2: env = sus + (env - sus) * dMul
                case 4: env *= rMul
                default: break
                }
                let pt = CGPoint(x: (CGFloat(k) + CGFloat(s) / CGFloat(per)) * w, y: top + CGFloat(1 - env) * span)
                if k == 0 && s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }
}
