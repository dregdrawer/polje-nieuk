import Foundation

/// Simple circular delay line used by the modulation effects.
struct DelayLine {
    let buf: UnsafeMutablePointer<Float>
    let len: Int
    var w = 0
    init(samples: Int) {
        len = max(samples, 4)
        buf = .allocate(capacity: len)
        buf.initialize(repeating: 0, count: len)
    }
    func free() { buf.deallocate() }
    @inline(__always) mutating func write(_ x: Float) {
        buf[w] = x
        w += 1
        if w >= len { w = 0 }
    }
    /// Read `d` samples behind the most recent write.
    @inline(__always) func read(_ d: Double) -> Float {
        var p = Double(w - 1) - d
        if p < 0 { p += Double(len) }
        if p < 0 { p = 0 }
        return readLinear(buf, len, p)
    }
}

/// chorus : three characters.
///  • chorus   — one modulated voice per side, classic
///  • ensemble — three voices per side, slow + fast LFOs 120° apart (string-machine shimmer)
///  • vibrato  — wet only: pure pitch wobble
/// Params: 0 rate, 1 depth, 2 delay, 3 feedback, 4 width, 5 mix, 6 type
final class ChorusNode: DSPNode {
    private var dl: DelayLine, dr: DelayLine
    private var phase: Double = 0, phase2: Double = 0
    override init(spec: ModuleSpec, sampleRate: Double) {
        dl = DelayLine(samples: Int(sampleRate * 0.1)); dr = DelayLine(samples: Int(sampleRate * 0.1))
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { dl.free(); dr.free() }
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let algo = clampIndex(params[6], 3)
        let rate = Double(params[0]), depth = Double(params[1]) * 0.005 * sampleRate
        let base = Double(params[2]) * 0.001 * sampleRate
        let fb = params[3], width = params[4]
        let mix: Float = algo == 2 ? 1 : params[5]
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            phase += rate / sampleRate
            if phase >= 1 { phase -= 1 }
            phase2 += rate * 6.3 / sampleRate
            if phase2 >= 1 { phase2 -= 1 }
            var yl: Float = 0, yr: Float = 0
            if algo == 1 {
                // three taps per side, slow + fast modulation, 120° apart
                for v in 0..<3 {
                    let o = Double(v) / 3
                    let mL = 0.8 * Double(lfoShape(0, phase + o)) + 0.2 * Double(lfoShape(0, phase2 + o))
                    let mR = 0.8 * Double(lfoShape(0, phase + o + 0.5 * Double(width))) + 0.2 * Double(lfoShape(0, phase2 + o + 0.25))
                    yl += dl.read(base + depth * (mL + 1) * 0.5) / 3 * 1.6
                    yr += dr.read(base + depth * (mR + 1) * 0.5) / 3 * 1.6
                }
            } else {
                let mL = Double(lfoShape(0, phase)), mR = Double(lfoShape(0, phase + 0.25 + 0.25 * Double(width)))
                yl = dl.read(base + depth * (mL + 1) * 0.5)
                yr = dr.read(base + depth * (mR + 1) * 0.5)
            }
            let l = inL[i], r = inR[i]
            dl.write(softClip(l + yl * fb))
            dr.write(softClip(r + yr * fb))
            let wl = yl * (0.5 + 0.5 * width) + yr * (0.5 - 0.5 * width)
            let wr = yr * (0.5 + 0.5 * width) + yl * (0.5 - 0.5 * width)
            oL[i] = l * (1 - mix) + wl * mix
            oR[i] = r * (1 - mix) + wr * mix
        }
    }
}

/// phaser : phaser (allpass stages) or flanger, free or clock-synced.
final class PhaserNode: DSPNode {
    // 0 mode, 1 rate, 2 sync, 3 division, 4 depth, 5 freq, 6 feedback, 7 stages, 8 mix
    private var apL = [Float](repeating: 0, count: 12), apR = [Float](repeating: 0, count: 12)
    private var fbL: Float = 0, fbR: Float = 0
    private var dl: DelayLine, dr: DelayLine
    private var clock = PhaseClock()
    override init(spec: ModuleSpec, sampleRate: Double) {
        dl = DelayLine(samples: Int(sampleRate * 0.03)); dr = DelayLine(samples: Int(sampleRate * 0.03))
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { dl.free(); dr.free() }
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let flanger = params[0] > 0.5
        let sync = params[2] > 0.5, hz = Double(params[1]), div = Divisions.beats(params[3])
        let depth = params[4], center = params[5], fb = params[6], mix = params[8]
        let stages = clampIndex(params[7], 13) < 1 ? 1 : clampIndex(params[7], 13)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        let sr = Float(sampleRate)
        for i in 0..<frames {
            let p = clock.advance(sync: sync, hz: hz, divBeats: div, beat: ctx.beat[i], sampleRate: sampleRate)
            let mL = lfoShape(1, p), mR = lfoShape(1, p + 0.25)
            let l = inL[i], r = inR[i]
            var yl: Float, yr: Float
            if flanger {
                let dms = 1000 / center
                let dL = Double(dms * (1 + 0.9 * depth * mL) * 0.001 * sr)
                let dR = Double(dms * (1 + 0.9 * depth * mR) * 0.001 * sr)
                yl = dl.read(max(dL, 1)); yr = dr.read(max(dR, 1))
                dl.write(softClip(l + yl * fb)); dr.write(softClip(r + yr * fb))
            } else {
                let fL = min(center * exp2f(mL * depth * 2.5), sr * 0.45)
                let fR = min(center * exp2f(mR * depth * 2.5), sr * 0.45)
                let tL = tanf(.pi * fL / sr), tR = tanf(.pi * fR / sr)
                let aL = (tL - 1) / (tL + 1), aR = (tR - 1) / (tR + 1)
                var xl = l + fbL * fb, xr = r + fbR * fb
                for s in 0..<stages {
                    let y1 = aL * xl + apL[s]; apL[s] = xl - aL * y1; xl = y1
                    let y2 = aR * xr + apR[s]; apR[s] = xr - aR * y2; xr = y2
                }
                fbL = softClip(xl); fbR = softClip(xr)
                yl = xl; yr = xr
            }
            oL[i] = l * (1 - mix * 0.5) + yl * mix * 0.5
            oR[i] = r * (1 - mix * 0.5) + yr * mix * 0.5
        }
    }
}

/// redux : bit and sample-rate reduction.
final class ReduxNode: DSPNode {
    // 0 bits, 1 rate, 2 mix
    private var phase: Float = 1
    private var hl: Float = 0, hr: Float = 0
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let q = powf(2, params[0] - 1)
        let step = params[1] / Float(sampleRate)
        let mix = params[2]
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            phase += step
            if phase >= 1 {
                phase -= floor(phase)
                hl = (inL[i] * q).rounded() / q
                hr = (inR[i] * q).rounded() / q
            }
            oL[i] = inL[i] * (1 - mix) + hl * mix
            oR[i] = inR[i] * (1 - mix) + hr * mix
        }
    }
}

/// shift : delay-line pitch shifter (two crossfading taps).
final class ShifterNode: DSPNode {
    // 0 pitch, 1 fine, 2 window, 3 feedback, 4 mix
    private var dl: DelayLine, dr: DelayLine
    private var ph: Double = 0
    override init(spec: ModuleSpec, sampleRate: Double) {
        dl = DelayLine(samples: Int(sampleRate * 0.5)); dr = DelayLine(samples: Int(sampleRate * 0.5))
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { dl.free(); dr.free() }
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let ratio = Double(exp2f((params[0] + params[1] / 100) / 12))
        let win = Double(params[2]) * 0.001 * sampleRate
        let fb = params[3], mix = params[4]
        let inc = (1 - ratio) / win
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        var yl: Float = 0, yr: Float = 0
        for i in 0..<frames {
            ph += inc
            ph -= floor(ph)
            let p2 = ph + 0.5 - floor(ph + 0.5)
            let g1 = sinf(Float.pi * Float(ph)), g2 = sinf(Float.pi * Float(p2))
            yl = dl.read(ph * win + 2) * g1 + dl.read(p2 * win + 2) * g2
            yr = dr.read(ph * win + 2) * g1 + dr.read(p2 * win + 2) * g2
            let l = inL[i], r = inR[i]
            dl.write(softClip(l + yl * fb)); dr.write(softClip(r + yr * fb))
            oL[i] = l * (1 - mix) + yl * mix
            oR[i] = r * (1 - mix) + yr * mix
        }
    }
}

/// autopan : tremolo / auto-pan, free or clock-synced.
final class AutoPanNode: DSPNode {
    // 0 rate, 1 sync, 2 division, 3 amount, 4 shape, 5 phase (deg)
    private var clock = PhaseClock()
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let sync = params[1] > 0.5, hz = Double(params[0]), div = Divisions.beats(params[2])
        let amt = params[3], shape = clampIndex(params[4], 4), off = Double(params[5]) / 360
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            let p = clock.advance(sync: sync, hz: hz, divBeats: div, beat: ctx.beat[i], sampleRate: sampleRate)
            let gl = 1 - amt * (0.5 - 0.5 * lfoShape(shape, p))
            let gr = 1 - amt * (0.5 - 0.5 * lfoShape(shape, p + off))
            oL[i] = inL[i] * gl
            oR[i] = inR[i] * gr
        }
    }
}

/// repeat : clock-synced beat repeat (stutter) in the spirit of Ableton's Beat Repeat.
final class BeatRepeatNode: DSPNode {
    // 0 interval, 1 offset (16ths), 2 gate (16ths), 3 grid, 4 chance, 5 decay, 6 mode, 7 hold
    static let intervals: [Double] = [1, 2, 4, 8, 16]
    static let grids: [Double] = [0.125, 0.25, 0.5, 1, 2]
    private let len: Int
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>
    private var w = 0
    private var repeating = false
    private var sliceStart = 0
    private var elapsed = 0
    private var sliceLen = 1
    private var remaining = 0
    private var level: Float = 1
    private var prevBeat: Double = 0
    private var rng = XorShift(seed: 0xBEA7_0001)

    override init(spec: ModuleSpec, sampleRate: Double) {
        len = Int(sampleRate * 8)
        bufL = .allocate(capacity: len); bufL.initialize(repeating: 0, count: len)
        bufR = .allocate(capacity: len); bufR.initialize(repeating: 0, count: len)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    private func start(spb: Double, gridBeats: Double, gateSixteenths: Double, hold: Bool) {
        repeating = true
        sliceStart = w
        elapsed = 0
        sliceLen = max(64, min(safeInt(gridBeats * spb), len / 2))
        remaining = hold ? Int.max : max(64, safeInt(gateSixteenths * 0.25 * spb))
        level = 1
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let interval = Self.intervals[clampIndex(params[0], Self.intervals.count)]
        let offset = Double(params[1]) * 0.25
        let gate = Double(params[2])
        let grid = Self.grids[clampIndex(params[3], Self.grids.count)]
        let chance = params[4], decay = params[5]
        let mode = clampIndex(params[6], 3)
        let holdParam = params[7] > 0.5
        let hasHold = isConnected(connected, 2), holdIn = inputs[2]
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        let spb = ctx.samplesPerBeat
        let fade = 96
        for i in 0..<frames {
            let b = ctx.beat[i]
            let hold = holdParam || (hasHold && holdIn[i] > 0.2)
            let l = inL[i], r = inR[i]
            bufL[w] = l; bufR[w] = r

            if hold && !repeating {
                start(spb: spb, gridBeats: grid, gateSixteenths: gate, hold: true)
            } else if !hold && repeating && remaining == Int.max {
                repeating = false
            } else if !repeating && crossed(prevBeat - offset, b - offset, interval) && b >= offset && rng.next() < chance {
                start(spb: spb, gridBeats: grid, gateSixteenths: gate, hold: false)
            }
            prevBeat = b

            var wl: Float = 0, wr: Float = 0
            if repeating {
                let pos = elapsed % sliceLen
                if pos == 0 && elapsed > 0 { level *= (1 - decay) }
                var idx = sliceStart + pos
                if idx >= len { idx -= len }
                let edge = min(pos, sliceLen - 1 - pos)
                let env = edge < fade ? Float(edge) / Float(fade) : 1
                wl = bufL[idx] * env * level
                wr = bufR[idx] * env * level
                elapsed += 1
                if remaining != Int.max {
                    remaining -= 1
                    if remaining <= 0 { repeating = false }
                }
            }
            switch mode {
            case 0: oL[i] = l + wl; oR[i] = r + wr                                // mix
            case 1: oL[i] = repeating ? wl : l; oR[i] = repeating ? wr : r        // insert
            default: oL[i] = wl; oR[i] = wr                                       // gate
            }
            w += 1
            if w >= len { w = 0 }
        }
        readouts[0] = repeating ? 1 : 0
    }
}
