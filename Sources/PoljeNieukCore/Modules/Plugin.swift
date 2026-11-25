// plugin: hosts an Audio Unit (Mac, iPad) or a VST3 plugin (Mac) in a box. Audio in → plugin → audio out,
// notes from a pitch / gate cable (instruments), four knobs that move plugin parameters (patchable), the
// plugin's own editor in a window, and its state saved in the patch.
import Foundation
import AVFoundation
import AudioToolbox
import os
import PluginBridge

/// A loaded plugin, whatever its format.
public protocol HostedPlugin: AnyObject {
    var name: String { get }
    var vendor: String { get }
    var format: String { get }
    var isInstrument: Bool { get }
    /// Automatable parameters (index = what a knob maps to).
    var paramNames: [String] { get }
    // audio thread
    func note(on: Bool, pitch: Int, velocity: Float, offset: Int)
    func setParam(_ index: Int, _ value: Float)
    func render(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>,
                outR: UnsafeMutablePointer<Float>, frames: Int, beat: Double, bpm: Double, playing: Bool)
    // main thread
    func paramValue(_ index: Int) -> Float
    func idle()
    func state() -> Data?
    func restore(_ data: Data)
}

/// One plugin in the list the box offers.
public struct PluginInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let vendor: String
    public let format: String          // "AU" or "VST3"
    public let instrument: Bool
}

public enum PluginCatalog {
    /// Installed Audio Units (instruments and effects) and, on the Mac, VST3 bundles.
    /// The last scan (nil until one has run).
    nonisolated(unsafe) public static var cached: [PluginInfo]?

    public static func scan() -> [PluginInfo] {
        let r = scanNow()
        cached = r
        return r
    }

    private static func scanNow() -> [PluginInfo] {
        var out: [PluginInfo] = []
        let mgr = AVAudioUnitComponentManager.shared()
        for type in [kAudioUnitType_MusicDevice, kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let d = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                              componentFlags: 0, componentFlagsMask: 0)
            for c in mgr.components(matching: d) {
                let a = c.audioComponentDescription
                out.append(PluginInfo(id: "au:\(a.componentType):\(a.componentSubType):\(a.componentManufacturer)",
                                      name: c.name, vendor: c.manufacturerName, format: "AU",
                                      instrument: type == kAudioUnitType_MusicDevice))
            }
        }
        #if os(macOS)
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")]
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3"))
        var seen = Set<String>()
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e where u.pathExtension.lowercased() == "vst3" {
                e.skipDescendants()
                let name = u.deletingPathExtension().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                out.append(PluginInfo(id: "vst3:" + u.path, name: name, vendor: vst3Vendor(u), format: "VST3", instrument: false))
            }
        }
        #endif
        // one name per company: a VST3 maker spelled like an AU maker (spaces / case aside) takes the AU spelling
        var canon: [String: String] = [:]
        func key(_ v: String) -> String { v.lowercased().filter { $0.isLetter || $0.isNumber } }
        for p in out where p.format == "AU" && !p.vendor.isEmpty { canon[key(p.vendor)] = canon[key(p.vendor)] ?? p.vendor }
        out = out.map { p in
            guard p.format == "VST3" else { return p }
            var v = p.vendor
            if let r = v.range(of: "©", options: .backwards) {
                v = v[r.upperBound...].split(separator: " ").drop { $0.allSatisfy(\.isNumber) }.joined(separator: " ")
            }
            for (k, name) in canon where key(v) == k || key(v).hasPrefix(k) && !k.isEmpty { v = name; break }
            return PluginInfo(id: p.id, name: p.name, vendor: v, format: p.format, instrument: p.instrument)
        }
        // the same maker spelled two ways among the VST3s: the spelling with spaces wins
        for p in out where !p.vendor.isEmpty {
            let k = key(p.vendor)
            if let c = canon[k], c.contains(" ") || !p.vendor.contains(" ") { continue }
            canon[k] = p.vendor
        }
        out = out.map { p in
            guard let c = canon[key(p.vendor)], c != p.vendor else { return p }
            return PluginInfo(id: p.id, name: p.name, vendor: c, format: p.format, instrument: p.instrument)
        }
        return out.sorted { ($0.vendor.lowercased(), $0.name.lowercased()) < ($1.vendor.lowercased(), $1.name.lowercased()) }
    }

    #if os(macOS)
    /// The company, from the bundle's Info.plist when it says (cheap: the plugin isn't loaded).
    private static func vst3Vendor(_ u: URL) -> String {
        guard let b = Bundle(url: u), let info = b.infoDictionary else { return "" }
        for key in ["NSHumanReadableCopyright", "CFBundleGetInfoString"] {
            // "… © 2024 Company, Inc. All rights reserved." → Company
            guard let s = info[key] as? String, let r = s.range(of: "©") ?? s.range(of: "(c)", options: .caseInsensitive) else { continue }
            var words = s[r.upperBound...].split(separator: " ").map(String.init)
            while let w = words.first, w.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "," }) { words.removeFirst() }
            var name = words.joined(separator: " ")
            for stop in [",", ". ", " All rights", " Inc", " GmbH", " Ltd", " LLC"] {
                if let k = name.range(of: stop) { name = String(name[..<k.lowerBound]) }
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !name.isEmpty && name.count < 40 { return name }
        }
        if let id = b.bundleIdentifier { let parts = id.split(separator: "."); if parts.count > 1 { return String(parts[1]).capitalized } }
        return ""
    }
    #endif

    /// Opens a plugin (main thread; `done` is called on the main thread).
    public static func load(_ id: String, sampleRate: Double, done: @escaping (HostedPlugin?, String?) -> Void) {
        if id.hasPrefix("au:") {
            let f = id.dropFirst(3).split(separator: ":").compactMap { UInt32($0) }
            guard f.count == 3 else { done(nil, "unknown plugin"); return }
            let d = AudioComponentDescription(componentType: f[0], componentSubType: f[1], componentManufacturer: f[2],
                                              componentFlags: 0, componentFlagsMask: 0)
            AUPlugin.load(d, sampleRate: sampleRate, done: done)
        } else if id.hasPrefix("vst3:") {
            #if os(macOS)
            var err = [CChar](repeating: 0, count: 256)
            guard let h = pnvst3_load(String(id.dropFirst(5)), sampleRate, Int32(kMaxBlock), &err, 256) else {
                done(nil, String(cString: err)); return
            }
            done(VST3Plugin(h), nil)
            #else
            done(nil, "VST3 plugins only load on the Mac")
            #endif
        } else {
            done(nil, "unknown plugin")
        }
    }

    /// Text in a patch array (one UTF-8 byte per number).
    public static func codes(_ s: String) -> [Float] { s.utf8.map { Float($0) } }
    public static func text(_ v: [Float]?) -> String { String(decoding: (v ?? []).map { UInt8(clamping: Int($0)) }, as: UTF8.self) }

    // the patch keeps the plugin's state as bytes, three to a number
    public static func pack(_ d: Data) -> [Float] {
        var out = [Float(d.count)]
        out.reserveCapacity(1 + (d.count + 2) / 3)
        let b = [UInt8](d)
        var i = 0
        while i < b.count {
            let x = UInt32(b[i]) | (i + 1 < b.count ? UInt32(b[i + 1]) << 8 : 0) | (i + 2 < b.count ? UInt32(b[i + 2]) << 16 : 0)
            out.append(Float(x))
            i += 3
        }
        return out
    }
    public static func unpack(_ v: [Float]) -> Data? {
        guard let first = v.first, first >= 0, first.isFinite else { return nil }
        let n = Int(first)
        guard v.count >= 1 + (n + 2) / 3 else { return nil }
        var b = [UInt8](); b.reserveCapacity(n)
        for k in 0..<n {
            let x = UInt32(max(v[1 + k / 3], 0))
            b.append(UInt8((x >> (8 * UInt32(k % 3))) & 0xFF))
        }
        return Data(b)
    }
}

// MARK: - Audio Units

public var debugStatus = false
public final class AUPlugin: HostedPlugin {
    public let unit: AVAudioUnit
    public var au: AUAudioUnit { unit.auAudioUnit }
    public let name: String, vendor: String
    public let format = "AU"
    public let isInstrument: Bool
    public let paramNames: [String]
    private let params: [AUParameter]
    private let renderBlock: AURenderBlock
    private let midiBlock: AUScheduleMIDIEventBlock?
    private let paramBlock: AUScheduleParameterBlock
    private let abl: UnsafeMutableAudioBufferListPointer
    private let outCh: Int, inCh: Int
    private let source: UnsafeMutablePointer<UnsafePointer<Float>?>        // L, R for the pull block
    private let stamp: UnsafeMutablePointer<AudioTimeStamp>
    private let midiBytes: UnsafeMutablePointer<UInt8>
    private let addr: UnsafeMutablePointer<AUParameterAddress>
    private let pMin: UnsafeMutablePointer<Float>, pMax: UnsafeMutablePointer<Float>
    /// tempo, beat, playing (1/0) for the plugin's musical context
    private let music: UnsafeMutablePointer<Double>

    static func load(_ d: AudioComponentDescription, sampleRate: Double, done: @escaping (HostedPlugin?, String?) -> Void) {
        #if os(macOS)
        let opts: AudioComponentInstantiationOptions = []
        #else
        let opts: AudioComponentInstantiationOptions = .loadOutOfProcess
        #endif
        AVAudioUnit.instantiate(with: d, options: opts) { unit, error in
            DispatchQueue.main.async {
                guard let unit else { done(nil, error?.localizedDescription ?? "couldn't open the plugin"); return }
                do { done(try AUPlugin(unit, sampleRate: sampleRate), nil) }
                catch { done(nil, "the plugin won't run here (\(error.localizedDescription))") }
            }
        }
    }

    init(_ unit: AVAudioUnit, sampleRate: Double) throws {
        self.unit = unit
        let au = unit.auAudioUnit
        name = au.audioUnitName ?? "plugin"
        vendor = au.manufacturerName ?? ""
        isInstrument = au.componentDescription.componentType == kAudioUnitType_MusicDevice
        func setStereo(_ bus: AUAudioUnitBus) {
            if let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2), (try? bus.setFormat(f)) != nil { return }
            if let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) { try? bus.setFormat(f) }
        }
        guard au.outputBusses.count > 0 else { throw NSError(domain: "plugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio output"]) }
        setStereo(au.outputBusses[0])
        outCh = Int(au.outputBusses[0].format.channelCount)
        if au.inputBusses.count > 0 { setStereo(au.inputBusses[0]); inCh = Int(au.inputBusses[0].format.channelCount) } else { inCh = 0 }
        au.maximumFramesToRender = 1024

        music = .allocate(capacity: 3); music.initialize(repeating: 0, count: 3); music[0] = 120
        let m = music
        au.musicalContextBlock = { tempo, num, den, beat, toNext, downbeat in
            tempo?.pointee = m[0]; num?.pointee = 4; den?.pointee = 4; beat?.pointee = m[1]
            toNext?.pointee = 0; downbeat?.pointee = (m[1] / 4).rounded(.down) * 4
            return true
        }
        au.transportStateBlock = { flags, sample, _, _ in
            flags?.pointee = m[2] > 0.5 ? [.changed, .moving] : [.changed]
            sample?.pointee = m[1]
            return true
        }
        try au.allocateRenderResources()
        renderBlock = au.renderBlock
        midiBlock = au.scheduleMIDIEventBlock
        paramBlock = au.scheduleParameterBlock

        abl = AudioBufferList.allocate(maximumBuffers: max(outCh, 1))
        source = .allocate(capacity: 2); source.initialize(repeating: nil, count: 2)
        stamp = .allocate(capacity: 1); stamp.initialize(to: AudioTimeStamp())
        stamp.pointee.mFlags = .sampleTimeValid
        midiBytes = .allocate(capacity: 3); midiBytes.initialize(repeating: 0, count: 3)

        let list = (au.parameterTree?.allParameters ?? []).filter { $0.flags.contains(.flag_IsWritable) }.prefix(1024)
        params = Array(list)
        paramNames = params.map { $0.displayName }
        addr = .allocate(capacity: max(params.count, 1))
        pMin = .allocate(capacity: max(params.count, 1)); pMax = .allocate(capacity: max(params.count, 1))
        for (k, p) in params.enumerated() { addr[k] = p.address; pMin[k] = p.minValue; pMax[k] = p.maxValue }

        // effects get their input through the classic render callback (the bridge to older Audio Units
        // doesn't take it from the render block's pull block)
        if inCh > 0 {
            var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, io in
                guard let io else { return noErr }
                let src = refCon.assumingMemoryBound(to: UnsafePointer<Float>?.self)
                let l = UnsafeMutableAudioBufferListPointer(io)
                let bytes = Int(frames) * MemoryLayout<Float>.size
                for k in 0..<l.count {
                    guard let s = src[min(k, 1)] else { continue }
                    if let d = l[k].mData { memcpy(d, s, bytes) } else { l[k].mData = UnsafeMutableRawPointer(mutating: s) }
                    l[k].mDataByteSize = UInt32(bytes)
                }
                return noErr
            }, inputProcRefCon: UnsafeMutableRawPointer(source))
            AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                 &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
    }

    deinit {
        au.deallocateRenderResources()
        free(abl.unsafeMutablePointer)
        source.deallocate(); stamp.deallocate(); midiBytes.deallocate(); music.deallocate()
        addr.deallocate(); pMin.deallocate(); pMax.deallocate()
    }

    public func note(on: Bool, pitch: Int, velocity: Float, offset: Int) {
        guard let midiBlock else { return }
        midiBytes[0] = on ? 0x90 : 0x80
        midiBytes[1] = UInt8(min(max(pitch, 0), 127))
        midiBytes[2] = on ? UInt8(min(max(Int((velocity * 127).rounded()), 1), 127)) : 64
        midiBlock(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, 3, midiBytes)
    }

    public func setParam(_ i: Int, _ v: Float) {
        guard i >= 0, i < params.count else { return }
        paramBlock(AUEventSampleTimeImmediate, 0, addr[i], pMin[i] + min(max(v, 0), 1) * (pMax[i] - pMin[i]))
    }

    public func render(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>,
                       outR: UnsafeMutablePointer<Float>, frames: Int, beat: Double, bpm: Double, playing: Bool) {
        source[0] = inL; source[1] = inR
        music[0] = bpm; music[1] = beat; music[2] = playing ? 1 : 0
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        for k in 0..<abl.count {
            abl[k].mNumberChannels = 1
            abl[k].mDataByteSize = bytes
            abl[k].mData = UnsafeMutableRawPointer(k == 0 ? outL : outR)
        }
        var flags = AudioUnitRenderActionFlags()
        let status = inCh > 0 ? AudioUnitRender(unit.audioUnit, &flags, stamp, 0, UInt32(frames), abl.unsafeMutablePointer)
                              : renderBlock(&flags, stamp, AUAudioFrameCount(frames), 0, abl.unsafeMutablePointer, nil)
        stamp.pointee.mSampleTime += Double(frames)
        if status != noErr { if debugStatus { print("render status", status, "inCh", inCh, "outCh", outCh) }
            outL.update(repeating: 0, count: frames); outR.update(repeating: 0, count: frames); return
        }
        // the plugin may hand back its own buffers
        if let d = abl[0].mData, d != UnsafeMutableRawPointer(outL) { memcpy(outL, d, frames * 4) }
        if abl.count > 1 {
            if let d = abl[1].mData, d != UnsafeMutableRawPointer(outR) { memcpy(outR, d, frames * 4) }
        } else {
            outR.update(from: outL, count: frames)
        }
    }

    public func paramValue(_ i: Int) -> Float {
        guard i >= 0, i < params.count, pMax[i] > pMin[i] else { return 0 }
        return (params[i].value - pMin[i]) / (pMax[i] - pMin[i])
    }
    public func idle() {}
    public func state() -> Data? {
        guard let s = au.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
    }
    public func restore(_ data: Data) {
        guard let s = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
        au.fullState = s
    }
}

// MARK: - VST3 (Mac)

public final class VST3Plugin: HostedPlugin {
    public let handle: OpaquePointer
    public let name: String, vendor: String
    public let format = "VST3"
    public let isInstrument: Bool
    public let paramNames: [String]
    private let time: UnsafeMutablePointer<PNVst3Time>

    init(_ h: OpaquePointer) {
        handle = h
        name = String(cString: pnvst3_name(h))
        vendor = String(cString: pnvst3_vendor(h))
        isInstrument = pnvst3_is_instrument(h) != 0
        var names: [String] = []
        var buf = [CChar](repeating: 0, count: 128)
        for i in 0..<Int(pnvst3_param_count(h)) { pnvst3_param_name(h, Int32(i), &buf, 128); names.append(String(cString: buf)) }
        paramNames = names
        time = .allocate(capacity: 1); time.initialize(to: PNVst3Time())
    }
    deinit { pnvst3_free(handle); time.deallocate() }

    public func note(on: Bool, pitch: Int, velocity: Float, offset: Int) {
        pnvst3_note(handle, on ? 1 : 0, Int32(min(max(pitch, 0), 127)), velocity, Int32(offset))
    }
    public func setParam(_ i: Int, _ v: Float) { pnvst3_param(handle, Int32(i), Double(min(max(v, 0), 1))) }
    public func render(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>,
                       outR: UnsafeMutablePointer<Float>, frames: Int, beat: Double, bpm: Double, playing: Bool) {
        time.pointee.tempo = bpm; time.pointee.beat = beat; time.pointee.playing = playing ? 1 : 0
        pnvst3_process(handle, inL, inR, outL, outR, Int32(frames), time)
        time.pointee.samplePos += Int64(frames)
    }
    public func paramValue(_ i: Int) -> Float { Float(pnvst3_param_value(handle, Int32(i))) }
    public func idle() { pnvst3_idle(handle) }
    public func state() -> Data? {
        var p: UnsafeMutablePointer<UInt8>?
        var n: Int32 = 0
        guard pnvst3_get_state(handle, &p, &n) != 0, let p else { return nil }
        defer { free(p) }
        return Data(bytes: p, count: Int(n))
    }
    public func restore(_ data: Data) {
        let b = [UInt8](data)
        b.withUnsafeBufferPointer { _ = pnvst3_set_state(handle, $0.baseAddress, Int32(b.count)) }
    }
}

// MARK: - the box

public enum PluginLayout {
    public static let macros = 4
    public static let mix = 0, gain = 1, firstMacro = 2
    static func params() -> [ParamSpec] {
        var p = [ParamSpec("mix", "dry / wet", 0, 1, 1, unit: "%"),
                 ParamSpec("gain", "out level", -24, 12, 0, unit: "dB")]
        for k in 1...macros { p.append(ParamSpec("m\(k)", "knob \(k)", 0, 1, 0.5)) }
        return p
    }
}

public final class PluginNode: DSPNode {
    // inputs: 0 L, 1 R, 2 pitch, 3 gate, 4 vel · outputs: 0 L, 1 R
    /// The running plugin (main thread reads; the audio thread uses it under `lock`).
    public private(set) var plugin: HostedPlugin?
    public private(set) var pluginID = ""
    public private(set) var status = ""          // "" when fine; why it didn't load otherwise
    public private(set) var loading = false
    /// Bumped whenever the plugin, its status or the knob mapping changes (the display redraws).
    public private(set) var generation = 0
    /// Knob k moves the plugin's parameter map[k] (-1 = none).
    public let map: UnsafeMutablePointer<Int32>
    private let sent: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let wetL: UnsafeMutablePointer<Float>, wetR: UnsafeMutablePointer<Float>, zero: UnsafeMutablePointer<Float>
    private var high = [Bool](repeating: false, count: kMaxVoices)
    private var held = [Int](repeating: -1, count: kMaxVoices)
    private var pendingState: [Float]?
    private var applied: [Float] = []
    private var requested = ""
    private var savedName = ""

    public override init(spec: ModuleSpec, sampleRate: Double) {
        map = .allocate(capacity: PluginLayout.macros)
        for k in 0..<PluginLayout.macros { map[k] = Int32(k) }
        sent = .allocate(capacity: PluginLayout.macros); sent.initialize(repeating: -1, count: PluginLayout.macros)
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
        wetL = .allocate(capacity: kMaxBlock); wetL.initialize(repeating: 0, count: kMaxBlock)
        wetR = .allocate(capacity: kMaxBlock); wetR.initialize(repeating: 0, count: kMaxBlock)
        zero = .allocate(capacity: kMaxBlock); zero.initialize(repeating: 0, count: kMaxBlock)
        super.init(spec: spec, sampleRate: sampleRate)
    }

    deinit {
        swap(nil)
        map.deallocate(); sent.deallocate(); lock.deallocate()
        wetL.deallocate(); wetR.deallocate(); zero.deallocate()
    }

    public override var defaultData: [String: [Float]] {
        ["plugin": [], "pname": [], "state": [], "map": (0..<PluginLayout.macros).map(Float.init)]
    }

    public override func setData(_ key: String, _ values: [Float]) {
        switch key {
        case "plugin":
            let id = PluginCatalog.text(values)
            guard id != requested else { return }
            requested = id
            open(id)
        case "state":
            guard values != applied else { return }
            if let p = plugin, values.count > 1, let d = PluginCatalog.unpack(values) { p.restore(d); applied = values; pendingState = nil }
            else { pendingState = values }
        case "pname":
            let was = savedName
            savedName = PluginCatalog.text(values)
            // the name came after the plugin it names, which wasn't here: try the one of that name now
            if savedName != was, !requested.isEmpty, plugin == nil, !loading, !status.isEmpty { open(requested) }
        case "map":
            for k in 0..<PluginLayout.macros { map[k] = k < values.count ? Int32(values[k]) : -1; sent[k] = -1 }
            generation &+= 1
        default: break
        }
    }

    private func open(_ id: String) {
        swap(nil)
        pluginID = id
        status = ""
        generation &+= 1
        guard !id.isEmpty else { return }
        loading = true
        // a patch from another computer: when its plugin isn't here, the one of the same name (AU or VST3)
        var target = id
        if let all = PluginCatalog.cached ?? Optional(PluginCatalog.scan()), !all.contains(where: { $0.id == id }), !savedName.isEmpty,
           let same = all.first(where: { $0.name == savedName && id.hasPrefix($0.format == "AU" ? "au:" : "vst3:") })
                   ?? all.first(where: { $0.name == savedName }) {
            target = same.id
        }
        PluginCatalog.load(target, sampleRate: sampleRate) { [weak self] p, err in
            guard let self, self.requested == id else { return }
            self.loading = false
            if let p {
                if let s = self.pendingState, s.count > 1, let d = PluginCatalog.unpack(s) { p.restore(d); self.applied = s }
                self.pendingState = nil
                // knobs start where the plugin is: nothing jumps when it loads
                for k in 0..<PluginLayout.macros {
                    let i = Int(self.map[k])
                    if i >= 0, i < p.paramNames.count { self.base[PluginLayout.firstMacro + k] = p.paramValue(i) }
                    self.sent[k] = self.base[PluginLayout.firstMacro + k]
                }
                self.swap(p)
            } else {
                self.status = err ?? "couldn't open the plugin"
            }
            self.generation &+= 1
            NotificationCenter.default.post(name: PluginNode.changed, object: self)
        }
    }

    public static let changed = Notification.Name("PluginNodeChanged")

    /// Main thread: put a plugin in (or take it out) while audio may be running.
    private func swap(_ p: HostedPlugin?) {
        os_unfair_lock_lock(lock)
        let old = plugin
        plugin = p
        for v in 0..<kMaxVoices { high[v] = false; held[v] = -1 }
        os_unfair_lock_unlock(lock)
        _ = old            // released here, on the main thread
    }

    /// Main thread: the plugin's state now (for the patch).
    public func captureState() -> [Float]? {
        guard let p = plugin, let d = p.state() else { return nil }
        let v = PluginCatalog.pack(d)
        applied = v
        return v
    }

    /// Main thread: knob k now moves parameter i; the knob jumps to where that parameter is.
    public func knobValue(for i: Int) -> Float? {
        guard let p = plugin, i >= 0, i < p.paramNames.count else { return nil }
        return p.paramValue(i)
    }

    public override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>,
                                 connected: UInt64, ctx: ProcessContext) {
        let oL = outputs[0], oR = outputs[1]
        guard os_unfair_lock_trylock(lock) else {
            oL.update(repeating: 0, count: frames); oR.update(repeating: 0, count: frames); return
        }
        defer { os_unfair_lock_unlock(lock) }
        let hasL = isConnected(connected, 0), hasR = isConnected(connected, 1)
        let inL = hasL ? inputs[0] : (hasR ? inputs[1] : UnsafePointer(zero))
        let inR = hasR ? inputs[1] : inL
        guard let p = plugin else {
            // nothing loaded: audio passes through
            for i in 0..<frames { oL[i] = inL[i]; oR[i] = inR[i] }
            readouts[0] = 0
            return
        }
        // notes from the pitch / gate cable, up to four at once
        let hasPitch = isConnected(connected, 2), hasGate = isConnected(connected, 3), hasVel = isConnected(connected, 4)
        let ng = hasGate ? inVoices[3] : 0, np = hasPitch ? inVoices[2] : 1, nv = hasVel ? inVoices[4] : 1
        for v in 0..<kMaxVoices {
            guard v < ng else {
                if held[v] >= 0 { p.note(on: false, pitch: held[v], velocity: 0, offset: 0); held[v] = -1 }
                high[v] = false
                continue
            }
            let g = voice(inputs[3], v), pin = voice(inputs[2], min(v, np - 1)), vin = voice(inputs[4], min(v, nv - 1))
            for i in 0..<frames {
                let x = g[i]
                if !high[v] && x > 0.2 {
                    high[v] = true
                    if held[v] >= 0 { p.note(on: false, pitch: held[v], velocity: 0, offset: i); held[v] = -1 }
                    let vel = hasVel ? min(max(vin[i], 0), 1) : 0.8
                    if vel > 0 {
                        let n = Int(min(max((60 + (hasPitch ? cvSemitones(pin[i]) : 0)).rounded(), 0), 127))
                        p.note(on: true, pitch: n, velocity: vel, offset: i)
                        held[v] = n
                    }
                } else if high[v] && x < 0.1 {
                    high[v] = false
                    if held[v] >= 0 { p.note(on: false, pitch: held[v], velocity: 0, offset: i); held[v] = -1 }
                }
            }
        }
        // the four knobs (only when they move, so the plugin's own editor stays in charge otherwise)
        for k in 0..<PluginLayout.macros where map[k] >= 0 {
            let v = params[PluginLayout.firstMacro + k]
            if abs(v - sent[k]) > 0.0005 { p.setParam(Int(map[k]), v); sent[k] = v }
        }
        p.render(inL: inL, inR: inR, outL: wetL, outR: wetR, frames: frames,
                 beat: ctx.beat[0], bpm: ctx.bpm, playing: ctx.running)
        let mix = params[PluginLayout.mix], g = powf(10, params[PluginLayout.gain] / 20)
        var peak: Float = 0
        for i in 0..<frames {
            var l = (inL[i] * (1 - mix) + wetL[i] * mix) * g, r = (inR[i] * (1 - mix) + wetR[i] * mix) * g
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            oL[i] = l; oR[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        readouts[0] = max(peak, readouts[0] * 0.95)
    }
}
