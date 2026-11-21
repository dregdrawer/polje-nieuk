import Foundation

/// Offline helpers for the sampler (run on the main thread, never the audio thread).
public enum Transients {
    /// Onset positions (sample indices, ascending, excluding 0) found by energy-flux peak picking.
    /// `sensitivity` 0…1: higher finds more (quieter) hits.
    public static func detect(_ buf: UnsafePointer<Float>, count: Int, sampleRate: Double,
                              sensitivity: Float, maxSlices: Int = 128) -> [Int] {
        let hopN = 256, win = 512
        guard count > win * 2 else { return [] }
        let frames = (count - win) / hopN
        var logE = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var e: Float = 0
            let s = f * hopN
            for i in 0..<win { let v = buf[s + i]; e += v * v }
            logE[f] = 10 * log10f(e / Float(win) + 1e-10)
        }
        // onset strength = positive jump in level vs. the recent past
        var flux = [Float](repeating: 0, count: frames)
        for f in 2..<frames { flux[f] = max(0, logE[f] - max(logE[f - 1], logE[f - 2])) }
        let thr = 2 + (1 - min(max(sensitivity, 0), 1)) * 14      // 2 dB (sensitive) … 16 dB jump
        let minGap = max(1, Int(0.06 * sampleRate) / hopN)       // ≥ 60 ms between slices
        let floorDB: Float = -60
        var out: [Int] = []
        var lastF = -minGap
        for f in 2..<(frames - 1) {
            guard flux[f] >= thr, flux[f] >= flux[f - 1], flux[f] >= flux[f + 1],
                  logE[f] > floorDB, f - lastF >= minGap else { continue }
            // refine to the first sample in the frame that rises above half the frame peak
            let s = f * hopN
            var pk: Float = 0
            for i in 0..<win { pk = max(pk, abs(buf[s + i])) }
            var pos = s
            for i in 0..<win where abs(buf[s + i]) >= pk * 0.5 { pos = max(0, s + i - 32); break }
            if pos > 0 { out.append(pos) }
            lastF = f
            if out.count >= maxSlices { break }
        }
        return out
    }
}

/// sampler : records or loads a sample, chops it (transients / equal slices / whole region),
/// and plays slices on gates, clock divisions or CV — forward, reverse, random, ping-pong —
/// through an ADSR, mono (choke) or 8-voice poly.
public final class SamplerNode: DSPNode, SampleBufferNode {
    // triggers: 0 rec, 1 stop, 2 clear
    // 3 chop, 4 sensitivity, 5 order, 6 slice, 7 auto, 8 direction, 9 mode, 10 voices,
    // 11 pitch, 12 attack, 13 decay, 14 sustain, 15 release, 16 start, 17 end, 18 level, 19 monitor, 20 grid,
    // 21 PLAY (trigger), 22 loop, 23 sync, 24 sync length
    // inputs: 0 L, 1 R, 2 trig, 3 rec, 4 play (gate: restart playback)
    static let syncLengths: [Double] = [0, 1, 2, 4, 8, 16, 32]     // beats; 0 = auto
    static let chopCounts = [0, 4, 8, 16, 32, 1, -1]       // 0 = transients, 1 = whole region, -1 = grid
    /// Grid sizes in beats (index 0 = off).
    public static let gridBeats: [Double] = [0, 0.125, 0.25, 0.5, 1, 2, 4]
    static let autoDivs: [Double] = [0, 0.125, 0.25, 0.5, 1, 2, 4]

    struct Voice {
        var active = false
        var pos: Double = 0, inc: Double = 1
        var lo: Double = 0, hi: Double = 0
        var env: Float = 0
        var stage = 0           // 0 attack, 1 decay/sustain, 2 release
        var gated = false
        var fast = false
        var age = 0
    }

    private let cap: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var length = 0
    /// Samples per beat (from the clock), used by the grid chop and the waveform grid.
    public private(set) var beatSamples: Double = 24000
    private var recording = false
    private var recLen = 0
    let loadGuard = LoadGuard()
    public private(set) var contentVersion = 0

    // slice markers (written by the main thread after analysis)
    private let markers: UnsafeMutablePointer<Int>
    private var markerTotal = 0
    private let maxMarkers = 128

    private var voices = [Voice](repeating: Voice(), count: 8)
    private var lastSlice = -1
    private var pingDir = 1
    private var prevBeat: Double = 0
    private var trigGate = false
    private var recGate = EdgeDetector()
    private var rng = XorShift(seed: 0x5A3B_1E55)
    /// Slice to audition (set by the UI when you tap the waveform), -1 = none.
    public var auditionSlice = -1

    // whole-section playback (PLAY)
    private var playing = false
    /// STOP pressed: clock, trig and play inlets stay silent until PLAY (or REC).
    private var stopped = false
    private var playArmed = false
    private var playPos: Double = 0
    private var playEnv: Float = 0
    private var playBeats = 0
    private var playGate = EdgeDetector()

    /// Playback-rate factor that makes the region last a whole number of beats at the clock tempo.
    private func syncRatio(_ rs: Int, _ re: Int) -> (ratio: Double, beats: Double) {
        let spb = max(beatSamples, 1)
        let len = Double(re - rs)
        var beats = Self.syncLengths[clampIndex(params[24], Self.syncLengths.count)]
        if beats == 0 {
            // auto: nearest power-of-two number of beats (1, 2, 4, 8 … 64)
            let raw = len / spb
            beats = pow(2, max(0, min(6, (log2(max(raw, 0.5))).rounded())))
        }
        return (len / (beats * spb), beats)
    }

    public override init(spec: ModuleSpec, sampleRate: Double) {
        cap = Int(sampleRate * 60)
        bufL = .allocate(capacity: cap); bufL.initialize(repeating: 0, count: cap)
        bufR = .allocate(capacity: cap); bufR.initialize(repeating: 0, count: cap)
        markers = .allocate(capacity: 128); markers.initialize(repeating: 0, count: 128)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate(); markers.deallocate() }

    /// Main thread: install transient positions.
    public func setMarkers(_ m: [Int]) {
        let n = min(m.count, maxMarkers)
        markerTotal = 0
        for i in 0..<n { markers[i] = m[i] }
        markerTotal = n
    }

    // MARK: slices (audio thread, no allocation)

    private func region() -> (Int, Int) {
        var lo = Double(min(max(params[16], 0), 1)), hi = Double(min(max(params[17], 0), 1))
        if hi < lo { swap(&lo, &hi) }
        let L = Double(length)
        let a = Int(lo * L)
        return (a, max(a + 64, min(Int(hi * L), length)))
    }

    /// Number of slices and the bounds of slice k for the current chop mode/region.
    private var gridUnit: Int {
        var g = Self.gridBeats[clampIndex(params[20], Self.gridBeats.count)]
        if g == 0 { g = 0.25 }
        return max(64, safeInt(g * beatSamples))
    }

    private func sliceCount(_ rs: Int, _ re: Int) -> Int {
        let chop = Self.chopCounts[clampIndex(params[3], Self.chopCounts.count)]
        if chop < 0 { return min(max(1, (re - rs + gridUnit - 1) / gridUnit), 256) }
        if chop > 0 { return chop }
        var n = 1
        for i in 0..<markerTotal where markers[i] > rs + 32 && markers[i] < re - 32 { n += 1 }
        return n
    }

    private func sliceBounds(_ k: Int, _ n: Int, _ rs: Int, _ re: Int) -> (Int, Int) {
        let chop = Self.chopCounts[clampIndex(params[3], Self.chopCounts.count)]
        if chop < 0 {
            let u = gridUnit
            return (min(rs + k * u, re - 1), min(rs + (k + 1) * u, re))
        }
        if chop > 0 {
            let span = Double(re - rs)
            return (rs + Int(span * Double(k) / Double(n)), rs + Int(span * Double(k + 1) / Double(n)))
        }
        // slices = [rs] + markers inside the region; slice k runs to the next one (or the region end)
        var a = rs, b = re, idx = 0
        for i in 0..<markerTotal {
            let m = markers[i]
            guard m > rs + 32 && m < re - 32 else { continue }
            idx += 1
            if idx == k { a = m }
            if idx == k + 1 { b = m; break }
        }
        return (a, b)
    }

    private func pickSlice(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        switch clampIndex(params[5], 5) {
        case 0: lastSlice = (lastSlice + 1) % n
        case 1: lastSlice = lastSlice <= 0 ? n - 1 : lastSlice - 1
        case 2: lastSlice = min(Int(rng.next() * Float(n)), n - 1)
        case 3:
            if lastSlice < 0 { lastSlice = 0; pingDir = 1 }
            else {
                if lastSlice + pingDir >= n || lastSlice + pingDir < 0 { pingDir = -pingDir }
                lastSlice = min(max(lastSlice + pingDir, 0), n - 1)
            }
        default: lastSlice = min(clampIndex(params[6] * Float(n - 1), n), n - 1)
        }
        return lastSlice
    }

    private func hit(slice forced: Int? = nil, gated: Bool) {
        guard length > 256 else { return }
        let (rs, re) = region()
        let n = sliceCount(rs, re)
        let k = forced.map { min(max($0, 0), n - 1) } ?? pickSlice(n)
        if forced != nil { lastSlice = k }
        let (a, b) = sliceBounds(k, n, rs, re)
        guard b - a > 32 else { return }
        let dirMode = clampIndex(params[8], 3)
        let reverse = dirMode == 1 || (dirMode == 2 && rng.next() < 0.5)
        var rate = Double(exp2f(params[11] / 12))
        if params[23] > 0.5 { rate *= syncRatio(region().0, region().1).ratio }
        // mono: choke whatever is playing
        if params[10] < 0.5 {
            for v in voices.indices where voices[v].active { voices[v].stage = 2; voices[v].fast = true }
        }
        var slot = -1, oldest = -1, oldestAge = -1
        for v in voices.indices {
            if !voices[v].active { slot = v; break }
            if voices[v].age > oldestAge { oldestAge = voices[v].age; oldest = v }
        }
        if slot < 0 { slot = oldest }
        voices[slot] = Voice(active: true, pos: reverse ? Double(b - 1) : Double(a), inc: reverse ? -rate : rate,
                             lo: Double(a), hi: Double(b), env: 0, stage: 0, gated: gated, fast: false, age: 0)
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        if loadGuard.busy { oL.update(repeating: 0, count: frames); oR.update(repeating: 0, count: frames); return }
        if consumeTrigger(0) { recording = true; recLen = 0; stopped = false }
        if consumeTrigger(1) {
            if recording { finishRecording() } else {
                playing = false; playArmed = false; stopped = true
                for v in voices.indices where voices[v].active { voices[v].stage = 2; voices[v].fast = true }
            }
        }
        if consumeTrigger(2) { length = 0; recording = false; playing = false; markerTotal = 0; contentVersion &+= 1 }

        let autoDiv = Self.autoDivs[clampIndex(params[7], Self.autoDivs.count)]
        let gateMode = params[9] > 0.5
        let sr = Float(sampleRate)
        let attInc = 1 / max(params[12] * 0.001 * sr, 1)
        let decCoef = 1 - expf(-1 / max(params[13] * 0.001 * sr / 3, 1))
        let sus = min(max(params[14], 0), 1)
        let relSamples = max(params[15] * 0.001 * sr, 1)
        let relMul = expf(logf(1e-4) / relSamples)
        let fastMul = expf(logf(1e-4) / (0.005 * sr))
        let level = params[18], monitor = params[19] > 0.5
        beatSamples = ctx.samplesPerBeat
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let trig = inputs[2], recIn = inputs[3]
        let hasTrig = isConnected(connected, 2), hasRec = isConnected(connected, 3)

        if auditionSlice >= 0 { let k = auditionSlice; auditionSlice = -1; hit(slice: k, gated: false) }
        // PLAY / STOP for whole-section playback
        let sync = params[23] > 0.5, loop = params[22] > 0.5
        let hasPlayGate = isConnected(connected, 4), playIn = inputs[4]
        if consumeTrigger(21) {
            if playing || playArmed { playing = false; playArmed = false }
            else if stopped && (autoDiv > 0 || hasTrig || hasPlayGate) {
                stopped = false                          // resume clock / gate playback
            } else if length > 256 { stopped = false; if sync { playArmed = true } else { startPlay() } }
        }
        let (prs, pre) = length > 0 ? region() : (0, 0)
        let sr2 = length > 0 ? syncRatio(prs, pre) : (ratio: 1.0, beats: 4.0)
        let playRate = Double(exp2f(params[11] / 12)) * (sync ? sr2.ratio : 1)
        let fadeStep: Float = 1 / (0.004 * Float(sampleRate))

        for i in 0..<frames {
            let xl = inL[i], xr = inR[i]
            if hasRec && recGate.rising(recIn[i]) {
                if recording { finishRecording() } else { recording = true; recLen = 0 }
            }
            if recording {
                if recLen < cap { bufL[recLen] = xl; bufR[recLen] = xr; recLen += 1 } else { finishRecording() }
            }
            if hasTrig {
                let t = trig[i]
                if !trigGate && t > 0.2 { trigGate = true; if !stopped { hit(gated: gateMode) } }
                else if trigGate && t < 0.1 {
                    trigGate = false
                    if gateMode { for v in voices.indices where voices[v].gated { voices[v].gated = false; voices[v].stage = 2 } }
                }
            }
            let b = ctx.beat[i]
            if !stopped && autoDiv > 0 && crossed(prevBeat, b, autoDiv) { hit(gated: false) }
            if hasPlayGate && playGate.rising(playIn[i]) && length > 256 && !stopped { startPlay() }
            if crossed(prevBeat, b, 1) {
                if playArmed && crossed(prevBeat, b, min(sr2.beats, 4)) { playArmed = false; startPlay() }
                else if playing && sync && loop {
                    playBeats += 1
                    // re-align to the clock once per loop (absorbs tempo drift)
                    if playBeats % max(Int(sr2.beats), 1) == 0 { playPos = Double(prs) }
                }
            }
            prevBeat = b

            var sumL: Float = 0, sumR: Float = 0
            if !recording && length > 0 {
                for v in voices.indices where voices[v].active {
                    var vo = voices[v]
                    // envelope
                    switch vo.stage {
                    case 0:
                        vo.env += attInc
                        if vo.env >= 1 { vo.env = 1; vo.stage = 1 }
                    case 1:
                        vo.env += (sus - vo.env) * decCoef
                    default:
                        vo.env *= vo.fast ? fastMul : relMul
                        if vo.env < 1e-4 { vo.active = false }
                    }
                    // one-shot: start the release so it finishes right at the slice end
                    if !vo.gated && vo.stage < 2 {
                        let remaining = vo.inc > 0 ? (vo.hi - vo.pos) / vo.inc : (vo.pos - vo.lo) / -vo.inc
                        if Float(remaining) <= relSamples { vo.stage = 2 }
                    }
                    if vo.active {
                        sumL += readLinear(bufL, length, vo.pos) * vo.env
                        sumR += readLinear(bufR, length, vo.pos) * vo.env
                        vo.pos += vo.inc
                        if vo.pos >= vo.hi || vo.pos < vo.lo { vo.active = false }
                    }
                    vo.age += 1
                    voices[v] = vo
                }
            }
            // whole-section playback voice
            if playing && !recording && pre > prs {
                playEnv = min(playEnv + fadeStep, 1)
                if playPos < Double(prs) || playPos >= Double(pre) { playPos = Double(prs) }
                let remaining = (Double(pre) - playPos) / playRate
                let edge: Float = loop ? 1 : min(1, Float(remaining) * fadeStep)
                sumL += readLinear(bufL, length, playPos) * playEnv * edge
                sumR += readLinear(bufR, length, playPos) * playEnv * edge
                playPos += playRate
                if playPos >= Double(pre) {
                    if loop { playPos -= Double(pre - prs) } else { playing = false }
                }
            }
            let mon: Float = (recording && monitor) ? 1 : 0
            oL[i] = sumL * level + xl * mon
            oR[i] = sumR * level + xr * mon
        }
        if recording { contentVersion &+= 1 }

        readouts[0] = recording ? 1 : (length > 0 ? 2 : 0)
        readouts[1] = Float(Double(recording ? recLen : length) / sampleRate)
        if length > 0 && !recording {
            let (rs, re) = region()
            readouts[2] = Float(sliceCount(rs, re))
        } else { readouts[2] = 0 }
        readouts[3] = Float(lastSlice + 1)
        readouts[kBeatSamplesSlot] = Float(beatSamples)
        for v in 0..<7 {
            readouts[kPlayheadSlot + v] = voices[v].active && length > 0 ? Float(voices[v].pos / Double(length)) : -1
        }
        readouts[kPlayheadSlot + 7] = playing && length > 0 ? Float(playPos / Double(length)) : -1
        readouts[4] = playing ? 1 : (playArmed ? 2 : (stopped ? 3 : 0))
        readouts[7] = sync ? Float(sr2.beats) : 0
    }

    private func startPlay() {
        let (rs, _) = region()
        playing = true
        playArmed = false
        playPos = Double(rs)
        playEnv = 0
        playBeats = 0
    }

    private func finishRecording() {
        recording = false
        length = recLen
        markerTotal = 0
        lastSlice = -1
        contentVersion &+= 1
    }

    // MARK: SampleBufferNode
    public var waveBuffer: UnsafeMutablePointer<Float> { bufL }
    public var waveBufferR: UnsafeMutablePointer<Float> { bufR }
    public var waveLength: Int { recording ? recLen : length }
    public var waveRecording: Bool { recording }
    public var bufferCapacity: Int { cap }
    public var markerCount: Int {
        let chop = Self.chopCounts[clampIndex(params[3], Self.chopCounts.count)]
        return chop == 0 ? markerTotal : 0
    }
    public func marker(_ i: Int) -> Int { markers[min(max(i, 0), maxMarkers - 1)] }
    public func snapshot() -> StereoAudio {
        guard length > 0 else { return StereoAudio() }
        return StereoAudio(left: Array(UnsafeBufferPointer(start: bufL, count: length)),
                           right: Array(UnsafeBufferPointer(start: bufR, count: length)))
    }
    public func load(_ audio: StereoAudio) {
        loadGuard.whileBusy {
            let c = min(audio.count, cap)
            audio.copy(into: bufL, bufR, count: c)
            length = c; recording = false; markerTotal = 0; lastSlice = -1
            for v in voices.indices { voices[v].active = false }
            contentVersion &+= 1
        }
    }
    /// Main thread: run transient detection on the current audio.
    public func analyze() {
        guard !recording, length > 0 else { return }
        var mono = [Float](repeating: 0, count: length)
        for i in 0..<length { mono[i] = (bufL[i] + bufR[i]) * 0.5 }
        let m = mono.withUnsafeBufferPointer {
            Transients.detect($0.baseAddress!, count: length, sampleRate: sampleRate, sensitivity: base[4])
        }
        setMarkers(m)
    }
    /// Main thread: which slice is under a position 0…1 of the whole buffer.
    public func slice(at x: Double) -> Int {
        guard length > 0 else { return 0 }
        let (rs, re) = region()
        let n = sliceCount(rs, re)
        let p = Int(x * Double(length))
        for k in 0..<n {
            let (a, b) = sliceBounds(k, n, rs, re)
            if p >= a && p < b { return k }
        }
        return p < rs ? 0 : n - 1
    }
}
