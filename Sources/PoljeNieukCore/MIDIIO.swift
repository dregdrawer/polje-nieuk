import Foundation
import CoreMIDI
import os

// MIDI in and out (CoreMIDI). Every connected device is listened to; what arrives is handed to the graph
// once per audio buffer (ProcessContext.midiIn), and what modules send (ProcessContext.midiOut) goes out at
// the end of the buffer, time-stamped to the sample. The top bar's midi menu switches devices on and off;
// a midi box can also pick one device for itself (even one that's off in the menu).

/// One MIDI message inside an audio buffer.
public struct MidiMsg {
    /// In: the device it came from. Out: the device to send to (0 = every MIDI out that's on).
    public var port: Int32
    public var status: UInt8
    public var d1: UInt8
    public var d2: UInt8
    /// In: the device is on in the midi menu (keyboards and "all devices" boxes only listen to those).
    public var global: Bool
    /// Sample within the buffer.
    public var offset: UInt16
    public init(port: Int32, status: UInt8, d1: UInt8, d2: UInt8, global: Bool, offset: UInt16) {
        self.port = port; self.status = status; self.d1 = d1; self.d2 = d2; self.global = global; self.offset = offset
    }
}

public final class MIDIHub {
    public static let shared = MIDIHub()
    public struct Device: Equatable, Hashable { public let id: Int32; public let name: String }

    /// Main thread: devices you can receive from / send to (apps reach us through the "polje nieuk" ports).
    public private(set) var sources: [Device] = []
    public private(set) var destinations: [Device] = []
    /// Main thread: called after devices come or go.
    public var onChange: (() -> Void)?
    public private(set) var started = false

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var virtualSrc = MIDIEndpointRef()
    private var virtualDst = MIDIEndpointRef()
    private var virtualDstID: Int32 = 0
    private var connectedSources: [MIDIEndpointRef] = []

    // incoming: CoreMIDI's thread writes, the audio thread takes it all once per buffer
    private let inLock: UnsafeMutablePointer<os_unfair_lock>
    private static let ringSize = 1024
    private let ring: UnsafeMutablePointer<MidiMsg>
    private var ringCount = 0
    private var offInIDs: [Int32] = []

    // outgoing: the audio thread sends; the table only changes (under outLock) when devices change
    private struct Out { var ref: MIDIEndpointRef; var id: Int32; var on: Bool; var virtual: Bool }
    private let outLock: UnsafeMutablePointer<os_unfair_lock>
    private static let maxOuts = 64
    private let outs: UnsafeMutablePointer<Out>
    private var outCount = 0
    private static let listBytes = 16384
    private let listBuf: UnsafeMutableRawPointer
    private let order: UnsafeMutablePointer<Int>
    private let ticksPerSecond: Double

    /// In / out devices switched off in the midi menu (by name, remembered).
    public private(set) var offIn: Set<String>
    public private(set) var offOut: Set<String>
    private var boxes: [Weak] = []
    private struct Weak { weak var node: MIDIBoxNode? }

    /// Shown in device lists for the app's own ports.
    public static let appsName = "other apps (polje nieuk)"

    init() {
        inLock = .allocate(capacity: 1); inLock.initialize(to: os_unfair_lock())
        outLock = .allocate(capacity: 1); outLock.initialize(to: os_unfair_lock())
        ring = .allocate(capacity: Self.ringSize)
        ring.initialize(repeating: MidiMsg(port: 0, status: 0, d1: 0, d2: 0, global: false, offset: 0), count: Self.ringSize)
        outs = .allocate(capacity: Self.maxOuts)
        outs.initialize(repeating: Out(ref: 0, id: 0, on: false, virtual: false), count: Self.maxOuts)
        listBuf = .allocate(byteCount: Self.listBytes, alignment: 8)
        order = .allocate(capacity: ProcessContext.midiCapacity)
        order.initialize(repeating: 0, count: ProcessContext.midiCapacity)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksPerSecond = 1e9 * Double(tb.denom) / Double(max(tb.numer, 1))
        let d = UserDefaults.standard
        offIn = Set(d.stringArray(forKey: "midiOffIn") ?? [])
        offOut = Set(d.stringArray(forKey: "midiOffOut") ?? [])
    }

    // MARK: main thread

    /// Opens CoreMIDI (the app calls this once at launch; the self-test never does).
    public func start() {
        guard !started else { return }
        let st = MIDIClientCreateWithBlock("polje nieuk" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.rescan() } }
        }
        guard st == noErr else { return }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, ref in
            self?.receive(list, from: Int32(truncatingIfNeeded: Int(bitPattern: ref)))
        }
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        // ports other apps (a DAW, another synth app) can use to talk to us
        MIDISourceCreateWithProtocol(client, "polje nieuk" as CFString, ._1_0, &virtualSrc)
        MIDIDestinationCreateWithProtocol(client, "polje nieuk" as CFString, ._1_0, &virtualDst) { [weak self] list, _ in
            guard let self else { return }
            self.receive(list, from: self.virtualDstID)
        }
        virtualDstID = Self.uniqueID(virtualDst)
        started = true
        rescan()
    }

    public func rescan() {
        guard started else { return }
        for s in connectedSources { MIDIPortDisconnectSource(inPort, s) }
        connectedSources = []
        let ownSrc = Self.uniqueID(virtualSrc)
        var srcs: [Device] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let e = MIDIGetSource(i)
            let id = Self.uniqueID(e)
            guard id != ownSrc, id != 0 else { continue }
            srcs.append(Device(id: id, name: Self.name(e)))
            MIDIPortConnectSource(inPort, e, UnsafeMutableRawPointer(bitPattern: Int(id)))
            connectedSources.append(e)
        }
        if virtualDstID != 0 { srcs.append(Device(id: virtualDstID, name: Self.appsName)) }
        var dsts: [Device] = []
        var table: [Out] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let e = MIDIGetDestination(i)
            let id = Self.uniqueID(e)
            guard id != virtualDstID, id != 0 else { continue }
            let d = Device(id: id, name: Self.name(e))
            dsts.append(d)
            table.append(Out(ref: e, id: id, on: !offOut.contains(d.name), virtual: false))
        }
        let vid = Self.uniqueID(virtualSrc)
        if vid != 0 {
            dsts.append(Device(id: vid, name: Self.appsName))
            table.append(Out(ref: virtualSrc, id: vid, on: !offOut.contains(Self.appsName), virtual: true))
        }
        sources = srcs
        destinations = dsts
        let off = srcs.filter { offIn.contains($0.name) }.map(\.id)
        os_unfair_lock_lock(inLock); offInIDs = off; os_unfair_lock_unlock(inLock)
        os_unfair_lock_lock(outLock)
        outCount = min(table.count, Self.maxOuts)
        for k in 0..<outCount { outs[k] = table[k] }
        os_unfair_lock_unlock(outLock)
        boxes.removeAll { $0.node == nil }
        for b in boxes { b.node?.resolve() }
        onChange?()
    }

    public func isOn(input name: String) -> Bool { !offIn.contains(name) }
    public func isOn(output name: String) -> Bool { !offOut.contains(name) }
    public func setInput(_ name: String, on: Bool) {
        if on { offIn.remove(name) } else { offIn.insert(name) }
        UserDefaults.standard.set(Array(offIn), forKey: "midiOffIn")
        rescan()
    }
    public func setOutput(_ name: String, on: Bool) {
        if on { offOut.remove(name) } else { offOut.insert(name) }
        UserDefaults.standard.set(Array(offOut), forKey: "midiOffOut")
        rescan()
    }
    /// Device id for a name (0 = "all", -1 = not connected right now).
    func sourceID(_ name: String) -> Int32 { name.isEmpty ? 0 : (sources.first { $0.name == name }?.id ?? -1) }
    func destinationID(_ name: String) -> Int32 {
        if name == "none" { return -1 }
        return name.isEmpty ? 0 : (destinations.first { $0.name == name }?.id ?? -1)
    }
    func register(_ n: MIDIBoxNode) {
        if !boxes.contains(where: { $0.node === n }) { boxes.append(Weak(node: n)) }
    }

    private static func uniqueID(_ e: MIDIObjectRef) -> Int32 {
        var v: Int32 = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &v)
        return v
    }
    private static func name(_ e: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        if MIDIObjectGetStringProperty(e, kMIDIPropertyName, &s) == noErr, let v = s?.takeRetainedValue() { return v as String }
        return "MIDI device"
    }

    // MARK: CoreMIDI's thread

    private func receive(_ list: UnsafePointer<MIDIEventList>, from id: Int32) {
        os_unfair_lock_lock(inLock)
        defer { os_unfair_lock_unlock(inLock) }
        let global = !offInIDs.contains(id)
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12
        for packet in list.unsafeSequence() {
            let n = Int(packet.pointee.wordCount)
            let words = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
            for k in 0..<n {
                let w = words[k]
                let type = w >> 28
                let status = UInt8((w >> 16) & 0xFF)
                if type == 2 {                    // MIDI 1.0 channel message
                    push(MidiMsg(port: id, status: status, d1: UInt8((w >> 8) & 0x7F), d2: UInt8(w & 0x7F), global: global, offset: 0))
                } else if type == 1, status == 0xF8 || status == 0xFA || status == 0xFB || status == 0xFC {
                    push(MidiMsg(port: id, status: status, d1: 0, d2: 0, global: global, offset: 0))
                }
            }
        }
    }
    @inline(__always) private func push(_ m: MidiMsg) {
        guard ringCount < Self.ringSize else { return }
        ring[ringCount] = m
        ringCount += 1
    }

    // MARK: audio thread

    /// Start of an audio buffer: everything that arrived since the last one.
    func pull(_ ctx: ProcessContext) {
        ctx.midiInCount = 0
        guard started, ringCount > 0, os_unfair_lock_trylock(inLock) else { return }
        let n = min(ringCount, ProcessContext.midiCapacity)
        ctx.midiIn.update(from: ring, count: n)
        ctx.midiInCount = n
        ringCount = 0
        os_unfair_lock_unlock(inLock)
    }

    /// End of an audio buffer: send what the modules played, each at its sample.
    func push(_ ctx: ProcessContext, sampleRate: Double) {
        let n = ctx.midiOutCount
        guard n > 0 else { return }
        guard started else { ctx.midiOutCount = 0; return }
        guard os_unfair_lock_trylock(outLock) else {
            for k in 0..<n { ctx.midiOut[k].offset = 0 }      // devices are changing: send it next buffer
            return
        }
        defer { os_unfair_lock_unlock(outLock); ctx.midiOutCount = 0 }
        // in time order (stable, so a note-off still goes before a note-on at the same sample)
        for k in 0..<n { order[k] = k }
        for a in 1..<max(n, 1) {
            let v = order[a]; var b = a
            while b > 0 && ctx.midiOut[order[b - 1]].offset > ctx.midiOut[v].offset { order[b] = order[b - 1]; b -= 1 }
            order[b] = v
        }
        let now = mach_absolute_time()
        let tps = ticksPerSecond / max(sampleRate, 1)
        let list = listBuf.assumingMemoryBound(to: MIDIEventList.self)
        for d in 0..<outCount {
            let o = outs[d]
            var pkt: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
            var any = false
            for k in 0..<n {
                let m = ctx.midiOut[order[k]]
                guard m.port == 0 ? o.on : m.port == o.id else { continue }
                var w: UInt32 = m.status >= 0xF0
                    ? (1 << 28) | (UInt32(m.status) << 16)
                    : (2 << 28) | (UInt32(m.status) << 16) | (UInt32(m.d1 & 0x7F) << 8) | UInt32(m.d2 & 0x7F)
                guard let p = pkt else { break }
                pkt = MIDIEventListAdd(list, Self.listBytes, p, now &+ UInt64(Double(m.offset) * tps), 1, &w)
                any = true
            }
            if any {
                if o.virtual { MIDIReceivedEventList(o.ref, list) } else { MIDISendEventList(outPort, o.ref, list) }
            }
        }
    }
}
