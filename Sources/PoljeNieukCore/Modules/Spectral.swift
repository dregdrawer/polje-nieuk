import Foundation
import Accelerate

/// stretch~ : Paulstretch-style extreme time stretching.
/// Records (or loads) a buffer, then walks through it very slowly: every hop it takes a windowed
/// FFT frame, keeps the magnitudes, throws away the phases (random ones instead), and overlap-adds
/// the result. Left and right get different random phases, so the drone comes out wide.
final class PaulStretchNode: DSPNode, SampleBufferNode {
    // triggers: 0 rec, 1 stop, 2 clear
    // 3 stretch, 4 window, 5 start, 6 end, 7 freeze, 8 level, 9 monitor
    // inputs: 0 L, 1 R, 2 rec (gate), 3 freeze (gate)
    static let sizes = [2048, 4096, 8192, 16384]
    static let maxLog2n: vDSP_Length = 14

    private let cap: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var length = 0
    private var recording = false
    private var recLen = 0
    let loadGuard = LoadGuard()
    public private(set) var contentVersion = 0

    private let fft: FFTSetup
    private let maxN = 16384
    private var n = 0
    private var hop = 0
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>
    private let mag: UnsafeMutablePointer<Float>
    private let phase: UnsafeMutablePointer<Float>
    private let accL: UnsafeMutablePointer<Float>, accR: UnsafeMutablePointer<Float>
    private var outPos = 0
    private var readPos: Double = 0
    private var rng = XorShift(seed: 0x57E7_C401)
    private var recGate = EdgeDetector()

    override init(spec: ModuleSpec, sampleRate: Double) {
        cap = Int(sampleRate * 60)
        bufL = .allocate(capacity: cap); bufL.initialize(repeating: 0, count: cap)
        bufR = .allocate(capacity: cap); bufR.initialize(repeating: 0, count: cap)
        fft = vDSP_create_fftsetup(Self.maxLog2n, FFTRadix(kFFTRadix2))!
        func alloc(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        window = alloc(maxN); frame = alloc(maxN)
        re = alloc(maxN / 2); im = alloc(maxN / 2); mag = alloc(maxN / 2); phase = alloc(maxN / 2)
        accL = alloc(maxN); accR = alloc(maxN)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        [bufL, bufR, window, frame, re, im, mag, phase, accL, accR].forEach { $0.deallocate() }
    }

    private func configure(size: Int) {
        n = size
        hop = size / 4
        for i in 0..<n { window[i] = 0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(n)) }
        accL.update(repeating: 0, count: maxN)
        accR.update(repeating: 0, count: maxN)
        outPos = hop   // compute a frame on the next sample
    }

    /// One output frame with fresh random phases, overlap-added into `acc`.
    private func synthesize(into acc: UnsafeMutablePointer<Float>, half: Int, log2n: vDSP_Length) {
        for k in 0..<half { phase[k] = rng.next() * 2 * .pi }
        var count = Int32(half)
        vvsincosf(im, re, phase, &count)                // im = sin, re = cos
        vDSP_vmul(re, 1, mag, 1, re, 1, vDSP_Length(half))
        vDSP_vmul(im, 1, mag, 1, im, 1, vDSP_Length(half))
        re[0] = 0; im[0] = 0                            // no DC / Nyquist
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
        // scale: zrip forward×inverse = 2N; Hann² at 75 % overlap sums to 1.5
        var scale = 1 / (Float(2 * n) * 1.5)
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(n))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))
        vDSP_vadd(acc, 1, frame, 1, acc, 1, vDSP_Length(n))
    }

    private func nextFrame(lo: Int, hi: Int, stretch: Double, frozen: Bool) {
        // shift accumulators by one hop
        accL.update(from: accL + hop, count: n - hop); (accL + n - hop).update(repeating: 0, count: hop)
        accR.update(from: accR + hop, count: n - hop); (accR + n - hop).update(repeating: 0, count: hop)
        let span = hi - lo
        guard span > 64 else { return }
        // analysis frame from the buffer (wrapping inside the selected region), one per channel
        var p = Int(readPos)
        if p < lo || p >= hi { p = lo; readPos = Double(lo) }
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        for ch in 0..<2 {
            let src = ch == 0 ? bufL : bufR
            for i in 0..<n {
                var idx = p + i
                while idx >= hi { idx -= span }
                frame[i] = src[idx] * window[i]
            }
            var split = DSPSplitComplex(realp: re, imagp: im)
            frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            vDSP_zvabs(&split, 1, mag, 1, vDSP_Length(half))
            synthesize(into: ch == 0 ? accL : accR, half: half, log2n: log2n)
        }
        if !frozen {
            readPos += Double(hop) / max(stretch, 1)
            if readPos >= Double(hi) { readPos -= Double(span) }
        }
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        if loadGuard.busy { oL.update(repeating: 0, count: frames); oR.update(repeating: 0, count: frames); return }
        if consumeTrigger(0) { recording = true; recLen = 0 }
        if consumeTrigger(1) && recording { finishRecording() }
        if consumeTrigger(2) { length = 0; recording = false; contentVersion &+= 1 }
        let size = Self.sizes[clampIndex(params[4], Self.sizes.count)]
        if size != n { configure(size: size) }
        let stretch = Double(params[3])
        var lo = Double(min(max(params[5], 0), 1)), hi = Double(min(max(params[6], 0), 1))
        if hi < lo { swap(&lo, &hi) }
        let level = params[8], monitor = params[9] > 0.5
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let recIn = inputs[2], frz = inputs[3]
        let hasRec = isConnected(connected, 2), hasFrz = isConnected(connected, 3)
        let L = length
        let rlo = Int(lo * Double(L)), rhi = max(Int(hi * Double(L)), min(rlo + n + 1, L))
        for i in 0..<frames {
            let xl = inL[i], xr = inR[i]
            if hasRec && recGate.rising(recIn[i]) {
                if recording { finishRecording() } else { recording = true; recLen = 0 }
            }
            if recording {
                if recLen < cap { bufL[recLen] = xl; bufR[recLen] = xr; recLen += 1 } else { finishRecording() }
            }
            if outPos >= hop {
                outPos = 0
                let frozen = params[7] > 0.5 || (hasFrz && frz[i] > 0.2)
                if L > n && !recording { nextFrame(lo: rlo, hi: rhi, stretch: stretch, frozen: frozen) }
                else { accL.update(repeating: 0, count: maxN); accR.update(repeating: 0, count: maxN) }
            }
            let mon: Float = (recording && monitor) ? 1 : 0
            oL[i] = accL[outPos] * level + xl * mon
            oR[i] = accR[outPos] * level + xr * mon
            outPos += 1
        }
        if recording { contentVersion &+= 1 }
        readouts[0] = recording ? 1 : (L > 0 ? 2 : 0)
        readouts[1] = Float(Double(recording ? recLen : L) / sampleRate)
        readouts[kPlayheadSlot] = (!recording && L > 0) ? Float(readPos / Double(L)) : -1
        for k in 1..<8 { readouts[kPlayheadSlot + k] = -1 }
    }

    private func finishRecording() {
        recording = false
        length = recLen
        readPos = 0
        contentVersion &+= 1
    }

    // MARK: SampleBufferNode
    public var waveBuffer: UnsafeMutablePointer<Float> { bufL }
    public var waveBufferR: UnsafeMutablePointer<Float> { bufR }
    public var waveLength: Int { recording ? recLen : length }
    public var waveRecording: Bool { recording }
    public var bufferCapacity: Int { cap }
    public func snapshot() -> StereoAudio {
        guard length > 0 else { return StereoAudio() }
        return StereoAudio(left: Array(UnsafeBufferPointer(start: bufL, count: length)),
                           right: Array(UnsafeBufferPointer(start: bufR, count: length)))
    }
    public func load(_ audio: StereoAudio) {
        loadGuard.whileBusy {
            let c = min(audio.count, cap)
            audio.copy(into: bufL, bufR, count: c)
            length = c; recording = false; readPos = 0
            contentVersion &+= 1
        }
    }
}

/// freqshift~ : stereo Bode-style frequency shifter. A Hilbert transformer (two allpass chains 90° apart)
/// makes a complex signal that is multiplied by a complex oscillator: every frequency moves by the
/// same number of Hz, so harmonics go inharmonic — metallic, bell-like, or barber-pole with feedback.
/// Outputs: up L, up R, down L, down R. Params: 0 shift (Hz), 1 feedback, 2 mix
final class FreqShiftNode: DSPNode {
    private struct AP { var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0 }
    // Olli Niemitalo's 90° allpass pairs (coefficients are a², applied to 2-sample delays)
    private static let a: [Float] = [0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737].map { $0 * $0 }
    private static let b: [Float] = [0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278].map { $0 * $0 }
    private var pa = [[AP]](repeating: [AP](repeating: AP(), count: 4), count: 2)
    private var pb = [[AP]](repeating: [AP](repeating: AP(), count: 4), count: 2)
    // instance copies so the audio thread never triggers lazy static initialisation
    private let ca: [Float] = FreqShiftNode.a, cb: [Float] = FreqShiftNode.b
    private var bDelay: [Float] = [0, 0]
    private var fbUp: [Float] = [0, 0]
    private var phase: Double = 0

    @inline(__always) private static func run(_ chain: inout [AP], _ coefs: [Float], _ x: Float) -> Float {
        var v = x
        for k in 0..<4 {
            let c = coefs[k]
            let y = c * (v + chain[k].y2) - chain[k].x2
            chain[k].x2 = chain[k].x1; chain[k].x1 = v
            chain[k].y2 = chain[k].y1; chain[k].y1 = y
            v = y
        }
        return v
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let shift = Double(params[0]), fb = params[1], mix = params[2]
        let inL = inputs[0], inR = isConnected(connected, 1) ? inputs[1] : inputs[0]
        let inc = shift / sampleRate
        for i in 0..<frames {
            phase += inc
            phase -= floor(phase)
            let c = Float(cos(2 * .pi * phase)), s = Float(sin(2 * .pi * phase))
            for ch in 0..<2 {
                let dry = ch == 0 ? inL[i] : inR[i]
                let x = dry + fbUp[ch] * fb
                let iPath = Self.run(&pa[ch], ca, x)
                let qRaw = Self.run(&pb[ch], cb, x)
                let qPath = bDelay[ch]; bDelay[ch] = qRaw
                let u = iPath * c + qPath * s
                let d = iPath * c - qPath * s
                fbUp[ch] = softClip(u)
                outputs[ch][i] = dry * (1 - mix) + u * mix          // up L / up R
                outputs[2 + ch][i] = dry * (1 - mix) + d * mix      // down L / down R
            }
        }
    }
}
