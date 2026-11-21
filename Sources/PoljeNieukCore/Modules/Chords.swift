import Foundation

/// chord : a chord generator. "in key": a degree (I–VII) of a scale in a key, stacked in thirds; "free": a
/// chord type on the root. Voicing (inversion, spread, octave), voice leading (each chord takes the inversion
/// closest to the last), strum. The whole chord leaves on one pitch / gate cable — a synth plays every note
/// on it; a mono module (out to the modular) gets the lowest.
public final class ChordNode: DSPNode {
    // params: 0 mode, 1 key, 2 scale, 3 degree, 4 size (in key), 5 type (free), 6 voices, 7 inversion,
    //         8 spread, 9 voice leading, 10 octave, 11 strum, 12 strum direction
    // inputs: 0 root (pitch CV, transposes the chord), 1 gate
    // outputs: pitch, gate (all the chord's notes on each)
    // readouts: 0…3 the notes (semitones from middle C), 4 how many, 5 chord root (0…11), 6 quality index
    public static let maxVoices = kMaxVoices
    public static let keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    public static let scales = ["major", "minor", "dorian", "phrygian", "lydian", "mixolydian", "harmonic minor", "melodic minor"]
    static let scaleSteps: [[Int]] = [[0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10],
                                      [0, 2, 4, 6, 7, 9, 11], [0, 2, 4, 5, 7, 9, 10], [0, 2, 3, 5, 7, 8, 11], [0, 2, 3, 5, 7, 9, 11]]
    public static let degrees = ["I", "II", "III", "IV", "V", "VI", "VII"]
    public static let sizes = ["triad", "seventh", "ninth", "sus2", "sus4"]
    public static let types = ["maj", "min", "7", "maj7", "m7", "sus2", "sus4", "dim", "aug", "6", "m6", "add9", "9", "m9", "m7♭5", "dim7"]
    static let typeIntervals: [[Int]] = [[0, 4, 7], [0, 3, 7], [0, 4, 7, 10], [0, 4, 7, 11], [0, 3, 7, 10], [0, 2, 7], [0, 5, 7],
                                         [0, 3, 6], [0, 4, 8], [0, 4, 7, 9], [0, 3, 7, 9], [0, 4, 7, 14], [0, 4, 10, 14], [0, 3, 10, 14],
                                         [0, 3, 6, 10], [0, 3, 6, 9]]
    public static let spreads = ["close", "open", "drop 2", "wide"]
    public static let directions = ["up", "down", "alternate"]

    private var notes = [Float](repeating: 0, count: ChordNode.maxVoices)       // the chord now (semitones)
    private var count = 3
    private var last: [Float] = []                                            // for voice leading
    private var lastOctave = 0
    private var sig = Int.min
    private var gateEdge = EdgeDetector()
    private var gateHigh = false
    private var startIn = [Int](repeating: -1, count: ChordNode.maxVoices)    // samples until a voice's gate opens
    private var on = [Bool](repeating: false, count: ChordNode.maxVoices)
    private var retrig = 0                                                    // a short gap before re-striking
    private var alternate = false
    private var chordRoot = 0, quality = 0

    // MARK: building the chord (only when something changed)

    /// The chord's notes, ascending (semitones from middle C), its root pitch class and quality.
    public static func build(mode: Int, key: Int, scale: Int, degree: Int, size: Int, type: Int, voices: Int,
                      inversion: Int, spread: Int, octave: Int, shift: Float, previous: [Float]?) -> (notes: [Float], root: Int, quality: Int) {
        var iv: [Int]
        var root: Int
        var quality: Int
        if mode == 0 {
            // in key: stack scale notes in thirds from the degree
            let st = scaleSteps[scale]
            func note(_ k: Int) -> Int { st[((k % 7) + 7) % 7] + 12 * Int(floor(Double(k) / 7)) }
            let picks: [Int]
            switch size {
            case 1: picks = [0, 2, 4, 6]
            case 2: picks = [0, 2, 4, 6, 8]
            case 3: picks = [0, 1, 4]
            case 4: picks = [0, 3, 4]
            default: picks = [0, 2, 4]
            }
            let base = note(degree)
            iv = picks.map { note(degree + $0) - base }
            root = (key + base) % 12
            // name it: find the free type with the same intervals (for the display)
            quality = typeIntervals.firstIndex(of: iv) ?? (typeIntervals.firstIndex(of: Array(iv.prefix(4))) ?? -1)
            iv = iv.map { $0 + base }
        } else {
            iv = typeIntervals[type]
            root = key
            quality = type
        }
        // fit the voice count: drop the fifth first when there are too many notes, double the root an octave
        // up when there are too few
        var n = iv
        while n.count > voices, let five = n.indices.dropFirst().first(where: { (n[$0] - n[0]) % 12 == 7 }) ?? n.indices.dropFirst().first {
            n.remove(at: five)
        }
        while n.count < voices { n.append(n[0] + 12 * (1 + (n.count - 1) / 3)) }
        n.sort()
        let center = Float(key + 12 * octave) + shift
        func voiced(_ inv: Int, _ oct: Int) -> [Float] {
            var v = n
            for _ in 0..<inv { let lo = v.removeFirst(); v.append(lo + 12) }
            switch spread {
            case 1: if v.count > 1 { v[1] += 12 }                                  // open: the second note up
            case 2: if v.count > 2 { v[v.count - 2] -= 12 }                        // drop 2: second from the top down
            case 3: if v.count > 1 { v[1] += 12 }; if v.count > 3 { v[3] += 12 }   // wide
            default: break
            }
            return v.map { Float($0 + 12 * oct) + center }.sorted()
        }
        var best = voiced(inversion % max(n.count, 1), 0)
        if let prev = previous, prev.count == n.count {
            // voice leading: the inversion / octave that moves least from the last chord
            var score = Float.infinity
            for inv in 0..<n.count {
                for oct in -1...1 {
                    let c = voiced(inv, oct)
                    let d = zip(c, prev).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
                    if d < score { score = d; best = c }
                }
            }
        }
        return (best, root, quality)
    }

    // MARK: audio

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let mode = clampIndex(params[0], 2), key = clampIndex(params[1], 12), scale = clampIndex(params[2], Self.scales.count)
        let degree = clampIndex(params[3], 7), size = clampIndex(params[4], Self.sizes.count), type = clampIndex(params[5], Self.types.count)
        let voices = clampIndex(params[6], 2) + 3
        let inversion = clampIndex(params[7], 4), spread = clampIndex(params[8], Self.spreads.count)
        let leading = params[9] > 0.5, octave = clampIndex(params[10] + 3, 7) - 3
        let strum = max(0, Int(params[11] * 0.001 * Float(sampleRate)))
        let dir = clampIndex(params[12], 3)
        let hasRoot = isConnected(connected, 0), hasGate = isConnected(connected, 1)
        let shift = hasRoot ? cvSemitones(inputs[0][frames - 1]).rounded() : 0
        // rebuild only when a setting or the root changed (it allocates; it doesn't happen per sample)
        // (plain arithmetic: nothing allocated on the audio thread)
        var h = mode
        h = h &* 31 &+ key; h = h &* 31 &+ scale; h = h &* 31 &+ degree; h = h &* 31 &+ size; h = h &* 31 &+ type
        h = h &* 31 &+ voices; h = h &* 31 &+ inversion; h = h &* 31 &+ spread; h = h &* 31 &+ (leading ? 1 : 0)
        h = h &* 31 &+ octave; h = h &* 31 &+ Int(shift)
        var changed = false
        if h != sig {
            sig = h
            // the octave setting moves the remembered chord too, so voice leading doesn't pull it back
            if octave != lastOctave {
                for k in last.indices { last[k] += Float(12 * (octave - lastOctave)) }
                lastOctave = octave
            }
            let c = Self.build(mode: mode, key: key, scale: scale, degree: degree, size: size, type: type, voices: voices,
                               inversion: inversion, spread: spread, octave: octave, shift: shift,
                               previous: leading && last.count == voices ? last : nil)
            for k in 0..<Self.maxVoices { notes[k] = k < c.notes.count ? c.notes[k] : c.notes.last ?? 0 }
            changed = c.notes != last
            last = c.notes; count = c.notes.count
            chordRoot = c.root; quality = c.quality
        }
        // strum order: which voice opens first
        func order(_ k: Int) -> Int {
            switch dir {
            case 1: return count - 1 - k
            case 2: return alternate ? count - 1 - k : k
            default: return k
            }
        }
        func strike() {
            for k in 0..<count { startIn[k] = order(k) * strum; on[k] = false }
            if dir == 2 { alternate.toggle() }
        }
        if !hasGate && changed {
            // no gate patched: the chord rings, and re-strikes (briefly off, then strummed) when it changes
            for k in 0..<Self.maxVoices { on[k] = false }
            retrig = max(16, Int(0.003 * sampleRate))
        }
        let g = inputs[1]
        outVoices[0] = count; outVoices[1] = count
        for i in 0..<frames {
            if hasGate {
                if gateEdge.rising(g[i]) { gateHigh = true; strike() }
                else if gateHigh && g[i] < 0.1 { gateHigh = false; for k in 0..<Self.maxVoices { on[k] = false; startIn[k] = -1 } }
            } else if retrig > 0 {
                retrig -= 1
                if retrig == 0 { strike() }
            } else if !on[0] && startIn[0] < 0 && sig != Int.min {
                strike()                                       // first block: start ringing
            }
            for k in 0..<Self.maxVoices {
                if startIn[k] >= 0 { if startIn[k] == 0 { on[k] = true }; startIn[k] -= 1 }
                guard k < count else { continue }
                outVoice(0, k)[i] = pitchCV(notes[k])
                outVoice(1, k)[i] = on[k] ? kGateHigh : 0
            }
        }
        for k in 0..<Self.maxVoices { readouts[k] = notes[k] }
        readouts[4] = Float(count)
        readouts[5] = Float(chordRoot)
        readouts[6] = Float(quality)
    }
}
