import CoreGraphics
import Foundation
import PoljeNieukCore

/// The "tidy" layout: signal flows left → right in columns, each chain keeps its order all the way to the
/// mixer, boxes are lined up with what they connect to so cables run as straight as possible, controllers
/// (knob / slider / an LFO that only moves parameters) sit in a row above what they control, unpatched
/// boxes wait in a row underneath, and text notes travel with the box they were next to.
@MainActor public enum TidyLayout {
    static let grid: CGFloat = 24
    static let colGap: CGFloat = 72
    static let rowGap: CGFloat = 36
    static let origin = CGPoint(x: 48, y: 48)

    public static func layout(_ patch: Patch, inputs: Int, outputs: Int) -> [UUID: CGPoint] {
        layout(patch, HardwareCounts(inputs: inputs, outputs: outputs))
    }

    static func layout(_ patch: Patch, _ hw: HardwareCounts) -> [UUID: CGPoint] {
        let nodes = patch.nodes.filter { ModuleRegistry.spec($0.kind) != nil }
        guard !nodes.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let spec = { (n: PatchNode) in ModuleRegistry.spec(n.kind)! }
        func size(_ n: PatchNode) -> CGSize { CGSize(width: BoxLayout.width(n), height: BoxLayout.height(n, spec(n), hw)) }
        func outY(_ n: PatchNode, _ port: Int) -> CGFloat { BoxLayout.outlet(n, spec(n), hw, port).y - CGFloat(n.y) }
        func inY(_ n: PatchNode, _ port: Int) -> CGFloat {
            (BoxLayout.destination(n, spec(n), hw, port: port)?.y ?? CGFloat(n.y) + BoxLayout.header) - CGFloat(n.y)
        }

        let cables = patch.cables.filter { $0.fromNode != $0.toNode && byID[$0.fromNode] != nil && byID[$0.toNode] != nil }
        let texts = nodes.filter { $0.kind == "text" }
        let boxes = nodes.filter { $0.kind != "text" }
        let wired = Set(cables.flatMap { [$0.fromNode, $0.toNode] })
        // controllers: only send into parameters, nothing comes in (knobs, faders, a free LFO …)
        let controllers = boxes.filter { n in
            let outs = cables.filter { $0.fromNode == n.id }, ins = cables.filter { $0.toNode == n.id }
            return !outs.isEmpty && ins.isEmpty && outs.allSatisfy { $0.toPort >= kParamPortBase } && n.kind != "in"
        }
        let ctlIDs = Set(controllers.map(\.id))
        let loose = boxes.filter { !wired.contains($0.id) }
        let flowNodes = boxes.filter { wired.contains($0.id) && !ctlIDs.contains($0.id) }
        let flowIDs = Set(flowNodes.map(\.id))
        var edges = cables.filter { flowIDs.contains($0.fromNode) && flowIDs.contains($0.toNode) }

        // 1. break feedback loops (drop the edges that point back up a depth-first walk)
        do {
            var state: [UUID: Int] = [:]           // 1 = on the stack, 2 = done
            var back = Set<UUID>()
            let outs = Dictionary(grouping: edges, by: \.fromNode)
            func visit(_ id: UUID) {
                state[id] = 1
                for e in outs[id] ?? [] {
                    switch state[e.toNode] {
                    case 1: back.insert(e.id)
                    case nil: visit(e.toNode)
                    default: break
                    }
                }
                state[id] = 2
            }
            for n in flowNodes.sorted(by: { $0.x < $1.x }) where state[n.id] == nil { visit(n.id) }
            edges.removeAll { back.contains($0.id) }
        }
        let succ = Dictionary(grouping: edges, by: \.fromNode)
        let pred = Dictionary(grouping: edges, by: \.toNode)

        // 2. columns: longest path from the sources, then sources slide right next to what they feed
        var layer: [UUID: Int] = [:]
        func longest(_ id: UUID) -> Int {
            if let l = layer[id] { return l }
            let l = (pred[id] ?? []).map { longest($0.fromNode) + 1 }.max() ?? 0
            layer[id] = l
            return l
        }
        for n in flowNodes { _ = longest(n.id) }
        let order = flowNodes.map(\.id).sorted { layer[$0]! > layer[$1]! }
        for id in order where !(succ[id] ?? []).isEmpty && byID[id]!.kind != "in" {
            layer[id] = (succ[id] ?? []).map { layer[$0.toNode]! - 1 }.min()!
        }
        let last = (layer.values.max() ?? 0)
        for n in flowNodes where n.kind == "out" { layer[n.id] = max(last, 1) }
        for n in flowNodes where n.kind == "in" { layer[n.id] = 0 }
        let minL = layer.values.min() ?? 0
        for k in layer.keys { layer[k]! -= minL }
        let nLayers = (layer.values.max() ?? 0) + 1

        // 3. order inside each column: walk back from the outputs, taking each box's inputs in inlet order,
        //    so every chain keeps its place all the way to the mixer
        var rank: [UUID: Int] = [:]
        var counter = 0
        func walk(_ id: UUID) {
            guard rank[id] == nil else { return }
            rank[id] = counter; counter += 1
            let ins = (pred[id] ?? []).sorted { a, b in
                // audio / gate inlets top to bottom, then parameter inlets
                (a.toPort, byID[a.fromNode]!.y) < (b.toPort, byID[b.fromNode]!.y)
            }
            for e in ins { walk(e.fromNode) }
        }
        let sinks = flowNodes.filter { (succ[$0.id] ?? []).isEmpty }
            .sorted { ($0.kind == "out" ? 0 : 1, $0.y) < ($1.kind == "out" ? 0 : 1, $1.y) }
        for s in sinks { walk(s.id) }
        for n in flowNodes.sorted(by: { $0.y < $1.y }) { walk(n.id) }
        var cols = [[UUID]](repeating: [], count: nLayers)
        for n in flowNodes { cols[layer[n.id]!].append(n.id) }
        for c in cols.indices { cols[c].sort { rank[$0]! < rank[$1]! } }

        // 4. column x positions
        var colX = [CGFloat](repeating: origin.x, count: nLayers)
        var x = origin.x
        for c in 0..<nLayers {
            colX[c] = x
            x += (cols[c].map { size(byID[$0]!).width }.max() ?? 0) + colGap
        }

        // 5. controllers: a row along the top, each above the column it controls
        var pos: [UUID: CGPoint] = [:]
        var ctlBottom = origin.y
        do {
            func targetX(_ n: PatchNode) -> CGFloat {
                let xs = cables.filter { $0.fromNode == n.id }.compactMap { layer[$0.toNode].map { colX[$0] } }
                return xs.isEmpty ? origin.x : xs.reduce(0, +) / CGFloat(xs.count)
            }
            var right = origin.x - colGap
            for n in controllers.sorted(by: { targetX($0) < targetX($1) }) {
                let px = max(targetX(n), right + colGap / 2)
                pos[n.id] = CGPoint(x: px, y: origin.y)
                right = px + size(n).width
                ctlBottom = max(ctlBottom, origin.y + size(n).height)
            }
        }
        let top = controllers.isEmpty ? origin.y : ctlBottom + rowGap * 2

        // 6. heights: stack, then sweep right ← and left → so each box lines up with what it connects to
        var y: [UUID: CGFloat] = [:]
        for col in cols {
            var yy = top
            for id in col { y[id] = yy; yy += size(byID[id]!).height + rowGap }
        }
        func settle(_ col: [UUID], _ want: [UUID: CGFloat]) {
            // keep the order, no overlaps; push down where needed, then pull back up where there's room
            var placed: [CGFloat] = []
            for (k, id) in col.enumerated() {
                var v = want[id] ?? y[id]!
                if k > 0 { v = max(v, placed[k - 1] + size(byID[col[k - 1]]!).height + rowGap) }
                placed.append(max(v, top))
            }
            for k in stride(from: col.count - 2, through: 0, by: -1) {
                let limit = placed[k + 1] - size(byID[col[k]]!).height - rowGap
                let w = want[col[k]] ?? placed[k]
                if placed[k] > w && limit > placed[k] - 0.5 { placed[k] = max(min(limit, placed[k]), max(w, top)) }
            }
            for (k, id) in col.enumerated() { y[id] = placed[k] }
        }
        for _ in 0..<6 {
            for c in stride(from: nLayers - 2, through: 0, by: -1) {      // line up with what each box feeds
                var want: [UUID: CGFloat] = [:]
                for id in cols[c] {
                    let es = succ[id] ?? []
                    guard !es.isEmpty else { continue }
                    let n = byID[id]!
                    let t = es.map { e in y[e.toNode]! + inY(byID[e.toNode]!, e.toPort) - outY(n, e.fromPort) }
                    want[id] = t.reduce(0, +) / CGFloat(t.count)
                }
                settle(cols[c], want)
            }
            for c in 1..<max(nLayers, 1) {                                   // … and with what feeds it
                var want: [UUID: CGFloat] = [:]
                for id in cols[c] {
                    let es = (pred[id] ?? []).filter { $0.toPort < kParamPortBase }
                    guard !es.isEmpty else { continue }
                    let n = byID[id]!
                    let t = es.map { e in y[e.fromNode]! + outY(byID[e.fromNode]!, e.fromPort) - inY(n, e.toPort) }
                    want[id] = t.reduce(0, +) / CGFloat(t.count)
                }
                settle(cols[c], want)
            }
            // the passes only ever push down: lift the whole graph back so its top box sits at the top
            if let lowest = y.values.min(), lowest > top { for k in y.keys { y[k]! -= lowest - top } }
        }
        for c in 0..<nLayers { for id in cols[c] { pos[id] = CGPoint(x: colX[c], y: y[id]!) } }

        // 7. unpatched boxes: a row underneath
        let graphBottom = pos.compactMap { id, p in byID[id].map { p.y + size($0).height } }.max() ?? top
        var lx = origin.x
        let ly = (flowNodes.isEmpty && controllers.isEmpty) ? origin.y : graphBottom + rowGap * 2
        for n in loose.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            pos[n.id] = CGPoint(x: lx, y: ly)
            lx += size(n).width + colGap / 2
        }

        // 8. snap to the grid
        func snap(_ v: CGFloat) -> CGFloat { (v / grid).rounded() * grid }
        for (id, p) in pos { pos[id] = CGPoint(x: snap(p.x), y: snap(p.y)) }

        // 9. text notes keep their spot beside the box they were nearest to
        for t in texts {
            let tp = CGPoint(x: t.x, y: t.y)
            let near = boxes.min { a, b in
                dist(tp, rect(a, size(a))) < dist(tp, rect(b, size(b)))
            }
            if let near, let np = pos[near.id] {
                pos[t.id] = CGPoint(x: np.x + (tp.x - near.x), y: np.y + (tp.y - near.y))
            } else {
                pos[t.id] = tp
            }
        }
        return pos
    }

    public static func boxSize(_ n: PatchNode, inputs: Int, outputs: Int) -> CGSize {
        guard let s = ModuleRegistry.spec(n.kind) else { return .zero }
        return CGSize(width: BoxLayout.width(n), height: BoxLayout.height(n, s, HardwareCounts(inputs: inputs, outputs: outputs)))
    }

    private static func rect(_ n: PatchNode, _ s: CGSize) -> CGRect { CGRect(x: n.x, y: n.y, width: s.width, height: s.height) }
    private static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: measuring a layout (self-test)

    /// Cable crossings (straight segments between port points) and overlapping boxes, for a set of positions.
    public static func quality(_ patch: Patch, _ pos: [UUID: CGPoint], inputs: Int, outputs: Int) -> (crossings: Int, overlaps: Int) {
        let hw = HardwareCounts(inputs: inputs, outputs: outputs)
        var p = patch
        for i in p.nodes.indices { if let q = pos[p.nodes[i].id] { p.nodes[i].x = q.x; p.nodes[i].y = q.y } }
        let byID = Dictionary(uniqueKeysWithValues: p.nodes.map { ($0.id, $0) })
        var segs: [(CGPoint, CGPoint, UUID, UUID)] = []
        for c in p.cables {
            guard let a = byID[c.fromNode], let b = byID[c.toNode], let sa = ModuleRegistry.spec(a.kind),
                  let sb = ModuleRegistry.spec(b.kind), let d = BoxLayout.destination(b, sb, hw, port: c.toPort) else { continue }
            segs.append((BoxLayout.outlet(a, sa, hw, c.fromPort), d, a.id, b.id))
        }
        func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var crossings = 0
        for i in segs.indices {
            for j in segs.indices where j > i {
                let (a, b, a1, a2) = segs[i], (c, d, b1, b2) = segs[j]
                if a1 == b1 || a1 == b2 || a2 == b1 || a2 == b2 { continue }     // sharing a box isn't a crossing
                if ccw(a, b, c) * ccw(a, b, d) < 0 && ccw(c, d, a) * ccw(c, d, b) < 0 { crossings += 1 }
            }
        }
        let boxes = p.nodes.filter { $0.kind != "text" }.compactMap { n -> CGRect? in
            guard let s = ModuleRegistry.spec(n.kind) else { return nil }
            return CGRect(x: n.x, y: n.y, width: BoxLayout.width(n), height: BoxLayout.height(n, s, hw))
        }
        var overlaps = 0
        for i in boxes.indices { for j in boxes.indices where j > i && boxes[i].insetBy(dx: 1, dy: 1).intersects(boxes[j].insetBy(dx: 1, dy: 1)) { overlaps += 1 } }
        return (crossings, overlaps)
    }
}
