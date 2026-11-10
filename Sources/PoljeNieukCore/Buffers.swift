import Foundation
import Synchronization
import AVFoundation

/// Readout slots 16…23 carry playhead positions (0…1 of the buffer, -1 = none) for waveform views.
public let kPlayheadSlot = 16
/// Readout slot with the length of one beat in samples (for the waveform grid).
public let kBeatSamplesSlot = 6

/// Stereo audio passed between the UI and buffer modules (main thread only).
public struct StereoAudio: Sendable {
    public var left: [Float]
    public var right: [Float]
    public init(left: [Float] = [], right: [Float]? = nil) {
        self.left = left
        self.right = right ?? left
    }
    public var count: Int { min(left.count, right.count) }
    public var isEmpty: Bool { count == 0 }
    public func prefix(_ n: Int) -> StereoAudio { StereoAudio(left: Array(left.prefix(n)), right: Array(right.prefix(n))) }
    public var mono: [Float] { (0..<count).map { (left[$0] + right[$0]) * 0.5 } }
    func copy(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        left.withUnsafeBufferPointer { l.update(from: $0.baseAddress!, count: n) }
        right.withUnsafeBufferPointer { r.update(from: $0.baseAddress!, count: n) }
    }
}

/// Modules that hold audio in a buffer the UI can draw, load into, and copy from.
public protocol SampleBufferNode: AnyObject {
    var waveBuffer: UnsafeMutablePointer<Float> { get }
    var waveBufferR: UnsafeMutablePointer<Float> { get }
    /// Samples currently valid (grows while recording).
    var waveLength: Int { get }
    /// Bumped whenever the content changes, so views/analysis/persistence know to refresh.
    var contentVersion: Int { get }
    var waveRecording: Bool { get }
    var bufferCapacity: Int { get }
    /// Main thread. Copy of the current audio.
    func snapshot() -> StereoAudio
    /// Main thread. Replaces the buffer (audio at the engine's sample rate).
    func load(_ audio: StereoAudio)
    /// Slice markers to draw (sample positions). Default: none.
    var markerCount: Int { get }
    func marker(_ i: Int) -> Int
}

public extension SampleBufferNode {
    var markerCount: Int { 0 }
    func marker(_ i: Int) -> Int { 0 }
}

/// Lets the main thread swap a buffer's contents while the audio thread is running:
/// the audio thread goes silent for that node while `busy`, and the main thread waits
/// long enough for any block in flight to finish before touching the memory.
public final class LoadGuard: @unchecked Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public var busy: Bool { flag.load(ordering: .acquiring) }
    public func whileBusy(_ body: () -> Void) {
        flag.store(true, ordering: .sequentiallyConsistent)
        usleep(30_000)          // > any audio callback (≤ 8192 frames would be 170 ms, but we run 64–512)
        body()
        flag.store(false, ordering: .sequentiallyConsistent)
    }
}

public enum AudioFiles {
    /// Reads any audio file as stereo floats at `sampleRate` (mono files are duplicated), at most `maxSeconds`.
    public static func read(_ url: URL, sampleRate: Double, maxSeconds: Double = 60) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate,
                                channels: file.fileFormat.channelCount, interleaved: false)!
        let frames = AVAudioFrameCount(min(Double(file.length), maxSeconds * file.fileFormat.sampleRate))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return StereoAudio() }
        try file.read(into: pcm, frameCount: frames)
        guard let ch = pcm.floatChannelData else { return StereoAudio() }
        let n = Int(pcm.frameLength), chans = Int(fmt.channelCount)
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = chans > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return StereoAudio(left: resample(l, from: fmt.sampleRate, to: sampleRate),
                           right: resample(r, from: fmt.sampleRate, to: sampleRate))
    }

    public static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard abs(from - to) > 0.5, !x.isEmpty else { return x }
        let ratio = from / to
        let n = Int(Double(x.count) / ratio)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * ratio
            let k = Int(p), f = Float(p - Double(k))
            let a = x[min(k, x.count - 1)], b = x[min(k + 1, x.count - 1)]
            y[i] = a + (b - a) * f
        }
        return y
    }

    /// Writes stereo float audio (32-bit float, WAV or CAF by extension).
    public static func write(_ audio: StereoAudio, sampleRate: Double, to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = audio.count
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        pcm.frameLength = AVAudioFrameCount(n)
        audio.copy(into: pcm.floatChannelData![0], pcm.floatChannelData![1], count: n)
        try file.write(from: pcm)
    }

    /// Audio file extensions the browser shows.
    public static let extensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac"]
}
