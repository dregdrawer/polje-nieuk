import Foundation

/// grain~ : live granulator over a 10 s rolling buffer, free-running or triggered by the clock.
final class GranulatorNode: DSPNode {
    struct Grain {
        var active = false
        var pos: Double = 0
        var rate: Double = 1
        var age = 0
        var len = 1
        var gl: Float = 0
        var gr: Float = 0
    }
    static let maxGrains = 64
    static let windowSize = 1024

    // params: 0 pos, 1 size, 2 density, 3 sync, 4 division, 5 pitch, 6 jitter,
    //         7 spray, 8 spread, 9 reverse, 10 freeze, 11 mix, 12 level
    // inputs: 0 L, 1 R, 2 trig, 3 freeze, 4 pos cv
    private let len: Int
    private let buf: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let grains: UnsafeMutablePointer<Grain>
    private let window: UnsafeMutablePointer<Float>
    private var w = 0
    private var phase: Double = 0
    private var prevBeat: Double = 0
    private var trigHigh = false
    private var rng = XorShift(seed: 0xC0FF_EE11)
    private var spawned = 0

    override init(spec: ModuleSpec, sampleRate: Double) {
        len = Int(sampleRate * 10)
        buf = .allocate(capacity: len)
        buf.initialize(repeating: 0, count: len)
        bufR = .allocate(capacity: len)
        bufR.initialize(repeating: 0, count: len)
        grains = .allocate(capacity: Self.maxGrains)
        grains.initialize(repeating: Grain(), count: Self.maxGrains)
        window = .allocate(capacity: Self.windowSize + 1)
        for i in 0...Self.windowSize {
            let s = sin(Double.pi * Double(i) / Double(Self.windowSize))
            window[i] = Float(s * s)
        }
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit { buf.deallocate(); bufR.deallocate(); grains.deallocate(); window.deallocate() }

    private func spawn(position: Double, frozen: Bool) {
        var slot = -1
        for g in 0..<Self.maxGrains where !grains[g].active { slot = g; break }
        if slot < 0 { return }
        let glen = max(16, safeInt(Double(params[1]) / 1000 * sampleRate, 16, len / 4))
        let semis = params[5] + params[6] * (rng.next() * 2 - 1)
        var rate = Double(exp2(semis / 12))
        if rng.next() < params[9] { rate = -rate }
        let maxBack = Double(len) * 0.8
        var delay = position * maxBack + Double(params[7]) * Double(rng.next()) * sampleRate * 0.5
        if !frozen && rate > 1 { delay = max(delay, Double(glen) * (rate - 1) + 8) }
        delay = min(max(delay, 8), Double(len) - Double(glen) * abs(rate) - 8)
        let pan = params[8] * (rng.next() * 2 - 1)
        let angle = (pan + 1) * Float.pi / 4
        spawned += 1
        grains[slot] = Grain(active: true, pos: wrap(Double(w) - delay, Double(len)), rate: rate,
                             age: 0, len: glen, gl: cosf(angle), gr: sinf(angle))
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let freezeParam = params[10] > 0.5
        let density = Double(params[2])
        let sync = params[3] > 0.5
        let div = Divisions.beats(params[4])
        let mix = params[11], level = params[12]
        let grainsPerSec = sync ? sampleRate / max(div * ctx.samplesPerBeat, 1) : density
        let overlap = grainsPerSec * Double(params[1]) / 1000
        let norm = Float(1 / max(1, sqrt(overlap)))
        let inp = inputs[0], inpR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let trig = inputs[2], frz = inputs[3], posCV = inputs[4]
        let hasTrig = isConnected(connected, 2), hasFrz = isConnected(connected, 3), hasPos = isConnected(connected, 4)
        let oL = outputs[0], oR = outputs[1]
        let flen = Double(len)
        let wsize = Float(Self.windowSize)
        var activeCount = 0
        var maxActive = 0
        var frozenNow = freezeParam

        for i in 0..<frames {
            let x = inp[i], xr = inpR[i]
            let frozen = freezeParam || (hasFrz && frz[i] > 0.2)
            frozenNow = frozen
            if !frozen {
                buf[w] = x
                bufR[w] = xr
                w += 1
                if w >= len { w = 0 }
            }

            var fire = false
            let b = ctx.beat[i]
            if sync {
                if crossed(prevBeat, b, div) { fire = true }
            } else {
                phase += density / sampleRate
                if phase >= 1 { phase -= 1; fire = true }
            }
            prevBeat = b
            if hasTrig {
                let t = trig[i]
                if !trigHigh && t > 0.2 { trigHigh = true; fire = true } else if trigHigh && t < 0.1 { trigHigh = false }
            }
            if fire {
                var p = Double(params[0])
                if hasPos { p += Double(posCV[i]) }
                spawn(position: min(max(p, 0), 1), frozen: frozen)
            }

            var l: Float = 0, r: Float = 0
            activeCount = 0
            for g in 0..<Self.maxGrains {
                let gp = grains + g
                guard gp.pointee.active else { continue }
                activeCount += 1
                let ph = Float(gp.pointee.age) / Float(gp.pointee.len) * wsize
                let wi = min(Int(ph), Self.windowSize - 1)
                let wf = ph - Float(wi)
                let env = window[wi] + (window[wi + 1] - window[wi]) * wf
                let sl = readLinear(buf, len, gp.pointee.pos) * env
                let sr = readLinear(bufR, len, gp.pointee.pos) * env
                // pan as a balance on the stereo grain
                l += sl * gp.pointee.gl * 1.414
                r += sr * gp.pointee.gr * 1.414
                var np = gp.pointee.pos + gp.pointee.rate
                if np >= flen { np -= flen } else if np < 0 { np += flen }
                gp.pointee.pos = np
                gp.pointee.age += 1
                if gp.pointee.age >= gp.pointee.len { gp.pointee.active = false }
            }
            maxActive = max(maxActive, activeCount)
            let g = norm * level * mix
            oL[i] = x * (1 - mix) + l * g
            oR[i] = xr * (1 - mix) + r * g
        }
        readouts[0] = Float(maxActive)
        readouts[1] = frozenNow ? 1 : 0
        readouts[2] = Float(spawned)
    }
}
