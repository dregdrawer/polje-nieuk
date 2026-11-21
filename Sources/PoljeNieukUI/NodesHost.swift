import SwiftUI
import Combine
import UniformTypeIdentifiers
import PoljeNieukCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The boxes, notes, group backdrops and cables of the 2D canvas, drawn natively — the way Max and Pure Data
/// draw a patcher: plain drawing calls at the exact zoom. Panning slides the drawing; zooming draws it again at
/// the new size, frame by frame, so it's always sharp and nothing ever jumps. Pointer presses on boxes are
/// handled here too (selecting, moving, patching, rows, menus, the displays' editors, files dropped on boxes).
struct NodesHost: View {
    let model: AppModel
    /// the pointer / Pencil-tip position the canvas highlights ports by (hovering over boxes lands here)
    let hover: HoverState
    var body: some View { Platform(model: model, hover: hover) }
}

/// What a box shows besides its own settings: when it changes, the box is drawn again.
struct BoxKey: Equatable {
    var node: PatchNode?
    var cables: [PatchCable] = []
    var related: [PatchNode] = []     // what a fader / knob drives (its targets' names and ranges)
    var nodeCount = 0
    var selected = false
    var running = false
    var hw = HardwareCounts(inputs: 0, outputs: 0)
    var transport: GraphHost.Transport = .play
    var autoRec = false
    var look = 0                      // colours / light-dark
    var groupRect: CGRect?
    var groupName = ""
    var padNames: [String] = []       // rack~: what each pad holds
    var loading: Set<Int> = []        // rack~: pads still reading their file
    var automationFlags = 0           // which rows are automated / modulated
}

enum NodesLayout {
    /// room around each box for the ports, which stick out over its edges
    static let pad: CGFloat = 12
}

struct CableEnd: Equatable { let from: UUID, to: UUID; let a: CGPoint, b: CGPoint; let style: Int }

private extension AppModel {
    /// Every cable's two ends in canvas points, and its style: 0 plain, 1 dashed, 2 selected.
    func cableEnds() -> [CableEnd] {
        guard !hideCables else { return [] }
        let hw = self.hw
        var out: [CableEnd] = []
        out.reserveCapacity(patch.cables.count)
        var index: [UUID: Int] = [:]
        for (k, n) in patch.nodes.enumerated() { index[n.id] = k }
        for c in patch.cables {
            guard let ai = index[c.fromNode], let bi = index[c.toNode] else { continue }
            let a = patch.nodes[ai], b = patch.nodes[bi]
            guard let sa = ModuleRegistry.spec(a.kind), let sb = ModuleRegistry.spec(b.kind),
                  c.fromPort < BoxLayout.ports(a, sa, hw).outs.count,
                  let dest = BoxLayout.destination(b, sb, hw, port: c.toPort) else { continue }
            let style = selectedCable == c.id || insertCandidates.contains(c.id) ? 2 : (c.toPort >= kParamPortBase ? 1 : 0)
            out.append(CableEnd(from: a.id, to: b.id, a: BoxLayout.outlet(a, sa, hw, c.fromPort), b: dest, style: style))
        }
        return out
    }
}

#if os(macOS)
private typealias PView = NSView
private typealias PColor = NSColor
#else
private typealias PView = UIView
private typealias PColor = UIColor
#endif

// MARK: - A box's layers

/// One moving part's layer (a display, a live row, a meter): redrawn by the tick when its signature changes.
@MainActor private final class PartLayer: NSObject, CALayerDelegate {
    let layer = CALayer()
    let slot = LiveSlot()
    var part: LivePart
    var scale: CGFloat = 1
    /// where the part's corner falls past the whole pixel its layer sits on (drawn into the bitmap)
    var frac: CGPoint = .zero
    init(_ part: LivePart) {
        self.part = part
        super.init()
        layer.delegate = self
        layer.isOpaque = false
        layer.masksToBounds = true
        slot.onChange = { [weak self] in self?.layer.setNeedsDisplay() }
        apply(part)
        slot.attach()
    }
    func apply(_ p: LivePart) {
        part = p
        slot.signature = p.signature
        slot.every = p.every
        slot.smooth = p.smooth
        layer.opacity = p.dimmed ? 0.35 : 1
    }
    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        MainActor.assumeIsolated {
            let s = max(scale, 0.01)
            if !layer.contentsAreFlipped() { ctx.translateBy(x: 0, y: layer.bounds.height); ctx.scaleBy(x: 1, y: -1) }
            ctx.translateBy(x: frac.x, y: frac.y)
            ctx.scaleBy(x: s, y: s)
            part.draw(LiveGC(cg: ctx), part.rect.size)
        }
    }
    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// A box, a note or a group backdrop on the canvas.
@MainActor private final class Item: NSObject, CALayerDelegate {
    enum Kind { case module, text, group }
    let id: UUID
    let kind: Kind
    /// placed in the canvas layer (canvas points × zoom); moves with drags
    let root = CALayer()
    /// what changes only with the settings (with room around it for the ports)
    let content = CALayer()
    var parts: [String: PartLayer] = [:]
    var node: PatchNode?
    var spec: ModuleSpec?
    var group: PatchGroup?
    var geo: BoxGeo?
    var display: NativeDisplay?
    var key: BoxKey?
    var selected = false
    var dropTarget = false
    var editing = false
    var liveRows: Set<Int> = []
    /// canvas points
    var rect: CGRect = .zero
    var visible = true
    var dirty = true
    unowned let model: AppModel

    init(id: UUID, kind: Kind, model: AppModel) {
        self.id = id; self.kind = kind; self.model = model
        super.init()
        content.delegate = self
        content.isOpaque = false
        root.delegate = self                 // (no implicit animations on it either)
        root.addSublayer(content)
        root.masksToBounds = false
    }

    var margin: CGFloat { kind == .module ? NodesLayout.pad : 0 }

    /// The zoom the item's bitmaps are drawn at, and how far past whole pixels its corner falls at that zoom
    /// (drawn into the bitmaps, so their layers sit on whole pixels — sharp — and yet the box is exactly where
    /// it belongs: a stretched old drawing and a fresh one land in the same place, nothing shifts).
    var si: CGFloat = 0
    var frac: CGPoint = .zero
    private var marginPx: CGFloat = 0

    /// Lay the bitmaps out for zoom `s` (device pixels: `px` per point) and mark them to be drawn.
    func drawAt(_ s: CGFloat, px: CGFloat) {
        si = s
        func floorPx(_ v: CGFloat) -> CGFloat { (v * px).rounded(.down) / px }
        func ceilPx(_ v: CGFloat) -> CGFloat { (v * px).rounded(.up) / px }
        let ox = rect.minX * s, oy = rect.minY * s
        frac = CGPoint(x: ox - floorPx(ox), y: oy - floorPx(oy))
        let size = CGSize(width: ceilPx(rect.width * s + frac.x) + 1 / px, height: ceilPx(rect.height * s + frac.y) + 1 / px)
        marginPx = ceilPx(margin * s)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.anchorPoint = .zero
        if root.bounds.size != size { root.bounds = CGRect(origin: .zero, size: size) }
        let cf = CGRect(x: -marginPx, y: -marginPx, width: size.width + 2 * marginPx, height: size.height + 2 * marginPx)
        if content.frame != cf { content.frame = cf }
        if content.contentsScale != px { content.contentsScale = px }
        for p in parts.values {
            let r = p.part.rect
            let ex = r.minX * s + frac.x, ey = r.minY * s + frac.y
            let fx = floorPx(ex), fy = floorPx(ey)
            p.frac = CGPoint(x: ex - fx, y: ey - fy)
            let pf = CGRect(x: fx, y: fy, width: ceilPx(r.width * s + p.frac.x), height: ceilPx(r.height * s + p.frac.y))
            if p.layer.frame != pf { p.layer.frame = pf }
            if p.layer.contentsScale != px { p.layer.contentsScale = px }
            p.scale = s
        }
        CATransaction.commit()
        content.setNeedsDisplay()
        for p in parts.values { p.layer.setNeedsDisplay() }
        dirty = false
    }

    /// Place it for the canvas zoom `sw` (moved by a drag `d`, canvas points). A drawing made at another zoom is
    /// scaled to fit until it's drawn again.
    func layout(_ sw: CGFloat, drag d: CGSize) {
        guard si > 0 else { return }
        let m = sw / si
        let pos = CGPoint(x: rect.minX * sw - frac.x * m, y: rect.minY * sw - frac.y * m)
        var t = m == 1 ? CATransform3DIdentity : CATransform3DMakeScale(m, m, 1)
        if d != .zero { t = CATransform3DConcat(t, CATransform3DMakeTranslation(d.width * sw, d.height * sw, 0)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if root.position != pos { root.position = pos }
        if !CATransform3DEqualToTransform(root.transform, t) { root.transform = t }
        CATransaction.commit()
    }

    /// Draw now (not at the next frame): for spreading a zoom's redraws over several frames.
    func displayNow() {
        content.displayIfNeeded()
        for p in parts.values { p.layer.displayIfNeeded() }
    }

    func redraw() {
        content.setNeedsDisplay()
        for p in parts.values { p.layer.setNeedsDisplay() }
        dirty = false
    }

    func setVisible(_ v: Bool) {
        guard v != visible else { return }
        visible = v
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.isHidden = !v
        CATransaction.commit()
        for p in parts.values { p.slot.active = v }
    }

    /// Replace the moving parts (a box's display layout or live rows changed).
    func setParts(_ list: [LivePart]) {
        var keep: Set<String> = []
        for lp in list {
            keep.insert(lp.key)
            if let p = parts[lp.key] { p.apply(lp) } else {
                let p = PartLayer(lp)
                p.slot.active = visible
                parts[lp.key] = p
                CATransaction.begin(); CATransaction.setDisableActions(true)
                root.addSublayer(p.layer)
                CATransaction.commit()
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, p) in parts where !keep.contains(k) {
            p.slot.active = false
            p.layer.removeFromSuperlayer()
            parts[k] = nil
        }
        CATransaction.commit()
    }

    func remove() {
        for p in parts.values { p.slot.active = false }
        // no fade-out (the layer outlives this item, which is what switched its animations off)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.removeFromSuperlayer()
        CATransaction.commit()
    }

    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        MainActor.assumeIsolated {
            guard layer === content, si > 0 else { return }
            if !layer.contentsAreFlipped() { ctx.translateBy(x: 0, y: layer.bounds.height); ctx.scaleBy(x: 1, y: -1) }
            ctx.translateBy(x: marginPx + frac.x, y: marginPx + frac.y)
            ctx.scaleBy(x: si, y: si)
            let g = LiveGC(cg: ctx)
            switch kind {
            case .module:
                guard let geo else { return }
                BoxPainter.paint(g, geo, model: model, selected: selected, dropTarget: dropTarget, liveRows: liveRows, display: display)
            case .text:
                guard let node else { return }
                BoxPainter.paintText(g, node, size: rect.size, selected: selected, editing: editing)
            case .group:
                guard let group else { return }
                BoxPainter.paintGroup(g, group, size: rect.size, selected: selected, renaming: editing)
            }
        }
    }
    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

// MARK: - Where a press lands in a box

private enum Region: Equatable {
    case port(Int, output: Bool)
    case button(BoxGeo.Button)
    case title, grab, trigger(Int), row(Int), display, grip
    case text
    case group, groupName
    case nothing
}

/// A press being followed.
@MainActor private final class Press {
    let item: Item
    var region: Region
    let startScreen: CGPoint
    var info: PointerInfo
    var dragging = false          // moving the box
    var resizeStart: CGSize?
    var rowStart: Float?
    var autoRecWasOn = false
    var pressedAt = Date()
    var longTimer: Timer?
    var longFired = false
    var groupDrag = false
    init(item: Item, region: Region, start: CGPoint, info: PointerInfo) {
        self.item = item; self.region = region; self.startScreen = start; self.info = info
    }
}

// MARK: - The canvas (shared by the Mac and the iPad)

@MainActor private final class Canvas {
    let model: AppModel
    let hover: HoverState
    let world = CALayer()            // slides with the pan
    private let groupLayer = CALayer(), cableLayer = CALayer(), boxLayer = CALayer()
    private var items: [UUID: Item] = [:]
    private var groupItems: [UUID: Item] = [:]
    private var order: [UUID] = []
    private let plain = CAShapeLayer(), dashed = CAShapeLayer(), selectedCables = CAShapeLayer()
    private let movPlain = CAShapeLayer(), movDashed = CAShapeLayer(), movSelected = CAShapeLayer()
    private var ends: [CableEnd] = []
    private var cablesFor: (scale: CGFloat, look: Int)?
    private var splitFor: Set<UUID> = []
    private var moving: [CableEnd] = []
    private(set) var scale: CGFloat = 0
    var px: CGFloat = 2
    var viewSize: CGSize = .zero
    /// set by the platform view
    var presentMenu: ([MenuItem], CGPoint) -> Void = { _, _ in }
    var beginTextEdit: (UUID, Bool) -> Void = { _, _ in }     // (id, isGroup)
    var editingID: UUID?

    init(model: AppModel, hover: HoverState) {
        self.model = model; self.hover = hover
        world.anchorPoint = .zero
        for l in [groupLayer, cableLayer, boxLayer] { l.anchorPoint = .zero; world.addSublayer(l) }
        for l in [plain, dashed, selectedCables, movPlain, movDashed, movSelected] {
            l.fillColor = nil; l.lineCap = .round; l.lineWidth = 1
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
            cableLayer.addSublayer(l)
        }
        dashed.lineDashPattern = [4, 3]; movDashed.lineDashPattern = [4, 3]
        selectedCables.lineWidth = 2; movSelected.lineWidth = 2
        for l in [world, groupLayer, cableLayer, boxLayer] { l.actions = ["sublayerTransform": NSNull(), "position": NSNull(), "bounds": NSNull()] }
    }

    // MARK: Keeping up with the patch

    private func look() -> Int { CustomColours.version &* 2 &+ (Theme.light ? 1 : 0) }

    /// Make the items match the patch; draw again the ones whose key changed.
    func sync() {
        let m = model
        var byNode: [UUID: [PatchCable]] = [:]
        for c in m.patch.cables {
            byNode[c.fromNode, default: []].append(c)
            if c.toNode != c.fromNode { byNode[c.toNode, default: []].append(c) }
        }
        var index: [UUID: Int] = [:]
        for (k, n) in m.patch.nodes.enumerated() { index[n.id] = k }
        let base = BoxKey(nodeCount: m.patch.nodes.count, running: m.isRunning, hw: m.hw, transport: m.transport, look: look())
        let alive = Set(m.patch.nodes.map(\.id))
        for (id, it) in items where !alive.contains(id) {
            it.remove(); items[id] = nil
            if editingID == id { editingID = nil }
        }
        for n in m.patch.nodes {
            let item = items[n.id] ?? {
                let it = Item(id: n.id, kind: n.kind == "text" ? .text : .module, model: m)
                items[n.id] = it
                CATransaction.begin(); CATransaction.setDisableActions(true)      // no fade-in
                boxLayer.addSublayer(it.root)
                CATransaction.commit()
                return it
            }()
            var k = base
            k.node = n
            let cs = byNode[n.id] ?? []
            k.cables = cs
            if n.kind == "slider" || n.kind == "knob" {
                k.related = cs.compactMap { c in c.fromNode == n.id ? index[c.toNode].map { m.patch.nodes[$0] } : nil }
            }
            k.selected = m.selectedNodes.contains(n.id)
            k.autoRec = m.autoRecording.contains(n.id)
            if n.kind == "rack", let r = m.host.node(n.id) as? RackNode { k.padNames = r.padNames; k.loading = m.loadingPads[n.id] ?? [] }
            if item.key != k { item.key = k; update(item, n) }
        }
        if m.patch.nodes.map(\.id) != order {
            order = m.patch.nodes.map(\.id)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for id in order { if let it = items[id] { it.root.removeFromSuperlayer(); boxLayer.addSublayer(it.root) } }
            CATransaction.commit()
        }
        // group backdrops
        let gids = Set(m.groups.map(\.id))
        for (id, it) in groupItems where !gids.contains(id) { it.remove(); groupItems[id] = nil }
        for g in m.groups {
            let item = groupItems[g.id] ?? {
                let it = Item(id: g.id, kind: .group, model: m)
                groupItems[g.id] = it
                CATransaction.begin(); CATransaction.setDisableActions(true)
                groupLayer.addSublayer(it.root)
                CATransaction.commit()
                return it
            }()
            var k = base
            k.groupRect = m.groupRect(g)
            k.groupName = g.name
            k.selected = !g.members.isEmpty && g.members.allSatisfy { m.selectedNodes.contains($0) }
            if item.key != k {
                item.key = k
                item.group = g
                item.selected = k.selected
                item.rect = k.groupRect ?? .zero
                refresh(item)
            }
        }
        applyDrag()
        layoutCables()
        updateVisibility()
        // a note that was being written in, now deselected (tapped away): done
        if let e = editingID, items[e]?.kind == .text, !m.selectedNodes.contains(e) { endTextEdit?() }
    }
    var endTextEdit: (() -> Void)?

    private func update(_ item: Item, _ n: PatchNode) {
        let m = model
        item.node = n
        item.selected = m.selectedNodes.contains(n.id)
        if item.kind == .text {
            let s = BoxLayout.textSize(n)
            item.rect = CGRect(x: n.x, y: n.y, width: s.width, height: s.height)
            refresh(item)
            if n.text == nil && editingID == nil {
                // a new note opens for typing
                DispatchQueue.main.async { [weak self] in self?.beginTextEdit(n.id, false) }
            }
            return
        }
        guard let spec = ModuleRegistry.spec(n.kind) else { return }
        item.spec = spec
        let geo = BoxGeo(n, spec, m.hw, selected: item.selected, model: m)
        item.geo = geo
        item.rect = CGRect(x: n.x, y: n.y, width: geo.w, height: geo.h)
        if item.display == nil { item.display = NativeDisplay.make(model: m, node: n, spec: spec) }
        item.display?.node = n
        // rows that move on their own: modulated or automated
        var live: Set<Int> = []
        for (i, _) in geo.rows where m.isModulated(n.id, i) || m.isAutomated(n, i, spec) { live.insert(i) }
        item.liveRows = live
        item.setParts(parts(item, geo))
        refresh(item)
    }

    /// An item changed: drawn again now at the canvas zoom if it's on screen (later, when it comes on screen,
    /// if it isn't), and placed.
    private func refresh(_ item: Item) {
        if item.visible && scale > 0 { item.drawAt(scale, px: px) } else { item.dirty = true }
        item.layout(scale, drag: dragShift(item.id))
    }

    /// A box's moving parts: its display, live rows, meters and outlet dots.
    private func parts(_ item: Item, _ geo: BoxGeo) -> [LivePart] {
        let m = model, n = geo.node, spec = geo.spec, id = n.id
        var list: [LivePart] = []
        if let d = geo.display, let display = item.display { list += display.parts(d) }
        if !n.collapsed {
            for (i, r) in geo.rows where item.liveRows.contains(i) {
                let ps = spec.params[i]
                let automated = m.isAutomated(n, i, spec)
                list.append(LivePart(key: "row\(i)", rect: r, every: 2, dimmed: n.bypassed, signature: {
                    guard let d = m.node(id) else { return 0 }
                    var h = LiveSig.q(ps.normalized(d.params[i]), 240)
                    LiveSig.mix(&h, ps.display(d.params[i]).hashValue)
                    return h
                }) { g, size in
                    guard let d = m.node(id) else { return }
                    BoxPainter.liveRow(g, size, ps, base: m.value(n, i, spec), live: d.params[i], automated: automated)
                })
            }
            // meters: in~ / out~ channels, mixer inputs
            let p = BoxLayout.ports(n, spec, geo.hw)
            if n.kind == "in" || n.kind == "out" || n.kind == "mix" {
                let rows = n.kind == "mix" ? p.ins.count : BoxLayout.portRows(n, spec, geo.hw)
                for r in 0..<rows {
                    let ch = n.kind == "mix" ? MixerLayout.channelMeterBase + r : r
                    let mr = BoxPainter.meterRect(geo, r)
                    guard mr.width > 4 else { continue }
                    list.append(LivePart(key: "meter\(r)", rect: mr, every: 2, dimmed: n.bypassed, signature: {
                        LiveSig.q(m.node(id).map { $0.readouts[min(ch, DSPNode.readoutCount - 1)] } ?? 0, 60)
                    }) { g, size in
                        drawMeter(g, CGRect(origin: .zero, size: size), m.node(id).map { $0.readouts[min(ch, DSPNode.readoutCount - 1)] } ?? 0)
                    })
                }
            }
        }
        // outlet activity dots (audio on)
        var outs = n.collapsed ? BoxLayout.collapsedRight(n, spec) : Array(BoxLayout.ports(n, spec, geo.hw).outs.indices)
        if n.kind == "rack" && !n.collapsed { outs = outs.filter { $0 < 2 } }     // the pads light up themselves
        if m.isRunning, !outs.isEmpty, n.kind != "in" {
            let ys = outs.map { BoxLayout.outlet(n, spec, geo.hw, $0).y - n.y }
            let names = outs.map { $0 < spec.outputs.count ? spec.outputs[$0] : "" }
            let gate = names.map { n.kind == "div" || ["gate", "pulse", "trig", "t1", "t2", "t3"].contains($0) }
            let w = geo.w, rowOutlets = BoxLayout.rowOutlets(n.kind) && !n.collapsed
            list.append(LivePart(key: "dots", rect: CGRect(x: 0, y: 0, width: w, height: geo.h), every: 2, signature: {
                guard let dsp = m.node(id) else { return 0 }
                var h = 0
                for (j, k) in outs.enumerated() where k < spec.outputs.count {
                    LiveSig.mix(&h, gate[j] ? (dsp.outLevel[k] * 4 > 0.1 ? 1 : 0) : LiveSig.q(min(max(dsp.outLevel[k] * 4, 0), 1), 4))
                }
                return h
            }) { ctx, _ in
                guard let dsp = m.node(id) else { return }
                for (j, k) in outs.enumerated() where k < spec.outputs.count {
                    let lv = dsp.outLevel[k]
                    let a: CGFloat = !lv.isFinite ? 0 : gate[j] ? (lv * 4 > 0.1 ? 1 : 0) : CGFloat((min(max(lv * 4, 0), 1) * 4).rounded() / 4)
                    let x = rowOutlets ? 8 + 8 + 5 * 5.45 + 14 : w - 10 - textWidth(names[j], size: 9) - 8
                    let r = CGRect(x: x - 3, y: ys[j] - 3, width: 6, height: 6)
                    if a > 0.02 {
                        ctx.fill(Path(ellipseIn: r), with: .color(Theme.text.opacity(0.35 + 0.65 * a)))
                    } else {
                        ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.dim.opacity(0.7)), lineWidth: 1)
                    }
                }
            })
        }
        return list
    }

    // MARK: Pan / zoom

    /// The view moved or zoomed. A pan slides the canvas (nothing is drawn). A zoom scales the last drawing on
    /// the GPU while it's under way (nothing drawn either: drawing every box on every frame took a whole core);
    /// once it pauses, the boxes are placed for the new zoom and drawn sharp, a few each frame — each exactly
    /// where its stretched picture was, so nothing shifts as it sharpens.
    func viewportChanged() {
        let s = model.viewScale
        if scale == 0 { scale = s; for it in allItems { it.dirty = true } }
        if s != scale {
            settleWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle() } }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        }
        placeWorld()
        updateVisibility()
        repositionEditor?()
    }
    private var settleWork: DispatchWorkItem?
    private var allItems: [Item] { Array(items.values) + Array(groupItems.values) }

    /// A zoom has paused: place everything for it, then draw it sharp (spread over frames, nearest first).
    private func settle() {
        guard !model.isZooming else {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle() } }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
            return
        }
        let s = model.viewScale
        guard s != scale else { return }
        scale = s
        for it in allItems { it.layout(s, drag: dragShift(it.id)); it.dirty = true }
        placeWorld()
        layoutCables()
        updateVisibility()
    }

    /// Items waiting to be drawn at the canvas zoom, drawn a few per frame.
    private var queue: [Item] = []
    private var pumping: Timer?
    private func enqueue(_ it: Item) {
        if !queue.contains(where: { $0 === it }) { queue.append(it) }
        guard pumping == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pump() } }
        RunLoop.main.add(t, forMode: .common)
        pumping = t
        pump()
    }
    private func pump() {
        // nearest the middle of the view first
        let s = max(model.viewScale, 0.01), o = model.viewOffset
        let mid = CGPoint(x: (viewSize.width / 2 - o.width) / s, y: (viewSize.height / 2 - o.height) / s)
        queue.sort { hypot($0.rect.midX - mid.x, $0.rect.midY - mid.y) < hypot($1.rect.midX - mid.x, $1.rect.midY - mid.y) }
        let start = CACurrentMediaTime()
        while !queue.isEmpty && CACurrentMediaTime() - start < 0.006 {
            let it = queue.removeFirst()
            guard it.visible, it.dirty || it.si != scale else { continue }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            it.drawAt(scale, px: px)
            it.layout(scale, drag: dragShift(it.id))
            it.displayNow()
            CATransaction.commit()
        }
        if queue.isEmpty { pumping?.invalidate(); pumping = nil }
    }

    /// The pan, and — while a zoom is under way — the scale from the drawing to the live zoom.
    private func placeWorld() {
        let o = model.viewOffset, k = model.viewScale / max(scale, 0.0001)
        let tx = (o.width * px).rounded() / px, ty = (o.height * px).rounded() / px
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var t = CATransform3DMakeTranslation(tx, ty, 0)
        if k != 1 { t = CATransform3DScale(t, k, k, 1) }
        world.sublayerTransform = t
        // cables keep one width on screen while scaled
        for l in [plain, dashed, movPlain, movDashed] { l.lineWidth = 1 / k }
        for l in [selectedCables, movSelected] { l.lineWidth = 2 / k }
        for l in [dashed, movDashed] { l.lineDashPattern = [NSNumber(value: Double(4 / k)), NSNumber(value: Double(3 / k))] }
        CATransaction.commit()
    }
    var repositionEditor: (() -> Void)?

    /// Off-screen items aren't drawn (or ticked); on screen, they're drawn at the canvas zoom.
    private func updateVisibility() {
        let s = max(model.viewScale, 0.01), o = model.viewOffset
        let vis = CGRect(x: -o.width / s, y: -o.height / s, width: viewSize.width / s, height: viewSize.height / s).insetBy(dx: -60 / s, dy: -60 / s)
        for it in allItems {
            let shift = dragShift(it.id)
            let r = it.rect.offsetBy(dx: shift.width, dy: shift.height).insetBy(dx: -it.margin, dy: -it.margin)
            let v = viewSize.width <= 0 || r.intersects(vis)
            it.setVisible(v)
            if v && (it.dirty || it.si != scale) {
                if it.si == 0 {
                    // never drawn: draw it now (a new box, the first frame)
                    it.drawAt(scale, px: px); it.layout(scale, drag: shift)
                } else {
                    enqueue(it)
                }
            }
        }
    }

    func setBackingScale(_ s: CGFloat) {
        guard s != px, s > 0 else { return }
        px = s
        for it in allItems { it.dirty = true }
        for l in [plain, dashed, selectedCables, movPlain, movDashed, movSelected] { l.contentsScale = s }
        updateVisibility()
    }

    // MARK: Dragging boxes

    /// How far a dragged box is shown moved: exactly where it'll land when let go (positions are kept in
    /// whole canvas points — shown at fractions, a box jumped a little when it was dropped).
    func dragShift(_ id: UUID) -> CGSize {
        let ds = model.dragState
        guard ds.ids.contains(id), let it = items[id], let n = it.node else { return ds.offset(id) }
        let d = ds.delta
        return CGSize(width: max(-2000, (n.x + d.width).rounded()) - n.x, height: max(-2000, (n.y + d.height).rounded()) - n.y)
    }

    /// Boxes being dragged move as they are (no redraw); their cables follow.
    func applyDrag() {
        let d = model.dragState.delta, ids = model.dragState.ids
        for it in items.values { it.layout(scale, drag: ids.contains(it.id) ? dragShift(it.id) : .zero) }
        for it in groupItems.values {
            let all = !(it.group?.members.isEmpty ?? true) && Set(it.group?.members ?? []).isSubset(of: ids)
            it.layout(scale, drag: all ? d : .zero)
        }
    }
    func dragged() {
        applyDrag()
        layoutCables(fresh: false)
        updateVisibility()
    }

    // MARK: Cables

    func layoutCables(fresh: Bool = true) {
        let lk = (scale: scale, look: look())
        if fresh {
            let e = model.cableEnds()
            if e == ends && splitFor.isEmpty && moving.isEmpty && cablesFor.map({ $0 == lk }) == true { return }
            ends = e; splitFor = []
        }
        cablesFor = lk
        let ids = fresh ? [] : model.dragState.ids
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if fresh || ids != splitFor {
            splitFor = ids
            let still = ids.isEmpty ? ends : ends.filter { !ids.contains($0.from) && !ids.contains($0.to) }
            moving = ids.isEmpty ? [] : ends.filter { ids.contains($0.from) || ids.contains($0.to) }
            style(paths(still), plain, dashed, selectedCables)
        }
        style(paths(moving), movPlain, movDashed, movSelected)
        CATransaction.commit()
    }
    private func paths(_ list: [CableEnd]) -> [CGPath] {
        let s = scale, ids = model.dragState.ids
        func map(_ c: CGPoint, _ id: UUID) -> CGPoint {
            let m = ids.contains(id) ? dragShift(id) : .zero
            return CGPoint(x: (c.x + m.width) * s, y: (c.y + m.height) * s)
        }
        let p = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for e in list {
            var path = Path()
            addCable(&path, map(e.a, e.from), map(e.b, e.to), scale: s)
            p[e.style].addPath(path.cgPath)
        }
        return p
    }
    private func style(_ p: [CGPath], _ a: CAShapeLayer, _ b: CAShapeLayer, _ c: CAShapeLayer) {
        let cable = PColor(Theme.cable).cgColor, sel = PColor(Theme.selected).cgColor
        a.path = p[0]; a.strokeColor = cable
        b.path = p[1]; b.strokeColor = cable
        c.path = p[2]; c.strokeColor = sel
    }

    // MARK: Finding what's under the pointer

    /// The topmost item under a point (canvas-view coordinates).
    func item(at screen: CGPoint) -> Item? {
        let c = model.toCanvas(screen)
        for id in order.reversed() {
            guard let it = items[id] else { continue }
            let shift = dragShift(id)
            let r = it.rect.offsetBy(dx: shift.width, dy: shift.height)
            if it.kind == .text {
                if r.insetBy(dx: -10, dy: -10).contains(c) { return it }
                continue
            }
            if r.contains(c) { return it }
            // just outside the box: only where a port sticks out
            if r.insetBy(dx: -11, dy: 0).contains(c), let geo = it.geo,
               geo.port(at: CGPoint(x: c.x - r.minX, y: c.y - r.minY)) != nil { return it }
        }
        for it in groupItems.values where it.rect.contains(c) { return it }
        return nil
    }
    func local(_ it: Item, _ screen: CGPoint) -> CGPoint {
        let c = model.toCanvas(screen), shift = dragShift(it.id)
        return CGPoint(x: c.x - it.rect.minX - shift.width, y: c.y - it.rect.minY - shift.height)
    }

    private func region(_ it: Item, _ p: CGPoint) -> Region {
        switch it.kind {
        case .text: return .text
        case .group: return p.y < 26 && p.x < 10 + textWidth(it.group?.name ?? "", size: 11, bold: true) + 10 ? .groupName : .group
        case .module: break
        }
        guard let geo = it.geo else { return .nothing }
        if let port = geo.port(at: p) { return .port(port.port, output: port.output) }
        guard p.x >= 0 && p.x <= geo.w && p.y >= 0 && p.y <= geo.h else { return .nothing }
        if geo.header.contains(p) {
            for (b, r) in geo.buttons where r.contains(p) { return .button(b) }
            return .title
        }
        if let g = geo.grip, g.contains(p) { return .grip }
        for (i, r) in geo.triggers where r.contains(p) { return .trigger(i) }
        for (i, r) in geo.rows where r.insetBy(dx: 0, dy: -1.5).contains(p) { return .row(i) }
        if let d = geo.display, d.contains(p) { return .display }
        if let pr = geo.portRows, pr.contains(p) { return .grab }
        return .nothing
    }

    // MARK: Pointer presses

    private var presses: [Int: Press] = [:]

    /// A press began (pointer `key`: the mouse, or one finger). True when a box takes it.
    @discardableResult func began(_ key: Int, at screen: CGPoint, _ info0: PointerInfo) -> Bool {
        guard !model.isZooming, let it = item(at: screen) else { return false }
        var info = info0
        let lp = local(it, screen)
        info.start = lp
        var reg = region(it, lp)
        if editingID == it.id && (it.kind == .text || reg == .groupName) { return true }
        let press = Press(item: it, region: reg, start: screen, info: info)
        presses[key] = press
        let m = model, id = it.id
        switch reg {
        case .port(let port, let output):
            let connected = m.isPortConnected(id, port: port, output: output)
            if m.pendingCable == nil && !output && connected, m.pickUpCable(into: id, port: port, at: screen) { break }
            m.pendingCable = PendingCable(node: id, port: port, fromOutput: output, point: screen)
        case .button(.autoRec):
            press.autoRecWasOn = m.autoRecording.contains(id)
            if !press.autoRecWasOn { m.startAutoRecord(id) }
        case .title, .text:
            if info.right { break }
            press.longTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak press] _ in
                MainActor.assumeIsolated {
                    guard let self, let press, !press.dragging, !press.info.moved else { return }
                    press.longFired = true
                    if press.item.kind == .module { self.model.beginReplace(press.item.id) }
                }
            }
        case .row(let i):
            if let node = it.node, let spec = it.spec { press.rowStart = spec.params[i].normalized(m.value(node, i, spec)) }
        case .grip:
            if let n = it.node { press.resizeStart = CGSize(width: BoxLayout.width(n), height: BoxLayout.readoutHeight(n)) }
        case .display:
            guard let d = it.geo?.display, let disp = it.display else { break }
            if info.right {
                if let items = disp.menu(lp, d) { presentMenu(items, screen) }
                presses[key] = nil
                return true
            }
            if !disp.press(lp, d, info) {
                // nothing to do in this part of the display: the port rows under it (fader / knob boxes) move the box
                if let pr = it.geo?.portRows, pr.contains(lp) { reg = .grab; press.region = .grab } else { press.region = .nothing }
            }
        default: break
        }
        return true
    }

    func moved(_ key: Int, to screen: CGPoint) {
        guard let press = presses[key] else { return }
        let it = press.item, m = model, id = it.id
        let dx = screen.x - press.startScreen.x, dy = screen.y - press.startScreen.y
        if !press.info.moved && hypot(dx, dy) > 2.5 { press.info.moved = true; press.longTimer?.invalidate() }
        if m.isZooming && !press.dragging { return }
        let lp = local(it, screen)
        switch press.region {
        case .port:
            if m.pendingCable != nil { m.pendingCable?.point = screen }
        case .title, .grab, .text:
            guard press.info.moved, !press.longFired, editingID != id else { return }
            if !press.dragging {
                press.dragging = true
                m.nativeDrag = true
                m.nativeDragBegan(id)
            }
            m.nativeDragMoved(by: CGSize(width: dx, height: dy), at: screen)
        case .group:
            guard press.info.moved, let g = it.group else { return }
            if !press.dragging {
                press.dragging = true
                m.selectGroup(g)
                m.beginGroupDrag()
            }
            m.groupDrag(by: CGSize(width: dx / m.viewScale, height: dy / m.viewScale))
        case .row(let i):
            guard press.info.moved, let node = it.node, let spec = it.spec, let start = press.rowStart else { return }
            let ps = spec.params[i]
            if case .toggle = ps.kind { return }
            let width = max((it.geo?.w ?? 186) - 16, 1)
            let n = start + Float(dx / m.viewScale / width)
            if !m.isZooming { m.setParam(node.id, i, ps.value(fromNormalized: n)) }
        case .grip:
            guard press.info.moved, let n = it.node, let s = press.resizeStart else { return }
            let can = BoxLayout.resizable(n.kind)
            m.resizeNode(id, width: can.width ? s.width + dx / m.viewScale : nil, display: can.height ? s.height + dy / m.viewScale : nil)
        case .display:
            guard let d = it.geo?.display else { return }
            it.display?.drag(lp, d, press.info)
        default: break
        }
    }

    func ended(_ key: Int, at screen: CGPoint, cancelled: Bool = false) {
        guard let press = presses.removeValue(forKey: key) else { return }
        press.longTimer?.invalidate()
        let it = press.item, m = model, id = it.id
        let lp = local(it, screen)
        let inside: (CGRect?) -> Bool = { r in r.map { $0.contains(lp) } ?? false }
        if cancelled {
            if press.dragging { m.nativeDragEnded() }
            if case .port = press.region { m.pendingCable = nil }
            if press.region == .display, let d = it.geo?.display { it.display?.release(lp, d, press.info) }
            DispatchQueue.main.async { m.nativeDrag = false }
            return
        }
        switch press.region {
        case .port:
            m.finishCable(at: screen)
        case .button(let b):
            let r = it.geo?.buttons.first { $0.0 == b }?.1
            if b == .autoRec {
                let held = Date().timeIntervalSince(press.pressedAt)
                if press.autoRecWasOn || held > 0.35 { m.stopAutoRecord(id) }
                break
            }
            guard inside(r?.insetBy(dx: -3, dy: -3)) else { break }
            switch b {
            case .bypass: m.toggleBypass(id)
            case .collapse: m.toggleCollapsed(id)
            case .close: m.removeNode(id)
            case .clearPattern: m.clearPattern(id)
            case .resetAuto: m.clearAutomation(id)
            case .audioMenu:
                var list = [MenuItem(title: "Load audio file…", action: { m.audioImportTarget = id })]
                let sources = m.patch.nodes.filter { $0.id != id && m.node($0.id) is SampleBufferNode }
                if !sources.isEmpty {
                    list.append(.divider)
                    list.append(.section("Copy audio from"))
                    for src in sources { list.append(MenuItem(title: m.label(for: src), action: { m.copyBuffer(from: src.id, to: id) })) }
                }
                presentMenu(list, screen)
            case .autoRec: break
            }
        case .title, .grab, .text:
            if press.dragging { m.nativeDragEnded() }
            else if !press.longFired && !press.info.moved {
                if it.kind == .text && press.info.clickCount >= 2 { beginTextEdit(id, false) }
                else if press.region == .title && press.info.clickCount >= 2 { m.duplicate(id) }
                else if m.selectMode || press.info.shift { m.toggleSelected(id) } else { m.select(id) }
            }
        case .group, .groupName:
            if press.dragging { m.endGroupDrag(); m.scheduleAutosave() }
            else if !press.info.moved, let g = it.group {
                if press.region == .groupName && press.info.clickCount >= 2 { beginTextEdit(id, true) } else { m.selectGroup(g) }
            }
        case .trigger(let i):
            if let r = it.geo?.triggers.first(where: { $0.0 == i })?.1, inside(r) { m.fire(id, i) }
        case .row(let i):
            guard let node = it.node, let spec = it.spec else { break }
            let ps = spec.params[i]
            if !press.info.moved {
                switch ps.kind {
                case .toggle:
                    m.setParam(id, i, m.value(node, i, spec) > 0.5 ? 0 : 1)
                case .choice(let options):
                    let cur = Int(m.value(node, i, spec).rounded())
                    let list = options.indices.map { k in MenuItem(title: options[k], checked: k == cur, action: { m.setParam(id, i, Float(k)) }) }
                    presentMenu(list, screen)
                default:
                    if press.info.clickCount >= 2 { m.setParam(id, i, ps.def) }
                }
            }
            m.scheduleAutosave()
        case .grip:
            if !press.info.moved && press.info.clickCount >= 2 { m.resizeNode(id, width: nil, display: nil) }
            m.scheduleAutosave()
        case .display:
            if let d = it.geo?.display { it.display?.release(lp, d, press.info) }
        case .nothing:
            break
        }
        // stand down once SwiftUI has had its look at the release too
        DispatchQueue.main.async { m.nativeDrag = false }
    }

    func cancelAll() { for k in Array(presses.keys) { ended(k, at: presses[k]?.startScreen ?? .zero, cancelled: true) } }

    // MARK: Help mode

    private var helpShown: [HelpTopic] = []
    func hovered(_ screen: CGPoint?) {
        guard model.helpMode else { if !helpShown.isEmpty { helpShown = [] }; return }
        var topics: [HelpTopic] = []
        if let s = screen, let it = item(at: s) {
            let lp = local(it, s)
            switch it.kind {
            case .group:
                if let g = it.group {
                    topics.append(HelpTopic(id: "group-\(g.id)", title: g.name,
                                            body: "A group. Drag its backdrop to move all its boxes, tap it to select them, double-tap the name to rename. Ungroup from the top bar."))
                }
            case .text: break
            case .module:
                if let spec = it.spec, let geo = it.geo {
                    let h = PortHelp.module(spec)
                    topics.append(HelpTopic(id: "box-\(it.id)", title: h.0, body: h.1))
                    switch region(it, lp) {
                    case .row(let i):
                        let p = PortHelp.param(spec, spec.params[i]); topics.append(HelpTopic(id: "param-\(it.id)-\(i)", title: p.0, body: p.1))
                    case .port(let port, let out):
                        let p = PortHelp.describe(spec, port: port, output: out); topics.append(HelpTopic(id: "port-\(it.id)-\(out)-\(port)", title: p.0, body: p.1))
                    case .button(.autoRec):
                        topics.append(HelpTopic(id: "autorec-\(it.id)", title: "Record automation",
                                                body: "Hold and move this box's controls: the movements are recorded into a 4-bar loop and play back. A quick tap latches recording on; tap again to stop."))
                    case .button(.resetAuto):
                        topics.append(HelpTopic(id: "autoreset-\(it.id)", title: "Reset automation",
                                                body: "Removes every recorded movement in this box. Parameters stay where they are."))
                    default: _ = geo
                    }
                }
            }
        }
        guard topics != helpShown else { return }
        for t in helpShown where !topics.contains(t) { model.hoverHelp(t, inside: false) }
        for t in topics where !helpShown.contains(t) { model.hoverHelp(t, inside: true) }
        helpShown = topics
    }

    // MARK: Files dropped on boxes

    private var dropItem: Item?
    /// A file is dragged over `screen`: light up the box (or rack~ pad) that would take it. True if one would.
    func dropHover(_ screen: CGPoint?) -> Bool {
        var target: Item?, pad: Int?
        if let s = screen, let it = item(at: s), it.kind == .module, let n = it.node {
            if n.kind == "rack" {
                target = it
                if let d = it.geo?.display { pad = it.display?.pad(at: local(it, s), d) }
            } else if model.node(n.id) is SampleBufferNode {
                target = it
            }
        }
        if dropItem !== target || dropItem?.display?.dropPad != pad {
            if let old = dropItem, old !== target { old.dropTarget = false; old.display?.dropPad = nil; old.redraw() }
            dropItem = target
            if let t = target {
                t.display?.dropPad = pad
                t.dropTarget = pad == nil
                t.redraw()
            }
        }
        return target != nil
    }
    /// Files dropped: load them into the box under the point.
    func drop(_ urls: [URL], at screen: CGPoint) -> Bool {
        _ = dropHover(screen)
        defer { _ = dropHover(nil) }
        guard let it = dropItem, let n = it.node, !urls.isEmpty else { return false }
        if n.kind == "rack" {
            let from = it.display?.dropPad ?? Int((n.params["sel"] ?? 0).rounded())
            return model.loadPads(n.id, from: from, urls)
        }
        return model.loadAudio(urls[0], into: n.id)
    }

    // MARK: Text editing (notes, group names)

    /// Where the editor for a note / group name goes (canvas-view coordinates) and its font size.
    func editorFrame(_ id: UUID) -> (CGRect, CGFloat)? {
        let s = model.viewScale
        if let it = items[id], let n = it.node {
            let sz = BoxLayout.textSize(n)
            let p = model.toScreen(CGPoint(x: n.x, y: n.y))
            return (CGRect(x: p.x + 5 * s, y: p.y + 3 * s, width: max(sz.width + 60, 120) * s, height: (sz.height + 15) * s), 12 * s)
        }
        if let it = groupItems[id] {
            let p = model.toScreen(CGPoint(x: it.rect.minX, y: it.rect.minY))
            return (CGRect(x: p.x + 10 * s, y: p.y + 5 * s, width: 180 * s, height: 18 * s), 11 * s)
        }
        return nil
    }
    func setEditing(_ id: UUID?, _ on: Bool) {
        let it = id.flatMap { items[$0] ?? groupItems[$0] }
        it?.editing = on
        it?.redraw()
        editingID = on ? id : nil
    }
}

// MARK: - Mac

#if os(macOS)
private struct Platform: NSViewRepresentable {
    let model: AppModel
    let hover: HoverState
    func makeNSView(context: Context) -> NodesContainer { NodesContainer(model: model, hover: hover) }
    func updateNSView(_ v: NodesContainer, context: Context) {}
    /// It fills what it's given. (Left to AppKit, its size was worked out by loading every box into the
    /// constraint solver — on each change to the patch.)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NodesContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class NodesContainer: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    private let model: AppModel
    private let hover: HoverState
    private let canvas: Canvas
    private var subs = Set<AnyCancellable>()

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        canvas = Canvas(model: model, hover: hover)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(canvas.world)
        registerForDraggedTypes([.fileURL])
        canvas.presentMenu = { [weak self] items, p in self?.showMenu(items, at: p) }
        canvas.beginTextEdit = { [weak self] id, isGroup in self?.startEditing(id, isGroup: isGroup) }
        canvas.endTextEdit = { [weak self] in self?.finishEditing() }
        canvas.repositionEditor = { [weak self] in self?.placeEditor() }
        // the patch, selection … changed: catch up (once per run-loop turn)
        model.objectWillChange
            .receive(on: DispatchQueue.main)   // not RunLoop.main: that pauses while the mouse is held
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.canvas.sync() } }
            .store(in: &subs)
        // pan / zoom: laid out in the next layout pass (once per frame, however many events came in)
        model.viewport.$offset.combineLatest(model.viewport.$scale)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.needsLayout = true } }
            .store(in: &subs)
        model.dragState.moved = { [weak self] in self?.canvas.dragged() }
        canvas.sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        canvas.setBackingScale(window?.backingScaleFactor ?? 2)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        canvas.setBackingScale(window?.backingScaleFactor ?? 2)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        canvas.viewSize = bounds.size
        canvas.viewportChanged()
    }

    /// Only boxes catch the mouse; empty canvas lets it through to the canvas underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview, !model.threeD else { return nil }
        let p = convert(point, from: sv)
        if let e = editor, e.frame.contains(p) { return e.hitTest(e.convert(p, from: self)) ?? e }
        return canvas.item(at: p) != nil ? self : nil
    }

    private func info(_ e: NSEvent) -> PointerInfo {
        var i = PointerInfo()
        i.clickCount = e.clickCount
        i.shift = e.modifierFlags.contains(.shift)
        i.option = e.modifierFlags.contains(.option)
        i.command = e.modifierFlags.contains(.command)
        i.right = e.type == .rightMouseDown || e.modifierFlags.contains(.control)
        return i
    }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        if editor != nil { finishEditing() }
        if !canvas.began(0, at: point(e), info(e)) { super.mouseDown(with: e) }
    }
    override func mouseDragged(with e: NSEvent) { canvas.moved(0, to: point(e)) }
    override func mouseUp(with e: NSEvent) { canvas.ended(0, at: point(e)) }
    override func rightMouseDown(with e: NSEvent) { if !canvas.began(1, at: point(e), info(e)) { super.rightMouseDown(with: e) } }
    override func rightMouseUp(with e: NSEvent) { canvas.ended(1, at: point(e)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        hover.point = p
        canvas.hovered(p)
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { hover.point = nil; canvas.hovered(nil); super.mouseExited(with: event) }

    // MARK: menus

    private final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func run() { action() }
    }
    private var menuTargets: [MenuTarget] = []
    private func showMenu(_ items: [MenuItem], at p: CGPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuTargets = []
        for it in items {
            if it.separator { menu.addItem(.separator()); continue }
            if it.header {
                let h = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                continue
            }
            let mi = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
            if let a = it.action {
                let t = MenuTarget(a)
                menuTargets.append(t)
                mi.target = t
                mi.action = #selector(MenuTarget.run)
            }
            mi.state = it.checked ? .on : .off
            mi.isEnabled = it.enabled
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }

    // MARK: text editing

    private var editor: NSView?
    private var editingID: UUID?
    private var editingGroup = false
    private func startEditing(_ id: UUID, isGroup: Bool) {
        finishEditing()
        guard let (frame, size) = canvas.editorFrame(id) else { return }
        editingID = id; editingGroup = isGroup
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: isGroup ? .semibold : .regular)
        if isGroup {
            let f = NSTextField(frame: frame)
            f.stringValue = model.groups.first { $0.id == id }?.name ?? ""
            f.font = font
            f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
            f.textColor = NSColor(Theme.text)
            f.delegate = self
            addSubview(f)
            editor = f
            window?.makeFirstResponder(f)
        } else {
            let t = NSTextView(frame: frame)
            t.string = model.patch.nodes.first { $0.id == id }?.text ?? ""
            t.font = font
            t.textColor = NSColor(Theme.text)
            t.insertionPointColor = NSColor(Theme.text)
            t.drawsBackground = false
            t.isRichText = false
            t.textContainerInset = .zero
            t.textContainer?.lineFragmentPadding = 0
            t.delegate = self
            addSubview(t)
            editor = t
            model.select(id)
            window?.makeFirstResponder(t)
            t.setSelectedRange(NSRange(location: (t.string as NSString).length, length: 0))
        }
        canvas.setEditing(id, true)
    }
    private func placeEditor() {
        guard let id = editingID, let e = editor, let (frame, size) = canvas.editorFrame(id) else { return }
        e.frame = frame
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: editingGroup ? .semibold : .regular)
        (e as? NSTextView)?.font = font
        (e as? NSTextField)?.font = font
    }
    func textDidChange(_ notification: Notification) {
        guard let id = editingID, let t = editor as? NSTextView, !editingGroup else { return }
        model.setText(id, t.string)
        placeEditor()
    }
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            // Return: done (⌥Return: a new line)
            if NSEvent.modifierFlags.contains(.option) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            finishEditing(); return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishEditing(); return true }
        return false
    }
    func textDidEndEditing(_ notification: Notification) { finishEditing() }
    func controlTextDidEndEditing(_ obj: Notification) { finishEditing() }
    private func finishEditing() {
        guard let id = editingID, let e = editor else { return }
        editingID = nil; editor = nil
        if editingGroup {
            if let f = e as? NSTextField { model.renameGroup(id, f.stringValue) }
        } else if let t = e as? NSTextView {
            model.setText(id, t.string.trimmingCharacters(in: .whitespacesAndNewlines))
            // an empty note that was never written in goes away
            if (model.patch.nodes.first { $0.id == id }?.text ?? "").isEmpty { model.removeNode(id) }
        }
        e.removeFromSuperview()
        canvas.setEditing(id, false)
        window?.makeFirstResponder(nil)
    }

    // MARK: files dropped on boxes

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canvas.dropHover(convert(sender.draggingLocation, from: nil)) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { _ = canvas.dropHover(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return canvas.drop(urls, at: convert(sender.draggingLocation, from: nil))
    }
}
#else

// MARK: - iPad

private struct Platform: UIViewRepresentable {
    let model: AppModel
    let hover: HoverState
    func makeUIView(context: Context) -> NodesContainer { NodesContainer(model: model, hover: hover) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NodesContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    func updateUIView(_ v: NodesContainer, context: Context) {}
}

final class NodesContainer: UIView, UIGestureRecognizerDelegate, UITextViewDelegate, UITextFieldDelegate, UIDropInteractionDelegate {
    private let model: AppModel
    private let hover: HoverState
    private let canvas: Canvas
    private var subs = Set<AnyCancellable>()

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        canvas = Canvas(model: model, hover: hover)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isMultipleTouchEnabled = true
        layer.addSublayer(canvas.world)
        canvas.presentMenu = { [weak self] items, p in self?.showMenu(items, at: p) }
        canvas.beginTextEdit = { [weak self] id, isGroup in self?.startEditing(id, isGroup: isGroup) }
        canvas.endTextEdit = { [weak self] in self?.finishEditing() }
        canvas.repositionEditor = { [weak self] in self?.placeEditor() }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.canvas.sync() } }
            .store(in: &subs)
        model.viewport.$offset.combineLatest(model.viewport.$scale)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.setNeedsLayout() } }
            .store(in: &subs)
        model.dragState.moved = { [weak self] in self?.canvas.dragged() }
        canvas.sync()
        // the iPad's only pinch-zoom: on the window (see didMoveToWindow), so it sees both fingers wherever
        // they land on the canvas — over boxes or not
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(UIDropInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let w = window, pinch.view !== w { pinch.view?.removeGestureRecognizer(pinch); w.addGestureRecognizer(pinch) }
        canvas.setBackingScale(window?.screen.scale ?? 2)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.viewSize = bounds.size
        canvas.viewportChanged()
    }

    private let pinch = UIPinchGestureRecognizer()
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                model.isZooming = true
                canvas.cancelAll()            // a box being dragged with the first finger lets go: the two fingers zoom
            }
            guard g.numberOfTouches >= 2 else { return }
            model.zoom(by: g.scale, around: g.location(in: self))     // keeps the point between the fingers still
            g.scale = 1
        default: model.isZooming = false
        }
    }
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hover.point = g.location(in: self); canvas.hovered(hover.point)
        default: hover.point = nil; canvas.hovered(nil)
        }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === pinch {
            let p = touch.location(in: self)
            return bounds.contains(p) && window != nil && !model.threeD
        }
        return true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !model.threeD else { return nil }
        if let e = editor, e.frame.contains(point) { return e.hitTest(convert(point, to: e), with: event) ?? e }
        return canvas.item(at: point) != nil ? self : nil
    }

    // MARK: touches: each finger is its own press (several faders at once)
    private func key(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }
    private var longTimers: [Int: Timer] = [:]
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editor != nil { finishEditing() }
        for t in touches {
            var i = PointerInfo()
            i.clickCount = t.tapCount
            i.touch = true
            let p = t.location(in: self), k = key(t)
            if canvas.began(k, at: p, i) {
                // a long press on a display opens its menu (rack~ pads)
                longTimers[k] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        var r = PointerInfo(); r.right = true
                        self.canvas.ended(k, at: p, cancelled: true)
                        self.canvas.began(k, at: p, r)
                    }
                }
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let k = key(t)
            let p = t.location(in: self), p0 = t.previousLocation(in: self)
            if hypot(p.x - p0.x, p.y - p0.y) > 0.5 { longTimers[k]?.invalidate(); longTimers[k] = nil }
            canvas.moved(k, to: p)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { let k = key(t); longTimers[k]?.invalidate(); longTimers[k] = nil; canvas.ended(k, at: t.location(in: self)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { let k = key(t); longTimers[k]?.invalidate(); longTimers[k] = nil; canvas.ended(k, at: t.location(in: self), cancelled: true) }
    }

    // MARK: menus
    private var parentController: UIViewController? {
        sequence(first: next, next: { $0?.next }).first(where: { $0 is UIViewController }) as? UIViewController
    }
    private func showMenu(_ items: [MenuItem], at p: CGPoint) {
        guard let vc = parentController else { return }
        let sheet = UIAlertController(title: items.first(where: { $0.header })?.title, message: nil, preferredStyle: .actionSheet)
        for it in items where !it.separator && !it.header {
            let a = UIAlertAction(title: (it.checked ? "✓ " : "") + it.title, style: .default) { _ in it.action?() }
            a.isEnabled = it.enabled
            sheet.addAction(a)
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = CGRect(x: p.x, y: p.y, width: 1, height: 1)
        vc.present(sheet, animated: true)
    }

    // MARK: text editing
    private var editor: UIView?
    private var editingID: UUID?
    private var editingGroup = false
    private func startEditing(_ id: UUID, isGroup: Bool) {
        finishEditing()
        guard let (frame, size) = canvas.editorFrame(id) else { return }
        editingID = id; editingGroup = isGroup
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: isGroup ? .semibold : .regular)
        if isGroup {
            let f = UITextField(frame: frame)
            f.text = model.groups.first { $0.id == id }?.name ?? ""
            f.font = font; f.textColor = UIColor(Theme.text); f.delegate = self
            addSubview(f); editor = f
            f.becomeFirstResponder()
        } else {
            let t = UITextView(frame: frame)
            t.text = model.patch.nodes.first { $0.id == id }?.text ?? ""
            t.font = font; t.textColor = UIColor(Theme.text); t.backgroundColor = .clear
            t.textContainerInset = .zero; t.textContainer.lineFragmentPadding = 0
            t.delegate = self
            addSubview(t); editor = t
            model.select(id)
            t.becomeFirstResponder()
        }
        canvas.setEditing(id, true)
    }
    private func placeEditor() {
        guard let id = editingID, let e = editor, let (frame, size) = canvas.editorFrame(id) else { return }
        e.frame = frame
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: editingGroup ? .semibold : .regular)
        (e as? UITextView)?.font = font
        (e as? UITextField)?.font = font
    }
    func textViewDidChange(_ textView: UITextView) {
        guard let id = editingID else { return }
        model.setText(id, textView.text)
        placeEditor()
    }
    func textViewDidEndEditing(_ textView: UITextView) { finishEditing() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { finishEditing(); return false }
    func textFieldDidEndEditing(_ textField: UITextField) { finishEditing() }
    private func finishEditing() {
        guard let id = editingID, let e = editor else { return }
        editingID = nil; editor = nil
        if editingGroup {
            if let f = e as? UITextField { model.renameGroup(id, f.text ?? "") }
        } else if let t = e as? UITextView {
            model.setText(id, t.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if (model.patch.nodes.first { $0.id == id }?.text ?? "").isEmpty { model.removeNode(id) }
        }
        e.resignFirstResponder()
        e.removeFromSuperview()
        canvas.setEditing(id, false)
    }

    // MARK: files dropped on boxes
    func dropInteraction(_ i: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSURL.self) || session.hasItemsConforming(toTypeIdentifiers: [UTType.audio.identifier])
    }
    func dropInteraction(_ i: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: canvas.dropHover(session.location(in: self)) ? .copy : .cancel)
    }
    func dropInteraction(_ i: UIDropInteraction, sessionDidExit session: UIDropSession) { _ = canvas.dropHover(nil) }
    func dropInteraction(_ i: UIDropInteraction, performDrop session: UIDropSession) {
        let p = session.location(in: self)
        _ = session.loadObjects(ofClass: NSURL.self) { [weak self] objs in
            let urls = objs.compactMap { ($0 as? NSURL) as URL? }
            DispatchQueue.main.async { _ = self?.canvas.drop(urls, at: p) }
        }
    }
}
#endif

private struct HostedNodesKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside NodesHost's layer (each box its own view: drags are measured in window coordinates).
    var hostedNodes: Bool {
        get { self[HostedNodesKey.self] }
        set { self[HostedNodesKey.self] = newValue }
    }
}
