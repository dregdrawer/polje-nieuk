import SwiftUI
import CoreText
import PoljeNieukCore

// The boxes on the 2D canvas are drawn the way Max or Pure Data draw theirs: plain drawing calls (rectangles,
// text, circles) at the exact zoom, every time the zoom changes — never a stretched picture, so nothing jumps
// or blurs. This file says where everything in a box is (`BoxGeo`) and draws the parts of a box that only
// change when its settings do (`BoxPainter`). Displays that move (meters, playheads, modulated rows) are
// `LivePart`s: small layers of their own, redrawn by the tick only when what they show changes.

/// A pointer press, as the boxes see it.
struct PointerInfo {
    var clickCount = 1
    var shift = false
    var option = false
    var command = false
    var right = false
    /// where it went down (box points)
    var start: CGPoint = .zero
    /// moved past the drag threshold
    var moved = false
    /// a finger or the Pencil (not a mouse)
    var touch = false
}

/// One entry of a native menu (choice rows, the audio menu, rack pads).
struct MenuItem {
    var title: String
    var checked = false
    var enabled = true
    var header = false          // a section title
    var separator = false
    var action: (() -> Void)?
    static let divider = MenuItem(title: "", separator: true)
    static func section(_ t: String) -> MenuItem { MenuItem(title: t, enabled: false, header: true) }
}

/// A part of a box that moves on its own (a display, a live row, a meter): its own layer, redrawn by the
/// tick when `signature` changes (every tick when there's none).
struct LivePart {
    var key: String
    /// box points
    var rect: CGRect
    var every = 1
    var smooth = false
    var dimmed = false
    var signature: (() -> Int)?
    var draw: (LiveGC, CGSize) -> Void
}

/// Text width for the native drawing (monospaced system font, as LiveText draws it).
@MainActor func textWidth(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
    guard !s.isEmpty else { return 0 }
    let line = LiveColor.line(LiveText(s, size: size, color: Theme.text, bold: bold))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Cut `s` to fit `width` (with an ellipsis).
@MainActor func fitText(_ s: String, size: CGFloat, width: CGFloat, bold: Bool = false) -> String {
    if textWidth(s, size: size, bold: bold) <= width { return s }
    var t = s
    while t.count > 1 && textWidth(t + "…", size: size, bold: bold) > width { t.removeLast() }
    return t + "…"
}

// MARK: - Where things are

@MainActor struct BoxGeo {
    enum Button: Hashable { case bypass, clearPattern, autoRec, resetAuto, audioMenu, close, collapse }

    let node: PatchNode
    let spec: ModuleSpec
    let hw: HardwareCounts
    let w: CGFloat, h: CGFloat
    let buttons: [(Button, CGRect)]
    let titleRect: CGRect

    init(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, selected: Bool, model: AppModel) {
        self.node = node; self.spec = spec; self.hw = hw
        w = BoxLayout.width(node); h = BoxLayout.height(node, spec, hw)
        var b: [(Button, CGRect)] = []
        if spec.bypass != .none { b.append((.bypass, CGRect(x: 6, y: 2, width: 18, height: 18))) }
        // the right-hand buttons, from the right edge in
        var right: [(Button, CGFloat)] = [(.close, 18), (.collapse, 18)]      // ✕ always, at the very right
        if model.node(node.id) is SampleBufferNode { right.append((.audioMenu, 18)) }
        if model.canAutomate(spec) && !node.collapsed {
            if model.hasAutomation(node) { right.append((.resetAuto, 15)) }
            right.append((.autoRec, 15))
        }
        if AppModel.patternKinds.contains(node.kind) && !node.collapsed { right.append((.clearPattern, 15)) }
        var x = w - 4
        var leftmost = x
        for (k, (btn, bw)) in right.enumerated() {
            if k > 0 { x -= 6 }
            x -= bw
            b.append((btn, CGRect(x: x, y: 2, width: bw, height: 18)))
            leftmost = x
        }
        buttons = b
        let tx: CGFloat = spec.bypass != .none ? 30 : 10
        titleRect = CGRect(x: tx, y: 0, width: max(leftmost - 6 - tx, 0), height: BoxLayout.header)
    }

    var header: CGRect { CGRect(x: 0, y: 0, width: w, height: BoxLayout.header) }

    /// The inlet / outlet label rows (empty space there moves the box).
    var portRows: CGRect? {
        if node.collapsed {
            let r = BoxLayout.collapsedRows(node, spec)
            return r > 0 ? CGRect(x: 0, y: BoxLayout.header, width: w, height: CGFloat(r) * BoxLayout.portRow + 6) : nil
        }
        let r = BoxLayout.portRows(node, spec, hw)
        return r > 0 ? CGRect(x: 0, y: BoxLayout.header, width: w, height: CGFloat(r) * BoxLayout.portRow + 6) : nil
    }

    /// The module's own display (waveform, grid, curve …), before its own padding.
    var display: CGRect? {
        let dh = BoxLayout.readoutHeight(node)
        guard BoxLayout.hasReadout(spec.kind), dh > 0 else { return nil }
        if node.collapsed {
            let r = BoxLayout.collapsedRows(node, spec)
            return CGRect(x: 10, y: BoxLayout.header + (r > 0 ? CGFloat(r) * BoxLayout.portRow + 6 : 0), width: w - 20, height: dh)
        }
        if BoxLayout.sideDisplay(spec.kind) {
            return CGRect(x: 10, y: BoxLayout.header, width: max(w - 20 - BoxLayout.sideOutletColumn, 10), height: dh)
        }
        return CGRect(x: 10, y: BoxLayout.header + BoxLayout.portsHeight(node, spec, hw), width: w - 20, height: dh)
    }

    private var paramsTop: CGFloat { BoxLayout.header + BoxLayout.bodyHeight(node, spec, hw) + 2 }

    /// Trigger buttons (one row above the parameters).
    var triggers: [(Int, CGRect)] {
        guard !node.collapsed else { return [] }
        let t = spec.params.indices.filter { spec.params[$0].isTrigger }
        guard !t.isEmpty else { return [] }
        let full = w - 16, gap: CGFloat = 4
        let bw = (full - gap * CGFloat(t.count - 1)) / CGFloat(t.count)
        return t.enumerated().map { k, i in (i, CGRect(x: 8 + CGFloat(k) * (bw + gap), y: paramsTop, width: bw, height: BoxLayout.row - 3)) }
    }

    /// Parameter rows: index → rect.
    var rows: [(Int, CGRect)] {
        guard !node.collapsed else { return [] }
        let off = BoxLayout.hasTriggerRow(spec) ? 1 : 0
        return BoxLayout.rowParams(spec, node).enumerated().map { k, i in
            (i, CGRect(x: 8, y: paramsTop + CGFloat(k + off) * BoxLayout.row, width: w - 16, height: BoxLayout.row - 3))
        }
    }

    var grip: CGRect? {
        guard !node.collapsed else { return nil }
        let can = BoxLayout.resizable(node.kind)
        return can.width || can.height ? CGRect(x: w - 22, y: h - 22, width: 22, height: 22) : nil
    }

    struct Port { let port: Int; let output: Bool; let center: CGPoint; let size: CGFloat }
    /// Every port circle drawn on the box.
    var ports: [Port] {
        var r: [Port] = []
        let p = BoxLayout.ports(node, spec, hw)
        if node.collapsed {
            for i in BoxLayout.collapsedLeft(node, spec) {
                if i >= kParamPortBase {
                    if let y = BoxLayout.paramRowY(node, spec, hw, i - kParamPortBase) {
                        r.append(Port(port: i, output: false, center: CGPoint(x: 0, y: y), size: BoxLayout.paramPort))
                    }
                } else {
                    r.append(Port(port: i, output: false, center: CGPoint(x: 0, y: BoxLayout.inlet(node, spec, hw, i).y - node.y), size: BoxLayout.port))
                }
            }
            for i in BoxLayout.collapsedRight(node, spec) {
                r.append(Port(port: i, output: true, center: CGPoint(x: w, y: BoxLayout.outlet(node, spec, hw, i).y - node.y), size: BoxLayout.port))
            }
            return r
        }
        for i in p.ins.indices {
            r.append(Port(port: i, output: false, center: CGPoint(x: 0, y: BoxLayout.inlet(node, spec, hw, i).y - node.y), size: BoxLayout.port))
        }
        for i in p.outs.indices {
            r.append(Port(port: i, output: true, center: CGPoint(x: w, y: BoxLayout.outlet(node, spec, hw, i).y - node.y), size: BoxLayout.port))
        }
        for i in BoxLayout.rowParams(spec, node) {
            if let y = BoxLayout.paramRowY(node, spec, hw, i) {
                r.append(Port(port: kParamPortBase + i, output: false, center: CGPoint(x: 0, y: y), size: BoxLayout.paramPort))
            }
        }
        return r
    }

    /// The port whose touch area (22 × 18, as before) holds `p`, nearest first.
    func port(at p: CGPoint) -> Port? {
        ports.filter { abs($0.center.x - p.x) <= 11 && abs($0.center.y - p.y) <= 9 }
            .min { hypot($0.center.x - p.x, $0.center.y - p.y) < hypot($1.center.x - p.x, $1.center.y - p.y) }
    }
}

// MARK: - Drawing what changes only with the settings

@MainActor enum BoxPainter {
    /// Everything of a module box except its live parts.
    static func paint(_ g: LiveGC, _ geo: BoxGeo, model: AppModel, selected: Bool, dropTarget: Bool,
                      liveRows: Set<Int>, display: NativeDisplay?) {
        let node = geo.node, spec = geo.spec, w = geo.w, h = geo.h
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        g.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.box))
        g.stroke(Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(selected ? Theme.selected : Theme.border), lineWidth: 1)
        header(g, geo, model: model)
        if !node.collapsed {
            g.fill(Path(CGRect(x: 0, y: BoxLayout.header - 1, width: w, height: 1)), with: .color(Theme.border.opacity(0.6)))
        }
        // the body: dimmed when the box is switched off
        g.dimmed(node.bypassed ? 0.35 : 1) { g in
            if node.collapsed {
                collapsedRows(g, geo)
            } else {
                portRows(g, geo, model: model)
                for (i, r) in geo.triggers { trigger(g, r, spec.params[i]) }
                for (i, r) in geo.rows where !liveRows.contains(i) {
                    let ps = spec.params[i]
                    paramRow(g, r, ps, value: model.value(node, i, spec))
                }
            }
            if let d = geo.display, let display { display.paintStatic(g, d) }
        }
        ports(g, geo, model: model)
        if let r = geo.grip {
            g.fill(Path(ellipseIn: CGRect(x: r.maxX - 7, y: r.maxY - 7, width: 3, height: 3)), with: .color(Theme.dim))
        }
        if dropTarget {
            g.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.text.opacity(0.06)))
            g.stroke(Path(roundedRect: box.insetBy(dx: 1, dy: 1), cornerRadius: 3), with: .color(Theme.text), lineWidth: 2)
        }
    }

    private static func header(_ g: LiveGC, _ geo: BoxGeo, model: AppModel) {
        let node = geo.node
        let mid = BoxLayout.header / 2
        for (b, r) in geo.buttons {
            let c = CGPoint(x: r.midX, y: r.midY)
            switch b {
            case .bypass:
                let dot = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
                if !node.bypassed { g.fill(Path(ellipseIn: dot), with: .color(Theme.text)) }
                g.stroke(Path(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5)), with: .color(node.bypassed ? Theme.dim : Theme.text), lineWidth: 1)
            case .collapse: Icons.dash(g, c)
            case .close: Icons.xmark(g, c)
            case .audioMenu: Icons.waveform(g, c)
            case .resetAuto: Icons.resetArrow(g, c)
            case .clearPattern: Icons.trash(g, c)
            case .autoRec:
                let on = model.autoRecording.contains(node.id)
                let ring = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
                if on { g.fill(Path(ellipseIn: ring), with: .color(Theme.rec)) }
                g.stroke(Path(ellipseIn: ring.insetBy(dx: 0.5, dy: 0.5)), with: .color(on ? Theme.rec : Theme.dim), lineWidth: 1)
                g.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)),
                       with: .color(on ? Color.white.opacity(0.9) : Theme.dim))
            }
        }
        let t = geo.titleRect
        let name = fitText(geo.spec.name, size: 11, width: t.width, bold: true)
        g.draw(LiveText(name, size: 11, color: node.bypassed ? Theme.dim : Theme.text, bold: true), at: CGPoint(x: t.minX, y: mid), anchor: .leading)
        if node.bypassed {
            let tw = textWidth(name, size: 11, bold: true)
            g.fill(Path(CGRect(x: t.minX, y: mid, width: tw, height: 1)), with: .color(Theme.dim))
        }
    }

    private static func portRows(_ g: LiveGC, _ geo: BoxGeo, model: AppModel) {
        let node = geo.node
        let p = BoxLayout.ports(node, geo.spec, geo.hw)
        let rows = BoxLayout.portRows(node, geo.spec, geo.hw)
        let outLabels = !BoxLayout.rowOutlets(node.kind)
        for r in 0..<rows {
            let y = BoxLayout.header + 3 + CGFloat(r) * BoxLayout.portRow + BoxLayout.portRow / 2
            if r < p.ins.count { g.draw(LiveText(p.ins[r], size: 9, color: Theme.dim), at: CGPoint(x: 10, y: y), anchor: .leading) }
            if outLabels && r < p.outs.count { g.draw(LiveText(p.outs[r], size: 9, color: Theme.dim), at: CGPoint(x: geo.w - 10, y: y), anchor: .trailing) }
        }
    }

    /// Where the meter sits in port row `r` (in~ / out~ channels, mixer inputs).
    static func meterRect(_ geo: BoxGeo, _ r: Int) -> CGRect {
        let p = BoxLayout.ports(geo.node, geo.spec, geo.hw)
        let y = BoxLayout.header + 3 + CGFloat(r) * BoxLayout.portRow + BoxLayout.portRow / 2
        let l = r < p.ins.count ? textWidth(p.ins[r], size: 9) : 0
        let rr = r < p.outs.count && !BoxLayout.rowOutlets(geo.node.kind) ? textWidth(p.outs[r], size: 9) : 0
        let x0 = 10 + l + 6, x1 = geo.w - 10 - rr - 6
        return CGRect(x: x0, y: y - 2, width: max(x1 - x0, 0), height: 4)
    }

    private static func collapsedRows(_ g: LiveGC, _ geo: BoxGeo) {
        let node = geo.node, spec = geo.spec
        let left = BoxLayout.collapsedLeft(node, spec), right = BoxLayout.collapsedRight(node, spec)
        for r in 0..<max(left.count, right.count) {
            let y = BoxLayout.header + 3 + CGFloat(r) * BoxLayout.portRow + BoxLayout.portRow / 2
            if r < left.count { g.draw(LiveText(BoxLayout.inletName(spec, left[r]), size: 9, color: Theme.dim), at: CGPoint(x: 10, y: y), anchor: .leading) }
            if r < right.count { g.draw(LiveText(spec.outputs[right[r]], size: 9, color: Theme.dim), at: CGPoint(x: geo.w - 10, y: y), anchor: .trailing) }
        }
    }

    static func trigger(_ g: LiveGC, _ r: CGRect, _ ps: ParamSpec) {
        g.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.row))
        g.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(Theme.border), lineWidth: 1)
        g.draw(LiveText(ps.name, size: 9, color: ps.key == "rec" ? Theme.rec : Theme.text, bold: true), at: CGPoint(x: r.midX, y: r.midY))
    }

    /// A number-box row: the bar, the name and the value (choice rows get their ▾).
    static func paramRow(_ g: LiveGC, _ r: CGRect, _ ps: ParamSpec, value: Float) {
        var fill = CGFloat(ps.normalized(value)), text = ps.display(value), recOn = false
        var trailing: CGFloat = 0
        switch ps.kind {
        case .toggle:
            fill = value > 0.5 ? 1 : 0; text = value > 0.5 ? "on" : "off"; recOn = value > 0.5 && ps.key == "rec"
        case .choice: trailing = 16
        default: break
        }
        g.fill(Path(r), with: .color(Theme.row))
        g.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width * min(max(fill, 0), 1), height: r.height)),
               with: .color(recOn ? Theme.rec.opacity(0.5) : Theme.fill))
        let valueX = r.maxX - 6 - trailing
        let vw = textWidth(text, size: 11)
        let name = fitText(ps.name, size: 11, width: max(valueX - vw - 4 - (r.minX + 6), 8))
        g.draw(LiveText(name, size: 11, color: Theme.dim), at: CGPoint(x: r.minX + 6, y: r.midY), anchor: .leading)
        g.draw(LiveText(text, size: 11, color: recOn ? Theme.rec : Theme.text), at: CGPoint(x: valueX, y: r.midY), anchor: .trailing)
        if case .choice = ps.kind {
            g.draw(LiveText("▾", size: 11, color: Theme.dim), at: CGPoint(x: r.maxX - 9, y: r.midY))
        }
    }

    /// A row a cable modulates (or automation plays): the knob's own position, and where the signal has taken it.
    static func liveRow(_ g: LiveGC, _ size: CGSize, _ ps: ParamSpec, base: Float, live: Float, automated: Bool) {
        let n = CGFloat(ps.normalized(live))
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        var trailing: CGFloat = 0
        var fill = CGFloat(ps.normalized(base)), recOn = false
        switch ps.kind {
        case .toggle: fill = base > 0.5 ? 1 : 0; recOn = base > 0.5 && ps.key == "rec"
        case .choice: trailing = 16
        default: break
        }
        if automated {
            g.fill(Path(CGRect(x: 0, y: 0, width: size.width * n, height: size.height)), with: .color(Theme.fill))
            g.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(Theme.rec))
        } else {
            g.fill(Path(CGRect(x: 0, y: 0, width: size.width * fill, height: size.height)), with: .color(recOn ? Theme.rec.opacity(0.5) : Theme.fill))
            g.fill(Path(CGRect(x: max(0, size.width * n - 1), y: 0, width: 2, height: size.height)), with: .color(Theme.text))
        }
        let text = ps.display(live)
        let vw = textWidth(text, size: 11)
        let name = fitText(ps.name, size: 11, width: max(size.width - 6 - trailing - vw - 4 - 6, 8))
        g.draw(LiveText(name, size: 11, color: Theme.dim), at: CGPoint(x: 6, y: size.height / 2), anchor: .leading)
        g.draw(LiveText(text, size: 11, color: Theme.text), at: CGPoint(x: size.width - 6 - trailing, y: size.height / 2), anchor: .trailing)
        if case .choice = ps.kind {
            g.draw(LiveText("▾", size: 11, color: Theme.dim), at: CGPoint(x: size.width - 9, y: size.height / 2))
        }
    }

    private static func ports(_ g: LiveGC, _ geo: BoxGeo, model: AppModel) {
        for p in geo.ports {
            let connected = model.isPortConnected(geo.node.id, port: p.port, output: p.output)
            let r = CGRect(x: p.center.x - p.size / 2, y: p.center.y - p.size / 2, width: p.size, height: p.size)
            g.fill(Path(ellipseIn: r), with: .color(p.output || connected ? Theme.text : Theme.box))
            g.stroke(Path(ellipseIn: r.insetBy(dx: 0.5, dy: 0.5)),
                     with: .color(p.port >= kParamPortBase && !connected ? Theme.faint : Theme.text), lineWidth: 1)
        }
    }

    /// A free text note.
    static func paintText(_ g: LiveGC, _ node: PatchNode, size: CGSize, selected: Bool, editing: Bool) {
        if !editing {
            let t = node.text ?? ""
            let lines = (t.isEmpty ? "text" : t).components(separatedBy: "\n")
            for (k, l) in lines.enumerated() {
                g.draw(LiveText(l, size: 12, color: t.isEmpty ? Theme.faint : Theme.text),
                       at: CGPoint(x: 5, y: 3 + CGFloat(k) * 15 + 7.5), anchor: .leading)
            }
        }
        if selected || editing {
            g.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.dim.opacity(0.6)),
                     style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
        }
    }

    /// A group's backdrop.
    static func paintGroup(_ g: LiveGC, _ group: PatchGroup, size: CGSize, selected: Bool, renaming: Bool) {
        let r = CGRect(origin: .zero, size: size)
        g.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(Theme.text.opacity(Theme.boxIsLight ? 0.07 : 0.09)))
        g.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6),
                 with: .color(selected ? Theme.text.opacity(0.6) : Theme.text.opacity(0.18)), lineWidth: 1)
        if !renaming {
            g.draw(LiveText(group.name, size: 11, color: Theme.dim, bold: true), at: CGPoint(x: 10, y: 7 + 7), anchor: .leading)
        }
    }
}

// MARK: - Small icons (drawn, so they're sharp at every zoom)

@MainActor enum Icons {
    static func xmark(_ g: LiveGC, _ c: CGPoint, size: CGFloat = 3, color: Color = Theme.dim) {
        var p = Path()
        p.move(to: CGPoint(x: c.x - size, y: c.y - size)); p.addLine(to: CGPoint(x: c.x + size, y: c.y + size))
        p.move(to: CGPoint(x: c.x + size, y: c.y - size)); p.addLine(to: CGPoint(x: c.x - size, y: c.y + size))
        g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }
    /// collapse / expand a box
    static func dash(_ g: LiveGC, _ c: CGPoint) {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 3.5, y: c.y)); p.addLine(to: CGPoint(x: c.x + 3.5, y: c.y))
        g.stroke(p, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }
    static func chevron(_ g: LiveGC, _ c: CGPoint, up: Bool) {
        var p = Path()
        let d: CGFloat = up ? -1 : 1
        p.move(to: CGPoint(x: c.x - 3.5, y: c.y - 1.75 * d)); p.addLine(to: CGPoint(x: c.x, y: c.y + 1.75 * d))
        p.addLine(to: CGPoint(x: c.x + 3.5, y: c.y - 1.75 * d))
        g.stroke(p, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
    static func waveform(_ g: LiveGC, _ c: CGPoint) {
        var p = Path()
        for (k, hh) in [CGFloat(2), 5, 3.5, 6, 2.5].enumerated() {
            let x = c.x - 4 + CGFloat(k) * 2
            p.move(to: CGPoint(x: x, y: c.y - hh / 2)); p.addLine(to: CGPoint(x: x, y: c.y + hh / 2))
        }
        g.stroke(p, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }
    static func trash(_ g: LiveGC, _ c: CGPoint) {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 3.5, y: c.y - 2.5)); p.addLine(to: CGPoint(x: c.x + 3.5, y: c.y - 2.5))
        p.move(to: CGPoint(x: c.x - 1, y: c.y - 3.5)); p.addLine(to: CGPoint(x: c.x + 1, y: c.y - 3.5))
        p.addRect(CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 6))
        g.stroke(p, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
    static func resetArrow(_ g: LiveGC, _ c: CGPoint) {
        var p = Path()
        p.addArc(center: c, radius: 3.2, startAngle: .degrees(-60), endAngle: .degrees(200), clockwise: false)
        g.stroke(p, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        let a = CGPoint(x: c.x + 3.2 * cos(-60 * .pi / 180), y: c.y + 3.2 * sin(-60 * .pi / 180))
        var head = Path()
        head.move(to: CGPoint(x: a.x - 2.4, y: a.y - 0.6)); head.addLine(to: a); head.addLine(to: CGPoint(x: a.x - 0.3, y: a.y + 2.4))
        g.stroke(head, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
    }
    static func play(_ g: LiveGC, _ c: CGPoint, _ color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 2.5, y: c.y - 3.5)); p.addLine(to: CGPoint(x: c.x + 3.5, y: c.y)); p.addLine(to: CGPoint(x: c.x - 2.5, y: c.y + 3.5))
        p.closeSubpath()
        g.fill(p, with: .color(color))
    }
    static func pause(_ g: LiveGC, _ c: CGPoint, _ color: Color) {
        g.fill(Path(CGRect(x: c.x - 3, y: c.y - 3.5, width: 2, height: 7)), with: .color(color))
        g.fill(Path(CGRect(x: c.x + 1, y: c.y - 3.5, width: 2, height: 7)), with: .color(color))
    }
    static func stop(_ g: LiveGC, _ c: CGPoint, _ color: Color) {
        g.fill(Path(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(color))
    }
}

extension LiveGC {
    /// Draw `body` at `alpha` (the parts of a switched-off box).
    func dimmed(_ alpha: CGFloat, _ body: (LiveGC) -> Void) {
        guard alpha < 1, let cg = cgContext else { body(self); return }
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        body(self)
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
}
