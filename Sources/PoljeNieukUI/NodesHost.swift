import SwiftUI
import Combine
import PoljeNieukCore

/// The boxes (and notes and group backdrops) drawn in their own native layer.
///
/// Panning used to move SwiftUI's copy of all the boxes, and SwiftUI then re-placed every box, port, row
/// and gesture on every frame (and AppKit re-checked every hover area and tooltip) — a 26-box patch took a
/// whole core just to slide around. Here the boxes are laid out once, at the "drawn" pan / zoom
/// (`HostedZoom`), into a layer the size of the window plus a margin; while you pan or zoom that layer is only
/// moved / stretched as a picture. Once you stop — or the pan runs past the margin — it's laid out afresh.
///
/// Inside the layer a box at canvas point c sits at c·drawnZoom + drawnOffset + margin.
/// Touches on empty canvas fall through to the canvas behind.
struct NodesHost: View {
    let model: AppModel
    /// the pointer / Pencil-tip position the canvas highlights ports by (hovering over boxes lands here)
    let hover: HoverState
    /// The coordinate space of the layer: gestures in boxes measure drags in it.
    static let space = "nodes"

    var body: some View {
        Platform(model: model, hover: hover)
    }
}

/// What the layer shows: the boxes at the pan / zoom it was last laid out at.
private struct HostedNodes: View {
    @ObservedObject var model: AppModel
    @ObservedObject var zoom: HostedZoom

    /// What the cables' drawing depends on.
    private var cablesKey: Int {
        var h = Hasher()
        for c in model.patch.cables { h.combine(c.id); h.combine(c.fromPort); h.combine(c.toPort) }
        for n in model.patch.nodes {
            h.combine(n.id); h.combine(n.x); h.combine(n.y); h.combine(n.collapsed)
            h.combine(BoxLayout.width(n))
            if let spec = ModuleRegistry.spec(n.kind) { h.combine(BoxLayout.height(n, spec, model.hw)) }
        }
        h.combine(model.selectedCable); h.combine(model.insertCandidates); h.combine(model.hideCables)
        h.combine(CustomColours.version); h.combine(Theme.light)
        return h.finalize()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // the cables are in this layer too, so boxes and cables always move as one
            HostedCables(model: model, key: cablesKey, scale: zoom.scale,
                         origin: CGPoint(x: zoom.offset.width + zoom.margin, y: zoom.offset.height + zoom.margin))
                .equatable()
            NodesLayer(model: model).equatable()
                // live displays draw at the zoomed pixel density, so they stay sharp (see LiveCanvas)
                .environment(\.canvasZoom, zoom.scale <= 1 ? 1 : (zoom.scale * 4).rounded() / 4)
                .environment(\.hostedNodes, true)
                .environment(\.helpModeOn, model.helpMode)    // a separate view tree: nothing is inherited
                .scaleEffect(zoom.scale, anchor: .topLeading)
                .offset(x: zoom.offset.width + zoom.margin, y: zoom.offset.height + zoom.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: NodesHost.space)
    }
}

/// The cables, drawn in the layer's own coordinates (canvas point c → c·scale + origin).
/// Redrawn only when `key` changes (cables, box places / sizes, selection) — not on every pointer move.
private struct HostedCables: View, Equatable {
    let model: AppModel
    let key: Int
    let scale: CGFloat
    let origin: CGPoint
    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.scale == b.scale && a.origin == b.origin }

    private func map(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x * scale + origin.x, y: c.y * scale + origin.y) }

    var body: some View {
        var plain = Path(), dashed = Path(), selected = Path()
        let hw = model.hw
        for c in model.hideCables ? [] : model.patch.cables {
            guard let ai = model.patch.index(of: c.fromNode), let bi = model.patch.index(of: c.toNode) else { continue }
            let a = model.patch.nodes[ai], b = model.patch.nodes[bi]
            guard let sa = ModuleRegistry.spec(a.kind), let sb = ModuleRegistry.spec(b.kind),
                  c.fromPort < BoxLayout.ports(a, sa, hw).outs.count,
                  let dest = BoxLayout.destination(b, sb, hw, port: c.toPort) else { continue }
            let p = map(BoxLayout.outlet(a, sa, hw, c.fromPort)), q = map(dest)
            if model.selectedCable == c.id || model.insertCandidates.contains(c.id) { addCable(&selected, p, q, scale: scale) }
            else if c.toPort >= kParamPortBase { addCable(&dashed, p, q, scale: scale) }
            else { addCable(&plain, p, q, scale: scale) }
        }
        let w = max(1, 1.5 * scale)
        return ZStack(alignment: .topLeading) {
            plain.stroke(Theme.cable, style: StrokeStyle(lineWidth: w, lineCap: .round))
            dashed.stroke(Theme.cable, style: StrokeStyle(lineWidth: w, lineCap: .round, dash: [4, 3]))
            selected.stroke(Theme.selected, style: StrokeStyle(lineWidth: w + 1.5, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

/// Where the layer goes: laid out at the drawn offset / zoom, then moved as a picture to the live ones.
private struct Placement {
    var offset: CGSize, live: CGFloat
    var drawnOffset: CGSize, drawn: CGFloat
    /// how much the drawn layer is stretched
    var stretch: CGFloat { live / max(drawn, 0.001) }
    /// the move from the laid-out place to the live one (container coordinates, y down, about its top-left)
    var move: CGAffineTransform {
        let r = stretch
        return CGAffineTransform(a: r, b: 0, c: 0, d: r,
                                 tx: offset.width - drawnOffset.width * r, ty: offset.height - drawnOffset.height * r)
    }
    var isStill: Bool { move.isIdentity }
    /// canvas-view point → canvas point
    func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / live, y: (p.y - offset.height) / live)
    }
    /// Has the move gone far enough that the layer's margin no longer covers the window?
    func outrun(margin: CGFloat) -> Bool {
        let m = move
        return abs(m.tx) > margin * 0.6 || abs(m.ty) > margin * 0.6 || stretch < 0.6 || stretch > 1.6
    }
}

private extension AppModel {
    func subscribePlacement(_ place: @escaping (Placement) -> Void) -> AnyCancellable {
        viewport.$offset.combineLatest(viewport.$scale, hostedZoom.$offset, hostedZoom.$scale)
            .sink { o, s, dO, d in place(Placement(offset: o, live: s, drawnOffset: dO, drawn: d)) }
    }
    var placement: Placement {
        Placement(offset: viewOffset, live: viewScale, drawnOffset: hostedZoom.offset, drawn: hostedZoom.scale)
    }
    /// lay the boxes out afresh at the live pan / zoom (soon, not inside a publish)
    func relayHosted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.hostedZoom.scale != self.viewScale { self.hostedZoom.scale = self.viewScale }
            if self.hostedZoom.offset != self.viewOffset { self.hostedZoom.offset = self.viewOffset }
        }
    }
}

/// The margin round the window the layer covers, so a pan shows boxes coming in from off-screen.
private func margin(for size: CGSize) -> CGFloat { (max(size.width, size.height) * 0.6).rounded() }

#if os(macOS)
private struct Platform: NSViewRepresentable {
    let model: AppModel
    let hover: HoverState
    func makeNSView(context: Context) -> NodesContainer { NodesContainer(model: model, hover: hover) }
    func updateNSView(_ v: NodesContainer, context: Context) {}
}

final class NodesContainer: NSView {
    private let model: AppModel
    private let hover: HoverState
    /// carries the move while panning / zooming — a layer transform, so AppKit doesn't re-lay-out the boxes
    /// or re-check every hover area and tooltip on each frame
    private let mover = NSView()
    private let host: NSHostingView<AnyView>
    private var sub: AnyCancellable?
    private var placement: Placement
    private var relayPending = false

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        host = NSHostingView(rootView: AnyView(HostedNodes(model: model, zoom: model.hostedZoom)))
        placement = model.placement
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        addSubview(mover)
        host.sizingOptions = []
        mover.addSubview(host)
        sub = model.subscribePlacement { [weak self] p in self?.place(p) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // The pointer over boxes: report it to the canvas, which lights up the port under it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        hover.point = convert(event.locationInWindow, from: nil)
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        hover.point = nil
        super.mouseExited(with: event)
    }

    private func place(_ p: Placement) {
        placement = p
        let m = model.hostedZoom.margin
        if mover.frame != bounds { mover.frame = bounds }
        let f = bounds.insetBy(dx: -m, dy: -m)
        if host.frame != f { host.frame = f }
        guard let layer = mover.layer else { return }
        // the layer sits in its parent's space, which may be y-up from the bottom-left: turn the y-down move into that
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
        if p.outrun(margin: m), !relayPending {
            relayPending = true
            model.relayHosted()
            DispatchQueue.main.async { [weak self] in self?.relayPending = false }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let m = margin(for: newSize)
        if model.hostedZoom.margin != m { model.hostedZoom.margin = m }
        place(placement)
    }

    /// Only boxes catch the mouse; empty canvas lets it through to the canvas (pan, marquee, double-click…).
    /// (While the layer is mid-move nothing in it is clickable: the canvas is being dragged anyway.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview, placement.isStill else { return nil }
        let c = placement.canvasPoint(convert(point, from: sv))
        guard model.hasContent(at: c) else { return nil }
        return super.hitTest(point)
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
    private let host: UIHostingController<AnyView>
    /// carries the move while panning / zooming (a transform about its top-left corner)
    private let mover = UIView()
    private var sub: AnyCancellable?
    private var placement: Placement
    private var relayPending = false

    init(model: AppModel, hover: HoverState) {
        self.model = model
        self.hover = hover
        host = UIHostingController(rootView: AnyView(HostedNodes(model: model, zoom: model.hostedZoom)))
        placement = model.placement
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        mover.layer.anchorPoint = .zero
        mover.backgroundColor = .clear
        addSubview(mover)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.sizingOptions = []
        mover.addSubview(host.view)
        sub = model.subscribePlacement { [weak self] p in self?.place(p) }
        // the canvas's own pinch and hover don't see touches that land on boxes (they belong to this
        // layer): pinching with fingers on boxes, and the Pencil hovering over ports, are handled here
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            model.isZooming = true
            model.zoom(by: g.scale, around: g.location(in: self))
            g.scale = 1
        default:
            model.isZooming = false
        }
    }
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hover.point = g.location(in: self)
        default: hover.point = nil
        }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func place(_ p: Placement) {
        placement = p
        let m = model.hostedZoom.margin
        mover.transform = .identity
        mover.bounds = CGRect(origin: .zero, size: bounds.size)
        mover.layer.position = .zero
        let f = CGRect(origin: .zero, size: bounds.size).insetBy(dx: -m, dy: -m)
        if host.view.frame != f { host.view.frame = f }
        mover.transform = p.move
        if p.outrun(margin: m), !relayPending {
            relayPending = true
            model.relayHosted()
            DispatchQueue.main.async { [weak self] in self?.relayPending = false }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = margin(for: bounds.size)
        if model.hostedZoom.margin != m { model.hostedZoom.margin = m }
        place(placement)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // the hosting controller needs a parent for menus, popovers and keyboard focus
        if window != nil, host.parent == nil,
           let parent = sequence(first: next, next: { $0?.next }).first(where: { $0 is UIViewController }) as? UIViewController {
            parent.addChild(host)
            host.didMove(toParent: parent)
        }
    }

    /// Only boxes catch touches; empty canvas lets them through to the canvas (pan, marquee, double-tap…).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard model.hasContent(at: placement.canvasPoint(point)) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif

private struct HostedNodesKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside NodesHost's layer.
    var hostedNodes: Bool {
        get { self[HostedNodesKey.self] }
        set { self[HostedNodesKey.self] = newValue }
    }
}
