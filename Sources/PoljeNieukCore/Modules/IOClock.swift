import Foundation

public let kMaxHardwareChannels = 32

/// in : every hardware input channel as its own outlet (disting NT USB channels 1…N).
final class HardwareInNode: DSPNode {
    private var peaks = [Float](repeating: 0, count: kMaxHardwareChannels)
    private var zeroedFrom = 0

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let n = min(ctx.inputCount, kMaxHardwareChannels)
        let decay = powf(0.5, Float(frames) / Float(sampleRate * 0.12))
        for c in 0..<n {
            let src = ctx.inputs[c], out = outputs[c]
            var m: Float = 0
            for i in 0..<frames { let v = src[i]; out[i] = v; m = max(m, abs(v)) }
            peaks[c] = max(m, peaks[c] * decay)
            readouts[c] = peaks[c]
        }
        if zeroedFrom != n {
            for c in n..<kMaxHardwareChannels {
                outputs[c].update(repeating: 0, count: kMaxBlock)
                readouts[c] = 0
            }
            zeroedFrom = n
        }
    }
}

/// out : every hardware output channel as its own inlet.
final class HardwareOutNode: DSPNode {
    private var peaks = [Float](repeating: 0, count: kMaxHardwareChannels)
    /// Channels fed only by control voltages (pitch, gates, LFOs …): the gain doesn't touch them, so a
    /// pitch CV stays exactly 1 V/oct however loud the audio is set. Set by the graph when it's built.
    var cvChannels: UInt64 = 0

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let g = params[0] <= -59.9 ? 0 : dbToGain(params[0])
        let n = min(ctx.outputCount, kMaxHardwareChannels)
        let decay = powf(0.5, Float(frames) / Float(sampleRate * 0.12))
        for c in 0..<n {
            guard isConnected(connected, c) else { peaks[c] = 0; readouts[c] = 0; continue }
            let src = inputs[c], o = ctx.outputs[c]
            var m: Float = 0
            let gc = cvChannels & (1 << UInt64(c)) != 0 ? 1 : g
            for i in 0..<frames { let v = src[i] * gc; o[i] += v; m = max(m, abs(v)) }
            peaks[c] = max(m, peaks[c] * decay)
            readouts[c] = peaks[c]
        }
    }
}

/// clock : follows a clock signal from the modular (or runs internally) and drives
/// the beat position every synced module reads.
final class ClockNode: DSPNode {
    static let ppqnValues: [Double] = [1, 2, 4, 8, 24]
    static let outRates: [Double] = [0.25, 0.5, 1, 2, 4]

    private var high = false, resetHigh = false, pendingReset = false
    private var sinceEdge: Double = 1e12
    private var period: Double = 0          // samples between clock pulses (smoothed)
    private var tick = -1
    private var beat: Double = 0
    private var prevBeat: Double = 0
    private var pulseLeft = 0
    private var freewheel = false

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let ext = params[0] < 0.5
        let bpm = Double(params[1])
        let ppqn = Self.ppqnValues[clampIndex(params[2], Self.ppqnValues.count)]
        let thr = params[3]
        let rate = Self.outRates[clampIndex(params[4], Self.outRates.count)]
        let clk = inputs[0], rst = inputs[1]
        let pulseOut = outputs[0], rampOut = outputs[1]
        let pulseLen = safeInt(sampleRate * 0.005)
        let minGap = sampleRate * 0.002

        if ctx.stopPending {
            // ■: park just before beat 0 — the first ▶ (or the next pulse) is beat 0, step one
            beat = -1e-6; prevBeat = beat; tick = -1; pendingReset = false; freewheel = false
        }
        for i in 0..<frames {
            if !ctx.running {
                // paused / stopped: time stands still; keep track of the clock input's level only
                if ext { let x = clk[i]; if x > thr { high = true } else if x < thr * 0.5 { high = false } }
                sinceEdge = 1e12
                ctx.beat[i] = beat
                pulseOut[i] = 0
                rampOut[i] = Float(max(beat, 0) - floor(max(beat, 0)))
                prevBeat = beat
                continue
            }
            let r = rst[i]
            if !resetHigh && r > thr { resetHigh = true; pendingReset = true }
            else if resetHigh && r < thr * 0.5 { resetHigh = false }

            if ext {
                sinceEdge += 1
                let x = clk[i]
                if !high && x > thr {
                    high = true
                    if sinceEdge >= minGap {
                        if sinceEdge < sampleRate * 4 {
                            if period == 0 || abs(sinceEdge - period) > period * 0.15 {
                                period = sinceEdge            // tempo jump: lock immediately
                            } else {
                                period += (sinceEdge - period) * 0.3   // small drift: smooth
                            }
                        }
                        sinceEdge = 0
                        if pendingReset { tick = 0; pendingReset = false }
                        else if freewheel {
                            // pulses came back: continue from the next tick ahead of where we free-ran to
                            tick = max(tick + 1, Int((beat * ppqn - 1e-6).rounded(.up)))
                        } else { tick += 1 }
                        freewheel = false
                        beat = Double(tick) / ppqn
                    }
                } else if high && x < thr * 0.5 {
                    high = false
                }
                // Between pulses, extrapolate, but never run past the next expected pulse.
                if period > 0 && sinceEdge > 0 && sinceEdge < period * 2.5 {
                    let limit = Double(tick + 1) / ppqn - 1e-7
                    beat = min(beat + 1 / (period * ppqn), limit)
                } else if sinceEdge > 0 {
                    // No clock (yet, or it stopped): keep time at the last tempo (or int bpm) so
                    // quantised loopers, synced delays etc. keep working. Snaps back when pulses return.
                    freewheel = true
                    let spb = period > 0 ? period * ppqn : sampleRate * 60 / max(bpm, 1)
                    beat += 1 / spb
                }
            } else {
                if pendingReset { pendingReset = false; beat = 0; prevBeat = -1e-9 }
                beat += bpm / 60 / sampleRate
            }

            ctx.beat[i] = beat
            if crossed(prevBeat, beat, rate) { pulseLeft = pulseLen }
            pulseOut[i] = pulseLeft > 0 ? 0.5 : 0     // 0.5 ≈ +5 V on a ±10 V DC-coupled path
            if pulseLeft > 0 { pulseLeft -= 1 }
            rampOut[i] = Float(beat - floor(beat))
            prevBeat = beat
        }

        if ext {
            ctx.samplesPerBeat = period > 0 ? period * ppqn : sampleRate * 60 / max(bpm, 1)
        } else {
            ctx.samplesPerBeat = sampleRate * 60 / max(bpm, 1)
        }
        ctx.externalClock = ext
        readouts[0] = Float(60 * sampleRate / ctx.samplesPerBeat)
        readouts[1] = Float(safeInt(floor(beat)) % 4)
        readouts[2] = ext ? ((period > 0 && sinceEdge < period * 2.5) ? 1 : 0) : 1
        readouts[3] = ext ? 1 : 0
    }
}

/// mix : stereo mixer with 2, 4, 8 or 16 mono channels, each with level and pan, and a master level.
/// Params: 0 channels, then per channel k: 1+2k level, 2+2k pan, then 33 master.
public enum MixerLayout {
    public static let channelChoices = [2, 4, 8, 16]
    public static let maxChannels = 16
    public static let masterIndex = 1 + 2 * maxChannels
    public static let showPansIndex = masterIndex + 1
    /// readout slot of channel 0's level meter
    public static let channelMeterBase = 8
    public static func channels(_ v: Float) -> Int { channelChoices[clampIndex(v, channelChoices.count)] }
    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.choice("chans", "channels", channelChoices.map { "\($0)" }, def: 1)]
        for k in 1...maxChannels {
            p.append(ParamSpec("g\(k)", "\(k) level", 0, 1.5, 1, unit: "%"))
            p.append(ParamSpec("p\(k)", "\(k) pan", -1, 1, 0))
        }
        p.append(ParamSpec("master", "master", 0, 1.5, 1, unit: "%"))
        p.append(.toggle("pans", "show pans", false))     // display only: pan rows hidden by default
        return p
    }
}

final class MixerNode: DSPNode {
    /// readouts: 0 / 1 output L / R, 8… per-channel level (after its fader)
    static let channelMeterBase = MixerLayout.channelMeterBase
    private var meterL = PeakMeter(), meterR = PeakMeter()
    private var chMeters = [PeakMeter](repeating: PeakMeter(), count: MixerLayout.maxChannels)
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        oL.update(repeating: 0, count: frames)
        oR.update(repeating: 0, count: frames)
        let n = MixerLayout.channels(params[0])
        let master = params[MixerLayout.masterIndex]
        for k in n..<MixerLayout.maxChannels { readouts[Self.channelMeterBase + k] = 0 }
        for k in 0..<n {
            guard isConnected(connected, k) else { readouts[Self.channelMeterBase + k] = 0; continue }
            let g = params[1 + 2 * k] * master
            let pan = min(max(params[2 + 2 * k], -1), 1)
            let theta = (pan + 1) * Float.pi / 4            // constant power, centre = unity
            let gl = cosf(theta) * 1.41421356 * g, gr = sinf(theta) * 1.41421356 * g
            let src = inputs[k]
            var pk: Float = 0
            for i in 0..<frames {
                let x = src[i]
                oL[i] += x * gl
                oR[i] += x * gr
                pk = max(pk, abs(x))
            }
            readouts[Self.channelMeterBase + k] = chMeters[k].update(peak: pk * abs(g), frames, sampleRate: sampleRate)
        }
        readouts[0] = meterL.update(oL, frames, sampleRate: sampleRate)
        readouts[1] = meterR.update(oR, frames, sampleRate: sampleRate)
    }
}

/// smix: the mixer for stereo sources — each channel an L and an R inlet, one level for both, pan as balance
/// (centre = both sides at unity). arrange's "multi" outlet patches every track into it.
final class StereoMixerNode: DSPNode {
    private var meterL = PeakMeter(), meterR = PeakMeter()
    private var chMeters = [PeakMeter](repeating: PeakMeter(), count: MixerLayout.maxChannels)
    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        oL.update(repeating: 0, count: frames)
        oR.update(repeating: 0, count: frames)
        let n = MixerLayout.channels(params[0])
        let master = params[MixerLayout.masterIndex]
        for k in n..<MixerLayout.maxChannels { readouts[MixerLayout.channelMeterBase + k] = 0 }
        for k in 0..<n {
            let hasL = isConnected(connected, 2 * k), hasR = isConnected(connected, 2 * k + 1)
            guard hasL || hasR else { readouts[MixerLayout.channelMeterBase + k] = 0; continue }
            let g = params[1 + 2 * k] * master
            let bal = min(max(params[2 + 2 * k], -1), 1)
            let gl = g * min(1, 1 - bal), gr = g * min(1, 1 + bal)
            let sL = hasL ? inputs[2 * k] : inputs[2 * k + 1], sR = hasR ? inputs[2 * k + 1] : inputs[2 * k]
            var pk: Float = 0
            for i in 0..<frames {
                oL[i] += sL[i] * gl
                oR[i] += sR[i] * gr
                pk = max(pk, abs(sL[i]), abs(sR[i]))
            }
            readouts[MixerLayout.channelMeterBase + k] = chMeters[k].update(peak: pk * abs(g), frames, sampleRate: sampleRate)
        }
        readouts[0] = meterL.update(oL, frames, sampleRate: sampleRate)
        readouts[1] = meterR.update(oR, frames, sampleRate: sampleRate)
    }
}

/// lfo : free or clock-synced modulation source (also useful as CV back into the modular).
/// A patched clock drives it instead (its pulses count as 1/16 notes, so the division still applies);
/// reset starts the wave from the top.
final class LFONode: DSPNode {
    private var phase: Double = 0
    private var prevPhase: Double = 0
    private var held: Float = 0
    private var prevHeld: Float = 0
    private var rng = XorShift(seed: 0x1234_5678)
    private var clockEdge = EdgeDetector(), resetEdge = EdgeDetector()
    private var pulses = -1, samplesSincePulse = 0, pulsePeriod = 3000
    private var beatZero: Double = 0                 // synced to the beat: where a reset put the start

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let shape = clampIndex(params[0], 6)
        let sync = params[1] > 0.5
        let rate = Double(params[2])
        let div = Divisions.beats(params[3])
        let depth = params[4], offset = params[5]
        let out = outputs[0]
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let ck = inputs[0], rs = inputs[1]
        if ctx.stopPending { pulses = -1; beatZero = 0 }
        for i in 0..<frames {
            if hasReset && resetEdge.rising(rs[i]) {
                pulses = -1; phase = 0; prevPhase = 0
                beatZero = ctx.beat[i]
            }
            if hasClock {
                // follow the patched clock: 1 pulse = 1/16 note, smooth between pulses
                samplesSincePulse += 1
                if clockEdge.rising(ck[i]) && ctx.running {
                    if pulses >= 0 && samplesSincePulse > 16 { pulsePeriod = samplesSincePulse }
                    pulses += 1
                    samplesSincePulse = 0
                }
                if pulses >= 0 {
                    let pos = Double(pulses) + min(Double(samplesSincePulse) / Double(max(pulsePeriod, 1)), 0.999)
                    let p = pos * 0.25 / div
                    phase = p - floor(p)
                }
            } else if sync {
                let p = (ctx.beat[i] - beatZero) / div
                phase = p - floor(p)
            } else {
                phase += rate / sampleRate
                if phase >= 1 { phase -= 1 }
            }
            if phase < prevPhase {
                prevHeld = held
                held = rng.next() * 2 - 1
                // UI: the last 8 random values, newest last
                for k in 2..<9 { readouts[k] = readouts[k + 1] }
                readouts[9] = held
            }
            prevPhase = phase
            let p = Float(phase)
            let v: Float
            switch shape {
            case 0: v = sinf(2 * .pi * p)
            case 1: v = p < 0.5 ? 4 * p - 1 : 3 - 4 * p
            case 2: v = 2 * p - 1
            case 3: v = p < 0.5 ? 1 : -1
            case 4:
                // random: glide smoothly (cosine) from the last random value to the next over each cycle
                let k = (1 - cosf(.pi * p)) / 2
                v = prevHeld + (held - prevHeld) * k
            default:
                // square random: a new random value at each cycle, held (steps)
                v = held
            }
            out[i] = v * depth + offset
        }
        readouts[0] = out[frames - 1]
        readouts[1] = Float(phase)
    }
}
