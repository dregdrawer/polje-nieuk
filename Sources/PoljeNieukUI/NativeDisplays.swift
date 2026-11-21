import SwiftUI
import PoljeNieukCore

// Each module's own display on the native canvas: what it draws (with the same drawing code as before),
// where, and what pointer presses do in it. Positions are box points; `r` is the display's area in the box.

@MainActor class NativeDisplay {
    unowned let model: AppModel
    let id: UUID
    var node: PatchNode
    let spec: ModuleSpec
    var dsp: DSPNode? { model.node(id) }
    /// a file is being dragged over this pad (rack)
    var dropPad: Int?

    init(model: AppModel, node: PatchNode, spec: ModuleSpec) {
        self.model = model; self.id = node.id; self.node = node; self.spec = spec
    }

    /// The parts that move (each its own layer).
    func parts(_ r: CGRect) -> [LivePart] { [] }
    /// What doesn't move (labels, buttons), drawn with the box.
    func paintStatic(_ g: LiveGC, _ r: CGRect) {}
    /// A press in the display: true when the display takes it (and the drag that follows).
    func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool { false }
    func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {}
    func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {}
    /// Right-click / long-press menu.
    func menu(_ p: CGPoint, _ r: CGRect) -> [MenuItem]? { nil }
    /// rack: the pad under a dropped file (nil: the box takes it)
    func pad(at p: CGPoint, _ r: CGRect) -> Int? { nil }

    func param(_ key: String) -> Int? { spec.paramIndex(key) }
    func setParam(_ key: String, _ v: Float) {
        guard let i = param(key) else { return }
        model.setParam(id, i, v)
    }

    static func make(model: AppModel, node: PatchNode, spec: ModuleSpec) -> NativeDisplay? {
        guard BoxLayout.hasReadout(spec.kind) else { return nil }
        switch spec.kind {
        case "looper", "sampler", "stretch": return BufferDisplay(model: model, node: node, spec: spec)
        case "keys": return KeysDisplay(model: model, node: node, spec: spec)
        case "seq": return SeqDisplay(model: model, node: node, spec: spec)
        case "turing": return TuringDisplay(model: model, node: node, spec: spec)
        case "roll", "drums": return GridDisplay(model: model, node: node, spec: spec)
        case "comp": return CompDisplay(model: model, node: node, spec: spec)
        case "lfo": return LFODisplay(model: model, node: node, spec: spec)
        case "chord": return ChordDisplay(model: model, node: node, spec: spec)
        case "wave": return WaveDisplay(model: model, node: node, spec: spec)
        case "scope": return ScopeDisplay(model: model, node: node, spec: spec)
        case "drumsynth": return DrumSynthDisplay(model: model, node: node, spec: spec)
        case "rack": return RackDisplay(model: model, node: node, spec: spec)
        case "slider", "knob": return ControlsDisplay(model: model, node: node, spec: spec)
        case "peq": return EQDisplay(model: model, node: node, spec: spec)
        case "clock": return ClockDisplay(model: model, node: node, spec: spec)
        default: return TextReadout(model: model, node: node, spec: spec)
        }
    }

    /// A part covering `rect`, drawing with `draw` at its own size.
    func part(_ key: String, _ rect: CGRect, every: Int = 1, smooth: Bool = false,
              signature: (() -> Int)?, _ draw: @escaping (LiveGC, CGSize) -> Void) -> LivePart {
        LivePart(key: key, rect: rect, every: every, smooth: smooth, dimmed: node.bypassed, signature: signature, draw: draw)
    }
}

// MARK: - The small text readouts (grain, rec, comp / limit, repeat, gain, mix)

final class TextReadout: NativeDisplay {
    override func parts(_ r: CGRect) -> [LivePart] {
        let m = model, nid = id
        return [part("readout", r, signature: { [weak self] in
            guard let self else { return 0 }
            return LiveSig.readouts(m.node(nid), 24, steps: 200) &+ LiveSig.patch(self.node) &* 3 &+ (m.isRunning ? 1 : 0)
        }) { [weak self] g, size in
            guard let self else { return }
            ReadoutView(kind: self.spec.kind, node: m.node(nid), model: m, patchNode: self.node, spec: self.spec).drawLive(g, size)
        }]
    }
}

// MARK: - clock: the tempo line and ▶ ❚❚ ■

final class ClockDisplay: NativeDisplay {
    private func buttons(_ r: CGRect) -> [(GraphHost.Transport, CGRect)] {
        [GraphHost.Transport.play, .pause, .stop].enumerated().map { k, t in
            (t, CGRect(x: r.minX + CGFloat(k) * 19, y: r.minY + 17, width: 18, height: 16))
        }
    }
    override func parts(_ r: CGRect) -> [LivePart] {
        let m = model, nid = id
        return [part("tempo", CGRect(x: r.minX, y: r.minY, width: r.width, height: 14), signature: { [weak self] in
            guard let self else { return 0 }
            return LiveSig.readouts(m.node(nid), 24, steps: 200) &+ LiveSig.patch(self.node) &* 3 &+ (m.isRunning ? 1 : 0)
        }) { [weak self] g, size in
            guard let self else { return }
            ReadoutView(kind: "clock", node: m.node(nid), model: m, patchNode: self.node, spec: self.spec).drawLive(g, size)
        }]
    }
    override func paintStatic(_ g: LiveGC, _ r: CGRect) {
        for (t, b) in buttons(r) {
            let on = model.transport == t
            if on { g.fill(Path(b), with: .color(Theme.fill)) }
            let c = CGPoint(x: b.midX, y: b.midY), col = on ? Theme.text : Theme.dim.opacity(0.7)
            switch t {
            case .play: Icons.play(g, c, col)
            case .pause: Icons.pause(g, c, col)
            default: Icons.stop(g, c, col)
            }
        }
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        for (t, b) in buttons(r) where b.contains(p) { model.setTransport(t); return true }
        return false
    }
}

// MARK: - looper / sampler / stretch: status line and waveform

final class BufferDisplay: NativeDisplay {
    private var view: WaveformView?
    private var from: CGFloat?
    private func wave(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: r.minY + 3 + 18, width: r.width, height: r.height - 6 - 18) }
    private func waveformView() -> WaveformView? {
        guard let d = dsp, let b = d as? SampleBufferNode else { return nil }
        if view == nil { view = WaveformView(node: d, buffer: b, model: model, patchNode: node, spec: spec) }
        return view
    }

    override func parts(_ r: CGRect) -> [LivePart] {
        guard let d = dsp, let b = d as? SampleBufferNode else { return [] }
        let m = model, kind = spec.kind
        let status = part("status", CGRect(x: r.minX, y: r.minY + 3, width: r.width, height: 14), signature: {
            LiveSig.readouts(d, 12, steps: 100) &* 3 &+ (m.isRunning ? 1 : 2) &+ b.contentVersion &* 7
        }) { g, size in
            let mid = size.height / 2
            func t(_ s: String, _ x: CGFloat, _ c: Color, size sz: CGFloat = 11, right: Bool = false) {
                g.draw(LiveText(s, size: sz, color: c), at: CGPoint(x: x, y: mid), anchor: right ? .trailing : .leading)
            }
            let r = d.readouts
            if !m.isRunning {
                let secs = Double(b.waveLength) / max(m.host.sampleRate, 1)
                t(b.waveLength > 0 ? "loaded — audio off" : "empty — REC or load", 0, Theme.dim)
                t(String(format: "%.2fs", secs), size.width, Theme.dim, size: 9, right: true)
                return
            }
            switch kind {
            case "looper":
                let state = min(max(ri(r[0]), 0), 6)
                let names = ["empty", "armed", "REC", "play", "DUB", "stop", "REC→"]
                t(names[state], 0, state == 2 || state == 4 || state == 6 ? Theme.rec : Theme.text)
                t(String(format: "%.2fs", fin(r[2])), size.width, Theme.dim, size: 9, right: true)
            case "sampler":
                let st = ri(r[0])
                let a = st == 1 ? "REC" : st == 2 ? "\(ri(r[2])) slices" : "empty — REC or load"
                t(a, 0, st == 1 ? Theme.rec : Theme.text)
                var x = textWidth(a, size: 11) + 6
                if st == 2 { let s = "▸ \(ri(r[3]))"; t(s, x, Theme.dim); x += textWidth(s, size: 11) + 6 }
                if st == 2 && ri(r[4]) == 3 { t("stopped", x, Theme.dim) }
                t(String(format: "%.2fs", fin(r[1])), size.width, Theme.dim, size: 9, right: true)
            default:
                let st = ri(r[0])
                t(st == 1 ? "REC" : st == 2 ? "stretching" : "empty — REC or load", 0, st == 1 ? Theme.rec : Theme.text)
                t(String(format: "%.2fs", fin(r[1])), size.width, Theme.dim, size: 9, right: true)
            }
        }
        let waveform = part("wave", wave(r), smooth: true, signature: nil) { [weak self] g, size in
            self?.waveformView()?.draw(g, size)
        }
        return [status, waveform]
    }

    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        let w = wave(r)
        guard w.contains(p), let v = waveformView(), let s = v.startIndex, let e = v.endIndex else { return false }
        if info.clickCount >= 2 {
            model.setParam(id, s, 0); model.setParam(id, e, 1)
        }
        from = nil
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard info.moved, let v = waveformView(), let s = v.startIndex, let e = v.endIndex else { return }
        let w = wave(r), width = max(w.width, 1)
        if from == nil { from = info.start.x - w.minX }
        let x = p.x - w.minX
        var a = Double(min(max(min(from ?? 0, x) / width, 0), 1))
        var b = Double(min(max(max(from ?? 0, x) / width, 0), 1))
        a = v.snap(a); b = v.snap(b)
        if b <= a, let g = v.gridStep() { b = min(a + g, 1) }
        model.setParam(id, s, Float(a)); model.setParam(id, e, Float(b))
    }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        let w = wave(r)
        if !info.moved && info.clickCount == 1 {
            model.audition(id, at: Double((p.x - w.minX) / max(w.width, 1)))
        }
        from = nil
    }
}

// MARK: - keys

final class KeysDisplay: NativeDisplay {
    private var lastKey = -1
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    private var view: KeysView? { (dsp as? KeysNode).map { KeysView(node: $0, model: model, patchNode: node) } }

    override func parts(_ r: CGRect) -> [LivePart] {
        guard let k = dsp as? KeysNode else { return [] }
        let m = model
        return [part("keys", inner(r), signature: { [weak self] in
            var h = m.isRunning ? Int(k.readouts[0]) : -1
            LiveSig.mix(&h, k.touchNote)
            LiveSig.mix(&h, LiveSig.floats(k.latched, KeysNode.keyCount))
            if let self { LiveSig.mix(&h, LiveSig.patch(self.node)) }
            return h
        }) { [weak self] g, size in self?.view?.draw(g, size) }]
    }
    private func hit(_ p: CGPoint, _ r: CGRect) {
        let i = inner(r)
        guard let v = view, let k = dsp as? KeysNode, let key = v.key(at: CGPoint(x: p.x - i.minX, y: p.y - i.minY), i.size) else { return }
        if v.latch {
            if key != lastKey { k.toggleLatched(key); lastKey = key }
        } else {
            if key != lastKey { k.pressNote = key; k.pressCount &+= 1; lastKey = key }
            k.touchNote = key
        }
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        guard inner(r).contains(p) else { return false }
        lastKey = -1
        hit(p, r)
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { hit(p, r) }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        (dsp as? KeysNode)?.touchNote = -1
        lastKey = -1
    }
}

// MARK: - seq

final class SeqDisplay: NativeDisplay {
    private var paintGate: Float?
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    private var view: SeqView? { (dsp as? SeqNode).map { SeqView(node: $0, model: model, patchNode: node) } }

    override func parts(_ r: CGRect) -> [LivePart] {
        guard let s = dsp as? SeqNode else { return [] }
        let m = model
        return [part("seq", inner(r), signature: { [weak self] in
            var h = m.isRunning ? Int(s.readouts[0]) : -1
            LiveSig.mix(&h, LiveSig.floats(s.pitches, SeqNode.steps))
            LiveSig.mix(&h, LiveSig.floats(s.gates, SeqNode.steps))
            if let self { LiveSig.mix(&h, LiveSig.patch(self.node)); LiveSig.mix(&h, LiveSig.q(self.paintGate ?? -1, 4)) }
            return h
        }) { [weak self] g, size in self?.view?.draw(g, size) }]
    }
    private func edit(_ p: CGPoint, _ r: CGRect, start: CGPoint) {
        guard let v = view, let s = dsp as? SeqNode else { return }
        let i = inner(r), size = i.size
        let lp = CGPoint(x: p.x - i.minX, y: p.y - i.minY), ls = CGPoint(x: start.x - i.minX, y: start.y - i.minY)
        let colW = size.width / CGFloat(v.cols)
        let col = min(max(Int(lp.x / colW), 0), v.cols - 1)
        let barH = size.height - v.gateRow - 2
        if ls.y > barH {
            if paintGate == nil { paintGate = s.gates[col] > 0.5 ? 0 : 1 }
            s.gates[col] = paintGate!
        } else {
            let val = Float(1 - min(max(lp.y / barH, 0), 1)) * 2 - 1
            s.pitches[col] = (val * v.range).rounded()
        }
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        guard inner(r).contains(p) else { return false }
        paintGate = nil
        edit(p, r, start: info.start)
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { edit(p, r, start: info.start) }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        paintGate = nil
        guard let s = dsp as? SeqNode else { return }
        model.setData(id, ["pitch": (0..<SeqNode.steps).map { s.pitches[$0] }, "gate": (0..<SeqNode.steps).map { s.gates[$0] }])
    }
}

// MARK: - turing

final class TuringDisplay: NativeDisplay {
    override func parts(_ r: CGRect) -> [LivePart] {
        guard let t = dsp as? TuringNode else { return [] }
        let m = model
        return [part("turing", r.insetBy(dx: 0, dy: 4), signature: { LiveSig.readouts(t, 24) &+ (m.isRunning ? 1 : 0) }) { g, size in
            TuringView(node: t, model: m).draw(g, size)
        }]
    }
}

// MARK: - roll / drums

final class GridDisplay: NativeDisplay {
    private var paint: Float?
    private var scrolling = false
    private var isRoll: Bool { spec.kind == "roll" }
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: spec.kind == "drums" ? 3 : 4) }
    /// roll: the grid, with a scrollbar beside it (all 7 octaves, 2 on screen)
    private static let bar: CGFloat = 7
    private func gridRect(_ r: CGRect) -> CGRect {
        let i = inner(r)
        return isRoll ? CGRect(x: i.minX, y: i.minY, width: i.width - Self.bar - 3, height: i.height) : i
    }
    private func barRect(_ r: CGRect) -> CGRect { let i = inner(r); return CGRect(x: i.maxX - Self.bar, y: i.minY, width: Self.bar, height: i.height) }
    private var view: GridEditor? {
        if let n = dsp as? RollNode { return GridEditor(kind: .roll(n), model: model, patchNode: node) }
        if let n = dsp as? DrumsNode { return GridEditor(kind: .drums(n), model: model, patchNode: node) }
        return nil
    }
    private var maxBase: Int { RollNode.rows - RollNode.shown }
    /// the scrollbar's thumb (bar-local): its size is the share of the range on screen
    private func thumb(_ size: CGSize, base: Int) -> CGRect {
        let h = max(size.height * CGFloat(RollNode.shown) / CGFloat(RollNode.rows), 14)
        let t = maxBase > 0 ? CGFloat(base) / CGFloat(maxBase) : 0
        return CGRect(x: 0, y: (1 - t) * (size.height - h), width: size.width, height: h)      // high notes at the top
    }
    override func parts(_ r: CGRect) -> [LivePart] {
        let m = model, d = dsp
        var list = [part("grid", gridRect(r), signature: { [weak self] in
            var h = 0
            if let n = d as? RollNode {
                h = m.isRunning ? Int(n.readouts[0]) : -1
                LiveSig.mix(&h, LiveSig.floats(n.grid, RollNode.steps * RollNode.rows))
            } else if let n = d as? DrumsNode {
                h = m.isRunning ? Int(n.readouts[0]) : -1
                LiveSig.mix(&h, LiveSig.floats(n.hits, DrumsNode.steps * DrumsNode.lanes))
            }
            if let self { LiveSig.mix(&h, LiveSig.patch(self.node)) }
            return h
        }) { [weak self] g, size in self?.view?.draw(g, size) }]
        if isRoll {
            list.append(part("scroll", barRect(r), signature: { [weak self] in self?.view?.base ?? 0 }) { [weak self] g, size in
                guard let self, let v = self.view else { return }
                g.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(Theme.row))
                g.fill(Path(roundedRect: self.thumb(size, base: v.base), cornerRadius: 2), with: .color(Theme.dim))
            })
        }
        return list
    }
    private func scroll(to p: CGPoint, _ r: CGRect) {
        let b = barRect(r)
        let th = thumb(b.size, base: 0).height
        let t = 1 - min(max((p.y - b.minY - th / 2) / max(b.height - th, 1), 0), 1)
        let base = Int((t * CGFloat(maxBase)).rounded())
        guard let li = spec.paramIndex("low"), base != view?.base else { return }
        model.setParam(id, li, Float(RollNode.lowest + base))
    }
    private func edit(_ p: CGPoint, _ r: CGRect) {
        guard let v = view else { return }
        let i = gridRect(r)
        let cw = i.width / CGFloat(max(v.len, 1)), rh = i.height / CGFloat(v.rows)
        let step = Int((p.x - i.minX) / cw), row = v.rowAt(p.y - i.minY, rh)
        guard step >= 0 && step < v.len && row >= 0 && row < v.rows else { return }
        if paint == nil { paint = v.isOn(step, row) ? 0 : 1 }
        v.set(step, row, paint == 1)
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        if isRoll && barRect(r).insetBy(dx: -3, dy: 0).contains(p) { scrolling = true; scroll(to: p, r); return true }
        guard gridRect(r).contains(p) else { return false }
        paint = nil
        edit(p, r)
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { if scrolling { scroll(to: p, r) } else { edit(p, r) } }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        if scrolling { scrolling = false; return }
        paint = nil
        view?.commit()
    }
}

// MARK: - comp

final class CompDisplay: NativeDisplay {
    private var view: CompView?
    override func parts(_ r: CGRect) -> [LivePart] {
        guard let d = dsp else { return [] }
        if view == nil { view = CompView(node: d) }
        let i = r.insetBy(dx: 0, dy: 4)
        let curve = min(i.height, i.width / 2)
        let hist = CGRect(x: i.minX, y: i.minY, width: i.width - 6 - curve, height: i.height)
        let cur = CGRect(x: hist.maxX + 6, y: i.minY + (i.height - curve) / 2, width: curve, height: curve)
        return [part("history", hist, every: 2, signature: nil) { [weak self] g, size in self?.view?.drawHistory(g, size) },
                part("curve", cur, every: 2, signature: nil) { [weak self] g, size in self?.view?.drawCurve(g, size) }]
    }
}

// MARK: - lfo

final class LFODisplay: NativeDisplay {
    override func parts(_ r: CGRect) -> [LivePart] {
        guard let d = dsp else { return [] }
        return [part("lfo", r.insetBy(dx: 0, dy: 4), smooth: true, signature: nil) { [weak self] g, size in
            guard let self else { return }
            LFOView(node: d, patchNode: self.node).draw(g, size)
        }]
    }
}

// MARK: - chord

final class ChordDisplay: NativeDisplay {
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    private var view: ChordView? { dsp.map { ChordView(node: $0, model: model, patchNode: node) } }
    override func parts(_ r: CGRect) -> [LivePart] {
        guard let d = dsp else { return [] }
        let m = model
        return [part("chord", inner(r), signature: { [weak self] in
            LiveSig.readouts(d, 7, steps: 100) &+ (self.map { LiveSig.patch($0.node) } ?? 0) &* 7 &+ (m.isRunning ? 1 : 0)
        }) { [weak self] g, size in self?.view?.draw(g, size) }]
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool { inner(r).contains(p) }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard !info.moved else { return }
        let i = inner(r)
        view?.tap(CGPoint(x: p.x - i.minX, y: p.y - i.minY), i.size)
    }
}

// MARK: - wave: tabs, drawing area, ready-made shapes

final class WaveDisplay: NativeDisplay {
    private var last: (index: Int, value: Float)?
    private var view: WaveDrawView? { (dsp as? WavetableNode).map { WaveDrawView(node: $0, model: model, patchNode: node) } }
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    private func tabs(_ r: CGRect) -> CGRect { let i = inner(r); return CGRect(x: i.minX, y: i.minY, width: i.width, height: 26) }
    private func presetsRow(_ r: CGRect) -> CGRect { let i = inner(r); return CGRect(x: i.minX, y: i.maxY - 18, width: i.width, height: 18) }
    private func main(_ r: CGRect) -> CGRect {
        let i = inner(r)
        return CGRect(x: i.minX, y: i.minY + 26 + 4, width: i.width, height: max(i.height - 26 - 18 - 8, 10))
    }
    private var buttonNames: [String] { WavetableNode.presets + ["smooth", "flip"] }
    private func buttons(_ r: CGRect) -> [(String, CGRect)] {
        let row = presetsRow(r), n = buttonNames.count, gap: CGFloat = 3
        let bw = (row.width - gap * CGFloat(n - 1)) / CGFloat(n)
        return buttonNames.enumerated().map { k, s in (s, CGRect(x: row.minX + CGFloat(k) * (bw + gap), y: row.minY, width: bw, height: row.height)) }
    }

    override func parts(_ r: CGRect) -> [LivePart] {
        guard let w = dsp as? WavetableNode else { return [] }
        let sig: () -> Int = { [weak self] in
            var h = w.version
            LiveSig.mix(&h, self?.view?.editing ?? 0)
            LiveSig.mix(&h, LiveSig.q(w.readouts[0], 50))
            return h
        }
        return [part("tabs", tabs(r), signature: sig) { [weak self] g, size in self?.view?.drawTabs(g, size) },
                part("main", main(r), smooth: true, signature: sig) { [weak self] g, size in self?.view?.drawMain(g, size) }]
    }
    override func paintStatic(_ g: LiveGC, _ r: CGRect) {
        for (s, b) in buttons(r) {
            g.fill(Path(b), with: .color(Theme.row))
            g.draw(LiveText(fitText(s, size: 9, width: b.width - 2), size: 9, color: Theme.text), at: CGPoint(x: b.midX, y: b.midY))
        }
    }
    private func paint(_ p: CGPoint, _ r: CGRect) {
        guard let w = dsp as? WavetableNode, let v = view else { return }
        let m = main(r), n = WavetableNode.points
        guard m.width > 0, m.height > 6 else { return }
        let i = min(max(Int((p.x - m.minX) / m.width * CGFloat(n)), 0), n - 1)
        let val = Float(min(max(1 - (p.y - m.minY - 3) / (m.height - 6) * 2, -1), 1))
        let base = w.drawn + v.editing * n
        if let (li, lv) = last, li != i {
            let step = li < i ? 1 : -1
            var k = li
            while k != i { k += step; base[k] = lv + (val - lv) * Float(k - li) / Float(i - li) }
        } else {
            base[i] = val
        }
        last = (i, val)
        w.rebuild(frame: v.editing)
    }
    private var drawing = false
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        if tabs(r).contains(p) {
            let t = tabs(r), gap: CGFloat = 4, n = WavetableNode.frames
            let tw = (t.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let f = min(max(Int((p.x - t.minX) / (tw + gap)), 0), n - 1)
            model.setParam(id, 0, Float(f)); model.scheduleAutosave()
            drawing = false
            return true
        }
        if main(r).contains(p) { last = nil; drawing = true; paint(p, r); return true }
        if presetsRow(r).contains(p) { drawing = false; return true }
        return false
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { if drawing { paint(p, r) } }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        if drawing { last = nil; drawing = false; view?.commit(); return }
        guard !info.moved, let v = view, let w = dsp as? WavetableNode else { return }
        for (s, b) in buttons(r) where b.contains(p) && b.contains(info.start) {
            switch s {
            case "smooth": v.set(v.smoothed())
            case "flip": v.set((0..<WavetableNode.points).map { -w.drawn[v.editing * WavetableNode.points + $0] })
            default: v.set(WavetableNode.shape(s))
            }
        }
    }
}

// MARK: - scope

final class ScopeDisplay: NativeDisplay {
    override func parts(_ r: CGRect) -> [LivePart] {
        guard let s = dsp as? ScopeNode else { return [] }
        let m = model, nid = id
        return [part("scope", r.insetBy(dx: 0, dy: 4), signature: { [weak self] in
            var h = s.version
            if let self { LiveSig.mix(&h, LiveSig.patch(self.node)) }
            LiveSig.mix(&h, (m.isPortConnected(nid, port: 0, output: false) ? 1 : 0) + (m.isPortConnected(nid, port: 1, output: false) ? 2 : 0))
            return h
        }) { [weak self] g, size in
            guard let self else { return }
            ScopeView(node: s, model: m, patchNode: self.node).draw(g, size, hasA: m.isPortConnected(nid, port: 0, output: false),
                                                                    hasB: m.isPortConnected(nid, port: 1, output: false))
        }]
    }
}

// MARK: - slider / knob

final class ControlsDisplay: NativeDisplay {
    private var start: [Int: Float] = [:]
    private var grabbed: Int?
    private var style: ControlsView.Style { spec.kind == "slider" ? .slider : .knob }
    private var view: ControlsView? { dsp.map { ControlsView(style: style, node: $0, model: model, patchNode: node) } }
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    /// Each control's cell (box points).
    private func cells(_ r: CGRect) -> [CGRect] {
        guard let v = view else { return [] }
        let i = inner(r), n = v.count
        if style == .slider {
            let cw = (i.width - CGFloat(n - 1) * 6) / CGFloat(n)
            return (0..<n).map { CGRect(x: i.minX + CGFloat($0) * (cw + 6), y: i.minY, width: cw, height: i.height) }
        }
        let cols = min(n, 4), rows = (n + cols - 1) / cols
        let cw = i.width / CGFloat(cols), rh = i.height / CGFloat(rows)
        return (0..<n).map { k in CGRect(x: i.minX + CGFloat(k % cols) * cw, y: i.minY + CGFloat(k / cols) * rh, width: cw, height: rh) }
    }
    private func cell(_ k: Int) -> ControlCell? {
        guard let v = view, let d = dsp else { return nil }
        let t = v.target(k)
        let anyTarget = (0..<v.count).contains { v.target($0) != nil }
        return ControlCell(style: style, index: k, node: d, model: model, nodeID: id, range: v.range,
                           value: node.params["v\(k + 1)"] ?? 0.5, targetModule: t?.module, targetParam: t?.param,
                           targetValue: t?.value, reserveLabel: anyTarget)
    }
    override func parts(_ r: CGRect) -> [LivePart] {
        cells(r).enumerated().map { k, c in
            part("cell\(k)", c, every: 2, signature: { [weak self] in
                guard let self, let cell = self.cell(k) else { return 0 }
                var h = LiveSig.q(Float(cell.live), 512)
                LiveSig.mix(&h, cell.label.hashValue)
                return h
            }) { [weak self] g, size in
                guard let self, let cell = self.cell(k) else { return }
                if self.style == .slider { cell.drawSlider(g, size) } else { cell.drawKnob(g, size) }
            }
        }
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        guard let k = cells(r).firstIndex(where: { $0.contains(p) }) else { return false }
        grabbed = k
        if info.clickCount >= 2 {
            model.setParam(id, ControlsLayout.valueIndex(k), 0.5); model.scheduleAutosave()
            grabbed = nil
            return true
        }
        start[k] = node.params["v\(k + 1)"] ?? 0.5
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard let k = grabbed, info.moved, let s = start[k] else { return }
        let c = cells(r)[min(k, cells(r).count - 1)]
        let tx = p.x - info.start.x, ty = p.y - info.start.y
        let span: CGFloat = style == .slider ? max(c.height - 24, 40) : 200
        let d = style == .slider ? -ty : (tx - ty)
        model.setParam(id, ControlsLayout.valueIndex(k), min(max(s + Float(d / span), 0), 1))
    }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        if let k = grabbed { start[k] = nil }
        grabbed = nil
        model.scheduleAutosave()
    }
}

// MARK: - eq: response curve with draggable bands

final class EQDisplay: NativeDisplay {
    private var view: EQCurveView?
    private var band: Int?
    private func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    private func eq() -> EQCurveView? {
        guard let d = dsp else { return nil }
        if view == nil { view = EQCurveView(node: d, sampleRate: model.host.sampleRate, model: model, patchNode: node, spec: spec) }
        return view
    }
    override func parts(_ r: CGRect) -> [LivePart] {
        [part("eq", inner(r), every: 2, signature: nil) { [weak self] g, size in self?.eq()?.draw(g, size, band: self?.band) }]
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        let i = inner(r)
        guard i.contains(p), let v = eq() else { return false }
        let lp = CGPoint(x: p.x - i.minX, y: p.y - i.minY)
        let near = v.bandPoints(i.size).min { hypot($0.1.x - lp.x, $0.1.y - lp.y) < hypot($1.1.x - lp.x, $1.1.y - lp.y) }
        guard let (b, pt) = near, hypot(pt.x - lp.x, pt.y - lp.y) < 30 else { band = nil; return true }
        if info.clickCount >= 2 { model.setParam(id, ParametricEQ.gainIndex(b), 0); band = nil; return true }
        band = b
        return true
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard let b = band, let v = eq() else { return }
        let i = inner(r)
        let lp = CGPoint(x: p.x - i.minX, y: p.y - i.minY)
        model.setParam(id, ParametricEQ.freqIndex(b), Float(v.f(lp.x, i.width)))
        let g = min(max(v.gain(lp.y, i.height), -18), 18)
        model.setParam(id, ParametricEQ.gainIndex(b), Float(abs(g) < 0.4 ? 0 : g))
    }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { band = nil }
}

// MARK: - rack and drumsynth: a drum roll (lane names on the left) above pads with M ▶ S

class PadsDisplay: NativeDisplay {
    var lanes: Int { 0 }
    var laneHeight: CGFloat { 9 }
    var labelWidth: CGFloat { 64 }
    var labelSize: CGFloat { 7.5 }
    var padRows: Int { 1 }
    var padCols: Int { 4 }
    var steps: Int { 64 }
    var hits: UnsafeMutablePointer<Float>? { nil }
    func laneName(_ k: Int) -> String { "" }
    func padName(_ k: Int) -> String { laneName(k) }
    func padLevel(_ k: Int) -> Float { fin(dsp?.readouts[1 + k] ?? 0) }
    func padPlaying(_ k: Int) -> Bool { padLevel(k) > 0.05 }
    func audition(_ k: Int) {}
    var nameLines: Int { 1 }
    private var paint: Float?
    private var pressedPad: Int?

    var len: Int { Int((node.params["len"] ?? 16).rounded()) }
    var selected: Int { Int((node.params["sel"] ?? 0).rounded()) }

    func inner(_ r: CGRect) -> CGRect { r.insetBy(dx: 0, dy: 4) }
    func rollRect(_ r: CGRect) -> CGRect {
        let i = inner(r)
        return CGRect(x: i.minX, y: i.minY, width: i.width, height: CGFloat(lanes) * laneHeight)
    }
    func gridRect(_ r: CGRect) -> CGRect { let rr = rollRect(r); return CGRect(x: rr.minX + labelWidth, y: rr.minY, width: rr.width - labelWidth, height: rr.height) }
    /// pad k's rect (pad 1 bottom-left)
    func padRect(_ k: Int, _ r: CGRect) -> CGRect {
        let i = inner(r), top = rollRect(r).maxY + 8, gap: CGFloat = 4
        let pw = (i.width - gap * CGFloat(padCols - 1)) / CGFloat(padCols)
        let row = padRows - 1 - k / padCols, col = k % padCols
        return CGRect(x: i.minX + CGFloat(col) * (pw + gap), y: top + CGFloat(row) * (42 + gap), width: pw, height: 42)
    }
    func padButtons(_ k: Int, _ r: CGRect) -> [(String, CGRect)] {
        let p = padRect(k, r)
        return ["M", "▶", "S"].enumerated().map { j, s in (s, CGRect(x: p.minX + 4 + CGFloat(j) * 17, y: p.maxY - 4 - 12, width: 15, height: 12)) }
    }
    func flag(_ key: String) -> Bool { (node.params[key] ?? 0) > 0.5 }
    func select(_ k: Int) { setParam("sel", Float(k)) }
    func toggle(_ key: String) { setParam(key, flag(key) ? 0 : 1) }
    func drawRoll(_ g: LiveGC, _ size: CGSize) {}
    func commit() {}

    override func parts(_ r: CGRect) -> [LivePart] {
        let m = model, d = dsp
        let roll = part("roll", gridRect(r), signature: { [weak self] in
            guard let self, let h0 = self.hits else { return 0 }
            var h = m.isRunning ? Int(d?.readouts[0] ?? 0) : -1
            LiveSig.mix(&h, LiveSig.floats(h0, self.lanes * self.steps))
            LiveSig.mix(&h, LiveSig.patch(self.node)); LiveSig.mix(&h, self.selected)
            return h
        }) { [weak self] g, size in self?.drawRoll(g, size) }
        // a pad lights while it plays: just on / off, no fade
        let n = padRows * padCols
        let top = padRect(n - padCols, r).minY
        let padsArea = CGRect(x: inner(r).minX, y: top, width: inner(r).width, height: padRect(0, r).maxY - top)
        let pads = part("pads", padsArea, signature: { [weak self] in
            guard let self else { return 0 }
            var h = 0
            for k in 0..<n where self.padPlaying(k) { h |= 1 << k }
            return h
        }) { [weak self] g, size in
            guard let self else { return }
            for k in 0..<n {
                let pr = self.padRect(k, r).offsetBy(dx: -padsArea.minX, dy: -padsArea.minY)
                if self.padPlaying(k) { g.fill(Path(pr), with: .color(Theme.text.opacity(0.14))) }
            }
        }
        return [roll, pads]
    }

    override func paintStatic(_ g: LiveGC, _ r: CGRect) {
        let rr = rollRect(r)
        for k in 0..<lanes {
            let y = rr.minY + CGFloat(k) * laneHeight + laneHeight / 2
            g.draw(LiveText(fitText(laneName(k), size: labelSize, width: labelWidth - 6), size: labelSize, color: k == selected ? Theme.text : Theme.dim),
                   at: CGPoint(x: rr.minX, y: y), anchor: .leading)
        }
        for k in 0..<(padRows * padCols) {
            let p = padRect(k, r)
            let muted = flag("m\(k + 1)"), solo = flag("s\(k + 1)")
            g.fill(Path(p), with: .color(Theme.row))
            let loading = model.loadingPads[id]?.contains(k) == true
            let title = dropPad == k ? "drop to load" : (loading ? "loading…" : padName(k))
            // name: up to two lines
            let maxW = p.width - 8
            var lines: [String] = []
            var rest = title
            while !rest.isEmpty && lines.count < nameLines {
                var cut = rest
                while cut.count > 1 && textWidth(cut, size: 8.5) > maxW { cut.removeLast() }
                if lines.count == nameLines - 1 && cut.count < rest.count { cut = fitText(rest, size: 8.5, width: maxW) ; rest = "" }
                else { rest = String(rest.dropFirst(cut.count)) }
                lines.append(cut)
            }
            for (j, l) in lines.enumerated() {
                g.draw(LiveText(l, size: 8.5, color: muted ? Theme.faint : (loading ? Theme.dim : Theme.text)),
                       at: CGPoint(x: p.minX + 4, y: p.minY + 4 + 5.5 + CGFloat(j) * 11), anchor: .leading)
            }
            for (s, b) in padButtons(k, r) {
                let on = (s == "M" && muted) || (s == "S" && solo)
                g.fill(Path(b), with: .color(on ? Theme.text : Theme.box))
                g.draw(LiveText(s, size: 8, color: on ? Theme.inverse : Theme.dim, bold: true), at: CGPoint(x: b.midX, y: b.midY))
            }
            let sel = k == selected, drop = dropPad == k
            if drop { g.fill(Path(p), with: .color(Theme.text.opacity(0.12))) }
            let lw: CGFloat = drop ? 2.5 : (sel ? 1.5 : 0.5)
            g.stroke(Path(p.insetBy(dx: lw / 2, dy: lw / 2)), with: .color(sel || drop ? Theme.text : Theme.border), lineWidth: lw)
        }
    }

    private enum Grab { case roll, none }
    private var grab = Grab.none
    private func paintRoll(_ p: CGPoint, _ r: CGRect) {
        guard let h = hits else { return }
        let gr = gridRect(r)
        let cw = gr.width / CGFloat(max(len, 1))
        let s = Int((p.x - gr.minX) / cw), lane = Int((p.y - gr.minY) / laneHeight)
        guard s >= 0 && s < len && lane >= 0 && lane < lanes else { return }
        let i = lane * steps + s
        if paint == nil { paint = h[i] > 0.5 ? 0 : 1 }
        h[i] = paint!
    }
    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        grab = .none
        if gridRect(r).contains(p) { paint = nil; grab = .roll; paintRoll(p, r); return true }
        let rr = rollRect(r)
        if rr.contains(p) {          // a lane name
            let k = Int((p.y - rr.minY) / laneHeight)
            if k >= 0 && k < lanes { select(k) }
            return true
        }
        for k in 0..<(padRows * padCols) where padRect(k, r).contains(p) { pressedPad = k; return true }
        return false
    }
    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) { if grab == .roll { paintRoll(p, r) } }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        if grab == .roll { paint = nil; grab = .none; commit(); return }
        defer { pressedPad = nil }
        guard let k = pressedPad, !info.moved, padRect(k, r).contains(p) else { return }
        for (s, b) in padButtons(k, r) where b.contains(p) {
            switch s {
            case "M": toggle("m\(k + 1)")
            case "S": toggle("s\(k + 1)")
            default: audition(k); select(k)
            }
            return
        }
        select(k)                    // the pad itself only selects it (▶ plays it)
    }
}

final class RackDisplay: PadsDisplay {
    private var rack: RackNode? { dsp as? RackNode }
    override var lanes: Int { RackLayout.pads }
    override var laneHeight: CGFloat { BoxLayout.padLaneHeight(node) }
    override var labelWidth: CGFloat { RackView.label }
    override var labelSize: CGFloat { 7.5 }
    override var padRows: Int { 4 }
    override var steps: Int { RackLayout.steps }
    override var nameLines: Int { 2 }
    override var hits: UnsafeMutablePointer<Float>? { rack?.hits }
    override func laneName(_ k: Int) -> String { rack?.padNames[k] ?? "" }
    override func audition(_ k: Int) { rack?.audition = k }
    override func drawRoll(_ g: LiveGC, _ size: CGSize) {
        guard let n = rack else { return }
        RackView(node: n, model: model, patchNode: node).drawRoll(g, size)
    }
    override func commit() {
        guard let n = rack else { return }
        model.setData(id, "hits", (0..<RackLayout.pads * RackLayout.steps).map { n.hits[$0] })
    }
    override func menu(_ p: CGPoint, _ r: CGRect) -> [MenuItem]? {
        guard let k = pad(at: p, r) else { return nil }
        let m = model, nid = id
        return [MenuItem(title: "Back to the built-in \(RackLayout.kitNames[k])", action: { m.resetPad(nid, k) })]
    }
    override func pad(at p: CGPoint, _ r: CGRect) -> Int? {
        (0..<RackLayout.pads).first { padRect($0, r).contains(p) }
    }
}

final class DrumSynthDisplay: PadsDisplay {
    private var synth: DrumSynthNode? { dsp as? DrumSynthNode }
    override var lanes: Int { DrumSynthLayout.voices }
    override var laneHeight: CGFloat { BoxLayout.padLaneHeight(node) }
    override var labelWidth: CGFloat { DrumSynthView.label }
    override var labelSize: CGFloat { 8.5 }
    override var padRows: Int { 1 }
    override var padCols: Int { DrumSynthLayout.voices }
    override var steps: Int { DrumSynthLayout.steps }
    override var hits: UnsafeMutablePointer<Float>? { synth?.hits }
    override func laneName(_ v: Int) -> String {
        guard let n = synth else { return "" }
        return DrumSynthView(node: n, model: model, patchNode: node).name(v)
    }
    override func audition(_ k: Int) { synth?.audition = k }
    override func drawRoll(_ g: LiveGC, _ size: CGSize) {
        guard let n = synth else { return }
        DrumSynthView(node: n, model: model, patchNode: node).drawRoll(g, size)
    }
    override func commit() {
        guard let n = synth else { return }
        model.setData(id, "hits", (0..<DrumSynthLayout.voices * DrumSynthLayout.steps).map { n.hits[$0] })
    }
}
