import SwiftUI
import PoljeNieukCore

/// wave's screen: the four waves as tabs (tap one to draw on it; the marker shows where "position" is),
/// a big drawing area (Apple Pencil, finger or mouse — strokes are joined up, so quick lines stay solid),
/// and ready-made shapes for the wave being drawn.
struct WaveDrawView: View {
    let node: WavetableNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State var last: (index: Int, value: Float)?

    var editing: Int { min(max(Int((patchNode.params["edit"] ?? 0).rounded()), 0), WavetableNode.frames - 1) }
    let tabsH: CGFloat = 26, presetsH: CGFloat = 18

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

    var tabs: some View {
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

    func drawTabs(_ ctx: LiveGC, _ size: CGSize) {
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

    func drawMain(_ ctx: LiveGC, _ size: CGSize) {
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

    func wavePath(_ f: Int, in r: CGRect) -> Path {
        path(in: r) { node.drawn[f * WavetableNode.points + $0] }
    }

    func path(in r: CGRect, _ value: (Int) -> Float) -> Path {
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
    func paint(_ p: CGPoint, _ size: CGSize) {
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

    func commit() {
        model.setData(patchNode.id, "wave", node.waveData)
        model.scheduleAutosave()
    }

    // MARK: ready-made shapes

    var presets: some View {
        HStack(spacing: 3) {
            ForEach(WavetableNode.presets, id: \.self) { name in button(name) { set(WavetableNode.shape(name)) } }
            button("smooth") { set(smoothed()) }
            button("flip") { set((0..<WavetableNode.points).map { -node.drawn[editing * WavetableNode.points + $0] }) }
        }
        .frame(height: presetsH)
    }

    func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.monoSmall).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func set(_ values: [Float]) {
        let base = node.drawn + editing * WavetableNode.points
        for i in 0..<min(values.count, WavetableNode.points) { base[i] = min(max(values[i], -1), 1) }
        node.rebuild(frame: editing)
        commit()
    }

    /// A gentle smoothing of the wave being drawn (rounds off a scribble).
    func smoothed() -> [Float] {
        let n = WavetableNode.points, base = node.drawn + editing * n
        return (0..<n).map { i in
            var s: Float = 0
            for d in -3...3 { s += base[(i + d + n) % n] }
            return s / 7
        }
    }
}

/// chord's screen: the chord's name and its notes on a little keyboard, each lit key labelled with its
/// interval (R, ♭3, 3, 5 …) — worked out from the settings, so it changes as soon as you do (audio on or not).
/// Click a key to make it the root.
struct ChordView: View {
    let node: DSPNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    static let suffix = ["", "m", "7", "maj7", "m7", "sus2", "sus4", "dim", "aug", "6", "m6", "add9", "9", "m9", "m7♭5", "dim7"]
    static let intervals = ["R", "♭9", "9", "♭3", "3", "4", "♭5", "5", "♯5", "6", "♭7", "7"]
    let top: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            LiveCanvas(signature: { LiveSig.readouts(node, 7, steps: 100) &+ LiveSig.patch(patchNode) &* 7 &+ (model.isRunning ? 1 : 0) }) { ctx, size in
                draw(ctx, size)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in tap(v.location, geo.size) })
        }
    }

    /// The chord shown: what's sounding while audio runs (voice leading may have picked another inversion),
    /// otherwise the chord the settings make.
    var chord: (notes: [Int], root: Int, quality: Int) {
        let r = node.readouts
        let n = min(max(Int(fin(r[4])), 0), ChordNode.maxVoices)
        if model.isRunning && n > 0 {
            return ((0..<n).map { Int(fin(r[$0]).rounded()) }, min(max(Int(fin(r[5])), 0), 11), Int(fin(r[6])))
        }
        guard let spec = ModuleRegistry.spec("chord") else { return ([], 0, -1) }
        func v(_ key: String) -> Int {
            let i = spec.paramIndex(key)!
            return Int((patchNode.params[key] ?? spec.params[i].def).rounded())
        }
        let c = ChordNode.build(mode: v("mode"), key: v("key"), scale: v("scale"), degree: v("degree"), size: v("size"),
                                type: v("type"), voices: v("voices") + 3, inversion: v("inv"), spread: v("spread"),
                                octave: v("oct"), shift: 0, previous: nil)
        return (c.notes.map { Int($0.rounded()) }, c.root, c.quality)
    }

    /// the keyboard's layout: first note shown, and how many octaves
    func keyboard(_ notes: [Int]) -> (start: Int, span: Int) {
        let lo = notes.min() ?? 0
        let start = Int(floor(Double(lo) / 12)) * 12
        return (start, 2 + ((notes.max() ?? 0) - start >= 24 ? 1 : 0))
    }
    static let whites = [0, 2, 4, 5, 7, 9, 11], blacks = [1, 3, 6, 8, 10]

    func draw(_ ctx: LiveGC, _ size: CGSize) {
        let c = chord
        let notes = c.notes, root = c.root, q = c.quality
        let name = ChordNode.keys[root] + (q >= 0 && q < Self.suffix.count ? Self.suffix[q] : "")
        let names = notes.map { ChordNode.keys[(($0 % 12) + 12) % 12] + String(4 + Int(floor(Double($0) / 12))) }.joined(separator: " ")
        ctx.draw(LiveText(notes.isEmpty ? "—" : name, size: 13, color: Theme.text, bold: true), at: CGPoint(x: 0, y: 8), anchor: .leading)
        ctx.draw(LiveText(names, size: 9, color: Theme.dim), at: CGPoint(x: size.width, y: 8), anchor: .trailing)
        guard !notes.isEmpty else { return }
        let h = size.height - top
        let (start, span) = keyboard(notes)
        let ww = size.width / CGFloat(7 * span)
        func label(_ note: Int) -> String { Self.intervals[(((note - root) % 12) + 12) % 12] }
        for o in 0..<span {
            for (k, w) in Self.whites.enumerated() {
                let x = CGFloat(o * 7 + k) * ww, note = start + o * 12 + w
                let lit = notes.contains(note)
                ctx.fill(Path(CGRect(x: x + 0.5, y: top, width: ww - 1, height: h)), with: .color(lit ? Theme.text : Theme.row))
                if lit { ctx.draw(LiveText(label(note), size: 7, color: Theme.box, bold: true), at: CGPoint(x: x + ww / 2, y: top + h - 6)) }
            }
            for b in Self.blacks {
                let k = Self.whites.firstIndex { $0 > b }! - 1
                let x = CGFloat(o * 7 + k + 1) * ww - ww * 0.3, note = start + o * 12 + b
                let lit = notes.contains(note)
                ctx.fill(Path(CGRect(x: x, y: top, width: ww * 0.6, height: h * 0.6)), with: .color(lit ? Theme.text : Theme.dim))
                if lit { ctx.draw(LiveText(label(note), size: 6, color: Theme.box, bold: true), at: CGPoint(x: x + ww * 0.3, y: top + h * 0.6 - 5)) }
            }
        }
    }

    /// Click a key: it becomes the root (the "key" setting).
    func tap(_ p: CGPoint, _ size: CGSize) {
        guard p.y >= top, let spec = ModuleRegistry.spec("chord"), let ki = spec.paramIndex("key") else { return }
        let (start, span) = keyboard(chord.notes)
        let ww = size.width / CGFloat(7 * span)
        let h = size.height - top
        var note: Int?
        // black keys sit on top: check them first
        if p.y < top + h * 0.6 {
            for o in 0..<span {
                for b in Self.blacks {
                    let k = Self.whites.firstIndex { $0 > b }! - 1
                    let x = CGFloat(o * 7 + k + 1) * ww - ww * 0.3
                    if p.x >= x && p.x <= x + ww * 0.6 { note = start + o * 12 + b }
                }
            }
        }
        if note == nil {
            let w = min(max(Int(p.x / ww), 0), 7 * span - 1)
            note = start + (w / 7) * 12 + Self.whites[w % 7]
        }
        if let n = note {
            model.setParam(patchNode.id, ki, Float(((n % 12) + 12) % 12))
            model.scheduleAutosave()
        }
    }
}
