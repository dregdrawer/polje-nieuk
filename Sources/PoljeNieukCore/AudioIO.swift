import Foundation
import Synchronization
import AudioToolbox
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
}

public enum AudioIOError: LocalizedError {
    case noComponent
    case noDevice
    case noOutputs
    case status(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noComponent: return "Could not open the system audio unit."
        case .noDevice: return "No audio device found."
        case .noOutputs: return "The selected audio device has no outputs."
        case .status(let what, let s): return "\(what) failed (OSStatus \(s))."
        }
    }
}

/// Low-latency duplex audio straight through RemoteIO (iPadOS) or AUHAL (macOS).
/// Input and output are handled in the same callback, so there is no extra buffering.
/// Every hardware channel is exposed: with the disting NT over USB, its USB audio channels
/// show up as in~/out~ channel numbers.
public final class AudioIO {
    public let host: GraphHost
    public private(set) var isRunning = false
    public private(set) var sampleRate: Double = 48000
    public private(set) var inputChannels = 0
    public private(set) var outputChannels = 0
    public private(set) var bufferFrames = 0
    public private(set) var inputName = "—"
    public private(set) var outputName = "—"
    public var preferredBufferFrames = 128
    /// Fraction of the buffer period spent in the render callback (written by the audio thread).
    public private(set) var cpuLoad: Float = 0
    /// Highest recent load (decays over ~2 s), so short spikes — the ones that cause dropouts — show up.
    public private(set) var cpuPeak: Float = 0
    #if os(macOS)
    /// Device UIDs. Output nil = system default (or a disting NT if present).
    /// Input nil = same as output when it has inputs; "none" = no input.
    public var outputUID: String?
    public var inputUID: String?
    private var aggregateID: AudioDeviceID = 0
    /// Real devices currently in use (watched for removal and sample-rate changes).
    public private(set) var activeDevices: [AudioDeviceID] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Called on the main queue when devices are added/removed.
    public var onDevicesChanged: (() -> Void)?
    /// Called on the main queue when an active device changes sample rate or disappears.
    public var onActiveDeviceChanged: (() -> Void)?
    #else
    /// UID of the preferred AVAudioSessionPortDescription (nil = system choice).
    public var inputUID: String?
    /// Force output to the iPad's own speakers instead of the connected interface.
    public var outputToSpeaker = false
    #endif

    /// OUT set to "off": the patch keeps running (clocks, meters, recording) but nothing is sent out.
    public var muteOutput = false

    /// Where the chosen input/output channels sit inside the opened device (non-zero for aggregates).
    private var inOffset = 0, outOffset = 0
    private var devInputs = 0, devOutputs = 0

    static let maxChannels = 64
    #if os(iOS)
    /// Whether the output is currently forced to the speaker (device queue only).
    nonisolated(unsafe) private static var speakerOverride = false

    /// What's plugged in, as far as audio is concerned: the ports and how many channels they offer.
    /// A route change that leaves this the same doesn't need a restart.
    public static func routeSignature() -> String {
        let s = AVAudioSession.sharedInstance()
        let ins = (s.availableInputs ?? []).map(\.uid).sorted().joined(separator: ",")
        let outs = s.currentRoute.outputs.map(\.uid).joined(separator: ",")
        return "\(ins)|\(outs)|\(s.maximumInputNumberOfChannels)|\(s.maximumOutputNumberOfChannels)"
    }
    #endif
    static let maxFrames = 8192

    private var unit: AudioUnit?
    private let inBufs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let inPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let inABL: UnsafeMutableAudioBufferListPointer
    private let ticksToSeconds: Double

    public init(host: GraphHost) {
        self.host = host
        inBufs = .allocate(capacity: Self.maxChannels)
        for c in 0..<Self.maxChannels {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            b.initialize(repeating: 0, count: Self.maxFrames)
            (inBufs + c).initialize(to: b)
        }
        inPtrs = .allocate(capacity: Self.maxChannels)
        inPtrs.initialize(from: inBufs, count: Self.maxChannels)
        outPtrs = .allocate(capacity: Self.maxChannels)
        outPtrs.initialize(from: inBufs, count: Self.maxChannels)
        inABL = AudioBufferList.allocate(maximumBuffers: Self.maxChannels)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToSeconds = Double(tb.numer) / Double(tb.denom) / 1e9
        #if os(macOS)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        #endif
    }

    #if os(macOS)
    private func watch(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
            deviceListeners.append((id, addr, block))
        }
    }

    /// Which devices the current choices point at. The input is chosen on its own and never
    /// follows the output. Automatic input = a connected disting NT, otherwise the system input.
    func resolveDevices() -> (input: AudioDeviceInfo?, output: AudioDeviceInfo)? {
        resolveDevices(inputUID: inputUID, outputUID: outputUID)
    }

    func resolveDevices(inputUID: String?, outputUID: String?) -> (input: AudioDeviceInfo?, output: AudioDeviceInfo)? {
        let all = Self.allDevices()
        guard let outDev = all.first(where: { $0.uid == outputUID && $0.outputChannels > 0 })
                ?? Self.defaultDeviceID().flatMap({ id in all.first { $0.id == id } }) else { return nil }
        var inDev: AudioDeviceInfo?
        if inputUID == "none" {
            inDev = nil
        } else if let uid = inputUID, let d = all.first(where: { $0.uid == uid && $0.inputChannels > 0 }) {
            inDev = d
        } else {
            inDev = all.first { $0.name.lowercased().contains("disting") && $0.inputChannels > 0 }
                ?? Self.defaultInputDeviceID().flatMap { id in all.first { $0.id == id && $0.inputChannels > 0 } }
        }
        return (inDev, outDev)
    }

    #endif

    deinit {
        removeListeners()
        stopHardware()
        for c in 0..<Self.maxChannels { inBufs[c].deallocate() }
        inBufs.deallocate(); inPtrs.deallocate(); outPtrs.deallocate()
        free(inABL.unsafeMutablePointer)
    }

    public var latencyMs: Double { sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0 }

    // MARK: Starting and stopping — off the main thread
    //
    // Everything that talks to the system's audio service (creating, starting, stopping the audio unit,
    // combining interfaces, reading device lists) runs on `deviceQueue`. If macOS audio stalls — it can,
    // e.g. while an interface is plugged in or out — only that queue waits; the window stays responsive.
    // Each start is numbered; a newer start or a stop makes an older one give up when it returns.

    private let deviceQueue = DispatchQueue(label: "polje.audio.devices", qos: .userInitiated)
    private let latest = Mutex<Int>(0)
    /// Main thread: a start is under way.
    public private(set) var isStarting = false

    private struct Request {
        var inputUID: String?
        var outputUID: String?
        var outputToSpeaker = false
        var bufferFrames: Int
    }

    /// What a start found and built (on the device queue), before the main thread takes it over.
    private struct Plan {
        var unit: AudioUnit
        var aggregate: UInt32
        var sampleRate: Double
        var inputChannels: Int, outputChannels: Int, bufferFrames: Int
        var inputName: String, outputName: String
        var devInputs: Int, devOutputs: Int, inOffset: Int, outOffset: Int
        var activeDevices: [UInt32]
    }

    /// Main thread. Starts (or restarts) audio with the current choices; `done` runs on the main thread
    /// with nil on success. `prepare` runs on the main thread just before the unit starts, with the sample
    /// rate (the place to reset the engine).
    public func start(prepare: @escaping (Double) -> Void, done: @escaping (Error?) -> Void) {
        removeListeners()
        isRunning = false
        isStarting = true
        let gen = latest.withLock { $0 += 1; return $0 }
        var req = Request(bufferFrames: preferredBufferFrames)
        req.inputUID = inputUID
        #if os(macOS)
        req.outputUID = outputUID
        #else
        req.outputToSpeaker = outputToSpeaker
        #endif
        deviceQueue.async { [self] in
            stopHardware()
            let built = Result { try build(req) }
            DispatchQueue.main.async { [self] in
                guard latest.withLock({ $0 }) == gen else {          // superseded while the system was busy
                    if case .success(let p) = built { deviceQueue.async { Self.dispose(p) } }
                    return
                }
                switch built {
                case .failure(let e):
                    isStarting = false
                    done(e)
                case .success(let p):
                    apply(p)
                    prepare(p.sampleRate)
                    deviceQueue.async { [self] in
                        var err: Error?
                        if latest.withLock({ $0 }) != gen {
                            Self.dispose(p); return
                        }
                        unit = p.unit
                        #if os(macOS)
                        aggregateID = p.aggregate
                        #endif
                        do {
                            try check(AudioUnitInitialize(p.unit), "Initializing audio unit")
                            try check(AudioOutputUnitStart(p.unit), "Starting audio")
                        } catch {
                            err = error
                            stopHardware()
                        }
                        DispatchQueue.main.async { [self] in
                            guard latest.withLock({ $0 }) == gen else { return }
                            isStarting = false
                            isRunning = err == nil
                            if err == nil { addListeners() }
                            done(err)
                        }
                    }
                }
            }
        }
    }

    /// Main thread. Stops audio; returns straight away (the hardware is released in the background).
    public func stop() {
        latest.withLock { $0 += 1 }                         // any start still in flight gives up
        removeListeners()
        isRunning = false
        isStarting = false
        cpuLoad = 0
        cpuPeak = 0
        deviceQueue.async { [self] in stopHardware() }
    }

    /// Main thread: the device list, read in the background (the list can stall too).
    public func listDevices(_ done: @escaping ([AudioDeviceInfo]) -> Void) {
        deviceQueue.async {
            #if os(macOS)
            let all = Self.allDevices()
            #else
            let all: [AudioDeviceInfo] = []
            #endif
            DispatchQueue.main.async { done(all) }
        }
    }

    #if os(macOS)
    /// Main thread: whether a restart is needed (device gone, rate changed, preferred device back) —
    /// worked out in the background; `done` runs on the main thread.
    public func checkNeedsRestart(_ done: @escaping (Bool) -> Void) {
        let running = isRunning, active = activeDevices, sr = sampleRate
        let req = (inputUID, outputUID)
        deviceQueue.async { [self] in
            var needs = !running
            if running {
                if let (i, o) = resolveDevices(inputUID: req.0, outputUID: req.1) {
                    let wanted = [o.id] + (i.map { $0.id == o.id ? [] : [$0.id] } ?? [])
                    if wanted != active { needs = true }
                }
                for d in active {
                    guard Self.deviceInfo(d) != nil else { needs = true; break }
                    if let r = Self.nominalSampleRate(d), abs(r - sr) > 1 { needs = true; break }
                }
            }
            DispatchQueue.main.async { done(needs) }
        }
    }
    #endif

    /// Main thread: take over what the device queue built (the render callback reads these; the
    /// previous unit is already stopped).
    private func apply(_ p: Plan) {
        sampleRate = p.sampleRate
        inputChannels = p.inputChannels; outputChannels = p.outputChannels
        bufferFrames = p.bufferFrames
        inputName = p.inputName; outputName = p.outputName
        devInputs = p.devInputs; devOutputs = p.devOutputs
        inOffset = p.inOffset; outOffset = p.outOffset
        #if os(macOS)
        activeDevices = p.activeDevices
        #endif
        inABL.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(devInputs)
        for c in 0..<devInputs {
            inABL[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: UnsafeMutableRawPointer(inBufs[c]))
        }
    }

    private func addListeners() {
        #if os(macOS)
        for d in activeDevices {
            watch(d, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.onActiveDeviceChanged?() }
            watch(d, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.onActiveDeviceChanged?() }
        }
        #endif
    }

    private func removeListeners() {
        #if os(macOS)
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        #endif
    }

    /// Device queue: stop and release the running unit and any aggregate device.
    private func stopHardware() {
        if let u = unit {
            AudioOutputUnitStop(u)
            unit = nil
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        destroyAggregate()
    }

    /// Device queue: throw away a unit that was built but never used.
    private static func dispose(_ p: Plan) {
        AudioUnitUninitialize(p.unit)
        AudioComponentInstanceDispose(p.unit)
        #if os(macOS)
        if p.aggregate != 0 { AudioHardwareDestroyAggregateDevice(p.aggregate) }
        #endif
    }

    /// Device queue: find the devices, set them up and build (not start) the audio unit.
    private func build(_ req: Request) throws -> Plan {
        let subtype: OSType
        var p = Plan(unit: AudioUnit(bitPattern: 1)!, aggregate: 0, sampleRate: 48000, inputChannels: 0, outputChannels: 0,
                     bufferFrames: req.bufferFrames, inputName: "—", outputName: "—", devInputs: 0, devOutputs: 0,
                     inOffset: 0, outOffset: 0, activeDevices: [])
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        // Not .mixWithOthers: a mixable session is treated as a background mixer and multichannel
        // interfaces only give it stereo — a patcher should own the interface and all its channels.
        // With an interface plugged in (disting NT over USB): measurement mode, which switches off the
        // system's input processing — its gain control and DC filter turned clocks, gates and CV into
        // brief spikes (the in~ meters still moved, but nothing downstream got the signal). The Mac never
        // processes input. Without an interface: the default mode (normal speaker / mic levels).
        let usb = s.currentRoute.inputs.contains { $0.portType == .usbAudio }
            || s.currentRoute.outputs.contains { $0.portType == .usbAudio }
            || (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
        try s.setCategory(.playAndRecord, mode: usb ? .measurement : .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
        try? s.setPreferredSampleRate(48000)
        try? s.setPreferredIOBufferDuration(Double(req.bufferFrames) / 48000)
        try s.setActive(true)
        // Each of these changes the route (and the system announces it): only touch what's actually different,
        // or every start would set off another route change — and another restart
        if let uid = req.inputUID, s.preferredInput?.uid != uid, let port = s.availableInputs?.first(where: { $0.uid == uid }) {
            try? s.setPreferredInput(port)
        }
        // Output: follow the connected device, or force the built-in speakers.
        if req.outputToSpeaker != Self.speakerOverride {
            try? s.overrideOutputAudioPort(req.outputToSpeaker ? .speaker : .none)
            Self.speakerOverride = req.outputToSpeaker
        }
        if s.isInputAvailable {
            try? s.setPreferredInputNumberOfChannels(s.maximumInputNumberOfChannels)
        }
        try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels)
        p.sampleRate = s.sampleRate
        let inputOff = req.inputUID == "none"
        p.inputChannels = s.isInputAvailable && !inputOff ? min(s.inputNumberOfChannels, Self.maxChannels) : 0
        p.outputChannels = min(s.outputNumberOfChannels, Self.maxChannels)
        p.bufferFrames = Int((s.ioBufferDuration * s.sampleRate).rounded())
        p.inputName = inputOff ? "off" : (s.currentRoute.inputs.first?.portName ?? "none")
        p.outputName = s.currentRoute.outputs.first?.portName ?? "iPad"
        p.devInputs = p.inputChannels; p.devOutputs = p.outputChannels
        subtype = kAudioUnitSubType_RemoteIO
        #else
        guard let (inDev, outDev) = resolveDevices(inputUID: req.inputUID, outputUID: req.outputUID) else { throw AudioIOError.noDevice }
        guard outDev.outputChannels > 0 else { throw AudioIOError.noOutputs }

        var dev = outDev.id
        if let inDev, inDev.id != outDev.id {
            // Two interfaces: combine them in a private aggregate device with drift correction.
            guard let agg = Self.createAggregate(input: inDev, output: outDev) else {
                throw AudioIOError.status("Combining \(inDev.name) and \(outDev.name)", -1)
            }
            p.aggregate = agg
            dev = agg
            let info = Self.deviceInfo(agg)
            p.devInputs = info?.inputChannels ?? 0
            p.devOutputs = info?.outputChannels ?? 0
            p.inputChannels = min(inDev.inputChannels, p.devInputs)
            p.outOffset = min(inDev.outputChannels, max(p.devOutputs - outDev.outputChannels, 0))
            p.outputChannels = min(outDev.outputChannels, p.devOutputs - p.outOffset)
        } else {
            p.devInputs = inDev == nil ? 0 : outDev.inputChannels
            p.devOutputs = outDev.outputChannels
            p.inputChannels = p.devInputs
            p.outputChannels = p.devOutputs
        }
        p.inputChannels = min(p.inputChannels, Self.maxChannels)
        p.outputChannels = min(p.outputChannels, Self.maxChannels)
        p.devInputs = min(p.devInputs, Self.maxChannels)
        p.devOutputs = min(p.devOutputs, Self.maxChannels)
        Self.setBufferSize(dev, frames: req.bufferFrames)
        p.sampleRate = Self.nominalSampleRate(dev) ?? 48000
        p.bufferFrames = Self.bufferSize(dev) ?? req.bufferFrames
        p.inputName = inDev?.name ?? "none"
        p.outputName = outDev.name
        p.activeDevices = [outDev.id] + (inDev.map { $0.id == outDev.id ? [] : [$0.id] } ?? [])
        subtype = kAudioUnitSubType_HALOutput
        #endif

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subtype,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        func fail(_ e: Error) -> Error {
            #if os(macOS)
            if p.aggregate != 0 { AudioHardwareDestroyAggregateDevice(p.aggregate) }
            #endif
            return e
        }
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw fail(AudioIOError.noComponent) }
        var maybeUnit: AudioUnit?
        do { try check(AudioComponentInstanceNew(comp, &maybeUnit), "Creating audio unit") } catch { throw fail(error) }
        guard let u = maybeUnit else { throw fail(AudioIOError.noComponent) }

        do {
            var one: UInt32 = 1
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            if p.devInputs > 0 {
                try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32),
                          "Enabling input")
            }
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, u32),
                      "Enabling output")
            #if os(macOS)
            var d = dev
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &d, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting device")
            #endif
            var maxF = UInt32(Self.maxFrames)
            AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, u32)
            let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if p.devInputs > 0 {
                var f = Self.format(p.sampleRate, p.devInputs)
                try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, asbdSize),
                          "Setting input format")
            }
            var of = Self.format(p.sampleRate, p.devOutputs)
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &of, asbdSize),
                      "Setting output format")
            var cb = AURenderCallbackStruct(inputProc: poljeNieukRenderCallback,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Setting render callback")
        } catch {
            AudioComponentInstanceDispose(u)
            throw fail(error)
        }
        p.unit = u
        return p
    }

    private func destroyAggregate() {
        #if os(macOS)
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        #endif
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioIOError.status(what, status) }
    }

    private static func format(_ sr: Double, _ ch: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
    }

    // MARK: - Audio thread

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let u = unit else { return noErr }
        let t0 = mach_absolute_time()
        let n = Int(frames)

        let out = UnsafeMutableAudioBufferListPointer(ioData)
        var oc = 0
        for b in out {
            guard let d = b.mData else { continue }
            memset(d, 0, Int(b.mDataByteSize))
            if oc < Self.maxChannels {
                outPtrs[oc] = d.assumingMemoryBound(to: Float.self)
                oc += 1
            }
        }

        var ic = 0
        if devInputs > 0 && n <= Self.maxFrames {
            for c in 0..<devInputs {
                inABL[c].mDataByteSize = frames * 4
                inABL[c].mData = UnsafeMutableRawPointer(inBufs[c])
            }
            if AudioUnitRender(u, flags, ts, 1, frames, inABL.unsafeMutablePointer) == noErr {
                for c in 0..<devInputs {
                    inPtrs[c] = inABL[c].mData?.assumingMemoryBound(to: Float.self) ?? inBufs[c]
                }
                ic = min(inputChannels, devInputs - inOffset)
            }
        }
        let goc = max(min(outputChannels, oc - outOffset), 0)

        host.process(frames: n, inputs: inPtrs + inOffset, inputCount: ic, outputs: outPtrs + outOffset, outputCount: goc)

        // OUT off: everything above still ran (clocks, meters, recorders) — just send silence.
        if muteOutput {
            for c in 0..<oc { outPtrs[c].update(repeating: 0, count: n) }
        }
        // Never send NaNs or overs to the modular.
        for c in 0..<oc {
            let p = outPtrs[c]
            for i in 0..<n {
                let v = p[i]
                p[i] = v.isFinite ? min(max(v, -1), 1) : 0
            }
        }

        let elapsed = Double(mach_absolute_time() - t0) * ticksToSeconds
        let load = Float(elapsed / (Double(n) / sampleRate))
        cpuLoad = cpuLoad * 0.9 + load * 0.1
        let decay = Float(exp(-Double(n) / (sampleRate * 2)))
        cpuPeak = max(load, cpuPeak * decay)
        return noErr
    }
}

private func poljeNieukRenderCallback(_ refCon: UnsafeMutableRawPointer,
                                     _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                     _ ts: UnsafePointer<AudioTimeStamp>,
                                     _ bus: UInt32, _ frames: UInt32,
                                     _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioIO>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, frames, ioData)
}

#if os(macOS)
public extension AudioIO {
    /// All audio devices with at least one output.
    static func devices() -> [AudioDeviceInfo] { allDevices().filter { $0.outputChannels > 0 } }
    static func inputDevices() -> [AudioDeviceInfo] { allDevices().filter { $0.inputChannels > 0 } }

    /// Every device, excluding our own temporary aggregates.
    static func allDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(deviceInfo).filter { !$0.uid.hasPrefix("com.poljenieuk.aggregate") && !$0.uid.hasPrefix("com.patchwork.aggregate") }   // ours (and the old name's)
    }

    static func deviceInfo(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let cf = name else { return nil }
        return AudioDeviceInfo(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: cf.takeRetainedValue() as String,
                               inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                               outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Private aggregate: input device first (drift-corrected), output device is the clock.
    static func createAggregate(input: AudioDeviceInfo, output: AudioDeviceInfo) -> AudioDeviceID? {
        if let sr = nominalSampleRate(output.id) { setNominalSampleRate(input.id, sr) }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "polje nieuk I/O",
            kAudioAggregateDeviceUIDKey: "com.poljenieuk.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1],
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0],
            ],
        ]
        var id = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr, id != 0 else { return nil }
        // The new device takes a moment to publish its streams.
        let expectedOut = input.outputChannels + output.outputChannels
        for _ in 0..<40 {
            if let info = deviceInfo(id), info.outputChannels >= expectedOut, info.inputChannels >= input.inputChannels { break }
            usleep(25_000)
        }
        return id
    }

    private static func setNominalSampleRate(_ id: AudioDeviceID, _ sr: Double) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v = Float64(sr)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
    }

    /// Prefers a disting NT if one is connected, otherwise the system output device.
    static func defaultDeviceID() -> AudioDeviceID? {
        let all = devices()
        if let nt = all.first(where: { $0.name.lowercased().contains("disting") }) { return nt.id }

        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return all.first?.id }
        return id
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr) == noErr && sr > 0 ? sr : nil
    }

    private static func setBufferSize(_ id: AudioDeviceID, frames: Int) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var f = UInt32(frames)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &f)
    }

    private static func bufferSize(_ id: AudioDeviceID) -> Int? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var f: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &f) == noErr ? Int(f) : nil
    }
}
#endif

#if os(iOS)
public extension AudioIO {
    /// Inputs iPadOS currently offers (built-in mic, USB interfaces such as the disting NT, …).
    static func availableInputs() -> [(uid: String, name: String)] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map { ($0.uid, $0.portName) }
    }

    /// Where audio is going right now (USB interface, speakers, headphones, AirPlay, Bluetooth …).
    static func currentOutputs() -> [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName }
    }
}
#endif
