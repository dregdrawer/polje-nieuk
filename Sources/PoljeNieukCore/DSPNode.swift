import Foundation

/// Largest block a node is ever asked to process. Hardware buffers are split into chunks of this size.
/// Also the control rate for patched parameters: 64 samples ≈ 1.3 ms at 48 kHz.
public let kMaxBlock = 64

/// Cables whose `toPort` is at or above this number go to a parameter (port - base = parameter index).
public let kParamPortBase = 1000

/// Notes one cable can carry (a chord). A poly outlet's buffer holds them one after another (note v at
/// `outputs[k] + v * kMaxBlock`); note 0 is the outlet's ordinary buffer, so mono modules read the first one.
public let kMaxVoices = 4

/// Per-parameter info the audio thread needs, without touching Swift strings/arrays.
public struct ParamRT {
    var min: Float
    var max: Float
    var exp: Bool
    var cubic: Bool
    var round: Bool
    var trigger: Bool
    /// a semitone parameter (frequency, pitch, tune …): patched CV moves it 1 V/oct (0.1 = 12 st)
    var semis: Bool = false
}

/// Shared per-block state handed to every node: hardware I/O and the musical clock.
public final class ProcessContext {
    public internal(set) var sampleRate: Double
    public internal(set) var frames: Int = 0
    public let maxChannels: Int
    /// Hardware input channels for this block (e.g. disting NT USB channels).
    public let inputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public internal(set) var inputCount = 0
    /// Hardware output channels for this block. Nodes add into these.
    public let outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    public internal(set) var outputCount = 0
    /// Musical position in beats (quarter notes) for every sample of the block.
    public let beat: UnsafeMutablePointer<Double>
    public var samplesPerBeat: Double
    public var externalClock = false
    /// Transport: false = paused or stopped (the beat holds still; clocked modules wait).
    public internal(set) var running = true
    /// True for the one block after ■ stop: clocked modules go back to their first step.
    public internal(set) var stopPending = false
    var lastBeat: Double = 0
    private let dummy: UnsafeMutablePointer<Float>

    // MARK: MIDI (MIDIIO.swift)
    public static let midiCapacity = 512
    /// What arrived from MIDI devices this block (only the first block of an audio buffer has any).
    public let midiIn: UnsafeMutablePointer<MidiMsg>
    public internal(set) var midiInCount = 0
    /// What modules send; it goes out at the end of the audio buffer.
    public let midiOut: UnsafeMutablePointer<MidiMsg>
    public internal(set) var midiOutCount = 0
    /// Where this block starts within the audio buffer.
    var blockOffset = 0
    /// Send a MIDI message at sample `offset` of this block (port 0 = every MIDI out that's on).
    @inline(__always) public func sendMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, offset: Int, port: Int32 = 0) {
        guard midiOutCount < Self.midiCapacity, port >= 0 else { return }
        midiOut[midiOutCount] = MidiMsg(port: port, status: status, d1: d1 & 0x7F, d2: d2 & 0x7F, global: true,
                                        offset: UInt16(clamping: blockOffset + max(offset, 0)))
        midiOutCount += 1
    }

    init(sampleRate: Double, maxChannels: Int = 64) {
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels
        dummy = .allocate(capacity: kMaxBlock)
        dummy.initialize(repeating: 0, count: kMaxBlock)
        inputs = .allocate(capacity: maxChannels)
        inputs.initialize(repeating: dummy, count: maxChannels)
        outputs = .allocate(capacity: maxChannels)
        outputs.initialize(repeating: dummy, count: maxChannels)
        beat = .allocate(capacity: kMaxBlock)
        beat.initialize(repeating: 0, count: kMaxBlock)
        samplesPerBeat = sampleRate * 0.5
        let empty = MidiMsg(port: 0, status: 0, d1: 0, d2: 0, global: false, offset: 0)
        midiIn = .allocate(capacity: Self.midiCapacity); midiIn.initialize(repeating: empty, count: Self.midiCapacity)
        midiOut = .allocate(capacity: Self.midiCapacity); midiOut.initialize(repeating: empty, count: Self.midiCapacity)
    }

    deinit {
        dummy.deallocate(); inputs.deallocate(); outputs.deallocate(); beat.deallocate()
        midiIn.deallocate(); midiOut.deallocate()
    }

    public var bpm: Double { 60 * sampleRate / samplesPerBeat }
}

/// Base class for every module's DSP. `process` runs on the real-time audio thread:
/// no allocation, no locks, no Objective-C, no printing.
open class DSPNode {
    public let sampleRate: Double
    public let spec: ModuleSpec
    /// Knob positions set from the UI.
    public let base: UnsafeMutablePointer<Float>
    /// Effective values (knob + patched modulation) that `process` reads. Rebuilt every block.
    public let params: UnsafeMutablePointer<Float>
    public let paramCount: Int
    private let rt: UnsafeMutablePointer<ParamRT>
    private let modPrev: UnsafeMutablePointer<Float>
    /// Values the UI displays (levels, BPM, looper state, ...).
    public let readouts: UnsafeMutablePointer<Float>
    public let outputs: [UnsafeMutablePointer<Float>]
    public static let readoutCount = 32
    /// Set from the UI. The graph crossfades over one block when it changes.
    public var bypassed = false
    var bypassMix: Float = 0
    let bypassRouting: [Int]

    // MARK: automation — one looping lane per parameter
    /// Lanes loop over this many beats (4 bars), in `autoSlots` steps (a 1/64 note each).
    public static let autoBeats: Double = 16
    public static let autoSlots = 256
    /// paramCount × autoSlots recorded values (raw parameter values).
    public let autoLane: UnsafeMutablePointer<Float>
    /// Per parameter: a lane is playing.
    public let autoOn: UnsafeMutablePointer<Bool>
    /// Per parameter: being recorded right now — the hand wins, playback waits.
    public let autoHold: UnsafeMutablePointer<Bool>
    /// Main thread: how many lanes are on (0 = skip the automation pass entirely).
    public var autoCount = 0
    /// Where the lanes are (0 ..< autoSlots, fractional), for the UI.
    public internal(set) var autoPosition: Double = 0

    /// Note sources with a "midi out" channel: the graph plays their pitch / gate (or trigger) outlets as MIDI.
    let midiOutParam: Int
    let midiSender: MIDINoteSender?

    public init(spec: ModuleSpec, sampleRate: Double) {
        self.spec = spec
        self.sampleRate = sampleRate
        midiOutParam = spec.params.firstIndex { $0.key == "midiout" } ?? -1
        midiSender = midiOutParam >= 0 ? MIDINoteSender(spec: spec) : nil
        bypassRouting = spec.bypassRouting
        let pc = max(1, spec.params.count)
        paramCount = spec.params.count
        base = .allocate(capacity: pc)
        base.initialize(repeating: 0, count: pc)
        params = .allocate(capacity: pc)
        params.initialize(repeating: 0, count: pc)
        modPrev = .allocate(capacity: pc)
        modPrev.initialize(repeating: 0, count: pc)
        rt = .allocate(capacity: pc)
        rt.initialize(repeating: ParamRT(min: 0, max: 1, exp: false, cubic: false, round: false, trigger: false), count: pc)
        for (i, p) in spec.params.enumerated() {
            base[i] = p.isTrigger ? 0 : p.def
            params[i] = base[i]
            var round = true
            if case .continuous = p.kind { round = false }
            rt[i] = ParamRT(min: p.min, max: p.max, exp: p.curve == .exponential, cubic: p.curve == .cubic,
                            round: round, trigger: p.isTrigger, semis: p.unit == "st")
        }
        readouts = .allocate(capacity: Self.readoutCount)
        readouts.initialize(repeating: 0, count: Self.readoutCount)
        autoLane = .allocate(capacity: pc * Self.autoSlots)
        autoLane.initialize(repeating: 0, count: pc * Self.autoSlots)
        autoOn = .allocate(capacity: pc)
        autoOn.initialize(repeating: false, count: pc)
        autoHold = .allocate(capacity: pc)
        autoHold.initialize(repeating: false, count: pc)
        let poly = Set(spec.polyOutputs)
        outputs = spec.outputs.indices.map { k in
            let n = kMaxBlock * (poly.contains(k) ? kMaxVoices : 1)
            let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
            b.initialize(repeating: 0, count: n)
            return b
        }
        outVoices = .allocate(capacity: max(spec.outputs.count, 1))
        outVoices.initialize(repeating: 1, count: max(spec.outputs.count, 1))
        inVoices = .allocate(capacity: max(spec.inputs.count, 1))
        inVoices.initialize(repeating: 1, count: max(spec.inputs.count, 1))
        outLevel = .allocate(capacity: max(spec.outputs.count, 1))
        outLevel.initialize(repeating: 0, count: max(spec.outputs.count, 1))
    }

    deinit {
        base.deallocate()
        params.deallocate()
        modPrev.deallocate()
        rt.deallocate()
        readouts.deallocate()
        autoLane.deallocate(); autoOn.deallocate(); autoHold.deallocate()
        outputs.forEach { $0.deallocate() }
        outLevel.deallocate()
        outVoices.deallocate(); inVoices.deallocate()
    }

    open func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>,
                      connected: UInt64, ctx: ProcessContext) {}

    /// Main thread: install a saved array (steps, notes …). Modules copy it into preallocated storage.
    open func setData(_ key: String, _ values: [Float]) {}

    /// The arrays a fresh module starts with (its starter pattern), by data key. A patch that doesn't
    /// hold one of these keys means "as it started" — undo back to before the first edit restores this.
    open var defaultData: [String: [Float]] { [:] }

    /// Main thread: make this (already running) module match a patch exactly — knob positions, patterns,
    /// automation. Undo / redo and every re-patch go through here, so the sound always matches the screen.
    public final func sync(to n: PatchNode) {
        for (i, p) in spec.params.enumerated() where !p.isTrigger {
            let v = n.params[p.key] ?? p.def
            if base[i] != v { base[i] = v }
        }
        for (key, start) in defaultData { setData(key, n.data[key] ?? start) }
        loadAutomation(n.data)
    }

    /// Notes on each outlet this block (poly outlets set it; 1 otherwise).
    public let outVoices: UnsafeMutablePointer<Int>
    /// Notes arriving on each inlet this block (set by the graph before `process`; 1 = mono).
    public let inVoices: UnsafeMutablePointer<Int>
    /// Note `v` of what arrives on an inlet (only valid for v < inVoices[port]).
    @inline(__always) public final func voice(_ input: UnsafePointer<Float>, _ v: Int) -> UnsafePointer<Float> {
        input + v * kMaxBlock
    }
    /// Note `v` of a poly outlet's buffer.
    @inline(__always) public final func outVoice(_ k: Int, _ v: Int) -> UnsafeMutablePointer<Float> {
        outputs[k] + v * kMaxBlock
    }

    /// Which outlets have a cable (bit k = outlet k); set when the patch is loaded. rack sends a pad to its
    /// own outlet instead of the main mix while that outlet is patched.
    public internal(set) var patchedOutputs: UInt64 = 0

    /// UI: activity per outlet — block peak with a ~250 ms fall, so short clock / gate pulses still show.
    public let outLevel: UnsafeMutablePointer<Float>

    /// How many NaN / inf samples the graph's safety net has had to remove from this module's outputs.
    public internal(set) var nonFinite = 0

    @inline(__always) public final func isConnected(_ mask: UInt64, _ i: Int) -> Bool {
        mask & (1 << UInt64(i)) != 0
    }

    /// Reads a trigger parameter (fired by a UI button or a patched gate) and clears it.
    @inline(__always) public final func consumeTrigger(_ i: Int) -> Bool {
        if params[i] > 0.5 { params[i] = 0; return true }
        return false
    }

    /// Start of every block: effective values = knob positions; pending UI triggers move across.
    @inline(__always) final func syncParams() {
        for i in 0..<paramCount {
            if rt[i].trigger {
                if base[i] > 0.5 { base[i] = 0; params[i] = 1 }
            } else {
                let b = base[i]
                params[i] = b.isFinite ? min(max(b, rt[i].min), rt[i].max) : rt[i].min
            }
        }
    }

    /// Lane slot (fractional) for a musical position.
    @inline(__always) public static func autoSlot(beat: Double) -> Double {
        guard beat.isFinite else { return 0 }
        var p = beat.truncatingRemainder(dividingBy: autoBeats)
        if p < 0 { p += autoBeats }
        return p / autoBeats * Double(autoSlots)
    }

    /// After syncParams: automated parameters follow their lanes (interpolated; stepped for whole-number
    /// parameters). Patched modulation then works on top of the automated value.
    @inline(__always) final func applyAutomation(beat: Double) {
        let pos = Self.autoSlot(beat: beat)
        autoPosition = pos
        guard autoCount > 0 else { return }
        let n = Self.autoSlots
        let i0 = min(Int(pos), n - 1), i1 = (i0 + 1) % n
        let f = Float(pos - Double(i0))
        for i in 0..<paramCount where autoOn[i] && !autoHold[i] && !rt[i].trigger {
            let lane = autoLane + i * n
            var v = rt[i].round ? lane[i0] : lane[i0] + (lane[i1] - lane[i0]) * f
            if !v.isFinite { continue }
            if rt[i].round { v = v.rounded() }
            params[i] = min(max(v, rt[i].min), rt[i].max)
        }
    }

    /// Main thread: install (or remove, with nil) the lane for one parameter.
    public final func setAutomation(_ i: Int, _ values: [Float]?) {
        guard i >= 0, i < paramCount else { return }
        if let values, values.count == Self.autoSlots {
            let lane = autoLane + i * Self.autoSlots
            for k in 0..<Self.autoSlots { lane[k] = values[k].isFinite ? values[k] : rt[i].min }
            autoOn[i] = true
        } else {
            autoOn[i] = false
        }
        autoCount = (0..<paramCount).reduce(0) { $0 + (autoOn[$1] ? 1 : 0) }
    }

    /// Main thread: the lanes as saved in a patch ("auto.<param key>" data entries).
    public final func loadAutomation(_ data: [String: [Float]]) {
        for (i, p) in spec.params.enumerated() where !autoHold[i] {   // a lane being recorded stays as it is
            let lane = data[Self.autoKey(p.key)]
            if lane != nil || autoOn[i] { setAutomation(i, lane) }
        }
    }

    public static func autoKey(_ paramKey: String) -> String { "auto." + paramKey }

    /// A patched signal moves the knob: ±1.0 sweeps the whole range. Gates fire trigger params.
    @inline(__always) final func applyMod(_ i: Int, _ mod: Float, position: Float = .nan) {
        let r = rt[i]
        let m: Float = mod.isFinite ? min(max(mod, -4), 4) : 0
        if r.trigger {
            let m = position.isNaN ? m : m + position
            if m > 0.5 && modPrev[i] <= 0.5 { params[i] = 1 }
            modPrev[i] = m
            return
        }
        let src = autoOn[i] && !autoHold[i] ? params[i] : base[i]
        let b = src.isFinite ? src : r.min
        if r.semis && position.isNaN {
            // pitch CV into a semitone row: 1 V/oct, like the pitch inlets (not scaled to the row's range)
            var v = min(max(b + m * 120, r.min), r.max)
            if r.round { v = v.rounded() }
            params[i] = v
            return
        }
        let a = max(abs(r.min), abs(r.max))
        let unipolar = r.min >= 0
        var n: Float = r.exp ? logf(max(b, r.min) / r.min) / logf(r.max / r.min)
                     : r.cubic ? (unipolar ? cbrtf(max(b, 0) / max(r.max, 1e-9)) : (cbrtf(b / a) + 1) / 2)
                     : (b - r.min) / (r.max - r.min)
        // a fader / knob patched in sets the position itself; other modulation adds on top
        if !position.isNaN { n = position.isFinite ? min(max(position, 0), 1) : 0 }
        n = n.isFinite ? min(max(n + m, 0), 1) : 0
        var v: Float
        if r.exp { v = r.min * powf(r.max / r.min, n) }
        else if r.cubic {
            if unipolar { v = r.max * n * n * n } else { let x = 2 * n - 1; v = a * x * x * x }
        }
        else { v = r.min + (r.max - r.min) * n }
        if r.round { v = v.rounded() }
        params[i] = v
    }
}
