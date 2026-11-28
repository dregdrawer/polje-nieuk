import Foundation
import Synchronization
import AVFoundation

// arrange: a timeline of 8 tracks. Audio clips (files) sit on it in beats, with trims, fades and automatic
// crossfades where two overlap; it plays with the app's transport. Each track also has an L / R inlet that
// is heard through the track and can be recorded: armed tracks record to their own WAV files, which land on
// the timeline where they were played.

public enum ArrangeLayout {
    /// Most tracks a box can have (the "tracks" row picks how many it shows).
    public static let tracks = 32
    public static let defaultTrackCount = 8
    /// snap: "auto" follows the grid (finer as you zoom in)
    public static let snapNames = ["off", "auto", "1/16", "1/8", "1/4", "1/2", "1 bar"]
    public static let snapBeats: [Double] = [0, -1, 0.25, 0.5, 1, 2, 4]
    // params
    public static let trackCount = 0, level = 1, snap = 2, loop = 3, rec = 4
    public static func params() -> [ParamSpec] {
        [.integer("tracks", "tracks", 1, tracks, defaultTrackCount),
         ParamSpec("level", "level", -60, 6, 0, unit: "dB"),
         .choice("snap", "snap", snapNames, def: 1),
         .toggle("loop", "loop", false),
         .toggle("rec", "record armed", false)]
    }
    public static func count(_ v: Float?) -> Int { min(max(Int((v ?? Float(defaultTrackCount)).rounded()), 1), tracks) }
    public static var inputs: [String] { (1...tracks).flatMap { ["\($0) L", "\($0) R"] } }
    /// mix L / R, "multi" (no signal: a cable from it to a mixer patches every track into its own channel),
    /// then each track's L / R
    public static var outputs: [String] { ["L", "R", "multi"] + inputs }
    public static let multiOutlet = 2, firstTrackOutlet = 3
    // data
    public static let clipsKey = "clips", filesKey = "files", tracksKey = "tracks", loopKey = "loop"
    /// per track: volume (0 … 2, linear), pan (-1 … 1), mute, solo, arm
    public static let trackFields = 5
    public static var defaultTracks: [Float] { (0..<tracks).flatMap { _ in [1, 0, 0, 0, 0] as [Float] } }
    /// readouts: 0 position (beats, after the loop), 1 recording (1) / waiting for the bar (0.5),
    /// 2 where the take started, 3 seconds per beat, 4 mix level (track levels: `ArrangeNode.levels`)
    public static let posSlot = 0, recSlot = 1, recStartSlot = 2, secondsPerBeatSlot = 3, mixSlot = 4
}

/// One clip on the timeline (main thread; the patch keeps them as numbers, 8 to a clip).
public struct ArrangeClip: Equatable, Sendable {
    public var track: Int
    public var start: Double          // beats
    public var length: Double         // beats
    public var offset: Double         // seconds into the file
    public var gain: Float            // linear
    public var fadeIn: Double         // beats
    public var fadeOut: Double        // beats
    public var file: Int              // index into the box's file list
    /// semitones: re-pitched (up = higher and faster, like a record sped up)
    public var transpose: Float = 0
    public var end: Double { start + length }
    /// how fast the file plays (2 = an octave up)
    public var speed: Double { pow(2, Double(transpose) / 12) }
    public init(track: Int, start: Double, length: Double, offset: Double = 0, gain: Float = 1,
                fadeIn: Double = 0, fadeOut: Double = 0, file: Int, transpose: Float = 0) {
        self.track = track; self.start = start; self.length = length; self.offset = offset
        self.gain = gain; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.file = file; self.transpose = transpose
    }
    /// The patch keeps clips as numbers: a version mark (-9), then 9 to a clip. Older ones: 8 to a clip, no mark.
    public static let fields = 9
    static let mark: Float = -9
    public static func decode(_ v: [Float]) -> [ArrangeClip] {
        let new = v.first == mark
        let n = new ? 9 : 8, from = new ? 1 : 0
        return stride(from: from, to: v.count - n + 1, by: n).compactMap { i in
            let c = ArrangeClip(track: Int(v[i]), start: Double(v[i + 1]), length: Double(v[i + 2]), offset: Double(v[i + 3]),
                                gain: v[i + 4], fadeIn: Double(v[i + 5]), fadeOut: Double(v[i + 6]), file: Int(v[i + 7]),
                                transpose: new && v[i + 8].isFinite ? min(max(v[i + 8], -48), 48) : 0)
            guard c.track >= 0, c.track < ArrangeLayout.tracks, c.length > 0, c.file >= 0,
                  c.start.isFinite, c.length.isFinite, c.offset.isFinite, c.gain.isFinite else { return nil }
            return c
        }
    }
    public static func encode(_ c: [ArrangeClip]) -> [Float] {
        [mark] + c.flatMap { [Float($0.track), Float($0.start), Float($0.length), Float($0.offset), $0.gain,
                              Float($0.fadeIn), Float($0.fadeOut), Float($0.file), $0.transpose] }
    }
    /// The file list: paths as text, one per line.
    public static func decodeFiles(_ v: [Float]?) -> [String] {
        let s = String(decoding: (v ?? []).map { UInt8(clamping: Int($0)) }, as: UTF8.self)
        return s.isEmpty ? [] : s.components(separatedBy: "\n")
    }
    public static func encodeFiles(_ f: [String]) -> [Float] { f.joined(separator: "\n").utf8.map { Float($0) } }
}

/// A file's audio in memory, at its own sample rate, with a waveform overview.
public final class ClipAudio: @unchecked Sendable {
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public let frames: Int
    public let rate: Double
    /// peak (0 … 1) of each `peakBlock` frames
    public let peaks: [Float]
    public static let peakBlock = 256
    /// lowest / highest (L+R)/2 sample of every 32 and every 1024 frames: a waveform point costs a few reads
    public let lo32: [Float], hi32: [Float], lo1k: [Float], hi1k: [Float]
    public var seconds: Double { Double(frames) / max(rate, 1) }

    init(left l: [Float], right r: [Float], rate: Double) {
        let n = min(l.count, r.count)
        frames = n
        self.rate = rate
        let lp = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1)), rp = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
        l.withUnsafeBufferPointer { lp.initialize(from: $0.baseAddress!, count: n) }
        r.withUnsafeBufferPointer { rp.initialize(from: $0.baseAddress!, count: n) }
        left = lp; right = rp
        var p = [Float](repeating: 0, count: (n + Self.peakBlock - 1) / Self.peakBlock)
        for b in 0..<p.count {
            var m: Float = 0
            for i in (b * Self.peakBlock)..<min((b + 1) * Self.peakBlock, n) { m = max(m, abs(l[i]), abs(r[i])) }
            p[b] = min(m, 1)
        }
        peaks = p
        func summary(_ block: Int) -> ([Float], [Float]) {
            let c = (n + block - 1) / block
            var lo = [Float](repeating: 0, count: c), hi = lo
            for b in 0..<c {
                var a: Float = 1, z: Float = -1
                for i in (b * block)..<min((b + 1) * block, n) { let x = (l[i] + r[i]) * 0.5; a = min(a, x); z = max(z, x) }
                lo[b] = a; hi[b] = z
            }
            return (lo, hi)
        }
        (lo32, hi32) = summary(32)
        (lo1k, hi1k) = summary(1024)
    }
    deinit { left.deallocate(); right.deallocate() }

    /// Lowest and highest (L+R)/2 sample from frame `a` to `b` (for drawing), from the summaries when it's long.
    public func minMax(_ a: Int, _ b: Int) -> (Float, Float) {
        let a = max(a, 0), b = min(max(b, a + 1), frames)
        guard a < b else { return (0, 0) }
        var lo: Float = 1, hi: Float = -1
        if b - a >= 4096 {
            for k in (a / 1024)...min((b - 1) / 1024, lo1k.count - 1) { lo = min(lo, lo1k[k]); hi = max(hi, hi1k[k]) }
        } else if b - a >= 128 {
            for k in (a / 32)...min((b - 1) / 32, lo32.count - 1) { lo = min(lo, lo32[k]); hi = max(hi, hi32[k]) }
        } else {
            for i in a..<b { let x = (left[i] + right[i]) * 0.5; lo = min(lo, x); hi = max(hi, x) }
        }
        return (lo, hi)
    }

    /// Peak over a range of frames (for drawing).
    public func peak(from a: Int, to b: Int) -> Float {
        let lo = max(a / Self.peakBlock, 0), hi = min(max(b / Self.peakBlock, lo), peaks.count - 1)
        guard lo <= hi else { return 0 }
        var m: Float = 0
        for k in lo...hi { m = max(m, peaks[k]) }
        return m
    }
}

/// Every audio file arrange boxes use, loaded once (in the background) and shared.
public final class ArrangeAudio: @unchecked Sendable {
    public static let shared = ArrangeAudio()
    private var loaded: [String: ClipAudio] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private let queue = DispatchQueue(label: "poljenieuk.arrange.load", qos: .userInitiated)
    private var nodes: [Weak] = []
    private struct Weak { weak var node: ArrangeNode? }
    /// Bumped (main thread) whenever a file finishes loading — displays redraw.
    public private(set) var generation = 0

    /// Main thread: the audio, or nil while it loads (it starts loading) / when it can't be read.
    public func audio(_ path: String) -> ClipAudio? {
        let p = Self.resolve(path)
        if let a = loaded[p] { return a }
        guard !loading.contains(p), !failed.contains(p) else { return nil }
        loading.insert(p)
        queue.async { [weak self] in
            let a = Self.read(URL(fileURLWithPath: p))
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(p)
                if let a { self.loaded[p] = a } else { self.failed.insert(p) }
                self.generation += 1
                self.nodes.removeAll { $0.node == nil }
                for n in self.nodes { n.node?.rebuild() }
            }
        }
        return nil
    }
    public func isMissing(_ path: String) -> Bool { failed.contains(Self.resolve(path)) }
    func register(_ n: ArrangeNode) { if !nodes.contains(where: { $0.node === n }) { nodes.append(Weak(node: n)) } }

    /// A path from another computer: the same name in this one's recordings folder.
    public static func resolve(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        let name = (path as NSString).lastPathComponent
        for dir in [Recordings.directory, Recordings.directory.appendingPathComponent("Takes"),
                    Recordings.directory.appendingPathComponent("Imported")] {
            let p = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return path
    }

    static func read(_ url: URL) -> ClipAudio? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        let chans = Int(file.fileFormat.channelCount)
        let total = Int(min(file.length, Int64(rate * 60 * 30)))          // up to half an hour
        guard total > 0, let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                 channels: AVAudioChannelCount(chans), interleaved: false) else { return nil }
        var l = [Float](), r = [Float]()
        l.reserveCapacity(total); r.reserveCapacity(total)
        let chunk: AVAudioFrameCount = 65536
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        while l.count < total {
            pcm.frameLength = 0
            do { try file.read(into: pcm, frameCount: min(chunk, AVAudioFrameCount(total - l.count))) } catch { break }
            let n = Int(pcm.frameLength)
            guard n > 0, let ch = pcm.floatChannelData else { break }
            l.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            r.append(contentsOf: UnsafeBufferPointer(start: ch[chans > 1 ? 1 : 0], count: n))
        }
        return l.isEmpty ? nil : ClipAudio(left: l, right: r, rate: rate)
    }
}

/// What the audio thread plays: built on the main thread, swapped in without locking.
final class ArrangeSnapshot {
    struct Clip {
        var track: Int
        var start: Double, end: Double
        var offsetFrames: Double
        var gain: Float
        var fadeIn: Double, fadeOut: Double       // beats, crossfades included
        var left: UnsafePointer<Float>, right: UnsafePointer<Float>
        var frames: Int
        var ratio: Double                          // file frames per engine sample
    }
    let clips: [Clip]
    let audio: [ClipAudio]                         // keeps the memory alive
    let loopStart: Double, loopEnd: Double
    init(clips: [Clip], audio: [ClipAudio], loopStart: Double, loopEnd: Double) {
        self.clips = clips; self.audio = audio; self.loopStart = loopStart; self.loopEnd = loopEnd
    }
}

/// One finished take of an arrangement recording.
public struct ArrangeTake: Sendable {
    public let track: Int
    public let url: URL
    public let start: Double      // beats
    public let length: Double     // beats
}

public final class ArrangeNode: DSPNode {
    // main thread
    public private(set) var clips: [ArrangeClip] = []
    public private(set) var files: [String] = []
    public private(set) var trackData = ArrangeLayout.defaultTracks
    public private(set) var loopRange: (Double, Double) = (0, 16)
    /// Main thread: called with the takes when an arrangement recording ends (the app adds them as clips).
    @MainActor public static var onTakes: ((ArrangeNode, [ArrangeTake]) -> Void)?

    private let slot = Mutex<Unmanaged<ArrangeSnapshot>?>(nil)
    private var live: ArrangeSnapshot?
    private var retired: [(ArrangeSnapshot, Date)] = []
    private var rt: Unmanaged<ArrangeSnapshot>?                   // audio thread
    // track mix, read by the audio thread (written on the main thread, one float at a time)
    private let mix: UnsafeMutablePointer<Float>
    private let busL: UnsafeMutablePointer<Float>, busR: UnsafeMutablePointer<Float>
    private let meters: UnsafeMutablePointer<Float>
    /// UI: each track's level (peak with a fall).
    public var levels: UnsafePointer<Float> { UnsafePointer(meters) }

    // recording: one ring per track, written on the audio thread, drained to files in the background
    private let capFrames: Int
    /// one per track, made (on the main thread) the first time the track is armed
    private let rings: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private final class Counter: @unchecked Sendable { let v = Atomic<Int>(0) }
    private let writePos: [Counter]
    private let readPos: [Counter]
    private let startPos: [Counter]               // where in the ring the current take starts
    private let takeArmed = Atomic<UInt32>(0)       // tracks in the take
    private let takeSession = Atomic<Int>(0)
    private let takeActive = Atomic<Bool>(false)
    private let takeStart = Atomic<UInt64>(0)       // beats (Double bits)
    private let takeLength = Atomic<UInt64>(0)      // beats recorded
    private var recFrom: Double = 0, recTo: Double = 0
    private var recState = 0                        // 0 idle, 1 waiting for the bar, 2 recording
    private var recArmed: UInt32 = 0
    private let queue = DispatchQueue(label: "poljenieuk.arrange.rec", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var writers: [Int: AVAudioFile] = [:]
    private var writerSession = 0
    private var writerURLs: [Int: URL] = [:]
    private var writerFrames: [Int: Int] = [:]
    private var scratch: AVAudioPCMBuffer?

    public override init(spec: ModuleSpec, sampleRate: Double) {
        mix = .allocate(capacity: ArrangeLayout.tracks * ArrangeLayout.trackFields)
        mix.initialize(from: ArrangeLayout.defaultTracks, count: ArrangeLayout.tracks * ArrangeLayout.trackFields)
        busL = .allocate(capacity: kMaxBlock); busL.initialize(repeating: 0, count: kMaxBlock)
        busR = .allocate(capacity: kMaxBlock); busR.initialize(repeating: 0, count: kMaxBlock)
        meters = .allocate(capacity: ArrangeLayout.tracks + 1); meters.initialize(repeating: 0, count: ArrangeLayout.tracks + 1)
        capFrames = Int(sampleRate * 6)
        rings = .allocate(capacity: ArrangeLayout.tracks)
        rings.initialize(repeating: nil, count: ArrangeLayout.tracks)
        writePos = (0..<ArrangeLayout.tracks).map { _ in Counter() }
        readPos = (0..<ArrangeLayout.tracks).map { _ in Counter() }
        startPos = (0..<ArrangeLayout.tracks).map { _ in Counter() }
        super.init(spec: spec, sampleRate: sampleRate)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }
    deinit {
        timer?.cancel()
        mix.deallocate(); busL.deallocate(); busR.deallocate(); meters.deallocate()
        for t in 0..<ArrangeLayout.tracks { rings[t]?.deallocate() }
        rings.deallocate()
        if let u = slot.withLock({ $0 }) { u.release() }
    }

    public override var defaultData: [String: [Float]] {
        [ArrangeLayout.clipsKey: [], ArrangeLayout.filesKey: [], ArrangeLayout.tracksKey: ArrangeLayout.defaultTracks,
         ArrangeLayout.loopKey: [0, 16]]
    }
    public override func setData(_ key: String, _ values: [Float]) {
        switch key {
        case ArrangeLayout.clipsKey: clips = ArrangeClip.decode(values)
        case ArrangeLayout.filesKey: files = ArrangeClip.decodeFiles(values)
        case ArrangeLayout.tracksKey:
            var t = ArrangeLayout.defaultTracks
            for i in 0..<min(values.count, t.count) where values[i].isFinite { t[i] = values[i] }
            trackData = t
            for k in 0..<ArrangeLayout.tracks where t[k * ArrangeLayout.trackFields + 4] > 0.5 && rings[k] == nil {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: capFrames * 2)
                p.initialize(repeating: 0, count: capFrames * 2)
                rings[k] = p
            }
            for i in 0..<t.count { mix[i] = t[i] }
            return
        case ArrangeLayout.loopKey:
            if values.count >= 2, values[0].isFinite, values[1].isFinite, values[1] > values[0] {
                loopRange = (Double(values[0]), Double(values[1]))
            }
        default: return
        }
        ArrangeAudio.shared.register(self)
        rebuild()
    }

    /// Main thread: the file a clip plays (nil while it loads).
    public func audio(for c: ArrangeClip) -> ClipAudio? {
        c.file < files.count ? ArrangeAudio.shared.audio(files[c.file]) : nil
    }

    /// Main thread: hand the audio thread what to play.
    func rebuild() {
        var rtClips: [ArrangeSnapshot.Clip] = []
        var keep: [ClipAudio] = []
        let (fadeIn, fadeOut) = Self.fades(clips)
        for (i, c) in clips.enumerated() {
            guard let a = audio(for: c) else { continue }
            keep.append(a)
            rtClips.append(.init(track: c.track, start: c.start, end: c.end, offsetFrames: c.offset * a.rate,
                                 gain: c.gain, fadeIn: min(fadeIn[i], c.length), fadeOut: min(fadeOut[i], c.length),
                                 left: UnsafePointer(a.left), right: UnsafePointer(a.right), frames: a.frames,
                                 ratio: a.rate / sampleRate * c.speed))
        }
        let snap = ArrangeSnapshot(clips: rtClips, audio: keep, loopStart: loopRange.0, loopEnd: loopRange.1)
        let u = Unmanaged.passRetained(snap)
        let old = slot.withLock { s -> Unmanaged<ArrangeSnapshot>? in let o = s; s = u; return o }
        old?.release()
        if let l = live { retired.append((l, Date())) }
        live = snap
        retired.removeAll { Date().timeIntervalSince($0.1) > 2 }
    }

    /// The mix of many loud tracks: untouched up to ±2 (+6 dB over full scale), then eased towards ±4.
    @inline(__always) static func soft(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 2 else { return x }
        return (x < 0 ? -1 : 1) * (2 + 2 * tanhf((a - 2) / 2))
    }

    /// Fades with the crossfades: where a clip starts inside the one before it on its track, both fade over the overlap.
    static func fades(_ clips: [ArrangeClip]) -> ([Double], [Double]) {
        var fadeIn = clips.map(\.fadeIn), fadeOut = clips.map(\.fadeOut)
        for t in 0..<ArrangeLayout.tracks {
            let idx = clips.indices.filter { clips[$0].track == t }.sorted { clips[$0].start < clips[$1].start }
            for (k, a) in idx.enumerated() {
                for b in idx[(k + 1)...] where clips[b].start < clips[a].end {
                    let overlap = min(clips[a].end - clips[b].start, clips[b].length, clips[a].length)
                    fadeOut[a] = max(fadeOut[a], overlap)
                    fadeIn[b] = max(fadeIn[b], overlap)
                }
            }
        }
        return (fadeIn, fadeOut)
    }

    /// Main thread: the clips from beat `a` to `b`, rendered offline at `rate` with `secondsPerBeat` — the mix
    /// (track volume, pan, mute, solo, level) and each track that has clips there on its own (volume and pan,
    /// for stems). Files still loading are read here.
    public func render(from a: Double, to b: Double, rate: Double, secondsPerBeat: Double) -> (mix: StereoAudio, tracks: [Int: StereoAudio]) {
        let frames = max(Int((b - a) * secondsPerBeat * rate), 0)
        guard frames > 0 else { return (StereoAudio(), [:]) }
        let count = ArrangeLayout.count(base[ArrangeLayout.trackCount])
        let (fin, fout) = Self.fades(clips)
        var stems: [Int: StereoAudio] = [:]
        var mixL = [Float](repeating: 0, count: frames), mixR = mixL
        var anySolo = false
        for t in 0..<count where trackData[t * ArrangeLayout.trackFields + 3] > 0.5 { anySolo = true }
        let beatsPerFrame = 1 / (secondsPerBeat * rate)
        for t in 0..<count {
            let mine = clips.indices.filter { clips[$0].track == t && clips[$0].end > a && clips[$0].start < b }
            guard !mine.isEmpty else { continue }
            var l = [Float](repeating: 0, count: frames), r = l
            for i in mine {
                let c = clips[i]
                guard c.file < files.count else { continue }
                let path = ArrangeAudio.resolve(files[c.file])
                guard let au = ArrangeAudio.shared.audio(path) ?? ArrangeAudio.read(URL(fileURLWithPath: path)) else { continue }
                let first = max(Int((c.start - a) / beatsPerFrame), 0), last = min(Int((c.end - a) / beatsPerFrame) + 1, frames)
                guard first < last else { continue }
                for k in first..<last {
                    let p = a + Double(k) * beatsPerFrame
                    guard p >= c.start && p < c.end else { continue }
                    let pos = (c.offset + (p - c.start) * secondsPerBeat * c.speed) * au.rate
                    let j = Int(pos)
                    guard j >= 0 && j + 1 < au.frames else { continue }
                    let f = Float(pos - Double(j))
                    var g = c.gain
                    if fin[i] > 0 && p - c.start < fin[i] { g *= sinf(Float((p - c.start) / fin[i]) * .pi / 2) }
                    if fout[i] > 0 && c.end - p < fout[i] { g *= sinf(Float((c.end - p) / fout[i]) * .pi / 2) }
                    l[k] += (au.left[j] + (au.left[j + 1] - au.left[j]) * f) * g
                    r[k] += (au.right[j] + (au.right[j + 1] - au.right[j]) * f) * g
                }
            }
            let fi = t * ArrangeLayout.trackFields
            let vol = min(max(trackData[fi], 0), 2), pan = min(max(trackData[fi + 1], -1), 1)
            let gl = min(vol * cosf((pan + 1) * .pi / 4) * 1.41421356, vol), gr = min(vol * sinf((pan + 1) * .pi / 4) * 1.41421356, vol)
            for k in 0..<frames { l[k] *= gl; r[k] *= gr }
            stems[t] = StereoAudio(left: l, right: r)
            let audible = trackData[fi + 2] < 0.5 && (!anySolo || trackData[fi + 3] > 0.5)
            if audible { for k in 0..<frames { mixL[k] += l[k]; mixR[k] += r[k] } }
        }
        let master = powf(10, base[ArrangeLayout.level] / 20)
        for k in 0..<frames { mixL[k] = Self.soft(mixL[k] * master); mixR[k] = Self.soft(mixR[k] * master) }
        return (StereoAudio(left: mixL, right: mixR), stems)
    }

    /// Where the timeline is for a transport beat (the loop wraps it).
    /// Looping, the transport's start is the loop's start (■ then ▶ plays the loop from its beginning).
    @inline(__always) static func position(_ beat: Double, loop: Bool, _ a: Double, _ b: Double) -> Double {
        guard loop, b > a else { return beat }
        let len = b - a
        let t = max(beat, 0).truncatingRemainder(dividingBy: len)
        return a + t
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        if let u = slot.withLockIfAvailable({ $0 }) { rt = u }
        let snap = rt?.takeUnretainedValue()
        let master = powf(10, params[ArrangeLayout.level] / 20)
        let looping = params[ArrangeLayout.loop] > 0.5
        let la = snap?.loopStart ?? 0, lb = snap?.loopEnd ?? 0
        let spb = ctx.samplesPerBeat
        let oL = outputs[0], oR = outputs[1]
        oL.update(repeating: 0, count: frames); oR.update(repeating: 0, count: frames)
        let count = ArrangeLayout.count(params[ArrangeLayout.trackCount])
        var anySolo = false
        for t in 0..<count where mix[t * ArrangeLayout.trackFields + 3] > 0.5 { anySolo = true }

        for t in 0..<count {
            let f = t * ArrangeLayout.trackFields
            let vol = min(max(mix[f], 0), 2), pan = min(max(mix[f + 1], -1), 1)
            let audible = mix[f + 2] < 0.5 && (!anySolo || mix[f + 3] > 0.5)
            // the inlets are heard through the track
            let hasL = isConnected(connected, 2 * t), hasR = isConnected(connected, 2 * t + 1)
            if hasL || hasR {
                let iL = hasL ? inputs[2 * t] : inputs[2 * t + 1], iR = hasR ? inputs[2 * t + 1] : iL
                busL.update(from: iL, count: frames); busR.update(from: iR, count: frames)
            } else {
                busL.update(repeating: 0, count: frames); busR.update(repeating: 0, count: frames)
            }
            if let snap, ctx.running {
                let b0 = Self.position(ctx.beat[0], loop: looping, la, lb)
                let b1 = Self.position(ctx.beat[frames - 1], loop: looping, la, lb)
                let lo = min(b0, b1), hi = max(b0, b1)
                let wrapped = b1 < b0
                for c in snap.clips where c.track == t && (wrapped || (c.end > lo && c.start <= hi)) {
                    for i in 0..<frames {
                        let p = Self.position(ctx.beat[i], loop: looping, la, lb)
                        guard p >= c.start && p < c.end else { continue }
                        let pos = c.offsetFrames + (p - c.start) * spb * c.ratio
                        let k = Int(pos)
                        guard k >= 0 && k + 1 < c.frames else { continue }
                        let fr = Float(pos - Double(k))
                        var g = c.gain
                        if c.fadeIn > 0 && p - c.start < c.fadeIn { g *= sinf(Float((p - c.start) / c.fadeIn) * .pi / 2) }
                        if c.fadeOut > 0 && c.end - p < c.fadeOut { g *= sinf(Float((c.end - p) / c.fadeOut) * .pi / 2) }
                        busL[i] += (c.left[k] + (c.left[k + 1] - c.left[k]) * fr) * g
                        busR[i] += (c.right[k] + (c.right[k + 1] - c.right[k]) * fr) * g
                    }
                }
            }
            // volume, equal-power pan, mute / solo → the track's outlets and the mix
            let gl = audible ? vol * cosf((pan + 1) * .pi / 4) * 1.41421356 : 0
            let gr = audible ? vol * sinf((pan + 1) * .pi / 4) * 1.41421356 : 0
            let tL = outputs[ArrangeLayout.firstTrackOutlet + 2 * t], tR = outputs[ArrangeLayout.firstTrackOutlet + 1 + 2 * t]
            var pk: Float = 0
            for i in 0..<frames {
                let l = busL[i] * min(gl, vol), r = busR[i] * min(gr, vol)
                tL[i] = l; tR[i] = r
                oL[i] += l; oR[i] += r
                pk = max(pk, abs(l), abs(r))
            }
            meters[t] = max(pk, meters[t] * 0.94)
        }
        for t in count..<ArrangeLayout.tracks { meters[t] = 0 }
        var mpk: Float = 0
        for i in 0..<frames {
            oL[i] = Self.soft(oL[i] * master); oR[i] = Self.soft(oR[i] * master)
            mpk = max(mpk, abs(oL[i]), abs(oR[i]))
        }
        meters[ArrangeLayout.tracks] = max(mpk, meters[ArrangeLayout.tracks] * 0.94)
        readouts[ArrangeLayout.mixSlot] = meters[ArrangeLayout.tracks]
        readouts[ArrangeLayout.posSlot] = Float(Self.position(ctx.beat[frames - 1], loop: looping, la, lb))
        readouts[ArrangeLayout.secondsPerBeatSlot] = Float(spb / sampleRate)

        record(frames: frames, inputs: inputs, connected: connected, ctx: ctx, looping: looping, la: la, lb: lb)
    }

    // MARK: arrangement recording

    private func record(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext,
                        looping: Bool, la: Double, lb: Double) {
        let want = params[ArrangeLayout.rec] > 0.5
        var armed: UInt32 = 0
        for t in 0..<ArrangeLayout.count(params[ArrangeLayout.trackCount]) where mix[t * ArrangeLayout.trackFields + 4] > 0.5 { armed |= 1 << UInt32(t) }
        if recState == 2 && (!want || !ctx.running) {
            // the take ends: the writer closes the files and hands them over
            takeLength.store(max(recTo - recFrom, 0).bitPattern, ordering: .relaxed)
            takeActive.store(false, ordering: .sequentiallyConsistent)
            recState = 0
        }
        if !want { recState = 0 }
        if want && recState == 0 && armed != 0 { recState = 1 }
        var startAt = -1
        if recState == 1 && ctx.running {
            // start on the next bar (or straight away when the transport has just started)
            if ctx.beat[0] < 0.02 { startAt = 0 }
            else {
                for i in 0..<frames where i > 0 && floor(ctx.beat[i] / 4) != floor(ctx.beat[i - 1] / 4) { startAt = i; break }
            }
            if startAt >= 0 {
                recArmed = armed
                for t in 0..<ArrangeLayout.tracks { startPos[t].v.store(writePos[t].v.load(ordering: .relaxed), ordering: .relaxed) }
                takeArmed.store(armed, ordering: .relaxed)
                takeStart.store(Self.position(ctx.beat[startAt], loop: looping, la, lb).bitPattern, ordering: .relaxed)
                takeSession.wrappingAdd(1, ordering: .sequentiallyConsistent)
                takeActive.store(true, ordering: .sequentiallyConsistent)
                readouts[ArrangeLayout.recStartSlot] = Float(Self.position(ctx.beat[startAt], loop: looping, la, lb))
                recFrom = ctx.beat[startAt]; recTo = recFrom
                recState = 2
            }
        }
        if recState == 2 {
            let from = max(startAt, 0)
            recTo = ctx.beat[frames - 1]
            for t in 0..<ArrangeLayout.tracks where recArmed & (1 << UInt32(t)) != 0 {
                guard let ring = rings[t] else { continue }
                let hasL = isConnected(connected, 2 * t), hasR = isConnected(connected, 2 * t + 1)
                let iL = hasL ? inputs[2 * t] : (hasR ? inputs[2 * t + 1] : nil)
                let iR = hasR ? inputs[2 * t + 1] : iL
                let w = writePos[t].v.load(ordering: .relaxed), r = readPos[t].v.load(ordering: .acquiring)
                let n = min(frames - from, capFrames - (w - r))
                for i in 0..<max(n, 0) {
                    let idx = ((w + i) % capFrames) * 2
                    ring[idx] = iL?[from + i] ?? 0
                    ring[idx + 1] = iR?[from + i] ?? 0
                }
                writePos[t].v.store(w + max(n, 0), ordering: .releasing)
            }
        }
        readouts[ArrangeLayout.recSlot] = recState == 2 ? 1 : (recState == 1 ? 0.5 : 0)
    }

    /// Background: write what the tracks recorded; when a take ends, close its files and pass them on.
    private func drain() {
        let s = takeSession.load(ordering: .sequentiallyConsistent)
        let active = takeActive.load(ordering: .sequentiallyConsistent)
        if s != writerSession {                 // a new take (even one that's already over: write it all)
            finish()
            writerSession = s
            let armed = takeArmed.load(ordering: .relaxed)
            let dir = Recordings.directory.appendingPathComponent("Takes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = f.string(from: Date())
            for t in 0..<ArrangeLayout.tracks where armed & (1 << UInt32(t)) != 0 {
                readPos[t].v.store(startPos[t].v.load(ordering: .acquiring), ordering: .releasing)
                let url = dir.appendingPathComponent("take \(stamp) track \(t + 1).wav")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                               AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                               AVLinearPCMIsNonInterleaved: false]
                if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                    writers[t] = file; writerURLs[t] = url; writerFrames[t] = 0
                }
            }
        }
        for (t, file) in writers {
            let w = writePos[t].v.load(ordering: .acquiring)
            var pos = readPos[t].v.load(ordering: .relaxed)
            guard w > pos else { continue }
            if scratch == nil { scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) }
            guard let buf = scratch, let ch = buf.floatChannelData, let ring = rings[t] else { continue }
            while pos < w {
                let n = min(4096, w - pos)
                for i in 0..<n {
                    let idx = ((pos + i) % capFrames) * 2
                    ch[0][i] = ring[idx]; ch[1][i] = ring[idx + 1]
                }
                buf.frameLength = AVAudioFrameCount(n)
                try? file.write(from: buf)
                pos += n
                writerFrames[t, default: 0] += n
            }
            readPos[t].v.store(w, ordering: .releasing)
        }
        if !active && !writers.isEmpty { finish() }
    }

    private func finish() {
        guard !writers.isEmpty else { return }
        let start = Double(bitPattern: takeStart.load(ordering: .relaxed))
        let length = Double(bitPattern: takeLength.load(ordering: .relaxed))
        var takes: [ArrangeTake] = []
        for t in writers.keys {
            let frames = Double(writerFrames[t] ?? 0)
            if frames > 0, let url = writerURLs[t] {
                // the length in beats follows the frames written (the tempo of the take)
                let beats = length > 0 ? length : frames / max(sampleRate * 0.5, 1)
                takes.append(ArrangeTake(track: t, url: url, start: start, length: beats))
            }
        }
        writers.removeAll(); writerURLs.removeAll(); writerFrames.removeAll(); scratch = nil      // the files close here
        takes.sort { $0.track < $1.track }
        guard !takes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.onTakes?(self, takes)
            }
        }
    }
}
