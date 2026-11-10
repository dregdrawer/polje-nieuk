import SwiftUI
import Accelerate
import QuartzCore
import PoljeNieukCore

/// Peak overview cache so we only rescan audio when it changed.
final class WaveCache {
    var version = -1, length = -1, width = -1
    var peaks: [Float] = []
}

/// Waveform of a looper/sampler/stretch buffer with playheads, slice markers and a selectable region.
/// Drag = select the section to loop/play (sets start/end). Double-tap = whole buffer.
/// Tap on a sampler = audition the slice under your finger.
struct WaveformView: View {
    let node: DSPNode
    let buffer: SampleBufferNode
    @ObservedObject var model: AppModel
    let patchNode: PatchNode
    let spec: ModuleSpec
    @State private var cache = WaveCache()
    @State private var dragFrom: CGFloat?

    private var startIndex: Int? { spec.paramIndex("start") }
    private var endIndex: Int? { spec.paramIndex("end") }
    private var gridIndex: Int? { spec.paramIndex("grid") }

    /// Grid spacing as a fraction of the buffer (nil = grid off / unknown).
    private func gridStep() -> Double? {
        guard let gi = gridIndex else { return nil }
        let beats = SamplerNode.gridBeats[min(max(Int(node.params[gi].rounded()), 0), SamplerNode.gridBeats.count - 1)]
        let bs = Double(node.readouts[kBeatSamplesSlot])
        let len = Double(buffer.waveLength)
        guard beats > 0, bs.isFinite, bs > 1, len > 0 else { return nil }
        let step = beats * bs / len
        return step > 0.002 ? step : nil
    }

    private func snap(_ x: Double) -> Double {
        guard let g = gridStep() else { return x }
        return min(max((x / g).rounded() * g, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            LiveCanvas { ctx, size in draw(ctx, size) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        let w = max(geo.size.width, 1)
                        if dragFrom == nil { dragFrom = v.startLocation.x }
                        var a = Double(min(max(min(dragFrom ?? 0, v.location.x) / w, 0), 1))
                        var b = Double(min(max(max(dragFrom ?? 0, v.location.x) / w, 0), 1))
                        a = snap(a); b = snap(b)
                        if b <= a, let g = gridStep() { b = min(a + g, 1) }
                        if let s = startIndex, let e = endIndex {
                            model.setParam(patchNode.id, s, Float(a))
                            model.setParam(patchNode.id, e, Float(b))
                        }
                    }
                    .onEnded { _ in dragFrom = nil }
            )
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in
                    if let s = startIndex, let e = endIndex {
                        model.setParam(patchNode.id, s, 0)
                        model.setParam(patchNode.id, e, 1)
                    }
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                    model.audition(patchNode.id, at: Double(v.location.x / max(geo.size.width, 1)))
                })
            )
        }
    }

    private func peaks(width: Int) -> [Float] {
        let len = buffer.waveLength, ver = buffer.contentVersion
        if cache.version == ver && cache.length == len && cache.width == width { return cache.peaks }
        var p = [Float](repeating: 0, count: max(width, 1))
        if len > 0 && width > 0 {
            let buf = buffer.waveBuffer, bufR = buffer.waveBufferR
            // while recording, scale to what's been captured so far (min 2 s so it grows from the left)
            let span = buffer.waveRecording ? max(len, Int(model.host.sampleRate * 2)) : len
            for x in 0..<width {
                let a = x * span / width, b = min((x + 1) * span / width, len)
                guard a < b else { continue }
                let stride = max(1, (b - a) / 48)
                var m: Float = 0
                var i = a
                while i < b { m = max(m, abs(buf[i]), abs(bufR[i])); i += stride }
                p[x] = m.isFinite ? min(m, 1) : 0
            }
        }
        cache.version = ver; cache.length = len; cache.width = width; cache.peaks = p
        return p
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height, mid = h / 2
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        let rec = buffer.waveRecording && node.readouts[0] != 4   // looper overdub (4) keeps white
        let p = peaks(width: Int(w))
        var wave = Path()
        for (x, v) in p.enumerated() where v > 0.0005 {
            let a = CGFloat(min(sqrt(v), 1)) * (mid - 1)        // sqrt = more visible quiet detail
            wave.addRect(CGRect(x: CGFloat(x), y: mid - a, width: 1, height: max(a * 2, 1)))
        }
        ctx.fill(wave, with: .color(rec ? Theme.rec : Theme.text.opacity(0.75)))
        ctx.fill(Path(CGRect(x: 0, y: mid, width: w, height: 0.5)), with: .color(Theme.faint))

        let len = buffer.waveLength
        guard len > 0, !buffer.waveRecording else { return }
        // beat grid
        if let g = gridStep() {
            var x = 0.0
            var k = 0
            while x <= 1.0001 && k < 512 {
                ctx.fill(Path(CGRect(x: CGFloat(x) * w, y: 0, width: 0.5, height: h)), with: .color(Theme.faint))
                x += g; k += 1
            }
        }
        // slice markers
        for k in 0..<buffer.markerCount {
            let x = CGFloat(buffer.marker(k)) / CGFloat(len) * w
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: h)), with: .color(Theme.dim.opacity(0.8)))
        }
        // region: dim what's outside the selection
        if let s = startIndex, let e = endIndex {
            var a = CGFloat(min(max(node.params[s], 0), 1)), b = CGFloat(min(max(node.params[e], 0), 1))
            if b < a { swap(&a, &b) }
            if a > 0.001 || b < 0.999 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: a * w, height: h)), with: .color(.black.opacity(0.6)))
                ctx.fill(Path(CGRect(x: b * w, y: 0, width: (1 - b) * w, height: h)), with: .color(.black.opacity(0.6)))
                ctx.fill(Path(CGRect(x: a * w, y: 0, width: 1, height: h)), with: .color(Theme.text))
                ctx.fill(Path(CGRect(x: b * w - 1, y: 0, width: 1, height: h)), with: .color(Theme.text))
            }
        }
        // playheads
        for k in 0..<8 {
            let v = node.readouts[kPlayheadSlot + k]
            guard v.isFinite, v >= 0, v <= 1 else { continue }
            ctx.fill(Path(CGRect(x: CGFloat(v) * w, y: 0, width: 1.5, height: h)), with: .color(Theme.text))
        }
    }
}

/// FFT spectrum of a SpectrumSource, smoothed like a hardware analyser (fast rise, slow fall).
final class SpectrumAnalyzer {
    static let n = 4096
    private let fft = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
    private var input = [Float](repeating: 0, count: n)
    private var window = [Float](repeating: 0, count: n)
    private var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    private var mags = [Float](repeating: 0, count: n / 2)
    /// Smoothed level in dB per FFT bin.
    private(set) var db = [Float](repeating: -120, count: n / 2)

    init() { vDSP_hann_window(&window, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM)) }

    private var last: CFTimeInterval = 0
    /// The display redraws at up to 120 Hz; the FFT only needs ~30.
    func updateIfDue(from src: SpectrumSource) {
        let now = CACurrentMediaTime()
        guard now - last >= 1.0 / 30 else { return }
        last = now
        update(from: src)
    }
    deinit { vDSP_destroy_fftsetup(fft) }

    func update(from src: SpectrumSource) {
        input.withUnsafeMutableBufferPointer { src.copyRecent(into: $0.baseAddress!, count: Self.n) }
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(Self.n))
        let half = Self.n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, 12, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // magnitude → dB (Hann + zrip scaling ≈ n/2), then rise fast / fall slowly
        let scale: Float = 4 / Float(Self.n)
        for k in 1..<half {
            let v = 20 * log10f(max(mags[k] * scale, 1e-7))
            db[k] = v > db[k] ? v : db[k] - 1.2
        }
    }
}

/// eq~ display: live spectrum (when something is patched in), the response curve, and band points
/// you can drag with a finger, mouse or Apple Pencil — left/right = frequency, up/down = gain.
/// Double-tap a point to flatten that band.
struct EQCurveView: View {
    let node: DSPNode
    let sampleRate: Double
    @ObservedObject var model: AppModel
    let patchNode: PatchNode
    let spec: ModuleSpec
    @State private var analyzer = SpectrumAnalyzer()
    @State private var dragBand: Int?

    private static let fLo = 20.0, fHi = 20000.0, range: Double = 18

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(max(f, Self.fLo) / Self.fLo) / log(Self.fHi / Self.fLo)) * w }
    private func f(_ x: CGFloat, _ w: CGFloat) -> Double { Self.fLo * pow(Self.fHi / Self.fLo, Double(min(max(x / max(w, 1), 0), 1))) }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(max(min(db, Self.range), -Self.range) / Self.range) * (h / 2 - 4) }
    private func gain(_ y: CGFloat, _ h: CGFloat) -> Double { Double((h / 2 - y) / (h / 2 - 4)) * Self.range }

    private var connected: Bool { model.isPortConnected(patchNode.id, port: 0, output: false) || model.isPortConnected(patchNode.id, port: 1, output: false) }

    /// Band point positions (canvas-local) for hit-testing drags.
    private func bandPoints(_ size: CGSize) -> [(Int, CGPoint)] {
        let p = node.base
        let n = ParametricEQ.bandCount(p[0])
        return (0..<n).map { b in
            let fr = Double(p[ParametricEQ.freqIndex(b)])
            return (b, CGPoint(x: x(fr, size.width), y: y(Double(p[ParametricEQ.gainIndex(b)]), size.height)))
        }
    }

    var body: some View {
        GeometryReader { geo in
            LiveCanvas { ctx, size in draw(ctx, size) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragBand == nil {
                            // grab the nearest band point (generous radius for fingers)
                            let near = bandPoints(geo.size).min { hypot($0.1.x - v.startLocation.x, $0.1.y - v.startLocation.y) < hypot($1.1.x - v.startLocation.x, $1.1.y - v.startLocation.y) }
                            guard let (b, pt) = near, hypot(pt.x - v.startLocation.x, pt.y - v.startLocation.y) < 30 else { return }
                            dragBand = b
                        }
                        guard let b = dragBand else { return }
                        model.setParam(patchNode.id, ParametricEQ.freqIndex(b), Float(f(v.location.x, geo.size.width)))
                        let g = min(max(gain(v.location.y, geo.size.height), -Self.range), Self.range)
                        model.setParam(patchNode.id, ParametricEQ.gainIndex(b), Float(abs(g) < 0.4 ? 0 : g))   // gentle snap to 0 dB
                    }
                    .onEnded { _ in dragBand = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    let near = bandPoints(geo.size).min { hypot($0.1.x - v.location.x, $0.1.y - v.location.y) < hypot($1.1.x - v.location.x, $1.1.y - v.location.y) }
                    if let (b, pt) = near, hypot(pt.x - v.location.x, pt.y - v.location.y) < 30 {
                        model.setParam(patchNode.id, ParametricEQ.gainIndex(b), 0)
                    }
                }
            )
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        // grid: decades and ±12 dB
        for fr in [100.0, 1000, 10000] {
            ctx.fill(Path(CGRect(x: x(fr, w), y: 0, width: 0.5, height: h)), with: .color(Theme.faint.opacity(0.6)))
        }
        for db in [-12.0, 0, 12] {
            ctx.fill(Path(CGRect(x: 0, y: y(db, h), width: w, height: 0.5)), with: .color(db == 0 ? Theme.dim.opacity(0.7) : Theme.faint.opacity(0.6)))
        }
        // live spectrum (post-EQ), only when something is patched in and audio is running
        if connected && model.isRunning, let src = node as? SpectrumSource {
            analyzer.updateIfDue(from: src)
            let half = SpectrumAnalyzer.n / 2
            let binHz = sampleRate / Double(SpectrumAnalyzer.n)
            var spec = Path()
            spec.move(to: CGPoint(x: 0, y: h))
            var col = 0
            while col <= Int(w) {
                // max of the bins under this pixel column
                let f0 = f(CGFloat(col), w), f1 = f(CGFloat(col + 1), w)
                let k0 = max(1, Int(f0 / binHz)), k1 = min(half - 1, max(k0, Int(f1 / binHz)))
                var m: Float = -120
                for k in k0...k1 { m = max(m, analyzer.db[k]) }
                // -90…0 dBFS mapped to the full height
                let yy = h - CGFloat(min(max((m + 90) / 90, 0), 1)) * h
                spec.addLine(to: CGPoint(x: CGFloat(col), y: yy))
                col += 2
            }
            spec.addLine(to: CGPoint(x: w, y: h))
            spec.closeSubpath()
            ctx.fill(spec, with: .color(Theme.text.opacity(0.13)))
            ctx.stroke(spec, with: .color(Theme.text.opacity(0.25)), lineWidth: 0.6)
        }
        // response curve
        let p = node.params
        var path = Path()
        let steps = Int(w)
        for i in 0...steps {
            let fr = f(CGFloat(i), w)
            let db = ParametricEQ.responseDB({ p[$0] }, freq: fr, sampleRate: sampleRate)
            let pt = CGPoint(x: CGFloat(i), y: y(db.isFinite ? db : 0, h))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(Theme.text), lineWidth: 1.4)
        // band points
        for (b, pt) in bandPoints(size) {
            let r: CGFloat = dragBand == b ? 7 : 5
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                     with: .color(dragBand == b ? Theme.text : Theme.box))
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                       with: .color(Theme.text), lineWidth: 1.2)
            ctx.draw(Text("\(b + 1)").font(Theme.monoSmall).foregroundColor(Theme.dim),
                     at: CGPoint(x: min(max(pt.x, 8), w - 8), y: pt.y < h / 2 ? pt.y + 13 : pt.y - 13))
        }
        if let b = dragBand {
            let fr = Double(node.base[ParametricEQ.freqIndex(b)]), g = node.base[ParametricEQ.gainIndex(b)]
            let label = String(format: fr >= 1000 ? "%.1fk Hz  %+.1f dB" : "%.0f Hz  %+.1f dB", fr >= 1000 ? fr / 1000 : fr, g)
            ctx.draw(Text(label).font(Theme.monoSmall).foregroundColor(Theme.text), at: CGPoint(x: w / 2, y: 9))
        }
    }
}
