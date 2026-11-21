import Foundation
import Synchronization

/// wave : a wavetable synth with four waves you draw yourself, morphed by "position".
///
/// A drawn wave has sharp corners, which would alias horribly at high notes. So every wave is kept as a set
/// of band-limited tables, one per octave (the harmonics that fit under Nyquist at that pitch), rebuilt on
/// the main thread whenever a wave changes, and handed to the audio thread through a double buffer.
public final class WavetableNode: DSPNode {
    // params: 0 edit wave (UI only), 1 position (0…3), 2 frequency (st), 3 fine (ct), 4 attack, 5 decay (0 = drone), 6 level,
    // inputs: 0 pitch (0.1 = 1 octave), 1 trig — a chord on these cables (roll, chord) plays every note
    // outputs: out (all notes mixed)   readouts: 0 position now
    public static let frames = 4
    /// points per drawn wave
    public static let points = 256
    static let harmonics = points / 2
    /// samples per band-limited table (+1 guard sample for interpolation)
    static let tableLen = 2048
    /// octave levels: level L keeps harmonics 1 … 128 >> L
    static let levels = 8

    /// The drawn waves (frames × points, -1 … 1). Main thread: draw into it, then call `rebuild`.
    public let drawn: UnsafeMutablePointer<Float>
    /// Bumped whenever a wave changes (for the display).
    public private(set) var version = 0

    private let tables: UnsafeMutablePointer<Float>          // 2 buffers × frames × levels × (tableLen + 1)
    private static var frameSize: Int { levels * (tableLen + 1) }
    private static var bufferSize: Int { frames * frameSize }
    private let active = Atomic<Int>(0)       // the buffer the audio thread should read
    private let inUse = Atomic<Int>(0)        // the buffer it is reading
    private let blocks = Atomic<Int>(0)       // counts audio blocks (to tell whether audio is running)

    public static let maxVoices = kMaxVoices
    private var phase = [Double](repeating: 0, count: WavetableNode.maxVoices)
    private var pos: Float = 0
    private var env = [Float](repeating: 1, count: WavetableNode.maxVoices)
    private var rising = [Bool](repeating: false, count: WavetableNode.maxVoices)
    private var trigEdge = [EdgeDetector](repeating: EdgeDetector(), count: WavetableNode.maxVoices)

    public static let presets = ["sine", "tri", "saw", "square", "pulse", "noise"]

    public override init(spec: ModuleSpec, sampleRate: Double) {
        drawn = .allocate(capacity: Self.frames * Self.points)
        drawn.initialize(repeating: 0, count: Self.frames * Self.points)
        tables = .allocate(capacity: 2 * Self.bufferSize)
        tables.initialize(repeating: 0, count: 2 * Self.bufferSize)
        super.init(spec: spec, sampleRate: sampleRate)
        let start = Self.starter
        for k in 0..<start.count { drawn[k] = start[k] }
        rebuildAll()
    }
    deinit { drawn.deallocate(); tables.deallocate() }

    /// A starting set: sine, triangle, saw, square.
    static let starter: [Float] = {
        var v: [Float] = []
        for name in ["sine", "tri", "saw", "square"] { v += shape(name) }
        return v
    }()

    /// One of the ready-made shapes (points values).
    public static func shape(_ name: String) -> [Float] {
        (0..<points).map { i in
            let p = Float(i) / Float(points)
            switch name {
            case "tri": return p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4)
            case "saw": return 1 - 2 * p
            case "square": return p < 0.5 ? 0.9 : -0.9
            case "pulse": return p < 0.15 ? 0.9 : -0.9
            case "noise": return Float.random(in: -0.9...0.9)
            default: return sinf(2 * .pi * p)
            }
        }
    }

    public override var defaultData: [String: [Float]] { ["wave": Self.starter] }

    public override func setData(_ key: String, _ values: [Float]) {
        guard key == "wave", !values.isEmpty else { return }
        let n = Self.frames * Self.points
        for k in 0..<n { let v = k < values.count ? values[k] : 0; drawn[k] = v.isFinite ? min(max(v, -1), 1) : 0 }
        rebuildAll()
    }

    /// The drawn waves, for saving (frames × points).
    public var waveData: [Float] { (0..<Self.frames * Self.points).map { drawn[$0] } }

    // MARK: building the band-limited tables (main thread)

    private static let cosT: [Float] = (0..<tableLen).map { cosf(2 * .pi * Float($0) / Float(tableLen)) }
    private static let sinT: [Float] = (0..<tableLen).map { sinf(2 * .pi * Float($0) / Float(tableLen)) }

    /// Rebuild one wave's tables (after drawing it), or all of them.
    public func rebuild(frame: Int) { swapIn([frame]) }
    public func rebuildAll() { swapIn(Array(0..<Self.frames)) }

    private func swapIn(_ changed: [Int]) {
        let cur = active.load(ordering: .acquiring), target = 1 - cur
        // wait until the audio thread has moved off the buffer we're about to write (a block at most);
        // if audio isn't running, there's nothing to wait for
        let start = blocks.load(ordering: .relaxed)
        var waited = 0
        while inUse.load(ordering: .acquiring) == target && waited < 40 {
            usleep(100); waited += 1
            if waited == 20 && blocks.load(ordering: .relaxed) == start { break }
        }
        let dst = tables + target * Self.bufferSize, src = tables + cur * Self.bufferSize
        for f in 0..<Self.frames where !changed.contains(f) {
            (dst + f * Self.frameSize).update(from: src + f * Self.frameSize, count: Self.frameSize)
        }
        for f in changed { build(frame: f, into: dst + f * Self.frameSize) }
        active.store(target, ordering: .releasing)
        version &+= 1
    }

    private func build(frame f: Int, into out: UnsafeMutablePointer<Float>) {
        let N = Self.points, H = Self.harmonics, T = Self.tableLen
        let x = drawn + f * N
        // the drawn wave's harmonics (its average — DC — is left out)
        var a = [Float](repeating: 0, count: H + 1), b = [Float](repeating: 0, count: H + 1)
        for h in 1...H {
            var sa: Float = 0, sb: Float = 0
            for n in 0..<N {
                let k = (h * n * (T / N)) % T
                sa += x[n] * Self.cosT[k]; sb += x[n] * Self.sinT[k]
            }
            let scale: Float = h == H ? 1 / Float(N) : 2 / Float(N)
            a[h] = sa * scale; b[h] = sb * scale
        }
        for L in 0..<Self.levels {
            let top = max(H >> L, 1)
            let t = out + L * (T + 1)
            for k in 0..<T {
                var s: Float = 0
                for h in 1...top {
                    let i = (h * k) % T
                    s += a[h] * Self.cosT[i] + b[h] * Self.sinT[i]
                }
                t[k] = s
            }
            t[T] = t[0]
        }
    }

    // MARK: audio

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let buf = active.load(ordering: .acquiring)
        inUse.store(buf, ordering: .releasing)
        blocks.wrappingAdd(1, ordering: .relaxed)
        let base = tables + buf * Self.bufferSize
        let target = min(max(params[1], 0), Float(Self.frames - 1))
        let attackMs = params[4], decayMs = params[5], gain = params[6]
        let decays = decayMs > 0.5
        let mul = decays ? expf(logf(1e-3) / max(decayMs * 0.001 * Float(sampleRate), 1)) : 1
        let rise: Float = attackMs > 0.5 ? 1 / max(attackMs * 0.001 * Float(sampleRate), 1) : 1
        let posC: Float = 1 - expf(-1 / (0.005 * Float(sampleRate)))
        let T = Self.tableLen, TL = Double(T)
        let o = outputs[0]
        o.update(repeating: 0, count: frames)
        // the morph position moves smoothly; worked out once per sample for all voices
        let p0 = pos
        pos += (target - pos) * (1 - powf(1 - posC, Float(frames)))
        let hasPitch = isConnected(connected, 0), hasTrig = isConnected(connected, 1)
        // one voice per note arriving (a chord); a mono cable is one note
        let np = hasPitch ? inVoices[0] : 1, nt = hasTrig ? inVoices[1] : 1
        for v in 0..<max(np, nt) {
            let pitch = voice(inputs[0], min(v, np - 1)), tr = voice(inputs[1], min(v, nt - 1))
            let semis = params[2] + params[3] / 100 + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0)
            let hz = 261.6256 * Double(powf(2, semis / 12))
            let inc = hz / sampleRate
            // the band-limited level: only harmonics that fit under ~90 % of Nyquist
            let fit = max(sampleRate * 0.45 / max(hz, 1), 1)
            let level = min(max(Int(ceil(log2(Double(Self.harmonics) / fit))), 0), Self.levels - 1)
            let useEnv = hasTrig && (decays || attackMs > 0.5)
            var ph = phase[v], e = env[v], up = rising[v], edge = trigEdge[v]
            var pp = p0
            for i in 0..<frames {
                pp += (target - pp) * posC
                let f0 = min(Int(pp), Self.frames - 2), t = pp - Float(f0)
                let ta = base + f0 * Self.frameSize + level * (T + 1)
                let tb = ta + Self.frameSize
                let p = ph * TL
                let k = Int(p), fr = Float(p - Double(k))
                let va = ta[k] + (ta[k + 1] - ta[k]) * fr
                let vb = tb[k] + (tb[k + 1] - tb[k]) * fr
                var y = va + (vb - va) * t
                if hasTrig && edge.rising(tr[i]) {
                    if rise < 1 { e = 0; up = true } else { e = 1; up = false }
                }
                if useEnv {
                    y *= e
                    if up { e += rise; if e >= 1 { e = 1; up = false } } else { e *= mul }
                }
                o[i] += y * gain
                ph += inc
                if ph >= 1 { ph -= floor(ph) }
            }
            phase[v] = ph; env[v] = e; rising[v] = up; trigEdge[v] = edge
        }
        readouts[0] = pos
    }
}
