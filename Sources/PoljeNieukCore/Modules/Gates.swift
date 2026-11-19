import Foundation

/// tgate~ : a rhythmic gate (a "trance gate"). A step pattern locked to the clock opens and closes the audio;
/// every opening is shaped by attack / decay / sustain / release, and tied steps stay open across steps. The
/// envelope also leaves on its own outlet, so the same rhythm can drive a filter, a VCA in the modular …
public final class TranceGateNode: DSPNode {
    // params: 0 length, 1 division, 2 attack, 3 decay, 4 sustain, 5 release, 6 gate length, 7 mix
    // inputs: L, R   outputs: L, R, env   readouts: 0 step now, 1 envelope now
    public static let steps = 32
    /// per step: 0 off, 1 on (opens the gate), 2 tied (stays open from the step before)
    public let pattern: UnsafeMutablePointer<Float>
    private var lastStep = Int.min
    private var env: Float = 0
    private enum Stage { case idle, attack, decay, sustain, release }
    private var stage = Stage.idle
    private var open = false
    private var smooth: Float = 0

    public static let presets = ["quarters", "eighths", "offbeat", "trance", "stutter", "random", "invert", "clear"]

    public override init(spec: ModuleSpec, sampleRate: Double) {
        pattern = .allocate(capacity: Self.steps)
        pattern.initialize(repeating: 0, count: Self.steps)
        super.init(spec: spec, sampleRate: sampleRate)
        let p = Self.preset("trance", current: [])
        for k in 0..<Self.steps { pattern[k] = p[k] }
    }
    deinit { pattern.deallocate() }

    public override var defaultData: [String: [Float]] { ["steps": Self.preset("trance", current: [])] }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "steps" else { return }
        for k in 0..<Self.steps {
            let v = k < values.count && values[k].isFinite ? values[k].rounded() : 0
            pattern[k] = min(max(v, 0), 2)
        }
    }

    /// A ready-made pattern (32 steps). "invert" and "random" work from the current one.
    public static func preset(_ name: String, current: [Float]) -> [Float] {
        (0..<steps).map { k -> Float in
            let s = k % 16
            switch name {
            case "quarters": return s % 4 == 0 ? 1 : (s % 4 == 1 ? 2 : 0)
            case "eighths": return s % 2 == 0 ? 1 : 0
            case "offbeat": return s % 4 == 2 ? 1 : (s % 4 == 3 ? 2 : 0)
            case "stutter": return [1, 1, 1, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1][s]
            case "random": return Float.random(in: 0..<1) < 0.55 ? (k > 0 && Float.random(in: 0..<1) < 0.3 ? 2 : 1) : 0
            case "invert": return k < current.count ? (current[k] > 0.5 ? 0 : 1) : 0
            case "clear": return 0
            default: return [1, 2, 0, 1, 0, 1, 2, 0, 1, 0, 1, 2, 2, 0, 1, 0][s]       // trance
            }
        }
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let len = clampIndex(params[0] - 1, Self.steps) + 1
        let div = Divisions.beats(params[1])
        let sr = Float(sampleRate)
        let aInc: Float = params[2] > 0.05 ? 1 / max(params[2] * 0.001 * sr, 1) : 1
        let dMul = expf(-5 / max(params[3] * 0.001 * sr, 1))
        let sus = min(max(params[4], 0), 1)
        let rMul = expf(-5 / max(params[5] * 0.001 * sr, 1))
        let gateLen = min(max(params[6], 0.05), 1)
        let mix = min(max(params[7], 0), 1)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1], oE = outputs[2]
        let declick: Float = 1 - expf(-1 / (0.0015 * sr))       // ~1.5 ms smoothing, no clicks at any setting
        var step = 0
        for i in 0..<frames {
            let pos = ctx.beat[i] / div
            if pos >= 0 {
                let abs = Int(floor(pos))
                step = ((abs % len) + len) % len
                if abs != lastStep {
                    lastStep = abs
                    let v = pattern[step]
                    if v > 1.5 && open {
                        // tied: stays open
                    } else if v > 0.5 {
                        open = true; stage = .attack
                    } else {
                        if open { stage = .release }
                        open = false
                    }
                }
                // gate length: close early in the step, unless the next step continues the gate
                if open && pos - floor(pos) >= Double(gateLen) && gateLen < 0.999 {
                    let next = pattern[(step + 1) % len]
                    if next < 1.5 { open = false; stage = .release }
                }
            }
            switch stage {
            case .attack:
                env += aInc
                if env >= 1 { env = 1; stage = .decay }
            case .decay:
                env = sus + (env - sus) * dMul
                if abs(env - sus) < 1e-4 { env = sus; stage = .sustain }
            case .sustain: env = sus
            case .release:
                env *= rMul
                if env < 1e-5 { env = 0; stage = .idle }
            case .idle: env = 0
            }
            smooth += (env - smooth) * declick
            let g = 1 - mix + mix * smooth
            oL[i] = inL[i] * g
            oR[i] = inR[i] * g
            oE[i] = smooth
        }
        readouts[0] = Float(step)
        readouts[1] = smooth
    }
}
