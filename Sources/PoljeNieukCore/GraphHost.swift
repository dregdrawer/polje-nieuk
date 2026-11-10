import Foundation
import Synchronization

/// An immutable, render-ready snapshot of the patch: nodes in processing order with their inlets resolved.
final class CompiledGraph {
    struct Sum {
        let dest: UnsafeMutablePointer<Float>
        let sources: [UnsafePointer<Float>]
    }
    struct Mod {
        let index: Int
        let sources: [UnsafePointer<Float>]
        /// slider~ / knob~ outlets: they *set* the parameter's position (0…1 across its whole range)
        /// instead of adding to it.
        var absolute: [UnsafePointer<Float>] = []
    }
    struct Entry {
        let node: DSPNode
        let inputs: UnsafeMutablePointer<UnsafePointer<Float>>
        let sums: [Sum]
        let mods: [Mod]
        let connected: UInt64
    }

    let entries: [Entry]
    let hasClock: Bool
    private let owned: [UnsafeMutableRawPointer]

    init(entries: [Entry], hasClock: Bool, owned: [UnsafeMutableRawPointer]) {
        self.entries = entries; self.hasClock = hasClock; self.owned = owned
    }

    deinit { owned.forEach { $0.deallocate() } }

    @inline(__always) func process(frames: Int, ctx: ProcessContext) {
        for e in entries {
            for s in e.sums {
                let d = s.dest
                d.update(from: s.sources[0], count: frames)
                for k in 1..<s.sources.count {
                    let src = s.sources[k]
                    for i in 0..<frames { d[i] += src[i] }
                }
            }
            let node = e.node
            let target: Float = node.bypassed && node.spec.bypass != .none ? 1 : 0
            let start = node.bypassMix
            // Fully bypassed: the module is frozen (no CPU), outputs come straight from the routing.
            if !(start == 1 && target == 1) {
                node.syncParams()
                node.applyAutomation(beat: ctx.beat[0])
                for m in e.mods {
                    var v: Float = 0
                    for s in m.sources { v += s[0] }
                    if m.absolute.isEmpty {
                        node.applyMod(m.index, v)
                    } else {
                        var pos: Float = 0
                        for s in m.absolute { pos += s[0] }
                        node.applyMod(m.index, v, position: pos)
                    }
                }
                node.process(frames: frames, inputs: UnsafePointer(e.inputs), connected: e.connected, ctx: ctx)
            }
            if start > 0 || target > 0 {
                let step = (target - start) / Float(frames)
                for (k, out) in node.outputs.enumerated() {
                    let r = k < node.bypassRouting.count ? node.bypassRouting[k] : -1
                    var src: UnsafePointer<Float>? = nil
                    if r >= 0 {
                        // an unpatched R inlet falls back to L, like the effects themselves do
                        let ri = (r > 0 && e.connected & (1 << UInt64(r)) == 0) ? 0 : r
                        src = e.inputs[ri]
                    }
                    var g = start
                    for i in 0..<frames {
                        g += step
                        let thru = src?[i] ?? 0
                        out[i] = (start == 1 && target == 1) ? thru : out[i] * (1 - g) + thru * g
                    }
                }
                node.bypassMix = target
            }
            // Safety net: a module that blows up can't poison the rest of the patch (or crash the UI).
            let fall = expf(-Float(frames) / (0.25 * Float(ctx.sampleRate)))   // ~250 ms fall
            for (k, out) in node.outputs.enumerated() {
                var pk: Float = 0
                for i in 0..<frames {
                    if !out[i].isFinite { out[i] = 0; node.nonFinite &+= 1 }
                    pk = max(pk, abs(out[i]))
                }
                node.outLevel[k] = max(pk, node.outLevel[k] * fall)
            }
        }
    }
}

/// Owns the DSP nodes and hands compiled graphs to the audio thread without blocking it.
/// Nodes persist across edits, so loops and grain buffers survive re-patching.
public final class GraphHost {
    public private(set) var sampleRate: Double
    public private(set) var nodes: [UUID: DSPNode] = [:]
    let ctx: ProcessContext

    private let slot = Mutex<Unmanaged<CompiledGraph>?>(nil)
    private var live: CompiledGraph?
    private var retired: [(graph: CompiledGraph, time: Date)] = []
    private var rtGraph: Unmanaged<CompiledGraph>?   // audio thread only
    private let zero: UnsafeMutablePointer<Float>
    private var lastPatch = Patch()

    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        ctx = ProcessContext(sampleRate: sampleRate)
        zero = .allocate(capacity: kMaxBlock)
        zero.initialize(repeating: 0, count: kMaxBlock)
        // Touch static tables now (main thread) so the audio thread never triggers their lazy init.
        _ = Divisions.beats(0); _ = ClockNode.ppqnValues; _ = ClockNode.outRates
        _ = LooperNode.lengths; _ = BeatRepeatNode.intervals; _ = BeatRepeatNode.grids
        _ = SamplerNode.chopCounts; _ = SamplerNode.autoDivs; _ = PaulStretchNode.sizes
        _ = ParametricEQ.bandChoices
    }

    public func node(_ id: UUID) -> DSPNode? { nodes[id] }

    public var clockBPM: Double { ctx.bpm }

    public enum Transport: Sendable { case play, pause, stop }
    /// ▶ ❚❚ ■ — main thread. Stop also rewinds: the next ▶ starts everything from its first step.
    public func transport(_ t: Transport) {
        switch t {
        case .play: ctx.running = true
        case .pause: ctx.running = false
        case .stop: ctx.running = false; ctx.stopPending = true
        }
    }
    public var isPlaying: Bool { ctx.running }
    /// Where the clock is now, in beats (read on the main thread for visuals).
    public var currentBeat: Double { ctx.lastBeat }
    public var externalClock: Bool { ctx.externalClock }

    /// Call from the main thread whenever nodes or cables change.
    /// Swap in a fresh instance of one module (same settings), so delay lines, reverb tails, grain
    /// buffers etc. start empty. It fades in from its bypass state rather than jumping.
    public func renew(_ id: UUID, in patch: Patch) {
        guard nodes[id] != nil else { return }
        nodes.removeValue(forKey: id)
        load(patch)
        if let n = nodes[id] { n.bypassMix = 1 }
    }

    /// Tempo used when the patch has no clock~ module.
    public var defaultBPM: Double = 120

    public func load(_ patch: Patch) {
        lastPatch = patch
        defaultBPM = patch.tempo ?? 120
        var fresh: [UUID: DSPNode] = [:]
        for n in patch.nodes {
            if let existing = nodes[n.id] {
                existing.bypassed = n.bypassed
                existing.sync(to: n)                  // undo / redo: knobs, patterns and lanes follow the patch
                fresh[n.id] = existing
            } else if let spec = ModuleRegistry.spec(n.kind) {
                let node = spec.factory(spec, sampleRate)
                node.bypassed = n.bypassed
                node.bypassMix = n.bypassed ? 1 : 0
                for (k, v) in n.data { node.setData(k, v) }
                node.loadAutomation(n.data)
                for (i, p) in spec.params.enumerated() where !p.isTrigger {
                    if let v = n.params[p.key] { node.base[i] = v; node.params[i] = v }
                }
                fresh[n.id] = node
            }
        }
        nodes = fresh
        install(compile(patch))
    }

    /// Rebuilds every node at a new sample rate. Stop audio before calling.
    public func setSampleRate(_ sr: Double) {
        guard sr != sampleRate else { return }
        sampleRate = sr
        ctx.sampleRate = sr
        ctx.samplesPerBeat = sr * 0.5
        nodes = [:]
        load(lastPatch)
    }

    /// Call before starting the audio unit (audio thread not running).
    public func prepareForStart() { rtGraph = nil }

    /// Zeroes meters/BPM etc. so the UI doesn't show stale values while audio is off.
    public func clearReadouts() {
        for n in nodes.values { n.readouts.update(repeating: 0, count: DSPNode.readoutCount) }
        ctx.samplesPerBeat = sampleRate * 0.5
        ctx.externalClock = false
    }

    private func install(_ g: CompiledGraph) {
        let ref = Unmanaged.passUnretained(g)
        slot.withLock { $0 = ref }
        if let old = live { retired.append((old, Date())) }
        live = g
        purgeRetired()
    }

    private func purgeRetired() {
        let now = Date()
        retired.removeAll { now.timeIntervalSince($0.time) > 2 }
        if !retired.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.purgeRetired() }
        }
    }

    private func compile(_ patch: Patch) -> CompiledGraph {
        let ids = patch.nodes.map(\.id).filter { nodes[$0] != nil }
        let idSet = Set(ids)
        let cables = patch.cables.filter { idSet.contains($0.fromNode) && idSet.contains($0.toNode) }

        // Clocks (and whatever feeds them) run first so every synced module sees this block's beat.
        var upstream: [UUID: [UUID]] = [:]
        for c in cables { upstream[c.toNode, default: []].append(c.fromNode) }
        var first = Set<UUID>()
        var stack = patch.nodes.filter { $0.kind == "clock" && idSet.contains($0.id) }.map(\.id)
        while let id = stack.popLast() {
            if first.insert(id).inserted { stack.append(contentsOf: upstream[id] ?? []) }
        }
        let order = topo(ids.filter { first.contains($0) }, cables) + topo(ids.filter { !first.contains($0) }, cables)

        var owned: [UnsafeMutableRawPointer] = []
        var entries: [CompiledGraph.Entry] = []
        for id in order {
            guard let node = nodes[id] else { continue }
            let nIn = node.spec.inputs.count
            let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: max(1, nIn))
            ptrs.initialize(repeating: UnsafePointer(zero), count: max(1, nIn))
            owned.append(UnsafeMutableRawPointer(ptrs))
            var sums: [CompiledGraph.Sum] = []
            var mask: UInt64 = 0
            for p in 0..<nIn {
                let sources: [UnsafePointer<Float>] = cables
                    .filter { $0.toNode == id && $0.toPort == p }
                    .compactMap { c in
                        guard let src = nodes[c.fromNode], c.fromPort < src.outputs.count else { return nil }
                        return UnsafePointer(src.outputs[c.fromPort])
                    }
                if sources.isEmpty { continue }
                mask |= 1 << UInt64(p)
                if sources.count == 1 {
                    ptrs[p] = sources[0]
                } else {
                    let dest = UnsafeMutablePointer<Float>.allocate(capacity: kMaxBlock)
                    dest.initialize(repeating: 0, count: kMaxBlock)
                    owned.append(UnsafeMutableRawPointer(dest))
                    sums.append(.init(dest: dest, sources: sources))
                    ptrs[p] = UnsafePointer(dest)
                }
            }
            if let out = node as? HardwareOutNode {
                // channels fed only by control voltages skip out~'s gain (1 V/oct stays 1 V/oct)
                var cv: UInt64 = 0
                for p in 0..<min(nIn, 64) {
                    let srcs = cables.filter { $0.toNode == id && $0.toPort == p }
                    if !srcs.isEmpty && srcs.allSatisfy({ isCV($0.fromNode, $0.fromPort, cables, depth: 0) }) { cv |= 1 << UInt64(p) }
                }
                out.cvChannels = cv
            }
            var mods: [CompiledGraph.Mod] = []
            for i in 0..<node.paramCount {
                var sources: [UnsafePointer<Float>] = [], absolute: [UnsafePointer<Float>] = []
                for c in cables where c.toNode == id && c.toPort == kParamPortBase + i {
                    guard let src = nodes[c.fromNode], c.fromPort < src.outputs.count else { continue }
                    if let ctl = src as? ControlsNode, let pos = ctl.position(c.fromPort) {
                        absolute.append(pos)
                    } else {
                        sources.append(UnsafePointer(src.outputs[c.fromPort]))
                    }
                }
                if !sources.isEmpty || !absolute.isEmpty { mods.append(.init(index: i, sources: sources, absolute: absolute)) }
            }
            entries.append(.init(node: node, inputs: ptrs, sums: sums, mods: mods, connected: mask))
        }
        let hasClock = entries.contains { $0.node is ClockNode }
        return CompiledGraph(entries: entries, hasClock: hasClock, owned: owned)
    }

    /// Is this outlet a control voltage? scope~ passes its inputs through, so it is whatever feeds it.
    private func isCV(_ id: UUID, _ port: Int, _ cables: [PatchCable], depth: Int) -> Bool {
        guard let n = nodes[id], depth < 8 else { return false }
        if n.spec.kind == "scope" {
            let feeds = cables.filter { $0.toNode == id && $0.toPort == port }
            return !feeds.isEmpty && feeds.allSatisfy { isCV($0.fromNode, $0.fromPort, cables, depth: depth + 1) }
        }
        return n.spec.outputsAreCV
    }

    /// Kahn's algorithm. Nodes in feedback loops are appended afterwards and read the previous block.
    private func topo(_ ids: [UUID], _ cables: [PatchCable]) -> [UUID] {
        let set = Set(ids)
        var indeg: [UUID: Int] = [:]
        var down: [UUID: [UUID]] = [:]
        for id in ids { indeg[id] = 0 }
        for c in cables where set.contains(c.fromNode) && set.contains(c.toNode) && c.fromNode != c.toNode {
            indeg[c.toNode, default: 0] += 1
            down[c.fromNode, default: []].append(c.toNode)
        }
        var queue = ids.filter { indeg[$0] == 0 }
        var out: [UUID] = []
        var seen = Set<UUID>()
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted else { continue }
            out.append(id)
            for d in down[id] ?? [] {
                indeg[d, default: 0] -= 1
                if indeg[d] == 0 { queue.append(d) }
            }
        }
        for id in ids where !seen.contains(id) { out.append(id) }
        return out
    }

    // MARK: - Audio thread

    /// Runs the graph. Output buffers must be zeroed by the caller; modules add into them.
    public func process(frames: Int,
                        inputs: UnsafePointer<UnsafeMutablePointer<Float>>, inputCount: Int,
                        outputs: UnsafePointer<UnsafeMutablePointer<Float>>, outputCount: Int) {
        if let g = slot.withLockIfAvailable({ $0 }) { rtGraph = g }
        guard let graph = rtGraph?.takeUnretainedValue() else { return }
        let ic = min(inputCount, ctx.maxChannels)
        let oc = min(outputCount, ctx.maxChannels)
        var off = 0
        while off < frames {
            let n = min(kMaxBlock, frames - off)
            for c in 0..<ic { ctx.inputs[c] = inputs[c] + off }
            for c in 0..<oc { ctx.outputs[c] = outputs[c] + off }
            ctx.inputCount = ic
            ctx.outputCount = oc
            ctx.frames = n
            if !graph.hasClock {
                // No clock module: free-running at the patch tempo (120 BPM unless changed in the top bar).
                ctx.samplesPerBeat = sampleRate * 60 / min(max(defaultBPM, 20), 300)
                ctx.externalClock = false
                let step = ctx.running ? 1 / ctx.samplesPerBeat : 0
                var b = ctx.stopPending ? -1e-6 : ctx.lastBeat
                for i in 0..<n { b += step; ctx.beat[i] = b }
            }
            graph.process(frames: n, ctx: ctx)
            ctx.lastBeat = ctx.beat[n - 1]
            ctx.stopPending = false
            off += n
        }
    }
}
