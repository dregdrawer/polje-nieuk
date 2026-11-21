import Foundation

@inline(__always) func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }

/// Converts a parameter value to an index in 0..<count. Never traps (NaN/inf → 0).
@inline(__always) func clampIndex(_ v: Float, _ count: Int) -> Int {
    guard v.isFinite, count > 0 else { return 0 }
    let r = v.rounded()
    if r <= 0 { return 0 }
    if r >= Float(count - 1) { return count - 1 }
    return Int(r)
}

/// Double → Int that never traps.
@inline(__always) func safeInt(_ v: Double, _ lo: Int = 0, _ hi: Int = Int(Int32.max)) -> Int {
    guard v.isFinite else { return lo }
    if v <= Double(lo) { return lo }
    if v >= Double(hi) { return hi }
    return Int(v)
}

/// True when the beat position moved into a new multiple of `unit` (or jumped backwards, e.g. on reset).
@inline(__always) func crossed(_ prev: Double, _ now: Double, _ unit: Double) -> Bool {
    // a stopped transport parks the beat just below 0: nothing fires there, and the first step fires
    // as soon as ▶ moves it past 0
    now >= 0 && (now < prev || floor(now / unit) != floor(prev / unit))
}

/// Linear-interpolated read from a circular buffer. Out-of-range or NaN positions are wrapped/clamped,
/// never read outside the buffer.
@inline(__always) func readLinear(_ buf: UnsafeMutablePointer<Float>, _ len: Int, _ pos: Double) -> Float {
    guard len > 0 else { return 0 }
    var p = pos
    if !(p >= 0 && p < Double(len)) {
        guard p.isFinite else { return 0 }
        p = p.truncatingRemainder(dividingBy: Double(len))
        if p < 0 { p += Double(len) }
        if p >= Double(len) { p = 0 }
    }
    let i = min(Int(p), len - 1)
    let f = Float(p - Double(i))
    let a = buf[i]
    let b = buf[i + 1 >= len ? 0 : i + 1]
    return a + (b - a) * f
}

@inline(__always) func wrap(_ p: Double, _ len: Double) -> Double {
    var x = p.truncatingRemainder(dividingBy: len)
    if x < 0 { x += len }
    return x
}

/// Gentle limiter that leaves signals under 0.8 untouched and never exceeds 1.
@inline(__always) func softClip(_ x: Float) -> Float {
    let a = abs(x)
    if a <= 0.8 { return x }
    let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
    return x < 0 ? -y : y
}

struct XorShift {
    var s: UInt32 = 0x9E37_79B9
    init(seed: UInt32 = 0x9E37_79B9) { s = seed == 0 ? 1 : seed }
    /// Uniform in [0, 1].
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(s) / Float(UInt32.max)
    }
}

struct PeakMeter {
    var value: Float = 0
    mutating func update(_ buf: UnsafePointer<Float>, _ n: Int, sampleRate: Double) -> Float {
        var m: Float = 0
        for i in 0..<n { m = max(m, abs(buf[i])) }
        value = max(m, value * powf(0.5, Float(n) / Float(sampleRate * 0.12)))
        return value
    }
    /// Same, from a peak already measured over `n` samples.
    mutating func update(peak m: Float, _ n: Int, sampleRate: Double) -> Float {
        value = max(m.isFinite ? m : 0, value * powf(0.5, Float(n) / Float(sampleRate * 0.12)))
        return value
    }
}

/// Clock divisions shared by synced modules, in beats (quarter notes).
public enum Divisions {
    public static let names = ["1/32", "1/16T", "1/16", "1/8T", "1/16D", "1/8", "1/4T", "1/8D",
                               "1/4", "1/2T", "1/4D", "1/2", "1/2D", "1 bar", "2 bars", "4 bars"]
    /// lfo~ also goes slower: every 8 or 16 bars
    public static let longNames = names + ["8 bars", "16 bars"]
    static let beatValues: [Double] = [0.125, 1.0 / 6, 0.25, 1.0 / 3, 0.375, 0.5, 2.0 / 3, 0.75,
                                       1, 4.0 / 3, 1.5, 2, 3, 4, 8, 16, 32, 64]
    @inline(__always) public static func beats(_ v: Float) -> Double {
        beatValues[clampIndex(v, beatValues.count)]
    }
    public static func index(_ name: String) -> Int { names.firstIndex(of: name) ?? 0 }
}

/// Zero-delay-feedback state-variable filter (Simper).
struct SVF {
    var ic1: Float = 0, ic2: Float = 0
    var a1: Float = 0, a2: Float = 0, a3: Float = 0, k: Float = 1.414
    mutating func set(freq: Float, sampleRate: Float, k: Float) {
        let g = tanf(Float.pi * min(max(freq, 5), sampleRate * 0.45) / sampleRate)
        self.k = k
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    @inline(__always) mutating func process(_ x: Float) -> (low: Float, band: Float, high: Float) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }
}

/// Bipolar LFO shapes for phase in [0, 1): sine, triangle, saw, square.
@inline(__always) func lfoShape(_ shape: Int, _ phase: Double) -> Float {
    let p = Float(phase - floor(phase))
    switch shape {
    case 0: return sinf(2 * .pi * p)
    case 1: return p < 0.5 ? 4 * p - 1 : 3 - 4 * p
    case 2: return 2 * p - 1
    default: return p < 0.5 ? 1 : -1
    }
}

/// Rising-edge detector with hysteresis for gates/triggers coming from the modular.
struct EdgeDetector {
    var high = false
    @inline(__always) mutating func rising(_ x: Float) -> Bool {
        if !high && x > 0.2 { high = true; return true }
        if high && x < 0.1 { high = false }
        return false
    }
}

/// Free-running or clock-locked phase accumulator shared by LFO-style modules.
struct PhaseClock {
    var phase: Double = 0
    @inline(__always) mutating func advance(sync: Bool, hz: Double, divBeats: Double, beat: Double, sampleRate: Double) -> Double {
        if sync {
            let p = beat / divBeats
            phase = p - floor(p)
        } else {
            phase += hz / sampleRate
            if phase >= 1 { phase -= floor(phase) }
        }
        return phase
    }
}

@inline(__always) func onePoleCoef(ms: Float, sampleRate: Double) -> Float {
    ms <= 0 ? 1 : 1 - expf(-1 / (ms * 0.001 * Float(sampleRate)))
}

/// Drum / piano rolls: a new division keeps the pattern in time. Finer (1/16 → 1/32) spreads the steps out
/// and doubles the length; coarser (1/16 → 1/8) halves it, and a hit between the new steps joins the step
/// before. `values` is lane × 32 steps (lane * steps + step); `empty` is what a blank step holds.
public enum PatternRescale {
    public static func rescale(_ values: [Float], lanes: Int, steps: Int, length: Int,
                               fromDivision old: Float, toDivision new: Float, empty: Float) -> (values: [Float], length: Int) {
        let r = Divisions.beats(old) / Divisions.beats(new)           // new steps per old step
        guard r.isFinite, r > 0, abs(r - 1) > 1e-9 else { return (values, length) }
        let newLen = min(max(Int((Double(length) * r).rounded()), 1), steps)
        var out = [Float](repeating: empty, count: lanes * steps)
        for lane in 0..<lanes {
            for i in 0..<min(length, steps) {
                let k = lane * steps + i
                guard k < values.count, values[k] != empty, values[k].isFinite else { continue }
                let pos = Double(i) * r
                let j = r >= 1 ? Int(pos.rounded()) : Int(pos.rounded(.down) + 1e-9)
                guard j >= 0, j < newLen else { continue }
                let d = lane * steps + j
                // two hits landing together: keep the stronger (piano roll: the first note stays)
                if out[d] == empty || (empty == 0 && values[k] > out[d]) { out[d] = values[k] }
            }
        }
        return (out, newLen)
    }
}
