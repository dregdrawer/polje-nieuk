import Foundation

/// scope~ : a two-channel oscilloscope for anything in the patch — audio, LFOs, envelopes, pitch CV, gates.
/// Shows the waveform (min/max per pixel, so nothing between pixels is missed), and measures each channel:
/// average, lowest, highest (in volts: 0.1 = 1 V) and frequency. A steady pitch CV also reads as a note.
public final class ScopeNode: DSPNode {
    // params: 0 time (window, ms), 1 trigger (free / rise A / bar), 2 scale, 3 hold
    // inputs: A, B   readouts: A 0 mean, 1 min, 2 max, 3 Hz;  B 4 mean, 5 min, 6 max, 7 Hz
    public static let points = 256
    public static let scales = ["auto", "±10 V", "±5 V", "±1 V", "±0.1 V"]
    /// full-scale value for each fixed scale (0.1 = 1 V); 0 = auto
    public static let scaleValues: [Float] = [0, 1, 0.5, 0.1, 0.01]

    /// The last finished sweep, per channel: points × (min, max). Read by the display.
    public let shownMin: UnsafeMutablePointer<Float>
    public let shownMax: UnsafeMutablePointer<Float>
    /// Bumped each time a sweep is shown.
    public private(set) var version = 0

    private let curMin: UnsafeMutablePointer<Float>, curMax: UnsafeMutablePointer<Float>
    private var point = 0, inPoint = 0
    private var armed = false, waited = 0
    private var acc = [Double](repeating: 0, count: 2), accN = 0
    private var lo = [Float](repeating: 0, count: 2), hi = [Float](repeating: 0, count: 2)
    private var dc = [Float](repeating: 0, count: 2)
    private var above = [Bool](repeating: false, count: 2)
    private var sinceRise = [Double](repeating: 0, count: 2)
    private var period = [Double](repeating: 0, count: 2)
    private var prevBeat: Double = 0

    public override init(spec: ModuleSpec, sampleRate: Double) {
        let n = 2 * Self.points
        shownMin = .allocate(capacity: n); shownMin.initialize(repeating: 0, count: n)
        shownMax = .allocate(capacity: n); shownMax.initialize(repeating: 0, count: n)
        curMin = .allocate(capacity: n); curMin.initialize(repeating: 0, count: n)
        curMax = .allocate(capacity: n); curMax.initialize(repeating: 0, count: n)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { shownMin.deallocate(); shownMax.deallocate(); curMin.deallocate(); curMax.deallocate() }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let windowMs = Double(min(max(params[0], 1), 10_000))
        let perPoint = max(1, Int(windowMs * 0.001 * sampleRate / Double(Self.points)))
        let mode = clampIndex(params[1], 3)
        let hold = params[3] > 0.5
        let a = inputs[0], b = isConnected(connected, 1) ? inputs[1] : inputs[0]
        // pass-through: what comes in goes out untouched (so it can sit on any cable)
        outputs[0].update(from: inputs[0], count: frames)
        outputs[1].update(from: inputs[1], count: frames)
        let dcC = Float(1 - exp(-1 / (0.5 * sampleRate)))
        for i in 0..<frames {
            let xa = a[i].isFinite ? a[i] : 0, xb = b[i].isFinite ? b[i] : 0
            for c in 0..<2 {
                let v = c == 0 ? xa : xb
                // frequency: time between rising crossings of the channel's own average (with hysteresis)
                dc[c] += (v - dc[c]) * dcC
                let h = max(0.002, (hi[c] - lo[c]) * 0.05)
                sinceRise[c] += 1
                if !above[c] && v > dc[c] + h {
                    above[c] = true
                    let p = sinceRise[c]
                    if p > 2 && p < sampleRate * 20 { period[c] = period[c] == 0 || abs(p - period[c]) > period[c] * 0.1 ? p : period[c] + (p - period[c]) * 0.2 }
                    sinceRise[c] = 0
                } else if above[c] && v < dc[c] - h { above[c] = false }
                if sinceRise[c] > sampleRate * 20 { period[c] = 0 }
            }
            // waiting for the trigger: A rising through its average, or the start of a bar
            if armed {
                waited += 1
                let fire: Bool
                switch mode {
                case 1: fire = sinceRise[0] == 0          // A just rose through its average
                case 2: fire = crossed(prevBeat, ctx.beat[i], 4)
                default: fire = true
                }
                prevBeat = ctx.beat[i]
                // nothing to trigger on for a while: sweep anyway, so a flat line still shows
                if fire || waited > perPoint * Self.points * 2 { armed = false; waited = 0 } else { continue }
            } else { prevBeat = ctx.beat[i] }
            for c in 0..<2 {
                let v = c == 0 ? xa : xb
                let k = c * Self.points + point
                if inPoint == 0 { curMin[k] = v; curMax[k] = v } else { curMin[k] = min(curMin[k], v); curMax[k] = max(curMax[k], v) }
                acc[c] += Double(v)
            }
            accN += 1
            inPoint += 1
            if inPoint >= perPoint {
                inPoint = 0
                point += 1
                if point >= Self.points {
                    point = 0
                    for c in 0..<2 {
                        var l = Float.infinity, u = -Float.infinity
                        for p in 0..<Self.points { l = min(l, curMin[c * Self.points + p]); u = max(u, curMax[c * Self.points + p]) }
                        lo[c] = l; hi[c] = u
                        readouts[c * 4] = Float(acc[c] / Double(max(accN, 1)))
                        readouts[c * 4 + 1] = l
                        readouts[c * 4 + 2] = u
                        readouts[c * 4 + 3] = period[c] > 0 ? Float(sampleRate / period[c]) : 0
                        acc[c] = 0
                    }
                    accN = 0
                    if !hold {
                        shownMin.update(from: curMin, count: 2 * Self.points)
                        shownMax.update(from: curMax, count: 2 * Self.points)
                        version &+= 1
                    }
                    armed = mode != 0
                }
            }
        }
    }
}
