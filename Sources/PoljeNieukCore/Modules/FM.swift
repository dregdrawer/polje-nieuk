import Foundation

// fm : a six-operator FM synth in the style of the Yamaha DX7 — 32 algorithms, 4-rate / 4-level envelopes,
// feedback, LFO and pitch envelope — that plays DX7 voices and loads DX7 sysex banks. Our own implementation
// (written from how the DX7 behaves; no code from Dexed or msfa). Slightly simplified: the keyboard level
// scaling curves and the envelope / LFO timings are close to the DX7, not bit-exact.

/// Where everything lives in the module's parameters. The per-operator block is in the DX7's own order
/// (R1-4 L1-4 BP LD RD LC RC RS AMS KVS OL OM FC FF DT), so a sysex voice maps straight onto it.
public enum FMLayout {
    public static let ops = 6
    public static let perOp = 21
    public static let globals = 21
    // globals
    public static let sel = 0, algo = 1, fb = 2, transpose = 3, level = 4, oks = 5
    public static let lfs = 6, lfd = 7, lpmd = 8, lamd = 9, lks = 10, lfw = 11, lpms = 12, pr = 13, pl = 17
    // per operator (op 0 = OP1)
    public static let R = 0, L = 4, BP = 8, LD = 9, RD = 10, LC = 11, RC = 12, RS = 13, AMS = 14, KVS = 15
    public static let OL = 16, OM = 17, FC = 18, FF = 19, DT = 20
    public static func base(_ op: Int) -> Int { globals + op * perOp }
    public static let count = globals + ops * perOp

    /// The rows the box shows (the rest still play — a sysex voice sets them): the main ones, then the
    /// selected operator's.
    public static let shownGlobals = [sel, algo, fb, transpose, level, lfs, lpmd, lamd, lfw, lpms]
    public static let shownOp = [OL, OM, FC, FF, DT, R, R + 1, R + 2, R + 3, L, L + 1, L + 2, L + 3, KVS, RS]

    public static let lfoWaves = ["triangle", "saw down", "saw up", "square", "sine", "s&h"]
    static let curves = ["-lin", "-exp", "+exp", "+lin"]

    static func params() -> [ParamSpec] {
        let d = FMVoice.toParams(FMPresets.all[0].vced)
        var p: [ParamSpec] = [
            .choice("sel", "operator", (1...ops).map { "op \($0)" }, def: 0),
            .integer("algo", "algorithm", 1, 32, Int(d[algo])),
            .integer("fb", "feedback", 0, 7, Int(d[fb])),
            .integer("transpose", "transpose", -24, 24, Int(d[transpose])),
            ParamSpec("level", "level", 0, 1.5, 0.8, unit: "%"),
            .toggle("oks", "osc key sync", d[oks] > 0.5),
            .integer("lfs", "lfo speed", 0, 99, Int(d[lfs])),
            .integer("lfd", "lfo delay", 0, 99, Int(d[lfd])),
            .integer("lpmd", "lfo pitch depth", 0, 99, Int(d[lpmd])),
            .integer("lamd", "lfo amp depth", 0, 99, Int(d[lamd])),
            .toggle("lks", "lfo key sync", d[lks] > 0.5),
            .choice("lfw", "lfo wave", lfoWaves, def: Int(d[lfw])),
            .integer("lpms", "pitch mod sens", 0, 7, Int(d[lpms]))]
        for k in 0..<4 { p.append(.integer("pr\(k + 1)", "pitch rate \(k + 1)", 0, 99, Int(d[pr + k]))) }
        for k in 0..<4 { p.append(.integer("pl\(k + 1)", "pitch level \(k + 1)", 0, 99, Int(d[pl + k]))) }
        for o in 0..<ops {
            let b = base(o), n = o + 1
            func v(_ f: Int) -> Int { Int(d[b + f]) }
            for k in 0..<4 { p.append(.integer("o\(n)r\(k + 1)", "rate \(k + 1)", 0, 99, v(R + k))) }
            for k in 0..<4 { p.append(.integer("o\(n)l\(k + 1)", "level \(k + 1)", 0, 99, v(L + k))) }
            p.append(.integer("o\(n)bp", "break point", 0, 99, v(BP)))
            p.append(.integer("o\(n)ld", "left depth", 0, 99, v(LD)))
            p.append(.integer("o\(n)rd", "right depth", 0, 99, v(RD)))
            p.append(.choice("o\(n)lc", "left curve", curves, def: v(LC)))
            p.append(.choice("o\(n)rc", "right curve", curves, def: v(RC)))
            p.append(.integer("o\(n)rs", "rate scaling", 0, 7, v(RS)))
            p.append(.integer("o\(n)ams", "amp mod sens", 0, 3, v(AMS)))
            p.append(.integer("o\(n)kvs", "velocity", 0, 7, v(KVS)))
            p.append(.integer("o\(n)ol", "op \(n) level", 0, 99, v(OL)))
            p.append(.choice("o\(n)om", "mode", ["ratio", "fixed"], def: v(OM)))
            p.append(.integer("o\(n)fc", "coarse", 0, 31, v(FC)))
            p.append(.integer("o\(n)ff", "fine", 0, 99, v(FF)))
            p.append(.integer("o\(n)dt", "detune", -7, 7, v(DT)))
        }
        return p
    }
}

/// The 32 algorithms: which operators modulate which, the carriers (heard), and the feedback loop
/// (from the source operator's output into the target's input). Operators 1…6 as on the DX7.
public enum FMAlgorithms {
    public struct Algorithm: Sendable {
        public let mods: [[Int]]      // per operator (0 = OP1): the operators modulating it
        public let carriers: [Int]
        public let fbSource: Int, fbTarget: Int
    }
    static let text = [
        "6>5 5>4 4>3 2>1|1 3|6>6", "6>5 5>4 4>3 2>1|1 3|2>2", "6>5 5>4 3>2 2>1|1 4|6>6", "6>5 5>4 3>2 2>1|1 4|4>6",
        "6>5 4>3 2>1|1 3 5|6>6", "6>5 4>3 2>1|1 3 5|5>6", "6>5 5>3 4>3 2>1|1 3|6>6", "6>5 5>3 4>3 2>1|1 3|4>4",
        "6>5 5>3 4>3 2>1|1 3|2>2", "3>2 2>1 5>4 6>4|1 4|3>3", "3>2 2>1 5>4 6>4|1 4|6>6", "2>1 4>3 5>3 6>3|1 3|2>2",
        "2>1 4>3 5>3 6>3|1 3|6>6", "2>1 4>3 5>4 6>4|1 3|6>6", "2>1 4>3 5>4 6>4|1 3|2>2", "2>1 4>3 3>1 6>5 5>1|1|6>6",
        "2>1 4>3 3>1 6>5 5>1|1|2>2", "2>1 3>1 6>5 5>4 4>1|1|3>3", "3>2 2>1 6>4 6>5|1 4 5|6>6", "3>1 3>2 5>4 6>4|1 2 4|3>3",
        "3>1 3>2 6>4 6>5|1 2 4 5|3>3", "2>1 6>3 6>4 6>5|1 3 4 5|6>6", "3>2 6>4 6>5|1 2 4 5|6>6", "6>3 6>4 6>5|1 2 3 4 5|6>6",
        "6>4 6>5|1 2 3 4 5|6>6", "3>2 5>4 6>4|1 2 4|6>6", "3>2 5>4 6>4|1 2 4|3>3", "2>1 4>3 5>4|1 3 6|5>5",
        "4>3 6>5|1 2 3 5|6>6", "4>3 5>4|1 2 3 6|5>5", "6>5|1 2 3 4 5|6>6", "|1 2 3 4 5 6|6>6"]
    public static let all: [Algorithm] = text.map { t in
        let parts = t.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var mods = [[Int]](repeating: [], count: 6)
        for e in parts[0].split(separator: " ") {
            let ab = e.split(separator: ">").compactMap { Int($0) }
            if ab.count == 2 { mods[ab[1] - 1].append(ab[0] - 1) }
        }
        let carriers = parts[1].split(separator: " ").compactMap { Int($0) }.map { $0 - 1 }
        let fb = parts[2].split(separator: ">").compactMap { Int($0) }
        return Algorithm(mods: mods, carriers: carriers, fbSource: fb[0] - 1, fbTarget: fb[1] - 1)
    }
}

/// DX7 voices: the 155-byte "VCED" form (op 6 first, as in the sysex), the 128-byte packed bank form, and
/// the module's parameters.
public enum FMVoice {
    /// Packed (32-voice bank) → unpacked.
    public static func unpack(_ p: [UInt8]) -> [UInt8] {
        guard p.count >= 128 else { return [] }
        var v = [UInt8](repeating: 0, count: 155)
        for o in 0..<6 {
            let s = o * 17, d = o * 21
            for k in 0..<11 { v[d + k] = p[s + k] }                // R1-4 L1-4 BP LD RD
            v[d + 11] = p[s + 11] & 3; v[d + 12] = (p[s + 11] >> 2) & 3
            v[d + 13] = p[s + 12] & 7; v[d + 20] = (p[s + 12] >> 3) & 15
            v[d + 14] = p[s + 13] & 3; v[d + 15] = (p[s + 13] >> 2) & 7
            v[d + 16] = p[s + 14]
            v[d + 17] = p[s + 15] & 1; v[d + 18] = (p[s + 15] >> 1) & 31
            v[d + 19] = p[s + 16]
        }
        for k in 0..<8 { v[126 + k] = p[102 + k] }                   // pitch EG
        v[134] = p[110] & 31
        v[135] = p[111] & 7; v[136] = (p[111] >> 3) & 1
        for k in 0..<4 { v[137 + k] = p[112 + k] }                   // LFS LFD LPMD LAMD
        v[141] = p[116] & 1; v[142] = (p[116] >> 1) & 7; v[143] = (p[116] >> 4) & 7
        v[144] = p[117]
        for k in 0..<10 { v[145 + k] = p[118 + k] }
        return v
    }

    /// Unpacked → packed (the 32-voice bank form).
    public static func pack(_ v: [UInt8]) -> [UInt8] {
        guard v.count >= 155 else { return [] }
        var p = [UInt8](repeating: 0, count: 128)
        for o in 0..<6 {
            let s = o * 17, d = o * 21
            for k in 0..<11 { p[s + k] = v[d + k] }
            p[s + 11] = (v[d + 11] & 3) | ((v[d + 12] & 3) << 2)
            p[s + 12] = (v[d + 13] & 7) | ((v[d + 20] & 15) << 3)
            p[s + 13] = (v[d + 14] & 3) | ((v[d + 15] & 7) << 2)
            p[s + 14] = v[d + 16]
            p[s + 15] = (v[d + 17] & 1) | ((v[d + 18] & 31) << 1)
            p[s + 16] = v[d + 19]
        }
        for k in 0..<8 { p[102 + k] = v[126 + k] }
        p[110] = v[134] & 31
        p[111] = (v[135] & 7) | ((v[136] & 1) << 3)
        for k in 0..<4 { p[112 + k] = v[137 + k] }
        p[116] = (v[141] & 1) | ((v[142] & 7) << 1) | ((v[143] & 7) << 4)
        p[117] = v[144]
        for k in 0..<10 { p[118 + k] = v[145 + k] }
        return p
    }
    /// A 32-voice bank as a sysex file (F0 43 00 09 20 00, the voices, checksum, F7).
    public static func bankSysex(_ voices: [[UInt8]]) -> [UInt8] {
        var body: [UInt8] = []
        for k in 0..<32 { body += pack(k < voices.count ? voices[k] : voices.last ?? [UInt8](repeating: 0, count: 155)) }
        let sum = body.reduce(0) { ($0 + Int($1)) & 0x7F }
        return [0xF0, 0x43, 0x00, 0x09, 0x20, 0x00] + body + [UInt8((128 - sum) & 0x7F), 0xF7]
    }

    public static func name(_ vced: [UInt8]) -> String {
        guard vced.count >= 155 else { return "" }
        let chars = vced[145..<155].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : " " }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// The module's parameter values for a voice (sel and level left at 0 / 0.8).
    public static func toParams(_ v: [UInt8]) -> [Float] {
        var p = [Float](repeating: 0, count: FMLayout.count)
        guard v.count >= 155 else { return p }
        func c(_ x: UInt8, _ hi: Int) -> Float { Float(min(Int(x), hi)) }
        for o in 0..<6 {
            let s = (5 - o) * 21, b = FMLayout.base(o)                // sysex: op 6 first
            for k in 0..<8 { p[b + k] = c(v[s + k], 99) }
            p[b + FMLayout.BP] = c(v[s + 8], 99); p[b + FMLayout.LD] = c(v[s + 9], 99); p[b + FMLayout.RD] = c(v[s + 10], 99)
            p[b + FMLayout.LC] = c(v[s + 11], 3); p[b + FMLayout.RC] = c(v[s + 12], 3)
            p[b + FMLayout.RS] = c(v[s + 13], 7); p[b + FMLayout.AMS] = c(v[s + 14], 3); p[b + FMLayout.KVS] = c(v[s + 15], 7)
            p[b + FMLayout.OL] = c(v[s + 16], 99); p[b + FMLayout.OM] = c(v[s + 17], 1)
            p[b + FMLayout.FC] = c(v[s + 18], 31); p[b + FMLayout.FF] = c(v[s + 19], 99)
            p[b + FMLayout.DT] = c(v[s + 20], 14) - 7
        }
        for k in 0..<4 { p[FMLayout.pr + k] = c(v[126 + k], 99); p[FMLayout.pl + k] = c(v[130 + k], 99) }
        p[FMLayout.algo] = c(v[134], 31) + 1
        p[FMLayout.fb] = c(v[135], 7)
        p[FMLayout.oks] = c(v[136], 1)
        p[FMLayout.lfs] = c(v[137], 99); p[FMLayout.lfd] = c(v[138], 99)
        p[FMLayout.lpmd] = c(v[139], 99); p[FMLayout.lamd] = c(v[140], 99)
        p[FMLayout.lks] = c(v[141], 1); p[FMLayout.lfw] = c(v[142], 5); p[FMLayout.lpms] = c(v[143], 7)
        p[FMLayout.transpose] = c(v[144], 48) - 24
        p[FMLayout.level] = 0.8
        return p
    }

    /// A voice from the module's parameters (for saving / naming).
    public static func fromParams(_ p: [Float], name: String) -> [UInt8] {
        var v = [UInt8](repeating: 0, count: 155)
        func b(_ x: Float, _ lo: Float, _ hi: Float) -> UInt8 { UInt8(min(max(x.isFinite ? x.rounded() : lo, lo), hi)) }
        for o in 0..<6 {
            let s = (5 - o) * 21, pb = FMLayout.base(o)
            for k in 0..<11 { v[s + k] = b(p[pb + k], 0, 99) }
            v[s + 11] = b(p[pb + FMLayout.LC], 0, 3); v[s + 12] = b(p[pb + FMLayout.RC], 0, 3)
            v[s + 13] = b(p[pb + FMLayout.RS], 0, 7); v[s + 14] = b(p[pb + FMLayout.AMS], 0, 3); v[s + 15] = b(p[pb + FMLayout.KVS], 0, 7)
            v[s + 16] = b(p[pb + FMLayout.OL], 0, 99); v[s + 17] = b(p[pb + FMLayout.OM], 0, 1)
            v[s + 18] = b(p[pb + FMLayout.FC], 0, 31); v[s + 19] = b(p[pb + FMLayout.FF], 0, 99)
            v[s + 20] = b(p[pb + FMLayout.DT] + 7, 0, 14)
        }
        for k in 0..<4 { v[126 + k] = b(p[FMLayout.pr + k], 0, 99); v[130 + k] = b(p[FMLayout.pl + k], 0, 99) }
        v[134] = b(p[FMLayout.algo] - 1, 0, 31); v[135] = b(p[FMLayout.fb], 0, 7); v[136] = b(p[FMLayout.oks], 0, 1)
        v[137] = b(p[FMLayout.lfs], 0, 99); v[138] = b(p[FMLayout.lfd], 0, 99)
        v[139] = b(p[FMLayout.lpmd], 0, 99); v[140] = b(p[FMLayout.lamd], 0, 99)
        v[141] = b(p[FMLayout.lks], 0, 1); v[142] = b(p[FMLayout.lfw], 0, 5); v[143] = b(p[FMLayout.lpms], 0, 7)
        v[144] = b(p[FMLayout.transpose] + 24, 0, 48)
        let n = Array(name.utf8.prefix(10)) + [UInt8](repeating: 32, count: 10)
        for k in 0..<10 { v[145 + k] = n[k] < 32 || n[k] > 126 ? 32 : n[k] }
        return v
    }

    /// The voices in a sysex file: a 32-voice bank (with or without its F0 … F7 wrapper) or a single voice.
    public static func parseSysex(_ d: [UInt8]) -> [[UInt8]] {
        // single voice: F0 43 0n 00 01 1B, 155 bytes, checksum, F7
        if d.count >= 163, d[0] == 0xF0, d[1] == 0x43, d[3] == 0x00, d[4] == 0x01, d[5] == 0x1B {
            return [Array(d[6..<161])]
        }
        var body: ArraySlice<UInt8>?
        if let start = d.firstIndex(of: 0xF0), start + 6 + 4096 <= d.count,
           d[start + 1] == 0x43, d[start + 3] == 0x09 {
            body = d[(start + 6)..<(start + 6 + 4096)]
        } else if d.count == 4096 {
            body = d[0..<4096]
        }
        guard let b = body else { return [] }
        let a = Array(b)
        return (0..<32).map { unpack(Array(a[($0 * 128)..<($0 * 128 + 128)])) }
    }
}

/// The voice engine: up to 4 notes from a poly pitch / gate cable (roll, chord, keys …).
/// Everything it keeps is allocated up front: nothing is allocated on the audio thread.
public final class FMNode: DSPNode {
    // inputs: 0 pitch (0.1 = 1 octave, 0 = middle C), 1 gate, 2 velocity (0…1; 0.8 when nothing's patched)
    // outputs: out   readouts: 0…5 each operator's level now (for the display)
    public static let maxVoices = kMaxVoices
    static let V = kMaxVoices
    // per voice
    private var active = [Bool](repeating: false, count: V), gate = [Bool](repeating: false, count: V)
    private var edges = [EdgeDetector](repeating: EdgeDetector(), count: V)
    private var vel = [Float](repeating: 0.8, count: V)
    private var pStage = [Int](repeating: 4, count: V), peg = [Float](repeating: 50, count: V)
    private var fb1 = [Float](repeating: 0, count: V), fb2 = [Float](repeating: 0, count: V)
    // per voice × operator (voice * 6 + op)
    private let phase: UnsafeMutablePointer<Double>
    private let stage: UnsafeMutablePointer<Int>        // 0…2 attack / decays, 3 release, 4 hold (sustain / done)
    private let eg: UnsafeMutablePointer<Float>         // envelope level, dB
    private let out: UnsafeMutablePointer<Float>        // last output
    private let rate: UnsafeMutablePointer<Float>       // voice * 24 + op * 4 + stage: dB per sample (rate scaling in)
    private let att: UnsafeMutablePointer<Float>        // keyboard level scaling, dB
    // per block
    private let target: UnsafeMutablePointer<Float>     // op * 4 + stage: the level, dB
    private let ol: UnsafeMutablePointer<Float>, ratio: UnsafeMutablePointer<Float>, amsD: UnsafeMutablePointer<Float>
    private let velD: UnsafeMutablePointer<Float>
    private var fixed = [Bool](repeating: false, count: 6), carrier = [Bool](repeating: false, count: 6)
    private let lfo: UnsafeMutablePointer<Float>
    private var lfoPhase: Double = 0, lfoSH: Float = 0, lfoDelay: Float = 1
    private var rng = XorShift(seed: 0x0F00_D00D)

    public override init(spec: ModuleSpec, sampleRate: Double) {
        let n = Self.V * 6
        phase = .allocate(capacity: n); phase.initialize(repeating: 0, count: n)
        stage = .allocate(capacity: n); stage.initialize(repeating: 4, count: n)
        eg = .allocate(capacity: n); eg.initialize(repeating: -96, count: n)
        out = .allocate(capacity: n); out.initialize(repeating: 0, count: n)
        rate = .allocate(capacity: n * 4); rate.initialize(repeating: 0, count: n * 4)
        att = .allocate(capacity: n); att.initialize(repeating: 0, count: n)
        target = .allocate(capacity: 24); target.initialize(repeating: -96, count: 24)
        ol = .allocate(capacity: 6); ol.initialize(repeating: 0, count: 6)
        ratio = .allocate(capacity: 6); ratio.initialize(repeating: 1, count: 6)
        amsD = .allocate(capacity: 6); amsD.initialize(repeating: 0, count: 6)
        velD = .allocate(capacity: 6); velD.initialize(repeating: 0, count: 6)
        lfo = .allocate(capacity: kMaxBlock); lfo.initialize(repeating: 0, count: kMaxBlock)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit {
        phase.deallocate(); stage.deallocate(); eg.deallocate(); out.deallocate(); rate.deallocate(); att.deallocate()
        target.deallocate(); ol.deallocate(); ratio.deallocate(); amsD.deallocate(); velD.deallocate(); lfo.deallocate()
    }

    /// dB → amplitude
    @inline(__always) static func amp(_ db: Float) -> Float { db <= -95 ? 0 : exp2f(db / 6.0206) }
    /// a DX7 level (0…99) as dB (99 = 0 dB, about 0.75 dB per step)
    @inline(__always) static func levelDB(_ l: Float) -> Float { l <= 0 ? -96 : (min(l, 99) - 99) * 0.75 }
    /// an envelope rate (0…99, plus rate scaling) as dB per second
    @inline(__always) static func rateDB(_ r: Float, _ scale: Float) -> Float { 0.2 * exp2f(min(r * 41 / 64 + scale, 63) / 4) }
    static let pmsTable: [Float] = [0, 0.1, 0.2, 0.35, 0.6, 1.2, 2.4, 12]      // semitones at full depth
    static let amsTable: [Float] = [0, 0.25, 0.5, 1]

    private func keyOn(_ v: Int, _ velocity: Float, _ oks: Bool, _ lks: Bool) {
        if !active[v] || oks { for op in 0..<6 { phase[v * 6 + op] = 0 } }
        if !active[v] {
            for op in 0..<6 { eg[v * 6 + op] = Self.levelDB(params[FMLayout.base(op) + FMLayout.L + 3]) }
            peg[v] = params[FMLayout.pl + 3]
            fb1[v] = 0; fb2[v] = 0
        }
        for op in 0..<6 {
            stage[v * 6 + op] = 0
            // an attack starts from about -40 dB, as on the DX7 (otherwise most of it would be inaudible)
            if eg[v * 6 + op] < -40 && Self.levelDB(params[FMLayout.base(op) + FMLayout.L]) > -40 { eg[v * 6 + op] = -40 }
        }
        pStage[v] = 0
        active[v] = true; gate[v] = true; vel[v] = velocity
        if lks { lfoPhase = 0 }
        lfoDelay = 0
    }
    private func keyOff(_ v: Int) {
        gate[v] = false
        for op in 0..<6 { stage[v * 6 + op] = 3 }
        pStage[v] = 3
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let o = outputs[0]
        o.update(repeating: 0, count: frames)
        let sr = Float(sampleRate)
        let alg = FMAlgorithms.all[min(max(Int(params[FMLayout.algo].rounded()) - 1, 0), 31)]
        let fbN = min(max(params[FMLayout.fb].rounded(), 0), 7)
        let fbScale: Float = fbN < 0.5 ? 0 : 0.5 * exp2f(fbN - 7)               // in cycles
        let oks = params[FMLayout.oks] > 0.5, lks = params[FMLayout.lks] > 0.5
        let gain = params[FMLayout.level] * 0.5 / sqrtf(Float(alg.carriers.count))
        let transpose = params[FMLayout.transpose].rounded()
        // per operator, for this block
        for op in 0..<6 {
            let b = FMLayout.base(op)
            ol[op] = Self.levelDB(params[b + FMLayout.OL])
            for k in 0..<4 { target[op * 4 + k] = Self.levelDB(params[b + FMLayout.L + k]) }
            let fc = min(max(params[b + FMLayout.FC].rounded(), 0), 31), ff = min(max(params[b + FMLayout.FF].rounded(), 0), 99)
            fixed[op] = params[b + FMLayout.OM] > 0.5
            ratio[op] = fixed[op] ? powf(10, Float(Int(fc) % 4) + ff / 100)
                                  : (fc < 0.5 ? 0.5 : fc) * (1 + ff / 100) * exp2f(params[b + FMLayout.DT].rounded() * 1.5 / 1200)
            amsD[op] = Self.amsTable[min(max(Int(params[b + FMLayout.AMS].rounded()), 0), 3)] * 48
            velD[op] = params[b + FMLayout.KVS] / 7 * 24
            carrier[op] = alg.carriers.contains(op)
        }
        // the LFO, once per sample for every voice
        let lfoHz = Double(0.062 * exp2f(params[FMLayout.lfs] * 0.1))
        let dl = params[FMLayout.lfd] / 99
        let lfoDelayStep: Float = dl <= 0.001 ? 1 : 1 / max(dl * dl * 5 * sr, 1)
        let pmd = params[FMLayout.lpmd] / 99 * Self.pmsTable[min(max(Int(params[FMLayout.lpms].rounded()), 0), 7)]
        let amd = params[FMLayout.lamd] / 99
        let wave = min(max(Int(params[FMLayout.lfw].rounded()), 0), 5)
        for i in 0..<frames {
            lfoPhase += lfoHz / sampleRate
            if lfoPhase >= 1 { lfoPhase -= 1; lfoSH = rng.next() * 2 - 1 }
            let p = Float(lfoPhase)
            var y: Float
            switch wave {
            case 0: y = p < 0.5 ? 4 * p - 1 : 3 - 4 * p
            case 1: y = 1 - 2 * p
            case 2: y = 2 * p - 1
            case 3: y = p < 0.5 ? 1 : -1
            case 4: y = sinf(2 * .pi * p)
            default: y = lfoSH
            }
            lfoDelay = min(lfoDelay + lfoDelayStep, 1)
            lfo[i] = y * lfoDelay
        }
        let hasPitch = isConnected(connected, 0), hasGate = isConnected(connected, 1), hasVel = isConnected(connected, 2)
        let np = hasPitch ? inVoices[0] : 1, ng = hasGate ? inVoices[1] : 1, nv = hasVel ? inVoices[2] : 1
        let count = max(np, ng)

        for v in 0..<count {
            let pin = voice(inputs[0], min(v, np - 1)), gin = voice(inputs[1], min(v, ng - 1)), vin = voice(inputs[2], min(v, nv - 1))
            let w = v * 6
            // per note: rate scaling and keyboard level scaling
            let midi = 60 + (hasPitch ? cvSemitones(pin[frames - 1]) : 0) + transpose
            for op in 0..<6 {
                let b = FMLayout.base(op)
                let rs = params[b + FMLayout.RS] * max(midi - 21, 0) / 24
                for k in 0..<4 { rate[(w + op) * 4 + k] = Self.rateDB(params[b + FMLayout.R + k], rs) / sr }
                let d = midi - (params[b + FMLayout.BP] + 21)
                let depth = d > 0 ? params[b + FMLayout.RD] : params[b + FMLayout.LD]
                let curve = Int((d > 0 ? params[b + FMLayout.RC] : params[b + FMLayout.LC]).rounded())
                let x = abs(d) / 12
                let shape: Float = curve == 1 || curve == 2 ? min((exp2f(x) - 1) / 15, 1) : min(x / 4, 1)
                att[w + op] = depth * 0.75 * shape * (curve >= 2 ? -1 : 1)
            }
            for i in 0..<frames {
                // notes on / off
                if hasGate {
                    let g = gin[i]
                    if edges[v].rising(g) { keyOn(v, hasVel ? min(max(vin[i], 0), 1) : 0.8, oks, lks) }
                    else if gate[v] && g < 0.1 { keyOff(v) }
                } else if !active[v] {
                    keyOn(v, 0.8, oks, lks)                     // nothing on the gate: a drone
                }
                guard active[v] else { continue }
                // pitch envelope (in DX7 levels, 50 = no change)
                let pk = pStage[v]
                if pk < 3 || (pk == 3 && !gate[v]) {
                    let tgt = params[FMLayout.pl + pk], r = Self.rateDB(params[FMLayout.pr + pk], 0) / 0.75 / sr
                    if peg[v] < tgt { peg[v] = min(peg[v] + r, tgt) } else { peg[v] = max(peg[v] - r, tgt) }
                    if peg[v] == tgt && pk < 3 { pStage[v] = pk == 2 ? 4 : pk + 1 }
                }
                // pitch: the note, the pitch envelope and the LFO
                let semis = (hasPitch ? cvSemitones(pin[i]) : 0) + transpose + (peg[v] - 50) / 50 * 48 + lfo[i] * pmd
                let hz = 261.6256 * exp2f(semis / 12)
                let lfoAmp = (1 - lfo[i]) / 2 * amd
                var sum: Float = 0
                var heard = false
                // operators 6 → 1 (modulators come after the operators they modulate, so they're ready first)
                for op in stride(from: 5, through: 0, by: -1) {
                    let j = w + op
                    // envelope: stages 0, 1, 2 to L1, L2, L3, then hold; released, to L4
                    let k = stage[j]
                    if k < 4 {
                        let t = target[op * 4 + k], r = rate[j * 4 + k]
                        if eg[j] < t { eg[j] = min(eg[j] + r * 2, t) } else { eg[j] = max(eg[j] - r, t) }
                        if eg[j] == t && k < 3 { stage[j] = k == 2 ? 4 : k + 1 }
                    }
                    let a = Self.amp(min(eg[j] + ol[op] - att[j] - velD[op] * (1 - vel[v]) - lfoAmp * amsD[op], 0))
                    if a > 0 && carrier[op] { heard = true }
                    var mod: Float = 0
                    for m in alg.mods[op] { mod += out[w + m] }
                    mod *= 2
                    if op == alg.fbTarget { mod += fbScale * (fb1[v] + fb2[v]) * 0.5 }
                    let y = a * sinf(2 * .pi * Float(phase[j] + Double(mod)))
                    out[j] = y
                    phase[j] += Double((fixed[op] ? ratio[op] : hz * ratio[op]) / sr)
                    if phase[j] >= 1 { phase[j] -= floor(phase[j]) }
                    if carrier[op] { sum += y }
                }
                fb2[v] = fb1[v]; fb1[v] = out[w + alg.fbSource]
                // a patched velocity also sets the note's loudness (0 = silent), on top of each operator's
                // own velocity sensitivity (which shapes the tone, as on the DX7)
                o[i] += sum * gain * (hasVel ? vel[v] : 1)
                if !gate[v] && !heard {
                    active[v] = false
                    for op in 0..<6 { eg[w + op] = -96; stage[w + op] = 4; out[w + op] = 0 }
                }
            }
        }
        // notes no longer on the cable fade out
        if count < Self.V { for v in count..<Self.V where gate[v] { keyOff(v) } }
        for op in 0..<6 {
            var m: Float = 0
            for v in 0..<Self.V where active[v] { m = max(m, Self.amp(eg[v * 6 + op])) }
            readouts[op] = m
        }
    }
}
