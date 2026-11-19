import SwiftUI
import PoljeNieukCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The 3D camera: the patch board seen in perspective — spun around (yaw) and tilted away from you (pitch).
/// Works both ways — a point on the board (at a height) to the screen, and a screen point back onto the
/// board — so dragging lands exactly under your finger.
///
/// Board coordinates are the flat view's screen coordinates (canvas × zoom + pan); `h` is the height above
/// the board in the same units. The board spins about `centre` and tilts about the horizontal line through it.
public struct BoardCamera: Equatable, Sendable {
    public var tilt: Double            // pitch, radians (0 = flat, looking straight down)
    public var yaw: Double             // spin of the board, radians
    public var distance: Double        // perspective: smaller = stronger
    public var centre: CGPoint

    public init(viewSize: CGSize, tilt: Double = 52 * .pi / 180, yaw: Double = 0, distance: Double = 1500) {
        self.tilt = tilt
        self.yaw = yaw
        self.distance = distance
        centre = CGPoint(x: viewSize.width / 2, y: viewSize.height * 0.55)
    }

    /// Board point → (u, v) relative to the centre, after the spin.
    @inline(__always) private func spun(_ p: CGPoint) -> (Double, Double) {
        let x = Double(p.x - centre.x), y = Double(p.y - centre.y)
        return (x * cos(yaw) - y * sin(yaw), x * sin(yaw) + y * cos(yaw))
    }

    /// Relative to how far the board's middle is: > 1 nearer, < 1 farther.
    @inline(__always) func w(_ v: Double, _ h: Double) -> Double {
        (distance - v * sin(tilt) - h * cos(tilt)) / distance
    }

    /// How near a board point at height `h` is (bigger = nearer) — for drawing order.
    public func nearness(_ p: CGPoint, h: Double = 0) -> Double { w(spun(p).1, h) }

    /// A board point (flat screen coordinates) at height `h` → where it appears on screen.
    public func project(_ p: CGPoint, h: Double = 0) -> CGPoint {
        let (u, v) = spun(p)
        let ww = max(w(v, h), 0.05)
        return CGPoint(x: Double(centre.x) + u / ww, y: Double(centre.y) + (v * cos(tilt) - h * sin(tilt)) / ww)
    }

    /// A screen point → the board point (flat screen coordinates) under it at height `h`.
    public func unproject(_ q: CGPoint, h: Double = 0) -> CGPoint {
        let k = Double(q.y - centre.y) / distance
        let den = cos(tilt) + k * sin(tilt)
        let v = abs(den) < 1e-6 ? 0 : (k * (distance - h * cos(tilt)) + h * sin(tilt)) / den
        let u = Double(q.x - centre.x) * max(w(v, h), 0.05)
        // undo the spin
        let x = u * cos(yaw) + v * sin(yaw), y = -u * sin(yaw) + v * cos(yaw)
        return CGPoint(x: Double(centre.x) + x, y: Double(centre.y) + y)
    }

    /// The perspective transform that draws a box (laid out in its own canvas units, `scale` = zoom) whose
    /// top-left sits at board point `origin`, at height `h`. Matches `project` exactly.
    public func boxTransform(origin: CGPoint, h: Double, scale s: Double) -> ProjectionTransform {
        let st = sin(tilt), ct = cos(tilt), d = distance, cy = cos(yaw), sy = sin(yaw)
        let x0 = Double(origin.x - centre.x), y0 = Double(origin.y - centre.y)
        let cu = Double(centre.x), cv = Double(centre.y)
        // spun board coordinates of a local point (x, y): u = a1 x + b1 y + c1, v = a2 x + b2 y + c2
        let a1 = s * cy, b1 = -s * sy, c1 = cy * x0 - sy * y0
        let a2 = s * sy, b2 = s * cy, c2 = sy * x0 + cy * y0
        // w = (d − v·st − h·ct) / d ; x'w = cu·w + u ; y'w = cv·w + v·ct − h·st
        let wx = -st / d * a2, wy = -st / d * b2, w0 = -st / d * c2 + (d - h * ct) / d
        var t = ProjectionTransform()
        t.m11 = CGFloat(cu * wx + a1); t.m21 = CGFloat(cu * wy + b1); t.m31 = CGFloat(cu * w0 + c1)
        t.m12 = CGFloat(cv * wx + ct * a2); t.m22 = CGFloat(cv * wy + ct * b2); t.m32 = CGFloat(cv * w0 + ct * c2 - h * st)
        t.m13 = CGFloat(wx); t.m23 = CGFloat(wy); t.m33 = CGFloat(w0)
        return t
    }
}

/// A box in 3D: rebuilt only when the box itself changes — moving the camera or another box just changes
/// its perspective transform (which is cheap).
private struct StillBox: View, Equatable {
    let model: AppModel
    let node: PatchNode
    /// what the box shows besides its own settings (its cables, selection, audio on / off)
    let rev: Int
    static func == (a: StillBox, b: StillBox) -> Bool { a.node == b.node && a.rev == b.rev }
    var body: some View {
        Group {
            if node.kind == "text" {
                FreeText(model: model, node: node, rev: rev)
            } else if let spec = ModuleRegistry.spec(node.kind) {
                ModuleBox(model: model, node: node, rev: rev, spec: spec)
            }
        }
        // live displays hold still in 3D (redrawing a box in perspective is the expensive part)
        .environment(\.liveDisplaysOn, false)
    }
}

/// 3D mode: the board, shadows, height stems, cables and lift dots drawn in one Canvas; the boxes as their
/// real views placed with perspective transforms (farthest first). One gesture layer on top: drag a box to
/// move it on the board, drag its dot to raise / lower it, drag empty board to pan. Orbit: three fingers
/// (iPad) or a right-click drag (Mac).
struct Board3DView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewport: Viewport
    let size: CGSize

    private var cam: BoardCamera {
        BoardCamera(viewSize: size, tilt: model.orbitPitch * .pi / 180, yaw: model.orbitYaw * .pi / 180)
    }
    private var s: Double { Double(model.viewScale) }
    private var o: CGSize { model.viewOffset }

    /// canvas point → board (flat screen) point
    private func board(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s + o.width, y: p.y * s + o.height) }
    private func height(_ n: PatchNode) -> Double { (n.z ?? 0) * s }
    private func boxSize(_ n: PatchNode) -> CGSize {
        if n.kind == "text" { return BoxLayout.textSize(n) }
        guard let spec = ModuleRegistry.spec(n.kind) else { return .zero }
        return CGSize(width: BoxLayout.width(n), height: BoxLayout.height(n, spec, model.hw))
    }
    private func centreOf(_ n: PatchNode) -> CGPoint {
        let sz = boxSize(n), o = board(CGPoint(x: n.x, y: n.y))
        return CGPoint(x: o.x + sz.width * s / 2, y: o.y + sz.height * s / 2)
    }

    /// Lower boxes first, so a lifted box always covers what's below it (seen from above, a higher plane is
    /// always nearer along your line of sight); within the same height, farthest first.
    private func drawOrder(_ cam: BoardCamera) -> [PatchNode] {
        model.patch.nodes
            .map { ($0, (($0.z ?? 0) * 100).rounded(), cam.nearness(centreOf($0), h: height($0))) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    var body: some View {
        let cam = cam
        let order = drawOrder(cam)
        ZStack(alignment: .topLeading) {
            Theme.bg
            Canvas { ctx, _ in drawBoard(ctx, cam) }
                .allowsHitTesting(false)
            // empty board: drag to pan (the boxes above take their own touches)
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in pan(v, cam) }
                    .onEnded { _ in panStart = nil; model.scheduleAutosave() })
                .onTapGesture { model.clearSelection() }
            // the boxes: live — rows, toggles and menus work through the perspective; drag a title to move
            ForEach(order) { n in
                StillBox(model: model, node: n, rev: model.boxRev(n.id)).equatable()
                    .fixedSize()
                    .projectionEffect(cam.boxTransform(origin: board(CGPoint(x: n.x, y: n.y)), h: height(n), scale: s))
            }
            // lift dots: drag up / down to raise or lower a box
            ForEach(order) { n in
                LiftDot()
                    .position(cam.project(dotPoint(n), h: height(n)))
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if lifting?.id != n.id { lifting = (n.id, n.z ?? 0); model.select(n.id) }
                            model.setHeight(n.id, (lifting?.z ?? 0) + Double(v.startLocation.y - v.location.y) * 1.6 / s)
                        }
                        .onEnded { _ in lifting = nil; model.scheduleAutosave() })
            }
            OrbitInput(model: model)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @State private var panStart: (offset: CGSize, board: CGPoint)?
    @State private var lifting: (id: UUID, z: Double)?

    private func pan(_ v: DragGesture.Value, _ cam: BoardCamera) {
        if panStart == nil { panStart = (model.viewOffset, cam.unproject(v.startLocation)) }
        guard let st = panStart else { return }
        let now = cam.unproject(v.location)
        model.viewOffset = CGSize(width: st.offset.width + (now.x - st.board.x), height: st.offset.height + (now.y - st.board.y))
    }

    // MARK: drawing

    private func quad(_ cam: BoardCamera, _ r: CGRect, h: Double) -> Path {
        var p = Path()
        p.move(to: cam.project(CGPoint(x: r.minX, y: r.minY), h: h))
        p.addLine(to: cam.project(CGPoint(x: r.maxX, y: r.minY), h: h))
        p.addLine(to: cam.project(CGPoint(x: r.maxX, y: r.maxY), h: h))
        p.addLine(to: cam.project(CGPoint(x: r.minX, y: r.maxY), h: h))
        p.closeSubpath()
        return p
    }

    private func drawBoard(_ ctx: GraphicsContext, _ cam: BoardCamera) {
        // the grid: lines every 120 canvas units over a large area around the view, drawn in short pieces and
        // only where they're in front of the camera — so it's there at any angle, fading toward the horizon
        let span = max(size.width, size.height) * 3.5
        let step = max(120 * s, 30)
        let phaseX = CGFloat(fmod(Double(o.width), Double(step))), phaseY = CGFloat(fmod(Double(o.height), Double(step)))
        let x0 = ((cam.centre.x - span) / step).rounded(.down) * step + phaseX
        let y0 = ((cam.centre.y - span) / step).rounded(.down) * step + phaseY
        let x1 = cam.centre.x + span, y1 = cam.centre.y + span
        let pieces = 28
        var near = Path(), far = Path()
        func line(_ a: CGPoint, _ b: CGPoint) {
            for k in 0..<pieces {
                let t0 = CGFloat(k) / CGFloat(pieces), t1 = CGFloat(k + 1) / CGFloat(pieces)
                let p0 = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                let p1 = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                let n0 = cam.nearness(p0), n1 = cam.nearness(p1)
                guard n0 > 0.12, n1 > 0.12 else { continue }               // behind / at the horizon: skip
                if min(n0, n1) > 0.45 { near.move(to: cam.project(p0)); near.addLine(to: cam.project(p1)) }
                else { far.move(to: cam.project(p0)); far.addLine(to: cam.project(p1)) }
            }
        }
        var x = x0
        while x <= x1 { line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y1)); x += step }
        var y = y0
        while y <= y1 { line(CGPoint(x: x0, y: y), CGPoint(x: x1, y: y)); y += step }
        ctx.stroke(near, with: .color(Theme.gridDot.opacity(0.9)), lineWidth: 0.6)
        ctx.stroke(far, with: .color(Theme.gridDot.opacity(0.4)), lineWidth: 0.5)

        // shadows and stems under floating boxes
        for n in model.patch.nodes where (n.z ?? 0) > 0.5 {
            let r = CGRect(origin: board(CGPoint(x: n.x, y: n.y)), size: CGSize(width: boxSize(n).width * s, height: boxSize(n).height * s))
            ctx.fill(quad(cam, r, h: 0), with: .color(.black.opacity(Theme.light ? 0.10 : 0.35)))
            var stem = Path()
            stem.move(to: cam.project(CGPoint(x: r.midX, y: r.maxY), h: 0))
            stem.addLine(to: cam.project(CGPoint(x: r.midX, y: r.maxY), h: height(n)))
            ctx.stroke(stem, with: .color(Theme.dim.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // cables, between the boxes at their heights
        let byID = Dictionary(uniqueKeysWithValues: model.patch.nodes.map { ($0.id, $0) })
        for c in model.hideCables ? [] : model.patch.cables {
            guard let a = byID[c.fromNode], let b = byID[c.toNode], let sa = ModuleRegistry.spec(a.kind),
                  let sb = ModuleRegistry.spec(b.kind), let dest = BoxLayout.destination(b, sb, model.hw, port: c.toPort),
                  c.fromPort < BoxLayout.ports(a, sa, model.hw).outs.count else { continue }
            let p1 = cam.project(board(BoxLayout.outlet(a, sa, model.hw, c.fromPort)), h: height(a))
            let p2 = cam.project(board(dest), h: height(b))
            var path = Path()
            path.move(to: p1)
            let dx = max(30, abs(p2.x - p1.x) * 0.45)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + dx, y: p1.y), control2: CGPoint(x: p2.x - dx, y: p2.y))
            ctx.stroke(path, with: .color(Theme.cable), style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                                             dash: c.toPort >= kParamPortBase ? [4, 3] : []))
        }
    }

    /// The lift dot: just above each box's top-right corner.
    private func dotPoint(_ n: PatchNode) -> CGPoint {
        let o = board(CGPoint(x: n.x, y: n.y)), w = boxSize(n).width * s
        return CGPoint(x: o.x + w - 8, y: o.y - 12)
    }

}

/// The lift dot (drag it up or down to raise or lower a box), with a finger-sized grab area.
private struct LiftDot: View {
    var body: some View {
        Circle().fill(Theme.text).frame(width: 12, height: 12)
            .frame(width: 30, height: 30).contentShape(Circle())
    }
}

// MARK: - Orbit input: three fingers on the iPad, a right-click drag on the Mac

#if os(iOS)
/// Adds a three-finger pan to the window while 3D is showing (and switches off iPadOS's own three-finger
/// undo / redo swipes there, which would otherwise fight it).
private struct OrbitInput: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> OrbitView { OrbitView(model: model) }
    func updateUIView(_ v: OrbitView, context: Context) {}
    static func dismantleUIView(_ v: OrbitView, coordinator: ()) { v.detach() }

    final class OrbitView: UIView {
        let model: AppModel
        private var pan: UIPanGestureRecognizer?
        private var start: (pitch: Double, yaw: Double) = (0, 0)
        init(model: AppModel) { self.model = model; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let p = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
            p.minimumNumberOfTouches = 3
            p.maximumNumberOfTouches = 3
            p.cancelsTouchesInView = true
            window.addGestureRecognizer(p)
            pan = p
            becomeFirstResponder()
        }
        func detach() {
            if let pan, let v = pan.view { v.removeGestureRecognizer(pan) }
            pan = nil
            resignFirstResponder()
        }
        override var canBecomeFirstResponder: Bool { true }
        // no three-finger undo / redo / copy / paste gestures while orbiting the board
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            MainActor.assumeIsolated {
                switch g.state {
                case .began: start = (model.orbitPitch, model.orbitYaw)
                case .changed:
                    let t = g.translation(in: g.view)
                    model.orbit(pitch: start.pitch - Double(t.y) * 0.25, yaw: start.yaw - Double(t.x) * 0.3)
                default: break
                }
            }
        }
    }
}
#else
/// Right-click drag anywhere on the board orbits it (while 3D is showing).
private struct OrbitInput: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> OrbitView { OrbitView(model: model) }
    func updateNSView(_ v: OrbitView, context: Context) {}
    static func dismantleNSView(_ v: OrbitView, coordinator: ()) { v.detach() }

    final class OrbitView: NSView {
        let model: AppModel
        private var monitor: Any?
        private var start: (pitch: Double, yaw: Double, at: NSPoint)?
        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                return MainActor.assumeIsolated { self.handle(e) }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }

        private func handle(_ e: NSEvent) -> NSEvent? {
            switch e.type {
            case .rightMouseDown:
                start = (model.orbitPitch, model.orbitYaw, e.locationInWindow)
                return nil
            case .rightMouseDragged:
                guard let s = start else { return e }
                let dx = e.locationInWindow.x - s.at.x, dy = e.locationInWindow.y - s.at.y   // window y goes up
                model.orbit(pitch: s.pitch + Double(dy) * 0.25, yaw: s.yaw - Double(dx) * 0.3)
                return nil
            default:
                start = nil
                return nil
            }
        }
    }
}
#endif

