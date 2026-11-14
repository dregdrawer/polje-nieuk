import SwiftUI
import PoljeNieukCore

/// wave~'s screen: the four waves as tabs (tap one to draw on it; the marker shows where "position" is),
/// a big drawing area (Apple Pencil, finger or mouse — strokes are joined up, so quick lines stay solid),
/// and ready-made shapes for the wave being drawn.
struct WaveDrawView: View {
    let node: WavetableNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State private var last: (index: Int, value: Float)?

    private var editing: Int { min(max(Int((patchNode.params["edit"] ?? 0).rounded()), 0), WavetableNode.frames - 1) }
    private let tabsH: CGFloat = 26, presetsH: CGFloat = 18

    var body: some View {
        VStack(spacing: 4) {
            tabs
            GeometryReader { geo in
                LiveCanvas(signature: {
                    var h = node.version
                    LiveSig.mix(&h, editing)
                    LiveSig.mix(&h, LiveSig.q(node.readouts[0], 50))
                    return h
                }, smooth: true) { ctx, size in drawMain(ctx, size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in paint(v.location, geo.size) }
                        .onEnded { _ in last = nil; commit() }
                )
            }
            presets
        }
    }

    // MARK: tabs

    private var tabs: some View {
        ZStack {
            LiveCanvas(signature: {
                var h = node.version
                LiveSig.mix(&h, editing)
                LiveSig.mix(&h, LiveSig.q(node.readouts[0], 50))
                return h
            }) { ctx, size in drawTabs(ctx, size) }
            HStack(spacing: 4) {
                ForEach(0..<WavetableNode.frames, id: \.self) { f in
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { model.setParam(patchNode.id, 0, Float(f)); model.scheduleAutosave() }
                }
            }
        }
        .frame(height: tabsH)
    }

    private func drawTabs(_ ctx: LiveGC, _ size: CGSize) {
        let n = WavetableNode.frames, gap: CGFloat = 4
        let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n), h = size.height - 5
        for f in 0..<n {
            let r = CGRect(x: CGFloat(f) * (w + gap), y: 0, width: w, height: h)
            ctx.fill(Path(r), with: .color(Theme.row))
            ctx.stroke(wavePath(f, in: r.insetBy(dx: 3, dy: 3)), with: .color(f == editing ? Theme.text : Theme.dim), lineWidth: f == editing ? 1.2 : 0.8)
            if f == editing { ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.text), lineWidth: 1) }
        }
        // where "position" is: 0 under wave 1 … 3 under wave 4
        let pos = CGFloat(min(max(node.readouts[0], 0), Float(n - 1)))
        let x = w / 2 + pos * (w + gap)
        ctx.fill(Path(CGRect(x: w / 2, y: size.height - 2, width: x - w / 2, height: 2)), with: .color(Theme.faint))
        ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: size.height - 4, width: 6, height: 5)), with: .color(Theme.text))
    }

    // MARK: drawing area

    private func drawMain(_ ctx: LiveGC, _ size: CGSize) {
        let r = CGRect(origin: .zero, size: size)
        ctx.fill(Path(r), with: .color(Theme.row))
        ctx.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 0.5)), with: .color(Theme.faint))
        for k in 1..<4 {
            ctx.fill(Path(CGRect(x: size.width * CGFloat(k) / 4, y: 0, width: 0.5, height: size.height)), with: .color(Theme.faint.opacity(0.5)))
        }
        // what's playing now (the morph between waves), faint behind the wave being drawn
        let pos = min(max(node.readouts[0], 0), Float(WavetableNode.frames - 1))
        let f0 = min(Int(pos), WavetableNode.frames - 2), t = pos - Float(f0)
        if abs(pos - Float(editing)) > 0.02 {
            ctx.stroke(path(in: r) { i in
                let a = node.drawn[f0 * WavetableNode.points + i], b = node.drawn[(f0 + 1) * WavetableNode.points + i]
                return a + (b - a) * t
            }, with: .color(Theme.dim.opacity(0.6)), lineWidth: 1)
        }
        ctx.stroke(wavePath(editing, in: r.insetBy(dx: 0, dy: 3)), with: .color(Theme.text), lineWidth: 1.6)
        ctx.draw(LiveText("wave \(editing + 1) · draw here", size: 9, color: Theme.dim), at: CGPoint(x: 4, y: 8), anchor: .leading)
    }

    private func wavePath(_ f: Int, in r: CGRect) -> Path {
        path(in: r) { node.drawn[f * WavetableNode.points + $0] }
    }

    private func path(in r: CGRect, _ value: (Int) -> Float) -> Path {
        let n = WavetableNode.points
        var p = Path()
        for i in 0...n {
            let v = CGFloat(min(max(value(i % n), -1), 1))
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(n), y: r.midY - v * r.height / 2)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// Draw at a point: the stroke is joined to the last point, so fast movements leave no gaps.
    private func paint(_ p: CGPoint, _ size: CGSize) {
        let n = WavetableNode.points
        guard size.width > 0, size.height > 6 else { return }
        let i = min(max(Int(p.x / size.width * CGFloat(n)), 0), n - 1)
        let v = Float(min(max(1 - (p.y - 3) / (size.height - 6) * 2, -1), 1))
        let base = node.drawn + editing * n
        if let (li, lv) = last, li != i {
            let step = li < i ? 1 : -1
            var k = li
            while k != i {
                k += step
                base[k] = lv + (v - lv) * Float(k - li) / Float(i - li)
            }
        } else {
            base[i] = v
        }
        last = (i, v)
        node.rebuild(frame: editing)           // heard straight away
    }

    private func commit() {
        model.setData(patchNode.id, "wave", node.waveData)
        model.scheduleAutosave()
    }

    // MARK: ready-made shapes

    private var presets: some View {
        HStack(spacing: 3) {
            ForEach(WavetableNode.presets, id: \.self) { name in button(name) { set(WavetableNode.shape(name)) } }
            button("smooth") { set(smoothed()) }
            button("flip") { set((0..<WavetableNode.points).map { -node.drawn[editing * WavetableNode.points + $0] }) }
        }
        .frame(height: presetsH)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.monoSmall).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func set(_ values: [Float]) {
        let base = node.drawn + editing * WavetableNode.points
        for i in 0..<min(values.count, WavetableNode.points) { base[i] = min(max(values[i], -1), 1) }
        node.rebuild(frame: editing)
        commit()
    }

    /// A gentle smoothing of the wave being drawn (rounds off a scribble).
    private func smoothed() -> [Float] {
        let n = WavetableNode.points, base = node.drawn + editing * n
        return (0..<n).map { i in
            var s: Float = 0
            for d in -3...3 { s += base[(i + d + n) % n] }
            return s / 7
        }
    }
}
