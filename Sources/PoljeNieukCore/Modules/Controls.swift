import Foundation

// slider and knob: hands-on CV for live playing. Each holds 1–8 controls; every control has its own
// outlet, and each control's value is also a parameter, so it can be modulated or saved with the patch.

public enum ControlsLayout {
    public static let countChoices = [1, 2, 4, 8]
    public static let maxControls = 8
    public static let ranges = ["0…10 V", "±10 V", "0…5 V", "±5 V", "0…1 V"]
    /// parameter index of control k (0-based)
    public static func valueIndex(_ k: Int) -> Int { 3 + k }
    public static func count(_ v: Float) -> Int { countChoices[clampIndex(v, countChoices.count)] }

    static func params() -> [ParamSpec] {
        var p: [ParamSpec] = [.choice("count", "controls", countChoices.map { "\($0)" }, def: 2),
                              .choice("range", "range", ranges, def: 0),
                              ParamSpec("slew", "smoothing", 0, 2000, 10, unit: "ms", curve: .exponential)]
        for k in 1...maxControls { p.append(ParamSpec("v\(k)", "\(k)", 0, 1, 0.5, unit: "%")) }
        return p
    }

    /// 0…1 control position → output in the app's CV units (0.1 = 1 V).
    @inline(__always) public static func map(_ x: Float, range: Int) -> Float {
        let v = min(max(x.isFinite ? x : 0, 0), 1)
        switch range {
        case 1: return v * 2 - 1
        case 2: return v * 0.5
        case 3: return v - 0.5
        case 4: return v * 0.1
        default: return v
        }
    }
}

final class ControlsNode: DSPNode {
    private var smoothed = [Float](repeating: 0, count: ControlsLayout.maxControls)
    private var smoothedPos = [Float](repeating: 0, count: ControlsLayout.maxControls)
    private var primed = false
    /// Smoothed 0…1 position of each control (first sample read), for cables into parameters.
    private let positions: UnsafeMutablePointer<Float>

    override init(spec: ModuleSpec, sampleRate: Double) {
        positions = .allocate(capacity: ControlsLayout.maxControls * kMaxBlock)
        positions.initialize(repeating: 0.5, count: ControlsLayout.maxControls * kMaxBlock)
        super.init(spec: spec, sampleRate: sampleRate)
    }
    deinit { positions.deallocate() }

    func position(_ k: Int) -> UnsafePointer<Float>? {
        k >= 0 && k < ControlsLayout.maxControls ? UnsafePointer(positions + k * kMaxBlock) : nil
    }

    override func process(frames: Int, inputs: UnsafePointer<UnsafePointer<Float>>, connected: UInt64, ctx: ProcessContext) {
        let n = ControlsLayout.count(params[0])
        let range = clampIndex(params[1], ControlsLayout.ranges.count)
        let coef = onePoleCoef(ms: params[2], sampleRate: sampleRate)
        for k in 0..<ControlsLayout.maxControls {
            let o = outputs[k]
            let pos = params[ControlsLayout.valueIndex(k)]
            readouts[k] = pos.isFinite ? min(max(pos, 0), 1) : 0       // UI: where the control really is
            guard k < n else { o.update(repeating: 0, count: frames); continue }
            let target = ControlsLayout.map(pos, range: range)
            var y = primed ? smoothed[k] : target
            for i in 0..<frames { y += (target - y) * coef; o[i] = y }
            smoothed[k] = y
            // position for parameter cables (read at the start of the next block by the target)
            let p01 = pos.isFinite ? min(max(pos, 0), 1) : 0
            var sp = primed ? smoothedPos[k] : p01
            sp += (p01 - sp) * (1 - powf(1 - coef, Float(frames)))
            smoothedPos[k] = sp
            positions[k * kMaxBlock] = sp
        }
        primed = true
    }
}

/// slider / knob outlets patched into parameters are locked to them both ways.
public enum ControlLink {
    public struct Update: Equatable {
        public let node: UUID; public let index: Int; public let value: Float
        public init(node: UUID, index: Int, value: Float) { self.node = node; self.index = index; self.value = value }
    }

    public static func isControl(_ patch: Patch, _ id: UUID) -> Bool {
        guard let n = patch.nodes.first(where: { $0.id == id }) else { return false }
        return n.kind == "slider" || n.kind == "knob"
    }

    /// The patch with every parameter that a slider / knob drives set to that control's position
    /// (the engine plays the control's position, so the row must show it too).
    public static func reconciled(_ patch: Patch) -> Patch {
        var p = patch
        for n in patch.nodes where n.kind == "slider" || n.kind == "knob" {
            guard let spec = ModuleRegistry.spec(n.kind) else { continue }
            for k in 0..<ControlsLayout.maxControls {
                let vi = ControlsLayout.valueIndex(k)
                let pos = n.params[spec.params[vi].key] ?? spec.params[vi].def
                for u in updates(patch, changed: n.id, index: vi, value: pos) {
                    guard let ti = p.nodes.firstIndex(where: { $0.id == u.node }),
                          let ts = ModuleRegistry.spec(p.nodes[ti].kind) else { continue }
                    p.nodes[ti].params[ts.params[u.index].key] = u.value
                }
            }
        }
        return p
    }

    /// Parameter values to set elsewhere after `changed`'s parameter `index` became `value`.
    public static func updates(_ patch: Patch, changed id: UUID, index: Int, value: Float) -> [Update] {
        guard let n = patch.nodes.first(where: { $0.id == id }), let spec = ModuleRegistry.spec(n.kind),
              index >= 0, index < spec.params.count else { return [] }
        var out: [Update] = []
        /// every parameter driven by control outlet (ctl, k), except `skip`
        func targets(_ ctl: UUID, _ k: Int, position: Float, skip: (UUID, Int)?) {
            for c in patch.cables where c.fromNode == ctl && c.fromPort == k && c.toPort >= kParamPortBase {
                let pi = c.toPort - kParamPortBase
                if let s = skip, s.0 == c.toNode && s.1 == pi { continue }
                guard let t = patch.nodes.first(where: { $0.id == c.toNode }), let ts = ModuleRegistry.spec(t.kind),
                      pi < ts.params.count, !ts.params[pi].isTrigger else { continue }
                out.append(Update(node: t.id, index: pi, value: ts.params[pi].value(fromNormalized: position)))
            }
        }
        if n.kind == "slider" || n.kind == "knob" {
            let k = index - ControlsLayout.valueIndex(0)
            guard k >= 0 && k < ControlsLayout.maxControls else { return [] }
            targets(id, k, position: min(max(value.isFinite ? value : 0, 0), 1), skip: nil)
        } else {
            guard !spec.params[index].isTrigger else { return [] }
            let pos = spec.params[index].normalized(value)
            for c in patch.cables where c.toNode == id && c.toPort == kParamPortBase + index && isControl(patch, c.fromNode) {
                out.append(Update(node: c.fromNode, index: ControlsLayout.valueIndex(c.fromPort), value: pos))
                targets(c.fromNode, c.fromPort, position: pos, skip: (id, index))   // its other targets follow too
            }
        }
        return out
    }
}
