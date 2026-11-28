import Foundation

// MIDI in the patch: the midi box (notes, a CC, bend and clock in from a device; notes, a CC and clock out to
// one), and the "midi out" channel every keyboard / arp / sequencer has (MIDINoteSender, run by the graph).

/// General MIDI drum notes for the drum roll's eight lanes (kick, snare, closed hat, open hat, tom, clap, crash, ride).
let kDrumNotes: [Int] = [36, 38, 42, 46, 45, 39, 49, 51]

/// Plays pitch / gate (and vel) signals — up to four notes on one cable — or trigger outlets as MIDI notes.
final class MIDINoteSender {
    private let pitchOut: Int, gateOut: Int, velOut: Int
    private let triggers: Bool
    private var high = [Bool](repeating: false, count: 8)
    private var held = [Int](repeating: -1, count: 8)
    private var channel = -1
    private var port: Int32 = 0

    init(spec: ModuleSpec) {
        pitchOut = spec.outputs.firstIndex(of: "pitch") ?? -1
        gateOut = spec.outputs.firstIndex(of: "gate") ?? -1
        velOut = spec.outputs.firstIndex(of: "vel") ?? -1
        triggers = gateOut < 0
    }
    /// Inlets instead of outlets (the midi box sends what's patched into it).
    init(pitch: Int, gate: Int, vel: Int) { pitchOut = pitch; gateOut = gate; velOut = vel; triggers = false }

    @inline(__always) private func off(_ v: Int, _ i: Int, _ ctx: ProcessContext) {
        if held[v] >= 0 { ctx.sendMIDI(0x80 | UInt8(channel), UInt8(held[v]), 0, offset: i, port: port); held[v] = -1 }
    }
    private func allOff(_ ctx: ProcessContext) {
        guard channel >= 0 else { return }
        for v in 0..<held.count { off(v, 0, ctx); high[v] = false }
    }
    /// Channel and port changes end the notes that are sounding first.
    @inline(__always) private func retune(_ ch: Int, _ p: Int32, _ ctx: ProcessContext) {
        if ch != channel || p != port { allOff(ctx); channel = ch; port = p }
    }

    /// A module's own outlets (channel -1 = midi out off).
    func run(_ node: DSPNode, channel ch: Int, frames: Int, ctx: ProcessContext) {
        retune(ch, 0, ctx)
        guard ch >= 0 && ch < 16 else { return }
        if triggers {
            for k in 0..<min(node.outputs.count, 8) {
                let o = node.outputs[k]
                let note = kDrumNotes[k]
                for i in 0..<frames {
                    if !high[k] && o[i] > 0.2 {
                        high[k] = true
                        off(k, i, ctx)
                        ctx.sendMIDI(0x90 | UInt8(ch), UInt8(note), 100, offset: i)
                        held[k] = note
                    } else if high[k] && o[i] < 0.1 {
                        high[k] = false
                        off(k, i, ctx)
                    }
                }
            }
            return
        }
        notes(gate: node.outputs[gateOut], voices: node.outVoices[gateOut],
              pitch: pitchOut >= 0 ? node.outputs[pitchOut] : nil, pitchVoices: pitchOut >= 0 ? node.outVoices[pitchOut] : 1,
              vel: velOut >= 0 ? node.outputs[velOut] : nil, velVoices: velOut >= 0 ? node.outVoices[velOut] : 1,
              frames: frames, ctx: ctx)
    }

    /// Patched inlets (the midi box); voices 0 ends whatever is sounding.
    func run(gate: UnsafePointer<Float>, voices: Int, pitch: UnsafePointer<Float>?, pitchVoices: Int,
             vel: UnsafePointer<Float>?, velVoices: Int, channel ch: Int, port p: Int32, frames: Int, ctx: ProcessContext) {
        retune(ch, p, ctx)
        guard ch >= 0 && ch < 16 && p >= 0 else { return }
        notes(gate: gate, voices: voices, pitch: pitch, pitchVoices: pitchVoices, vel: vel, velVoices: velVoices, frames: frames, ctx: ctx)
    }

    @inline(__always) private func notes(gate: UnsafePointer<Float>, voices: Int, pitch: UnsafePointer<Float>?, pitchVoices: Int,
                                         vel: UnsafePointer<Float>?, velVoices: Int, frames: Int, ctx: ProcessContext) {
        for v in 0..<kMaxVoices {
            guard v < voices else { off(v, 0, ctx); high[v] = false; continue }
            let g = gate + v * kMaxBlock
            let pin = pitch.map { $0 + min(v, max(pitchVoices, 1) - 1) * kMaxBlock }
            let vin = vel.map { $0 + min(v, max(velVoices, 1) - 1) * kMaxBlock }
            for i in 0..<frames {
                let x = g[i]
                if !high[v] && x > 0.2 {
                    high[v] = true
                    off(v, i, ctx)
                    let velocity: Float = vin != nil ? min(max(vin![i], 0), 1) : 0.8
                    if velocity > 0 {
                        let semis: Float = pin != nil ? cvSemitones(pin![i]) : 0
                        let n = Int(min(max((60 + semis).rounded(), 0), 127))
                        ctx.sendMIDI(0x90 | UInt8(channel), UInt8(n), UInt8(min(max(Int((velocity * 127).rounded()), 1), 127)),
                                     offset: i, port: port)
                        held[v] = n
                    }
                } else if high[v] && x < 0.1 {
                    high[v] = false
                    off(v, i, ctx)
                }
            }
        }
    }
}

// MARK: - midi box

public enum MIDIBoxLayout {
    public static let channels = ["all"] + (1...16).map { "\($0)" }
    public static let outChannels = (1...16).map { "\($0)" }
    public static let midiOut = ["off"] + (1...16).map { "\($0)" }
    public static let midiIn = ["off", "all"] + (1...16).map { "\($0)" }
    // params
    public static let inCh = 0, outCh = 1, voices = 2, bend = 3, cc = 4, clock = 5
    public static func params() -> [ParamSpec] {
        [.choice("inch", "in channel", channels, def: 0),
         .choice("outch", "out channel", outChannels, def: 0),
         .choice("voices", "voices", ["mono", "2", "3", "4"], def: 0),
         .integer("bend", "bend range", 0, 24, 2),
         .integer("cc", "cc number", 0, 127, 1),
         .toggle("clock", "send clock", false)]
    }
    /// The patch keeps the chosen devices by name ("" = every device that's on in the midi menu).
    public static let inKey = "indev", outKey = "outdev"
}

/// In: notes (mono or up to four voices on one cable, with bend), a CC, MIDI clock (24 ppqn pulses — patch it
/// into a clock module set to 24 ppqn) and start. Out: notes from what's patched in, the CC inlet, clock.
public final class MIDIBoxNode: DSPNode {
    // inputs: 0 pitch, 1 gate, 2 vel, 3 cc · outputs: 0 pitch, 1 gate, 2 vel, 3 cc, 4 clock, 5 reset
    /// Main thread: the chosen devices by name ("" = all that are on, "none" = don't send).
    public private(set) var inName = ""
    public private(set) var outName = ""
    /// Read by the audio thread: device ids (0 = all, -1 = not connected).
    private var inDev: Int32 = 0
    private var outDev: Int32 = 0

    private var stack = [Int](repeating: 0, count: 16)      // mono: held notes, newest last
    private var stackVel = [Float](repeating: 0, count: 16)
    private var depth = 0
    private var vNote = [Int](repeating: -1, count: kMaxVoices)   // poly: note per voice (-1 = free)
    private var vLast = [Int](repeating: 60, count: kMaxVoices)   // pitch it holds after release
    private var vVel = [Float](repeating: 0, count: kMaxVoices)
    private var vAge = [Int](repeating: 0, count: kMaxVoices)
    private var vDip = [Int](repeating: 0, count: kMaxVoices)
    private var age = 0
    private var bend: Float = 0
    private var ccValue: Float = 0
    private var clockLeft = 0, resetLeft = 0
    private let sender = MIDINoteSender(pitch: 0, gate: 1, vel: 2)
    private var lastCC = -1
    private var lastTick: Double = -1
    private var wasRunning = false
    private var inBlink = 0, outBlink = 0

    public override var defaultData: [String: [Float]] { [MIDIBoxLayout.inKey: [], MIDIBoxLayout.outKey: []] }
    public override func setData(_ key: String, _ values: [Float]) {
        if key == MIDIBoxLayout.inKey { inName = PluginCatalog.text(values) }
        else if key == MIDIBoxLayout.outKey { outName = PluginCatalog.text(values) }
        else { return }
        MIDIHub.shared.register(self)
        resolve()
    }
    /// Main thread: names → device ids (again whenever devices come or go).
    func resolve() {
        inDev = MIDIHub.shared.sourceID(inName)
        outDev = MIDIHub.shared.destinationID(outName)
    }

    private func noteOn(_ n: Int, _ vel: Float, poly: Int) {
        if poly <= 1 {
            var k = 0
            while k < depth { if stack[k] == n { break }; k += 1 }
            if k < depth { for j in k..<(depth - 1) { stack[j] = stack[j + 1]; stackVel[j] = stackVel[j + 1] }; depth -= 1 }
            if depth == stack.count { for j in 0..<(depth - 1) { stack[j] = stack[j + 1]; stackVel[j] = stackVel[j + 1] }; depth -= 1 }
            if depth > 0 { vDip[0] = 48 }          // a new note: retrigger envelopes
            stack[depth] = n; stackVel[depth] = vel; depth += 1
            return
        }
        age += 1
        var pick = -1
        for v in 0..<poly where vNote[v] == n { pick = v }
        if pick < 0 { for v in 0..<poly where vNote[v] < 0 { pick = v; break } }
        if pick < 0 {                              // all busy: the oldest note makes way
            pick = 0
            for v in 1..<poly where vAge[v] < vAge[pick] { pick = v }
        }
        if vNote[pick] >= 0 { vDip[pick] = 48 }
        vNote[pick] = n; vLast[pick] = n; vVel[pick] = vel; vAge[pick] = age
    }
    private func noteOff(_ n: Int, poly: Int) {
        if poly <= 1 {
            var k = 0
            while k < depth { if stack[k] == n { break }; k += 1 }
            guard k < depth else { return }
            if k == depth - 1 && depth > 0 { vLast[0] = n }
            for j in k..<(depth - 1) { stack[j] = stack[j + 1]; stackVel[j] = stackVel[j + 1] }
            depth -= 1
            return
        }
        for v in 0..<kMaxVoices where vNote[v] == n { vNote[v] = -1 }
    }
    private func allNotesOff() { depth = 0; for v in 0..<kMaxVoices { vNote[v] = -1 } }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let inCh = Int(params[MIDIBoxLayout.inCh].rounded()) - 1          // -1 = all
        let outCh = Int(params[MIDIBoxLayout.outCh].rounded())
        let poly = clampIndex(params[MIDIBoxLayout.voices], 4) + 1
        let range = params[MIDIBoxLayout.bend]
        let ccNum = Int(params[MIDIBoxLayout.cc].rounded())
        let dev = inDev
        if poly == 1 { for v in 1..<kMaxVoices { vNote[v] = -1 } }

        // what came in
        for k in 0..<ctx.midiInCount {
            let m = ctx.midiIn[k]
            guard dev == 0 ? m.global : m.port == dev else { continue }
            let s = m.status
            if s >= 0xF8 || s == 0xFA {
                if s == 0xF8 { clockLeft = max(16, Int(sampleRate * 0.002)) }
                else if s == 0xFA || s == 0xFB { resetLeft = max(16, Int(sampleRate * 0.002)) }
                continue
            }
            guard s >= 0x80 && s < 0xF0 else { continue }
            guard inCh < 0 || Int(s & 0x0F) == inCh else { continue }
            inBlink = 8
            switch s & 0xF0 {
            case 0x90 where m.d2 > 0: noteOn(Int(m.d1), Float(m.d2) / 127, poly: poly)
            case 0x80, 0x90: noteOff(Int(m.d1), poly: poly)
            case 0xB0:
                if Int(m.d1) == ccNum { ccValue = Float(m.d2) / 127 }
                if m.d1 == 123 || m.d1 == 120 { allNotesOff() }
            case 0xE0: bend = (Float(Int(m.d2) << 7 | Int(m.d1)) - 8192) / 8192
            default: break
            }
        }

        // notes out on the cables
        let b = bend * range
        for v in 0..<poly {
            let p = outVoice(0, v), g = outVoice(1, v), vo = outVoice(2, v)
            let on: Bool, note: Int, vel: Float
            if poly == 1 {
                on = depth > 0
                note = on ? stack[depth - 1] : vLast[0]
                vel = on ? stackVel[depth - 1] : 0
                if on { vLast[0] = note }
            } else {
                on = vNote[v] >= 0; note = vLast[v]; vel = on ? vVel[v] : 0
            }
            let pitch = pitchCV(Float(note - 60) + b)
            for i in 0..<frames {
                p[i] = pitch
                g[i] = on && vDip[v] == 0 ? kGateHigh : 0
                vo[i] = vel
                if vDip[v] > 0 { vDip[v] -= 1 }
            }
        }
        for k in 0..<3 { outVoices[k] = poly }
        let ccO = outputs[3], ck = outputs[4], rs = outputs[5]
        for i in 0..<frames {
            ccO[i] = ccValue
            ck[i] = clockLeft > 0 ? kGateHigh : 0
            rs[i] = resetLeft > 0 ? kGateHigh : 0
            if clockLeft > 0 { clockLeft -= 1 }
            if resetLeft > 0 { resetLeft -= 1 }
        }

        // what's patched in goes out
        let port = outDev
        let before = ctx.midiOutCount
        let hp = isConnected(connected, 0), hv = isConnected(connected, 2)
        sender.run(gate: inputs[1], voices: isConnected(connected, 1) ? inVoices[1] : 0,
                   pitch: hp ? inputs[0] : nil, pitchVoices: inVoices[0], vel: hv ? inputs[2] : nil, velVoices: inVoices[2],
                   channel: outCh, port: port, frames: frames, ctx: ctx)
        if isConnected(connected, 3) && port >= 0 {
            let x = inputs[3][frames - 1]
            let v = Int((min(max(x.isFinite ? x : 0, 0), 1) * 127).rounded())
            if v != lastCC { ctx.sendMIDI(0xB0 | UInt8(outCh), UInt8(ccNum & 0x7F), UInt8(v), offset: frames - 1, port: port); lastCC = v }
        }
        if params[MIDIBoxLayout.clock] > 0.5 && port >= 0 {
            if ctx.running && !wasRunning { ctx.sendMIDI(0xFA, 0, 0, offset: 0, port: port); lastTick = -1 }
            if !ctx.running && wasRunning { ctx.sendMIDI(0xFC, 0, 0, offset: 0, port: port) }
            if ctx.running {
                for i in 0..<frames {
                    let t = floor(ctx.beat[i] * 24)
                    if ctx.beat[i] >= 0 && t != lastTick { ctx.sendMIDI(0xF8, 0, 0, offset: i, port: port); lastTick = t }
                }
            }
        }
        wasRunning = ctx.running
        if ctx.midiOutCount > before { outBlink = 8 }

        // readouts: 0 notes held in, 1 in activity, 2 out activity, 3 device missing (1 in, 2 out, 3 both)
        readouts[0] = Float(poly == 1 ? min(depth, 1) : (0..<poly).reduce(0) { $0 + (vNote[$1] >= 0 ? 1 : 0) })
        readouts[1] = inBlink > 0 ? 1 : 0
        readouts[2] = outBlink > 0 ? 1 : 0
        readouts[3] = Float((inDev < 0 ? 1 : 0) + (outDev < 0 && outName != "none" ? 2 : 0))
        if inBlink > 0 { inBlink -= 1 }
        if outBlink > 0 { outBlink -= 1 }
    }
}
