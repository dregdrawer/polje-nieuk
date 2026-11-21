import Foundation

/// comp : LA-3A-style optical compressor.
/// Two knobs (Peak Reduction, Gain) and a Compress/Limit switch. Like a T4 opto cell:
/// attack is program-dependent (~10 ms, faster on big transients) and release is two-stage —
/// a quick ~60 ms recovery for most of the reduction, then a slow 0.5–5 s tail that gets
/// longer the longer and harder it has been compressing.
final class CompressorNode: DSPNode {
    // 0 peak reduction, 1 gain, 2 mode (compress/limit), 3 mix
    private var env: Float = 0          // detector (linear)
    private var fast: Float = 0, slow: Float = 0   // gain reduction in dB (≥ 0), two cell "stages"
    private var memory: Float = 0       // 0…1, builds up while compressing → longer slow release

    private var vcaEnv: Float = 0
    private var fetEnv: Float = 0

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let algo = clampIndex(params[4], 3)
        if algo != 0 { processModel(algo, frames, inputs, connected); return }
        let peak = min(max(params[0], 0), 1)
        let makeup = params[1]
        let limit = params[2] > 0.5
        let mix = params[3]
        // Peak Reduction acts like input drive into the cell: more knob = lower effective threshold.
        let threshold: Float = -2 - peak * 40
        let ratio: Float = limit ? 12 : 3
        let knee: Float = limit ? 4 : 10
        let sr = Float(sampleRate)
        let detAtt = 1 - expf(-1 / (0.0005 * sr)), detRel = 1 - expf(-1 / (0.02 * sr))
        let fastRel = 1 - expf(-1 / (0.06 * sr))
        let memUp = 1 / (5 * sr), memDown = 1 / (12 * sr)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let hasSC = isConnected(connected, 2), sc = inputs[2]
        let oL = outputs[0], oR = outputs[1]
        var maxGR: Float = 0, inPk: Float = 0, outPk: Float = 0
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            let d = hasSC ? abs(sc[i]) : max(abs(l), abs(r))
            env += (d - env) * (d > env ? detAtt : detRel)
            let xdb = 20 * log10f(env + 1e-9)
            let over = xdb - threshold
            var target: Float
            if over <= -knee / 2 { target = 0 }
            else if over < knee / 2 { let t = over + knee / 2; target = (1 - 1 / ratio) * t * t / (2 * knee) }
            else { target = (1 - 1 / ratio) * over }
            let gr = fast + slow
            if target > gr {
                // program-dependent attack: ~10 ms, quicker for big jumps
                let jump = target - gr
                let att = 1 - expf(-1 / ((0.010 / (1 + jump / 6)) * sr))
                let add = jump * att
                fast += add * 0.7
                slow += add * 0.3
            } else {
                fast -= fast * fastRel
                let slowTau = 0.5 + 4.5 * memory
                slow -= slow * (1 - expf(-1 / (slowTau * sr)))
            }
            memory = gr > 1 ? min(memory + memUp * min(gr / 6, 2), 1) : max(memory - memDown, 0)
            let g = dbToGain(makeup - (fast + slow))
            oL[i] = l * (1 - mix) + softClip(l * g) * mix
            oR[i] = r * (1 - mix) + softClip(r * g) * mix
            maxGR = max(maxGR, fast + slow)
            inPk = max(inPk, abs(l), abs(r)); outPk = max(outPk, abs(oL[i]), abs(oR[i]))
        }
        publish(maxGR, inPk, outPk, threshold: threshold, ratio: ratio, knee: knee, makeup: makeup)
    }

    /// UI: 0 GR dB, 1 input peak, 2 output peak (peak-hold with a short fall), 3 threshold, 4 ratio, 5 knee, 6 makeup
    private func publish(_ gr: Float, _ inPk: Float, _ outPk: Float, threshold: Float, ratio: Float, knee: Float, makeup: Float) {
        readouts[0] = gr
        readouts[1] = max(inPk, readouts[1] * 0.993)
        readouts[2] = max(outPk, readouts[2] * 0.993)
        readouts[3] = threshold; readouts[4] = ratio; readouts[5] = knee; readouts[6] = makeup
    }

    /// FET (1176-style): very fast attack, quick program-dependent release, hard-ish knee, adds grit.
    /// VCA bus (SSL-style): clean feed-forward, fixed 10 ms attack, auto release, glues a mix.
    private func processModel(_ algo: Int, _ frames: Int, _ inputs: UnsafePointer<UnsafePointer<Float>>, _ connected: UInt64) {
        let peak = min(max(params[0], 0), 1), makeup = params[1], limit = params[2] > 0.5, mix = params[3]
        let fet = algo == 1
        let threshold: Float = (fet ? -4 : -2) - peak * 40
        let ratio: Float = fet ? (limit ? 20 : 4) : (limit ? 10 : 4)
        let knee: Float = fet ? 2 : 0
        let sr = Float(sampleRate)
        let att = 1 - expf(-1 / ((fet ? 0.0004 : 0.010) * sr))
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let hasSC = isConnected(connected, 2), sc = inputs[2]
        let oL = outputs[0], oR = outputs[1]
        var maxGR: Float = 0, inPk: Float = 0, outPk: Float = 0
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            let d = hasSC ? abs(sc[i]) : max(abs(l), abs(r))
            let xdb = 20 * log10f(d + 1e-9)
            let over = xdb - threshold
            var target: Float
            if knee > 0 && abs(over) < knee / 2 { let t = over + knee / 2; target = (1 - 1 / ratio) * t * t / (2 * knee) }
            else { target = over > 0 ? (1 - 1 / ratio) * over : 0 }
            var env = fet ? fetEnv : vcaEnv
            if target > env { env += (target - env) * att }
            else {
                // auto release: faster after short peaks, slower when heavily compressed
                let relS: Float = fet ? 0.05 + 0.4 * min(env / 12, 1) : 0.1 + 1.1 * min(env / 10, 1)
                env -= env * (1 - expf(-1 / (relS * sr)))
            }
            if fet { fetEnv = env } else { vcaEnv = env }
            let g = dbToGain(makeup - env)
            var yl = l * g, yr = r * g
            if fet { yl = tanhf(yl * 1.15) / 1.15; yr = tanhf(yr * 1.15) / 1.15 }   // FET grit
            oL[i] = l * (1 - mix) + softClip(yl) * mix
            oR[i] = r * (1 - mix) + softClip(yr) * mix
            maxGR = max(maxGR, env)
            inPk = max(inPk, abs(l), abs(r)); outPk = max(outPk, abs(oL[i]), abs(oR[i]))
        }
        publish(maxGR, inPk, outPk, threshold: threshold, ratio: ratio, knee: knee, makeup: makeup)
    }
}

/// limit : brickwall-style limiter with 1.3 ms lookahead.
final class LimiterNode: DSPNode {
    // 0 input gain, 1 ceiling, 2 release
    private static let look = 64
    private var bufL = [Float](repeating: 0, count: 64), bufR = [Float](repeating: 0, count: 64)
    private var peakHist = [Float](repeating: 0, count: 64)
    private var w = 0
    private var g: Float = 1
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let pre = dbToGain(params[0]), ceil = dbToGain(params[1])
        let rel = onePoleCoef(ms: params[2], sampleRate: sampleRate)
        let att = onePoleCoef(ms: 0.4, sampleRate: sampleRate)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        var minG: Float = 1
        for i in 0..<frames {
            let l = inL[i] * pre, r = inR[i] * pre
            peakHist[w] = max(abs(l), abs(r))
            var pk: Float = 0
            for k in 0..<Self.look { pk = max(pk, peakHist[k]) }
            let need = pk > ceil ? ceil / pk : 1
            g += (need - g) * (need < g ? att : rel)
            let dl = bufL[w], dr = bufR[w]
            bufL[w] = l; bufR[w] = r
            w += 1; if w >= Self.look { w = 0 }
            oL[i] = min(max(dl * g, -ceil), ceil)
            oR[i] = min(max(dr * g, -ceil), ceil)
            minG = min(minG, g)
        }
        readouts[0] = -20 * log10f(minG)
    }
}

/// gate : noise gate with hold, floor, and sidechain inlet.
final class GateNode: DSPNode {
    // 0 threshold, 1 attack, 2 hold, 3 release, 4 floor
    private var g: Float = 0
    private var holdLeft = 0
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let thr = dbToGain(params[0])
        let att = onePoleCoef(ms: params[1], sampleRate: sampleRate)
        let hold = safeInt(Double(params[2]) * 0.001 * sampleRate)
        let rel = onePoleCoef(ms: params[3], sampleRate: sampleRate)
        let floor = params[4] <= -79.9 ? 0 : dbToGain(params[4])
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let hasSC = isConnected(connected, 2), sc = inputs[2]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            let det = hasSC ? abs(sc[i]) : max(abs(l), abs(r))
            if det > thr { holdLeft = hold }
            let open = holdLeft > 0
            if holdLeft > 0 { holdLeft -= 1 }
            let target: Float = open ? 1 : floor
            g += (target - g) * (open ? att : rel)
            oL[i] = l * g
            oR[i] = r * g
        }
        readouts[0] = g
    }
}

/// eq : three-band DJ-style EQ (perfect reconstruction when flat).
final class EQ3Node: DSPNode {
    // 0 low, 1 mid, 2 high, 3 low freq, 4 high freq
    private var lowL = SVF(), lowR = SVF(), highL = SVF(), highR = SVF()
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        func gain(_ db: Float) -> Float { db <= -59.9 ? 0 : dbToGain(db) }
        let gl = gain(params[0]), gm = gain(params[1]), gh = gain(params[2])
        let sr = Float(sampleRate)
        lowL.set(freq: params[3], sampleRate: sr, k: 1.414); lowR.set(freq: params[3], sampleRate: sr, k: 1.414)
        highL.set(freq: params[4], sampleRate: sr, k: 1.414); highR.set(freq: params[4], sampleRate: sr, k: 1.414)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            let lo = lowL.process(l).low, hi = highL.process(l).high
            let lo2 = lowR.process(r).low, hi2 = highR.process(r).high
            oL[i] = lo * gl + (l - lo - hi) * gm + hi * gh
            oR[i] = lo2 * gl + (r - lo2 - hi2) * gm + hi2 * gh
        }
    }
}
