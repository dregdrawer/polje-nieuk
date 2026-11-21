import Foundation
import PoljeNieukCore
import PoljeNieukUI

// Offline test: renders a patch with a synthetic modular clock and audio input, no hardware needed.

// `selftest --dump-specs <file>`: every module's definition as JSON — the Windows (JUCE) version embeds it,
// so both apps always offer exactly the same modules, rows and ranges.
if let i = CommandLine.arguments.firstIndex(of: "--dump-specs"), i + 1 < CommandLine.arguments.count {
    func kindInfo(_ k: ParamKind) -> (String, [String]) {
        switch k {
        case .continuous: return ("continuous", [])
        case .integer: return ("integer", [])
        case .toggle: return ("toggle", [])
        case .trigger: return ("trigger", [])
        case .choice(let o): return ("choice", o)
        }
    }
    func curveName(_ c: ParamCurve) -> String { c == .linear ? "linear" : (c == .exponential ? "exponential" : "cubic") }
    let modules: [[String: Any]] = ModuleRegistry.all.map { s in
        [
            "kind": s.kind, "name": s.name, "category": s.category, "summary": s.summary,
            "aliases": s.aliases, "inputs": s.inputs, "outputs": s.outputs, "polyOutputs": s.polyOutputs,
            "bypass": s.bypass == .through ? "through" : (s.bypass == .silent ? "silent" : "none"),
            "outputsAreCV": s.outputsAreCV,
            "params": s.params.map { p -> [String: Any] in
                let (k, o) = kindInfo(p.kind)
                var d: [String: Any] = ["key": p.key, "name": p.name, "min": p.min, "max": p.max, "def": p.def,
                                        "unit": p.unit, "kind": k, "curve": curveName(p.curve)]
                if !o.isEmpty { d["options"] = o }
                if let a = p.allowed { d["allowed"] = a }
                return d
            },
        ]
    }
    let doc: [String: Any] = ["categories": ModuleRegistry.categories, "modules": modules]
    let data = try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    // fm's built-in voices, next to it (155 bytes each), so the Windows version has exactly the same ones
    let fm = URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingLastPathComponent().appendingPathComponent("fmpresets.bin")
    try! Data(FMPresets.all.flatMap(\.vced)).write(to: fm)
    print("wrote \(ModuleRegistry.all.count) module specs and \(FMPresets.all.count) fm voices")
    exit(0)
}


// `selftest --render <patch.json> <seconds>`: renders a patch offline (no input) and prints every outlet's
// RMS — the Windows (JUCE) engine has the same mode, so the two can be compared number for number.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 2 < CommandLine.arguments.count {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let p = try! JSONDecoder().decode(Patch.self, from: data).migrated()
    let seconds = Double(CommandLine.arguments[i + 2]) ?? 4
    let h = GraphHost(sampleRate: 48000)
    h.load(p)
    let block = 256, chans = 8
    let ins = (0..<chans).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    let outs = (0..<chans).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    for b in ins { b.initialize(repeating: 0, count: block) }
    var sums: [UUID: [Double]] = [:]
    for n in p.nodes { sums[n.id] = [Double](repeating: 0, count: h.node(n.id)?.outputs.count ?? 0) }
    let blocks = Int(seconds * 48000) / block
    var total = 0
    ins.withUnsafeBufferPointer { ip in
        outs.withUnsafeBufferPointer { op in
            for _ in 0..<blocks {
                for b in outs { b.update(repeating: 0, count: block) }
                h.process(frames: block, inputs: UnsafePointer(ip.baseAddress!), inputCount: chans,
                          outputs: UnsafePointer(op.baseAddress!), outputCount: chans)
                // outlets hold the last 64-sample chunk: sample them once per block
                for n in p.nodes { if let d = h.node(n.id) { for k in 0..<d.outputs.count { for s in 0..<64 { let v = Double(d.outputs[k][s]); sums[n.id]![k] += v * v } } } }
                total += 64
            }
        }
    }
    for (idx, n) in p.nodes.enumerated() {
        let r = (sums[n.id] ?? []).map { String(format: "%.4f", sqrt($0 / Double(max(total, 1)))) }
        print("\(idx) \(n.kind) \(r.joined(separator: " "))")
    }
    exit(0)
}

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  PASS  \(msg)" : "  FAIL  \(msg)")
    if !ok { failures += 1 }
}

let sr = 48000.0
let host = GraphHost(sampleRate: sr)

func node(_ kind: String, _ params: [String: Float] = [:]) -> PatchNode {
    PatchNode(kind: kind, x: 0, y: 0, params: params)
}
var patch = Patch()
let hwIn = node("in")
let clock = node("clock", ["source": 0])          // follows the synthetic modular clock
let grain = node("grain", ["sync": 1])
let delay = node("delay")
let verb = node("reverb")
let filt = node("filter")
let drive = node("drive")
let lfo = node("lfo", ["sync": 1])
let looper = node("looper", ["dry": 0])
let mix = node("mix")
let out = node("out")
let atten = node("atten", ["off": 0.5, "amt": 0])
let newKinds = ["gain", "comp", "limit", "gate", "eq", "chorus", "phaser", "redux", "shift", "autopan", "repeat", "env"]
let chain = newKinds.map { node($0) }
patch.nodes = [hwIn, clock, grain, delay, verb, filt, drive, lfo, looper, mix, out, atten] + chain
func cable(_ a: PatchNode, _ ap: Int, _ b: PatchNode, _ bp: Int) -> PatchCable {
    PatchCable(fromNode: a.id, fromPort: ap, toNode: b.id, toPort: bp)
}
let inAudio = hwIn, inClock = hwIn
patch.cables = [
    cable(inClock, 1, clock, 0),
    cable(inAudio, 0, grain, 0),
    cable(grain, 0, verb, 0), cable(grain, 1, verb, 1),
    cable(inAudio, 0, delay, 0),
    cable(inAudio, 0, drive, 0), cable(drive, 0, filt, 0), cable(lfo, 0, filt, 1),
    cable(inAudio, 0, looper, 0),
    cable(verb, 0, mix, 0), cable(delay, 0, mix, 1), cable(filt, 0, mix, 2), cable(looper, 0, mix, 3),
    cable(mix, 0, out, 0), cable(verb, 1, out, 1),
    // a CV-style constant patched into the delay's free time parameter
    PatchCable(fromNode: atten.id, fromPort: 0, toNode: delay.id, toPort: kParamPortBase + 2),
]
// every new module in series: audio in → … → out channel 2
var prev = hwIn
for n in chain {
    let spec = ModuleRegistry.spec(n.kind)!
    if !spec.inputs.isEmpty { patch.cables.append(cable(prev, 0, n, 0)) }
    prev = n
}
patch.cables.append(cable(chain[chain.count - 3], 0, out, 1))
host.load(patch)
host.prepareForStart()

let block = 256
let inputs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
let outputs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
for c in 0..<2 {
    inputs[c] = .allocate(capacity: block); outputs[c] = .allocate(capacity: block)
}

var t = 0
var bpm = 120.0
var lastPulse = -1_000_000
var peak: Float = 0
var finite = true
var renderTime = 0.0

func render(seconds: Double) {
    let total = Int(seconds * sr)
    var done = 0
    while done < total {
        let period = Int(sr * 60 / bpm)   // one pulse per quarter note (1 ppqn)
        for i in 0..<block {
            let n = t + i
            inputs[0][i] = 0.3 * sinf(Float(2 * Double.pi * 220 * Double(n) / sr))
            if n - lastPulse >= period { lastPulse = n }
            inputs[1][i] = (n - lastPulse) < Int(sr * 0.01) ? 0.5 : 0   // 10 ms, +5 V gate
        }
        for c in 0..<2 { outputs[c].update(repeating: 0, count: block) }
        let t0 = Date()
        host.process(frames: block, inputs: inputs, inputCount: 2, outputs: outputs, outputCount: 2)
        renderTime += Date().timeIntervalSince(t0)
        for c in 0..<2 {
            for i in 0..<block {
                let v = outputs[c][i]
                if !v.isFinite { finite = false }
                peak = max(peak, abs(v))
            }
        }
        t += block
        done += block
    }
}

print("Clock following")
render(seconds: 3)
let clockNode = host.node(clock.id)!
check(abs(clockNode.readouts[0] - 120) < 0.5, "locks to 120 BPM external clock (got \(clockNode.readouts[0]))")
check(clockNode.readouts[2] == 1, "reports clock locked")

bpm = 90
render(seconds: 3)
check(abs(clockNode.readouts[0] - 90) < 0.5, "follows tempo change to 90 BPM (got \(clockNode.readouts[0]))")

print("Looper (1 bar, quantized)")
let loopNode = host.node(looper.id)!
loopNode.base[0] = 1   // press REC
render(seconds: 0.3)
check(loopNode.readouts[0] == 1 || loopNode.readouts[0] == 2, "armed or recording after REC (state \(loopNode.readouts[0]))")
render(seconds: 6)
check(loopNode.readouts[0] == 3, "playing after one bar (state \(loopNode.readouts[0]))")
check(abs(loopNode.readouts[2] - Float(4 * 60 / 90.0)) < 0.02, "loop length = 1 bar at 90 BPM (\(loopNode.readouts[2]) s)")
check(loopNode.readouts[3] == 4, "loop is 4 beats (\(loopNode.readouts[3]))")

print("Granulator (clock-synced)")
let grainNode = host.node(grain.id)!
check(grainNode.readouts[2] > 50, "grains spawned on the clock (\(Int(grainNode.readouts[2])))")

print("Re-patching keeps state")
patch.cables.removeAll { $0.toNode == out.id && $0.toPort == 1 }
host.load(patch)
render(seconds: 0.5)
check(host.node(looper.id) === loopNode && loopNode.readouts[0] == 3, "looper still playing after editing cables")

print("Patched parameters")
let delayNode = host.node(delay.id)!
check(delayNode.base[2] == 375 && delayNode.params[2] > 1000,
      "CV offset moves delay time (knob 375 ms → \(Int(delayNode.params[2])) ms)")
for n in chain {
    let dn = host.node(n.id)!
    var ok = true
    for o in dn.outputs { for i in 0..<kMaxBlock where !o[i].isFinite { ok = false } }
    check(ok, "\(n.kind) output is finite")
}

print("Old patch migration")
do {
    // v14: a 2-octave roll grid (relative to its "lowest note") moves onto the full 7-octave range, same notes
    var g = [Float](repeating: 0, count: 32 * 24); g[0 * 32 + 0] = 1; g[7 * 32 + 1] = 1
    var o = Patch(); o.version = 13
    o.nodes = [PatchNode(kind: "roll", x: 0, y: 0, params: ["low": -5], data: ["grid": g])]
    let m = o.migrated().nodes[0].data["grid"] ?? []
    let on = m.indices.filter { m[$0] > 0.5 }.map { ($0 / 32 + RollNode.lowest, $0 % 32) }
    check(m.count == RollNode.steps * RollNode.rows && on.map(\.0) == [-5, 2] && on.map(\.1) == [0, 1],
          "older roll: notes keep their pitch on the 7-octave grid (\(on))")
}
var old = Patch(); old.version = 1
let oi = PatchNode(kind: "in", x: 0, y: 0, params: ["ch": 4])
let oc = PatchNode(kind: "clock", x: 0, y: 0)
old.nodes = [oi, oc]; old.cables = [PatchCable(fromNode: oi.id, fromPort: 0, toNode: oc.id, toPort: 0)]
let m = old.migrated()
check(m.cables[0].fromPort == 3 && m.nodes[0].params.isEmpty, "in~ channel 4 becomes outlet 4")
var old2 = Patch(); old2.version = 2
old2.nodes = [PatchNode(kind: "looper", x: 0, y: 0, params: ["speed": 1, "dry": 0.5])]
let m2 = old2.migrated().nodes[0].params
check(m2["rate"] == 1 && m2["rev"] == 1 && m2["speed"] == nil && m2["dry"] == 0.5, "old looper '-1x' becomes speed 1x + reverse on")

print("Bypass")
let verbNode = host.node(verb.id)!
verbNode.bypassed = true
render(seconds: 0.2)
let inNode = host.node(hwIn.id)!
var same = true
for i in 0..<kMaxBlock where abs(verbNode.outputs[0][i] - host.node(grain.id)!.outputs[0][i]) > 1e-6 { same = false }
check(same, "bypassed reverb passes its input straight through")
verbNode.bypassed = false
render(seconds: 0.2)
_ = inNode

print("Output")
check(finite, "no NaN/Inf in output")
check(peak > 0.05, "output is not silent (peak \(peak))")
let audioSeconds = Double(t) / sr
print(String(format: "  INFO  rendered %.1f s of audio in %.3f s (%.1f%% of one core)", audioSeconds, renderTime, renderTime / audioSeconds * 100))

// MARK: - New modules

/// Runs a single module with `input` on its first inlet, returns its outlets.
func runModule(_ kind: String, params: [String: Float] = [:], input: [Float], setup: ((DSPNode) -> Void)? = nil,
               every: ((Int, DSPNode) -> Void)? = nil) -> (node: DSPNode, outs: [[Float]]) {
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    let src = PatchNode(kind: "in", x: 0, y: 0)
    let n = PatchNode(kind: kind, x: 0, y: 0, params: params)
    p.nodes = [src, n]
    if !(ModuleRegistry.spec(kind)!.inputs.isEmpty) {
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: n.id, toPort: 0)]
    }
    h.load(p); h.prepareForStart()
    let node = h.node(n.id)!
    setup?(node)
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    ins[0] = .allocate(capacity: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    outs[0] = .allocate(capacity: kMaxBlock)
    var result = [[Float]](repeating: [], count: node.outputs.count)
    var pos = 0, blockIndex = 0
    while pos + kMaxBlock <= input.count {
        for i in 0..<kMaxBlock { ins[0][i] = input[pos + i] }
        outs[0].update(repeating: 0, count: kMaxBlock)
        every?(blockIndex, node)
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 1)
        for (k, o) in node.outputs.enumerated() { result[k].append(contentsOf: UnsafeBufferPointer(start: o, count: kMaxBlock)) }
        pos += kMaxBlock; blockIndex += 1
    }
    return (node, result)
}
func sine(_ hz: Double, _ seconds: Double, _ amp: Float = 0.5) -> [Float] {
    let w: Double = 2 * Double.pi * hz / sr
    return (0..<Int(seconds * sr)).map { (i: Int) -> Float in amp * Float(Foundation.sin(w * Double(i))) }
}
func zeroCrossFreq(_ x: [Float]) -> Double {
    var n = 0
    for i in 1..<x.count where x[i - 1] <= 0 && x[i] > 0 { n += 1 }
    return Double(n) / (Double(x.count) / sr)
}
func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))) }

print("Frequency shifter")
let fs = runModule("freqshift", params: ["shift": 200], input: sine(1000, 1)).outs
let upF = zeroCrossFreq(Array(fs[0][24000...])), downF = zeroCrossFreq(Array(fs[2][24000...]))
check(abs(upF - 1200) < 15 && abs(downF - 800) < 15, "1 kHz shifted by +200 Hz → up \(Int(upF)) Hz, down \(Int(downF)) Hz")

print("Parametric EQ")
let noise: [Float] = (0..<48000).map { _ in Float.random(in: -0.5...0.5) }
let flat = runModule("peq", input: noise).outs
var maxErr: Float = 0
for i in 0..<noise.count - 64 { maxErr = max(maxErr, abs(flat[0][i] - noise[i])) }
check(maxErr < 1e-4, "all gains at 0 dB is perfectly flat (max error \(maxErr))")
let eqp: [Float] = { var v = [Float](repeating: 0, count: 26); v[0] = 1; v[1] = 0
    for b in 0..<8 { v[2 + 3*b] = ParametricEQ.defaultFrequencies(5)[min(b, 4)]; v[3 + 3*b] = 0; v[4 + 3*b] = 1 }
    v[3 + 3*2] = 6; return v }()
let peakDB = ParametricEQ.responseDB({ eqp[$0] }, freq: Double(eqp[2 + 3*2]), sampleRate: sr)
check(abs(peakDB - 6) < 0.3, "5-band mode: +6 dB on band 3 reads \(String(format: "%.2f", peakDB)) dB at its centre")

print("LA-3A compressor")
// keep the nodes alive while reading their readouts (they own that memory)
let loudRun = runModule("comp", params: ["peak": 0.6, "gain": 0], input: sine(200, 1, 0.5))
let quietRun = runModule("comp", params: ["peak": 0.6, "gain": 0], input: sine(200, 1, 0.002))
let loud = withExtendedLifetime(loudRun.node) { loudRun.node.readouts[0] }
let quiet = withExtendedLifetime(quietRun.node) { quietRun.node.readouts[0] }
check(loud > 6 && quiet < 0.5, "compresses a loud tone (\(String(format: "%.1f", loud)) dB GR), leaves a quiet one (\(String(format: "%.1f", quiet)) dB)")

print("Paulstretch")
let st = runModule("stretch", params: ["stretch": 20], input: [Float](repeating: 0, count: Int(sr * 3)),
                   setup: { ($0 as! SampleBufferNode).load(StereoAudio(left: Array(noise.prefix(Int(sr))), right: Array(noise.reversed().prefix(Int(sr))))) }).outs
let stRMS = rms(st[0][Int(sr)...]), stR = rms(st[1][Int(sr)...])
var corr: Float = 0
for i in Int(sr)..<st[0].count { corr += st[0][i] * st[1][i] }
corr /= Float(st[0].count - Int(sr)) * stRMS * stR
check(stRMS > 0.01 && stRMS.isFinite, "stretches 1 s of noise into a continuous drone (rms \(String(format: "%.3f", stRMS)))")
check(abs(corr) < 0.3, "left/right are decorrelated for width (corr \(String(format: "%.2f", corr)))")

print("Sampler")
// a fake drum loop: 8 decaying bursts every 250 ms
var loop = [Float](repeating: 0, count: Int(sr * 2))
for k in 0..<8 { let s0 = Int(Double(k) * 0.25 * sr)
    for i in 0..<Int(0.08 * sr) { loop[s0 + i] = Float.random(in: -0.8...0.8) * expf(-Float(i) / Float(0.015 * sr)) } }
var hits = 0
let samp = runModule("sampler", params: ["auto": 4], input: [Float](repeating: 0, count: Int(sr * 2.2)),
                     setup: { n in let sn = n as! SamplerNode; sn.load(StereoAudio(left: loop)); sn.analyze() },
                     every: { _, n in hits = max(hits, Int(n.readouts[3])) })
let sn = samp.node as! SamplerNode
check(sn.markerCount == 7, "transient detection finds the 7 hits after the first (\(sn.markerCount))")
check(Int(sn.readouts[2]) == 8, "8 slices")
check(hits >= 4 && rms(samp.outs[0][...]) > 0.01, "plays slices on the clock (reached slice \(hits))")

var odd2 = [Float](repeating: 0, count: Int(sr * 1.5))
for i in 0..<odd2.count { odd2[i] = Float(i % 4800) / 4800 - 0.5 }
print("Sampler STOP")
// clock-sliced playback: STOP must silence it for good, PLAY brings it back
let stopBlock = Int(1.0 * sr) / kMaxBlock, playBlock = Int(2.0 * sr) / kMaxBlock
let stopRun = runModule("sampler", params: ["auto": 4], input: [Float](repeating: 0, count: Int(sr * 3)),
                        setup: { n in let sn = n as! SamplerNode; sn.load(StereoAudio(left: loop)); sn.analyze() },
                        every: { b, n in if b == stopBlock { n.base[1] = 1 }; if b == playBlock { n.base[21] = 1 } })
let afterStop = rms(stopRun.outs[0][Int(1.1 * sr)..<Int(2.0 * sr)])
let afterPlay = rms(stopRun.outs[0][Int(2.0 * sr)...])
check(afterStop < 1e-5 && afterPlay > 0.01, String(format: "STOP silences clock-sliced playback (rms %.6f), PLAY resumes it (rms %.3f)", afterStop, afterPlay))
// whole-section PLAY: STOP stops it
let secRun = runModule("sampler", params: ["loop": 1], input: [Float](repeating: 0, count: Int(sr * 2)),
                       setup: { n in (n as! SamplerNode).load(StereoAudio(left: odd2)); n.base[21] = 1 },
                       every: { b, n in if b == stopBlock { n.base[1] = 1 } })
check(rms(secRun.outs[0][Int(0.2 * sr)..<Int(0.9 * sr)]) > 0.05 && rms(secRun.outs[0][Int(1.1 * sr)...]) < 1e-5,
      "PLAY then STOP: looping section playback stops")

print("Looper monitoring")
let mon = runModule("looper", params: ["quant": 0], input: sine(300, 0.5),
                    every: { b, n in if b == 10 { n.base[0] = 1 } })
check(abs(mon.outs[0][Int(sr * 0.3)] - sine(300, 0.5)[Int(sr * 0.3)]) < 1e-5, "input is heard while recording (monitor on, dry 0)")

print("Sampler PLAY synced to the clock")
// a 2.4 s loop (not a whole number of beats at 120 BPM) should be stretched to 4 beats = 2.0 s
var odd = [Float](repeating: 0, count: Int(sr * 2.4))
for i in 0..<odd.count { odd[i] = Float(i % 4800) / 4800 - 0.5 }
var loopStarts: [Int] = []
var prevPH: Float = 2
var blockN = 0
let syncRun = runModule("sampler", params: ["sync": 1, "loop": 1], input: [Float](repeating: 0, count: Int(sr * 6)),
                        setup: { n in (n as! SamplerNode).load(StereoAudio(left: odd)); n.base[21] = 1 },
                        every: { b, n in
                            let ph = n.readouts[kPlayheadSlot + 7]
                            if ph >= 0 && ph < prevPH - 0.5 || (prevPH < 0 && ph >= 0) { loopStarts.append(b * kMaxBlock) }
                            prevPH = ph; blockN = b })
let syncBeats = withExtendedLifetime(syncRun.node) { syncRun.node.readouts[7] }
let gaps = zip(loopStarts.dropFirst(), loopStarts).map { Double($0 - $1) / sr }
check(syncBeats == 4 && !gaps.isEmpty && gaps.allSatisfy { abs($0 - 2.0) < 0.01 },
      "2.4 s section plays as 4 beats = 2.00 s per loop at 120 BPM (loops: \(gaps.map { String(format: "%.3f", $0) }))")

print("Stereo")
let stereoLoop = runModule("looper", params: ["quant": 0], input: sine(300, 1),
                           every: { b, n in if b == 5 { n.base[0] = 1 }; if b == 300 { n.base[0] = 1 } })
let lsnap = withExtendedLifetime(stereoLoop.node) { (stereoLoop.node as! SampleBufferNode).snapshot() }
check(lsnap.count > 1000 && lsnap.left.count == lsnap.right.count, "looper records both channels (\(lsnap.count) frames)")

print("Patch migration v5 (stereo ports)")
var old5 = Patch(); old5.version = 4
let oLooper = PatchNode(kind: "looper", x: 0, y: 0), oOut = PatchNode(kind: "out", x: 0, y: 0)
let oIn = PatchNode(kind: "in", x: 0, y: 0)
old5.nodes = [oIn, oLooper, oOut]
old5.cables = [PatchCable(fromNode: oIn.id, fromPort: 4, toNode: oLooper.id, toPort: 1),       // old "rec" gate
               PatchCable(fromNode: oLooper.id, fromPort: 0, toNode: oOut.id, toPort: 0),
               PatchCable(fromNode: oLooper.id, fromPort: 0, toNode: oOut.id, toPort: 1)]
let m5 = old5.migrated()
check(m5.cables[0].toPort == 2, "looper rec-gate cable moves to the new rec inlet")
check(m5.cables[1].fromPort == 0 && m5.cables[2].fromPort == 1, "mono looper → out~ 1+2 becomes L → 1, R → 2")

print("Mixer")
let mixRun = runModule("mix", params: ["chans": 0, "p1": -1], input: sine(200, 0.3))
let mL = rms(mixRun.outs[0][4800...]), mR = rms(mixRun.outs[1][4800...])
check(mL > 0.3 && mR < 1e-4, "channel 1 panned hard left only reaches L (L \(String(format: "%.2f", mL)), R \(String(format: "%.4f", mR)))")
let mixCentre = runModule("mix", params: ["chans": 0], input: sine(200, 0.3))
let cL = rms(mixCentre.outs[0][4800...]), inR2 = rms(sine(200, 0.3)[4800...])
check(abs(cL - inR2) < 0.01, "centre pan = unity on both sides")
var old6 = Patch(); old6.version = 5
let om = PatchNode(kind: "mix", x: 0, y: 0, params: ["g2": 0.5]), ol = PatchNode(kind: "lfo", x: 0, y: 0)
old6.nodes = [om, ol]
old6.cables = [PatchCable(fromNode: ol.id, fromPort: 0, toNode: om.id, toPort: kParamPortBase + 1)]
let m6 = old6.migrated()
check(m6.cables[0].toPort == kParamPortBase + 3 && m6.nodes[0].params["g2"] == 0.5, "old mixer level-2 modulation cable follows its parameter")

print("Instruments (Gillet DSP via the rate bridge)")
for hostRate in [48000.0, 44100.0] {
    for (kind, params, feedNoise, gateIn) in [("texture", ["mix": 1.0 as Float], true, -1),
                                             ("texture", ["mix": 1.0 as Float, "mode": 1], true, -1),     // stretch
                                             ("resonator", [String: Float](), false, 2),
                                             ("macro", ["engine": 8], false, 1),
                                             ("modal", [String: Float](), false, 1),
                                             ("xmod", ["alg": 0, "timbre": 0], true, -1),
                                             ("shapes", ["shape": 0], false, -1),
                                             ("shapes", ["shape": 34, "decay": 300], false, 1),
                                             ("haze", ["mix": 1, "density": 0.8], true, -1)] {
        let h = GraphHost(sampleRate: hostRate)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0), n = PatchNode(kind: kind, x: 0, y: 0, params: params)
        p.nodes = [src, n]
        if feedNoise { p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: n.id, toPort: 0)] }
        if gateIn >= 0 { p.cables.append(PatchCable(fromNode: src.id, fromPort: 1, toNode: n.id, toPort: gateIn)) }
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: 256); ins[1] = .allocate(capacity: 256)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: 256)
        let node = h.node(n.id)!
        var e: Double = 0, cnt = 0, finite = true, t = 0
        let start = Date()
        let total = Int(hostRate * 3)
        while t < total {
            for i in 0..<256 {
                ins[0][i] = Float.random(in: -0.3...0.3)
                ins[1][i] = ((t + i) % Int(hostRate / 2)) < Int(hostRate * 0.02) ? 0.5 : 0   // gate twice a second
            }
            h.process(frames: 256, inputs: ins, inputCount: 2, outputs: outs, outputCount: 1)
            if t > Int(hostRate * 0.5) {
                for o in node.outputs { for i in 0..<kMaxBlock { let v = o[i]; if !v.isFinite { finite = false }; e += Double(v * v); cnt += 1 } }
            }
            t += 256
        }
        let secs = Date().timeIntervalSince(start)
        let r = sqrt(e / Double(max(cnt, 1)))
        check(finite && r > 0.005, String(format: "%@~ at %.1f kHz makes sound (rms %.3f, %.1f%% of one core)",
                                          kind, hostRate / 1000, r, secs / 3 * 100))
    }
}

print("Sequencing")
/// Runs a single module for `seconds` (internal 120 BPM clock) and returns its outlets.
func runSource(_ kind: String, params: [String: Float] = [:], data: [String: [Float]] = [:], seconds: Double = 4,
               setup: ((DSPNode) -> Void)? = nil) -> (DSPNode, [[Float]]) {
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    let n = PatchNode(kind: kind, x: 0, y: 0, params: params, data: data)
    p.nodes = [n]
    h.load(p); h.prepareForStart()
    let node = h.node(n.id)!
    setup?(node)
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: 256)
    ins[0].update(repeating: 0, count: 256)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: 256)
    // capture sample-accurately in 64-frame chunks (node outputs hold one chunk)
    var res = [[Float]](repeating: [], count: node.outputs.count)
    for _ in 0..<Int(seconds * sr / Double(kMaxBlock)) {
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        for (k, o) in node.outputs.enumerated() { res[k].append(contentsOf: UnsafeBufferPointer(start: o, count: kMaxBlock)) }
    }
    return (node, res)
}
/// Like runSource, but every note a cable carries: [outlet][note][samples].
func runNotes(_ kind: String, params: [String: Float] = [:], data: [String: [Float]] = [:], seconds: Double) -> [[[Float]]] {
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    let n = PatchNode(kind: kind, x: 0, y: 0, params: params, data: data)
    p.nodes = [n]
    h.load(p); h.prepareForStart()
    let node = h.node(n.id)!
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
    ins[0].update(repeating: 0, count: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var res = [[[Float]]](repeating: [[Float]](repeating: [], count: kMaxVoices), count: node.outputs.count)
    for _ in 0..<Int(seconds * sr / Double(kMaxBlock)) {
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        for k in 0..<node.outputs.count {
            for v in 0..<kMaxVoices {
                if v < node.outVoices[k] { res[k][v].append(contentsOf: UnsafeBufferPointer(start: node.outputs[k] + v * kMaxBlock, count: kMaxBlock)) }
                else { res[k][v].append(contentsOf: [Float](repeating: 0, count: kMaxBlock)) }
            }
        }
    }
    return res
}
/// Pitch (semitones) at each gate onset.
func notesAtGates(_ pitch: [Float], _ gate: [Float]) -> [Int] {
    var r: [Int] = [], prev: Float = 0
    for i in 0..<gate.count { if gate[i] > 0.2 && prev <= 0.2 { r.append(Int((pitch[i] * 120).rounded())) }; prev = gate[i] }
    return r
}

let seqPitch: [Float] = [0, 3, 7, 12, -5, 0, 5, 10] + [Float](repeating: 0, count: 8)
let seqGate: [Float] = [1, 1, 0, 1, 1, 1, 0, 1] + [Float](repeating: 1, count: 8)
let (_, seqOut) = runSource("seq", params: ["len": 8], data: ["pitch": seqPitch, "gate": seqGate], seconds: 2.1)
let seqNotes = notesAtGates(seqOut[0], seqOut[1])
check(Array(seqNotes.prefix(6)) == [0, 3, 12, -5, 0, 10], "seq~ plays its steps and skips gated-off ones (\(seqNotes.prefix(6)))")

let (_, tOut) = runSource("turing", params: ["change": 0, "len": 8, "scale": 0], seconds: 8)
let tCV = stride(from: 0, to: tOut[2].count, by: Int(sr * 0.125)).map { tOut[2][$0] }   // one sample per 1/16 at 120 BPM
let firstLoop = Array(tCV[16..<24]), secondLoop = Array(tCV[24..<32])
check(firstLoop == secondLoop && Set(firstLoop).count > 1, "turing~ with change 0 locks into a repeating 8-step loop")

var drumHits = [Float](repeating: 0, count: 256)
for st in [0, 4, 8, 12] { drumHits[0 * 32 + st] = 1 }      // lane 1: four on the floor
drumHits[1 * 32 + 4] = 1; drumHits[1 * 32 + 12] = 1        // lane 2: backbeat
let (_, dOut) = runSource("drums", params: ["len": 16], data: ["hits": drumHits], seconds: 4)
func onsets(_ x: [Float]) -> Int { var n = 0, p: Float = 0; for v in x { if v > 0.2 && p <= 0.2 { n += 1 }; p = v }; return n }
check(onsets(dOut[0]) == 8 && onsets(dOut[1]) == 4 && onsets(dOut[2]) == 0, "drums~ fires lane 1 ×8, lane 2 ×4, lane 3 never in 2 bars (\(onsets(dOut[0])), \(onsets(dOut[1])), \(onsets(dOut[2])))")

let (_, kOut) = runSource("keys", params: ["arp": 1, "latch": 1, "rate": Float(Divisions.index("1/8"))], seconds: 2,
                          setup: { n in let k = n as! KeysNode; k.toggleLatched(12); k.toggleLatched(16); k.toggleLatched(19) })
let arpNotes = notesAtGates(kOut[0], kOut[1])
check(Array(arpNotes.prefix(6)) == [0, 4, 7, 0, 4, 7], "keys~ arpeggiates a latched C major chord upwards (\(arpNotes.prefix(6)))")

var rollNotes = [Float](repeating: -1, count: 32); rollNotes[0] = 12; rollNotes[4] = 19; rollNotes[8] = 16
let (_, rOut) = runSource("roll", params: ["len": 16, "low": -12], data: ["grid": RollNode.grid(fromNotes: rollNotes)], seconds: 2)
check(Array(notesAtGates(rOut[0], rOut[1]).prefix(3)) == [0, 7, 4], "roll~ plays the drawn notes (C, G, E)")
do {
    // a chord: C E G on step 0 → voice 1 = C, voice 2 = E, voice 3 = G; voice 4 stays silent
    var g = [Float](repeating: 0, count: 32 * 24)
    for r in [12, 16, 19] { g[r * 32 + 0] = 1 }
    let c = runNotes("roll", params: ["len": 4, "low": -12], data: ["grid": RollNode.grid(fromShown: g, low: -12)], seconds: 0.4)
    let v1 = notesAtGates(c[0][0], c[1][0]).first, v2 = notesAtGates(c[0][1], c[1][1]).first, v3 = notesAtGates(c[0][2], c[1][2]).first
    check(v1 == 0 && v2 == 4 && v3 == 7 && notesAtGates(c[0][3], c[1][3]).isEmpty,
          "roll~ chord on one cable: C, E, G as its three notes (\(String(describing: v1)), \(String(describing: v2)), \(String(describing: v3)))")
    // an old one-note-per-step patch converts to the grid
    var old = Patch(); old.version = 10
    old.nodes = [PatchNode(kind: "roll", x: 0, y: 0, data: ["notes": rollNotes])]
    let m = old.migrated()
    check(m.nodes[0].data["notes"] == nil && m.nodes[0].data["grid"] == RollNode.grid(fromNotes: rollNotes),
          "an older piano roll converts to the chord grid")
}

let (_, tapOut) = runSource("keys", seconds: 0.5, setup: { n in let k = n as! KeysNode; k.pressNote = 7; k.pressCount = 1 })
let tapLen = Double(tapOut[1].filter { $0 > 0.2 }.count) / sr
check(tapLen > 0.07 && tapLen < 0.1 && notesAtGates(tapOut[0], tapOut[1]) == [-5], String(format: "keys~ a press released instantly still plays G for %.0f ms", tapLen * 1000))
let (_, arpTap) = runSource("keys", params: ["arp": 1, "rate": Float(Divisions.index("1 bar"))], seconds: 0.3,
                            setup: { n in let k = n as! KeysNode; k.pressNote = 4; k.pressCount = 1 })
check(notesAtGates(arpTap[0], arpTap[1]).first == -8, "keys~ with the arp on: a tap sounds at once, not on the next bar")

print("Live controls")
let (_, sl) = runSource("slider", params: ["count": 2, "range": 1, "v1": 0.75, "v2": 0, "slew": 0], seconds: 0.1)
check(abs(sl[0].last! - 0.5) < 1e-4 && abs(sl[1].last! + 1) < 1e-4 && sl[4].allSatisfy { $0 == 0 },
      "slider~ ±10 V: fader 1 at 75 % gives +5 V, fader 2 at 0 gives −10 V, unused outlets stay at 0")
let (_, kb) = runSource("knob", params: ["range": 2, "v3": 1, "slew": 0], seconds: 0.1)
check(abs(kb[2].last! - 0.5) < 1e-4, "knob~ 0…5 V: knob 3 fully up gives 5 V")

print("Modulators (Gillet DSP)")
func upCrossings(_ x: [Float]) -> Int { var n = 0, p: Float = 0; for v in x { if v > 0 && p <= 0 { n += 1 }; p = v }; return n }
let (_, chOut) = runSource("chance", params: ["sync": 1, "div": Float(Divisions.index("1/16"))], seconds: 4)
let chT = onsets(chOut[0]) + onsets(chOut[2])
check(chT >= 28 && chT <= 34, "chance~ coin toss: every 1/16 goes to T1 or T3 (\(onsets(chOut[0])) + \(onsets(chOut[2])))")
check(Set(chOut[3].map { ($0 * 1000).rounded() }).count > 4 && chOut[6].allSatisfy { $0.isFinite }, "chance~ X1 produces varying voltages")
let (_, chLoop) = runSource("chance", params: ["sync": 1, "dejavu": 1, "len": 3, "div": Float(Divisions.index("1/4"))], seconds: 16)
let xs = stride(from: Int(sr * 0.25), to: chLoop[3].count, by: Int(sr * 0.5)).map { (chLoop[3][$0] * 1000).rounded() }
// X1 follows T1, which itself loops: the beat-sampled sequence must become periodic (≤ 8 beats)
let period = (1...8).first { p in (20..<24).allSatisfy { xs[$0] == xs[$0 + p] } }
check(period != nil && Set(xs[20...]).count > 1, "chance~ déjà vu 100 % locks into a loop (period \(period.map(String.init) ?? "none") beats)")

check(ShapesNames.names.count == 47, "shapes~ lists all \(ShapesNames.names.count) shapes")

// MARK: - Every module

print("Every module: defaults, every parameter at min / mid / max, silence afterwards (48 kHz)")
/// Runs one module with audio, gates and a slow CV on its inlets. Returns peak per outlet, NaN count, last-second rms.
func exercise(_ kind: String, params: [String: Float], seconds: Double, hostRate: Double = sr, silenceAfter: Double = 0)
    -> (peaks: [Float], nonFinite: Int, tailRMS: Float, cpu: Double) {
    let spec = ModuleRegistry.spec(kind)!
    let h = GraphHost(sampleRate: hostRate)
    var p = Patch()
    let src = PatchNode(kind: "in", x: 0, y: 0)
    let n = PatchNode(kind: kind, x: 0, y: 0, params: params)
    p.nodes = [src, n]
    for (k, name) in spec.inputs.enumerated() {
        let lname = name.lowercased()
        let port: Int
        if ["trig", "gate", "clock", "clk", "strum", "seed", "play", "reset", "t clk", "x clk"].contains(where: { lname.contains($0) }) { port = 2 }
        else if lname.contains("pitch") || lname == "freeze" || lname == "rec" || lname == "sc" { continue }
        else { port = k % 2 }
        p.cables.append(PatchCable(fromNode: src.id, fromPort: port, toNode: n.id, toPort: k))
    }
    h.load(p); h.prepareForStart()
    let node = h.node(n.id)!
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
    for c in 0..<4 { ins[c] = .allocate(capacity: kMaxBlock) }
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var peaks = [Float](repeating: 0, count: node.outputs.count)
    var tail: Double = 0, tailN = 0
    let total = Int((seconds + silenceAfter) * hostRate) / kMaxBlock
    let loud = Int(seconds * hostRate) / kMaxBlock
    var t = 0
    let start = Date()
    for b in 0..<total {
        let on = b < loud
        for i in 0..<kMaxBlock {
            let ph = Double(t + i) / hostRate
            ins[0][i] = on ? Float(0.5 * Foundation.sin(2 * .pi * 220 * ph)) : 0
            ins[1][i] = on ? Float(0.4 * Foundation.sin(2 * .pi * 331 * ph)) : 0
            ins[2][i] = on && (t + i) % Int(hostRate / 4) < Int(hostRate * 0.02) ? 0.8 : 0
            ins[3][i] = on ? Float(0.3 * Foundation.sin(2 * .pi * 0.5 * ph)) : 0
        }
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 4, outputs: outs, outputCount: 1)
        for (k, o) in node.outputs.enumerated() {
            for i in 0..<kMaxBlock { peaks[k] = max(peaks[k], abs(o[i])) }
            if b >= total - Int(hostRate) / kMaxBlock { for i in 0..<kMaxBlock { tail += Double(o[i] * o[i]); tailN += 1 } }
        }
        t += kMaxBlock
    }
    let cpu = Date().timeIntervalSince(start) / (seconds + silenceAfter)
    return (peaks, node.nonFinite, Float(sqrt(tail / Double(max(tailN, 1)))), cpu)
}

/// Sound sources and modulators keep producing output in silence; effects should settle.
let selfSounding: Set<String> = ["clock", "keys", "seq", "turing", "roll", "drums", "lfo", "atten", "slider", "knob",
                                 "chance", "macro", "shapes", "modal", "resonator", "looper",
                                 "sampler", "grain", "stretch", "texture", "haze", "in", "env", "xmod", "wave", "chord"]
var moduleProblems: [String] = []
var sweepRuns = 0
var sweepPeak: Float = 0
var cpuTable: [(String, Double)] = []
for spec in ModuleRegistry.all where spec.kind != "in" && spec.kind != "out" && spec.kind != "rec" {
    for rate in [48000.0, 44100.0] {
        let r = exercise(spec.kind, params: [:], seconds: 1.5, hostRate: rate, silenceAfter: 3)
        if rate == 48000 { cpuTable.append((spec.name, r.cpu)) }
        if r.nonFinite > 0 { moduleProblems.append("\(spec.name) @\(Int(rate)): \(r.nonFinite) NaN/inf samples with default settings") }
        for (k, pk) in r.peaks.enumerated() where pk > 8 { moduleProblems.append("\(spec.name) @\(Int(rate)): outlet \(spec.outputs[k]) peaks at \(pk)") }
        if !selfSounding.contains(spec.kind) && r.tailRMS > 0.02 {
            moduleProblems.append("\(spec.name) @\(Int(rate)): still \(String(format: "%.3f", r.tailRMS)) rms 3 s after the input stopped")
        }
    }
    for (i, ps) in spec.params.enumerated() where !ps.isTrigger {
        for v in [ps.min, (ps.min + ps.max) / 2, ps.max] {
            let r = exercise(spec.kind, params: [ps.key: v], seconds: 0.6, silenceAfter: 0.4)
            sweepRuns += 1; sweepPeak = max(sweepPeak, r.peaks.max() ?? 0)
            if r.nonFinite > 0 { moduleProblems.append("\(spec.name) \(ps.name)=\(ps.display(v)): \(r.nonFinite) NaN/inf samples") }
            for (k, pk) in r.peaks.enumerated() where pk > 8 || !pk.isFinite {
                moduleProblems.append("\(spec.name) \(ps.name)=\(ps.display(v)): outlet \(spec.outputs[k]) peaks at \(pk)")
            }
            _ = i
        }
    }
}
for p in moduleProblems { print("    ! \(p)") }
print("    \(sweepRuns) parameter runs, loudest outlet \(sweepPeak)")
// the checks must be able to fail: a deliberately broken run is caught
let canary = exercise("gain", params: ["gain": 24], seconds: 0.3)
check(canary.peaks[0] > 4, "sanity: the sweep sees a loud signal when there is one (+24 dB gain → peak \(canary.peaks[0]))")
check(moduleProblems.isEmpty, "every module is finite, bounded and settles, at defaults and with every parameter at min / mid / max (\(moduleProblems.count) problems)")
let heavy = cpuTable.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0) \(String(format: "%.1f%%", $0.1 * 100))" }
print("    heaviest (share of one core, alone): \(heavy.joined(separator: ", "))")

print("Every module: save / reload")
var allPatch = Patch()
for (i, spec) in ModuleRegistry.all.enumerated() {
    var n = PatchNode(kind: spec.kind, x: Double(i * 10), y: 0)
    for ps in spec.params where !ps.isTrigger { n.params[ps.key] = ps.max }
    n.w = 400; n.dh = 300
    allPatch.nodes.append(n)
}
let encoded = try! JSONEncoder().encode(allPatch)
let decoded = try! JSONDecoder().decode(Patch.self, from: encoded).migrated()
check(decoded.nodes == allPatch.nodes, "a patch with every module (all knobs at max, resized) survives save + load unchanged")
let bigHost = GraphHost(sampleRate: sr)
bigHost.load(decoded)
check(decoded.nodes.allSatisfy { bigHost.node($0.id) != nil }, "every module in it loads into the engine")

print("Every module: box layout")
let layoutProblems = MainActor.assumeIsolated { LayoutCheck.run() }
for p in layoutProblems.prefix(30) { print("    ! \(p)") }
check(layoutProblems.isEmpty, "every box keeps its ports, rows and display inside its frame — default, resized, collapsed, fully patched (\(layoutProblems.count) problems)")

print("slider~ / knob~ into parameters")
do {
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    let ctl = PatchNode(kind: "slider", x: 0, y: 0, params: ["v1": 0, "slew": 0])
    let lfo = PatchNode(kind: "lfo", x: 0, y: 0, params: ["rate": 20])      // knob at max …
    p.nodes = [ctl, lfo]
    p.cables = [PatchCable(fromNode: ctl.id, fromPort: 0, toNode: lfo.id, toPort: kParamPortBase + 2)]
    h.load(p); h.prepareForStart()
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    func rateAt(_ pos: Float) -> Float {
        h.node(ctl.id)!.base[ControlsLayout.valueIndex(0)] = pos
        for _ in 0..<20 { h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1) }
        return h.node(lfo.id)!.params[2]
    }
    let lo = rateAt(0), mid = rateAt(0.5), hi = rateAt(1)
    check(abs(lo - 0.01) < 0.001 && abs(hi - 20) < 0.01 && mid > 0.3 && mid < 0.6,
          String(format: "a fader sets the parameter across its whole range, whatever the knob says (%.2f / %.2f / %.1f Hz)", lo, mid, hi))
}

print("slider~ / knob~ locked to their parameters, both ways")
do {
    var p = Patch()
    let ctl = PatchNode(kind: "knob", x: 0, y: 0)
    let lfo = PatchNode(kind: "lfo", x: 0, y: 0), comp = PatchNode(kind: "comp", x: 0, y: 0)
    p.nodes = [ctl, lfo, comp]
    p.cables = [PatchCable(fromNode: ctl.id, fromPort: 0, toNode: lfo.id, toPort: kParamPortBase + 2),     // rate (exp)
                PatchCable(fromNode: ctl.id, fromPort: 0, toNode: comp.id, toPort: kParamPortBase + 0)]    // peak reduction
    let rate = ModuleRegistry.spec("lfo")!.params[2]
    // knob moved → both targets follow
    let a = ControlLink.updates(p, changed: ctl.id, index: ControlsLayout.valueIndex(0), value: 1)
    check(a.contains(.init(node: lfo.id, index: 2, value: 20)) && a.contains(.init(node: comp.id, index: 0, value: 1)) && a.count == 2,
          "turning the knob moves every parameter it's patched into")
    // target row moved → knob follows, and its other target follows too
    let b = ControlLink.updates(p, changed: lfo.id, index: 2, value: rate.value(fromNormalized: 0.25))
    let knobPos = b.first { $0.node == ctl.id }?.value ?? -1
    check(abs(knobPos - 0.25) < 1e-4 && b.contains { $0.node == comp.id && abs($0.value - 0.25) < 1e-4 } && !b.contains { $0.node == lfo.id },
          "moving the parameter's own row moves the knob (and the knob's other target), not itself")
    // loading a patch where they disagree: the row takes the fader's position
    var loaded = p
    loaded.nodes[0].params["v1"] = 0.5
    loaded.nodes[1].params["rate"] = 7
    let fixed = ControlLink.reconciled(loaded)
    check(abs((fixed.nodes[1].params["rate"] ?? 0) - rate.value(fromNormalized: 0.5)) < 1e-4,
          "a loaded patch shows the parameter where the fader actually puts it")
    // an unrelated parameter or module changes nothing
    check(ControlLink.updates(p, changed: lfo.id, index: 4, value: 0.3).isEmpty
          && ControlLink.updates(p, changed: ctl.id, index: ControlsLayout.valueIndex(1), value: 0.3).isEmpty,
          "parameters and controls that aren't patched together stay independent")
}

print("Outlet activity")
do {
    let (lfoNode, _) = runSource("lfo", params: ["depth": 1], seconds: 0.5)
    let (seqNode, seqOut) = runSource("seq", seconds: 0.26)
    let gateHigh = seqOut[1].last! > 0.2
    check(lfoNode.outLevel[0] > 0.5, "lfo~ outlet shows activity (\(lfoNode.outLevel[0]))")
    check(seqNode.outLevel[1] > 0.3 || !gateHigh, "seq~ gate outlet shows activity after a step (\(seqNode.outLevel[1]))")
    let (idle, _) = runSource("env", seconds: 1)     // envelope follower with nothing coming in: idle
    check(idle.outLevel[0] < 0.01, "an idle envelope's outlet stays dark (\(idle.outLevel[0]))")
}

print("Undo / redo")
do {
    var a = Patch(); a.nodes = [PatchNode(kind: "lfo", x: 0, y: 0)]
    var b = a; b.nodes[0].params["rate"] = 3
    var c = b; c.nodes.append(PatchNode(kind: "delay", x: 100, y: 0))
    var h = UndoHistory(committed: a)
    h.commit(a)                                   // no change → no step
    check(!h.canUndo, "an unchanged patch isn't an undo step")
    h.commit(b); h.commit(c)
    check(h.undo() == b && h.undo() == a && h.undo() == nil, "undo walks back through each step to the start")
    check(h.redo() == b && h.redo() == c && h.redo() == nil, "redo walks forward again")
    _ = h.undo()                                  // at b
    var d = b; d.nodes[0].x = 50
    h.commit(d)
    check(!h.canRedo && h.undo() == b, "a new edit after undo clears redo")
    var big = UndoHistory(committed: a, limit: 5)
    for i in 0..<20 { var p = a; p.nodes[0].x = Double(i + 1); big.commit(p) }
    check(big.undoStack.count == 5, "history is capped (\(big.undoStack.count) steps kept)")
}

print("div~ clock divider")
do {
    // a 4 Hz external clock (10 ms pulses) for 4 s = 16 pulses
    // params here use plain ÷n numbers for d1…d8 (default ÷k on outlet k); "x<k>": m asks for ×m
    func run(_ given: [String: Float], reset: Int? = nil) -> [[Float]] {
        var params = given.filter { !$0.key.hasPrefix("d") && !$0.key.hasPrefix("x") }
        for k in 1...8 {
            if let m = given["x\(k)"] { params["d\(k)"] = Float(DividerLayout.ratioIndex(-Int(m))) }
            else { params["d\(k)"] = Float(DividerLayout.ratioIndex(Int(given["d\(k)"] ?? Float(k)))) }
        }
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0), d = PatchNode(kind: "div", x: 0, y: 0, params: params)
        p.nodes = [src, d]
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: d.id, toPort: 0),
                    PatchCable(fromNode: src.id, fromPort: 1, toNode: d.id, toPort: 1)]
        h.load(p); h.prepareForStart()
        let node = h.node(d.id)!
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: kMaxBlock); ins[1] = .allocate(capacity: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var res = [[Float]](repeating: [], count: 8)
        var t = 0
        for _ in 0..<Int(4 * sr) / kMaxBlock {
            for i in 0..<kMaxBlock {
                ins[0][i] = (t + i) % 12000 < 480 ? 0.8 : 0
                ins[1][i] = reset.map { (t + i) >= $0 && (t + i) < $0 + 100 } == true ? 0.8 : 0
            }
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 2, outputs: outs, outputCount: 1)
            for k in 0..<8 { res[k].append(contentsOf: UnsafeBufferPointer(start: node.outputs[k], count: kMaxBlock)) }
            t += kMaxBlock
        }
        return res
    }
    let r = run([:])
    let counts = r.map { onsets($0) }
    let expected = (1...8).map { (16 + $0 - 1) / $0 }      // fires on pulse 1, 1+n, 1+2n …
    check(counts == expected, "÷1…÷8 fire \(counts) times for 16 clock pulses (expected \(expected))")
    let firstOnsets = r.map { $0.firstIndex { $0 > 0.2 } ?? -1 }
    check(Set(firstOnsets).count == 1 && firstOnsets[0] == 0, "all eight start together on the first pulse")
    let sq = run(["mode": 1, "d2": 4])
    let high = Double(sq[1].prefix(Int(sr * 4)).filter { $0 > 0.2 }.count) / (sr * 4)
    check(abs(high - 0.5) < 0.02 && onsets(sq[1]) == 4, String(format: "50%% mode: ÷4 is a square wave (%.0f%% high, %d cycles)", high * 100, onsets(sq[1])))
    let rr = run(["d4": 4], reset: 12000 + 1000)
    let fires = rr[3].indices.filter { $0 > 0 && rr[3][$0] > 0.2 && rr[3][$0 - 1] <= 0.2 }.map { $0 / 12000 }
    // pulse 1 fires at sample 0; after the reset between pulses 2 and 3, ÷4 restarts: 3, 7, 11 (not 5, 9, 13)
    check(Array(fires.prefix(3)) == [2, 6, 10], "reset lines the divisions up again (÷4 then fired on pulses \(fires.prefix(3).map { $0 + 1 }))")
    // faster: ×2 / ×4 / ×8 of a patched 4 Hz clock (16 pulses in 4 s)
    let fast = run(["x1": 2, "x2": 4, "x3": 8, "x4": 3])
    let fc = (0..<4).map { onsets(fast[$0]) }
    check(abs(fc[0] - 32) <= 1 && abs(fc[1] - 64) <= 1 && abs(fc[2] - 128) <= 1 && abs(fc[3] - 48) <= 1,
          "× outlets run faster than a patched clock: ×2 ×4 ×8 ×3 give \(fc) pulses for 16 (expected ≈ 32, 64, 128, 48)")
    let sqf = run(["mode": 1, "x1": 4])
    let hi = Double(sqf[0].prefix(Int(sr * 4)).filter { $0 > 0.2 }.count) / (sr * 4)
    check(abs(hi - 0.5) < 0.03, String(format: "50%% mode: ×4 is a square wave too (%.0f%% high)", hi * 100))
    var oldDiv = Patch(); oldDiv.version = 8
    oldDiv.nodes = [PatchNode(kind: "div", x: 0, y: 0, params: ["d3": 7])]
    let md = oldDiv.migrated().nodes[0].params
    check(DividerLayout.ratioNames[Int(md["d3"]!)] == "÷7" && DividerLayout.ratioNames[Int(md["d1"]!)] == "×1" && DividerLayout.ratioNames[Int(md["d8"]!)] == "÷8",
          "older patches keep their divisions (÷7 stays ÷7, untouched outlets keep ÷1 … ÷8)")
    let (_, appX) = runSource("div", params: ["base": Float(DividerLayout.baseNames.firstIndex(of: "1/4")!)], seconds: 4)
    check(onsets(appX[0]) == 32 && onsets(appX[1]) == 16 && onsets(appX[2]) == 8, "on the app clock the defaults ×4 ×2 ×1 give \(onsets(appX[0])), \(onsets(appX[1])), \(onsets(appX[2])) pulses in 4 s at 1/4 (expected 32, 16, 8)")
    let (_, appClk) = runSource("div", params: ["base": Float(DividerLayout.baseNames.firstIndex(of: "1/4")!), "d1": Float(DividerLayout.ratioIndex(1)), "d2": Float(DividerLayout.ratioIndex(2))], seconds: 4)
    check(onsets(appClk[0]) == 8 && onsets(appClk[1]) == 4, "with nothing patched it follows the app clock (1/4 at 120 BPM: \(onsets(appClk[0])) and \(onsets(appClk[1])) pulses)")
}

print("Division on turing~ / seq~ (app clock and a patched clock)")
do {
    var counts: [String: Int] = [:]
    for d in ["1/32", "1/16", "1/8", "1/4", "1 bar"] {
        let (_, o) = runSource("turing", params: ["div": Float(Divisions.index(d)), "notes": 1, "gatelen": 0.3], seconds: 4)
        counts[d] = onsets(o[1])
    }
    check(counts == ["1/32": 64, "1/16": 32, "1/8": 16, "1/4": 8, "1 bar": 2], "turing~ on the app clock follows the division (4 s at 120 BPM: \(counts))")
    // patched 1/16 pulses (8 Hz, 4 s = 32 pulses): the division counts them as sixteenths
    func clocked(_ kind: String, _ div: String, _ extra: [String: Float] = [:]) -> Int {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        var prm = extra; prm["div"] = Float(Divisions.index(div))
        let src = PatchNode(kind: "in", x: 0, y: 0), t = PatchNode(kind: kind, x: 0, y: 0, params: prm)
        p.nodes = [src, t]
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: t.id, toPort: 0)]
        h.load(p); h.prepareForStart()
        let node = h.node(t.id)!
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
        ins[0] = .allocate(capacity: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var gate: [Float] = []
        var t0 = 0
        for _ in 0..<Int(4 * sr) / kMaxBlock {
            for i in 0..<kMaxBlock { ins[0][i] = (t0 + i) % 6000 < 240 ? 0.8 : 0 }
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 1)
            gate.append(contentsOf: UnsafeBufferPointer(start: node.outputs[1], count: kMaxBlock))
            t0 += kMaxBlock
        }
        return onsets(gate)
    }
    let ext = ["1/32", "1/16", "1/8", "1/4"].map { clocked("turing", $0, ["notes": 1, "gatelen": 0.3]) }
    check(ext == [64, 32, 16, 8], "turing~ with a patched clock: 1/32, 1/16, 1/8, 1/4 give \(ext) steps for 32 pulses (expected [64, 32, 16, 8])")
    let seqExt = ["1/16", "1/8"].map { clocked("seq", $0, ["gatelen": 0.3]) }
    check(seqExt[0] > 0 && seqExt[0] == 2 * seqExt[1], "seq~ with a patched clock: 1/8 plays half as many steps as 1/16 (\(seqExt))")
}

print("div~ internal clock down to 1/64")
do {
    let i64 = Float(DividerLayout.baseNames.firstIndex(of: "1/64")!), i32 = Float(DividerLayout.baseNames.firstIndex(of: "1/32")!)
    let d12: [String: Float] = ["d1": Float(DividerLayout.ratioIndex(1)), "d2": Float(DividerLayout.ratioIndex(2))]
    let (_, a) = runSource("div", params: d12.merging(["base": i64]) { $1 }, seconds: 4)
    let (_, b) = runSource("div", params: d12.merging(["base": i32]) { $1 }, seconds: 4)
    check(onsets(a[0]) == 128 && onsets(a[1]) == 64 && onsets(b[0]) == 64,
          "1/64 at 120 BPM: \(onsets(a[0])) pulses in 4 s (÷2: \(onsets(a[1]))), 1/32: \(onsets(b[0]))")
    var old = Patch(); old.version = 7
    old.nodes = [PatchNode(kind: "div", x: 0, y: 0, params: ["base": Float(Divisions.index("1/4"))])]
    let m = old.migrated()
    check(DividerLayout.baseNames[Int(m.nodes[0].params["base"]!)] == "1/4", "older patches keep their div~ clock (1/4 stays 1/4 after the list grew)")
}

print("Automation lanes")
do {
    // gain~'s gain parameter follows a ramp lane −60 → 0 dB over the 4-bar loop
    let spec = ModuleRegistry.spec("gain")!
    let gi = spec.paramIndex("gain")!
    let ramp = (0..<DSPNode.autoSlots).map { Float(-60 + 60 * Double($0) / Double(DSPNode.autoSlots)) }
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    var g = PatchNode(kind: "gain", x: 0, y: 0, params: ["gain": -6])
    g.data[DSPNode.autoKey("gain")] = ramp
    p.nodes = [g]
    h.load(p); h.prepareForStart()
    let n = h.node(g.id)!
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
    ins[0].update(repeating: 0, count: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var worst: Float = 0, samples = 0
    for b in 0..<Int(8 * sr) / kMaxBlock {
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        if b % 50 == 0 {
            let pos = n.autoPosition
            let i0 = min(Int(pos), DSPNode.autoSlots - 1), i1 = (i0 + 1) % DSPNode.autoSlots
            let want = ramp[i0] + (ramp[i1] - ramp[i0]) * Float(pos - Double(i0))
            worst = max(worst, abs(n.params[gi] - want)); samples += 1
        }
    }
    check(n.autoCount == 1 && worst < 0.01 && samples > 50, "a saved lane plays back: gain follows it (worst error \(worst) dB over \(samples) checks)")
    let at = n.autoPosition
    check(at > 0 && at < Double(DSPNode.autoSlots), "lane position moves with the clock (slot \(Int(at)) of \(DSPNode.autoSlots))")
    n.autoHold[gi] = true
    h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
    check(n.params[gi] == -6, "while recording, the hand wins (gain = knob \(n.params[gi]) dB)")
    n.autoHold[gi] = false
    // undo-style reload without the lane switches it off
    var p2 = p; p2.nodes[0].data = [:]
    h.load(p2)
    h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
    check(n.autoCount == 0 && !n.autoOn[gi] && n.params[gi] == -6, "removing the lane (reset / undo) hands the parameter back to its knob")
    // round trip through JSON
    let enc = try! JSONEncoder().encode(p)
    let dec = try! JSONDecoder().decode(Patch.self, from: enc)
    check(dec.nodes[0].data[DSPNode.autoKey("gain")] == ramp, "lanes are saved with the patch")
    // a whole-number parameter steps rather than glides
    let h3 = GraphHost(sampleRate: sr)
    var p3 = Patch()
    var lf = PatchNode(kind: "lfo", x: 0, y: 0)
    let lspec = ModuleRegistry.spec("lfo")!
    if let si = lspec.params.firstIndex(where: { if case .choice = $0.kind { return true }; return false }) {
        let key = lspec.params[si].key
        lf.data[DSPNode.autoKey(key)] = (0..<DSPNode.autoSlots).map { Float($0 % 2) }
        p3.nodes = [lf]
        h3.load(p3); h3.prepareForStart()
        var whole = true
        for _ in 0..<400 {
            h3.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            let v = h3.node(lf.id)!.params[si]
            if v != v.rounded() { whole = false }
        }
        check(whole, "choice parameters step through their recorded values (lfo \(key))")
    }
}

print("wave~ (draw-your-own wavetable synth)")
do {
    /// zero crossings upward per second → frequency
    func hz(_ x: [Float]) -> Double {
        var c = 0
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { c += 1 }
        return Double(c) / (Double(x.count) / sr)
    }
    let (_, o) = runSource("wave", params: ["pos": 0], seconds: 1.05)
    let f = hz(Array(o[0].suffix(Int(sr))))
    check(abs(f - 261.63) < 2, "wave~ sine plays middle C at 0 st (\(f) Hz)")
    let (_, o2) = runSource("wave", params: ["pos": 0, "note": 12], seconds: 1.05)
    let f2 = hz(Array(o2[0].suffix(Int(sr))))
    check(abs(f2 - 523.25) < 3, "+12 st is an octave up (\(f2) Hz)")
    // position 2 = the saw (wave 3): a sharp edge, so lots of upper harmonics compared with the sine at 0
    func roughness(_ x: [Float]) -> Float { var r: Float = 0; for i in 1..<x.count { r += abs(x[i] - x[i - 1]) }; return r }
    let (_, sine) = runSource("wave", params: ["pos": 0], seconds: 0.5)
    let (_, saw) = runSource("wave", params: ["pos": 2], seconds: 0.5)
    check(roughness(Array(saw[0].suffix(12000))) > roughness(Array(sine[0].suffix(12000))) * 1.3, "position moves from the sine to the saw")
    // a drawn square played very high stays band-limited: no step bigger than a smooth wave of that pitch could make
    let sq = [Float](repeating: 0, count: 256 * 3) + WavetableNode.shape("square")
    let (_, hi) = runSource("wave", params: ["pos": 3, "note": 48], data: ["wave": sq], seconds: 0.3)
    let tail = Array(hi[0].suffix(6000))
    let maxStep = zip(tail.dropFirst(), tail).map { abs($0 - $1) }.max() ?? 0
    check(maxStep < 1.2, "a square drawn and played at +48 st is band-limited (largest sample step \(maxStep))")
    // redrawing a wave is quick enough to do on every pencil move
    let w = WavetableNode(spec: ModuleRegistry.spec("wave")!, sampleRate: sr)
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<20 { w.drawn[5] = Float.random(in: -1...1); w.rebuild(frame: 0) }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 20
    check(ms < 8, "rebuilding a drawn wave takes \(String(format: "%.2f", ms)) ms")
    w.setData("wave", WavetableNode.shape("saw") + WavetableNode.shape("saw") + WavetableNode.shape("saw") + WavetableNode.shape("saw"))
    check(abs(w.waveData[0] - 1) < 1e-4 && w.waveData.count == 1024, "drawn waves are saved and loaded")
}

print("turing~ loops up to 64 steps")
do {
    let spec = ModuleRegistry.spec("turing")!.params[1]
    check(spec.snapped(20) == 16 && spec.snapped(40) == 32 && spec.snapped(60) == 64 && spec.snapped(5) == 5 && spec.snapped(1) == 2,
          "length snaps to 2…16, 32, 64")
    for len in [32, 64] {
        // locked (change 0): the pitch sequence repeats exactly every `len` steps, and not sooner
        let (_, o) = runSource("turing", params: ["change": 0, "len": Float(len), "notes": 1, "div": Float(Divisions.index("1/32"))], seconds: Double(len) * 3 * 0.0625 + 0.3)
        let n = notesAtGates(o[0], o[1])
        let ok = n.count >= len * 2 + 1 && (0..<len).allSatisfy { n[$0] == n[$0 + len] }
        let shorter = (1..<len).filter { len % $0 == 0 }.contains { p in (0..<len).allSatisfy { n[$0] == n[($0 + p) % len] } }
        check(ok && !shorter, "a locked \(len)-step loop repeats every \(len) steps")
    }
}

print("Chords: roll~ on one cable into a synth")
do {
    /// how strongly `hz` is in x (Goertzel)
    func power(_ x: [Float], _ hz: Double) -> Double {
        let w = 2 * Double.pi * hz / sr, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
    }
    for kind in ["wave", "shapes", "macro"] {
        var g = [Float](repeating: 0, count: 32 * 24)
        for r in [12, 16, 19] { g[r * 32 + 0] = 1 }               // C E G on every step 0
        var p = Patch()
        let roll = PatchNode(kind: "roll", x: 0, y: 0, params: ["len": 1, "low": -12, "gatelen": 1], data: ["grid": RollNode.grid(fromShown: g, low: -12)])
        let params: [String: Float] = kind == "wave" ? [:] : (kind == "shapes" ? ["shape": 3] : ["engine": 8, "decay": 1])
        let syn = PatchNode(kind: kind, x: 0, y: 0, params: params)
        p.nodes = [roll, syn]
        p.cables = [PatchCable(fromNode: roll.id, fromPort: 0, toNode: syn.id, toPort: 0),
                    PatchCable(fromNode: roll.id, fromPort: 1, toNode: syn.id, toPort: 1)]
        let h = GraphHost(sampleRate: sr)
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        ins[0].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var y: [Float] = []
        for _ in 0..<Int(0.5 * sr / Double(kMaxBlock)) {
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            y.append(contentsOf: UnsafeBufferPointer(start: h.node(syn.id)!.outputs[0], count: kMaxBlock))
        }
        let tail = Array(y.suffix(12000))
        let off = power(tail, 300)
        check(power(tail, 261.63) > off * 20 && power(tail, 329.63) > off * 20 && power(tail, 392.0) > off * 20,
              "\(kind)~ plays C, E and G from one pitch / gate cable")
        // unplugged: back to a single note
        p.cables = []
        h.load(p)
        check(h.node(syn.id)!.inVoices[0] >= 1, "\(kind)~ unplugged keeps working")
    }
    // patches saved with 0.3's separate voice outlets / inlets: those cables go, the rest stay
    var old = Patch(); old.version = 11
    let r = PatchNode(kind: "roll", x: 0, y: 0), w = PatchNode(kind: "wave", x: 0, y: 0, params: ["voices": 2])
    old.nodes = [r, w]
    old.cables = [PatchCable(fromNode: r.id, fromPort: 0, toNode: w.id, toPort: 0), PatchCable(fromNode: r.id, fromPort: 1, toNode: w.id, toPort: 1),
                  PatchCable(fromNode: r.id, fromPort: 3, toNode: w.id, toPort: 2), PatchCable(fromNode: r.id, fromPort: 4, toNode: w.id, toPort: 3)]
    let m = old.migrated()
    check(m.cables.count == 2 && m.nodes[1].params["voices"] == nil, "0.3 patches lose the separate voice cables, keep pitch / gate")
}

print("chord~")
do {
    func chord(_ params: [String: Float], seconds: Double = 0.2) -> [Int] {
        let o = runNotes("chord", params: params, seconds: seconds)
        return (0..<4).map { Int((o[0][$0].last! * 120).rounded()) }
    }
    check(Array(chord(["size": 0, "voices": 0, "lead": 0]).prefix(3)) == [0, 4, 7], "C major, degree I, triad: C E G")
    check(chord(["degree": 4, "voices": 1, "lead": 0]) == [7, 11, 14, 17], "degree V seventh: G B D F (G7)")
    check(chord(["mode": 1, "key": 9, "type": 4, "voices": 1, "lead": 0]) == [9, 12, 16, 19], "free: A m7 = A C E G")
    check(chord(["size": 0, "voices": 0, "inv": 1, "lead": 0]).prefix(3) == [4, 7, 12], "first inversion: E G C")
    // voice leading: from C (I) to F (IV) the closest voicing moves less than the plain root position
    let viaLead = ChordNode.build(mode: 0, key: 0, scale: 0, degree: 3, size: 0, type: 0, voices: 3, inversion: 0, spread: 0,
                                  octave: 0, shift: 0, previous: [0, 4, 7]).notes
    let plain = ChordNode.build(mode: 0, key: 0, scale: 0, degree: 3, size: 0, type: 0, voices: 3, inversion: 0, spread: 0,
                                octave: 0, shift: 0, previous: nil).notes
    let move: ([Float]) -> Float = { c in zip(c, [Float(0), 4, 7]).reduce(0) { $0 + abs($1.0 - $1.1) } }
    check(move(viaLead) < move(plain) && Set(viaLead.map { (Int($0) % 12 + 12) % 12 }) == [5, 9, 0],
          "voice leading: C → F moves \(move(viaLead)) semitones instead of \(move(plain)) (\(viaLead))")
    // strum: with a gate patched, each voice opens later than the one below
    var p = Patch()
    let clk = PatchNode(kind: "lfo", x: 0, y: 0, params: ["shape": 3, "rate": 2, "depth": 0.5, "offset": 0.5])
    let ch = PatchNode(kind: "chord", x: 0, y: 0, params: ["strum": 50, "voices": 0])
    p.nodes = [clk, ch]
    p.cables = [PatchCable(fromNode: clk.id, fromPort: 0, toNode: ch.id, toPort: 1)]
    let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var g: [[Float]] = [[], [], []]
    for _ in 0..<Int(0.4 * sr / Double(kMaxBlock)) {
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        for k in 0..<3 { g[k].append(contentsOf: UnsafeBufferPointer(start: h.node(ch.id)!.outputs[1] + k * kMaxBlock, count: kMaxBlock)) }
    }
    let first = g.map { $0.firstIndex { $0 > 0.2 } ?? -1 }
    let gap = Int(0.05 * sr)
    check(first[0] >= 0 && abs((first[1] - first[0]) - gap) < 70 && abs((first[2] - first[1]) - gap) < 70,
          "strum 50 ms: the voices open 50 ms apart (\(first))")
}

print("chord~ octave with voice leading")
do {
    // voice leading on: raising the octave must move the chord up an octave at once, not get pulled back
    var p = Patch()
    let ch = PatchNode(kind: "chord", x: 0, y: 0, params: ["voices": 0, "lead": 1])
    p.nodes = [ch]
    let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    let node = h.node(ch.id)!
    func notes() -> [Int] {
        for _ in 0..<8 { h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1) }
        return (0..<3).map { Int((node.outputs[0][$0 * kMaxBlock + kMaxBlock - 1] * 120).rounded()) }
    }
    let a = notes()
    var seen = [a]
    for o in [1, 2, 1, 0, -1] { node.base[10] = Float(o); seen.append(notes()) }
    let ok = zip(seen, [0, 1, 2, 1, 0, -1]).allSatisfy { c, o in c == a.map { $0 + 12 * o } }
    check(ok, "each octave step moves the chord exactly 12 semitones (\(seen))")
}

print("rack~ pad outlets")
do {
    // pad 1 played with its own outlet patched: it comes out there, not in L / R; unpatched it's back in the mix
    func play(patched: Bool) -> (main: Float, own: Float) {
        var p = Patch()
        let rk = PatchNode(kind: "rack", x: 0, y: 0, data: ["hits": [Float](repeating: 0, count: RackLayout.pads * RackLayout.steps)])
        let at = PatchNode(kind: "atten", x: 0, y: 0)
        p.nodes = [rk, at]
        if patched { p.cables = [PatchCable(fromNode: rk.id, fromPort: 2, toNode: at.id, toPort: 0)] }
        let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        let node = h.node(rk.id)! as! RackNode
        node.audition = 0
        var main: [Float] = [], own: [Float] = []
        for _ in 0..<Int(0.3 * sr / Double(kMaxBlock)) {
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            main += UnsafeBufferPointer(start: node.outputs[0], count: kMaxBlock)
            own += UnsafeBufferPointer(start: node.outputs[2], count: kMaxBlock)
        }
        return (rms(main[...]), rms(own[...]))
    }
    let a = play(patched: true), b = play(patched: false)
    check(a.own > 0.01 && a.main < 1e-6, "pad 1's outlet patched: it plays only there (own \(a.own), main \(a.main))")
    check(b.main > 0.01 && b.own < 1e-6, "unpatched: pad 1 is back in the main L / R (main \(b.main))")
    check(ModuleRegistry.spec("rack")!.outputs.count == 18, "rack~ has L, R and one outlet per pad")
}

print("drumsynth voice outlets")
do {
    // voice 1 played with its own outlet patched: it comes out there, not in L / R
    func play(patched: Bool) -> (main: Float, own: Float) {
        var p = Patch()
        let ds = PatchNode(kind: "drumsynth", x: 0, y: 0, data: ["hits": [Float](repeating: 0, count: DrumSynthLayout.voices * DrumSynthLayout.steps)])
        let at = PatchNode(kind: "atten", x: 0, y: 0)
        p.nodes = [ds, at]
        if patched { p.cables = [PatchCable(fromNode: ds.id, fromPort: 2, toNode: at.id, toPort: 0)] }
        let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        let node = h.node(ds.id)! as! DrumSynthNode
        node.audition = 0
        var main: [Float] = [], own: [Float] = []
        for _ in 0..<Int(0.3 * sr / Double(kMaxBlock)) {
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            main += UnsafeBufferPointer(start: node.outputs[0], count: kMaxBlock)
            own += UnsafeBufferPointer(start: node.outputs[2], count: kMaxBlock)
        }
        return (rms(main[...]), rms(own[...]))
    }
    let a = play(patched: true), b = play(patched: false)
    check(a.own > 0.005 && a.main < 1e-3, "voice 1's outlet patched: it plays only there (own \(a.own), main \(a.main))")
    check(b.main > 0.005 && b.own < 1e-6, "unpatched: voice 1 is back in the main L / R (main \(b.main))")
}

print("fm")
do {
    check(FMAlgorithms.all.count == 32 && FMAlgorithms.all.allSatisfy { !$0.carriers.isEmpty }, "fm: 32 algorithms, each with carriers")
    check(FMPresets.all.count == 32, "fm: 32 built-in voices")
    // sysex: a bank of the built-in voices packs, wraps and reads back exactly
    let bank = FMVoice.bankSysex(FMPresets.all.map(\.vced))
    let back = FMVoice.parseSysex(bank)
    check(bank.count == 4104 && back.count == 32 && zip(back, FMPresets.all).allSatisfy { $0 == $1.vced },
          "fm: a 32-voice sysex bank round-trips (\(bank.count) bytes)")
    check(FMVoice.toParams(FMPresets.all[3].vced).count == FMLayout.count
          && FMVoice.fromParams(FMVoice.toParams(FMPresets.all[3].vced), name: FMVoice.name(FMPresets.all[3].vced)) == FMPresets.all[3].vced,
          "fm: voice → parameters → voice is lossless")
    // every voice sounds from a gate, stays finite, and fades after the gate closes
    // (the gate: a square LFO — high for the first half of each cycle)
    func play(_ vced: [UInt8], seconds: Double, gateHz: Float) -> [Float] {
        var p = Patch()
        let spec = ModuleRegistry.spec("fm")!
        let vals = FMVoice.toParams(vced)
        var params: [String: Float] = [:]
        for (k, ps) in spec.params.enumerated() where k != FMLayout.sel { params[ps.key] = vals[k] }
        let fm = PatchNode(kind: "fm", x: 0, y: 0, params: params)
        let g = PatchNode(kind: "lfo", x: 0, y: 0, params: ["shape": 3, "rate": gateHz, "depth": 0.25, "offset": 0.25])
        p.nodes = [g, fm]
        p.cables = [PatchCable(fromNode: g.id, fromPort: 0, toNode: fm.id, toPort: 1)]
        let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var y: [Float] = []
        for _ in 0..<Int(seconds * sr / Double(kMaxBlock)) {
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            y += UnsafeBufferPointer(start: h.node(fm.id)!.outputs[0], count: kMaxBlock)
        }
        return y
    }
    var loud: [String] = [], silent: [String] = [], stuck: [String] = []
    for v in FMPresets.all {
        let y = play(v.vced, seconds: 4, gateHz: 0.25)            // gate on for 2 s, off for 2 s
        let on = rms(y[Int(0.05 * sr)..<Int(1.9 * sr)])
        let tail = rms(y[(y.count - Int(0.2 * sr))...])
        if !y.allSatisfy({ $0.isFinite }) || (y.map(abs).max() ?? 0) > 2 { loud.append(v.name) }
        if on < 0.005 { silent.append(v.name) }
        if tail > on * 0.25 { stuck.append(v.name) }
    }
    check(loud.isEmpty && silent.isEmpty, "fm: every built-in voice sounds and stays in range (silent \(silent), too loud \(loud))")
    check(stuck.isEmpty, "fm: every voice fades once the gate closes (still sounding: \(stuck))")
    // pitch: one sine operator at ratio 1 plays middle C
    var sine = FMPresets.all[0].vced
    sine[134] = 31                                               // algorithm 32: all carriers
    for o in 0..<6 { sine[o * 21 + 16] = o == 5 ? 99 : 0 }       // op 1 (stored last) at full level, the rest off
    sine[135] = 0                                                // no feedback
    let y = play(sine, seconds: 0.5, gateHz: 0.25)
    let ups = upCrossings(Array(y[Int(0.1 * sr)..<Int(0.4 * sr)]))
    check(abs(Double(ups) / 0.3 - 261.63) < 6, "fm: one operator at ratio 1 plays middle C (\(Double(ups) / 0.3) Hz)")
}

print("lfo~")
do {
    check(Divisions.beats(16) == 32 && Divisions.beats(17) == 64 && ModuleRegistry.spec("lfo")!.params[3].max == 17,
          "lfo~ syncs up to every 8 and 16 bars")
    check(ModuleRegistry.spec("lfo")!.params[0].max == 4, "shapes: sine, triangle, saw, square, random (no s&h)")
    var old = Patch(); old.version = 12
    old.nodes = [4, 5, 2].map { PatchNode(kind: "lfo", x: 0, y: 0, params: ["shape": Float($0)]) }
    check(old.migrated().nodes.map { $0.params["shape"]! } == [4, 4, 2], "older patches: s&h and random both become random")
    // a patched clock drives it: 8 pulses a second, division 1 bar (16 pulses) → one cycle every 2 s
    var p = Patch()
    let clk = PatchNode(kind: "lfo", x: 0, y: 0, params: ["shape": 3, "rate": 8, "depth": 0.5, "offset": 0.5])
    let lfo = PatchNode(kind: "lfo", x: 0, y: 0, params: ["shape": 2, "div": Float(Divisions.index("1 bar")), "depth": 0.5, "offset": 0.5])
    p.nodes = [clk, lfo]
    p.cables = [PatchCable(fromNode: clk.id, fromPort: 0, toNode: lfo.id, toPort: 0)]
    let h = GraphHost(sampleRate: sr); h.load(p); h.prepareForStart()
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock); ins[0].update(repeating: 0, count: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var y: [Float] = []
    for _ in 0..<Int(5 * sr / Double(kMaxBlock)) {
        h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        y.append(contentsOf: UnsafeBufferPointer(start: h.node(lfo.id)!.outputs[0], count: kMaxBlock))
    }
    var wraps: [Int] = []
    for i in 1..<y.count where y[i] < y[i - 1] - 0.5 { wraps.append(i) }
    let period = wraps.count >= 2 ? Double(wraps[1] - wraps[0]) / sr : 0
    check(abs(period - 2) < 0.02, "clock in: 16 pulses at 8 Hz = one 1-bar cycle every \(period) s")
}

print("seq~ up to 64 steps")
do {
    let spec = ModuleRegistry.spec("seq")!.params[0]
    check(spec.snapped(17) == 16 && spec.snapped(25) == 32 && spec.snapped(50) == 64 && spec.snapped(9) == 9,
          "length snaps to 1…16, 32, 64")
    check(spec.value(fromNormalized: 1) == 64 && spec.value(fromNormalized: 16.0 / 17) == 32 && spec.value(fromNormalized: 0) == 1,
          "sliding the length row goes 1 … 16, then 32, then 64")
    // 32 steps: steps 16…31 are a fifth up, so the 17th note played is +7
    let pitch: [Float] = (0..<64).map { $0 < 16 ? 0 : 7 }, gate = [Float](repeating: 1, count: 64)
    let (_, o) = runSource("seq", params: ["len": 32, "div": Float(Divisions.index("1/16"))], data: ["pitch": pitch, "gate": gate], seconds: 4.2)
    let notes = notesAtGates(o[0], o[1])
    check(notes.count >= 33 && notes[15] == 0 && notes[16] == 7 && notes[31] == 7 && notes[32] == 0,
          "length 32 plays all 32 steps, then loops (\(notes.prefix(34)))")
    // an old 16-step pattern repeats to fill the longer steps
    let (_, o2) = runSource("seq", params: ["len": 32], data: ["pitch": (0..<16).map { Float($0) }, "gate": [Float](repeating: 1, count: 16)], seconds: 4.2)
    let n2 = notesAtGates(o2[0], o2[1])
    check(n2.count >= 18 && n2[16] == 0 && n2[17] == 1, "a saved 16-step pattern fills 32 steps by repeating")
}

print("seq~ off steps hold the pitch")
do {
    // steps: 0 C on, 1 +7 off, 2 +12 on, 3 +3 off …
    let pitch: [Float] = (0..<16).map { [0, 7, 12, 3][$0 % 4] }
    let gate: [Float] = (0..<16).map { $0 % 2 == 0 ? 1 : 0 }
    let (_, o) = runSource("seq", params: ["div": Float(Divisions.index("1/16"))], data: ["pitch": pitch, "gate": gate], seconds: 1)
    let step = Int(sr * 0.125)          // 1/16 at 120 BPM
    let mid = (0..<4).map { o[0][$0 * step + step / 2] }
    check(mid[1] == mid[0] && mid[3] == mid[2] && mid[2] != mid[0],
          "a switched-off step keeps the last played note (CV per step: \(mid.map { String(format: "%.3f", $0) }))")
}

print("Rolls: a new division keeps the pattern in time")
do {
    let i16 = Float(Divisions.index("1/16")), i32 = Float(Divisions.index("1/32")), i8 = Float(Divisions.index("1/8"))
    var v = [Float](repeating: 0, count: 2 * 32)
    for s in [0, 4, 8, 12] { v[s] = 1 }            // lane 0: four on the floor
    for s in [2, 6, 10, 14] { v[32 + s] = 1 }      // lane 1: off-beat 8ths
    let fine = PatternRescale.rescale(v, lanes: 2, steps: 32, length: 16, fromDivision: i16, toDivision: i32, empty: 0)
    check(fine.length == 32 && (0..<32).filter { fine.values[$0] > 0 } == [0, 8, 16, 24] && (0..<32).filter { fine.values[32 + $0] > 0 } == [4, 12, 20, 28],
          "1/16 → 1/32: 16 steps become 32, hits land on the same beats")
    let back = PatternRescale.rescale(fine.values, lanes: 2, steps: 32, length: 32, fromDivision: i32, toDivision: i16, empty: 0)
    check(back.length == 16 && back.values == v, "and back to 1/16 gives the original pattern")
    let coarse = PatternRescale.rescale(v, lanes: 2, steps: 32, length: 16, fromDivision: i16, toDivision: i8, empty: 0)
    check(coarse.length == 8 && (0..<8).filter { coarse.values[$0] > 0 } == [0, 2, 4, 6] && (0..<8).filter { coarse.values[32 + $0] > 0 } == [1, 3, 5, 7],
          "1/16 → 1/8: 8 steps, the same beats")
    var notes = [Float](repeating: -1, count: 32); notes[0] = 5; notes[3] = 9
    let rn = PatternRescale.rescale(notes, lanes: 1, steps: 32, length: 16, fromDivision: i16, toDivision: i32, empty: -1)
    check(rn.values[0] == 5 && rn.values[6] == 9 && rn.values.filter { $0 >= 0 }.count == 2, "piano roll notes move with it")
    let capped = PatternRescale.rescale(v, lanes: 2, steps: 32, length: 32, fromDivision: i16, toDivision: i32, empty: 0)
    check(capped.length == 32, "never longer than the 32 steps a roll has")
}

print("Transport: play / pause / stop")
do {
    for withClock in [false, true] {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let sq = PatchNode(kind: "seq", x: 0, y: 0, params: ["div": Float(Divisions.index("1/16")), "gatelen": 0.3])
        p.nodes = [sq]
        if withClock { p.nodes.append(PatchNode(kind: "clock", x: 0, y: 0, params: ["source": 1])) }
        h.load(p); h.prepareForStart()
        let n = h.node(sq.id)!
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        ins[0].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        func run(_ seconds: Double) -> [Float] {
            var g: [Float] = []
            for _ in 0..<Int(seconds * sr) / kMaxBlock {
                h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
                g.append(contentsOf: UnsafeBufferPointer(start: n.outputs[1], count: kMaxBlock))
            }
            return g
        }
        let tag = withClock ? "with clock~" : "app clock"
        let playing = onsets(run(1))
        h.transport(.pause)
        let paused = onsets(Array(run(1).dropFirst(Int(sr * 0.1))))    // a gate already open may finish
        h.transport(.play)
        let resumed = onsets(run(1))
        h.transport(.stop)
        let stopped = run(0.5)
        h.transport(.play)
        let again = run(0.25)
        let first = again.firstIndex { $0 > 0.2 } ?? -1
        check(playing >= 7 && paused == 0 && resumed >= 7 && onsets(Array(stopped.dropFirst(Int(sr * 0.1)))) == 0 && first >= 0 && first < kMaxBlock * 2 && n.readouts[0] <= 1,
              "\(tag): ▶ runs (\(playing) steps/s), ❚❚ holds (\(paused)), ▶ again (\(resumed)), ■ fires nothing new (\(onsets(Array(stopped.dropFirst(Int(sr * 0.1)))))) and ▶ starts from the top at once (first gate at sample \(first), 2 steps in 0.25 s)")
    }
}

print("Undo / redo: the engine follows the patch (patterns, knobs, starter beats)")
do {
    let h = GraphHost(sampleRate: sr)
    let rack = PatchNode(kind: "rack", x: 0, y: 0), ds = PatchNode(kind: "drumsynth", x: 0, y: 300)
    /// seq~ holds 64 steps: a shorter saved pattern repeats to fill them
    func steps64(_ v: [Float]) -> [Float] { (0..<SeqNode.steps).map { v[$0 % v.count] } }
    let sq = PatchNode(kind: "seq", x: 0, y: 600), rl = PatchNode(kind: "roll", x: 0, y: 900), dr = PatchNode(kind: "drums", x: 0, y: 1200)
    var p0 = Patch(); p0.nodes = [rack, ds, sq, rl, dr]
    h.load(p0)
    func engine(_ id: UUID, _ key: String) -> [Float] {
        switch h.node(id) {
        case let r as RackNode: return Array(UnsafeBufferPointer(start: r.hits, count: RackLayout.pads * RackLayout.steps))
        case let d as DrumSynthNode: return Array(UnsafeBufferPointer(start: d.hits, count: DrumSynthLayout.voices * DrumSynthLayout.steps))
        case let s as SeqNode: return Array(UnsafeBufferPointer(start: key == "pitch" ? s.pitches : s.gates, count: SeqNode.steps))
        case let r as RollNode: return Array(UnsafeBufferPointer(start: r.grid, count: RollNode.steps * RollNode.rows))
        case let d as DrumsNode: return Array(UnsafeBufferPointer(start: d.hits, count: DrumsNode.steps * DrumsNode.lanes))
        default: return []
        }
    }
    let rackStart = engine(rack.id, "hits"), dsStart = engine(ds.id, "hits")
    // three edits, each its own undo step: rack pattern, drumsynth pattern + a knob, seq / roll / drums
    var hist = UndoHistory(committed: p0)
    var p1 = p0; var e1 = rackStart; e1[5] = 1; e1[0] = 0; p1.nodes[0].data["hits"] = e1
    hist.commit(p1); h.load(p1)
    var p2 = p1; var e2 = dsStart; e2[33] = 1; p2.nodes[1].data["hits"] = e2; p2.nodes[1].params["swing"] = 0.3
    hist.commit(p2); h.load(p2)
    var p3 = p2
    p3.nodes[2].data["pitch"] = (0..<16).map { Float($0) }; p3.nodes[2].data["gate"] = (0..<16).map { Float($0 % 2) }
    var notes = [Float](repeating: -1, count: 32); notes[3] = 7; p3.nodes[3].data["grid"] = RollNode.grid(fromNotes: notes)
    var dh = [Float](repeating: 0, count: 256); dh[40] = 1; p3.nodes[4].data["hits"] = dh
    hist.commit(p3); h.load(p3)
    func matches(_ p: Patch) -> Bool {
        let d = h.node(ds.id)!, si = ModuleRegistry.spec("drumsynth")!.paramIndex("swing")!
        return engine(rack.id, "hits") == (p.nodes[0].data["hits"] ?? rackStart)
            && engine(ds.id, "hits") == (p.nodes[1].data["hits"] ?? dsStart)
            && d.base[si] == (p.nodes[1].params["swing"] ?? 0)
            && engine(sq.id, "pitch") == steps64(p.nodes[2].data["pitch"] ?? [Float](repeating: 0, count: 16))
            && engine(sq.id, "gate") == steps64(p.nodes[2].data["gate"] ?? [Float](repeating: 1, count: 16))
            && engine(rl.id, "grid") == (p.nodes[3].data["grid"] ?? [Float](repeating: 0, count: RollNode.steps * RollNode.rows))
            && engine(dr.id, "hits") == (p.nodes[4].data["hits"] ?? [Float](repeating: 0, count: 256))
    }
    check(matches(p3), "after three edits the engine plays what the patch says")
    var ok = true, trail: [String] = []
    for (want, label) in [(p2, "undo 1"), (p1, "undo 2"), (p0, "undo 3")] {
        guard let u = hist.undo() else { ok = false; break }
        h.load(u)
        let m = u == want && matches(want); ok = ok && m; trail.append("\(label) \(m ? "ok" : "WRONG")")
    }
    check(ok && engine(rack.id, "hits") == rackStart && engine(ds.id, "hits") == dsStart,
          "undo steps back one edit at a time, right back to the starter beats (\(trail.joined(separator: ", ")))")
    ok = true; trail = []
    for (want, label) in [(p1, "redo 1"), (p2, "redo 2"), (p3, "redo 3")] {
        guard let r = hist.redo() else { ok = false; break }
        h.load(r)
        let m = r == want && matches(want); ok = ok && m; trail.append("\(label) \(m ? "ok" : "WRONG")")
    }
    check(ok, "redo brings each edit back (\(trail.joined(separator: ", ")))")
    // an edit after undo starts from what's on screen, and drops the redo steps
    _ = hist.undo(); h.load(hist.committed)
    var p4 = hist.committed; var e4 = engine(ds.id, "hits"); e4[0] = 0; p4.nodes[1].data["hits"] = e4
    hist.commit(p4); h.load(p4)
    check(!hist.canRedo && matches(p4) && engine(ds.id, "hits")[33] == 1 && engine(ds.id, "hits")[0] == 0,
          "editing after an undo builds on the undone state (no stray hits from the redo branch)")
}

print("Tidy")
do {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("tidy-fixture.json")
    if let data = try? Data(contentsOf: fixture), let big = try? JSONDecoder().decode(Patch.self, from: data) {
        let p = big.migrated()
        let before = MainActor.assumeIsolated { TidyLayout.quality(p, [:], inputs: 4, outputs: 4) }
        let pos = MainActor.assumeIsolated { TidyLayout.layout(p, inputs: 4, outputs: 4) }
        let after = MainActor.assumeIsolated { TidyLayout.quality(p, pos, inputs: 4, outputs: 4) }
        check(pos.count == p.nodes.count && after.overlaps == 0,
              "a 26-box patch: every box placed, none overlapping (before \(before.overlaps) overlaps)")
        check(after.crossings <= 2 && after.crossings < before.crossings,
              "cable crossings \(before.crossings) → \(after.crossings)")
        var moved = p
        for i in moved.nodes.indices { if let q = pos[moved.nodes[i].id] { moved.nodes[i].x = q.x; moved.nodes[i].y = q.y } }
        let again = MainActor.assumeIsolated { TidyLayout.layout(moved, inputs: 4, outputs: 4) }
        check(again == pos, "tidying a tidy patch changes nothing")
        // compact: no big empty band between the controller row and the graph, and not much taller than
        // the tallest column stacked plainly
        let hw = (4, 4)
        let sizes = Dictionary(uniqueKeysWithValues: p.nodes.map { n in (n.id, MainActor.assumeIsolated { TidyLayout.boxSize(n, inputs: hw.0, outputs: hw.1) }) })
        let knobIDs = Set(p.nodes.filter { $0.kind == "knob" || $0.kind == "lfo" }.map(\.id))
        let ctlBottom = p.nodes.filter { knobIDs.contains($0.id) }.map { pos[$0.id]!.y + sizes[$0.id]!.height }.max() ?? 0
        let graph = p.nodes.filter { !knobIDs.contains($0.id) && $0.kind != "text" }
        let graphTop = graph.map { pos[$0.id]!.y }.min() ?? 0
        let graphBottom = graph.map { pos[$0.id]!.y + sizes[$0.id]!.height }.max() ?? 0
        let tallestColumn = Dictionary(grouping: graph, by: { pos[$0.id]!.x }).values.map { col in col.map { sizes[$0.id]!.height + 36 }.reduce(0, +) }.max() ?? 0
        check(graphTop - ctlBottom <= 96 && graphBottom - graphTop <= tallestColumn * 1.6,
              "compact: \(Int(graphTop - ctlBottom)) pt below the controllers, \(Int(graphBottom - graphTop)) pt tall (tallest column stacked: \(Int(tallestColumn)))")
        let byKind = { (k: String) in p.nodes.filter { $0.kind == k }.map { pos[$0.id]! } }
        let outX = byKind("out")[0].x, mixX = byKind("mix")[0].x
        let knobs = byKind("knob"), voices = byKind("macro") + byKind("drumsynth")
        check(outX > mixX && voices.allSatisfy { $0.x < mixX } && knobs.allSatisfy { k in voices.allSatisfy { k.y < $0.y } },
              "out~ last, voices before mix~, knob~ controllers in a row on top")
    } else {
        check(false, "tidy fixture missing (\(fixture.path))")
    }
    // small cases: a chain lines up straight; an unpatched box goes underneath; a note follows its box
    var p = Patch()
    let a = PatchNode(kind: "in", x: 400, y: 300), b = PatchNode(kind: "delay", x: 0, y: 0), c = PatchNode(kind: "out", x: 100, y: 500)
    let lone = PatchNode(kind: "lfo", x: 900, y: 0)
    var note = PatchNode(kind: "text", x: 10, y: -30); note.text = "echo"
    p.nodes = [a, b, c, lone, note]
    p.cables = [PatchCable(fromNode: a.id, fromPort: 0, toNode: b.id, toPort: 0), PatchCable(fromNode: b.id, fromPort: 0, toNode: c.id, toPort: 0)]
    let pos = MainActor.assumeIsolated { TidyLayout.layout(p, inputs: 4, outputs: 4) }
    let q = MainActor.assumeIsolated { TidyLayout.quality(p, pos, inputs: 4, outputs: 4) }
    check(pos[a.id]!.x < pos[b.id]!.x && pos[b.id]!.x < pos[c.id]!.x && q.overlaps == 0, "in~ → delay~ → out~ left to right")
    let bottom = [a, b, c].map { pos[$0.id]!.y }.max()!
    check(pos[lone.id]!.y > bottom, "an unpatched box waits underneath")
    check(pos[note.id]!.x - pos[b.id]!.x == 10 && pos[note.id]!.y - pos[b.id]!.y == -30, "a note stays beside its box")
}

if ProcessInfo.processInfo.environment["AUDIO_TEST"] == "1" {
    print("Audio start / stop never block (opens the real device, muted)")
    let h = GraphHost(sampleRate: 48000)
    var p = Patch(); p.nodes = [PatchNode(kind: "lfo", x: 0, y: 0)]
    h.load(p)
    let io = AudioIO(host: h)
    io.muteOutput = true
    io.inputUID = ProcessInfo.processInfo.environment["AUDIO_TEST_INPUT"] == "1" ? nil : "none"
    var result: Error?? = nil
    var prepared = false
    let t0 = Date()
    io.start(prepare: { sr in h.setSampleRate(sr); h.prepareForStart(); prepared = true }, done: { e in result = .some(e) })
    let returned = Date().timeIntervalSince(t0)
    check(returned < 0.05 && io.isStarting, String(format: "start returns at once (%.1f ms) and works in the background", returned * 1000))
    let deadline = Date().addingTimeInterval(10)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    let started = result.map { $0 == nil } ?? false
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(started && prepared && io.isRunning && io.cpuLoad > 0, "and audio comes up and runs the patch (\(io.outputName), \(Int(io.sampleRate)) Hz, \(io.bufferFrames) smp)")
    // a start superseded by a stop gives up quietly; a second start wins over the first
    var first: Error?? = nil, second: Error?? = nil
    io.start(prepare: { _ in }, done: { e in first = .some(e) })
    io.stop()
    io.start(prepare: { sr in h.setSampleRate(sr); h.prepareForStart() }, done: { e in second = .some(e) })
    let d2 = Date().addingTimeInterval(10)
    while second == nil && Date() < d2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(first == nil && second.map { $0 == nil } == true && io.isRunning, "a start cut short by stop / a newer start never takes over")
    let t1 = Date(); io.stop()
    check(Date().timeIntervalSince(t1) < 0.05 && !io.isRunning, "stop returns at once")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
}

print("Envelopes: decay curve, attack on shapes~ / macro~")
do {
    let shapes = ModuleRegistry.spec("shapes")!, di = shapes.paramIndex("decay")!
    let dec = shapes.params[di]
    check(dec.value(fromNormalized: 0) == 0 && abs(dec.value(fromNormalized: 0.5) - 500) < 0.5 && abs(dec.value(fromNormalized: 1) - 4000) < 0.5
          && abs(dec.normalized(500) - 0.5) < 1e-4,
          "shapes~ decay uses the whole slider: 0 → 0 ms, middle → \(Int(dec.value(fromNormalized: 0.5))) ms, end → 4000 ms (the left half used to do nothing)")
    let shift = ModuleRegistry.spec("freqshift")?.params.first { $0.key == "shift" }
    if let shift {
        check(abs(shift.value(fromNormalized: 0.5)) < 0.5 && shift.value(fromNormalized: 0) == -5000, "a ± setting (frequency shift) still centres on 0")
    }
    // a knob~ at its middle sets the decay to the middle of the slider (500 ms)
    do {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let knobSpec = ModuleRegistry.spec("knob")!
        let k = PatchNode(kind: "knob", x: 0, y: 0, params: [knobSpec.params[ControlsLayout.valueIndex(0)].key: 0.5])
        let sh = PatchNode(kind: "shapes", x: 0, y: 0)
        p.nodes = [k, sh]
        p.cables = [PatchCable(fromNode: k.id, fromPort: 0, toNode: sh.id, toPort: kParamPortBase + di)]
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        for _ in 0..<200 { h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1) }
        let v = h.node(sh.id)!.params[di]
        check(abs(v - 500) < 15, "a knob~ halfway sets decay to \(Int(v)) ms (≈ 500)")
    }
    // a voice with a trigger every 1 s; returns its output
    func voice(_ kind: String, _ params: [String: Float], trig: Bool = true, seconds: Double = 2) -> [Float] {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0), v = PatchNode(kind: kind, x: 0, y: 0, params: params)
        p.nodes = [src, v]
        if trig { p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: v.id, toPort: 1)] }
        h.load(p); h.prepareForStart()
        let node = h.node(v.id)!
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var out: [Float] = [], t = 0
        for _ in 0..<Int(seconds * sr) / kMaxBlock {
            for i in 0..<kMaxBlock { let k = t + i - 4800; ins[0][i] = k >= 0 && k % Int(sr) < 480 ? 0.8 : 0 }   // hits at 0.1 s, 1.1 s
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 1)
            out.append(contentsOf: UnsafeBufferPointer(start: node.outputs[0], count: kMaxBlock))
            t += kMaxBlock
        }
        return out
    }
    func level(_ x: [Float], _ from: Double, _ to: Double) -> Float { rms(x[Int(from * sr)..<Int(to * sr)]) }
    let d = voice("shapes", ["decay": 200])
    check(level(d, 0.11, 0.16) > 0.02 && level(d, 0.6, 0.9) < level(d, 0.11, 0.16) * 0.01,
          String(format: "shapes~ decay 200 ms: %.3f just after the hit, %.5f half a second later", level(d, 0.11, 0.16), level(d, 0.6, 0.9)))
    let dr = voice("shapes", ["decay": 200], trig: false)
    check(level(dr, 0.5, 1.0) > 0.02, String(format: "with nothing in trig it drones instead of going silent (%.3f)", level(dr, 0.5, 1.0)))
    let a = voice("shapes", ["decay": 0, "attack": 300])
    check(level(a, 0.1, 0.13) < level(a, 0.35, 0.45) * 0.35 && level(a, 0.35, 0.45) > 0.02,
          String(format: "shapes~ attack 300 ms fades the note in (%.3f at the start, %.3f after)", level(a, 0.1, 0.13), level(a, 0.35, 0.45)))
    let m0 = voice("macro", ["engine": 0, "decay": 1, "attack": 0])
    let m = voice("macro", ["engine": 0, "decay": 1, "attack": 300])
    check(level(m, 0.1, 0.13) < level(m0, 0.1, 0.13) * 0.35 && level(m, 0.38, 0.45) > level(m0, 0.38, 0.45) * 0.6,
          String(format: "macro~ attack 300 ms: start %.3f (vs %.3f without), full by 0.4 s (%.3f vs %.3f)",
                 level(m, 0.1, 0.13), level(m0, 0.1, 0.13), level(m, 0.38, 0.45), level(m0, 0.38, 0.45)))
}

print("clock~ starts internal; patched clocks stay external")
do {
    check(ModuleRegistry.spec("clock")!.params[0].def == 1, "a new clock runs on its own tempo")
    var old = Patch(); old.version = 9
    let src = PatchNode(kind: "in", x: 0, y: 0), c1 = PatchNode(kind: "clock", x: 0, y: 0), c2 = PatchNode(kind: "clock", x: 0, y: 0)
    old.nodes = [src, c1, c2]
    old.cables = [PatchCable(fromNode: src.id, fromPort: 3, toNode: c1.id, toPort: 0)]
    let m = old.migrated()
    check(m.nodes[1].params["source"] == 0 && m.nodes[2].params["source"] == nil,
          "older patches: a clock fed from the modular stays external, an unpatched one becomes internal")
}

print("keys~: record the notes you play into the automation loop")
do {
    let h = GraphHost(sampleRate: sr)
    var p = Patch()
    let kn = PatchNode(kind: "keys", x: 0, y: 0)
    p.nodes = [kn]
    h.load(p); h.prepareForStart()
    let k = h.node(kn.id) as! KeysNode
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
    var gate: [Float] = [], pitch: [Float] = []
    func run(_ seconds: Double, touch: (Double) -> Int = { _ in -1 }) {
        for b in 0..<Int(seconds * sr) / kMaxBlock {
            k.touchNote = touch(Double(b * kMaxBlock) / sr)
            if k.touchNote >= 0 && (gate.last ?? 0) < 0.2 { k.pressNote = k.touchNote; k.pressCount += 1 }
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
            gate.append(contentsOf: UnsafeBufferPointer(start: k.outputs[1], count: kMaxBlock))
            pitch.append(contentsOf: UnsafeBufferPointer(start: k.outputs[0], count: kMaxBlock))
        }
    }
    // record: key 7 from 1.0 s to 1.5 s, key 12 from 3.0 s to 3.25 s (one 8 s loop at 120 BPM)
    k.recordingKeys = true
    run(8) { t in t >= 1 && t < 1.5 ? 7 : (t >= 3 && t < 3.25 ? 12 : -1) }
    k.recordingKeys = false
    let recorded = k.recordedKeys
    let first = gate.count
    run(8)                                          // the next pass, hands off
    let pass = Array(gate[first...]), pp = Array(pitch[first...])
    func on(_ t: Double) -> Bool { pass[Int(t * sr)] > 0.2 }
    let pitchAt = { (t: Double) in pp[Int(t * sr)] }
    check(recorded && on(1.25) && on(3.1) && !on(0.5) && !on(2.0) && !on(5.0),
          "played notes come back in the next loop at the same moments (on at 1.25 s and 3.1 s, off at 0.5 / 2 / 5 s)")
    check(abs(pitchAt(3.22) - pitchAt(1.45) - 5.0 / 120) < 0.002, String(format: "and with the right pitches (+5 semitones apart: %.3f V)", pitchAt(3.22) - pitchAt(1.45)))
    h.transport(.pause)
    gate.removeAll(); run(2)
    check(gate.allSatisfy { $0 < 0.2 } || onsets(Array(gate.dropFirst(Int(sr * 0.1)))) == 0, "paused: the loop doesn't play")
    h.transport(.play)
    // saved with the patch and reset
    let lane = Array(UnsafeBufferPointer(start: k.keyLane, count: DSPNode.autoSlots))
    var p2 = p; p2.nodes[0].data[KeysNode.laneKey] = lane
    let h2 = GraphHost(sampleRate: sr); h2.load(p2)
    check((h2.node(kn.id) as! KeysNode).keyLaneOn, "the recorded notes are saved with the patch")
    h.load(p)                                        // patch without the lane (reset / undo)
    check(!k.keyLaneOn, "reset / undo clears them")
}


if let path = ProcessInfo.processInfo.environment["BENCH_PATCH"],
   let data = FileManager.default.contents(atPath: path),
   let full = try? JSONDecoder().decode(Patch.self, from: data).migrated() {
    /// Real-time share of one core to run `p` (5 s at 48 kHz, 128-frame blocks, silent inputs).
    func cost(_ p: Patch) -> Double {
        let h = GraphHost(sampleRate: 48000)
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: 128); ins[1] = .allocate(capacity: 128)
        ins[0].update(repeating: 0, count: 128); ins[1].update(repeating: 0, count: 128)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
        for k in 0..<4 { outs[k] = .allocate(capacity: 128) }
        for _ in 0..<400 { h.process(frames: 128, inputs: ins, inputCount: 2, outputs: outs, outputCount: 4) }   // let it get going
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<(48000 * 2 / 128) {
                for k in 0..<4 { outs[k].update(repeating: 0, count: 128) }
                h.process(frames: 128, inputs: ins, inputCount: 2, outputs: outs, outputCount: 4)
            }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 / 2 * 100)
        }
        return best
    }
    let all = cost(full)
    print(String(format: "Patch: %d modules, %.2f %% of one core", full.nodes.count, all))
    var rows: [(String, Double)] = []
    for n in full.nodes {
        var p = full
        p.nodes.removeAll { $0.id == n.id }
        p.cables.removeAll { $0.fromNode == n.id || $0.toNode == n.id }
        var label = n.kind
        if let a = n.params["algo"] { label += " algo=\(Int(a))" }
        if n.kind == "peq" { label += " bands=\(Int(n.params["bands"] ?? 0))" }
        rows.append((label + (n.bypassed ? " (bypassed)" : ""), all - cost(p)))
    }
    for (name, pct) in rows.sorted(by: { $0.1 > $1.1 }) { print(String(format: "  %6.2f %%  %@", pct, name)) }
    exit(0)
}

if ProcessInfo.processInfo.environment["BENCH"] == "1" {
    print("Benchmark: one instance of each module, 10 s of 48 kHz audio (share of one core in real time)")
    var rows: [(String, Double)] = []
    for spec in ModuleRegistry.all where !["in", "out", "text"].contains(spec.kind) {
        let h = GraphHost(sampleRate: 48000)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0), n = PatchNode(kind: spec.kind, x: 0, y: 0)
        p.nodes = [src, n]
        p.cables = (0..<min(spec.inputs.count, 2)).map { PatchCable(fromNode: src.id, fromPort: $0, toNode: n.id, toPort: $0) }
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: 128); ins[1] = .allocate(capacity: 128)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        outs[0] = .allocate(capacity: 128); outs[1] = .allocate(capacity: 128)
        var ph = 0.0
        let blocks = 48000 * 10 / 128
        // warm up
        for _ in 0..<50 { h.process(frames: 128, inputs: ins, inputCount: 2, outputs: outs, outputCount: 2) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blocks {
            for i in 0..<128 { let v = Float(Foundation.sin(ph)) * 0.4; ins[0][i] = v; ins[1][i] = v; ph += 2 * .pi * 220 / 48000 }
            outs[0].update(repeating: 0, count: 128); outs[1].update(repeating: 0, count: 128)
            h.process(frames: 128, inputs: ins, inputCount: 2, outputs: outs, outputCount: 2)
        }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        rows.append((spec.name, secs / 10 * 100))
    }
    for (name, pct) in rows.sorted(by: { $0.1 > $1.1 }) { print(String(format: "  %6.2f %%  %@", pct, name)) }
    // variants that matter: every reverb / filter / delay type
    func benchOne(_ kind: String, _ params: [String: Float]) -> Double {
        let h = GraphHost(sampleRate: 48000)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0), n = PatchNode(kind: kind, x: 0, y: 0, params: params)
        p.nodes = [src, n]
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: n.id, toPort: 0), PatchCable(fromNode: src.id, fromPort: 1, toNode: n.id, toPort: 1)]
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: 128); ins[1] = .allocate(capacity: 128)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        outs[0] = .allocate(capacity: 128); outs[1] = .allocate(capacity: 128)
        var ph = 0.0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<(48000 * 5 / 128) {
            for i in 0..<128 { let v = Float(Foundation.sin(ph)) * 0.4; ins[0][i] = v; ins[1][i] = v; ph += 2 * .pi * 220 / 48000 }
            h.process(frames: 128, inputs: ins, inputCount: 2, outputs: outs, outputCount: 2)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 / 5 * 100
    }
    for (k, key, names) in [("reverb", "algo", ["room", "plate", "hall", "spring"]), ("filter", "type", ["svf", "ladder", "ms20"]), ("delay", "algo", ["digital", "tape", "bbd"])] {
        for (i, nm) in names.enumerated() { print(String(format: "  %6.2f %%  %@ %@", benchOne(k, [key: Float(i)]), k, nm)) }
    }
    let total = rows.map(\.1).reduce(0, +)
    print(String(format: "  all %d modules together ≈ %.1f %% of one core", rows.count, total))
}

print("Starter patch")
do {
    let p = DefaultPatch.builtIn()
    check(p.nodes.map(\.kind).sorted() == ["clock", "in", "mix", "out"], "starter patch is in~, clock, mix~, out~ (\(p.nodes.map(\.kind)))")
    check(p.cables.isEmpty, "and nothing is patched")
    let h = GraphHost(sampleRate: sr); h.load(p)
    check(p.nodes.allSatisfy { h.node($0.id) != nil }, "it loads")
}

print("Set as default: copies get their own IDs")
do {
    var p = Patch()
    let a = PatchNode(kind: "in", x: 0, y: 0), b = PatchNode(kind: "looper", x: 0, y: 0), c = PatchNode(kind: "out", x: 0, y: 0)
    p.nodes = [a, b, c]
    p.cables = [PatchCable(fromNode: a.id, fromPort: 0, toNode: b.id, toPort: 0), PatchCable(fromNode: b.id, fromPort: 0, toNode: c.id, toPort: 0)]
    p.groups = [PatchGroup(name: "g", members: [a.id, b.id])]
    let (q, map) = p.withFreshIDs()
    let oldIDs = Set(p.nodes.map(\.id)), newIDs = Set(q.nodes.map(\.id))
    check(oldIDs.isDisjoint(with: newIDs) && map.count == 3 && q.nodes.map(\.kind) == p.nodes.map(\.kind),
          "every box gets a new ID (so a new patch never shares audio files with the default)")
    let wired = q.cables.allSatisfy { newIDs.contains($0.fromNode) && newIDs.contains($0.toNode) } && q.cables.count == 2
        && q.cables[0].fromNode == map[a.id] && q.cables[1].toNode == map[c.id]
    check(wired && q.groups?.first?.members == [map[a.id]!, map[b.id]!], "cables and groups follow the boxes")
}

print("text boxes")
do {
    var p = Patch()
    var t = PatchNode(kind: "text", x: 10, y: 20)
    t.text = "kick → reverb\nslow down at bar 8"
    p.nodes = [t]
    let dec = try! JSONDecoder().decode(Patch.self, from: try! JSONEncoder().encode(p))
    check(dec.nodes[0].text == t.text, "text is saved with the patch")
    let h = GraphHost(sampleRate: sr)
    h.load(p)
    check(h.node(t.id) != nil && ModuleRegistry.spec("text")!.bypass == .none, "a text box loads (no ports, no bypass)")
}

print("Switching an effect back on starts it empty")
do {
    func tail(renew: Bool) -> Float {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0)
        let d = PatchNode(kind: "delay", x: 0, y: 0, params: ["fb": 0.8, "mix": 1])
        p.nodes = [src, d]
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: d.id, toPort: 0)]
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var t = 0
        for _ in 0..<Int(sr) / kMaxBlock {
            for i in 0..<kMaxBlock { ins[0][i] = Float(0.5 * Foundation.sin(Double(t + i) * 0.05)) }
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 1); t += kMaxBlock
        }
        if renew { h.renew(d.id, in: p) }
        ins[0].update(repeating: 0, count: kMaxBlock)
        var e: Float = 0, n = 0
        for _ in 0..<Int(sr) / kMaxBlock {
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 1)
            let o = h.node(d.id)!.outputs[0]
            for i in 0..<kMaxBlock { e += o[i] * o[i]; n += 1 }
        }
        return sqrtf(e / Float(n))
    }
    let kept = tail(renew: false), fresh = tail(renew: true)
    check(kept > 0.01 && fresh < 1e-5, String(format: "delay~ keeps echoing without a reset (rms %.3f), a renewed one is silent (rms %.6f)", kept, fresh))
}

print("reverb~ types")
do {
    var lv: [Float] = [], tails: [Float] = []
    for algo in 0..<4 {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<Int(sr * 1.5)).map { _ in Float.random(in: -0.3...0.3, using: &rng) } + [Float](repeating: 0, count: Int(sr * 3))
        let r = runModule("reverb", params: ["algo": Float(algo), "mix": 1, "size": 0.5], input: noise)
        lv.append(rms(r.outs[0][Int(sr * 0.5)..<Int(sr * 1.5)]))
        tails.append(rms(r.outs[0][Int(sr * 4)...]))
    }
    let spread = (lv.max() ?? 1) / max(lv.min() ?? 1, 1e-6)
    check(lv.allSatisfy { $0 > 0.02 && $0.isFinite } && spread < 4,
          "room / plate / hall / spring all sound at similar levels (\(lv.map { String(format: "%.3f", $0) }))")
    check(tails.allSatisfy { $0 < 0.02 }, "and all die away after the input stops (\(tails.map { String(format: "%.4f", $0) }))")
}

print("turing~ octave shift and mixer meters")
do {
    let (_, t0) = runSource("turing", params: ["change": 0, "len": 8, "oct": 0], seconds: 2)
    let (_, t1) = runSource("turing", params: ["change": 0, "len": 8, "oct": 1], seconds: 2)
    let i = Int(sr * 1.5)
    check(abs((t1[0][i] - t0[0][i]) - 0.1) < 1e-4, "octave +1 moves the whole melody up exactly an octave")
    let (none, _) = runSource("turing", params: ["change": 0, "len": 8, "notes": 0], seconds: 0.5)
    let (all, _) = runSource("turing", params: ["change": 0, "len": 8, "notes": 1], seconds: 0.5)
    let tn = none as! TuringNode, ta = all as! TuringNode
    check(tn.playsBits == 0 && ta.playsBits == 255 && Set((0..<8).map { ta.loopNotes[$0] }).count > 1,
          "the display's loop follows the notes amount at once (none at 0, all 8 at 1)")
    let mixRun = runModule("mix", params: ["chans": 0, "g1": 0.5], input: sine(200, 0.5, 0.8))
    let m0 = mixRun.node.readouts[MixerLayout.channelMeterBase]
    check(abs(m0 - 0.4) < 0.02, String(format: "mix~ channel 1 meter reads its level after the fader (%.2f for 0.8 × 0.5)", m0))
}

print("turing~ notes amount")
do {
    let counts = [Float(0), 0.25, 0.5, 1].map { d -> Int in
        let (_, o) = runSource("turing", params: ["change": 0.5, "len": 16, "notes": d], seconds: 8)
        return onsets(o[1])
    }
    check(counts[0] == 0 && counts[3] >= 60 && counts[1] < counts[2] && counts[2] < counts[3],
          "notes 0 / 25 / 50 / 100 %: \(counts) gates in 64 steps")
    let (_, a) = runSource("turing", params: ["change": 0, "len": 8, "notes": 0.5], seconds: 8)
    let steps = stride(from: Int(sr * 0.125 * 16) + 100, to: Int(sr * 0.125 * 32), by: Int(sr * 0.125)).map { a[1][$0] > 0.2 }
    check(Array(steps[0..<8]) == Array(steps[8..<16]), "with change 0 the rhythm loops with the notes")
}

print("lfo~ random")
do {
    let (_, o) = runSource("lfo", params: ["shape": 5, "rate": 4, "depth": 1], seconds: 4)
    let x = o[0]
    var maxJump: Float = 0
    for i in 1..<x.count { maxJump = max(maxJump, abs(x[i] - x[i - 1])) }
    let span = (x.max() ?? 0) - (x.min() ?? 0)
    check(span > 0.5 && maxJump < 0.01, String(format: "random wanders (span %.2f) without jumps (largest step %.4f)", span, maxJump))
}

print("Inlet order: pitch first")
do {
    for k in ["modal", "macro", "shapes"] { check(ModuleRegistry.spec(k)!.inputs.first == "pitch", "\(k)~ takes pitch first") }
    check(ModuleRegistry.spec("resonator")!.inputs == ["in", "pitch", "strum"], "resonator~: in, pitch, strum")
    for k in ["keys", "seq", "turing", "roll"] { check(Array(ModuleRegistry.spec(k)!.outputs.prefix(2)) == ["pitch", "gate"], "\(k)~ gives pitch, gate") }
    var old = Patch(); old.version = 6
    let sq = PatchNode(kind: "seq", x: 0, y: 0), md = PatchNode(kind: "modal", x: 0, y: 0), rs = PatchNode(kind: "resonator", x: 0, y: 0)
    old.nodes = [sq, md, rs]
    old.cables = [PatchCable(fromNode: sq.id, fromPort: 1, toNode: md.id, toPort: 0),    // gate → modal gate (old 0)
                  PatchCable(fromNode: sq.id, fromPort: 0, toNode: md.id, toPort: 1),    // pitch → modal pitch (old 1)
                  PatchCable(fromNode: sq.id, fromPort: 1, toNode: rs.id, toPort: 1),    // gate → resonator strum (old 1)
                  PatchCable(fromNode: sq.id, fromPort: 0, toNode: md.id, toPort: kParamPortBase + 1)]
    let m = old.migrated()
    check(m.cables[0].toPort == 1 && m.cables[1].toPort == 0 && m.cables[2].toPort == 2 && m.cables[3].toPort == kParamPortBase + 1,
          "older patches keep every cable on the same signal (parameter cables untouched)")
}

print("Replace a box")
do {
    var p = Patch()
    let src = PatchNode(kind: "in", x: 0, y: 0), lfo = PatchNode(kind: "lfo", x: 0, y: 0)
    let dly = PatchNode(kind: "delay", x: 100, y: 50, params: ["mix": 0.7, "fb": 0.6])
    let out = PatchNode(kind: "out", x: 300, y: 0)
    p.nodes = [src, lfo, dly, out]
    let dSpec = ModuleRegistry.spec("delay")!
    p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: dly.id, toPort: 0),                 // → L
                PatchCable(fromNode: src.id, fromPort: 1, toNode: dly.id, toPort: 1),                 // → R
                PatchCable(fromNode: dly.id, fromPort: 0, toNode: out.id, toPort: 0),
                PatchCable(fromNode: dly.id, fromPort: 1, toNode: out.id, toPort: 1),
                PatchCable(fromNode: lfo.id, fromPort: 0, toNode: dly.id, toPort: kParamPortBase + dSpec.paramIndex("mix")!),
                PatchCable(fromNode: lfo.id, fromPort: 0, toNode: dly.id, toPort: kParamPortBase + dSpec.paramIndex("fb")!)]
    let r = p.replacing(dly.id, with: "reverb")!
    let rv = r.patch.nodes.first { $0.id == r.newID }!
    let rSpec = ModuleRegistry.spec("reverb")!
    check(rv.kind == "reverb" && rv.x == 100 && rv.y == 50 && !r.patch.nodes.contains { $0.id == dly.id },
          "the new box takes the old one's place")
    check(rv.params["mix"] == 0.7 && rv.params["fb"] == nil, "settings with the same name carry over (mix), others don't")
    let toNew = r.patch.cables.filter { $0.toNode == r.newID }, fromNew = r.patch.cables.filter { $0.fromNode == r.newID }
    check(Set(toNew.map(\.toPort)) == [0, 1, kParamPortBase + rSpec.paramIndex("mix")!] && Set(fromNew.map(\.fromPort)) == [0, 1],
          "L / R in and out stay patched, the mix modulation follows, the feedback one (no such knob) is dropped")
    let host = GraphHost(sampleRate: sr); host.load(r.patch)
    check(host.node(r.newID) is DSPNode, "and the engine builds it")
}

print("turing~ silent steps hold the pitch")
do {
    let (_, o) = runSource("turing", params: ["change": 0.3, "len": 16, "notes": 0.4, "gatelen": 0.3], seconds: 8)
    let pitch = o[0], gate = o[1]
    var changesWhileSilent = 0, lastGateStart = -1
    for i in 1..<pitch.count {
        if gate[i] > 0.2 && gate[i - 1] <= 0.2 { lastGateStart = i }
        if pitch[i] != pitch[i - 1] && !(i - lastGateStart < 4 && lastGateStart >= 0) { changesWhileSilent += 1 }
    }
    check(changesWhileSilent == 0, "pitch only moves when a note plays (\(changesWhileSilent) changes on silent steps)")
}

print("reverb~ is stereo")
do {
    func stereo(_ algo: Int, leftOnly: Bool) -> (corr: Double, ratio: Double) {
        let h = GraphHost(sampleRate: sr)
        var p = Patch()
        let src = PatchNode(kind: "in", x: 0, y: 0)
        let rv = PatchNode(kind: "reverb", x: 0, y: 0, params: ["algo": Float(algo), "mix": 1, "size": 0.6])
        p.nodes = [src, rv]
        p.cables = [PatchCable(fromNode: src.id, fromPort: 0, toNode: rv.id, toPort: 0)]
        if leftOnly { p.cables.append(PatchCable(fromNode: src.id, fromPort: 1, toNode: rv.id, toPort: 1)) }
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        ins[0] = .allocate(capacity: kMaxBlock); ins[1] = .allocate(capacity: kMaxBlock); ins[1].update(repeating: 0, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: kMaxBlock)
        var g = SystemRandomNumberGenerator()
        var ll = 0.0, rr = 0.0, lr = 0.0
        for b in 0..<Int(sr * 3) / kMaxBlock {
            for i in 0..<kMaxBlock { ins[0][i] = (b * kMaxBlock + i) % 24000 < 2400 ? Float.random(in: -0.4...0.4, using: &g) : 0 }
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 2, outputs: outs, outputCount: 1)
            if b > Int(sr * 0.5) / kMaxBlock {
                let n = h.node(rv.id)!
                for i in 0..<kMaxBlock { let l = Double(n.outputs[0][i]), r = Double(n.outputs[1][i]); ll += l * l; rr += r * r; lr += l * r }
            }
        }
        return (lr / sqrt(ll * rr + 1e-20), sqrt(ll / max(rr, 1e-20)))
    }
    for (a, name) in ["room", "plate", "hall", "spring"].enumerated() {
        let mono = stereo(a, leftOnly: false), left = stereo(a, leftOnly: true)
        check(mono.corr < 0.4 && left.ratio > 1.8 && left.ratio < 6,
              String(format: "%@: a mono input comes out wide (L/R correlation %.2f), a hard-left one stays left (L/R %.1f×)", name, mono.corr, left.ratio))
    }
}

print("Groups")
do {
    var p = Patch()
    let a = PatchNode(kind: "lfo", x: 0, y: 0), b = PatchNode(kind: "delay", x: 200, y: 0), c = PatchNode(kind: "out", x: 400, y: 0)
    p.nodes = [a, b, c]
    p.groups = [PatchGroup(name: "drums", members: [a.id, b.id])]
    let back = try! JSONDecoder().decode(Patch.self, from: try! JSONEncoder().encode(p))
    check(back.groups == p.groups, "groups are saved with the patch")
    let r = p.replacing(b.id, with: "reverb")!
    check(r.patch.groups?.first?.members == [a.id, r.newID], "a replaced box stays in its group")
    let old = try! JSONDecoder().decode(Patch.self, from: Data(#"{"version":7,"nodes":[],"cables":[]}"#.utf8))
    check(old.groups == nil, "patches from before groups still open")
}

print("File browser search")
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pj-search-\(UUID().uuidString)")
    let deep = root.appendingPathComponent("a/b/c")
    try! FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    for f in ["Kick 01.wav", "kick_hard.aif", "snare.wav", "kick notes.txt"] { FileManager.default.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
    FileManager.default.createFile(atPath: deep.appendingPathComponent("KICK deep.flac").path, contents: Data())
    let hits = Set(FileSearch.find("kick", in: [root]).map(\.lastPathComponent))
    check(hits == ["Kick 01.wav", "kick_hard.aif", "KICK deep.flac"], "search finds audio files by name, any case, in subfolders, and skips other files (\(hits.sorted()))")
    try? FileManager.default.removeItem(at: root)
}

print("rack~ drum machine")
do {
    let (_, beat) = runSource("rack", seconds: 2)
    let lv = rms(beat[0][...])
    check(lv > 0.03 && lv < 0.5 && beat[0].allSatisfy { $0.isFinite }, String(format: "the starter beat plays (rms %.3f)", lv))
    let (_, silent) = runSource("rack", data: ["hits": [Float](repeating: 0, count: 512)], seconds: 1)
    check(rms(silent[0][...]) < 1e-6, "an empty pattern is silent")
    var only = [Float](repeating: 0, count: 512); only[0] = 1                       // kick on step 1
    let (_, kick) = runSource("rack", data: ["hits": only], seconds: 0.5)
    let (_, muted) = runSource("rack", params: ["m1": 1], data: ["hits": only], seconds: 0.5)
    var two = only; two[1 * 32 + 0] = 1                                             // + snare
    let (_, soloed) = runSource("rack", params: ["s2": 1], data: ["hits": two], seconds: 0.5)
    let (_, both) = runSource("rack", data: ["hits": two], seconds: 0.5)
    let (_, snareOnly) = runSource("rack", data: ["hits": { var h = [Float](repeating: 0, count: 512); h[32] = 1; return h }()], seconds: 0.5)
    check(rms(kick[0][...]) > 0.02 && rms(muted[0][...]) < 1e-6, "M mutes a pad")
    check(abs(rms(soloed[0][...]) - rms(snareOnly[0][...])) < 1e-4 && rms(both[0][...]) > rms(snareOnly[0][...]) + 1e-3,
          "S solos a pad (only the soloed one plays)")
    let (loaded, lo) = runSource("rack", data: ["hits": only], seconds: 0.3, setup: { n in
        (n as! RackNode).load(pad: 0, StereoAudio(left: [Float](repeating: 0.25, count: 4800)), name: "box")
    })
    let r = lo[0]
    // right at the start (before the decay has moved it): sample × pad level 0.8 × master 0.9
    let flat = abs(r[10] - 0.25 * 0.8 * 0.9) < 0.002 && r[3000] < r[10] && r[3000] > 0.1
    check((loaded as! RackNode).padNames[0] == "box" && flat, "a loaded sample plays on its pad at pad level × master")
}

print("drumsynth~")
do {
    let (_, beat) = runSource("drumsynth", seconds: 2)
    let lv = rms(beat[0][...])
    check(lv > 0.02 && lv < 0.6 && beat[0].allSatisfy { $0.isFinite }, String(format: "the starter beat plays (rms %.3f)", lv))
    for v in 0..<4 {
        var h = [Float](repeating: 0, count: 128); h[v * 32] = 1; h[v * 32 + 8] = 1
        let (_, o) = runSource("drumsynth", data: ["hits": h], seconds: 1.2)
        let a = rms(o[0][...])
        var hp = [String: Float](); hp["c\(v + 1)"] = 1
        let (_, o2) = runSource("drumsynth", params: hp, data: ["hits": h], seconds: 1.2)
        let differs = zip(o[0], o2[0]).contains { abs($0 - $1) > 1e-3 }
        check(a > 0.005 && differs, String(format: "%@ sounds on its own (rms %.3f) and its synthetic model sounds different", DrumSynthLayout.names[v], a))
    }
    var two = [Float](repeating: 0, count: 128); two[0] = 1; two[32] = 1
    let (_, both) = runSource("drumsynth", data: ["hits": two], seconds: 0.6)
    let (_, muted) = runSource("drumsynth", params: ["m1": 1, "m2": 1], data: ["hits": two], seconds: 0.6)
    let (_, solo) = runSource("drumsynth", params: ["s2": 1], data: ["hits": two], seconds: 0.6)
    // (untriggered Plaits voices idle at about −87 dB, so "silent" means below −60 dB here)
    check(rms(muted[0][...]) < 1e-3 && rms(solo[0][...]) > 0.003 && rms(solo[0][...]) < rms(both[0][...]), String(format: "mute and solo work (muted %.6f, solo %.4f, both %.4f)", rms(muted[0][...]), rms(solo[0][...]), rms(both[0][...])))
    // the rack-style envelope and the Plaits engine choice
    var k1 = [Float](repeating: 0, count: 128); k1[0] = 1
    let (_, long) = runSource("drumsynth", params: ["h1": 0.9, "o1": 0.9], data: ["hits": k1], seconds: 0.5)
    let (_, short) = runSource("drumsynth", params: ["h1": 0.9, "o1": 0.9, "d1": 40], data: ["hits": k1], seconds: 0.5)
    let tailL = rms(long[0][Int(sr * 0.15)..<Int(sr * 0.4)]), tailS = rms(short[0][Int(sr * 0.15)..<Int(sr * 0.4)])
    check(tailS < tailL * 0.05 && rms(short[0][0..<Int(sr * 0.02)]) > 0.01,
          String(format: "a short decay cuts the kick's tail (%.4f → %.5f) but keeps the hit", tailL, tailS))
    let (_, slow) = runSource("drumsynth", params: ["a1": 150], data: ["hits": k1], seconds: 0.5)
    let (_, fast) = runSource("drumsynth", data: ["hits": k1], seconds: 0.5)
    check(rms(slow[0][0..<Int(sr * 0.01)]) < rms(fast[0][0..<Int(sr * 0.01)]) * 0.2, "attack fades the hit in")
    let (_, va) = runSource("drumsynth", params: ["e1": 8, "l1": 0.8], data: ["hits": k1], seconds: 0.5)
    check(rms(va[0][...]) > 0.005 && zip(va[0], fast[0]).contains { abs($0 - $1) > 0.01 }, "a voice can use any Plaits engine (virtual analog here)")
    check(DrumSynthLayout.label(0, engine: 21) == "kick" && DrumSynthLayout.label(0, engine: 8) == "virtual analog", "pads show the engine's name once it's changed")
    // 44.1 kHz too (through the rate bridge)
    let h = GraphHost(sampleRate: 44100)
    var p = Patch(); let n = PatchNode(kind: "drumsynth", x: 0, y: 0); p.nodes = [n]
    h.load(p); h.prepareForStart()
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: 256)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); outs[0] = .allocate(capacity: 256)
    var e: Double = 0, cnt = 0
    for _ in 0..<(44100 * 2 / 64) {
        h.process(frames: 64, inputs: ins, inputCount: 0, outputs: outs, outputCount: 1)
        for i in 0..<64 { let x = h.node(n.id)!.outputs[0][i]; e += Double(x * x); cnt += 1 }
    }
    check(sqrt(e / Double(cnt)) > 0.02, "and at 44.1 kHz")
}

// MARK: - Stress tests

print("Stress: garbage in")
// NaN / inf / huge values on the hardware inputs, patched into every parameter of every module.
var fuzz = Patch()
let fin = PatchNode(kind: "in", x: 0, y: 0)
fuzz.nodes = [fin]
for spec in ModuleRegistry.all where spec.kind != "in" && spec.kind != "rec" {
    let n = PatchNode(kind: spec.kind, x: 0, y: 0)
    fuzz.nodes.append(n)
    for k in spec.inputs.indices { fuzz.cables.append(PatchCable(fromNode: fin.id, fromPort: k % 4, toNode: n.id, toPort: k)) }
    for k in spec.params.indices { fuzz.cables.append(PatchCable(fromNode: fin.id, fromPort: k % 4, toNode: n.id, toPort: kParamPortBase + k)) }
}
let fhost = GraphHost(sampleRate: sr)
fhost.load(fuzz)
fhost.prepareForStart()
let fin4 = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
let fout = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 8)
for c in 0..<4 { fin4[c] = .allocate(capacity: block) }
for c in 0..<8 { fout[c] = .allocate(capacity: block) }
let garbage: [Float] = [.nan, .infinity, -.infinity, 1e30, -1e30, 0, 1, -1, 5, .leastNonzeroMagnitude]
var rng = SystemRandomNumberGenerator()
var garbageOK = true
for b in 0..<2000 {
    for c in 0..<4 { for i in 0..<block {
        fin4[c][i] = b % 3 == 0 ? garbage.randomElement(using: &rng)! : Float.random(in: -12...12, using: &rng)
    } }
    // knob values set to garbage too
    if b % 50 == 0 {
        for n in fuzz.nodes { if let dn = fhost.node(n.id) { for k in 0..<dn.paramCount { dn.base[k] = garbage.randomElement(using: &rng)! } } }
    }
    for c in 0..<8 { fout[c].update(repeating: 0, count: block) }
    fhost.process(frames: block, inputs: fin4, inputCount: 4, outputs: fout, outputCount: 8)
    for n in fuzz.nodes { if let dn = fhost.node(n.id) { for o in dn.outputs { for i in 0..<kMaxBlock where !o[i].isFinite { garbageOK = false } } } }
}
check(garbageOK, "NaN/inf/huge inputs and knob values never escape a module (and nothing traps)")
// every parameter display survives garbage
var displayOK = true
for spec in ModuleRegistry.all { for p in spec.params { for g in garbage { if p.display(g).isEmpty && !p.isTrigger { displayOK = false } } } }
check(displayOK, "parameter display handles NaN/inf without trapping")

print("Stress: re-patching while audio renders")
// One thread renders continuously while this thread rebuilds the patch hundreds of times.
let shost = GraphHost(sampleRate: sr)
var sp = Patch()
let sin = PatchNode(kind: "in", x: 0, y: 0)
sp.nodes = [sin]
shost.load(sp)
shost.prepareForStart()
let running = UnsafeMutablePointer<Bool>.allocate(capacity: 1); running.pointee = true
let blocks = UnsafeMutablePointer<Int>.allocate(capacity: 1); blocks.pointee = 0
let renderThread = Thread {
    let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
    let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
    for c in 0..<2 { ins[c] = .allocate(capacity: 256); outs[c] = .allocate(capacity: 256)
        ins[c].update(repeating: 0.3, count: 256) }
    while running.pointee {
        for c in 0..<2 { outs[c].update(repeating: 0, count: 256) }
        shost.process(frames: 256, inputs: ins, inputCount: 2, outputs: outs, outputCount: 2)
        blocks.pointee += 1
    }
}
renderThread.start()
let kinds = ModuleRegistry.all.map(\.kind).filter { $0 != "rec" }
for _ in 0..<400 {
    // add/remove random modules and cables
    if sp.nodes.count < 30 || Bool.random() {
        sp.nodes.append(PatchNode(kind: kinds.randomElement()!, x: 0, y: 0))
    } else {
        let victim = sp.nodes.dropFirst().randomElement()!
        sp.nodes.removeAll { $0.id == victim.id }
        sp.cables.removeAll { $0.fromNode == victim.id || $0.toNode == victim.id }
    }
    for _ in 0..<3 {
        let a = sp.nodes.randomElement()!, b = sp.nodes.randomElement()!
        let sa = ModuleRegistry.spec(a.kind)!, sb = ModuleRegistry.spec(b.kind)!
        guard !sa.outputs.isEmpty else { continue }
        let toParam = !sb.params.isEmpty && Bool.random()
        let port = toParam ? kParamPortBase + Int.random(in: 0..<sb.params.count)
                           : (sb.inputs.isEmpty ? -1 : Int.random(in: 0..<sb.inputs.count))
        if port >= 0 { sp.cables.append(PatchCable(fromNode: a.id, fromPort: Int.random(in: 0..<sa.outputs.count), toNode: b.id, toPort: port)) }
    }
    if let n = sp.nodes.randomElement(), let dn = shost.node(n.id) { dn.bypassed.toggle() }
    shost.load(sp)
    usleep(1500)
}
running.pointee = false
usleep(50_000)
check(blocks.pointee > 100, "audio kept rendering through 400 live edits (\(blocks.pointee) blocks, \(sp.nodes.count) modules)")

print("1 V/oct (0.1 = 1 V = one octave)")
do {
    /// Runs a small patch for `seconds`; returns hardware output channel 0 and the host.
    func runPatch(_ p: Patch, seconds: Double = 0.5, input: Float = 0) -> ([Float], GraphHost) {
        let h = GraphHost(sampleRate: sr)
        h.load(p); h.prepareForStart()
        let ins = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); ins[0] = .allocate(capacity: kMaxBlock)
        ins[0].update(repeating: input, count: kMaxBlock)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        outs[0] = .allocate(capacity: kMaxBlock); outs[1] = .allocate(capacity: kMaxBlock)
        var res: [Float] = []
        for _ in 0..<Int(seconds * sr / Double(kMaxBlock)) {
            outs[0].update(repeating: 0, count: kMaxBlock); outs[1].update(repeating: 0, count: kMaxBlock)
            h.process(frames: kMaxBlock, inputs: ins, inputCount: 1, outputs: outs, outputCount: 2)
            res.append(contentsOf: UnsafeBufferPointer(start: outs[0], count: kMaxBlock))
        }
        return (res, h)
    }
    // every step +12 semitones: the pitch output is exactly 0.1 (1 V)
    let up: [Float] = [Float](repeating: 12, count: 16), on: [Float] = [Float](repeating: 1, count: 16)
    let (_, o) = runSource("seq", params: ["len": 1], data: ["pitch": up, "gate": on], seconds: 0.3)
    check(abs((o[0].last ?? 0) - 0.1) < 1e-6, "seq~ +12 st = 0.1 (1 V) at its pitch outlet (\(o[0].last ?? 0))")
    // through out~ with its gain turned down: a pitch CV still leaves at exactly 1 V/oct; audio is turned down
    var p = Patch()
    let seq = PatchNode(kind: "seq", x: 0, y: 0, params: ["len": 1], data: ["pitch": up, "gate": on])
    let out = PatchNode(kind: "out", x: 0, y: 0, params: ["gain": -20])
    p.nodes = [seq, out]
    p.cables = [PatchCable(fromNode: seq.id, fromPort: 0, toNode: out.id, toPort: 0)]
    let (cv, _) = runPatch(p)
    check(abs((cv.last ?? 0) - 0.1) < 1e-6, "out~ at -20 dB passes pitch CV at unity: 1 V/oct kept (\(cv.last ?? 0))")
    var pa = Patch()
    let osc = PatchNode(kind: "shapes", x: 0, y: 0, params: ["shape": 3])
    let out2 = PatchNode(kind: "out", x: 0, y: 0, params: ["gain": -20])
    pa.nodes = [osc, out2]
    pa.cables = [PatchCable(fromNode: osc.id, fromPort: 0, toNode: out2.id, toPort: 0)]
    let (au, _) = runPatch(pa)
    let peak = au.suffix(4800).map { abs($0) }.max() ?? 0
    check(peak > 0.01 && peak < 0.15, "out~'s gain still turns audio down (peak \(peak))")
    // in~ → a semitone row: 1 V in = +12 semitones (not scaled to the row's range)
    var pi = Patch()
    let inn = PatchNode(kind: "in", x: 0, y: 0)
    let mac = PatchNode(kind: "macro", x: 0, y: 0)
    pi.nodes = [inn, mac]
    let noteIdx = ModuleRegistry.spec("macro")!.paramIndex("note")!
    pi.cables = [PatchCable(fromNode: inn.id, fromPort: 0, toNode: mac.id, toPort: kParamPortBase + noteIdx)]
    let (_, hi) = runPatch(pi, seconds: 0.1, input: 0.1)
    let note = hi.node(mac.id)!.params[noteIdx]
    check(abs(note - 12) < 1e-4, "1 V into in~ → macro~'s frequency row moves exactly +12 st (\(note))")
    check(abs(cvSemitonesForTest(0.1) - 12) < 1e-6 && abs(cvSemitonesForTest(-0.25) + 30) < 1e-5, "pitch inlets read 0.1 as one octave")
    // scope~ measures what it sees
    var ps = Patch()
    let lfo = PatchNode(kind: "lfo", x: 0, y: 0, params: ["rate": 5, "depth": 0.5, "offset": 0.1])
    let sc = PatchNode(kind: "scope", x: 0, y: 0, params: ["time": 400, "trig": 0])
    ps.nodes = [lfo, sc]
    ps.cables = [PatchCable(fromNode: lfo.id, fromPort: 0, toNode: sc.id, toPort: 0)]
    let (_, hs) = runPatch(ps, seconds: 2)
    let r = hs.node(sc.id)!.readouts
    check(abs(r[1] + 0.4) < 0.01 && abs(r[2] - 0.6) < 0.01 && abs(r[3] - 5) < 0.1 && abs(r[0] - 0.1) < 0.02,
          "scope~ reads an LFO: -4…+6 V, 5 Hz, average +1 V (min \(r[1]) max \(r[2]) Hz \(r[3]) mean \(r[0]))")
    check((hs.node(sc.id) as! ScopeNode).version > 0, "scope~ shows sweeps")
    // scope~ on a cable: passes the signal through untouched, and pitch through it still skips out~'s gain
    var pt = Patch()
    let seq2 = PatchNode(kind: "seq", x: 0, y: 0, params: ["len": 1], data: ["pitch": up, "gate": on])
    let sc2 = PatchNode(kind: "scope", x: 0, y: 0)
    let out3 = PatchNode(kind: "out", x: 0, y: 0, params: ["gain": -20])
    pt.nodes = [seq2, sc2, out3]
    pt.cables = [PatchCable(fromNode: seq2.id, fromPort: 0, toNode: sc2.id, toPort: 0),
                 PatchCable(fromNode: sc2.id, fromPort: 0, toNode: out3.id, toPort: 0)]
    let (thru, _) = runPatch(pt)
    check(abs((thru.last ?? 0) - 0.1) < 1e-6, "scope~ on a pitch cable: passes it through, still exactly 1 V/oct at out~ (\(thru.last ?? 0))")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
