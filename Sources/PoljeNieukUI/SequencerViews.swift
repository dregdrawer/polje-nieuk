import SwiftUI
import PoljeNieukCore

// Editable displays for the Sequencing modules. Finger, mouse or Apple Pencil; drag to paint.

// MARK: - keys~

struct KeysView: View {
    let node: KeysNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State private var lastKey = -1

    private static let whiteSemis = [0, 2, 4, 5, 7, 9, 11]
    private static let blackSemis = [1, 3, 6, 8, 10]

    private var latch: Bool { (patchNode.params["latch"] ?? 0) > 0.5 }

    // Geometry on whole points: every key edge is snapped, so all the gaps (the outlines) are the same
    // 1 pt — fractional edges made some lines look thicker or blurrier than others.
    private static func edge(_ i: Int, _ width: CGFloat) -> CGFloat { (CGFloat(i) * width / 15).rounded() }
    private static func whiteRect(_ w: Int, _ size: CGSize) -> CGRect {
        let x0 = edge(w, size.width), x1 = edge(w + 1, size.width)
        return CGRect(x: x0, y: 0, width: max(x1 - x0 - 1, 1), height: size.height.rounded())
    }
    private static func blackRect(_ whiteIndex: Int, _ size: CGSize) -> CGRect {
        let bw = max((size.width / 15 * 0.6 / 2).rounded() * 2, 2)       // even, so it centres on the gap
        let centre = edge(whiteIndex + 1, size.width) - 0.5               // the middle of the 1 pt gap
        return CGRect(x: (centre - bw / 2).rounded(), y: 0, width: bw, height: (size.height * 0.6).rounded())
    }

    /// key index (0…24) under a point
    private func key(at p: CGPoint, _ size: CGSize) -> Int? {
        // black keys first (upper part)
        for o in 0..<2 {
            for (j, s) in Self.blackSemis.enumerated() {
                let r = Self.blackRect([0, 1, 3, 4, 5][j] + o * 7, size).insetBy(dx: -1, dy: 0)
                if r.contains(p) { return o * 12 + s }
            }
        }
        guard p.x >= 0 && p.x <= size.width else { return nil }
        let w = min(max((0..<15).last { Self.edge($0, size.width) <= p.x } ?? 0, 0), 14)
        return w == 14 ? 24 : (w / 7) * 12 + Self.whiteSemis[w % 7]
    }

    var body: some View {
        GeometryReader { geo in
            LiveCanvas(signature: {
                var h = model.isRunning ? Int(node.readouts[0]) : -1
                LiveSig.mix(&h, node.touchNote)
                LiveSig.mix(&h, LiveSig.floats(node.latched, KeysNode.keyCount))
                LiveSig.mix(&h, LiveSig.patch(patchNode))
                return h
            }) { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                // high priority: a key press must never be taken by the canvas (pan, select, pencil)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            guard let k = key(at: v.location, geo.size) else { return }
                            if latch {
                                if k != lastKey { node.toggleLatched(k); lastKey = k }
                            } else {
                                if k != lastKey { node.pressNote = k; node.pressCount &+= 1; lastKey = k }
                                node.touchNote = k
                            }
                        }
                        .onEnded { _ in node.touchNote = -1; lastKey = -1 }
                )
        }
    }

    private func draw(_ ctx: LiveGC, _ size: CGSize) {
        // the engine only reports the sounding note while audio runs (its readout starts at 0 = the lowest C)
        let sounding = model.isRunning ? Int(node.readouts[0]) : -1
        // a key lights up as a whole while it's pressed, latched or sounding
        func lit(_ k: Int) -> Bool { node.touchNote == k || node.latched[k] > 0.5 || k == sounding }
        // the gaps between keys are the outline: one colour, exactly 1 pt everywhere
        let gap = Theme.boxIsLight ? Theme.border : Theme.box
        let total = CGRect(x: 0, y: 0, width: Self.edge(15, size.width) - 1, height: size.height.rounded())
        ctx.fill(Path(total), with: .color(gap))
        for w in 0..<15 {
            let k = w == 14 ? 24 : (w / 7) * 12 + Self.whiteSemis[w % 7]
            ctx.fill(Path(Self.whiteRect(w, size)), with: .color(lit(k) ? Theme.keyWhiteLit : Theme.keyWhite))
        }
        for o in 0..<2 {
            for (j, s) in Self.blackSemis.enumerated() {
                let k = o * 12 + s
                let r = Self.blackRect([0, 1, 3, 4, 5][j] + o * 7, size)
                ctx.fill(Path(r.insetBy(dx: -1, dy: 0).offsetBy(dx: 0, dy: 0).union(CGRect(x: r.minX - 1, y: 0, width: r.width + 2, height: r.height + 1))),
                         with: .color(Theme.box))                                       // 1 pt frame (sides and bottom)
                ctx.fill(Path(r), with: .color(lit(k) ? Theme.keyBlackLit : Theme.keyBlack))
            }
        }
    }
}

// MARK: - seq~

struct SeqView: View {
    let node: SeqNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State private var paintGate: Float?

    private let range: Float = 24
    /// Columns shown: 16, or the whole pattern when it's 32 / 64 steps.
    private var cols: Int { max(16, SeqNode.length(patchNode.params["len"] ?? 8)) }
    private let gateRow: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            LiveCanvas(signature: {
                // the playhead step, the pattern (edited live while dragging) and the settings
                var h = model.isRunning ? Int(node.readouts[0]) : -1
                LiveSig.mix(&h, LiveSig.floats(node.pitches, SeqNode.steps))
                LiveSig.mix(&h, LiveSig.floats(node.gates, SeqNode.steps))
                LiveSig.mix(&h, LiveSig.patch(patchNode))
                LiveSig.mix(&h, LiveSig.q(paintGate ?? -1, 4))
                return h
            }) { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in edit(v.location, start: v.startLocation, geo.size) }
                        .onEnded { _ in paintGate = nil; commit() }
                )
        }
    }

    private func edit(_ p: CGPoint, start: CGPoint, _ size: CGSize) {
        let colW = size.width / CGFloat(cols)
        let col = min(max(Int(p.x / colW), 0), cols - 1)
        let barH = size.height - gateRow - 2
        if start.y > barH {
            // gate row: tap toggles, drag paints the same state
            if paintGate == nil { paintGate = node.gates[col] > 0.5 ? 0 : 1 }
            node.gates[col] = paintGate!
        } else {
            let v = Float(1 - min(max(p.y / barH, 0), 1)) * 2 - 1        // -1 … 1
            node.pitches[col] = (v * range).rounded()
        }
    }

    private func commit() {
        model.setData(patchNode.id, ["pitch": (0..<SeqNode.steps).map { node.pitches[$0] },
                                     "gate": (0..<SeqNode.steps).map { node.gates[$0] }])
    }

    private func draw(_ ctx: LiveGC, _ size: CGSize) {
        let n = cols
        let colW = size.width / CGFloat(n)
        let barH = size.height - gateRow - 2
        let len = SeqNode.length(patchNode.params["len"] ?? 8)
        let cur = model.isRunning ? Int(node.readouts[0]) : -1      // no playing step while audio is off
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        // pitch grid: a faint line per semitone when there's room, stronger lines (labelled) per octave
        let semi = barH / CGFloat(range * 2)
        func yOf(_ st: Int) -> CGFloat { barH / 2 - CGFloat(st) / CGFloat(range) * barH / 2 }
        if semi >= 2.5 {
            for st in -Int(range)...Int(range) where st % 12 != 0 {
                ctx.fill(Path(CGRect(x: 0, y: yOf(st), width: size.width, height: 0.5)), with: .color(Theme.faint.opacity(0.35)))
            }
        }
        for st in stride(from: -Int(range), through: Int(range), by: 12) {
            ctx.fill(Path(CGRect(x: 0, y: yOf(st), width: size.width, height: st == 0 ? 1 : 0.5)),
                     with: .color(st == 0 ? Theme.faint : Theme.faint.opacity(0.8)))
            ctx.draw(LiveText(st == 0 ? "0" : String(format: "%+d", st), size: 7, color: Theme.dim),
                     at: CGPoint(x: 2, y: min(max(yOf(st) + (st > 0 ? 5 : -5), 4), barH - 4)), anchor: .leading)
        }
        for c in 0..<n {
            let x = CGFloat(c) * colW
            let active = c < len
            if c == cur { ctx.fill(Path(CGRect(x: x, y: 0, width: colW, height: size.height)), with: .color(Theme.text.opacity(0.12))) }
            let v = CGFloat(node.pitches[c] / range)
            let y0 = barH / 2, y1 = barH / 2 - v * barH / 2
            let gap: CGFloat = colW < 10 ? 1 : 2
            let r = CGRect(x: x + gap, y: min(y0, y1), width: colW - 2 * gap, height: max(abs(y1 - y0), 1.5))
            ctx.fill(Path(r), with: .color(active ? Theme.text : Theme.faint))   // same solid colour as the gate buttons
            let g = CGRect(x: x + gap, y: barH + 2, width: colW - 2 * gap, height: gateRow - 2)
            ctx.fill(Path(g),
                     with: .color(node.gates[c] > 0.5 ? (active ? Theme.text : Theme.dim) : Theme.box))

        }
        drawStepGrid(ctx, size, steps: n, division: patchNode.params["div"])
        // steps past the length don't play: grey that part of the display out, with an edge at the loop end
        if len < n {
            let x0 = CGFloat(len) * colW
            let off = CGRect(x: x0, y: 0, width: size.width - x0, height: size.height)
            ctx.fill(Path(off), with: .color(Theme.box.opacity(0.72)))
            var hatch = Path()
            var hx = x0 - size.height
            while hx < size.width {
                hatch.move(to: CGPoint(x: hx, y: size.height)); hatch.addLine(to: CGPoint(x: hx + size.height, y: 0))
                hx += 6
            }
            ctx.clipped(to: Path(off)) { l in
                l.stroke(hatch, with: .color(Theme.faint.opacity(0.35)), lineWidth: 0.5)
            }
            ctx.fill(Path(CGRect(x: x0 - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.text.opacity(0.6)))
        }
    }
}

// MARK: - turing~

struct TuringView: View {
    let node: DSPNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)

    var body: some View {
        LiveCanvas(signature: { LiveSig.readouts(node, 24) &+ (model.isRunning ? 1 : 0) }) { ctx, size in draw(ctx, size) }
    }

    /// Top: the shift register — only the bits in the loop, newest on the right. Middle: the loop as it will play (filled = plays, outline = silent).
    /// Bottom: the CV output right now.
    private func draw(_ ctx: LiveGC, _ size: CGSize) {
        guard model.isRunning else {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
            ctx.draw(LiveText("audio off", size: 9, color: Theme.dim),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let r = node.readouts
        let reg = UInt32(max(fin(r[0]), 0))
        let len = max(min(Int(fin(r[1])), 16), 2)
        // register
        let regH: CGFloat = 12
        let cw = size.width / CGFloat(len)
        for b in 0..<len {
            let bit = len - 1 - b                         // leftmost = oldest bit in the loop
            let on = (reg >> UInt32(bit)) & 1 == 1
            let cell = CGRect(x: CGFloat(b) * cw + 1, y: 0, width: cw - 2, height: regH - 3)
            ctx.fill(Path(cell), with: .color(on ? Theme.text : Theme.row))
        }
        // the loop as it will play from now: step 0 (left, highlighted) is sounding, then the next ones.
        // Dark = plays, plain box colour = silent step (holds the pitch). Follows notes / length / range / scale at once.
        let top = regH + 3, bottom = size.height - 8
        let gates = UInt32(max(fin(r[4]), 0))
        var notes: [Float] = []
        for k in 0..<len { notes.append(fin(r[8 + k])) }
        let lo = notes.min() ?? 0, hi = max(notes.max() ?? 1, lo + 12)
        let sw = size.width / CGFloat(len)
        ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)), with: .color(Theme.row))
        ctx.fill(Path(CGRect(x: 0, y: top, width: sw, height: bottom - top)), with: .color(Theme.text.opacity(0.1)))
        for k in 0..<len {
            let y = bottom - CGFloat((notes[k] - lo) / (hi - lo)) * (bottom - top - 4) - 4
            let cell = CGRect(x: CGFloat(k) * sw + 1, y: y, width: sw - 2, height: 3)
            if (gates >> UInt32(k)) & 1 == 1 { ctx.fill(Path(cell), with: .color(Theme.text)) }
            else { ctx.fill(Path(cell), with: .color(Theme.box)) }          // silent step: plain, no outline
        }
        // cv now
        let cv = CGFloat(min(max(fin(r[2]), 0), 1))
        ctx.fill(Path(CGRect(x: 0, y: size.height - 4, width: size.width, height: 3)), with: .color(Theme.row))
        ctx.fill(Path(CGRect(x: 0, y: size.height - 4, width: size.width * cv, height: 3)), with: .color(Theme.text.opacity(0.7)))
    }
}

// MARK: - roll~ and drums~ grids

struct GridEditor: View {
    enum Kind { case roll(RollNode), drums(DrumsNode) }
    let kind: Kind
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode
    @State private var paint: Float?

    private var rows: Int { if case .roll = kind { return RollNode.rows } else { return DrumsNode.lanes } }
    private var len: Int { Int((patchNode.params["len"] ?? 16).rounded()) }
    private var playStep: Int {
        switch kind { case .roll(let n): return Int(n.readouts[0]); case .drums(let n): return Int(n.readouts[0]) }
    }

    private func isOn(_ step: Int, _ row: Int) -> Bool {
        switch kind {
        case .roll(let n): return Int(n.notes[step]) == row
        case .drums(let n): return n.hits[row * DrumsNode.steps + step] > 0.5
        }
    }

    private func set(_ step: Int, _ row: Int, _ on: Bool) {
        switch kind {
        case .roll(let n): n.notes[step] = on ? Float(row) : (Int(n.notes[step]) == row ? -1 : n.notes[step])
        case .drums(let n): n.hits[row * DrumsNode.steps + step] = on ? 1 : 0
        }
    }

    private func commit() {
        switch kind {
        case .roll(let n): model.setData(patchNode.id, "notes", (0..<RollNode.steps).map { n.notes[$0] })
        case .drums(let n): model.setData(patchNode.id, "hits", (0..<DrumsNode.steps * DrumsNode.lanes).map { n.hits[$0] })
        }
    }

    var body: some View {
        GeometryReader { geo in
            LiveCanvas(signature: {
                var h = model.isRunning ? playStep : -1
                switch kind {
                case .roll(let n): LiveSig.mix(&h, LiveSig.floats(n.notes, RollNode.steps))
                case .drums(let n): LiveSig.mix(&h, LiveSig.floats(n.hits, DrumsNode.steps * DrumsNode.lanes))
                }
                LiveSig.mix(&h, LiveSig.patch(patchNode))
                return h
            }) { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let cw = geo.size.width / CGFloat(max(len, 1)), rh = geo.size.height / CGFloat(rows)
                            let step = Int(v.location.x / cw), row = rowAt(v.location.y, rh)
                            guard step >= 0 && step < len && row >= 0 && row < rows else { return }
                            if paint == nil { paint = isOn(step, row) ? 0 : 1 }
                            set(step, row, paint == 1)
                        }
                        .onEnded { _ in paint = nil; commit() }
                )
        }
    }

    /// drums~: lane 1 at the top, beside outlet 1. roll~: low notes at the bottom, like a piano roll.
    private var topDown: Bool { if case .drums = kind { return true } else { return false } }
    private func rowY(_ r: Int, _ rh: CGFloat, _ h: CGFloat) -> CGFloat { topDown ? CGFloat(r) * rh : h - CGFloat(r + 1) * rh }
    private func rowAt(_ y: CGFloat, _ rh: CGFloat) -> Int { let i = Int(floor(y / rh)); return topDown ? i : rows - 1 - i }

    private func draw(_ ctx: LiveGC, _ size: CGSize) {
        let cw = size.width / CGFloat(max(len, 1)), rh = size.height / CGFloat(rows)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        // piano roll: highlight C rows; drums: alternate lanes
        for r in 0..<rows {
            let y = rowY(r, rh, size.height)
            let shade: Bool
            if case .roll = kind { shade = [1, 3, 6, 8, 10].contains(r % 12) } else { shade = r % 2 == 1 }
            if shade { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rh)), with: .color(Theme.shade)) }
            if case .roll = kind, r % 12 == 0 {
                ctx.fill(Path(CGRect(x: 0, y: y + rh - 0.5, width: size.width, height: 0.5)), with: .color(Theme.dim.opacity(0.6)))
            }
        }
        drawStepGrid(ctx, size, steps: len, division: patchNode.params["div"])
        let ps = model.isRunning ? playStep : -1
        if ps >= 0 && ps < len {
            ctx.fill(Path(CGRect(x: CGFloat(ps) * cw, y: 0, width: cw, height: size.height)), with: .color(Theme.text.opacity(0.12)))
        }
        for s in 0..<len {
            for r in 0..<rows where isOn(s, r) {
                let rect = CGRect(x: CGFloat(s) * cw + 1, y: rowY(r, rh, size.height) + 1, width: cw - 2, height: rh - 2)
                ctx.fill(Path(rect), with: .color(s == ps ? Theme.text : Theme.text.opacity(0.75)))
            }
        }
    }
}
