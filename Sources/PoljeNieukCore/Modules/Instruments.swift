import Foundation
import MutableDSP

// Four instruments built on the open-source Eurorack DSP by Emilie Gillet (MIT licence, see Vendor/mutable).
// Each runs at its own native rate in fixed blocks; RateBridge converts to/from the engine's rate.

/// Streams audio between the host rate and a module's native rate (linear interpolation, with
/// 4th-order low-pass filtering on whichever side is band-limited), calling `render` once per native block.
final class RateBridge {
    let block: Int
    let chIn: Int, chOut: Int
    private let ratio: Double          // native samples per host sample
    private let step: Double           // host samples per native sample
    private let filtered: Bool
    private let inBuf: UnsafeMutablePointer<Float>    // chIn × block (native)
    let outBlock: UnsafeMutablePointer<Float>         // chOut × block (native), filled by render
    private var inCount = 0
    private var pin: Double = 0
    private let prev: UnsafeMutablePointer<Float>
    private let cur: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>     // chOut × cap
    private let cap: Int
    private var written = 0
    private var readPos: Double
    private var aaIn: [SVF], aaIn2: [SVF], aaOut: [SVF], aaOut2: [SVF]

    init(hostRate: Double, nativeRate: Double, block: Int, chIn: Int, chOut: Int) {
        self.block = block; self.chIn = max(chIn, 1); self.chOut = chOut
        ratio = nativeRate / hostRate
        step = hostRate / nativeRate
        filtered = abs(ratio - 1) > 1e-6
        inBuf = .allocate(capacity: self.chIn * block); inBuf.initialize(repeating: 0, count: self.chIn * block)
        outBlock = .allocate(capacity: chOut * block); outBlock.initialize(repeating: 0, count: chOut * block)
        prev = .allocate(capacity: self.chIn); prev.initialize(repeating: 0, count: self.chIn)
        cur = .allocate(capacity: self.chIn); cur.initialize(repeating: 0, count: self.chIn)
        cap = block * 16
        ring = .allocate(capacity: chOut * cap); ring.initialize(repeating: 0, count: chOut * cap)
        readPos = -Double(block + 4)
        // Butterworth-ish 4th order (two SVF stages) at 45 % of the lower Nyquist
        let fc = Float(min(hostRate, nativeRate) * 0.45)
        func make(_ sr: Double, _ k: Float) -> SVF { var f = SVF(); f.set(freq: fc, sampleRate: Float(sr), k: k); return f }
        aaIn = (0..<self.chIn).map { _ in make(hostRate, 1.848) }
        aaIn2 = (0..<self.chIn).map { _ in make(hostRate, 0.765) }
        aaOut = (0..<chOut).map { _ in make(hostRate, 1.848) }
        aaOut2 = (0..<chOut).map { _ in make(hostRate, 0.765) }
    }

    deinit { inBuf.deallocate(); outBlock.deallocate(); prev.deallocate(); cur.deallocate(); ring.deallocate() }

    @inline(__always) func inChannel(_ c: Int) -> UnsafeMutablePointer<Float> { inBuf + c * block }
    @inline(__always) func outChannel(_ c: Int) -> UnsafeMutablePointer<Float> { outBlock + c * block }

    /// Processes `frames` host samples. `input(c, i)` supplies host input; `render()` must fill
    /// `outChannel(c)` from `inChannel(c)`; `output(c, i, v)` receives host output.
    /// Processes `frames` host samples. `input(c, i)` supplies host input; `render()` must fill
    /// `outChannel(c)` from `inChannel(c)` (one native block); `output(c, i, v)` receives host output.
    @inline(__always)
    func run(frames: Int, input: (Int, Int) -> Float, render: () -> Void, output: (Int, Int, Float) -> Void) {
        for i in 0..<frames {
            // ---- host → native: native samples between the previous host sample and this one
            for c in 0..<chIn {
                var x = input(c, i)
                if filtered && ratio < 1 { x = aaIn[c].process(x).low; x = aaIn2[c].process(x).low }
                cur[c] = x
            }
            while pin <= 1 {
                let f = Float(pin)
                for c in 0..<chIn { inBuf[c * block + inCount] = prev[c] + (cur[c] - prev[c]) * f }
                inCount += 1
                pin += step
                if inCount == block {
                    render()
                    for c in 0..<chOut {
                        let src = outChannel(c), dst = ring + c * cap
                        for k in 0..<block { dst[(written + k) % cap] = src[k] }
                    }
                    written += block
                    inCount = 0
                }
            }
            pin -= 1
            for c in 0..<chIn { prev[c] = cur[c] }
            // ---- native → host
            let r = readPos
            for c in 0..<chOut {
                var y: Float = 0
                if r >= 0 {
                    let base = ring + c * cap
                    let i0 = Int(r), f = Float(r - Double(i0))
                    let a = base[i0 % cap], b = base[(i0 + 1) % cap]
                    y = a + (b - a) * f
                }
                if filtered && ratio < 1 { y = aaOut[c].process(y).low; y = aaOut2[c].process(y).low }
                output(c, i, y)
            }
            readPos += ratio
            // keep the reader a safe distance behind the writer (absorbs rounding drift)
            let lag = Double(written) - readPos
            if lag > Double(cap - block * 2) || lag < 2 { readPos = Double(written) - Double(block + 4) }
        }
    }
}

/// 1 V/oct CV (0.1 = 1 octave) to semitones, limited to ±10 V like a real jack.
@inline(__always) func cvSemitones(_ v: Float) -> Float { v.isFinite ? min(max(v, -1), 1) * 120 : 0 }
/// For the self-test: the same conversion every pitch inlet uses.
public func cvSemitonesForTest(_ v: Float) -> Float { cvSemitones(v) }

// MARK: - texture (granular texture processor)

final class TextureNode: DSPNode {
    // 0 mode, 1 position, 2 size, 3 pitch, 4 density, 5 texture, 6 mix, 7 spread, 8 feedback, 9 reverb, 10 freeze, 11 quality
    // inputs: 0 L, 1 R, 2 trig, 3 freeze
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var q = MITextureParams()
    private var trigEdge = EdgeDetector()
    private var trigPending = false
    private var freezeIn = false

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_texture_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_TEXTURE_RATE), block: Int(MI_TEXTURE_BLOCK), chIn: 2, chOut: 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_texture_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let hasTrig = isConnected(connected, 2), hasFrz = isConnected(connected, 3)
        let tr = inputs[2], fz = inputs[3]
        if hasTrig { for i in 0..<frames where trigEdge.rising(tr[i]) { trigPending = true } }
        freezeIn = hasFrz && fz[frames - 1] > 0.2
        q.mode = Int32(clampIndex(params[0], 4))
        q.position = params[1]; q.size = params[2]; q.pitch = params[3]
        q.density = params[4]; q.texture = params[5]; q.dry_wet = params[6]
        q.stereo_spread = params[7]; q.feedback = params[8]; q.reverb = params[9]
        q.freeze = (params[10] > 0.5 || freezeIn) ? 1 : 0
        q.quality = Int32(clampIndex(params[11], 4))
        let oL = outputs[0], oR = outputs[1]
        bridge.run(frames: frames, input: { c, i in c == 0 ? inL[i] : inR[i] }, render: {
            q.trigger = trigPending ? 1 : 0
            trigPending = false
            mi_texture_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1),
                               bridge.outChannel(0), bridge.outChannel(1))
        }, output: { c, i, v in if c == 0 { oL[i] = v } else { oR[i] = v } })
        readouts[0] = Float(q.freeze)
    }
}

// MARK: - resonator (modal / string resonator)

final class ResonatorNode: DSPNode {
    // 0 model, 1 polyphony, 2 note, 3 structure, 4 brightness, 5 damping, 6 position
    // inputs: 0 in, 1 pitch (1 V/oct: 0.1 = 1 octave), 2 strum
    static let polyphonies: [Int32] = [1, 2, 4]
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var p = MIResonatorParams()
    private var strumEdge = EdgeDetector()
    private var strumPending = false

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_resonator_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_RESONATOR_RATE), block: Int(MI_RESONATOR_BLOCK), chIn: 1, chOut: 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_resonator_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        // inputs: 0 in, 1 pitch, 2 strum (pitch before gates/triggers, as everywhere)
        let hasIn = isConnected(connected, 0), hasPitch = isConnected(connected, 1), hasStrum = isConnected(connected, 2)
        let inp = inputs[0], pitch = inputs[1], st = inputs[2]
        if hasStrum { for i in 0..<frames where strumEdge.rising(st[i]) { strumPending = true } }
        p.model = Int32(clampIndex(params[0], 6))
        p.polyphony = Self.polyphonies[clampIndex(params[1], 3)]
        p.tonic = 12 + params[2]
        p.note = hasPitch ? cvSemitones(pitch[frames - 1]) : 0
        p.structure = params[3]; p.brightness = params[4]; p.damping = params[5]; p.position = params[6]
        p.fm = 0
        p.internal_exciter = hasIn ? 0 : 1
        p.internal_strum = hasStrum ? 0 : 1
        p.internal_note = hasPitch ? 0 : 1
        let oL = outputs[0], oR = outputs[1]
        bridge.run(frames: frames, input: { _, i in inp[i] }, render: {
            p.strum = strumPending ? 1 : 0
            strumPending = false
            mi_resonator_process(dsp, &p, bridge.inChannel(0), bridge.outChannel(0), bridge.outChannel(1))
        }, output: { c, i, v in if c == 0 { oL[i] = v } else { oR[i] = v } })
    }
}

// MARK: - macro (macro oscillator, 24 engines)

public enum MacroEngines {
    public static let names = ["va + filter", "phase distortion", "6-op fm 1", "6-op fm 2", "6-op fm 3",
                               "wave terrain", "string machine", "chiptune",
                               "virtual analog", "waveshaper", "2-op fm", "formant/grain", "additive",
                               "wavetable", "chords", "speech", "swarm", "filtered noise", "particles",
                               "inharmonic string", "modal", "kick", "snare", "hi-hat"]
}

final class MacroNode: DSPNode {
    // 0 engine, 1 note, 2 harmonics, 3 timbre, 4 morph, 5 decay, 6 colour, 7 level, 8 attack
    // inputs: 0 pitch (0.1 = 1 octave), 1 trig, 2 level (gate/env into the low-pass gate) —
    //         a chord on the pitch / trig cables plays every note
    static let maxVoices = kMaxVoices
    private final class Voice {
        let dsp: OpaquePointer
        let bridge: RateBridge
        var p = MIMacroParams()
        var atk: Float = 1               // attack fade-in on each trigger (1 = full)
        var trigEdge = EdgeDetector()
        init(_ sr: Double) {
            dsp = mi_macro_create()!
            bridge = RateBridge(hostRate: sr, nativeRate: Double(MI_MACRO_RATE), block: Int(MI_MACRO_BLOCK), chIn: 1, chOut: 2)
        }
        deinit { mi_macro_destroy(dsp) }
    }
    private let voices: [Voice]

    override init(spec: ModuleSpec, sampleRate: Double) {
        voices = (0..<Self.maxVoices).map { _ in Voice(sampleRate) }
        super.init(spec: spec, sampleRate: sampleRate)
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let hasLevel = isConnected(connected, 2), lv = inputs[2]
        let level = params[7], attackMs = params[8]
        let oL = outputs[0], oR = outputs[1]
        oL.update(repeating: 0, count: frames); oR.update(repeating: 0, count: frames)
        let hasPitch = isConnected(connected, 0), hasTrig = isConnected(connected, 1)
        // one voice per note arriving (a chord); a mono cable is one note
        let np = hasPitch ? inVoices[0] : 1, nt = hasTrig ? inVoices[1] : 1
        for v in 0..<max(np, nt) {
            let pitch = voice(inputs[0], min(v, np - 1)), tr = voice(inputs[1], min(v, nt - 1))
            let vc = voices[v]
            vc.p.engine = Int32(clampIndex(params[0], MacroEngines.names.count))
            vc.p.note = 60 + params[1]
            vc.p.harmonics = params[2]; vc.p.timbre = params[3]; vc.p.morph = params[4]
            vc.p.decay = params[5]; vc.p.lpg_colour = params[6]
            vc.p.mod_note = hasPitch ? cvSemitones(pitch[frames - 1]) : 0
            vc.p.trigger_patched = hasTrig ? 1 : 0
            vc.p.level_patched = hasLevel ? 1 : 0
            vc.p.mod_level = hasLevel ? min(max(lv[frames - 1], 0), 1) : 0
            let rise: Float = attackMs > 0.5 && hasTrig ? 1 / max(attackMs * 0.001 * Float(sampleRate), 1) : 1
            if rise >= 1 { vc.atk = 1 }
            // the trigger is fed through the native-rate input stream so short gates aren't missed
            vc.bridge.run(frames: frames, input: { _, i in hasTrig ? tr[i] : 0 }, render: {
                var mx: Float = 0
                let t = vc.bridge.inChannel(0)
                for k in 0..<vc.bridge.block { mx = max(mx, t[k]) }
                vc.p.trigger = mx > 0.2 ? 1 : 0
                mi_macro_process(vc.dsp, &vc.p, vc.bridge.outChannel(0), vc.bridge.outChannel(1))
            }, output: { c, i, y in
                if c == 0 {
                    // attack: each trigger fades the note in (the low-pass gate's decay still shapes the tail)
                    if rise < 1 {
                        if vc.trigEdge.rising(tr[i]) { vc.atk = 0 }
                        vc.atk = min(vc.atk + rise, 1)
                    }
                    oL[i] += y * level * vc.atk
                } else { oR[i] += y * level * vc.atk }
            })
            if v == 0 { readouts[0] = Float(mi_macro_active_engine(vc.dsp)) }
        }
    }
}

// MARK: - modal (bow / blow / strike modal voice)

final class ModalNode: DSPNode {
    // 0 model, 1 note, 2 strength, 3 contour, 4 bow, 5 blow, 6 strike, 7 bow timbre, 8 flow, 9 blow timbre,
    // 10 mallet, 11 strike timbre, 12 geometry, 13 brightness, 14 damping, 15 position, 16 space
    // inputs: 0 pitch, 1 gate, 2 blow in, 3 strike in
    private let dsp: OpaquePointer
    private let bridge: RateBridge
    private var p = MIModalParams()
    private var gateEdge = EdgeDetector()

    override init(spec: ModuleSpec, sampleRate: Double) {
        dsp = mi_modal_create()!
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_MODAL_RATE), block: Int(MI_MODAL_BLOCK), chIn: 3, chOut: 2)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { mi_modal_destroy(dsp) }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        // inputs: 0 pitch, 1 gate, 2 blow in, 3 strike in
        let hasPitch = isConnected(connected, 0), hasGate = isConnected(connected, 1)
        let pitch = inputs[0], gt = inputs[1], blow = inputs[2], strike = inputs[3]
        p.model = Int32(clampIndex(params[0], 3))
        p.note = params[1] + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0)
        p.strength = params[2]; p.envelope_shape = params[3]
        p.bow_level = params[4]; p.blow_level = params[5]; p.strike_level = params[6]
        p.bow_timbre = params[7]; p.blow_meta = params[8]; p.blow_timbre = params[9]
        p.strike_meta = params[10]; p.strike_timbre = params[11]
        p.geometry = params[12]; p.brightness = params[13]; p.damping = params[14]; p.position = params[15]
        p.space = params[16]
        p.modulation = 0
        let oL = outputs[0], oR = outputs[1]
        bridge.run(frames: frames, input: { c, i in
            switch c { case 0: return hasGate ? gt[i] : 0; case 1: return blow[i]; default: return strike[i] }
        }, render: {
            var mx: Float = 0
            let g = bridge.inChannel(0)
            for k in 0..<bridge.block { mx = max(mx, g[k]) }
            p.gate = mx > 0.2 ? 1 : 0
            mi_modal_process(dsp, &p, bridge.inChannel(1), bridge.inChannel(2),
                             bridge.outChannel(0), bridge.outChannel(1))
        }, output: { c, i, v in if c == 0 { oL[i] = v } else { oR[i] = v } })
    }
}

// MARK: - drumsynth (four synthesized drum voices with their own drum roll)

public enum DrumSynthLayout {
    public static let voices = 4
    public static let steps = 32
    /// Per voice: 0 engine, 1 tune, 2 harmonics, 3 timbre, 4 morph, 5 model, 6 attack, 7 decay (envelope),
    /// 8 LPG decay, 9 LPG colour, 10 level, 11 pan, 12 mute, 13 solo
    public static let perVoice = 14
    public static let shown = 12                 // the rows for the selected voice (mute / solo live on the pads)
    public static let globals = 5                // length, division, swing, selected voice, master
    public static func base(_ v: Int) -> Int { globals + v * perVoice }
    public static let names = ["kick", "snare", "hi-hat", "perc"]
    /// Default engine per voice (bass drum, snare, hi-hat, modal "struck" percussion) and base MIDI note.
    public static let engines: [Int] = [21, 22, 23, 20]
    static let baseNotes: [Float] = [36, 50, 66, 60]
    static let defaults: [(h: Float, t: Float, m: Float)] = [(0.5, 0.45, 0.55), (0.5, 0.5, 0.45), (0.5, 0.65, 0.3), (0.6, 0.6, 0.35)]

    /// What a pad is called: the voice name, or the engine's when it's been changed.
    public static func label(_ v: Int, engine: Int) -> String {
        engine == engines[v] ? names[v] : MacroEngines.names[min(max(engine, 0), MacroEngines.names.count - 1)]
    }

    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.integer("len", "length", 1, steps, 16),
                              .choice("div", "division", Divisions.names, def: Divisions.index("1/16")),
                              ParamSpec("swing", "swing", 0, 0.5, 0, unit: "%"),
                              .choice("sel", "voice", names, def: 0),
                              ParamSpec("master", "master", 0, 1.5, 0.9, unit: "%")]
        for (k, n) in names.enumerated() {
            let d = defaults[k]
            p.append(.choice("e\(k + 1)", "\(n) engine", MacroEngines.names, def: engines[k]))
            p.append(ParamSpec("t\(k + 1)", "\(n) tune", -48, 48, 0, unit: "st"))
            p.append(ParamSpec("h\(k + 1)", "\(n) harmonics", 0, 1, d.h, unit: "%"))
            p.append(ParamSpec("b\(k + 1)", "\(n) timbre", 0, 1, d.t, unit: "%"))
            p.append(ParamSpec("o\(k + 1)", "\(n) morph", 0, 1, d.m, unit: "%"))
            p.append(.choice("c\(k + 1)", "\(n) model", ["analog", "synthetic"], def: 0))
            p.append(ParamSpec("a\(k + 1)", "\(n) attack", 0, 200, 0, unit: "ms", curve: .cubic))
            p.append(ParamSpec("d\(k + 1)", "\(n) decay", 10, 4000, 4000, unit: "ms", curve: .exponential))
            p.append(ParamSpec("l\(k + 1)", "\(n) lpg decay", 0, 1, 0.5, unit: "%"))
            p.append(ParamSpec("k\(k + 1)", "\(n) lpg colour", 0, 1, 0.5, unit: "%"))
            p.append(ParamSpec("v\(k + 1)", "\(n) level", 0, 1.5, 0.8, unit: "%"))
            p.append(ParamSpec("p\(k + 1)", "\(n) pan", -1, 1, 0))
            p.append(.toggle("m\(k + 1)", "\(n) mute", false))
            p.append(.toggle("s\(k + 1)", "\(n) solo", false))
        }
        return p
    }
}

public final class DrumSynthNode: DSPNode {
    // inputs: 0 clock, 1 reset   outputs: L, R
    // readouts: 0 playing step, 1…4 each voice's level right now
    public let hits: UnsafeMutablePointer<Float>          // voice * steps + step
    private var dsp: [OpaquePointer] = []
    private let bridge: RateBridge
    private var q = [MIMacroParams](repeating: MIMacroParams(), count: DrumSynthLayout.voices)
    private var gateLeft = [Int](repeating: 0, count: DrumSynthLayout.voices)
    private var pending = [Int](repeating: -1, count: DrumSynthLayout.voices)
    private var level = [Float](repeating: 0, count: DrumSynthLayout.voices)
    private var gl = [Float](repeating: 0, count: DrumSynthLayout.voices)
    private var gr = [Float](repeating: 0, count: DrumSynthLayout.voices)
    private var gm = [Float](repeating: 0, count: DrumSynthLayout.voices)     // a voice on its own outlet (mono)
    private var aux = [Bool](repeating: false, count: DrumSynthLayout.voices)
    private var env = [Float](repeating: 1, count: DrumSynthLayout.voices)
    private var attacking = [Bool](repeating: false, count: DrumSynthLayout.voices)
    private var attackInc = [Float](repeating: 1, count: DrumSynthLayout.voices)
    private var decayMul = [Float](repeating: 1, count: DrumSynthLayout.voices)

    /// A hit on voice `v`: gate the Plaits voice and restart the amplitude envelope.
    @inline(__always) private func start(_ v: Int, _ gate: Int) {
        gateLeft[v] = gate
        env[v] = attackInc[v] >= 1 ? 1 : 0
        attacking[v] = attackInc[v] < 1
    }
    private var step = -1
    private var clock = StepClock()
    private var clockEdge = EdgeDetector(), resetEdge = EdgeDetector()
    private var extCount = -1
    /// UI: voice to play now (tap), -1 = none.
    public var audition = -1

    public override init(spec: ModuleSpec, sampleRate: Double) {
        hits = .allocate(capacity: DrumSynthLayout.voices * DrumSynthLayout.steps)
        hits.initialize(repeating: 0, count: DrumSynthLayout.voices * DrumSynthLayout.steps)
        for (k, v) in Self.starterBeat.enumerated() { hits[k] = v }                    // a starter beat
        bridge = RateBridge(hostRate: sampleRate, nativeRate: Double(MI_MACRO_RATE), block: Int(MI_MACRO_BLOCK),
                            chIn: DrumSynthLayout.voices, chOut: DrumSynthLayout.voices * 2)
        super.init(spec: spec, sampleRate: sampleRate)
        dsp = (0..<DrumSynthLayout.voices).map { _ in mi_macro_create()! }
    }
    deinit {
        hits.deallocate()
        dsp.forEach { mi_macro_destroy($0) }
    }

    static let starterBeat: [Float] = {
        var h = [Float](repeating: 0, count: DrumSynthLayout.voices * DrumSynthLayout.steps)
        for s in [0, 8] { h[0 * DrumSynthLayout.steps + s] = 1 }
        for s in [4, 12] { h[1 * DrumSynthLayout.steps + s] = 1 }
        for s in stride(from: 2, to: 16, by: 4) { h[2 * DrumSynthLayout.steps + s] = 1 }
        return h
    }()
    public override var defaultData: [String: [Float]] { ["hits": Self.starterBeat] }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "hits" else { return }
        let n = DrumSynthLayout.voices * DrumSynthLayout.steps
        for k in 0..<n { hits[k] = k < values.count && values[k].isFinite ? values[k] : 0 }
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let V = DrumSynthLayout.voices
        let len = clampIndex(params[0] - 1, DrumSynthLayout.steps) + 1
        let div = Divisions.beats(params[1])
        let swing = min(max(params[2], 0), 0.5)
        let master = params[4]
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let ck = inputs[0], rs = inputs[1]
        var anySolo = false
        for v in 0..<V where params[DrumSynthLayout.base(v) + 13] > 0.5 { anySolo = true }
        let sr = Float(sampleRate)
        for v in 0..<V {
            let b = DrumSynthLayout.base(v)
            q[v].engine = Int32(clampIndex(params[b], MacroEngines.names.count))
            q[v].note = DrumSynthLayout.baseNotes[v] + min(max(params[b + 1], -48), 48)
            q[v].harmonics = params[b + 2]; q[v].timbre = params[b + 3]; q[v].morph = params[b + 4]
            q[v].decay = params[b + 8]; q[v].lpg_colour = params[b + 9]
            q[v].trigger_patched = 1
            q[v].level_patched = 0
            attackInc[v] = { let a = max(params[b + 6], 0) * 0.001 * sr; return a < 1 ? 1 : 1 / a }()
            decayMul[v] = expf(-6.9 / max(params[b + 7] * 0.001 * sr, 1))
        }
        if audition >= 0 && audition < V { start(audition, Int(sampleRate * 0.005)) }
        audition = -1
        let gateLen = Int(sampleRate * 0.005)
        // gains for this block
        // (gains live in preallocated storage — nothing is allocated on the audio thread)
        for v in 0..<V {
            let b = DrumSynthLayout.base(v)
            let audible = params[b + 12] < 0.5 && (!anySolo || params[b + 13] > 0.5)
            let g = audible ? params[b + 10] * master : 0
            let pan = min(max(params[b + 11], -1), 1)
            gl[v] = g * min(1, 1 - pan); gr[v] = g * min(1, 1 + pan); gm[v] = g
            aux[v] = params[b + 5] > 0.5
        }
        let oL = outputs[0], oR = outputs[1]
        // a voice whose own outlet is patched plays there (mono) instead of in the L / R mix
        let own = patchedOutputs >> 2
        for v in 0..<V where own & (1 << UInt64(v)) != 0 { outputs[2 + v].update(repeating: 0, count: frames) }
        for v in 0..<V { level[v] *= 0.9 }
        if ctx.stopPending { extCount = -1; step = -1 }
        bridge.run(frames: frames, input: { [self] c, i in
            // the sequencer runs per host sample; its triggers go to the voices as short gates
            if c == 0 {
                var fired = false
                if hasReset && resetEdge.rising(rs[i]) { extCount = -1; step = -1 }
                if hasClock {
                    if clockEdge.rising(ck[i]) && ctx.running { extCount += 1; step = extCount % len; fired = true }
                } else if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: nil, sampleRate: sampleRate) {
                    step = safeInt(floor(ctx.beat[i] / div)) % len
                    fired = true
                }
                if fired && step >= 0 {
                    let delay = step % 2 == 1 ? Int(Float(clock.stepSamples) * swing) : 0
                    for v in 0..<V where hits[v * DrumSynthLayout.steps + step] > 0.5 {
                        if delay == 0 { start(v, gateLen) } else { pending[v] = delay }
                    }
                }
                for v in 0..<V where pending[v] >= 0 {
                    if pending[v] == 0 { start(v, gateLen) }
                    pending[v] -= 1
                }
            }
            let on = gateLeft[c] > 0
            if c == V - 1 { for v in 0..<V where gateLeft[v] > 0 { gateLeft[v] -= 1 } }
            return on ? 1 : 0
        }, render: { [self] in
            for v in 0..<V {
                var mx: Float = 0
                let t = bridge.inChannel(v)
                for k in 0..<bridge.block { mx = max(mx, t[k]) }
                q[v].trigger = mx > 0.5 ? 1 : 0
                mi_macro_process(dsp[v], &q[v], bridge.outChannel(2 * v), bridge.outChannel(2 * v + 1))
            }
        }, output: { [self] c, i, x in
            let v = c / 2
            let isAux = c % 2 == 1
            guard isAux == aux[v] else { return }          // the chosen model: main (analog) or aux (synthetic)
            if v == 0 { oL[i] = 0; oR[i] = 0 }
            // amplitude envelope on top of the voice's own: linear attack, then exponential decay
            if attacking[v] { env[v] = min(env[v] + attackInc[v], 1); if env[v] >= 1 { attacking[v] = false } }
            else { env[v] *= decayMul[v] }
            let y = x * env[v]
            if own & (1 << UInt64(v)) != 0 { outputs[2 + v][i] = y * gm[v] }
            else { oL[i] += y * gl[v]; oR[i] += y * gr[v] }
            level[v] = max(level[v], abs(y))
        })
        readouts[0] = Float(step)
        for v in 0..<V { readouts[1 + v] = min(level[v] * 2, 1) }
    }
}
