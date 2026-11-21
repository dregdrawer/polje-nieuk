import SwiftUI
import PoljeNieukCore

/// Rolling history for scope-style displays. Sampled from the draw loop, at most `rate` times a second.
final class Trace {
    let length: Int
    let rate: Double
    private(set) var rows: [[Float]]
    var head = 0
    var last: TimeInterval = 0
    init(channels: Int, seconds: Double, rate: Double = 40) {
        self.rate = rate
        length = Int(seconds * rate)
        rows = Array(repeating: Array(repeating: 0, count: Int(seconds * rate)), count: channels)
    }
    func push(_ values: [Float], at t: TimeInterval) {
        guard t - last >= 1 / rate else { return }
        let steps = min(max(Int((t - last) * rate), 1), length)
        last = t
        for _ in 0..<steps {
            for c in rows.indices { rows[c][head] = c < values.count ? values[c] : 0 }
            head = (head + 1) % length
        }
    }
    /// value k samples ago-ordered oldest → newest
    @inline(__always) func value(_ c: Int, _ i: Int) -> Float { rows[c][(head + i) % length] }
}

@inline(__always) private func toDB(_ x: Float) -> Float { 20 * log10f(max(fin(x), 1e-5)) }

// MARK: - comp: level / gain-reduction history + transfer curve

struct CompView: View {
    let node: DSPNode
    var trace = Trace(channels: 3, seconds: 4)
    let floorDB: Float = -48

    var body: some View {
        HStack(spacing: 6) {
            // 10 fps: a gain-reduction history looks the same, at half the redraws
            LiveCanvas(every: 2) { ctx, size in drawHistory(ctx, size) }
            LiveCanvas(every: 2) { ctx, size in drawCurve(ctx, size) }
                .aspectRatio(1, contentMode: .fit)
        }
        .padding(.vertical, 4)
    }

    func y(_ db: Float, _ h: CGFloat) -> CGFloat {
        CGFloat(1 - (min(max(db, floorDB), 0) - floorDB) / -floorDB) * h
    }

    func drawHistory(_ ctx: LiveGC, _ size: CGSize) {
        let r = node.readouts
        trace.push([toDB(r[1]), toDB(r[2]), fin(r[0])], at: Date().timeIntervalSinceReferenceDate)
        let w = size.width, h = size.height - 12
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Theme.row))
        for db: Float in [-12, -24, -36] {
            ctx.fill(Path(CGRect(x: 0, y: y(db, h), width: w, height: 0.5)), with: .color(Theme.faint.opacity(0.5)))
        }
        let n = trace.length
        let dx = w / CGFloat(n - 1)
        // input level: filled, dim
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: 0, y: h))
        for i in 0..<n { fillPath.addLine(to: CGPoint(x: CGFloat(i) * dx, y: y(trace.value(0, i), h))) }
        fillPath.addLine(to: CGPoint(x: w, y: h)); fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(Theme.text.opacity(0.16)))
        // output level: line
        var out = Path()
        for i in 0..<n {
            let p = CGPoint(x: CGFloat(i) * dx, y: y(trace.value(1, i), h))
            if i == 0 { out.move(to: p) } else { out.addLine(to: p) }
        }
        ctx.stroke(out, with: .color(Theme.text.opacity(0.85)), lineWidth: 1)
        // gain reduction: hangs from the top (0…24 dB)
        var gr = Path()
        gr.move(to: .zero)
        for i in 0..<n { gr.addLine(to: CGPoint(x: CGFloat(i) * dx, y: CGFloat(min(trace.value(2, i) / 24, 1)) * h)) }
        gr.addLine(to: CGPoint(x: w, y: 0)); gr.closeSubpath()
        ctx.fill(gr, with: .color(Theme.meterYellow.opacity(0.75)))
        let label = String(format: "GR %4.1f dB   in %5.1f   out %5.1f", fin(r[0]), toDB(r[1]), toDB(r[2]))
        ctx.draw(LiveText(label, size: 9, color: Theme.dim), at: CGPoint(x: 0, y: size.height - 5), anchor: .leading)
    }

    /// Static transfer curve (input dB → output dB) with the live operating point.
    func drawCurve(_ ctx: LiveGC, _ size: CGSize) {
        let r = node.readouts
        let thr = fin(r[3]), ratio = max(fin(r[4]), 1), knee = max(fin(r[5]), 0), makeup = fin(r[6])
        let s = min(size.width, size.height)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: s, height: s)), with: .color(Theme.row))
        func px(_ db: Float) -> CGFloat { CGFloat((min(max(db, floorDB), 0) - floorDB) / -floorDB) * s }
        func curve(_ x: Float) -> Float {
            let over = x - thr
            let red: Float
            if knee > 0 && abs(over) < knee / 2 { let t = over + knee / 2; red = (1 - 1 / ratio) * t * t / (2 * knee) }
            else { red = over > 0 ? (1 - 1 / ratio) * over : 0 }
            return x - red + makeup
        }
        // unity diagonal
        var diag = Path(); diag.move(to: CGPoint(x: 0, y: s)); diag.addLine(to: CGPoint(x: s, y: 0))
        ctx.stroke(diag, with: .color(Theme.faint.opacity(0.6)), lineWidth: 0.5)
        var p = Path()
        for k in 0...40 {
            let x = floorDB + Float(k) / 40 * -floorDB
            let pt = CGPoint(x: px(x), y: s - px(curve(x)))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        ctx.stroke(p, with: .color(Theme.text.opacity(0.85)), lineWidth: 1)
        // threshold tick
        ctx.fill(Path(CGRect(x: px(thr), y: 0, width: 0.5, height: s)), with: .color(Theme.dim.opacity(0.5)))
        // where the signal is right now
        let inDB = toDB(r[1])
        if inDB > floorDB {
            let dot = CGPoint(x: px(inDB), y: s - px(curve(inDB)))
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(Theme.meterYellow))
        }
    }
}

// MARK: - lfo: the waveform with a moving playhead

struct LFOView: View {
    let node: DSPNode
    let patchNode: PatchNode

    var body: some View {
        LiveCanvas(smooth: true) { ctx, size in draw(ctx, size) }
            .padding(.vertical, 4)
    }

    func draw(_ ctx: LiveGC, _ size: CGSize) {
        let r = node.readouts
        let shape = Int((patchNode.params["shape"] ?? 0).rounded())
        let depth = patchNode.params["depth"] ?? 0.5, offset = patchNode.params["offset"] ?? 0
        let w = size.width - 44, h = size.height
        func y(_ v: Float) -> CGFloat { CGFloat(0.5 - min(max(fin(v), -1), 1) * 0.5) * h }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Theme.row))
        ctx.fill(Path(CGRect(x: 0, y: h / 2, width: w, height: 0.5)), with: .color(Theme.faint))
        var p = Path()
        if shape == 4 {
            // random: the last six values and the glide now under way, scrolling left as it plays;
            // the newest point is the current output, on the right edge
            let ph = min(max(fin(r[1]), 0), 1)
            for i in 0...120 {
                let u = Float(i) / 120 * 6 + ph               // cycles since the oldest value
                let k = min(Int(u), 6), f = u - Float(k)
                let a0 = r[2 + k] * depth + offset, a1 = r[3 + k] * depth + offset
                let kk = (1 - cosf(.pi * f)) / 2
                let pt = CGPoint(x: CGFloat(i) / 120 * w, y: y(a0 + (a1 - a0) * kk))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        } else {
            for k in 0...80 {
                let ph = Float(k) / 80
                let v: Float
                switch shape {
                case 0: v = sinf(2 * .pi * ph)
                case 1: v = ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph
                case 2: v = 2 * ph - 1
                default: v = ph < 0.5 ? 1 : -1
                }
                let pt = CGPoint(x: CGFloat(ph) * w, y: y(v * depth + offset))
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        ctx.stroke(p, with: .color(Theme.text.opacity(0.75)), lineWidth: 1)
        // playhead and current value
        let ph = CGFloat(min(max(fin(r[1]), 0), 1))
        let px = shape == 4 ? w : ph * w
        ctx.fill(Path(CGRect(x: px, y: 0, width: 0.5, height: h)), with: .color(Theme.dim))
        let cur = CGPoint(x: px, y: y(r[0]))
        ctx.fill(Path(ellipseIn: CGRect(x: cur.x - 3, y: cur.y - 3, width: 6, height: 6)), with: .color(Theme.text))
        // value meter on the right
        let bx = w + 8
        ctx.fill(Path(CGRect(x: bx, y: 0, width: 6, height: h)), with: .color(Theme.row))
        let v0 = h / 2, v1 = y(r[0])
        ctx.fill(Path(CGRect(x: bx, y: min(v0, v1), width: 6, height: abs(v1 - v0))), with: .color(Theme.text.opacity(0.8)))
        ctx.draw(LiveText(String(format: "%+.1f", fin(r[0]) * 10), size: 9, color: Theme.dim),
                 at: CGPoint(x: size.width, y: h / 2), anchor: .trailing)
    }
}
