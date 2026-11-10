import Foundation
import PoljeNieukCore

/// Geometry self-check for every module's box (used by the self-test): every drawn port, parameter row
/// and display must sit inside the box, in every state — default, collapsed with cables, resized, and with
/// the variable-size modules at their largest settings.
@MainActor
public enum LayoutCheck {
    public static func run() -> [String] {
        var problems: [String] = []
        let hw = HardwareCounts(inputs: 12, outputs: 8)
        let saved = BoxLayout.usage
        defer { BoxLayout.usage = saved }

        for spec in ModuleRegistry.all where spec.kind != "text" {   // free text has no frame
            var variants: [(String, PatchNode)] = []
            let base = PatchNode(kind: spec.kind, x: 100, y: 100)
            variants.append(("default", base))
            var big = base; big.w = 900; big.dh = 700
            variants.append(("resized", big))
            var tiny = base; tiny.w = 10; tiny.dh = 1
            variants.append(("shrunk", tiny))
            // the largest settings of modules whose box grows with a parameter
            for (key, v) in [("chans", Float(3)), ("count", Float(5)), ("bands", Float(2)), ("pans", Float(1))]
            where spec.paramIndex(key) != nil {
                var n = base; n.params[key] = v
                variants.append(("\(key)=\(v)", n))
            }
            for (label, node) in variants {
                for collapsed in [false, true] {
                    var n = node; n.collapsed = collapsed
                    // everything patched: every inlet, outlet and parameter has a cable
                    var u = PortUsage()
                    u.ins = Set(spec.inputs.indices).union(spec.params.indices.map { kParamPortBase + $0 })
                    u.outs = Set(spec.outputs.indices)
                    for patched in [false, true] {
                        BoxLayout.usage = patched ? [n.id: u] : [:]
                        problems += check(spec, n, hw, "\(spec.name) \(label)\(collapsed ? " collapsed" : "")\(patched ? " patched" : "")")
                    }
                }
            }
        }
        return problems
    }

    private static func check(_ spec: ModuleSpec, _ n: PatchNode, _ hw: HardwareCounts, _ what: String) -> [String] {
        var out: [String] = []
        let h = BoxLayout.height(n, spec, hw), w = BoxLayout.width(n)
        guard h.isFinite, w.isFinite, h > 0, w > 0 else { return ["\(what): box size \(w)×\(h)"] }
        if w < BoxLayout.width(n.kind) { out.append("\(what): narrower than default") }
        var seen: [String: CGFloat] = [:]
        for p in BoxLayout.visiblePorts(n, spec, hw) {
            let ly = p.point.y - n.y, lx = p.point.x - n.x
            if ly < 0 || ly > h + 0.5 { out.append("\(what): port \(p.name) at y \(Int(ly)) outside 0…\(Int(h))") }
            if abs(lx) > 0.5 && abs(lx - w) > 0.5 { out.append("\(what): port \(p.name) not on an edge (x \(Int(lx)))") }
            let key = "\(p.output)-\(Int(ly.rounded()))"
            if let other = seen[key], other == ly, !n.collapsed {
                out.append("\(what): two \(p.output ? "outlets" : "inlets") on top of each other at y \(Int(ly))")
            }
            seen[key] = ly
        }
        if !n.collapsed {
            // display + param rows must fit
            let rows = BoxLayout.rowParams(spec, n).count + (BoxLayout.hasTriggerRow(spec) ? 1 : 0)
            let need = BoxLayout.header + BoxLayout.bodyHeight(n, spec, hw)
                + (rows > 0 ? CGFloat(rows) * BoxLayout.row : 0)
            if need > h + 1 { out.append("\(what): contents \(Int(need)) taller than box \(Int(h))") }
            for i in BoxLayout.rowParams(spec, n) {
                if let y = BoxLayout.paramRowY(n, spec, hw, i), y > h { out.append("\(what): row \(spec.params[i].name) below the box") }
            }
        }
        return out
    }
}
