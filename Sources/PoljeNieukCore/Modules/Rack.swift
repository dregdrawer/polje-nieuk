import Foundation

// rack~ : a sampling drum machine. 16 pads (each a sample with tune / attack / decay / level / pan and
// mute / solo), played by its own drum roll (16 lanes × up to 32 steps) on the app clock or a clock input.
// Starts with a synthesized kit so it makes sound straight away; drop audio files onto pads to replace them.

public enum RackLayout {
    public static let pads = 16
    public static let steps = 32
    public static let perPad = 7                  // tune, attack, decay, level, pan, mute, solo
    public static let globals = 5                 // length, division, swing, selected pad, master
    public static func base(_ pad: Int) -> Int { globals + pad * perPad }
    public static let kitNames = ["kick", "snare", "closed hat", "open hat", "clap", "rim", "low tom", "mid tom",
                                  "hi tom", "crash", "ride", "cowbell", "shaker", "clave", "808", "zap"]

    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.integer("len", "length", 1, steps, 16),
                              .choice("div", "division", Divisions.names, def: Divisions.index("1/16")),
                              ParamSpec("swing", "swing", 0, 0.5, 0, unit: "%"),
                              .choice("sel", "pad", (1...pads).map { "\($0)" }, def: 0),
                              ParamSpec("master", "master", 0, 1.5, 0.9, unit: "%")]
        for k in 1...pads {
            p.append(ParamSpec("t\(k)", "\(k) tune", -24, 24, 0, unit: "st"))
            p.append(ParamSpec("a\(k)", "\(k) attack", 0, 200, 0, unit: "ms", curve: .cubic))
            p.append(ParamSpec("d\(k)", "\(k) decay", 10, 4000, 4000, unit: "ms", curve: .exponential))
            p.append(ParamSpec("v\(k)", "\(k) level", 0, 1.5, 0.8, unit: "%"))
            p.append(ParamSpec("p\(k)", "\(k) pan", -1, 1, 0))
            p.append(.toggle("m\(k)", "\(k) mute", false))
            p.append(.toggle("s\(k)", "\(k) solo", false))
        }
        return p
    }
}

public final class RackNode: DSPNode {
    // readouts: 0 playing step, 1…16 each pad's level right now (for the pads to flash)
    public let hits: UnsafeMutablePointer<Float>          // pad * steps + step
    private var padL = [UnsafeMutablePointer<Float>?](repeating: nil, count: RackLayout.pads)
    private var padR = [UnsafeMutablePointer<Float>?](repeating: nil, count: RackLayout.pads)
    private var padLen = [Int](repeating: 0, count: RackLayout.pads)
    /// Names shown on the pads (main thread).
    public private(set) var padNames: [String] = RackLayout.kitNames
    /// Bumped when a pad's sample changes (for saving).
    public private(set) var contentVersion = 0
    private let guardian = LoadGuard()

    // voices: one per pad
    private var pos = [Double](repeating: 0, count: RackLayout.pads)
    private var env = [Float](repeating: 0, count: RackLayout.pads)
    private var attacking = [Bool](repeating: false, count: RackLayout.pads)
    private var active = [Bool](repeating: false, count: RackLayout.pads)
    private var pending = [Int](repeating: -1, count: RackLayout.pads)   // swing: samples until it fires

    private var step = -1
    private var clock = StepClock()
    private var clockEdge = EdgeDetector(), resetEdge = EdgeDetector()
    private var extCount = -1
    /// UI: pad to play now (tap), -1 = none.
    public var audition = -1

    public override init(spec: ModuleSpec, sampleRate: Double) {
        hits = .allocate(capacity: RackLayout.pads * RackLayout.steps)
        hits.initialize(repeating: 0, count: RackLayout.pads * RackLayout.steps)
        super.init(spec: spec, sampleRate: sampleRate)
        for k in 0..<RackLayout.pads { install(k, RackKit.make(k, sampleRate: sampleRate), name: RackLayout.kitNames[k]) }
        setData("hits", Self.starterBeat)          // a starter beat so it's obvious what it does
    }

    static let starterBeat: [Float] = {
        var h = [Float](repeating: 0, count: RackLayout.pads * RackLayout.steps)
        for s in [0, 8] { h[0 * RackLayout.steps + s] = 1 }
        for s in [4, 12] { h[1 * RackLayout.steps + s] = 1 }
        for s in stride(from: 0, to: 16, by: 2) { h[2 * RackLayout.steps + s] = 1 }
        return h
    }()
    public override var defaultData: [String: [Float]] { ["hits": Self.starterBeat] }

    deinit {
        hits.deallocate()
        for k in 0..<RackLayout.pads { padL[k]?.deallocate(); padR[k]?.deallocate() }
    }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "hits" else { return }
        let n = RackLayout.pads * RackLayout.steps
        for k in 0..<n { hits[k] = k < values.count && values[k].isFinite ? values[k] : 0 }
    }

    // MARK: Samples (main thread)

    private func install(_ k: Int, _ audio: StereoAudio, name: String) {
        let n = audio.count
        let l = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
        let r = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
        audio.copy(into: l, r, count: n)
        let oldL = padL[k], oldR = padR[k]
        padL[k] = l; padR[k] = r; padLen[k] = n
        padNames[k] = name
        active[k] = false
        oldL?.deallocate(); oldR?.deallocate()
    }

    /// Replace pad `k`'s sample (audio at the engine's sample rate).
    public func load(pad k: Int, _ audio: StereoAudio, name: String) {
        guard k >= 0 && k < RackLayout.pads else { return }
        guardian.whileBusy { install(k, audio, name: name) }
        contentVersion &+= 1
    }

    /// Back to the built-in sound for pad `k`.
    public func resetPad(_ k: Int) {
        guard k >= 0 && k < RackLayout.pads else { return }
        load(pad: k, RackKit.make(k, sampleRate: sampleRate), name: RackLayout.kitNames[k])
    }

    public func sample(_ k: Int) -> StereoAudio {
        guard k >= 0 && k < RackLayout.pads, let l = padL[k], let r = padR[k] else { return StereoAudio() }
        return StereoAudio(left: Array(UnsafeBufferPointer(start: l, count: padLen[k])),
                           right: Array(UnsafeBufferPointer(start: r, count: padLen[k])))
    }

    public func padLength(_ k: Int) -> Int { k >= 0 && k < RackLayout.pads ? padLen[k] : 0 }

    // MARK: Audio

    @inline(__always) private func trigger(_ k: Int) {
        guard padLen[k] > 0 else { return }
        pos[k] = 0
        env[k] = 0
        attacking[k] = true
        active[k] = true
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        oL.update(repeating: 0, count: frames)
        oR.update(repeating: 0, count: frames)
        if guardian.busy { return }
        let len = clampIndex(params[0] - 1, RackLayout.steps) + 1
        let div = Divisions.beats(params[1])
        let swing = min(max(params[2], 0), 0.5)
        let master = params[4]
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let ck = inputs[0], rs = inputs[1]
        var anySolo = false
        for k in 0..<RackLayout.pads where params[RackLayout.base(k) + 6] > 0.5 { anySolo = true }

        if audition >= 0 && audition < RackLayout.pads { trigger(audition) }
        audition = -1

        // per-pad constants for this block
        let sr = Float(sampleRate)
        if ctx.stopPending { extCount = -1; step = -1 }
        for i in 0..<frames {
            // the sequencer: a step on the app clock, or on each pulse at the clock inlet
            var fired = false
            if hasReset && resetEdge.rising(rs[i]) { extCount = -1; step = -1 }
            if hasClock {
                if clockEdge.rising(ck[i]) && ctx.running { extCount += 1; step = extCount % len; fired = true }
            } else if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: nil, sampleRate: sampleRate) {
                step = safeInt(floor(ctx.beat[i] / div)) % len
                fired = true
            }
            if fired && step >= 0 {
                // swing: every second step comes late
                let delay = step % 2 == 1 ? Int(Float(clock.stepSamples) * swing) : 0
                for k in 0..<RackLayout.pads where hits[k * RackLayout.steps + step] > 0.5 {
                    if delay == 0 { trigger(k) } else { pending[k] = delay }
                }
            }
            var l: Float = 0, r: Float = 0
            for k in 0..<RackLayout.pads {
                if pending[k] >= 0 {
                    if pending[k] == 0 { trigger(k) }
                    pending[k] -= 1
                }
                guard active[k], let bl = padL[k], let br = padR[k] else { continue }
                let b = RackLayout.base(k)
                let n = padLen[k]
                let p = pos[k]
                let i0 = Int(p)
                if i0 >= n - 1 { active[k] = false; continue }
                let f = Float(p - Double(i0))
                var xl = bl[i0] + (bl[i0 + 1] - bl[i0]) * f
                var xr = br[i0] + (br[i0 + 1] - br[i0]) * f
                // envelope: linear attack, then exponential decay (to −60 dB over the decay time)
                if attacking[k] {
                    let a = max(params[b + 1], 0) * 0.001 * sr
                    env[k] = a < 1 ? 1 : min(env[k] + 1 / a, 1)
                    if env[k] >= 1 { attacking[k] = false }
                } else {
                    let d = max(params[b + 2], 10) * 0.001 * sr
                    env[k] *= expf(-6.9 / d)
                    if env[k] < 1e-4 { active[k] = false }
                }
                pos[k] = p + Double(exp2f(min(max(params[b], -24), 24) / 12))
                let audible = params[b + 5] < 0.5 && (!anySolo || params[b + 6] > 0.5)
                if !audible { continue }
                let g = env[k] * params[b + 3]
                let pan = min(max(params[b + 4], -1), 1)
                xl *= g * min(1, 1 - pan); xr *= g * min(1, 1 + pan)
                l += xl; r += xr
            }
            oL[i] = l * master
            oR[i] = r * master
        }
        readouts[0] = Float(step)
        for k in 0..<RackLayout.pads { readouts[1 + k] = active[k] ? env[k] : 0 }
    }
}

/// The built-in kit, synthesized (so the rack plays before you've loaded anything).
public enum RackKit {
    public static func make(_ k: Int, sampleRate sr: Double) -> StereoAudio {
        var g = SplitMix(seed: UInt64(1000 + k))
        func noise() -> Float { g.nextFloat() * 2 - 1 }
        func render(_ seconds: Double, _ f: (Double, Int) -> Float) -> [Float] {
            let n = Int(seconds * sr)
            return (0..<n).map { f(Double($0) / sr, $0) }
        }
        func env(_ t: Double, _ d: Double) -> Float { Float(exp(-t / d)) }
        var phase = 0.0
        func sweep(_ t: Double, from f0: Double, to f1: Double, _ k: Double) -> Float {
            let f = f1 + (f0 - f1) * exp(-t / k)
            phase += 2 * .pi * f / sr
            return Float(sin(phase))
        }
        var hp: Float = 0, lastIn: Float = 0
        func highpass(_ x: Float) -> Float { hp = 0.86 * (hp + x - lastIn); lastIn = x; return hp }
        var bp1: Float = 0, bp2: Float = 0
        func band(_ x: Float, _ fc: Double, _ q: Float) -> Float {
            let w = Float(2 * sin(.pi * min(fc, sr * 0.2) / sr))
            bp1 += w * bp2; let hpv = x - bp1 - q * bp2; bp2 += w * hpv
            return bp2
        }
        let mono: [Float]
        switch k {
        case 0: mono = render(0.5) { t, _ in sweep(t, from: 160, to: 46, 0.04) * env(t, 0.16) * 0.95 + (t < 0.004 ? noise() * 0.3 : 0) }
        case 1: mono = render(0.35) { t, _ in Float(sin(2 * .pi * 185 * t)) * env(t, 0.06) * 0.5 + band(noise(), 2400, 0.7) * env(t, 0.11) * 0.9 }
        case 2: mono = render(0.12) { t, _ in highpass(noise()) * env(t, 0.02) * 0.7 }
        case 3: mono = render(0.6) { t, _ in highpass(noise()) * env(t, 0.18) * 0.6 }
        case 4: mono = render(0.4) { t, _ in
            let bursts: Float = (t < 0.01 || (t > 0.012 && t < 0.02) || (t > 0.024 && t < 0.032)) ? 1 : 0
            return band(noise(), 1500, 0.8) * (bursts * 0.9 + env(t, 0.09) * 0.7) }
        case 5: mono = render(0.08) { t, _ in Float(sin(2 * .pi * 820 * t)) * env(t, 0.012) * 0.7 + (t < 0.002 ? noise() * 0.5 : 0) }
        case 6, 7, 8:
            let f = [6: 95.0, 7: 135.0, 8: 190.0][k]!
            mono = render(0.6) { t, _ in sweep(t, from: f * 1.6, to: f, 0.05) * env(t, 0.18) * 0.85 }
        case 9: mono = render(1.8) { t, _ in
            let metal = Float(sin(2 * .pi * 3220 * t) * sin(2 * .pi * 4630 * t))
            return (highpass(noise()) * 0.7 + metal * 0.3) * env(t, 0.55) * 0.6 }
        case 10: mono = render(1.4) { t, _ in
            let m = Float(sin(2 * .pi * 2980 * t) + 0.6 * sin(2 * .pi * 4410 * t) + 0.4 * sin(2 * .pi * 6120 * t))
            return (m * 0.2 + highpass(noise()) * 0.15) * env(t, 0.45) + Float(sin(2 * .pi * 3800 * t)) * env(t, 0.01) * 0.3 }
        case 11: mono = render(0.4) { t, _ in
            let sq = Float((sin(2 * .pi * 540 * t) > 0 ? 1 : -1) + (sin(2 * .pi * 800 * t) > 0 ? 1 : -1)) * 0.5
            return band(sq, 800, 0.6) * env(t, 0.09) * 0.8 }
        case 12: mono = render(0.18) { t, _ in highpass(noise()) * Float(min(t / 0.03, 1)) * env(t, 0.04) * 0.6 }
        case 13: mono = render(0.1) { t, _ in Float(sin(2 * .pi * 2500 * t)) * env(t, 0.018) * 0.7 }
        case 14: mono = render(1.6) { t, _ in sweep(t, from: 90, to: 50, 0.03) * env(t, 0.5) * 0.9 }
        default: mono = render(0.2) { t, _ in sweep(t, from: 2400, to: 90, 0.02) * env(t, 0.06) * 0.6 }
        }
        return StereoAudio(left: mono)
    }
}

/// Small deterministic random generator (the kit sounds the same every time).
struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
