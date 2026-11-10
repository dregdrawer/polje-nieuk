import Foundation
import MutableDSP

// Second batch of modules built on Emilie Gillet's open-source Eurorack DSP (MIT licence, see Vendor/mutable):
// xmod~ (cross-modulator), slopes~ (4-output function generator), chance~ (random gates and voltages).

// MARK: - xmod~ (cross / meta modulator)

final class XmodNode: DSPNode {
    // 0 algorithm, 1 timbre, 2 level 1, 3 level 2, 4 internal oscillator, 5 frequency
    // inputs: 0 carrier, 1 modulator, 2 pitch (internal oscillator, 0.1 = 1 octave)
    public static let algorithms = ["crossfade", "fold", "analog ring", "digital ring", "xor",
                                    "compare", "vocoder", "chebyshev", "freq shift"]
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MIXmodParams()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_xmod_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_XMOD_RATE), block: Int(MI_XMOD_BLOCK), chIn: 2, chOut: 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_xmod_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let car = inputs[0], mod = inputs[1], pitch = inputs[2]
        let hasCar = isConnected(connected, 0), hasPitch = isConnected(connected, 2)
        // algorithm knob sweeps continuously between the 9 algorithms (0…8 → 0…1)
        q.algorithm = min(max(params[0], 0), 8) / 8
        q.timbre = params[1]
        q.level1 = params[2]; q.level2 = params[3]
        // internal oscillator replaces the carrier when chosen, or when nothing is patched into it
        let osc = clampIndex(params[4], 4)
        q.carrier_shape = Int32(osc == 0 && !hasCar ? 1 : osc)
        q.note = 60 + params[5] + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0)
        let o = outputs[0], aux = outputs[1]
        bridge.run(frames: frames, input: { c, i in c == 0 ? car[i] : mod[i] }, render: {
            mi_xmod_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.outChannel(0), bridge.outChannel(1))
        }, output: { c, i, v in if c == 0 { o[i] = v } else { aux[i] = v } })
    }
}

// MARK: - slopes~ (4-channel function generator)

final class SlopesNode: DSPNode {
    // 0 ramp mode, 1 output mode, 2 range, 3 frequency, 4 slope, 5 shape, 6 smoothness, 7 shift, 8 sync, 9 division
    // inputs: 0 pitch (0.1 = 1 octave), 1 gate/trig
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MISlopesParams()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_slopes_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_SLOPES_RATE), block: Int(MI_SLOPES_BLOCK), chIn: 1, chOut: 4)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_slopes_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let pitch = inputs[0], gate = inputs[1]                   // inputs: 0 pitch, 1 gate
        let hasPitch = isConnected(connected, 0), hasGate = isConnected(connected, 1)
        q.ramp_mode = Int32(clampIndex(params[0], 3))
        q.output_mode = Int32(clampIndex(params[1], 4))
        q.range = Int32(clampIndex(params[2], 3))
        var semis = params[3] + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0)
        // sync: one cycle per clock division, the frequency knob becomes a ±ratio around it
        let sync = params[8] > 0.5 && q.range != 2
        if sync {
            let beats = Divisions.beats(params[9])
            let hz = ctx.sampleRate / max(ctx.samplesPerBeat * beats, 1)
            let root: Double = q.range == 0 ? 0.125 : 2
            semis += Float(12 * log2(max(hz, 1e-6) / root))
        }
        q.frequency = semis
        q.slope = params[4]; q.shape = params[5]; q.smoothness = params[6]; q.shift = params[7]
        q.gate_patched = hasGate ? 1 : 0
        let o0 = outputs[0], o1 = outputs[1], o2 = outputs[2], o3 = outputs[3]
        bridge.run(frames: frames, input: { _, i in hasGate ? gate[i] : 0 }, render: {
            mi_slopes_process(dsp, &q, bridge.inChannel(0), bridge.outChannel(0), bridge.outChannel(1),
                              bridge.outChannel(2), bridge.outChannel(3))
        }, output: { c, i, v in
            switch c { case 0: o0[i] = v; case 1: o1[i] = v; case 2: o2[i] = v; default: o3[i] = v }
        })
        for c in 0..<4 { readouts[c] = outputs[c][frames - 1] }
    }
}

// MARK: - chance~ (random gates T1–T3 and voltages X1–X3, Y)

public enum ChanceNames {
    public static let models = ["coin toss", "clusters", "drums", "independent", "divider", "three states", "markov"]
    public static let scales = ["major", "minor", "pentatonic", "pelog", "bhairav", "shri"]
    public static let lengths = ["1", "2", "3", "4", "5", "6", "7", "8", "10", "12", "14", "16"]
}

final class ChanceNode: DSPNode {
    // 0 t model, 1 t range, 2 rate, 3 bias, 4 jitter, 5 pulse width, 6 déjà vu, 7 length,
    // 8 x mode, 9 x range, 10 scale, 11 spread, 12 x bias, 13 steps, 14 sync, 15 division
    // inputs: 0 t clock, 1 x clock
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MIChanceParams()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_chance_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_CHANCE_RATE), block: Int(MI_CHANCE_BLOCK), chIn: 2, chOut: 7)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_chance_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let tc = inputs[0], xc = inputs[1]
        let hasT = isConnected(connected, 0), hasX = isConnected(connected, 1)
        // sync: without a patched T clock, drive it from the app clock at the chosen division
        let sync = !hasT && params[14] > 0.5
        let div = Divisions.beats(params[15])
        q.t_model = Int32(clampIndex(params[0], ChanceNames.models.count))
        q.t_range = Int32(clampIndex(params[1], 3))
        q.t_rate = params[2]
        q.t_bias = params[3]; q.t_jitter = params[4]; q.t_pulse_width = params[5]
        q.deja_vu = params[6]
        q.deja_vu_length_knob = (Float(clampIndex(params[7], 12)) + 0.5) / 12
        q.x_mode = Int32(clampIndex(params[8], 3))
        q.x_range = Int32(clampIndex(params[9], 3))
        q.x_scale = Int32(clampIndex(params[10], ChanceNames.scales.count))
        q.x_spread = params[11]; q.x_bias = params[12]; q.x_steps = params[13]
        q.t_clock_patched = (hasT || sync) ? 1 : 0
        q.x_clock_patched = hasX ? 1 : 0
        let beat = ctx.beat
        bridge.run(frames: frames, input: { c, i in
            if c == 1 { return xc[i] }
            if hasT { return tc[i] }
            guard sync else { return 0 }
            // high for the first half of each division
            let pos = beat[i] / div
            return pos - pos.rounded(.down) < 0.5 ? 1 : 0
        }, render: {
            mi_chance_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1),
                              bridge.outChannel(0), bridge.outChannel(1), bridge.outChannel(2),
                              bridge.outChannel(3), bridge.outChannel(4), bridge.outChannel(5), bridge.outChannel(6))
        }, output: { c, i, v in outputs[c][i] = v })
        for c in 0..<7 { readouts[c] = outputs[c][frames - 1] }
    }
}

// MARK: - segments~ (chainable ramp / step / hold segments: envelopes, LFOs, sequences)

public enum SegmentsLayout {
    public static let maxSegments = 6
    public static let types = ["ramp", "step", "hold"]
    /// parameter indices of segment k (0-based): type, primary, secondary, loop
    public static func base(_ k: Int) -> Int { 1 + k * 4 }
    public static func count(_ v: Float) -> Int { clampIndex(v, maxSegments) + 1 }
    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.choice("count", "segments", (1...maxSegments).map { "\($0)" }, def: 1)]
        let defTypes = [0, 0, 2, 0, 0, 0]
        let defPrimary: [Float] = [0.25, 0.45, 0.6, 0.4, 0.4, 0.4]
        for k in 1...maxSegments {
            p.append(.choice("t\(k)", "\(k) type", types, def: defTypes[k - 1]))
            p.append(ParamSpec("a\(k)", "\(k) time/level", 0, 1, defPrimary[k - 1], unit: "%"))
            p.append(ParamSpec("b\(k)", "\(k) shape/time", 0, 1, 0.5, unit: "%"))
            p.append(.toggle("l\(k)", "\(k) loop", false))
        }
        return p
    }
}

final class SegmentsNode: DSPNode {
    // 0 count, then per segment: type, primary, secondary, loop
    // inputs: 0 gate   outputs: 0 out
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MISegmentsParams()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_segments_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_SEGMENTS_RATE), block: Int(MI_SEGMENTS_BLOCK), chIn: 1, chOut: 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_segments_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let gate = inputs[0], hasGate = isConnected(connected, 0)
        let n = SegmentsLayout.count(params[0])
        q.count = Int32(n)
        q.gate_patched = hasGate ? 1 : 0
        withUnsafeMutableBytes(of: &q.type) { t in
            let tp = t.bindMemory(to: Int32.self)
            for k in 0..<6 { tp[k] = Int32(clampIndex(params[SegmentsLayout.base(k)], 3)) }
        }
        withUnsafeMutableBytes(of: &q.loop) { l in
            let lp = l.bindMemory(to: Int32.self)
            for k in 0..<6 { lp[k] = params[SegmentsLayout.base(k) + 3] > 0.5 ? 1 : 0 }
        }
        withUnsafeMutableBytes(of: &q.primary) { a in
            let ap = a.bindMemory(to: Float.self)
            for k in 0..<6 { ap[k] = params[SegmentsLayout.base(k) + 1] }
        }
        withUnsafeMutableBytes(of: &q.secondary) { b in
            let bp = b.bindMemory(to: Float.self)
            for k in 0..<6 { bp[k] = params[SegmentsLayout.base(k) + 2] }
        }
        let o = outputs[0]
        var active: Float = 0
        bridge.run(frames: frames, input: { _, i in hasGate ? gate[i] : 0 }, render: {
            mi_segments_process(dsp, &q, bridge.inChannel(0), bridge.outChannel(0), bridge.outChannel(1))
            active = bridge.outChannel(1)[Int(MI_SEGMENTS_BLOCK) - 1]
        }, output: { c, i, v in if c == 0 { o[i] = v } })
        readouts[0] = o[frames - 1]
        readouts[1] = active
    }
}

// MARK: - shapes~ (macro oscillator, 47 shapes)

public enum ShapesNames {
    public static let names = ["csaw", "morph", "saw/square", "sine/triangle", "buzz", "square sub", "saw sub",
                               "square sync", "saw sync", "triple saw", "triple square", "triple triangle",
                               "triple sine", "triple ring", "saw swarm", "saw comb", "toy",
                               "lp filter", "peak filter", "bp filter", "hp filter", "vosim", "vowel", "vowel fof",
                               "harmonics", "fm", "feedback fm", "chaotic fm",
                               "plucked", "bowed", "blown", "fluted", "bell", "drum", "kick", "cymbal", "snare",
                               "wavetables", "wave map", "wave line", "paraphonic",
                               "filtered noise", "twin peaks", "clocked noise", "granular cloud", "particle noise",
                               "digital mod"]
}

final class ShapesNode: DSPNode {
    // 0 shape, 1 note, 2 timbre, 3 colour, 4 decay (0 = drone), 5 level, 6 attack
    // inputs: 0 pitch (0.1 = 1 octave), 1 trig
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MIShapesParams()
    private var env: Float = 1
    private var rising = false

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_shapes_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_SHAPES_RATE), block: Int(MI_SHAPES_BLOCK), chIn: 1, chOut: 1)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_shapes_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let pitch = inputs[0], tr = inputs[1]                     // inputs: 0 pitch, 1 trig
        let hasPitch = isConnected(connected, 0), hasTrig = isConnected(connected, 1)
        q.shape = Int32(clampIndex(params[0], ShapesNames.names.count))
        q.note = 60 + params[1] + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0)
        q.timbre = params[2]; q.color = params[3]
        let decayMs = params[4], level = params[5], attackMs = params[6]
        // the envelope needs a trigger: with nothing in trig it's a drone whatever decay says
        let decays = decayMs > 0.5
        let useEnv = hasTrig && (decays || attackMs > 0.5)
        let mul = decays ? expf(logf(1e-3) / max(decayMs * 0.001 * Float(sampleRate), 1)) : 1
        let rise: Float = attackMs > 0.5 ? 1 / max(attackMs * 0.001 * Float(sampleRate), 1) : 1
        let o = outputs[0]
        bridge.run(frames: frames, input: { _, i in hasTrig ? tr[i] : 0 }, render: {
            var mx: Float = 0
            let t = bridge.inChannel(0)
            for k in 0..<bridge.block { mx = max(mx, t[k]) }
            q.strike = mx > 0.2 && !strikeHeld ? 1 : 0
            strikeHeld = mx > 0.2
            mi_shapes_process(dsp, &q, bridge.outChannel(0))
        }, output: { _, i, v in
            if hasTrig && trigEdge.rising(tr[i]) {
                // attack: fade in from silence; without one the note starts at full level
                if rise < 1 { env = 0; rising = true } else { env = 1; rising = false }
            }
            let g: Float = useEnv ? env : 1
            o[i] = v * g * level
            if useEnv {
                if rising { env += rise; if env >= 1 { env = 1; rising = false } }
                else { env *= mul }                      // decay (mul = 1: drone — hold)
            }
        })
    }
    private var strikeHeld = false
    private var trigEdge = EdgeDetector()
}

// MARK: - haze~ (granular / delay texture with four "media")

final class HazeNode: DSPNode {
    // 0 media, 1 time, 2 size, 3 shape, 4 pitch, 5–8 time/size/shape/pitch randomness, 9 density,
    // 10 feedback, 11 dry/wet, 12 reverb, 13 freeze
    // inputs: 0 L, 1 R, 2 seed, 3 freeze
    private let dsp: OpaquePointer
    private let bridges: [RateBridge]          // one per native rate: 24, 48, 32 kHz
    private var q = MIHazeParams()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_haze_create()!
        bridges = [0, 1, 2].map { m in
            RateBridge(hostRate: sampleRate, nativeRate: Double(mi_haze_rate(Int32(m))), block: Int(mi_haze_block(Int32(m))), chIn: 4, chOut: 2)
        }
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_haze_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let seed = inputs[2], frz = inputs[3]
        let hasSeed = isConnected(connected, 2), hasFrz = isConnected(connected, 3)
        let media = clampIndex(params[0], 4)
        q.media = Int32(media)
        q.time = params[1]; q.size = params[2]; q.shape = params[3]; q.pitch = params[4]
        q.time_rand = params[5]; q.size_rand = params[6]; q.shape_rand = params[7]; q.pitch_rand = params[8]
        q.density = params[9]; q.feedback = params[10]; q.dry_wet = params[11]; q.reverb = params[12]
        q.seed_patched = hasSeed ? 1 : 0
        q.seed_clock = params[14] > 0.5 ? 1 : 0
        let frozen: Float = params[13] > 0.5 ? 1 : 0
        let bridge = bridges[media == 3 ? 1 : media]
        let n = Int32(bridge.block)
        let oL = outputs[0], oR = outputs[1]
        bridge.run(frames: frames, input: { c, i in
            switch c {
            case 0: return inL[i]
            case 1: return inR[i]
            case 2: return hasSeed ? seed[i] : 0
            default: return max(frozen, hasFrz ? frz[i] : 0)
            }
        }, render: {
            mi_haze_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.inChannel(2), bridge.inChannel(3),
                            bridge.outChannel(0), bridge.outChannel(1), n)
        }, output: { c, i, v in if c == 0 { oL[i] = v } else { oR[i] = v } })
    }
}
