import Foundation

// MARK: - filter~

/// filter~ : stereo filter with three models.
///  • svf    — clean zero-delay-feedback state-variable filter
///  • ladder — Moog-style 4-pole transistor ladder (24 dB/oct, saturating, self-oscillates)
///  • ms20   — Sallen-Key-ish screamer: 2-pole with a saturating resonance path
/// Params: 0 mode, 1 cutoff, 2 resonance, 3 cv amount, 4 type
final class FilterNode: DSPNode {
    private var ic1 = [Double](repeating: 0, count: 2), ic2 = [Double](repeating: 0, count: 2)
    private var lad = [Float](repeating: 0, count: 8)      // 4 stages × 2 channels
    private var fc: Double = 1000

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let mode = clampIndex(params[0], 4)
        let target = Double(params[1])
        let res = Double(min(max(params[2], 0), 1))
        let amt = Double(params[3])
        let algo = clampIndex(params[4], 3)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0], cv = inputs[2]
        let hasCV = isConnected(connected, 2)
        let smooth = 1 - exp(-1 / (0.005 * sampleRate))
        let nyq = sampleRate * 0.45
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            fc += (target - fc) * smooth
            var f = fc
            if hasCV { f *= exp2(Double(cv[i]) * 10 * amt) }   // ±1.0 ≈ ±10 V → ±10 octaves × amount
            f = min(max(f, 10), nyq)
            if algo == 1 {
                // ladder
                let g = Float(1 - exp(-2 * Double.pi * f / sampleRate))
                let k = Float(res * 4.1)
                for c in 0..<2 {
                    let x0 = c == 0 ? inL[i] : inR[i]
                    let b = c * 4
                    let x = tanhf(x0 * 1.2 - k * lad[b + 3])
                    lad[b] += g * (x - lad[b])
                    lad[b + 1] += g * (lad[b] - lad[b + 1])
                    lad[b + 2] += g * (lad[b + 1] - lad[b + 2])
                    lad[b + 3] += g * (lad[b + 2] - lad[b + 3])
                    let comp = 1 + k * 0.35            // keep the bass when resonance is up
                    let lp = lad[b + 3] * comp, bp = (lad[b + 1] - lad[b + 3]) * 2 * comp
                    let y: Float
                    switch mode {
                    case 0: y = lp
                    case 1: y = bp
                    case 2: y = x - lad[b + 3]
                    default: y = x - bp
                    }
                    if c == 0 { oL[i] = y } else { oR[i] = y }
                }
            } else {
                // svf (clean) or ms20 (saturating resonance, can scream)
                let g = tan(Double.pi * f / sampleRate)
                let k = algo == 2 ? 2 - 2.05 * res : 2 - 1.97 * res
                let a1 = 1 / (1 + g * (g + max(k, 0.02))), a2 = g * a1, a3 = g * a2
                for c in 0..<2 {
                    let v0 = Double(c == 0 ? inL[i] : inR[i]) * (algo == 2 ? 1.5 : 1)
                    let v3 = v0 - ic2[c]
                    let v1 = a1 * ic1[c] + a2 * v3
                    let v2 = ic2[c] + a2 * ic1[c] + a3 * v3
                    if algo == 2 {
                        ic1[c] = 2 * tanh(v1) - ic1[c]
                        ic2[c] = 2 * tanh(v2 * 0.8) / 0.8 - ic2[c]
                    } else {
                        ic1[c] = 2 * v1 - ic1[c]
                        ic2[c] = 2 * v2 - ic2[c]
                    }
                    var y: Double
                    switch mode {
                    case 0: y = v2
                    case 1: y = v1
                    case 2: y = v0 - k * v1 - v2
                    default: y = v0 - k * v1
                    }
                    if algo == 2 { y = Double(softClip(Float(y / 1.5))) }
                    if c == 0 { oL[i] = Float(y) } else { oR[i] = Float(y) }
                }
            }
        }
        for c in 0..<2 where !ic1[c].isFinite || !ic2[c].isFinite { ic1[c] = 0; ic2[c] = 0 }
        for k in 0..<8 where !lad[k].isFinite { lad[k] = 0 }
    }
}

// MARK: - delay~

/// delay~ : stereo delay, free or clock-locked, three characters:
///  • digital — clean repeats
///  • tape    — wow & flutter, saturating record head, repeats lose lows and highs
///  • analog  — bucket-brigade: darker the longer the time, soft clipping, slow chorusy drift
/// Params: 0 sync, 1 division, 2 time, 3 feedback, 4 tone, 5 ping-pong, 6 mix, 7 type
final class DelayNode: DSPNode {
    private let len: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var w = 0
    private var dtime: Double = -1
    private var lpL: Float = 0, lpR: Float = 0
    private var hpL: Float = 0, hpR: Float = 0
    private var wow: Double = 0, flutter: Double = 0, drift: Double = 0
    private var rng = XorShift(seed: 0xDE1A_7E99)
    private var wander: Float = 0

    override init(spec: ModuleSpec, sampleRate: Double) {
        len = Int(sampleRate * 10)
        bufL = .allocate(capacity: len); bufL.initialize(repeating: 0, count: len)
        bufR = .allocate(capacity: len); bufR.initialize(repeating: 0, count: len)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let sync = params[0] > 0.5
        let raw = sync ? ctx.samplesPerBeat * Divisions.beats(params[1]) : Double(params[2]) * sampleRate / 1000
        let target = min(max(raw, 2), Double(len - 4) * 0.98)
        if dtime < 0 { dtime = target }
        let fb = params[3]
        let algo = clampIndex(params[7], 3)
        var tone = Double(params[4])
        if algo == 1 { tone = min(tone, 7000) }
        if algo == 2 {
            // BBD: fewer clock cycles per second at long times → darker
            let ms = dtime / sampleRate * 1000
            tone = min(tone, max(700, 4500 * sqrt(120 / max(ms, 1))))
        }
        let toneC = Float(1 - exp(-2 * Double.pi * tone / sampleRate))
        let hpC = Float(1 - exp(-2 * Double.pi * (algo == 1 ? 140 : 25) / sampleRate))
        let pingPong = params[5] > 0.5
        let mix = params[6]
        let smooth = 1 - exp(-1 / (0.08 * sampleRate))
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        let flen = Double(len)
        let tau = 2 * Double.pi / sampleRate
        for i in 0..<frames {
            dtime += (target - dtime) * smooth
            var d = dtime
            switch algo {
            case 1:
                wow += 0.55 * tau; flutter += 6.8 * tau
                if (i & 63) == 0 { wander += (rng.next() - 0.5) * 0.02; wander *= 0.995 }
                d *= 1 + 0.0022 * sin(wow) + 0.0006 * sin(flutter) + Double(wander) * 0.002
            case 2:
                drift += 0.3 * tau
                d *= 1 + 0.0012 * sin(drift)
            default: break
            }
            d = min(max(d, 2), flen - 4)
            var rp = Double(w) - d
            if rp < 0 { rp += flen }
            let dl = readLinear(bufL, len, rp)
            let dr = readLinear(bufR, len, rp)
            lpL += (dl - lpL) * toneC
            lpR += (dr - lpR) * toneC
            hpL += (lpL - hpL) * hpC
            hpR += (lpR - hpR) * hpC
            let fl = lpL - hpL, fr = lpR - hpR
            let l = inL[i], r = inR[i]
            var wl: Float, wr: Float
            if pingPong { wl = (l + r) * 0.5 + fr * fb; wr = fl * fb }
            else { wl = l + fl * fb; wr = r + fr * fb }
            switch algo {
            case 1: wl = tanhf(wl * 1.3) / 1.3; wr = tanhf(wr * 1.3) / 1.3
            case 2: wl = softClip(wl * 1.1); wr = softClip(wr * 1.1)
            default: wl = softClip(wl); wr = softClip(wr)
            }
            bufL[w] = wl; bufR[w] = wr
            w += 1
            if w >= len { w = 0 }
            oL[i] = l * (1 - mix) + dl * mix
            oR[i] = r * (1 - mix) + dr * mix
        }
        if wow > 2 * .pi { wow -= 2 * .pi }
        if flutter > 2 * .pi { flutter -= 2 * .pi }
        if drift > 2 * .pi { drift -= 2 * .pi }
        readouts[0] = Float(dtime / sampleRate * 1000)
    }
}

// MARK: - drive~

/// drive~ : stereo saturation with six curves.
///  soft (tanh) · tube (asymmetric, even harmonics) · hard clip · fold (wavefolder) · fuzz · rectify (octave-up)
/// Params: 0 drive, 1 tone, 2 mix, 3 output, 4 type
final class DriveNode: DSPNode {
    private var lp = [Float](repeating: 0, count: 2)
    private var dcX = [Float](repeating: 0, count: 2), dcY = [Float](repeating: 0, count: 2)

    @inline(__always) private static func shape(_ algo: Int, _ x: Float) -> Float {
        switch algo {
        case 1: return tanhf(x + 0.25) - tanhf(0.25)                         // tube
        case 2: return min(max(x, -1), 1)                                    // hard
        case 3: return sinf(x * .pi / 2)                                     // fold
        case 4: return x > 0 ? 1 - expf(-x * 1.5) : -0.8 * (1 - expf(x * 2.5))  // fuzz
        case 5: return tanhf(abs(x) * 1.5) * 2 - 1                           // rectify
        default: return tanhf(x)                                             // soft
        }
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let g = dbToGain(params[0])
        let tc = Float(1 - exp(-2 * Double.pi * Double(params[1]) / sampleRate))
        let mix = params[2]
        let outG = dbToGain(params[3])
        let algo = clampIndex(params[4], 6)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            for c in 0..<2 {
                let x = c == 0 ? inL[i] : inR[i]
                var y = Self.shape(algo, x * g)
                // DC blocker (asymmetric curves add offset)
                let d = y - dcX[c] + 0.9975 * dcY[c]; dcX[c] = y; dcY[c] = d; y = d
                lp[c] += (y - lp[c]) * tc
                let o = (x * (1 - mix) + lp[c] * mix) * outG
                if c == 0 { oL[i] = o } else { oR[i] = o }
            }
        }
    }
}

// MARK: - reverb~

private struct Comb {
    let buf: UnsafeMutablePointer<Float>
    let size: Int
    var idx = 0
    var store: Float = 0
    init(_ size: Int) {
        self.size = max(size, 1)
        buf = .allocate(capacity: self.size)
        buf.initialize(repeating: 0, count: self.size)
    }
    @inline(__always) mutating func process(_ x: Float, fb: Float, d1: Float, d2: Float) -> Float {
        let y = buf[idx]
        store = y * d2 + store * d1
        buf[idx] = x + store * fb
        idx += 1
        if idx >= size { idx = 0 }
        return y
    }
}

private struct Allpass {
    let buf: UnsafeMutablePointer<Float>
    let size: Int
    var idx = 0
    init(_ size: Int) {
        self.size = max(size, 1)
        buf = .allocate(capacity: self.size)
        buf.initialize(repeating: 0, count: self.size)
    }
    @inline(__always) mutating func process(_ x: Float) -> Float {
        let b = buf[idx]
        buf[idx] = x + b * 0.5
        idx += 1
        if idx >= size { idx = 0 }
        return b - x
    }
}

/// Lattice allpass on a DelayLine, with tap access (for the plate's output taps) and optional modulation.
private struct APLine {
    var line: DelayLine
    let n: Int
    init(_ n: Int, extra: Int = 0) { self.n = max(n, 2); line = DelayLine(samples: self.n + extra + 4) }
    @inline(__always) mutating func process(_ x: Float, _ g: Float, mod: Double = 0) -> Float {
        let d = line.read(Double(n - 1) + mod)
        let w = x + g * d
        line.write(w)
        return d - g * w
    }
    @inline(__always) func tap(_ k: Int) -> Float { line.read(Double(min(k, n - 1))) }
    func free() { line.free() }
}

/// reverb~ : three algorithms.
///  • room  — Freeverb (8 combs + 4 allpasses per side), bright and dense
///  • plate — Dattorro plate: input diffusers into a modulated figure-eight tank, smooth and lush
///  • hall  — 8-line feedback delay network with Hadamard mixing, long natural decays (RT60 up to ~12 s)
/// All have infinite freeze. Params: 0 size, 1 damping, 2 width, 3 mix, 4 freeze, 5 type
final class ReverbNode: DSPNode {
    private static let combTuning = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let apTuning = [556, 441, 341, 225]
    private let combL: UnsafeMutablePointer<Comb>, combR: UnsafeMutablePointer<Comb>
    private let apL: UnsafeMutablePointer<Allpass>, apR: UnsafeMutablePointer<Allpass>

    // plate
    private var pIn: [APLine]
    private var pApMod1: APLine, pApMod2: APLine, pAp5: APLine, pAp6: APLine
    private var pD1: DelayLine, pD2: DelayLine, pD3: DelayLine, pD4: DelayLine
    private let pLen: [Int]           // d1 d2 d3 d4 in samples
    private let pTaps: [Int]          // 14 output taps
    private var pBW: Float = 0, pDampL: Float = 0, pDampR: Float = 0
    private var pFeedL: Float = 0, pFeedR: Float = 0
    private var pLfo: Double = 0
    private let pScale: Double
    private var pSide: [APLine]                // diffuses the input's side (L − R) so stereo input stays stereo
    /// Input balance (slow): plate and hall tanks blend the two sides completely, so the wet signal is
    /// leaned toward the side the sound comes from. Mono input: no lean, full width.
    private var balEnvL: Float = 0, balEnvR: Float = 0
    @inline(__always) private func lean(_ l: Float, _ r: Float) -> (Float, Float) {
        let c: Float = 1 - expf(-1 / (0.25 * Float(sampleRate)))
        balEnvL += (abs(l) - balEnvL) * c
        balEnvR += (abs(r) - balEnvR) * c
        let sum = balEnvL + balEnvR
        let bal = sum > 1e-6 ? (balEnvL - balEnvR) / sum : 0
        return (1 + 0.5 * bal, 1 - 0.5 * bal)
    }

    // hall
    private var hLines: [DelayLine]
    private let hLen: [Int]
    private var hDamp = [Float](repeating: 0, count: 8)
    private var hDiff: [APLine]
    private var hSide: [APLine]
    private var hLfo: Double = 0
    private var hv = [Float](repeating: 0, count: 8)
    private var hGain = [Float](repeating: 1, count: 8)

    // spring: two springs (L, R), each a feedback delay with a chain of first-order allpasses in the loop
    // (the dispersion that gives the "boing" / drip), a high-pass at the input and a low-pass in the loop
    private static let springStages = 18
    private var sLines: [DelayLine]
    private let sLen: [Int]
    private let sAP: UnsafeMutablePointer<Float>          // 2 springs × stages × (x1, y1)
    private var sLP: (Float, Float) = (0, 0)
    private var sHP: (Float, Float) = (0, 0), sHPx: (Float, Float) = (0, 0)
    private var sChirp: Double = 0

    override init(spec: ModuleSpec, sampleRate: Double) {
        let s = sampleRate / 44100
        combL = .allocate(capacity: 8); combR = .allocate(capacity: 8)
        apL = .allocate(capacity: 4); apR = .allocate(capacity: 4)
        for (i, t) in Self.combTuning.enumerated() {
            (combL + i).initialize(to: Comb(Int(Double(t) * s)))
            (combR + i).initialize(to: Comb(Int(Double(t + 23) * s)))
        }
        for (i, t) in Self.apTuning.enumerated() {
            (apL + i).initialize(to: Allpass(Int(Double(t) * s)))
            (apR + i).initialize(to: Allpass(Int(Double(t + 23) * s)))
        }
        // Dattorro's figures are at 29761 Hz
        let ps = sampleRate / 29761
        pScale = ps
        func sc(_ v: Int) -> Int { Int(Double(v) * ps) }
        pIn = [APLine(sc(142)), APLine(sc(107)), APLine(sc(379)), APLine(sc(277))]
        pApMod1 = APLine(sc(672), extra: sc(32)); pApMod2 = APLine(sc(908), extra: sc(32))
        pAp5 = APLine(sc(1800)); pAp6 = APLine(sc(2656))
        pLen = [sc(4453), sc(3720), sc(4217), sc(3163)]
        pD1 = DelayLine(samples: pLen[0] + 4); pD2 = DelayLine(samples: pLen[1] + 4)
        pD3 = DelayLine(samples: pLen[2] + 4); pD4 = DelayLine(samples: pLen[3] + 4)
        pTaps = [266, 2974, 1913, 1996, 1990, 187, 1066, 353, 3627, 1228, 2673, 2111, 335, 121].map(sc)
        pSide = [APLine(sc(131)), APLine(sc(353))]
        // hall
        let ms: [Double] = [31.7, 37.3, 41.9, 47.3, 53.9, 61.1, 67.9, 73.7]
        hLen = ms.map { Int($0 * 1.35 * sampleRate / 1000) }
        hLines = hLen.map { DelayLine(samples: $0 + Int(0.004 * sampleRate) + 8) }
        hDiff = [APLine(Int(0.0047 * sampleRate)), APLine(Int(0.0113 * sampleRate)), APLine(Int(0.0171 * sampleRate))]
        hSide = [APLine(Int(0.0061 * sampleRate)), APLine(Int(0.0137 * sampleRate))]
        // spring
        sLen = [Int(0.0371 * sampleRate), Int(0.0503 * sampleRate)]
        sLines = sLen.map { DelayLine(samples: $0 + 8) }
        sAP = .allocate(capacity: 2 * Self.springStages * 2)
        sAP.initialize(repeating: 0, count: 2 * Self.springStages * 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        for i in 0..<8 { combL[i].buf.deallocate(); combR[i].buf.deallocate() }
        for i in 0..<4 { apL[i].buf.deallocate(); apR[i].buf.deallocate() }
        combL.deallocate(); combR.deallocate(); apL.deallocate(); apR.deallocate()
        pIn.forEach { $0.free() }
        pSide.forEach { $0.free() }
        [pApMod1, pApMod2, pAp5, pAp6].forEach { $0.free() }
        [pD1, pD2, pD3, pD4].forEach { $0.free() }
        hLines.forEach { $0.free() }
        hDiff.forEach { $0.free() }
        hSide.forEach { $0.free() }
        sLines.forEach { $0.free() }
        sAP.deallocate()
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let algo = clampIndex(params[5], 4)
        let frozen = params[4] > 0.5
        let size = min(max(params[0], 0), 1), dampP = min(max(params[1], 0), 1)
        let mix = params[3]
        let width = params[2]
        let dry = 1 - mix
        let inL = inputs[0]
        let inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]

        switch algo {
        case 1: plate(frames, inL, inR, oL, oR, size: size, damp: dampP, frozen: frozen, mix: mix, width: width, dry: dry)
        case 2: hall(frames, inL, inR, oL, oR, size: size, damp: dampP, frozen: frozen, mix: mix, width: width, dry: dry)
        case 3: spring(frames, inL, inR, oL, oR, size: size, damp: dampP, frozen: frozen, mix: mix, width: width, dry: dry)
        default:
            let fb: Float = frozen ? 1 : size * 0.28 + 0.7
            let damp: Float = frozen ? 0 : dampP * 0.4
            let d1 = damp, d2 = 1 - damp
            let gainIn: Float = frozen ? 0 : 0.015
            let wet = mix * 1.5      // level-matched with plate and hall
            let wet1 = wet * (width / 2 + 0.5), wet2 = wet * ((1 - width) / 2)
            for i in 0..<frames {
                let l = inL[i], r = inR[i]
                // true stereo: each side mostly feeds its own bank (with some blend), so a panned sound
                // keeps its place; a mono sound feeds both equally and the two banks spread it wide
                let xL = (l * 0.72 + r * 0.28) * 2 * gainIn, xR = (r * 0.72 + l * 0.28) * 2 * gainIn
                var sL: Float = 0, sR: Float = 0
                for c in 0..<8 {
                    sL += combL[c].process(xL, fb: fb, d1: d1, d2: d2)
                    sR += combR[c].process(xR, fb: fb, d1: d1, d2: d2)
                }
                for a in 0..<4 {
                    sL = apL[a].process(sL)
                    sR = apR[a].process(sR)
                }
                oL[i] = sL * wet1 + sR * wet2 + l * dry
                oR[i] = sR * wet1 + sL * wet2 + r * dry
            }
        }
    }

    private func plate(_ frames: Int, _ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
                       _ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>,
                       size: Float, damp: Float, frozen: Bool, mix: Float, width: Float, dry: Float) {
        let decay: Float = frozen ? 1 : 0.25 + size * 0.72
        let dampC: Float = frozen ? 1 : 1 - damp * 0.85     // 1 = no damping
        let inGain: Float = frozen ? 0 : 1
        let bw: Float = 0.9995
        let excursion = 8 * pScale
        let lfoInc = 2 * Double.pi * 1.0 / sampleRate
        let wet = mix * 0.9
        let t = pTaps
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            pBW += ((l + r) * 0.5 * inGain - pBW) * bw
            var x = pBW
            x = pIn[0].process(x, 0.75); x = pIn[1].process(x, 0.75)
            x = pIn[2].process(x, 0.625); x = pIn[3].process(x, 0.625)
            var side = (l - r) * 0.5 * inGain
            side = pSide[0].process(side, 0.7); side = pSide[1].process(side, 0.6)
            let xL = x + side, xR = x - side
            pLfo += lfoInc
            if pLfo > 2 * .pi { pLfo -= 2 * .pi }
            let m1 = excursion * (1 + sin(pLfo)) * 0.5, m2 = excursion * (1 + cos(pLfo)) * 0.5
            // left half of the tank
            let a = pApMod1.process(xL + pFeedR, -0.7, mod: m1)
            pD1.write(a)
            pDampL += (pD1.read(Double(pLen[0] - 1)) - pDampL) * dampC
            let c = pAp5.process(pDampL * decay, 0.5)
            pD2.write(c)
            pFeedL = pD2.read(Double(pLen[1] - 1)) * decay
            // right half
            let b = pApMod2.process(xR + pFeedL, -0.7, mod: m2)
            pD3.write(b)
            pDampR += (pD3.read(Double(pLen[2] - 1)) - pDampR) * dampC
            let e = pAp6.process(pDampR * decay, 0.5)
            pD4.write(e)
            pFeedR = pD4.read(Double(pLen[3] - 1)) * decay
            // output taps (Dattorro table)
            let yl = pD3.read(Double(t[0])) + pD3.read(Double(t[1])) - pAp6.tap(t[2]) + pD4.read(Double(t[3]))
                - pD1.read(Double(t[4])) - pAp5.tap(t[5]) - pD2.read(Double(t[6]))
            let yr = pD1.read(Double(t[7])) + pD1.read(Double(t[8])) - pAp5.tap(t[9]) + pD2.read(Double(t[10]))
                - pD3.read(Double(t[11])) - pAp6.tap(t[12]) - pD4.read(Double(t[13]))
            let (gl, gr) = lean(l, r)
            let sl = yl * 0.6 * gl, sr = yr * 0.6 * gr
            let w1 = width / 2 + 0.5, w2 = (1 - width) / 2
            oL[i] = (sl * w1 + sr * w2) * wet + l * dry
            oR[i] = (sr * w1 + sl * w2) * wet + r * dry
        }
        if !pFeedL.isFinite || !pFeedR.isFinite { pFeedL = 0; pFeedR = 0; pDampL = 0; pDampR = 0 }
    }

    private func spring(_ frames: Int, _ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
                        _ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>,
                        size: Float, damp: Float, frozen: Bool, mix: Float, width: Float, dry: Float) {
        let n = Self.springStages
        let g: Float = frozen ? 0.999 : 0.5 + size * 0.42                 // loop gain: decay
        let lpc: Float = 1 - expf(-2 * .pi * (6500 - 4800 * damp) / Float(sampleRate))   // brightness
        let hpc: Float = expf(-2 * .pi * 120 / Float(sampleRate))
        let a: Float = 0.62                                              // dispersion amount
        let inGain: Float = frozen ? 0 : 1
        let wet = mix * 2.6                     // level-matched with room / plate / hall
        let w1 = width / 2 + 0.5, w2 = (1 - width) / 2
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            // a tiny wobble of the loop length, like a real spring moving
            sChirp += 0.6 / sampleRate
            if sChirp > 1 { sChirp -= 1 }
            let wob = 2.0 * Foundation.sin(2 * .pi * sChirp)
            var outs: (Float, Float) = (0, 0)
            for sp in 0..<2 {
                // each spring mostly hears its own side, a little of the other; the two springs differ
                let x = (sp == 0 ? l * 0.75 + r * 0.25 : r * 0.75 + l * 0.25) * inGain
                // input high-pass (springs don't carry the low end)
                let hp: Float
                if sp == 0 { hp = hpc * (sHP.0 + x - sHPx.0); sHP.0 = hp; sHPx.0 = x }
                else { hp = hpc * (sHP.1 + x - sHPx.1); sHP.1 = hp; sHPx.1 = x }
                let v = sLines[sp].read(Double(sLen[sp] - 1) + (sp == 0 ? wob : -wob))
                var u = hp * 0.6 + v * g
                let base = sp * n * 2
                let ak: Float = sp == 0 ? a : a - 0.08          // a slightly different dispersion per spring
                for k in 0..<n {
                    let x1 = sAP[base + 2 * k], y1 = sAP[base + 2 * k + 1]
                    let y = ak * u + x1 - ak * y1
                    sAP[base + 2 * k] = u; sAP[base + 2 * k + 1] = y
                    u = y
                }
                if sp == 0 { sLP.0 += (u - sLP.0) * lpc; sLines[0].write(sLP.0); outs.0 = sLP.0 }
                else { sLP.1 += (u - sLP.1) * lpc; sLines[1].write(sLP.1); outs.1 = sLP.1 }
            }
            oL[i] = (outs.0 * w1 + outs.1 * w2) * wet + l * dry
            oR[i] = (outs.1 * w1 + outs.0 * w2) * wet + r * dry
        }
        if !sLP.0.isFinite || !sLP.1.isFinite {
            sLP = (0, 0); sAP.update(repeating: 0, count: 2 * n * 2)
        }
    }

    private func hall(_ frames: Int, _ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
                      _ oL: UnsafeMutablePointer<Float>, _ oR: UnsafeMutablePointer<Float>,
                      size: Float, damp: Float, frozen: Bool, mix: Float, width: Float, dry: Float) {
        let rt60 = 0.6 * pow(20, Double(size))           // 0.6 s … 12 s
        let dampC: Float = frozen ? 1 : 1 - damp * 0.8
        let inGain: Float = frozen ? 0 : 0.35
        let modDepth = 0.0015 * sampleRate
        let lfoInc = 2 * Double.pi * 0.37 / sampleRate
        let wet = mix * 0.8
        let norm: Float = 1 / sqrtf(8)
        // per-line feedback gain for the requested decay (preallocated: no allocation on the audio thread)
        for k in 0..<8 {
            hGain[k] = frozen ? 1 : Float(pow(10, -3 * Double(hLen[k]) / (rt60 * sampleRate)))
        }
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            var x = (l + r) * 0.5 * inGain
            x = hDiff[0].process(x, 0.6); x = hDiff[1].process(x, 0.6); x = hDiff[2].process(x, 0.5)
            var side = (l - r) * 0.5 * inGain
            side = hSide[0].process(side, 0.6); side = hSide[1].process(side, 0.55)
            let xL = x + side, xR = x - side
            hLfo += lfoInc
            if hLfo > 2 * .pi { hLfo -= 2 * .pi }
            for k in 0..<8 {
                let mod = (k == 1 || k == 6) ? modDepth * (1 + sin(hLfo + Double(k))) : 0
                let y = hLines[k].read(Double(hLen[k] - 1) + mod)
                hDamp[k] += (y - hDamp[k]) * dampC
                hv[k] = hDamp[k]
            }
            let outL = hv[0] - hv[2] + hv[4] - hv[6]
            let outR = hv[1] - hv[3] + hv[5] - hv[7]
            // 8×8 Hadamard (fast Walsh–Hadamard), energy-preserving
            var hh = 1
            while hh < 8 {
                var j = 0
                while j < 8 {
                    for k in j..<(j + hh) {
                        let a = hv[k], b = hv[k + hh]
                        hv[k] = a + b; hv[k + hh] = a - b
                    }
                    j += hh * 2
                }
                hh *= 2
            }
            for k in 0..<8 {
                let sign: Float = (k & 1) == 0 ? 1 : -1
                hLines[k].write(hv[k] * norm * hGain[k] + ((k & 1) == 0 ? xL : xR) * sign)
            }
            let (gl, gr) = lean(l, r)
            let sl = outL * 1.85 * gl, sr = outR * 1.85 * gr     // level-matched with room and plate
            let w1 = width / 2 + 0.5, w2 = (1 - width) / 2
            oL[i] = (sl * w1 + sr * w2) * wet + l * dry
            oR[i] = (sr * w1 + sl * w2) * wet + r * dry
        }
        for k in 0..<8 where !hDamp[k].isFinite { hDamp[k] = 0 }
    }
}
