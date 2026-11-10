import Foundation

/// gain~ : Ableton-Utility-style gain, balance, width, mono, phase invert, mute, DC block.
final class UtilityNode: DSPNode {
    // 0 gain, 1 balance, 2 width, 3 mono, 4 invert L, 5 invert R, 6 mute, 7 dc block
    private var g: Float = 1
    private var dcXL: Float = 0, dcYL: Float = 0, dcXR: Float = 0, dcYR: Float = 0
    private var meterL = PeakMeter(), meterR = PeakMeter()

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let target: Float = (params[6] > 0.5 || params[0] <= -59.9) ? 0 : dbToGain(params[0])
        let pan = params[1]
        let width = params[3] > 0.5 ? 0 : params[2]
        let invL: Float = params[4] > 0.5 ? -1 : 1, invR: Float = params[5] > 0.5 ? -1 : 1
        let dc = params[7] > 0.5
        let c = onePoleCoef(ms: 10, sampleRate: sampleRate)
        let gl = min(1, 1 - pan), gr = min(1, 1 + pan)
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let oL = outputs[0], oR = outputs[1]
        for i in 0..<frames {
            g += (target - g) * c
            var l = inL[i] * invL, r = inR[i] * invR
            if dc {
                let yl = l - dcXL + 0.9995 * dcYL; dcXL = l; dcYL = yl; l = yl
                let yr = r - dcXR + 0.9995 * dcYR; dcXR = r; dcYR = yr; r = yr
            }
            let m = (l + r) * 0.5, s = (l - r) * 0.5 * width
            oL[i] = (m + s) * gl * g
            oR[i] = (m - s) * gr * g
        }
        readouts[0] = meterL.update(oL, frames, sampleRate: sampleRate)
        readouts[1] = meterR.update(oR, frames, sampleRate: sampleRate)
    }
}

/// env~ : envelope follower — turns loudness into a control signal.
final class EnvelopeNode: DSPNode {
    // 0 attack, 1 release, 2 sensitivity, 3 amount, 4 offset
    private var env: Float = 0
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let att = onePoleCoef(ms: params[0], sampleRate: sampleRate)
        let rel = onePoleCoef(ms: params[1], sampleRate: sampleRate)
        let sens = params[2], amt = params[3], off = params[4]
        let inp = inputs[0], out = outputs[0]
        for i in 0..<frames {
            let x = min(abs(inp[i]) * sens, 1)
            env += (x - env) * (x > env ? att : rel)
            out[i] = env * amt + off
        }
        readouts[0] = env
    }
}

/// rand~ : random / sample-and-hold source with smoothing, free or clock-locked.
final class RandomNode: DSPNode {
    // 0 rate, 1 sync, 2 division, 3 smooth, 4 depth, 5 offset, 6 polarity
    private var clock = PhaseClock()
    private var prev: Double = 0
    private var target: Float = 0, cur: Float = 0
    private var rng = XorShift(seed: 0x5EED_1234)
    private var trig = EdgeDetector()

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let sync = params[1] > 0.5
        let hz = Double(params[0])
        let div = Divisions.beats(params[2])
        let periodSamples = sync ? div * ctx.samplesPerBeat : sampleRate / max(hz, 0.001)
        let smooth = params[3]
        let coef: Float = smooth <= 0.001 ? 1 : 1 - expf(-3 / (smooth * Float(periodSamples)))
        let depth = params[4], off = params[5], uni = params[6] > 0.5
        let hasTrig = isConnected(connected, 0)
        let tin = inputs[0], out = outputs[0]
        for i in 0..<frames {
            let p = clock.advance(sync: sync, hz: hz, divBeats: div, beat: ctx.beat[i], sampleRate: sampleRate)
            var fire = hasTrig ? trig.rising(tin[i]) : p < prev
            if !hasTrig && sync && ctx.beat[i] < 0 { fire = false }
            prev = p
            if fire { target = uni ? rng.next() : rng.next() * 2 - 1 }
            cur += (target - cur) * coef
            out[i] = cur * depth + off
        }
        readouts[0] = out[frames - 1]
    }
}

/// atten~ : attenuverter + offset + slew. With nothing patched in it is a constant (handy for CV).
final class AttenNode: DSPNode {
    // 0 amount, 1 offset, 2 slew ms
    private var y: Float = 0
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let amt = params[0], off = params[1]
        let c = onePoleCoef(ms: params[2], sampleRate: sampleRate)
        let inp = inputs[0], out = outputs[0]
        for i in 0..<frames {
            y += (inp[i] * amt + off - y) * c
            out[i] = y
        }
        readouts[0] = y
    }
}
