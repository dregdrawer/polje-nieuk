import Foundation

/// looper : stereo, clock-quantised looper with overdub, speed/reverse, gate inputs for rec/stop,
/// input monitoring while recording, loop-section selection (start/end) and a beat grid for snapping.
final class LooperNode: DSPNode, SampleBufferNode {
    enum State: Int { case empty = 0, armed, recording, playing, overdub, stopped, closing }
    static let lengths: [Int] = [0, 1, 2, 4, 8, 16, 32]
    // params: 0 rec, 1 play, 2 stop, 3 clear, 4 length, 5 quantize, 6 speed, 7 reverse, 8 keep, 9 level, 10 dry,
    //         11 monitor, 12 loop start, 13 loop end, 14 grid
    // inputs: 0 L, 1 R, 2 rec gate, 3 stop gate     outputs: L, R
    private let cap: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    let loadGuard = LoadGuard()
    public private(set) var contentVersion = 0
    private(set) var state = State.empty
    private var recLen = 0
    private var loopLen = 0
    private var play: Double = 0
    private var recBeats = 0
    private var loopBeats = 0
    private var beatCounter = 0
    private var prevBeat: Double = 0
    private var recGate = false, stopGate = false
    private var quant = true
    private var lengthBeats = 4

    override init(spec: ModuleSpec, sampleRate: Double) {
        cap = Int(sampleRate * 120)
        bufL = .allocate(capacity: cap); bufL.initialize(repeating: 0, count: cap)
        bufR = .allocate(capacity: cap); bufR.initialize(repeating: 0, count: cap)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    private func startRec() {
        state = .recording
        recLen = 0
        recBeats = 0
    }

    private func finishRec() {
        contentVersion &+= 1
        guard recLen >= 256 else { state = .empty; recLen = 0; loopLen = 0; return }
        loopLen = recLen
        let fade = min(64, loopLen / 4)
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            bufL[i] *= g; bufL[loopLen - 1 - i] *= g
            bufR[i] *= g; bufR[loopLen - 1 - i] *= g
        }
        loopBeats = quant ? recBeats : 0
        play = 0
        beatCounter = 0
        state = .playing
    }

    private func pressRec() {
        switch state {
        case .empty: if quant { state = .armed } else { startRec() }
        case .armed: state = .empty
        case .recording: if quant { state = .closing } else { finishRec() }
        case .closing: break
        case .playing: state = .overdub
        case .overdub: state = .playing
        case .stopped: play = 0; beatCounter = 0; state = .overdub
        }
    }

    private func pressPlay() {
        guard loopLen > 0 else { return }
        if state == .stopped { play = 0; beatCounter = 0 }
        if state == .stopped || state == .overdub { state = .playing }
    }

    private func pressStop() {
        switch state {
        case .recording, .closing:
            finishRec()
            if loopLen > 0 { state = .stopped; play = 0 }
        case .armed: state = .empty
        case .playing, .overdub: state = .stopped; play = 0
        default: break
        }
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        lengthBeats = Self.lengths[clampIndex(params[4], Self.lengths.count)]
        quant = params[5] > 0.5
        // Speed is varispeed (always forward); reverse is its own switch.
        var rate = Double(params[6])
        if !rate.isFinite || rate < 0.05 { rate = 1 }
        if abs(rate - 1) < 0.02 { rate = 1 }     // treat ~1x as exactly 1x so clock re-sync works
        let speed = params[7] > 0.5 ? -rate : rate
        let keep = params[8], level = params[9], dry = params[10]
        let qUnit = Double(lengthBeats > 0 ? min(lengthBeats, 4) : 1)
        let freeTarget = (!quant && lengthBeats > 0) ? max(256, safeInt(Double(lengthBeats) * ctx.samplesPerBeat)) : Int.max

        var recPress = consumeTrigger(0)
        var playPress = consumeTrigger(1)
        var stopPress = consumeTrigger(2)
        if consumeTrigger(3) { state = .empty; recLen = 0; loopLen = 0; contentVersion &+= 1 }
        if loadGuard.busy {
            for o in outputs { o.update(repeating: 0, count: frames) }
            return
        }
        let monitor = params[11] > 0.5
        var regionLo = Double(min(max(params[12], 0), 1)), regionHi = Double(min(max(params[13], 0), 1))
        if regionHi < regionLo { swap(&regionLo, &regionHi) }
        let fullRegion = regionLo <= 0.001 && regionHi >= 0.999

        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let recG = inputs[2], stopG = inputs[3]
        let hasRecG = isConnected(connected, 2), hasStopG = isConnected(connected, 3)
        let oL = outputs[0], oR = outputs[1]

        for i in 0..<frames {
            let b = ctx.beat[i]
            let beatTick = crossed(prevBeat, b, 1)
            let qTick = crossed(prevBeat, b, qUnit)
            prevBeat = b

            if hasRecG {
                let g = recG[i]
                if !recGate && g > 0.2 { recGate = true; recPress = true } else if recGate && g < 0.1 { recGate = false }
            }
            if hasStopG {
                let g = stopG[i]
                if !stopGate && g > 0.2 { stopGate = true; stopPress = true } else if stopGate && g < 0.1 { stopGate = false }
            }
            if recPress { recPress = false; pressRec() }
            if playPress { playPress = false; pressPlay() }
            if stopPress { stopPress = false; pressStop() }

            let xl = inL[i], xr = inR[i]
            var yl: Float = 0, yr: Float = 0
            let listening = state == .armed || state == .recording || state == .closing || state == .overdub

            if state == .armed && qTick { startRec() }

            if state == .recording || state == .closing {
                if beatTick && recLen > 0 { recBeats += 1 }
                let done = (quant && lengthBeats > 0 && recBeats >= lengthBeats)
                    || (state == .closing && beatTick && recLen > 0)
                    || recLen >= freeTarget
                    || recLen >= cap
                if done { finishRec() } else { bufL[recLen] = xl; bufR[recLen] = xr; recLen += 1 }
            }

            if (state == .playing || state == .overdub) && loopLen > 0 {
                let fl = Double(loopLen)
                let lo = (regionLo * fl).rounded(.down)
                let hi = max(lo + 64, min((regionHi * fl).rounded(.down), fl))
                let span = hi - lo
                if beatTick {
                    beatCounter += 1
                    // Re-align to the modular's clock once per loop, absorbing tempo drift.
                    if fullRegion && quant && loopBeats > 0 && speed == 1 && beatCounter % loopBeats == 0 {
                        let f = play / fl
                        if f > 0.85 || f < 0.15 { play = 0 }
                    }
                }
                if play < lo || play >= hi { play = speed >= 0 ? lo : hi - 1 }
                yl = readLinear(bufL, loopLen, play)
                yr = readLinear(bufR, loopLen, play)
                if state == .overdub {
                    let ip = min(max(Int(play), 0), loopLen - 1)
                    bufL[ip] = bufL[ip] * keep + xl
                    bufR[ip] = bufR[ip] * keep + xr
                }
                play += speed
                if play >= hi { play -= span } else if play < lo { play += span }
            }
            let thru: Float = (monitor && listening) ? max(dry, 1) : dry
            oL[i] = xl * thru + yl * level
            oR[i] = xr * thru + yr * level
        }
        if state == .recording || state == .closing || state == .overdub { contentVersion &+= 1 }

        readouts[0] = Float(state.rawValue)
        switch state {
        case .recording, .closing:
            readouts[1] = lengthBeats > 0 ? Float(recBeats) / Float(lengthBeats) : 0
            readouts[2] = Float(Double(recLen) / sampleRate)
        case .playing, .overdub, .stopped:
            readouts[1] = loopLen > 0 ? Float(play / Double(loopLen)) : 0
            readouts[2] = Float(Double(loopLen) / sampleRate)
        default:
            readouts[1] = 0; readouts[2] = 0
        }
        readouts[3] = Float(loopBeats)
        readouts[5] = (state == .recording || state == .closing) ? 1 : 0
        // samples per beat for the grid: exact when the loop was recorded in sync, else the clock's tempo
        readouts[kBeatSamplesSlot] = Float(loopBeats > 0 && loopLen > 0 ? Double(loopLen) / Double(loopBeats) : ctx.samplesPerBeat)
        readouts[kPlayheadSlot] = (state == .playing || state == .overdub) && loopLen > 0 ? Float(play / Double(loopLen)) : -1
        for k in 1..<8 { readouts[kPlayheadSlot + k] = -1 }
    }

    // MARK: SampleBufferNode

    public var waveBuffer: UnsafeMutablePointer<Float> { bufL }
    public var waveBufferR: UnsafeMutablePointer<Float> { bufR }
    public var waveLength: Int { (state == .recording || state == .closing) ? recLen : loopLen }
    public var waveRecording: Bool { state == .recording || state == .closing || state == .overdub }
    public var bufferCapacity: Int { cap }

    public func snapshot() -> StereoAudio {
        let n = loopLen
        guard n > 0 else { return StereoAudio() }
        return StereoAudio(left: Array(UnsafeBufferPointer(start: bufL, count: n)),
                           right: Array(UnsafeBufferPointer(start: bufR, count: n)))
    }

    public func load(_ audio: StereoAudio) {
        loadGuard.whileBusy {
            let n = min(audio.count, cap)
            audio.copy(into: bufL, bufR, count: n)
            loopLen = n; recLen = 0
            loopBeats = 0
            play = 0
            state = n > 0 ? .stopped : .empty
            contentVersion &+= 1
        }
    }
}
