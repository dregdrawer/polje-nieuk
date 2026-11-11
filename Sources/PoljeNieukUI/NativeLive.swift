import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Live displays drawn natively, the way Pure Data updates a canvas item.
//
// A live display (an LFO's curve, a meter, a playhead, a modulated row …) is a plain Core Animation layer
// on its box. A tick that changes it redraws just that layer: no SwiftUI update at all. Before this, every
// tick re-ran SwiftUI's update and layout for the whole box (~1 ms each), and a patch with a few dozen
// moving displays spent most of a core on that.
//
// The drawing code is shared with the SwiftUI path (used where native layers can't go: 3D mode, displays
// with SwiftUI drawn on top of them): it draws into `LiveGC`, which writes to either backend.

/// The drawing calls live displays use, on a Core Graphics context or a SwiftUI one.
struct LiveGC {
    enum Shading { case color(Color) }
    fileprivate let cg: CGContext?
    fileprivate let gc: GraphicsContext?
    init(cg: CGContext) { self.cg = cg; gc = nil }
    init(_ gc: GraphicsContext) { self.gc = gc; cg = nil }

    func fill(_ p: Path, with s: Shading, style: FillStyle = FillStyle()) {
        guard case .color(let col) = s else { return }
        if let gc { gc.fill(p, with: .color(col), style: style); return }
        guard let cg else { return }
        cg.addPath(p.cgPath)
        cg.setFillColor(LiveColor.cg(col))
        cg.fillPath(using: style.isEOFilled ? .evenOdd : .winding)
    }

    func stroke(_ p: Path, with s: Shading, lineWidth: CGFloat = 1) {
        stroke(p, with: s, style: StrokeStyle(lineWidth: lineWidth))
    }

    func stroke(_ p: Path, with s: Shading, style: StrokeStyle) {
        guard case .color(let col) = s else { return }
        if let gc { gc.stroke(p, with: .color(col), style: style); return }
        guard let cg else { return }
        cg.saveGState()
        cg.addPath(p.cgPath)
        cg.setStrokeColor(LiveColor.cg(col))
        cg.setLineWidth(style.lineWidth)
        cg.setLineCap(style.lineCap)
        cg.setLineJoin(style.lineJoin)
        if !style.dash.isEmpty { cg.setLineDash(phase: style.dashPhase, lengths: style.dash) }
        cg.strokePath()
        cg.restoreGState()
    }

    /// Text, anchored like GraphicsContext.draw(_:at:anchor:).
    func draw(_ t: LiveText, at p: CGPoint, anchor: UnitPoint = .center) {
        if let gc {
            gc.draw(Text(t.string).font(.system(size: t.size, weight: t.bold ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(t.color), at: p, anchor: anchor)
            return
        }
        guard let cg, !t.string.isEmpty else { return }
        let line = LiveColor.line(t)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        let h = asc + desc
        let x = p.x - anchor.x * w, top = p.y - anchor.y * h
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)        // the context runs y-down
        cg.textPosition = CGPoint(x: x, y: top + asc)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// Draw `body` clipped to `p` (GraphicsContext.drawLayer + clip).
    func clipped(to p: Path, _ body: (LiveGC) -> Void) {
        if let gc {
            gc.drawLayer { l in
                l.clip(to: p)
                body(LiveGC(l))
            }
            return
        }
        guard let cg else { return }
        cg.saveGState()
        cg.addPath(p.cgPath)
        cg.clip()
        body(self)
        cg.restoreGState()
    }
}

/// A line of monospaced text for a live display.
struct LiveText {
    let string: String
    let size: CGFloat
    let color: Color
    var bold = false
    init(_ string: String, size: CGFloat = 9, color: Color, bold: Bool = false) {
        self.string = string; self.size = size; self.color = color; self.bold = bold
    }
}

/// Colour and text conversions for the native path (cached: the same few colours and labels repeat).
/// Only ever used while drawing, on the main thread.
enum LiveColor {
    nonisolated(unsafe) private static var colors: [Color: CGColor] = [:]
    nonisolated(unsafe) private static var version = -1
    static func cg(_ c: Color) -> CGColor {
        // custom colours / light ↔ dark change what a Theme colour is: start the cache afresh then
        let v = MainActor.assumeIsolated { CustomColours.version &* 2 &+ (Theme.light ? 1 : 0) }
        if v != version { version = v; colors = [:]; lines = [:] }
        if let hit = colors[c] { return hit }
        #if os(macOS)
        let r = NSColor(c).cgColor
        #else
        let r = UIColor(c).cgColor
        #endif
        if colors.count > 512 { colors = [:] }
        colors[c] = r
        return r
    }

    private struct LineKey: Hashable { let s: String; let size: CGFloat; let bold: Bool; let color: Color }
    nonisolated(unsafe) private static var lines: [LineKey: CTLine] = [:]
    static func line(_ t: LiveText) -> CTLine {
        let key = LineKey(s: t.string, size: t.size, bold: t.bold, color: t.color)
        if let hit = lines[key] { return hit }
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular) as CTFont
        #else
        let font = UIFont.monospacedSystemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular) as CTFont
        #endif
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(t.color),
        ]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: t.string, attributes: attrs))
        if lines.count > 2048 { lines = [:] }
        lines[key] = l
        return l
    }
}

/// One native live display: its layer, what it draws, and where it sits in its box.
@MainActor final class NativeLiveEntry: NSObject, ObservableObject, CALayerDelegate {
    let layer = CALayer()
    let slot = LiveSlot()
    var draw: ((LiveGC, CGSize) -> Void)?
    var boxID: UUID?
    /// where the display sits in its box (box points, unzoomed)
    var rect: CGRect = .zero {
        didSet { if rect != oldValue { NativeLive.place(self) } }
    }
    /// the zoom the layer is laid out at (its content is drawn scaled by this, so it stays sharp)
    var zoom: CGFloat = 1

    override init() {
        super.init()
        layer.delegate = self
        layer.isOpaque = false
        layer.masksToBounds = true
        layer.zPosition = 10
        layer.needsDisplayOnBoundsChange = true
        slot.onChange = { [weak self] in self?.layer.setNeedsDisplay() }
        slot.attach()
    }

    func detach() {
        slot.active = false
        layer.removeFromSuperlayer()
    }
    func reattach() {
        slot.active = true
        NativeLive.place(self)
    }

    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        MainActor.assumeIsolated { self.render(ctx) }
    }
    private func render(_ ctx: CGContext) {
        guard let draw else { return }
        let s = layer.bounds.size
        guard s.width > 0, s.height > 0 else { return }
        if !layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: s.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let z = max(zoom, 0.01)
        ctx.scaleBy(x: z, y: z)
        draw(LiveGC(cg: ctx), CGSize(width: s.width / z, height: s.height / z))
    }
    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

@MainActor enum NativeLive {
    /// The coordinate space of a box's content (unzoomed), that displays report their place in.
    static let space = "liveBox"
    /// Set by the boxes' container: put / move an entry's layer on its box.
    static var place: (NativeLiveEntry) -> Void = { _ in }
}

private struct LiveBoxKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct LiveOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    /// The box a display belongs to (set where boxes are hosted natively; nil elsewhere).
    var liveBox: UUID? {
        get { self[LiveBoxKey.self] }
        set { self[LiveBoxKey.self] = newValue }
    }
    /// The box's dimming (bypassed boxes are drawn at 35 %): native layers apply it themselves.
    var liveOpacity: Double {
        get { self[LiveOpacityKey.self] }
        set { self[LiveOpacityKey.self] = newValue }
    }
}

/// Where a box can be grabbed to move it (its title, the empty port-row space, free text), reported in
/// the box's own coordinates whenever its layout changes. The canvas moves boxes from these places itself,
/// straight from the mouse / touch events — SwiftUI's gesture handling put a dragged box a frame or more
/// behind the pointer.
struct DragZone: View {
    let model: AppModel
    let id: UUID
    let key: Int
    /// keep clear of the edges, where the ports are (dragging from a port makes a cable)
    var inset: CGFloat = 0
    @Environment(\.liveBox) private var box
    var body: some View {
        if box != nil {
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NativeLive.space)) } action: { r in
                    model.dragZones[id, default: [:]][key] = r.insetBy(dx: min(inset, r.width / 2), dy: 0)
                }
                .onDisappear { model.dragZones[id]?[key] = nil }
        }
    }
}
