import Foundation
import AVFoundation
import Synchronization

/// rec : records its two inlets to a 32-bit float stereo WAV file.
/// The audio thread only copies into a lock-free ring; a background queue writes the file.
final class RecorderNode: DSPNode {
    public static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("polje nieuk Recordings", isDirectory: true)
        // carry recordings over from the folder's old name
        let old = docs.appendingPathComponent("Patchwork Recordings", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.moveItem(at: old, to: dir)
            } else if let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                for f in items { try? fm.moveItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent)) }
                try? fm.removeItem(at: old)
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let capFrames: Int
    private let ring: UnsafeMutablePointer<Float>   // interleaved L/R
    private let writePos = Atomic<Int>(0)
    private let readPos = Atomic<Int>(0)
    private let session = Atomic<Int>(0)
    private let recording = Atomic<Bool>(false)
    private var wasOn = false
    private var recFrames = 0

    private let queue = DispatchQueue(label: "poljenieuk.recorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var fileSession = 0
    private var scratch: AVAudioPCMBuffer?

    override init(spec: ModuleSpec, sampleRate: Double) {
        capFrames = Int(sampleRate * 8)
        ring = .allocate(capacity: capFrames * 2)
        ring.initialize(repeating: 0, count: capFrames * 2)
        super.init(spec: spec, sampleRate: sampleRate)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    deinit {
        timer?.cancel()
        ring.deallocate()
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let on = params[0] > 0.5
        if on && !wasOn {
            session.wrappingAdd(1, ordering: .sequentiallyConsistent)
            recFrames = 0
        }
        wasOn = on
        recording.store(on, ordering: .releasing)
        if on {
            let w = writePos.load(ordering: .relaxed)
            let r = readPos.load(ordering: .acquiring)
            let n = min(frames, capFrames - (w - r))
            let L = inputs[0]
            let R = isConnected(connected, 1) ? inputs[1] : inputs[0]
            for i in 0..<max(n, 0) {
                let idx = ((w + i) % capFrames) * 2
                ring[idx] = L[i]
                ring[idx + 1] = R[i]
            }
            writePos.store(w + max(n, 0), ordering: .releasing)
            recFrames += frames
        }
        readouts[0] = Float(Double(recFrames) / sampleRate)
        readouts[1] = on ? 1 : 0
    }

    private func drain() {
        let w = writePos.load(ordering: .acquiring)
        let s = session.load(ordering: .sequentiallyConsistent)
        if s != fileSession {
            file = nil
            fileSession = s
            file = openFile()
        }
        let r = readPos.load(ordering: .relaxed)
        var pos = r
        if let file, w > r {
            let chunk = 4096
            if scratch == nil {
                scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))
            }
            if let buf = scratch, let ch = buf.floatChannelData {
                while pos < w {
                    let n = min(chunk, w - pos)
                    for i in 0..<n {
                        let idx = ((pos + i) % capFrames) * 2
                        ch[0][i] = ring[idx]
                        ch[1][i] = ring[idx + 1]
                    }
                    buf.frameLength = AVAudioFrameCount(n)
                    try? file.write(from: buf)
                    pos += n
                }
            }
        }
        readPos.store(w, ordering: .releasing)
        if !recording.load(ordering: .acquiring) && file != nil && writePos.load(ordering: .acquiring) == w {
            file = nil   // closes and finalises the WAV header
        }
    }

    private func openFile() -> AVAudioFile? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.directory.appendingPathComponent("polje nieuk \(f.string(from: Date())).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        scratch = nil
        return try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

public enum Recordings {
    public static var directory: URL { RecorderNode.directory }
}
