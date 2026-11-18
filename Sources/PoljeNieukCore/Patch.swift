import Foundation

/// One box on the canvas.
public struct PatchNode: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var x: Double
    public var y: Double
    public var params: [String: Float]
    public var collapsed: Bool
    public var bypassed: Bool
    /// Module-specific arrays (sequencer steps, piano-roll notes, drum hits …).
    public var data: [String: [Float]]
    /// User-resized box: width, and height of its display area (nil = the module's default).
    public var w: Double?
    public var dh: Double?
    /// text boxes: what's written in them.
    public var text: String?
    /// 3D mode: how high the box floats above the board (canvas units; nil = on the board).
    public var z: Double?

    public init(id: UUID = UUID(), kind: String, x: Double, y: Double,
                params: [String: Float] = [:], collapsed: Bool = false, bypassed: Bool = false,
                data: [String: [Float]] = [:]) {
        self.id = id; self.kind = kind; self.x = x; self.y = y
        self.params = params; self.collapsed = collapsed; self.bypassed = bypassed; self.data = data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        params = try c.decodeIfPresent([String: Float].self, forKey: .params) ?? [:]
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        bypassed = try c.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        data = try c.decodeIfPresent([String: [Float]].self, forKey: .data) ?? [:]
        w = try c.decodeIfPresent(Double.self, forKey: .w)
        dh = try c.decodeIfPresent(Double.self, forKey: .dh)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        z = try c.decodeIfPresent(Double.self, forKey: .z)
    }
}

/// A patch cord from an outlet to an inlet.
public struct PatchCable: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fromNode: UUID
    public var fromPort: Int
    public var toNode: UUID
    public var toPort: Int

    public init(id: UUID = UUID(), fromNode: UUID, fromPort: Int, toNode: UUID, toPort: Int) {
        self.id = id; self.fromNode = fromNode; self.fromPort = fromPort
        self.toNode = toNode; self.toPort = toPort
    }
}

public struct PatchGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [UUID]
    public init(id: UUID = UUID(), name: String, members: [UUID]) { self.id = id; self.name = name; self.members = members }
}

public struct Patch: Codable, Equatable, Sendable {
    public static let currentVersion = 12
    public var version: Int = Patch.currentVersion
    public var nodes: [PatchNode] = []
    public var cables: [PatchCable] = []
    /// Tempo when there's no clock~ module (nil = 120 BPM).
    public var tempo: Double?
    /// Groups of boxes that move together on a shared backdrop.
    public var groups: [PatchGroup]?
    public init() {}

    public func index(of id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }
}

public extension Patch {
    /// Upgrades older patches. v1 had single-channel in~/out~ boxes with channel parameters;
    /// v2 boxes expose every hardware channel as its own port, so cables move to the matching port.
    func migrated() -> Patch {
        guard version < Patch.currentVersion else { return self }
        var p = self
        if version < 2 { p = p.migrateV1() }
        if version < 3 {
        // v3: looper "speed" menu (-2x…2x) became varispeed "rate" + a separate "rev" switch.
        let oldSpeeds: [Float] = [-2, -1, -0.5, 0.5, 1, 2]
        for (i, n) in p.nodes.enumerated() where n.kind == "looper" {
            if let idx = n.params["speed"] {
                let v = oldSpeeds[min(max(Int(idx.isFinite ? idx.rounded() : 4), 0), 5)]
                p.nodes[i].params["rate"] = abs(v)
                p.nodes[i].params["rev"] = v < 0 ? 1 : 0
                p.nodes[i].params["speed"] = nil
            }
            // parameter cables shift: keep/level/dry moved down one slot
            for k in p.cables.indices where p.cables[k].toNode == n.id && p.cables[k].toPort >= kParamPortBase + 7 {
                p.cables[k].toPort += 1
            }
        }
        }
        // v4: comp~ became an LA-3A-style compressor with different controls.
        if version < 4 {
            for (i, n) in p.nodes.enumerated() where n.kind == "comp" {
                p.nodes[i].params = [:]
                p.cables.removeAll { $0.toNode == n.id && $0.toPort >= kParamPortBase }
            }
        }
        // v5: stereo. These modules gained an "R" inlet at index 1, so their other inlets moved up one.
        if version < 5 {
            let shifted: Set<String> = ["looper", "sampler", "stretch", "grain", "filter"]
            let kinds = Dictionary(p.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
            for k in p.cables.indices {
                let c = p.cables[k]
                if let kind = kinds[c.toNode], shifted.contains(kind), c.toPort >= 1, c.toPort < kParamPortBase {
                    p.cables[k].toPort += 1
                }
                // freqshift outlets: up, down → up L, up R, down L, down R
                if kinds[c.fromNode] == "freqshift" && c.fromPort == 1 { p.cables[k].fromPort = 2 }
            }
            // Mono outlets that became L/R: a source feeding two out~ channels now sends L to the first, R to the second.
            let nowStereo: Set<String> = ["looper", "filter", "drive"]
            for n in p.nodes where nowStereo.contains(n.kind) {
                let toOut = p.cables.indices.filter {
                    p.cables[$0].fromNode == n.id && p.cables[$0].fromPort == 0 && kinds[p.cables[$0].toNode] == "out"
                }.sorted { p.cables[$0].toPort < p.cables[$1].toPort }
                if toOut.count >= 2 { p.cables[toOut[1]].fromPort = 1 }
            }
        }
        // v6: mix~ became a stereo 2–16 channel mixer. Old param slots 0–3 (g1–g4) and 4 (master) moved;
        // its single "out" became L/R.
        if version < 6 {
            let kinds = Dictionary(p.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
            for k in p.cables.indices {
                let c = p.cables[k]
                guard kinds[c.toNode] == "mix", c.toPort >= kParamPortBase else { continue }
                let old = c.toPort - kParamPortBase
                p.cables[k].toPort = kParamPortBase + (old < 4 ? 1 + 2 * old : MixerLayout.masterIndex)
            }
            for n in p.nodes where n.kind == "mix" {
                let toOut = p.cables.indices.filter {
                    p.cables[$0].fromNode == n.id && p.cables[$0].fromPort == 0 && kinds[p.cables[$0].toNode] == "out"
                }.sorted { p.cables[$0].toPort < p.cables[$1].toPort }
                if toOut.count >= 2 { p.cables[toOut[1]].fromPort = 1 }
            }
        }
        p.version = Patch.currentVersion
        if version < 7 {
            // v7: pitch inlets come first everywhere (like the sequencers' pitch, gate outlets).
            let remap: [String: [Int: Int]] = ["modal": [0: 1, 1: 0], "macro": [0: 1, 1: 0], "shapes": [0: 1, 1: 0],
                                               "slopes": [0: 1, 1: 0], "resonator": [1: 2, 2: 1]]
            let kinds = Dictionary(p.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
            for (i, c) in p.cables.enumerated() where c.toPort < kParamPortBase {
                if let k = kinds[c.toNode], let m = remap[k], let to = m[c.toPort] { p.cables[i].toPort = to }
            }
        }
        if version < 8 {
            // v8: div~'s internal clock list gained 1/64 at the front.
            for i in p.nodes.indices where p.nodes[i].kind == "div" {
                if let b = p.nodes[i].params["base"] { p.nodes[i].params["base"] = b + 1 }
            }
        }
        if version < 10 {
            // v10: clock~ starts internal (was external); one whose clock inlet is patched stays external
            for i in p.nodes.indices where p.nodes[i].kind == "clock" && p.nodes[i].params["source"] == nil {
                let id = p.nodes[i].id
                if p.cables.contains(where: { $0.toNode == id && $0.toPort == 0 }) { p.nodes[i].params["source"] = 0 }
            }
        }
        if version < 11 {
            // v11: roll~ holds chords — its one-note-per-step "notes" became a note grid
            for i in p.nodes.indices where p.nodes[i].kind == "roll" {
                if let old = p.nodes[i].data["notes"], p.nodes[i].data["grid"] == nil {
                    p.nodes[i].data["grid"] = RollNode.grid(fromNotes: old)
                }
                p.nodes[i].data["notes"] = nil
            }
        }
        if version < 12 {
            // v12: a chord travels on one pitch / gate cable. 0.3's extra voice outlets (roll~ pitch 2 …,
            // chord~ pitch 2 …) and the synths' extra voice inlets / "voices" setting are gone.
            let kinds = Dictionary(p.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
            p.cables.removeAll { c in
                switch kinds[c.fromNode] {
                case "roll" where c.fromPort >= 3: return true
                case "chord" where c.fromPort >= 2: return true
                default: break
                }
                switch kinds[c.toNode] {
                case "wave", "shapes": return (c.toPort >= 2 && c.toPort < kParamPortBase) || c.toPort == kParamPortBase + 7
                case "macro": return (c.toPort >= 3 && c.toPort < kParamPortBase) || c.toPort == kParamPortBase + 9
                default: return false
                }
            }
            for i in p.nodes.indices where ["wave", "shapes", "macro"].contains(p.nodes[i].kind) { p.nodes[i].params["voices"] = nil }
        }
        if version < 9 {
            // v9: div~ outlets became a ×16 … ÷64 list; old ÷n (default ÷k on outlet k) keeps its meaning.
            for i in p.nodes.indices where p.nodes[i].kind == "div" {
                for k in 1...DividerLayout.outputs {
                    let old = p.nodes[i].params["d\(k)"] ?? Float(k)
                    let n = old.isFinite ? min(max(Int(old.rounded()), 1), 64) : k
                    p.nodes[i].params["d\(k)"] = Float(DividerLayout.ratioIndex(n))
                }
            }
        }
        return p
    }

    private func migrateV1() -> Patch {
        var p = self
        for (i, n) in p.nodes.enumerated() {
            if n.kind == "in", let ch = n.params["ch"] {
                let port = max(Int(ch.rounded()) - 1, 0)
                for k in p.cables.indices where p.cables[k].fromNode == n.id && p.cables[k].fromPort == 0 {
                    p.cables[k].fromPort = port
                }
                p.nodes[i].params = [:]
            } else if n.kind == "out", n.params["chL"] != nil || n.params["chR"] != nil {
                let l = max(Int((n.params["chL"] ?? 1).rounded()) - 1, 0)
                let r = max(Int((n.params["chR"] ?? 2).rounded()) - 1, 0)
                for k in p.cables.indices where p.cables[k].toNode == n.id {
                    if p.cables[k].toPort == 0 { p.cables[k].toPort = l }
                    else if p.cables[k].toPort == 1 { p.cables[k].toPort = r }
                }
                p.nodes[i].params = n.params.filter { $0.key == "gain" }
            }
        }
        p.version = 2
        return p
    }
}

public extension Patch {
    /// Swap box `id` for a new module of `kind` in the same place. Settings with the same name carry over;
    /// cables reconnect to the inlet / outlet / parameter with the same name — or, for audio ports, the
    /// same position — and are dropped when the new module has nothing to plug them into.
    func replacing(_ id: UUID, with kind: String) -> (patch: Patch, newID: UUID)? {
        guard let i = index(of: id), let oldSpec = ModuleRegistry.spec(nodes[i].kind),
              let newSpec = ModuleRegistry.spec(kind) else { return nil }
        let old = nodes[i]
        var n = PatchNode(kind: kind, x: old.x, y: old.y)
        n.collapsed = old.collapsed
        for ps in newSpec.params where !ps.isTrigger {
            if let v = old.params[ps.key] { n.params[ps.key] = min(max(v, ps.min), ps.max) }
        }
        var p = self
        p.nodes[i] = n
        func mapPort(_ port: Int, input: Bool) -> Int? {
            if port >= kParamPortBase {
                let k = port - kParamPortBase
                guard k < oldSpec.params.count, let j = newSpec.paramIndex(oldSpec.params[k].key) else { return nil }
                return kParamPortBase + j
            }
            let oldNames = input ? oldSpec.inputs : oldSpec.outputs, newNames = input ? newSpec.inputs : newSpec.outputs
            if port < oldNames.count, let j = newNames.firstIndex(of: oldNames[port]) { return j }
            return port < newNames.count ? port : nil
        }
        var cables: [PatchCable] = []
        for var c in p.cables {
            if c.toNode == id {
                guard let to = mapPort(c.toPort, input: true) else { continue }
                c.toNode = n.id; c.toPort = to
            }
            if c.fromNode == id {
                guard let from = mapPort(c.fromPort, input: false) else { continue }
                c.fromNode = n.id; c.fromPort = from
            }
            // no duplicates (two old ports landing on the same new one)
            if !cables.contains(where: { $0.fromNode == c.fromNode && $0.fromPort == c.fromPort && $0.toNode == c.toNode && $0.toPort == c.toPort }) {
                cables.append(c)
            }
        }
        p.cables = cables
        if let gs = p.groups {           // the new box stays in the old one's group
            p.groups = gs.map { g -> PatchGroup in var g = g; g.members = g.members.map { $0 == id ? n.id : $0 }; return g }
        }
        return (p, n.id)
    }
}

public extension Patch {
    /// The same patch with new box / cable / group IDs (so a copy never shares audio files with the
    /// original). `map` tells which old box became which new one.
    func withFreshIDs() -> (patch: Patch, map: [UUID: UUID]) {
        var p = self
        var map: [UUID: UUID] = [:]
        for i in p.nodes.indices { let n = UUID(); map[p.nodes[i].id] = n; p.nodes[i].id = n }
        p.cables = p.cables.compactMap { c in
            guard let a = map[c.fromNode], let b = map[c.toNode] else { return nil }
            return PatchCable(fromNode: a, fromPort: c.fromPort, toNode: b, toPort: c.toPort)
        }
        p.groups = p.groups?.map { g in PatchGroup(name: g.name, members: g.members.compactMap { map[$0] }) }
        return (p, map)
    }
}
