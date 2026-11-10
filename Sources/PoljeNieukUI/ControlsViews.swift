import SwiftUI
import PoljeNieukCore

// Big touch controls for slider~ and knob~. Every control is its own view with its own gesture,
// so several fingers can move several controls at once. Drag is relative (no jumps when you grab one);
// double-tap returns a control to the middle.

struct ControlsView: View {
    enum Style { case slider, knob }
    let style: Style
    let node: DSPNode
    @ObservedObject var model: AppModel
    let patchNode: PatchNode

    private var count: Int { ControlsLayout.count(patchNode.params["count"] ?? 2) }
    private var range: Int { clampRange(patchNode.params["range"] ?? 0) }

    private func clampRange(_ v: Float) -> Int { v.isFinite ? min(max(Int(v.rounded()), 0), ControlsLayout.ranges.count - 1) : 0 }

    var body: some View {
        GeometryReader { geo in
            let n = count
            if style == .slider {
                HStack(spacing: 6) {
                    ForEach(0..<n, id: \.self) { k in control(k, CGSize(width: (geo.size.width - CGFloat(n - 1) * 6) / CGFloat(n), height: geo.size.height)) }
                }
            } else {
                let cols = min(n, 4), rows = (n + cols - 1) / cols
                let cw = geo.size.width / CGFloat(cols), rh = geo.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<cols, id: \.self) { c in
                                let k = r * cols + c
                                if k < n { control(k, CGSize(width: cw, height: rh)) } else { Color.clear.frame(width: cw, height: rh) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func control(_ k: Int, _ size: CGSize) -> some View {
        let t = target(k)
        // every control in the box reserves the same label space, so they all line up
        let anyTarget = (0..<count).contains { target($0) != nil }
        return ControlCell(style: style, index: k, node: node, model: model, nodeID: patchNode.id,
                           range: range, value: patchNode.params["v\(k + 1)"] ?? 0.5,
                           targetModule: t?.module, targetParam: t?.param, targetValue: t?.value,
                           reserveLabel: anyTarget)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .clipped()
            .help(t.map { "\($0.module) → \($0.param)" } ?? "Patch this outlet into a parameter")
    }

    /// What control k is patched into: the box's name and the parameter / inlet ("+n" when it drives several).
    private func target(_ k: Int) -> (module: String, param: String, value: (() -> String)?)? {
        let cs = model.patch.cables.filter { $0.fromNode == patchNode.id && $0.fromPort == k }
        guard let c = cs.first, let n = model.patch.nodes.first(where: { $0.id == c.toNode }),
              let spec = ModuleRegistry.spec(n.kind) else { return nil }
        let more = cs.count > 1 ? " +\(cs.count - 1)" : ""
        // a parameter target: show its live value in its own units instead of volts
        var value: (() -> String)? = nil
        let pi = c.toPort - kParamPortBase
        if pi >= 0 && pi < spec.params.count, let dsp = model.node(n.id) {
            let ps = spec.params[pi]
            let model = model
            let pos = patchNode.params["v\(k + 1)"] ?? 0.5
            // running: the parameter's live value; audio off: what this control will set it to
            value = { model.isRunning ? ps.display(dsp.params[pi]) : ps.display(ps.value(fromNormalized: pos)) }
        }
        return (model.label(for: n), BoxLayout.inletName(spec, c.toPort) + more, value)
    }
}

private struct ControlCell: View {
    let style: ControlsView.Style
    let index: Int
    let node: DSPNode
    @ObservedObject var model: AppModel
    let nodeID: UUID
    let range: Int
    let value: Float
    let targetModule: String?
    let targetParam: String?
    let targetValue: (() -> String)?
    let reserveLabel: Bool
    @State private var start: Float?

    /// Cut a label to the width available (monospaced small type ≈ 5.6 pt per character).
    private func fit(_ s: String, _ width: CGFloat) -> String {
        let n = max(Int(width / 5.6), 1)
        return s.count <= n ? s : String(s.prefix(max(n - 1, 1))) + "…"
    }

    /// Target names at the top of the cell; returns the height they take.
    /// Target names at the top of the cell. Returns the label band's height — the same for every
    /// control in the box (whether or not this one is patched), so knobs and faders stay level.
    private func drawTarget(_ ctx: GraphicsContext, _ size: CGSize, twoLines: Bool) -> CGFloat {
        guard reserveLabel else { return 0 }
        if let p = targetParam {
            ctx.draw(Text(fit(p, size.width)).font(Theme.monoSmall).foregroundColor(Theme.text),
                     at: CGPoint(x: size.width / 2, y: 6), anchor: .center)
            if twoLines, let m = targetModule {
                ctx.draw(Text(fit(m, size.width)).font(Theme.monoSmall).foregroundColor(Theme.dim),
                         at: CGPoint(x: size.width / 2, y: 17), anchor: .center)
            }
        }
        return twoLines ? 23 : 12
    }

    private var param: Int { ControlsLayout.valueIndex(index) }

    var body: some View {
        GeometryReader { geo in
            LiveCanvas(signature: {
                // redraw only when the position or the shown value changes
                var h = LiveSig.q(Float(live), 512)
                LiveSig.mix(&h, label.hashValue)
                return h
            }, every: 2) { ctx, size in style == .slider ? drawSlider(ctx, size) : drawKnob(ctx, size) }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.setParam(nodeID, param, 0.5); model.scheduleAutosave() }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { v in
                            if start == nil { start = value }
                            // sliders: the travel of the fader; knobs: ~200 pt for the whole turn (up/right = more)
                            let span: CGFloat = style == .slider ? max(geo.size.height - 24, 40) : 200
                            let d = style == .slider ? -v.translation.height : (v.translation.width - v.translation.height)
                            let nv = min(max((start ?? 0.5) + Float(d / span), 0), 1)
                            model.setParam(nodeID, param, nv)
                        }
                        .onEnded { _ in start = nil; model.scheduleAutosave() }
                )
        }
    }

    /// Position actually in effect (includes modulation patched into the control).
    private var live: CGFloat {
        // audio off: the engine isn't running, so show the saved position
        let r = model.isRunning ? node.readouts[index] : value
        return CGFloat(r.isFinite ? min(max(r, 0), 1) : 0)
    }

    private var label: String {
        if let tv = targetValue { return tv() }
        let v = ControlsLayout.map(Float(live), range: range) * 10      // volts
        return String(format: abs(v) < 9.95 ? "%.2f" : "%.1f", v)
    }

    private func drawSlider(_ ctx: GraphicsContext, _ size: CGSize) {
        let labelH: CGFloat = 14
        let top = max(drawTarget(ctx, size, twoLines: size.height > 110), 0) + 6
        let track = CGRect(x: size.width / 2 - 2, y: top, width: 4, height: max(size.height - labelH - 6 - top, 10))
        ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Theme.row))
        let y = track.maxY - live * track.height
        ctx.fill(Path(roundedRect: CGRect(x: track.minX, y: y, width: 4, height: track.maxY - y), cornerRadius: 2),
                 with: .color(Theme.text.opacity(0.55)))
        let capW = min(size.width - 4, 44)
        let cap = CGRect(x: size.width / 2 - capW / 2, y: y - 6, width: capW, height: 12)
        ctx.fill(Path(roundedRect: cap, cornerRadius: 2), with: .color(Theme.text))
        ctx.fill(Path(CGRect(x: cap.minX + 3, y: y - 0.5, width: cap.width - 6, height: 1)), with: .color(Theme.box))
        ctx.draw(Text(fit(size.width < 44 ? label : "\(index + 1)  \(label)", size.width)).font(Theme.monoSmall).foregroundColor(Theme.dim),
                 at: CGPoint(x: size.width / 2, y: size.height - labelH / 2), anchor: .center)
    }

    /// Max-style dial: a 270° track with the gap centred at the bottom (both ends level), and the value
    /// as a white arc from the left end. Angles are measured from 12 o'clock, clockwise,
    /// and every point is computed directly, so the drawing is exactly symmetric.
    private func drawKnob(_ ctx: GraphicsContext, _ size: CGSize) {
        let labelH: CGFloat = 14
        let top = drawTarget(ctx, size, twoLines: size.height > 120)
        let avail = size.height - labelH - top
        // the dial's height is r (above centre) + r·cos45° (below): centre it on that, not on the full circle
        // a little smaller than the cell, for breathing space between knobs
        let r = max(min(size.width / 2 - 6, (avail - 6) / (1 + 0.7071)) * 0.82, 6)
        let c = CGPoint(x: size.width / 2, y: top + 3 + r)
        let start = -135.0, sweep = 270.0
        func point(_ deg: Double, _ radius: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + CGFloat(sin(a)) * radius, y: c.y - CGFloat(cos(a)) * radius)
        }
        func arc(from a: Double, to b: Double) -> Path {
            var p = Path()
            let steps = max(Int(abs(b - a) / 4), 1)
            for i in 0...steps {
                let pt = point(a + (b - a) * Double(i) / Double(steps), r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        let v = Double(live)
        let lw = max(min(r * 0.18, 4), 2)
        ctx.stroke(arc(from: start, to: start + sweep), with: .color(Theme.dim.opacity(Theme.boxIsLight ? 0.55 : 0.75)), style: StrokeStyle(lineWidth: lw, lineCap: .butt))
        if v > 0.001 {
            ctx.stroke(arc(from: start, to: start + sweep * v), with: .color(Theme.text), style: StrokeStyle(lineWidth: lw, lineCap: .butt))
        }
        ctx.draw(Text(fit(size.width < 44 ? label : "\(index + 1)  \(label)", size.width)).font(Theme.monoSmall).foregroundColor(Theme.dim),
                 at: CGPoint(x: size.width / 2, y: size.height - labelH / 2), anchor: .center)
    }

}
