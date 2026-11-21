import Foundation

// Note sources: keyboard + arpeggiator, step sequencer, Turing-style shift register, piano roll, drum roll.
// Pitch outputs are 1 V/oct in the app's scale (0.1 = one octave; 0 = middle C), gates are 0.5 (≈ +5 V).

let kGateHigh: Float = 0.5
@inline(__always) func pitchCV(_ semitonesFromMiddleC: Float) -> Float { semitonesFromMiddleC / 120 }

public enum Scales {
    public static let names = ["chromatic", "major", "minor", "dorian", "phrygian", "mixolydian",
                               "pentatonic maj", "pentatonic min", "blues", "whole tone"]
    static let degrees: [[Int]] = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10],
                                   [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10], [0, 2, 4, 5, 7, 9, 10],
                                   [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 3, 5, 6, 7, 10], [0, 2, 4, 6, 8, 10]]
    /// Nearest scale note (semitones, any octave).
    @inline(__always) static func quantize(_ semis: Float, _ scale: Int) -> Float {
        let d = degrees[min(max(scale, 0), degrees.count - 1)]
        let n = semis.rounded()
        let oct = floor(n / 12), within = n - oct * 12
        var best = Float(d[0]), bestDist: Float = 99
        for deg in d {
            var o = -12
            while o <= 12 {                       // no array literal: this runs on the audio thread
                let c = Float(deg + o)
                let dist = abs(c - within)
                if dist < bestDist { bestDist = dist; best = c }
                o += 12
            }
        }
        return oct * 12 + best
    }
}

/// Advances a step either on its own clock inlet or on the global clock at a division.
struct StepClock {
    var prevBeat: Double = 0
    var edge = EdgeDetector()
    var resetEdge = EdgeDetector()
    var samplesSinceStep = 0
    var stepSamples = 12000
    var primed = false
    // a patched clock: its pulses count as 1/16 notes, so the division still applies
    // (1/8 = every 2nd pulse, 1/32 = twice per pulse, triplets in between)
    var pulses = -1
    var samplesSincePulse = 0
    var pulsePeriod = 3000
    var prevPulsePos: Double = -1
    /// Reset: the next pulse is step one again.
    mutating func restart() { pulses = -1; prevPulsePos = -1 }
    /// Returns true on samples where a new step starts.
    @inline(__always) mutating func tick(beat: Double, div: Double, spb: Double,
                                         clockIn: Float?, sampleRate: Double, running: Bool = true) -> Bool {
        samplesSinceStep += 1
        var fire = false
        if let c = clockIn, !running {
            _ = edge.rising(c)                 // transport stopped: pulses don't count
            return false
        }
        if let c = clockIn {
            samplesSincePulse += 1
            if edge.rising(c) {
                if pulses >= 0 && samplesSincePulse > 16 { pulsePeriod = samplesSincePulse }
                pulses += 1
                samplesSincePulse = 0
            }
            if pulses >= 0 {
                let r = max(div / 0.25, 1e-3)        // steps are this many pulses long
                let pos = Double(pulses) + min(Double(samplesSincePulse) / Double(max(pulsePeriod, 1)), 0.999)
                fire = (pos / r).rounded(.down) != (prevPulsePos / r).rounded(.down)
                prevPulsePos = pos
                stepSamples = max(16, safeInt(r * Double(pulsePeriod)))
            }
        } else {
            // the first sample counts as a step start, so step 1 plays when the clock starts
            fire = !primed || crossed(prevBeat, beat, div)
            primed = true
            stepSamples = max(16, safeInt(div * spb))
        }
        prevBeat = beat
        if fire { samplesSinceStep = 0 }
        return fire
    }
}

// MARK: - keys : keyboard + arpeggiator

public final class KeysNode: DSPNode {
    // 0 octave, 1 glide, 2 arp mode, 3 arp rate, 4 gate length, 5 arp octaves, 6 latch, 7 scale-free velocity
    // outputs: pitch, gate, vel
    public static let keyCount = 25        // two octaves C…C
    static let arpModes = ["off", "up", "down", "up-down", "random", "as played"]

    /// UI: key under the finger (0…24), -1 = none.
    public var touchNote = -1
    /// UI: bumped on every key press, with the pressed key — so a tap shorter than an audio block
    /// (or one the touch system reports late, press and release together) still plays a note.
    public var pressCount = 0
    public var pressNote = -1
    private var seenPress = 0
    private var holdLeft = 0
    private var anyHeldBefore = false
    /// UI: latched keys (1 = held), and the order they were added (for "as played").
    public let latched: UnsafeMutablePointer<Float>
    private let order: UnsafeMutablePointer<Int>
    private var orderCounter = 0

    private var pitchNow: Float = 0
    private var note = -1
    private var gateLeft = 0
    private var gateOn = false
    private var dip = 0
    private var arpIndex = -1
    private var arpDir = 1
    private var clock = StepClock()
    private var lastTouch = -1
    private var rng = XorShift(seed: 0xA4B9_17E3)
    private let scratch: UnsafeMutablePointer<Int>

    // MARK: played-notes automation (the box's record button): a 4-bar loop of which key is down
    /// Key held in each automation slot (−1 = none), same loop as parameter automation.
    public let keyLane: UnsafeMutablePointer<Float>
    public private(set) var keyLaneOn = false
    /// UI: the record button is held / latched.
    public var recordingKeys = false
    /// UI: something was played into the lane during this recording (read and cleared when it stops).
    public var recordedKeys = false
    private var recStarted = false
    private var recLast = -1
    private var laneKeyPrev = -1
    public static let laneKey = DSPNode.autoKey("keys")

    public override var defaultData: [String: [Float]] {
        [Self.laneKey: [Float](repeating: -1, count: DSPNode.autoSlots)]
    }
    public override func setData(_ key: String, _ values: [Float]) {
        guard key == Self.laneKey else { return }
        var any = false
        for k in 0..<DSPNode.autoSlots {
            let v = k < values.count && values[k].isFinite ? values[k] : -1
            keyLane[k] = v
            if v >= 0 { any = true }
        }
        keyLaneOn = any
    }

    public override init(spec: ModuleSpec, sampleRate: Double) {
        keyLane = .allocate(capacity: DSPNode.autoSlots); keyLane.initialize(repeating: -1, count: DSPNode.autoSlots)
        latched = .allocate(capacity: Self.keyCount); latched.initialize(repeating: 0, count: Self.keyCount)
        order = .allocate(capacity: Self.keyCount); order.initialize(repeating: 0, count: Self.keyCount)
        scratch = .allocate(capacity: Self.keyCount * 3); scratch.initialize(repeating: 0, count: Self.keyCount * 3)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { latched.deallocate(); order.deallocate(); scratch.deallocate(); keyLane.deallocate() }

    /// UI: tap a key while latch is on.
    public func toggleLatched(_ k: Int) {
        guard k >= 0 && k < Self.keyCount else { return }
        if latched[k] > 0.5 { latched[k] = 0 } else { orderCounter += 1; order[k] = orderCounter; latched[k] = 1 }
    }
    public func clearLatched() { for k in 0..<Self.keyCount { latched[k] = 0 } }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let base = Float(params[0].rounded()) * 12 - 12          // bottom key = C3 at octave 0
        let glide = onePoleCoef(ms: params[1], sampleRate: sampleRate)
        let mode = clampIndex(params[2], Self.arpModes.count)
        let div = Divisions.beats(params[3])
        let gateLen = min(max(params[4], 0.05), 1)
        let octs = clampIndex(params[5] - 1, 3) + 1
        let latch = params[6] > 0.5
        let pOut = outputs[0], gOut = outputs[1], vOut = outputs[2]
        var touch = touchNote
        let pc = pressCount
        var pn = pressNote
        var newPress = pc != seenPress && pn >= 0 && pn < Self.keyCount
        seenPress = pc

        // played-notes automation: record what's played into the loop, or play the loop back
        let slot = min(max(Int(autoPosition), 0), DSPNode.autoSlots - 1)
        if recordingKeys {
            let k = touch >= 0 ? touch : (newPress ? pn : -1)
            if !recStarted && k >= 0 { recStarted = true; recLast = (slot + DSPNode.autoSlots - 1) % DSPNode.autoSlots }
            if recStarted {
                // fill every slot since the last block (whatever is down now, or a rest)
                var s = recLast, n = 0
                while s != slot && n < DSPNode.autoSlots { s = (s + 1) % DSPNode.autoSlots; keyLane[s] = Float(k); n += 1 }
                if newPress { keyLane[slot] = Float(pn) }            // a tap shorter than a slot still counts
                recLast = slot
                recordedKeys = true
                keyLaneOn = true
            }
        } else {
            recStarted = false
        }
        var laneKey = -1
        if keyLaneOn && !recordingKeys && ctx.running && touch < 0 {
            let v = Int(keyLane[slot])
            laneKey = v >= 0 && v < Self.keyCount ? v : -1
        }
        if laneKey >= 0 {
            touch = laneKey
            if laneKey != laneKeyPrev && !newPress { newPress = true; pn = laneKey }     // a new played note
        }
        laneKeyPrev = laneKey

        // the set of notes the arp (or the plain keyboard) can play
        var count = 0
        if latch {
            for k in 0..<Self.keyCount where latched[k] > 0.5 { scratch[count] = k; count += 1 }
        }
        if touch >= 0 && !(latch && latched[touch] > 0.5) { scratch[count] = touch; count += 1 }
        if mode == 5 {   // as played: sort by insertion order (touch last)
            for a in 0..<count { for b in (a + 1)..<max(count, a + 1) where order[scratch[b]] < order[scratch[a]] {
                let t = scratch[a]; scratch[a] = scratch[b]; scratch[b] = t } }
        }
        // expand over octaves
        var total = 0
        for o in 0..<octs { for k in 0..<count { scratch[Self.keyCount + total] = scratch[k] + o * 12; total += 1; if total >= Self.keyCount * 2 { break } } }

        let minHold = Int(sampleRate * 0.08)
        for i in 0..<frames {
            if mode == 0 {
                // plain keyboard: gate while a key is held (or latched), at least 80 ms per tap; a short
                // dip when moving to a new key so envelopes retrigger
                if newPress && i == 0 {
                    if gateOn && pn != note { dip = 48 }
                    note = pn
                    holdLeft = minHold
                }
                let held = touch >= 0 ? touch : (holdLeft > 0 ? note : (latch && count > 0 ? scratch[count - 1] : -1))
                if holdLeft > 0 { holdLeft -= 1 }
                if held >= 0 { note = held }
                if touch >= 0 && lastTouch >= 0 && touch != lastTouch { dip = 48 }
                gateOn = held >= 0 && dip == 0
                if dip > 0 { dip -= 1 }
            } else {
                let fire = clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: nil, sampleRate: sampleRate)
                // first key down: sound right away instead of waiting for the next step
                if newPress && i == 0 && !anyHeldBefore {
                    note = pn
                    arpIndex = -1
                    gateLeft = max(Int(sampleRate * 0.08), Int(Float(clock.stepSamples) * gateLen))
                }
                if fire && total > 0 {
                    switch mode {
                    case 1: arpIndex = (arpIndex + 1) % total
                    case 2: arpIndex = arpIndex <= 0 ? total - 1 : arpIndex - 1
                    case 3:
                        if total == 1 { arpIndex = 0 } else {
                            if arpIndex + arpDir >= total || arpIndex + arpDir < 0 { arpDir = -arpDir }
                            arpIndex = min(max(arpIndex + arpDir, 0), total - 1)
                        }
                    case 4: arpIndex = min(Int(rng.next() * Float(total)), total - 1)
                    default: arpIndex = (arpIndex + 1) % total
                    }
                    note = scratch[Self.keyCount + min(arpIndex, total - 1)]
                    gateLeft = max(16, Int(Float(clock.stepSamples) * gateLen))
                }
                if total == 0 { arpIndex = -1 }
                gateOn = false
            }
            lastTouch = touch
            let target = (base + Float(max(note, 0)))
            pitchNow += (target - pitchNow) * glide
            pOut[i] = pitchCV(pitchNow)
            gOut[i] = (mode == 0 ? gateOn : gateLeft > 0) ? kGateHigh : 0
            if gateLeft > 0 { gateLeft -= 1 }
            vOut[i] = note >= 0 ? 0.8 : 0
        }
        anyHeldBefore = total > 0
        readouts[0] = Float(gOut[frames - 1] > 0 ? note : -1)
    }
}

// MARK: - seq : 16-step sequencer

public final class SeqNode: DSPNode {
    // 0 length, 1 division, 2 direction, 3 gate length, 4 scale, 5 transpose
    // inputs: clock, reset   outputs: pitch, gate
    public static let steps = 64
    /// The lengths it plays: every one up to 16, then 32 and 64.
    public static let lengths: [Float] = (1...16).map(Float.init) + [32, 64]
    @inline(__always) public static func length(_ v: Float) -> Int {
        guard v.isFinite else { return 8 }
        if v <= 16 { return min(max(Int(v.rounded()), 1), 16) }
        return v < 48 ? 32 : 64
    }
    public let pitches: UnsafeMutablePointer<Float>    // semitones from middle C
    public let gates: UnsafeMutablePointer<Float>      // 0 / 1
    private var step = -1
    /// Last step whose gate was on: switched-off steps keep its pitch (sample & hold), so a voice's
    /// release doesn't slide to bars that aren't played.
    private var heldStep = -1
    private var dir = 1
    private var gateLeft = 0
    private var clock = StepClock()
    private var rng = XorShift(seed: 0x5E9_0001)

    public override init(spec: ModuleSpec, sampleRate: Double) {
        pitches = .allocate(capacity: Self.steps); pitches.initialize(repeating: 0, count: Self.steps)
        gates = .allocate(capacity: Self.steps); gates.initialize(repeating: 1, count: Self.steps)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { pitches.deallocate(); gates.deallocate() }
    public override var defaultData: [String: [Float]] {
        ["pitch": [Float](repeating: 0, count: Self.steps), "gate": [Float](repeating: 1, count: Self.steps)]
    }

    public override func setData(_ key: String, _ values: [Float]) {
        let dst = key == "pitch" ? pitches : (key == "gate" ? gates : nil)
        guard let dst else { return }
        // an older, shorter pattern (16 steps) repeats to fill the rest
        guard !values.isEmpty else { return }
        for k in 0..<Self.steps { let v = values[k % values.count]; dst[k] = v.isFinite ? v : 0 }
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let len = Self.length(params[0])
        let div = Divisions.beats(params[1])
        let direction = clampIndex(params[2], 4)
        let gateLen = min(max(params[3], 0.05), 1)
        let scale = clampIndex(params[4], Scales.names.count)
        let transpose = params[5].rounded()
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let ck = inputs[0], rs = inputs[1]
        let pOut = outputs[0], gOut = outputs[1]
        if ctx.stopPending { step = -1; dir = 1; clock.restart() }
        // the pitch only changes with the step (or a knob): quantise it then, not on every sample
        var cvStep = -2, cv: Float = 0
        for i in 0..<frames {
            if hasReset && clock.resetEdge.rising(rs[i]) { step = -1; dir = 1; clock.restart() }
            if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: hasClock ? ck[i] : nil, sampleRate: sampleRate, running: ctx.running) {
                switch direction {
                case 1: step = step <= 0 ? len - 1 : step - 1
                case 2:
                    if len == 1 { step = 0 } else {
                        if step + dir >= len || step + dir < 0 { dir = -dir }
                        step = min(max(step + dir, 0), len - 1)
                    }
                case 3: step = min(Int(rng.next() * Float(len)), len - 1)
                default: step = (step + 1) % len
                }
                if !hasClock && direction == 0 {
                    // lock to the bar so patterns line up with loopers
                    step = safeInt(floor(ctx.beat[i] / div)) % len
                }
                gateLeft = gates[step] > 0.5 ? max(16, Int(Float(clock.stepSamples) * gateLen)) : 0
                if gates[step] > 0.5 { heldStep = step }
            }
            let s = heldStep >= 0 ? heldStep : max(step, 0)
            if s != cvStep { cvStep = s; cv = pitchCV(Scales.quantize(pitches[s] + transpose, scale)) }
            pOut[i] = cv
            gOut[i] = gateLeft > 0 ? kGateHigh : 0
            if gateLeft > 0 { gateLeft -= 1 }
        }
        readouts[0] = Float(step)
    }
}

// MARK: - turing : looping random shift register

public final class TuringNode: DSPNode {
    // 0 change, 1 length, 2 range (octaves), 3 scale, 4 division, 5 gate length, 6 octave shift, 7 notes (density)
    // inputs: clock, reset   outputs: pitch, gate, cv
    // readouts: 0 register, 1 length, 2 cv, 4 which loop steps play (bits), 5 range,
    //           8… the loop's notes from the current step on (semitones)
    public static let historyLength = 16
    /// The loop lengths: every one from 2 to 16, then 32 and 64.
    public static let lengths: [Float] = (2...16).map(Float.init) + [32, 64]
    @inline(__always) public static func length(_ v: Float) -> Int {
        guard v.isFinite else { return 8 }
        if v <= 16 { return min(max(Int(v.rounded()), 2), 16) }
        return v < 48 ? 32 : 64
    }
    public static let maxLength = 64
    private static let seed: UInt64 = 0x3B91_6E2D_A5C3
    private var reg: UInt64 = TuringNode.seed
    /// For the display (written by the audio thread, read when drawing): the register, which loop steps
    /// play (bits), and the loop's notes from the current step on.
    public private(set) var regNow: UInt64 = TuringNode.seed
    public private(set) var playsBits: UInt64 = 0
    public let loopNotes: UnsafeMutablePointer<Float>
    private var displayCountdown = 0

    public override init(spec: ModuleSpec, sampleRate: Double) {
        loopNotes = .allocate(capacity: Self.maxLength)
        loopNotes.initialize(repeating: 0, count: Self.maxLength)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { loopNotes.deallocate() }
    private var gateLeft = 0
    private var clock = StepClock()
    private var rng = XorShift(seed: 0x7E57_1A9B)
    private var cvNow: Float = 0
    private var noteNow: Float = 0
    private var head = 0

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let change = min(max(params[0], 0), 1)
        let len = UInt64(Self.length(params[1]))
        let range = Float(clampIndex(params[2] - 1, 4) + 1)
        let scale = clampIndex(params[3], Scales.names.count)
        let div = Divisions.beats(params[4])
        let gateLen = min(max(params[5], 0.05), 1)
        let octave = Float(clampIndex(params[6] + 3, 7) - 3) * 12
        let density = min(max(params[7], 0), 1)
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let ck = inputs[0], rs = inputs[1]
        let pOut = outputs[0], gOut = outputs[1], cOut = outputs[2]
        let mask: UInt64 = len >= 64 ? ~0 : (1 << len) - 1
        if ctx.stopPending { clock.restart() }
        for i in 0..<frames {
            if hasReset && clock.resetEdge.rising(rs[i]) { reg = Self.seed; clock.restart() }
            if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: hasClock ? ck[i] : nil, sampleRate: sampleRate, running: ctx.running) {
                // the bit leaving the loop comes back in — flipped with probability `change`
                var bit = (reg >> (len - 1)) & 1
                if rng.next() < change { bit ^= 1 }
                reg = ((reg << 1) | bit) & mask
                let window = reg & 0xFF
                cvNow = Float(window) / 255
                // does this step play? a number derived from the register (so a locked loop keeps the
                // same rhythm) against the "notes" amount: 0 = silent, 1 = every step
                let plays = Self.plays(reg, density)
                gateLeft = plays ? max(16, Int(Float(clock.stepSamples) * gateLen)) : 0
                // silent steps hold the last played pitch (sample & hold), so a voice's release
                // doesn't glide to notes that aren't played
                if plays { noteNow = Scales.quantize(cvNow * range * 12, scale) + octave }
                head = (head + 1) % Self.historyLength
            }
            pOut[i] = pitchCV(noteNow)
            gOut[i] = gateLeft > 0 ? kGateHigh : 0
            cOut[i] = cvNow
            if gateLeft > 0 { gateLeft -= 1 }
        }
        readouts[0] = Float(reg & 0xFFFF)
        readouts[1] = Float(len)
        readouts[2] = cvNow
        readouts[3] = Float((reg >> 16) & 0xFFFF)          // the rest of the register (for the display's fingerprint)
        readouts[5] = range
        readouts[6] = Float((reg >> 32) & 0xFFFF)
        readouts[7] = Float((reg >> 48) & 0xFFFF)
        regNow = reg & mask
        // the display: the loop as it will play from here with the current settings — step 0 is the one
        // sounding now, then the next ones (as if nothing mutates), so changing notes / length / range /
        // scale / octave shows straight away. (Worked out every few blocks: up to 64 notes.)
        displayCountdown -= 1
        if displayCountdown <= 0 {
            displayCountdown = 4
            var st = reg & mask, bits: UInt64 = 0
            for k in 0..<Int(len) {
                if Self.plays(st, density) { bits |= 1 << UInt64(k) }
                loopNotes[k] = Scales.quantize(Float(st & 0xFF) / 255 * range * 12, scale) + octave
                st = ((st << 1) | ((st >> (len - 1)) & 1)) & mask
            }
            playsBits = bits
            // a fingerprint of the shown loop, so the display redraws when any of it changes
            var h: UInt32 = UInt32(truncatingIfNeeded: bits ^ (bits >> 32))
            for k in 0..<Int(len) { h = h &* 31 &+ UInt32(bitPattern: Int32(loopNotes[k])) }
            readouts[4] = Float(h & 0xFF_FFFF)
        }
    }

    /// Whether a step with register `r` plays, for the "notes" amount (0 = none … 1 = every step).
    /// Derived from the register so a locked loop keeps its rhythm.
    @inline(__always) static func plays(_ r: UInt64, _ density: Float) -> Bool {
        density >= 1 || Float(((r &* 0x9E37_79B1) >> 24) & 0xFF) / 256 < density
    }
}

// MARK: - roll : piano roll (monophonic)

public final class RollNode: DSPNode {
    // 0 length, 1 division, 2 lowest note, 3 gate length
    // outputs: pitch, gate, vel — a step with a chord sends all its notes down the same cables (up to 4;
    // the lowest first, which is what a mono module plays)
    public static let steps = 32
    public static let rows = 24
    /// Notes on / off: row * steps + step (row 0 = lowest). Any number of notes per step.
    public let grid: UnsafeMutablePointer<Float>
    private var step = -1
    private var gateLeft = 0
    private var clock = StepClock()
    public static let voices = kMaxVoices
    /// each note's pitch row, kept while it's silent (so a release doesn't slide)
    private var held = [Float](repeating: 0, count: RollNode.voices)
    private var on = [Bool](repeating: false, count: RollNode.voices)

    public override init(spec: ModuleSpec, sampleRate: Double) {
        grid = .allocate(capacity: Self.steps * Self.rows); grid.initialize(repeating: 0, count: Self.steps * Self.rows)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { grid.deallocate() }
    public override var defaultData: [String: [Float]] { ["grid": [Float](repeating: 0, count: Self.steps * Self.rows)] }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "grid" else { return }
        for k in 0..<Self.steps * Self.rows { grid[k] = k < values.count && values[k].isFinite && values[k] > 0.5 ? 1 : 0 }
    }

    @inline(__always) public func isOn(_ step: Int, _ row: Int) -> Bool { grid[row * Self.steps + step] > 0.5 }

    /// The old one-note-per-step pattern (a row per step, -1 = rest) as a grid.
    public static func grid(fromNotes notes: [Float]) -> [Float] {
        var g = [Float](repeating: 0, count: steps * rows)
        for s in 0..<min(notes.count, steps) {
            let r = notes[s]
            if r.isFinite, r >= 0, Int(r) < rows { g[Int(r) * steps + s] = 1 }
        }
        return g
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let len = clampIndex(params[0] - 1, Self.steps) + 1
        let div = Divisions.beats(params[1])
        let low = params[2].rounded()
        let gateLen = min(max(params[3], 0.05), 1)
        // notes on the cables: the most any step of the loop has (kept steady, so releases ring out)
        var V = 1
        for s in 0..<len {
            var c = 0
            for r in 0..<Self.rows where grid[r * Self.steps + s] > 0.5 { c += 1 }
            V = max(V, c)
        }
        V = min(V, Self.voices)
        for k in 0..<3 { outVoices[k] = V }
        for i in 0..<frames {
            if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: nil, sampleRate: sampleRate) {
                step = safeInt(floor(ctx.beat[i] / div)) % len
                // this step's notes, lowest first, one per voice
                var v = 0
                for r in 0..<Self.rows where grid[r * Self.steps + step] > 0.5 && v < Self.voices {
                    held[v] = Float(r); on[v] = true; v += 1
                }
                for k in v..<Self.voices { on[k] = false }
                gateLeft = v > 0 ? max(16, Int(Float(clock.stepSamples) * gateLen)) : 0
            }
            for v in 0..<V {
                let g = gateLeft > 0 && on[v]
                outVoice(0, v)[i] = pitchCV(low + held[v])
                outVoice(1, v)[i] = g ? kGateHigh : 0
                outVoice(2, v)[i] = g ? 0.8 : 0
            }
            if gateLeft > 0 { gateLeft -= 1 }
        }
        readouts[0] = Float(step)
    }
}

// MARK: - drums : drum roll, 8 lanes of triggers

public final class DrumsNode: DSPNode {
    // 0 length, 1 division, 2 trigger length (ms)
    // outputs: 1…8 triggers
    public static let steps = 32
    public static let lanes = 8
    public let hits: UnsafeMutablePointer<Float>       // lane * steps + step
    private var step = -1
    private var left = [Int](repeating: 0, count: 8)
    private var clock = StepClock()

    public override init(spec: ModuleSpec, sampleRate: Double) {
        hits = .allocate(capacity: Self.steps * Self.lanes); hits.initialize(repeating: 0, count: Self.steps * Self.lanes)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { hits.deallocate() }
    public override var defaultData: [String: [Float]] { ["hits": [Float](repeating: 0, count: Self.steps * Self.lanes)] }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "hits" else { return }
        for k in 0..<min(values.count, Self.steps * Self.lanes) { hits[k] = values[k].isFinite ? values[k] : 0 }
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let len = clampIndex(params[0] - 1, Self.steps) + 1
        let div = Divisions.beats(params[1])
        let trig = max(16, safeInt(Double(params[2]) * 0.001 * sampleRate))
        for i in 0..<frames {
            if clock.tick(beat: ctx.beat[i], div: div, spb: ctx.samplesPerBeat, clockIn: nil, sampleRate: sampleRate) {
                step = safeInt(floor(ctx.beat[i] / div)) % len
                for l in 0..<Self.lanes where hits[l * Self.steps + step] > 0.5 { left[l] = trig }
            }
            for l in 0..<Self.lanes {
                outputs[l][i] = left[l] > 0 ? kGateHigh : 0
                if left[l] > 0 { left[l] -= 1 }
            }
        }
        readouts[0] = Float(step)
    }
}

// MARK: - div : clock divider, 8 outputs

public enum DividerLayout {
    public static let outputs = 8
    public static func divIndex(_ k: Int) -> Int { 3 + k }        // parameters d1…d8
    /// Internal clock rates: everything the other modules offer plus 1/64.
    public static let baseNames = ["1/64"] + Divisions.names
    @inline(__always) static func baseBeats(_ v: Float) -> Double {
        let i = clampIndex(v, baseNames.count)
        return i == 0 ? 0.0625 : Divisions.beats(Float(i - 1))
    }
    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.choice("mode", "output", ["pulse", "50% gate"], def: 0),
                              .choice("base", "int clock", baseNames, def: baseNames.firstIndex(of: "1/16") ?? 3),
                              .integer("offset", "offset", 0, 63, 0)]
        for k in 1...outputs { p.append(.choice("d\(k)", "out \(k)", ratioNames, def: ratioIndex(defaults[k - 1]))) }
        return p
    }
    /// Per outlet: faster (× the clock) or slower (÷ the clock).
    public static let multipliers = [16, 12, 8, 6, 4, 3, 2]
    public static let ratioNames = multipliers.map { "×\($0)" } + ["×1"] + (2...64).map { "÷\($0)" }
    /// Ratio as a signed count: +n = ÷n (1 = the clock itself), −m = ×m.
    @inline(__always) public static func ratio(_ v: Float) -> Int {
        let i = clampIndex(v, ratioNames.count)
        return i < multipliers.count ? -multipliers[i] : i - multipliers.count + 1
    }
    public static func ratioIndex(_ r: Int) -> Int {
        r < 0 ? (multipliers.firstIndex(of: -r) ?? multipliers.count) : multipliers.count + max(r, 1) - 1
    }
    static let defaults = [-4, -2, 1, 2, 3, 4, 8, 16]
}

/// Counts clock pulses and fires each outlet every N of them. "pulse" passes the incoming pulse through on
/// the counted beats (keeps its width); "50% gate" gives a square wave N clocks long. With nothing in the
/// clock inlet it runs from the app clock at the chosen division. Reset (or the first pulse) lines all up.
final class DividerNode: DSPNode {
    // 0 mode, 1 base, 2 offset, 3…10 divisions;  inputs: 0 clock, 1 reset;  outputs: 8 gates
    private var clockEdge = EdgeDetector()
    private var resetEdge = EdgeDetector()
    private var count = -1             // pulses since reset (−1: none yet)
    private var clockHigh = false
    private var sinceEdge = 0           // samples since the last clock pulse (patched clock)
    private var period = 12000          // samples between clock pulses
    private let lastFire = UnsafeMutablePointer<Bool>.allocate(capacity: DividerLayout.outputs)

    override init(spec: ModuleSpec, sampleRate: Double) {
        lastFire.initialize(repeating: false, count: DividerLayout.outputs)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { lastFire.deallocate() }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let hasClock = isConnected(connected, 0), hasReset = isConnected(connected, 1)
        let clk = inputs[0], rst = inputs[1]
        let square = params[0] > 0.5
        let base = DividerLayout.baseBeats(params[1])
        let offset = max(Int(params[2].isFinite ? params[2].rounded() : 0), 0)
        var divs = (0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &divs) { raw in
            let d = raw.bindMemory(to: Int.self)
            for k in 0..<DividerLayout.outputs { d[k] = DividerLayout.ratio(params[DividerLayout.divIndex(k)]) }
        }
        let internalPeriod = max(base * ctx.samplesPerBeat, 1)
        if ctx.stopPending { count = -1 }
        if !ctx.running {
            // transport stopped / paused: outputs rest, patched pulses don't count
            for i in 0..<frames { _ = clockEdge.rising(hasClock ? clk[i] : 0) }
            for k in 0..<DividerLayout.outputs { outputs[k].update(repeating: 0, count: frames) }
            readouts[0] = Float(count)
            return
        }
        for i in 0..<frames {
            if hasReset && resetEdge.rising(rst[i]) { count = -1 }
            // the clock: the inlet, or the app clock (high for the first half of each step)
            let c: Float
            var phase: Double                      // how far through the current clock period (0 ..< 1)
            if hasClock {
                c = clk[i]
                sinceEdge += 1
                phase = min(Double(sinceEdge) / Double(max(period, 1)), 0.999)
            } else {
                let pos = ctx.beat[i] / base
                phase = pos - pos.rounded(.down)
                c = phase < 0.5 ? 1 : 0
                period = Int(internalPeriod)
            }
            if clockEdge.rising(c) {
                count += 1
                if hasClock {
                    if sinceEdge > 16 && count > 0 { period = sinceEdge }
                    sinceEdge = 0
                    phase = 0
                }
            }
            clockHigh = clockEdge.high
            withUnsafeBytes(of: &divs) { raw in
                let d = raw.bindMemory(to: Int.self)
                for k in 0..<DividerLayout.outputs {
                    let o = outputs[k]
                    guard count >= 0 else { o[i] = 0; continue }
                    let n = d[k]
                    if n < 0 {
                        // × m: m evenly spaced pulses per clock (from the measured clock period)
                        let m = Double(-n)
                        let sub = phase * m
                        let f = sub - sub.rounded(.down)
                        let width = square ? 0.5 : min(0.5, 0.005 * sampleRate * m / Double(max(period, 1)))
                        o[i] = f < width ? kGateHigh : 0
                        continue
                    }
                    let pos = (count + offset) % n
                    let on: Bool
                    if square {
                        // n = 1: follow the clock; otherwise high for the first half of every n clocks
                        on = n == 1 ? clockHigh : pos < (n + 1) / 2
                    } else {
                        on = pos == 0 && clockHigh
                    }
                    o[i] = on ? kGateHigh : 0
                }
            }
        }
        readouts[0] = Float(count)
    }
}
