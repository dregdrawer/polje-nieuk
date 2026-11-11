import SwiftUI
import PoljeNieukCore

/// scope~'s screen: both channels' waveforms (A bright, B dim) on a volt grid, with each channel's
/// average, range and frequency — and, for a steady signal, the note it would play at 1 V/oct.
struct ScopeView: View {
    let node: ScopeNode
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let patchNode: PatchNode

    var body: some View {
        let hasA = model.isPortConnected(patchNode.id, port: 0, output: false)
        let hasB = model.isPortConnected(patchNode.id, port: 1, output: false)
        LiveCanvas(signature: {
            var h = node.version
            LiveSig.mix(&h, LiveSig.patch(patchNode))
            LiveSig.mix(&h, (hasA ? 1 : 0) + (hasB ? 2 : 0))
            return h
        }) { ctx, size in draw(ctx, size, hasA: hasA, hasB: hasB) }
    }

    /// 0.1 = 1 V in the app's units
    static func volts(_ v: Float) -> String { String(format: "%+.2f V", v * 10) }
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// The note a voltage plays at 1 V/oct (0 V = C4, middle C), with cents.
    static func note(_ v: Float) -> String {
        let semis = Double(v) * 120
        let n = Int(semis.rounded())
        let cents = Int(((semis - Double(n)) * 100).rounded())
        let name = noteNames[((n % 12) + 12) % 12]
        let octave = 4 + Int((Double(n) / 12).rounded(.down))
        return "\(name)\(octave)" + (cents == 0 ? "" : String(format: " %+d¢", cents))
    }
    static func hz(_ f: Float) -> String {
        f <= 0 ? "" : (f >= 1000 ? String(format: "%.2f kHz", f / 1000) : (f >= 10 ? String(format: "%.1f Hz", f) : String(format: "%.2f Hz", f)))
    }

    private func draw(_ ctx: LiveGC, _ size: CGSize, hasA: Bool, hasB: Bool) {
        let n = ScopeNode.points
        let r = node.readouts
        let w = size.width, top: CGFloat = hasA && hasB ? 34 : 20, h = max(size.height - top - 14, 10)
        // vertical scale: fixed, or auto (the next round range above the biggest swing on screen)
        let pick = Int((patchNode.params["scale"] ?? 0).rounded())
        var full = ScopeNode.scaleValues[min(max(pick, 0), ScopeNode.scaleValues.count - 1)]
        if full == 0 {
            var m: Float = 0
            for c in 0..<2 where (c == 0 ? hasA : hasB) {
                for p in 0..<n { m = max(m, abs(fin(node.shownMin[c * n + p])), abs(fin(node.shownMax[c * n + p]))) }
            }
            full = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1].first { $0 >= m * 1.05 } ?? 1
        }
        func y(_ v: Float) -> CGFloat { top + CGFloat(0.5 - min(max(fin(v) / full, -1), 1) * 0.5) * h }
        ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: h)), with: .color(Theme.row))
        for k in 1..<4 { ctx.fill(Path(CGRect(x: 0, y: top + h * CGFloat(k) / 4, width: w, height: 0.5)), with: .color(Theme.faint)) }
        for k in 1..<8 { ctx.fill(Path(CGRect(x: w * CGFloat(k) / 8, y: top, width: 0.5, height: h)), with: .color(Theme.faint.opacity(0.5))) }
        // traces: B under A
        for c in [1, 0] where (c == 0 ? hasA : hasB) {
            // one path: down each pixel column's range and on to the next (cheap, nothing between pixels lost)
            var line = Path()
            for p in 0..<n {
                let x = CGFloat(p) / CGFloat(n - 1) * w
                let lo = node.shownMin[c * n + p], hi = node.shownMax[c * n + p]
                if p == 0 { line.move(to: CGPoint(x: x, y: y(hi))) } else { line.addLine(to: CGPoint(x: x, y: y(hi))) }
                line.addLine(to: CGPoint(x: x, y: y(lo) + 0.5))
            }
            ctx.stroke(line, with: .color(c == 0 ? Theme.text : Theme.dim), lineWidth: 1)
        }
        // readings
        func reading(_ c: Int) -> String {
            let mean = r[c * 4], lo = r[c * 4 + 1], hi = r[c * 4 + 2], f = r[c * 4 + 3]
            let steady = hi - lo < 0.004              // under 40 mV of movement: a held voltage (pitch, offset)
            var s = (c == 0 ? "A " : "B ") + Self.volts(mean)
            if steady { s += "  " + Self.note(mean) }
            else { s += "  " + String(format: "%.1f…%.1f V", lo * 10, hi * 10) + (f > 0 ? "  " + Self.hz(f) : "") }
            return s
        }
        // one line per channel, so neither runs off the edge
        var lines: [(String, Color)] = []
        if hasA { lines.append((reading(0), Theme.text)) }
        if hasB { lines.append((reading(1), Theme.dim)) }
        if lines.isEmpty { lines = [("patch something into A or B", Theme.dim)] }
        for (k, l) in lines.enumerated() {
            ctx.draw(LiveText(l.0, size: 11, color: l.1), at: CGPoint(x: 2, y: 8 + CGFloat(k) * 15), anchor: .leading)
        }
        let ms = patchNode.params["time"] ?? 20
        let timeText = ms >= 1000 ? String(format: "%.1f s", ms / 1000) : String(format: "%.0f ms", ms)
        ctx.draw(LiveText("±\(full * 10 >= 1 ? String(format: "%g", full * 10) : String(format: "%.2g", full * 10)) V · \(timeText)", size: 11, color: Theme.dim),
                 at: CGPoint(x: w - 2, y: size.height - 5), anchor: .trailing)
    }
}
