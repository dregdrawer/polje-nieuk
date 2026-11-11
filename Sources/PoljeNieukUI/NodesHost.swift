import SwiftUI
import Combine
import PoljeNieukCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The boxes, notes and group backdrops — each in its own native view — and the cables as one native
/// vector layer.
///
/// Why: with every box in one shared SwiftUI layer, *any* change (a box moved a pixel, one small display
/// ticking) made SwiftUI re-render the whole layer: dragging a box cost ~40 % of a core, displays ~1–2 ms
/// each. Now a moving box is just a moved view (no re-rendering at all), a ticking display only redraws its
/// own box, and the cables are a plain path.
///
/// Pan / zoom: the boxes are laid out at the "drawn" pan / zoom (`HostedZoom`); while you pan or zoom, the
/// whole layer is moved / stretched as a picture, and laid out afresh once you stop.
struct NodesHost: View {
    let model: AppModel
    /// the pointer / Pencil-tip position the canvas highlights ports by (hovering over boxes lands here)
    let hover: HoverState
    var body: some View { Platform(model: model, hover: hover) }
}

/// One box's content, drawn at the laid-out zoom, with room around it for the ports that stick out.
private struct BoxRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var zoom: HostedZoom
    let id: UUID
    let group: Bool
    var body: some View {
        content
            .coordinateSpace(name: NativeLive.space)          // live displays report their place in the box here
            .environment(\.liveBox, group ? nil : id)
            .environment(\.canvasZoom, zoom.scale <= 1 ? 1 : (zoom.scale * 4).rounded() / 4)
            .environment(\.hostedNodes, true)
            .environment(\.helpModeOn, model.helpMode)       // a separate view tree: nothing is inherited
            .scaleEffect(zoom.scale, anchor: .topLeading)
            // laid out at exactly its zoomed size: larger, the hosting view would centre it (boxes drifted off
            // their cables)
            .frame(width: size.width * zoom.scale, height: size.height * zoom.scale, alignment: .topLeading)
            .padding(NodesLayout.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    /// unzoomed size of what this view shows
    private var size: CGSize {
        if group {
            if let g = model.groups.first(where: { $0.id == id }), let r = model.groupRect(g) { return r.size }
            return .zero
        }
        guard let n = model.patch.nodes.first(where: { $0.id == id }) else { return .zero }
        if n.kind == "text" { return BoxLayout.textSize(n) }
        guard let spec = ModuleRegistry.spec(n.kind) else { return .zero }
        return CGSize(width: BoxLayout.width(n), height: BoxLayout.height(n, spec, model.hw))
    }
    @ViewBuilder private var content: some View {
        if group {
            if let g = model.groups.first(where: { $0.id == id }), let r = model.groupRect(g) {
                GroupBackdrop(model: model, group: g, rect: r)
            }
        } else if let n = model.patch.nodes.first(where: { $0.id == id }) {
            if n.kind == "text" { FreeText(model: model, node: n) }
            else if let spec = ModuleRegistry.spec(n.kind) { ModuleBox(model: model, node: n, spec: spec) }
        }
    }
}

struct CableEnd { let from: UUID, to: UUID; let a: CGPoint, b: CGPoint; let style: Int }

enum NodesLayout {
    /// space around each box's view for the ports, which stick out over its edges
    static let pad: CGFloat = 12
}

/// Where the layer goes: laid out at the drawn offset / zoom, then moved as a picture to the live ones.
private struct Placement {
    var offset: CGSize, live: CGFloat
    var drawnOffset: CGSize, drawn: CGFloat
    var stretch: CGFloat { live / max(drawn, 0.001) }
    /// the move from the laid-out place to the live one (container coordinates, y down, about its top-left)
    var move: CGAffineTransform {
        let r = stretch
        return CGAffineTransform(a: r, b: 0, c: 0, d: r,
                                 tx: offset.width - drawnOffset.width * r, ty: offset.height - drawnOffset.height * r)
    }
    var isStill: Bool { move.isIdentity }
    /// zoomed far enough that the stretched picture would blur: lay out afresh (even mid-gesture)
    var outrun: Bool { stretch < 0.6 || stretch > 1.6 }
}

private extension AppModel {
    func subscribePlacement(_ place: @escaping (Placement) -> Void) -> AnyCancellable {
        viewport.$offset.combineLatest(viewport.$scale, hostedZoom.$offset, hostedZoom.$scale)
            .sink { o, s, dO, d in place(Placement(offset: o, live: s, drawnOffset: dO, drawn: d)) }
    }
    var placement: Placement {
        Placement(offset: viewOffset, live: viewScale, drawnOffset: hostedZoom.offset, drawn: hostedZoom.scale)
    }
    func relayHosted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.hostedZoom.scale != self.viewScale { self.hostedZoom.scale = self.viewScale }
            if self.hostedZoom.offset != self.viewOffset { self.hostedZoom.offset = self.viewOffset }
        }
    }
    /// A box's view frame in the layer: canvas rect at the drawn zoom / offset, plus the port margin.
    func boxFrame(_ n: PatchNode, drag: CGSize) -> CGRect? {
        let s = hostedZoom.scale, o = hostedZoom.offset
        let w: CGFloat, h: CGFloat
        if n.kind == "text" { let t = BoxLayout.textSize(n); w = t.width; h = t.height }
        else if let spec = ModuleRegistry.spec(n.kind) { w = BoxLayout.width(n); h = BoxLayout.height(n, spec, hw) } else { return nil }
        let p = NodesLayout.pad
        return CGRect(x: (n.x + drag.width) * s + o.width - p, y: (n.y + drag.height) * s + o.height - p,
                      width: w * s + 2 * p, height: h * s + 2 * p)
    }
    func groupFrame(_ g: PatchGroup, drag: Bool = true) -> CGRect? {
        guard let r = groupRect(g) else { return nil }
        let s = hostedZoom.scale, o = hostedZoom.offset, p = NodesLayout.pad
        let d = drag && !g.members.isEmpty && Set(g.members).isSubset(of: dragState.ids) ? dragState.delta : .zero
        return CGRect(x: (r.minX + d.width) * s + o.width - p, y: (r.minY + d.height) * s + o.height - p,
                      width: r.width * s + 2 * p, height: r.height * s + 2 * p)
    }
    /// Every cable's two ends in canvas points (worked out from the boxes' layouts — the slow part, so it's
    /// done once per change, not on every pointer move while dragging), and its style: 0 plain, 1 dashed, 2 selected.
    func cableEnds() -> [CableEnd] {
        guard !hideCables else { return [] }
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
    /// The cables as paths in layer coordinates (dragged boxes' ends shifted by the drag).
    func cablePaths(_ ends: [CableEnd]) -> (CGPath, CGPath, CGPath, CGFloat) {
        let s = hostedZoom.scale, o = hostedZoom.offset
        let dragging = dragState.ids, d = dragState.delta
        func map(_ c: CGPoint, _ id: UUID) -> CGPoint {
            let m = dragging.contains(id) ? d : .zero
            return CGPoint(x: (c.x + m.width) * s + o.width, y: (c.y + m.height) * s + o.height)
        }
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for e in ends {
            var path = Path()
            addCable(&path, map(e.a, e.from), map(e.b, e.to), scale: s)
            paths[e.style].addPath(path.cgPath)
        }
        return (paths[0], paths[1], paths[2], max(1, 1.5 * s))
    }
}

#if os(macOS)
private typealias PView = NSView
private typealias PColor = NSColor
#else
private typealias PView = UIView
private typealias PColor = UIColor
#endif

/// Holds the cable layers.
#if os(macOS)
private final class CableView: NSView {
    let root = CALayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { root }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
private final class CableView: UIView {
    var root: CALayer { layer }
}
#endif

/// The parts shared by the Mac and iPad containers: box views, cable layers, layout.
@MainActor
private final class Layer {
    let model: AppModel
    let mover: PView
    private(set) var boxes: [UUID: PView] = [:]
    /// per box: the view its native live displays' layers sit in (above the box's SwiftUI content)
    private var overlays: [UUID: CableView] = [:]
    private let liveEntries = NSHashTable<NativeLiveEntry>.weakObjects()
    private var liveZoom: CGFloat = -1
    private var groups: [UUID: PView] = [:]
    private var order: [UUID] = []
    private let plain = CAShapeLayer(), dashed = CAShapeLayer(), selected = CAShapeLayer()
    private let cableHolder = CableView()
    let makeHost: (AnyView) -> PView

    init(model: AppModel, mover: PView, makeHost: @escaping (AnyView) -> PView) {
        self.model = model; self.mover = mover; self.makeHost = makeHost
        // the cables' layers live in the cable view's own backing layer (a flipped view on the Mac, so y runs
        // down like the boxes' frames)
        let host = cableHolder.root
        #if os(iOS)
        cableHolder.isUserInteractionEnabled = false
        #endif
        for l in [plain, dashed, selected] {
            l.fillColor = nil; l.lineCap = .round
            host.addSublayer(l)
        }
        dashed.lineDashPattern = [4, 3]
        mover.addSubview(cableHolder)
        NativeLive.place = { [weak self] e in self?.placeLive(e) }
    }

    /// A box's view: its SwiftUI content, with a pass-through view on top for its native live displays.
    private func boxView(_ id: UUID, _ root: AnyView) -> PView {
        let host = makeHost(root)
        let box = PView()
        let overlay = CableView()
        #if os(macOS)
        box.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        #else
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        #endif
        box.addSubview(host)
        box.addSubview(overlay)
        overlays[id] = overlay
        return box
    }

    /// Put a native display's layer on its box, at its place at the laid-out zoom.
    func placeLive(_ e: NativeLiveEntry) {
        liveEntries.add(e)
        guard e.slot.active, let id = e.boxID, let overlay = overlays[id], e.rect.width > 0, e.rect.height > 0 else { return }
        let root = overlay.root
        if e.layer.superlayer !== root { root.addSublayer(e.layer) }
        let z = model.hostedZoom.scale, p = NodesLayout.pad
        #if os(macOS)
        let scale = mover.window?.backingScaleFactor ?? 2
        #else
        let scale = mover.window?.screen.scale ?? 2
        #endif
        let f = CGRect(x: p + e.rect.minX * z, y: p + e.rect.minY * z, width: e.rect.width * z, height: e.rect.height * z)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if e.layer.frame != f { e.layer.frame = f }
        if e.layer.contentsScale != scale { e.layer.contentsScale = scale }
        CATransaction.commit()
        if e.zoom != z { e.zoom = z }
        e.layer.setNeedsDisplay()
    }

    /// Everything: views for new boxes, frames, stacking, cables.
    func layoutAll() {
        let ids = model.patch.nodes.map(\.id)
        let alive = Set(ids)
        for (id, v) in boxes where !alive.contains(id) { v.removeFromSuperview(); boxes[id] = nil; overlays[id] = nil }
        let gids = Set(model.groups.map(\.id))
        for (id, v) in groups where !gids.contains(id) { v.removeFromSuperview(); groups[id] = nil }
        for g in model.groups {
            let v = groups[g.id] ?? { let h = makeHost(AnyView(BoxRoot(model: model, zoom: model.hostedZoom, id: g.id, group: true)))
                                      groups[g.id] = h
                                      #if os(macOS)
                                      mover.addSubview(h, positioned: .below, relativeTo: cableHolder)
                                      #else
                                      mover.insertSubview(h, belowSubview: cableHolder)
                                      #endif
                                      return h }()
            if let f = model.groupFrame(g, drag: false), v.frame != f { v.frame = f }
            shift(v, !g.members.isEmpty && Set(g.members).isSubset(of: model.dragState.ids) ? model.dragState.delta : .zero)
        }
        for n in model.patch.nodes {
            let v = boxes[n.id] ?? { let h = boxView(n.id, AnyView(BoxRoot(model: model, zoom: model.hostedZoom, id: n.id, group: false)))
                                     boxes[n.id] = h; mover.addSubview(h); return h }()
            if let f = model.boxFrame(n, drag: .zero), v.frame != f { v.frame = f }
            shift(v, model.dragState.offset(n.id))
        }
        if ids != order {
            // stacking follows the patch (the last box is on top)
            order = ids
            for id in ids { if let v = boxes[id] { v.removeFromSuperview(); mover.addSubview(v) } }
        }
        if liveZoom != model.hostedZoom.scale {
            liveZoom = model.hostedZoom.scale
            for e in liveEntries.allObjects { placeLive(e) }
        }
        layoutCables()
    }

    /// While boxes are dragged: only theirs move (no SwiftUI work at all), and the cables follow.
    /// While boxes are dragged they move as pictures (a layer transform): their real frames stay put until
    /// they're let go. Moving the frames on every pointer move made the window re-lay-out the box and
    /// rebuild the mouse cursor each time (a third of a core).
    func layoutDragged() {
        let d = model.dragState.delta
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in model.dragState.ids { if let v = boxes[id] { shift(v, d) } }
        for g in model.groups where !g.members.isEmpty && Set(g.members).isSubset(of: model.dragState.ids) {
            if let v = groups[g.id] { shift(v, d) }
        }
        CATransaction.commit()
        layoutCables(fresh: false)
    }

    /// Shift a view by a drag (canvas points) without touching its frame.
    private func shift(_ v: PView, _ d: CGSize) {
        let s = model.hostedZoom.scale
        let t = CGAffineTransform(translationX: d.width * s, y: d.height * s)
        #if os(macOS)
        guard let l = v.layer else { return }
        let yDown = l.superlayer?.contentsAreFlipped() ?? true
        let tt = yDown ? t : CGAffineTransform(translationX: t.tx, y: -t.ty)
        if l.affineTransform() != tt { l.setAffineTransform(tt) }
        #else
        if v.transform != t { v.transform = t }
        #endif
    }

    /// Every box lays itself out (and so draws its content) in the coming layout pass.
    func markHostsForLayout() {
        for v in Array(boxes.values) + Array(groups.values) {
            #if os(macOS)
            v.needsLayout = true
            #else
            v.setNeedsLayout()
            #endif
        }
    }

    private var ends: [CableEnd] = []
    /// `fresh`: the boxes changed (work the cable ends out again); otherwise reuse them (a drag)
    func layoutCables(fresh: Bool = true) {
        if cableHolder.frame != mover.bounds { cableHolder.frame = mover.bounds }
        if fresh { ends = model.cableEnds() }
        let (p, d, s, w) = model.cablePaths(ends)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let cable = PColor(Theme.cable).cgColor, sel = PColor(Theme.selected).cgColor
        plain.path = p; plain.strokeColor = cable; plain.lineWidth = w
        dashed.path = d; dashed.strokeColor = cable; dashed.lineWidth = w
        dashed.lineDashPattern = [NSNumber(value: Double(4 * model.hostedZoom.scale)), NSNumber(value: Double(3 * model.hostedZoom.scale))]
        selected.path = s; selected.strokeColor = sel; selected.lineWidth = w + 1.5
        CATransaction.commit()
    }

    /// The box whose grab area (title, empty port space …) is under this point (mover coordinates), if any.
    /// Only the topmost box under the point counts.
    func grabbable(at p: CGPoint) -> UUID? {
        let z = model.hostedZoom.scale, pad = NodesLayout.pad
        for n in model.patch.nodes.reversed() {
            guard let v = boxes[n.id] else { continue }
            let box = v.frame.insetBy(dx: pad, dy: pad)
            guard box.contains(p) else { continue }
            let local = CGPoint(x: (p.x - box.minX) / z, y: (p.y - box.minY) / z)
            return model.dragZones[n.id]?.values.contains { $0.contains(local) } == true ? n.id : nil
        }
        return nil
    }

    /// Is there a box (or backdrop) under this point (mover coordinates)?
    func hasView(at p: CGPoint) -> Bool {
        boxes.values.contains { $0.frame.contains(p) } || groups.values.contains { $0.frame.contains(p) }
    }
}

#if os(macOS)
private struct Platform: NSViewRepresentable {
    let model: AppModel
    let hover: HoverState
    func makeNSView(context: Context) -> NodesContainer { NodesContainer(model: model, hover: hover) }
    func updateNSView(_ v: NodesContainer, context: Context) {}
}

/// A box's native view: clicks on its empty margin go through to the canvas.
private final class BoxHostView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }

}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class NodesContainer: NSView {
    private let model: AppModel
    private let hover: HoverState
    /// carries the pan / zoom move as a layer transform, so AppKit doesn't re-lay-out anything while moving
    private let mover = FlippedView()
    private var layer2: Layer!
    private var subs = Set<AnyCancellable>()
    private var placement: Placement

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        placement = model.placement
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        addSubview(mover)
        layer2 = Layer(model: model, mover: mover, makeHost: { root in
            let h = BoxHostView(rootView: root)
            h.sizingOptions = []
            return h
        })
        model.subscribePlacement { [weak self] p in self?.place(p) }.store(in: &subs)
        // the patch, selection, zoom … changed: lay out (soon, once per run-loop turn)
        // a zoom change is laid out in the layout pass (see place), not here
        model.objectWillChange
            .receive(on: DispatchQueue.main)   // not RunLoop.main: that pauses while the mouse is held (dragged boxes froze)
            .sink { [weak self] _ in self?.layer2.layoutAll() }
            .store(in: &subs)
        model.dragState.moved = { [weak self] in self?.layer2.layoutDragged() }
        layer2.layoutAll()
        // box drags straight from the mouse (see DragZone); everything else carries on to SwiftUI as before
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouse(e) } ?? e
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private var monitor: Any?
    private var pressID: UUID?
    private var pressStart = CGPoint.zero
    private var dragging = false

    private func mouse(_ e: NSEvent) -> NSEvent {
        guard e.window === window else { return e }
        let p = convert(e.locationInWindow, from: nil)
        switch e.type {
        case .leftMouseDown:
            pressID = nil; dragging = false; model.nativeDrag = false
            guard placement.isStill, !model.threeD, !model.isZooming,
                  e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
                  let hit = window?.contentView?.hitTest(e.locationInWindow), hit.isDescendant(of: self),
                  let id = layer2.grabbable(at: p) else { return e }
            pressID = id; pressStart = p; model.nativeDrag = true
        case .leftMouseDragged:
            guard let id = pressID else { return e }
            if !dragging {
                guard hypot(p.x - pressStart.x, p.y - pressStart.y) > 2 else { return e }
                dragging = true
                model.nativeDragBegan(id)
            }
            model.nativeDragMoved(by: CGSize(width: p.x - pressStart.x, height: p.y - pressStart.y), at: p)
        case .leftMouseUp:
            if dragging { model.nativeDragEnded() }
            pressID = nil; dragging = false
            // stand down once SwiftUI has seen this mouse-up too
            DispatchQueue.main.async { [weak self] in self?.model.nativeDrag = false }
        default: break
        }
        return e
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hover.point = convert(event.locationInWindow, from: nil); super.mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hover.point = nil; super.mouseExited(with: event) }

    private var laidOut: (CGFloat, CGSize)?
    private var pendingSwap = false
    private func place(_ p: Placement) {
        // zoom settled: the boxes are redrawn sharp at the new zoom. The swap (new frames, stretch removed)
        // happens in the window's layout pass — the same pass in which each box's SwiftUI content draws at
        // the new zoom — so it all reaches the screen in one frame. (Done any earlier, the boxes showed
        // half-updated for a frame: the flicker when a zoom stopped.)
        if let l = laidOut, l.0 != p.drawn || l.1 != p.drawnOffset {
            laidOut = (p.drawn, p.drawnOffset)
            pendingSwap = true
            needsLayout = true
            layer2.markHostsForLayout()
            return
        }
        laidOut = (p.drawn, p.drawnOffset)
        apply(p)
    }

    override func layout() {
        super.layout()
        guard pendingSwap else { return }
        pendingSwap = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer2.layoutAll()
        apply(model.placement)
        CATransaction.commit()
    }

    private func apply(_ p: Placement) {
        placement = p
        if mover.frame != bounds { mover.frame = bounds }
        guard let layer = mover.layer else { return }
        let mv = p.move, h = bounds.height
        var t = CATransform3DIdentity
        if !p.isStill {
            let yDown = layer.superlayer?.contentsAreFlipped() ?? true
            let ty = yDown ? mv.ty : h - mv.d * h - mv.ty
            t = CATransform3DMakeAffineTransform(CGAffineTransform(a: mv.a, b: 0, c: 0, d: mv.d, tx: mv.tx, ty: ty))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.transform = t
        CATransaction.commit()
        // no redraw mid-zoom (every box re-rendering, again and again): the picture stretches, and is
        // redrawn sharp once, when the zoom settles
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply(placement)
    }

    /// Only boxes catch the mouse; empty canvas lets it through. (Mid-move nothing in here is clickable.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview, placement.isStill else { return nil }
        let local = convert(point, from: sv)
        guard layer2.hasView(at: local) else { return nil }
        let v = super.hitTest(point)
        return v === self || v === mover ? nil : v
    }
}
#else
private struct Platform: UIViewRepresentable {
    let model: AppModel
    let hover: HoverState
    func makeUIView(context: Context) -> NodesContainer { NodesContainer(model: model, hover: hover) }
    func updateUIView(_ v: NodesContainer, context: Context) {}
}

final class NodesContainer: UIView, UIGestureRecognizerDelegate {
    private let model: AppModel
    private let hover: HoverState
    private let mover = UIView()
    private var layer2: Layer!
    private var hosts: [UIHostingController<AnyView>] = []
    private var subs = Set<AnyCancellable>()
    private var placement: Placement

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        placement = model.placement
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        mover.layer.anchorPoint = .zero
        mover.backgroundColor = .clear
        addSubview(mover)
        layer2 = Layer(model: model, mover: mover, makeHost: { [weak self] root in
            let h = UIHostingController(rootView: root)
            h.view.backgroundColor = .clear
            h.safeAreaRegions = []
            h.sizingOptions = []
            self?.adopt(h)
            return h.view
        })
        model.subscribePlacement { [weak self] p in self?.place(p) }.store(in: &subs)
        // a zoom change is laid out in the layout pass (see place), not here
        model.objectWillChange
            .receive(on: DispatchQueue.main)   // not RunLoop.main: that pauses while the mouse is held (dragged boxes froze)
            .sink { [weak self] _ in self?.layer2.layoutAll() }
            .store(in: &subs)
        model.dragState.moved = { [weak self] in self?.layer2.layoutDragged() }
        layer2.layoutAll()
        // the canvas's own pinch and hover don't see touches that land on boxes: handled here
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        // box drags straight from the finger (see DragZone)
        boxPan.addTarget(self, action: #selector(dragged(_:)))
        boxPan.delegate = self
        boxPan.maximumNumberOfTouches = 1
        addGestureRecognizer(boxPan)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func adopt(_ h: UIHostingController<AnyView>) {
        hosts.append(h)
        if let parent = parentController, h.parent == nil { parent.addChild(h); h.didMove(toParent: parent) }
    }
    private var parentController: UIViewController? {
        sequence(first: next, next: { $0?.next }).first(where: { $0 is UIViewController }) as? UIViewController
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // the hosting controllers need a parent for menus, popovers and keyboard focus
        if window != nil, let parent = parentController {
            for h in hosts where h.parent == nil { parent.addChild(h); h.didMove(toParent: parent) }
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            model.isZooming = true
            model.zoom(by: g.scale, around: g.location(in: self))
            g.scale = 1
        default: model.isZooming = false
        }
    }
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hover.point = g.location(in: self)
        default: hover.point = nil
        }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private let boxPan = UIPanGestureRecognizer()
    private var panID: UUID?
    private var panStart = CGPoint.zero
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard g === boxPan else { return true }
        // decided at touch-down, so the box's own (later) gesture stands aside from the start
        let p = touch.location(in: self)
        panID = placement.isStill && !model.threeD && !model.isZooming ? layer2.grabbable(at: convert(p, to: mover)) : nil
        panStart = p
        model.nativeDrag = panID != nil
        return panID != nil
    }
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let id = panID else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            model.nativeDragBegan(id)
            model.nativeDragMoved(by: CGSize(width: p.x - panStart.x, height: p.y - panStart.y), at: p)
        case .changed:
            model.nativeDragMoved(by: CGSize(width: p.x - panStart.x, height: p.y - panStart.y), at: p)
        default:
            model.nativeDragEnded()
            panID = nil
            DispatchQueue.main.async { [weak self] in self?.model.nativeDrag = false }
        }
    }

    private var laidOut: (CGFloat, CGSize)?
    private var pendingSwap = false
    /// zoom settled: swap in the layout pass, where the boxes draw at the new zoom (no flicker; see the Mac)
    private func place(_ p: Placement) {
        if let l = laidOut, l.0 != p.drawn || l.1 != p.drawnOffset {
            laidOut = (p.drawn, p.drawnOffset)
            pendingSwap = true
            setNeedsLayout()
            layer2.markHostsForLayout()
            return
        }
        laidOut = (p.drawn, p.drawnOffset)
        apply(p)
    }

    private func apply(_ p: Placement) {
        placement = p
        mover.transform = .identity
        mover.bounds = CGRect(origin: .zero, size: bounds.size)
        mover.layer.position = .zero
        mover.transform = p.move
        // no redraw mid-zoom (every box re-rendering, again and again): the picture stretches, and is
        // redrawn sharp once, when the zoom settles
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if pendingSwap {
            pendingSwap = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer2.layoutAll()
            apply(model.placement)
            CATransaction.commit()
        } else {
            apply(placement)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let local = convert(point, to: mover)
        guard layer2.hasView(at: local) else { return nil }
        let v = super.hitTest(point, with: event)
        return v === self || v === mover ? nil : v
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
