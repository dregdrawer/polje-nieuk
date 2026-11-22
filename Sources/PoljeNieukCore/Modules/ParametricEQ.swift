import Foundation

/// eq : parametric EQ with 3, 5 or 8 bands. First band is a low shelf, last a high shelf,
/// the rest are peaking bells (RBJ biquads). Parameter layout:
/// 0 bands (3/5/8), 1 output gain, then per band b: 2+3b freq, 3+3b gain, 4+3b Q.
public enum ParametricEQ {
    public static let bandChoices = [3, 5, 8]
    public static let maxBands = 8

    public static func bandCount(_ choice: Float) -> Int { bandChoices[clampIndex(choice, bandChoices.count)] }
    public static func freqIndex(_ b: Int) -> Int { 2 + 3 * b }
    public static func gainIndex(_ b: Int) -> Int { 3 + 3 * b }
    public static func qIndex(_ b: Int) -> Int { 4 + 3 * b }

    /// Default centre frequencies when switching to `n` bands: spread evenly (log) 80 Hz – 10 kHz.
    public static func defaultFrequencies(_ n: Int) -> [Float] {
        (0..<n).map { k in 80 * powf(10000 / 80, Float(k) / Float(max(n - 1, 1))) }
    }

    public enum Shape { case lowShelf, peak, highShelf }

    public static func shape(_ band: Int, of n: Int) -> Shape {
        band == 0 ? .lowShelf : (band == n - 1 ? .highShelf : .peak)
    }

    /// Normalised biquad coefficients (b0, b1, b2, a1, a2).
    public static func coefficients(_ shape: Shape, freq: Float, gainDB: Float, q: Float, sampleRate: Double)
        -> (Float, Float, Float, Float, Float) {
        let f = Double(min(max(freq, 10), Float(sampleRate * 0.45)))
        let A = pow(10, Double(gainDB) / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * Double(max(q, 0.05)))
        var b0, b1, b2, a0, a1, a2: Double
        switch shape {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s
        }
        return (Float(b0 / a0), Float(b1 / a0), Float(b2 / a0), Float(a1 / a0), Float(a2 / a0))
    }

    /// Total response in dB at `freq` for a parameter array laid out as above (for the curve display).
    public static func responseDB(_ p: (Int) -> Float, freq: Double, sampleRate: Double) -> Double {
        let n = bandCount(p(0))
        var db = Double(p(1))
        let w = 2 * Double.pi * freq / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        for b in 0..<n {
            let (b0, b1, b2, a1, a2) = coefficients(shape(b, of: n), freq: p(freqIndex(b)), gainDB: p(gainIndex(b)),
                                                    q: p(qIndex(b)), sampleRate: sampleRate)
            let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2
            let ni = -(Double(b1) * s1 + Double(b2) * s2)
            let dr = 1 + Double(a1) * c1 + Double(a2) * c2
            let di = -(Double(a1) * s1 + Double(a2) * s2)
            let mag = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
            db += 20 * log10(max(mag, 1e-9))
        }
        return db
    }

    static func params() -> [ParamSpec] {
        var ps: [ParamSpec] = [.choice("bands", "bands", bandChoices.map { "\($0) band" }, def: 0),
                               ParamSpec("out", "output", -24, 24, 0, unit: "dB")]
        let defaults = defaultFrequencies(3) + [2500, 5000, 8000, 12000, 15000]
        for b in 0..<maxBands {
            ps.append(ParamSpec("f\(b + 1)", "\(b + 1) freq", 20, 20000, defaults[b], unit: "Hz", curve: .exponential))
            ps.append(ParamSpec("g\(b + 1)", "\(b + 1) gain", -18, 18, 0, unit: "dB"))
            ps.append(ParamSpec("q\(b + 1)", "\(b + 1) Q", 0.3, 10, b == 0 || b == 2 ? 0.7 : 1, curve: .exponential))
        }
        return ps
    }
}

/// Modules that can feed a spectrum display: they keep the last few thousand output samples in a ring.
public protocol SpectrumSource: AnyObject {
    /// Main thread: copies the most recent `count` samples (oldest first) into `out`.
    func copyRecent(into out: UnsafeMutablePointer<Float>, count: Int)
}
/// eq: what goes in as well as what comes out (the display draws both).
public protocol InputSpectrumSource: AnyObject {
    func copyRecentInput(into out: UnsafeMutablePointer<Float>, count: Int)
}

final class ParametricEQNode: DSPNode, SpectrumSource, InputSpectrumSource {
    static let ringSize = 8192
    private let ring: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: ParametricEQNode.ringSize)
        p.initialize(repeating: 0, count: ParametricEQNode.ringSize)
        return p
    }()
    private var ringW = 0
    /// the input, before the bands (same position as `ring`)
    private let inRing: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: ParametricEQNode.ringSize)
        p.initialize(repeating: 0, count: ParametricEQNode.ringSize)
        return p
    }()
    deinit { ring.deallocate(); inRing.deallocate() }

    func copyRecentInput(into out: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(count, Self.ringSize)
        var r = ringW - n
        if r < 0 { r += Self.ringSize }
        for i in 0..<n {
            out[i] = inRing[r]
            r += 1
            if r >= Self.ringSize { r = 0 }
        }
    }

    func copyRecent(into out: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(count, Self.ringSize)
        var r = ringW - n
        if r < 0 { r += Self.ringSize }
        for i in 0..<n {
            out[i] = ring[r]
            r += 1
            if r >= Self.ringSize { r = 0 }
        }
    }

    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var zL1: Float = 0, zL2: Float = 0, zR1: Float = 0, zR2: Float = 0
    }
    private var bands = [Biquad](repeating: Biquad(), count: ParametricEQ.maxBands)
    private var last = [Float](repeating: .nan, count: 2 + 3 * ParametricEQ.maxBands)

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let n = ParametricEQ.bandCount(params[0])
        // recompute coefficients only when something moved
        var changed = false
        for k in 0..<paramCount where last[k] != params[k] { changed = true; last[k] = params[k] }
        if changed {
            for b in 0..<n {
                let (b0, b1, b2, a1, a2) = ParametricEQ.coefficients(
                    ParametricEQ.shape(b, of: n), freq: params[ParametricEQ.freqIndex(b)],
                    gainDB: params[ParametricEQ.gainIndex(b)], q: params[ParametricEQ.qIndex(b)], sampleRate: sampleRate)
                bands[b].b0 = b0; bands[b].b1 = b1; bands[b].b2 = b2; bands[b].a1 = a1; bands[b].a2 = a2
            }
        }
        let g = dbToGain(params[1])
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            var l = inL[i], r = inR[i]
            inRing[ringW] = (l + r) * 0.5                 // pre-EQ mono feed for the analyzer
            for b in 0..<n {
                let q = bands[b]
                let yl = q.b0 * l + q.zL1
                bands[b].zL1 = q.b1 * l - q.a1 * yl + q.zL2
                bands[b].zL2 = q.b2 * l - q.a2 * yl
                let yr = q.b0 * r + q.zR1
                bands[b].zR1 = q.b1 * r - q.a1 * yr + q.zR2
                bands[b].zR2 = q.b2 * r - q.a2 * yr
                l = yl; r = yr
            }
            oL[i] = l * g
            oR[i] = r * g
            ring[ringW] = (l + r) * 0.5 * g       // post-EQ mono feed for the analyzer
            ringW += 1
            if ringW >= Self.ringSize { ringW = 0 }
        }
        for b in 0..<n where !(bands[b].zL1.isFinite && bands[b].zR1.isFinite) {
            bands[b].zL1 = 0; bands[b].zL2 = 0; bands[b].zR1 = 0; bands[b].zR2 = 0
        }
    }
}
