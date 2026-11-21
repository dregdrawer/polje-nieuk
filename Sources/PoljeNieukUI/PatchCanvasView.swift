import SwiftUI
import PoljeNieukCore

/// The patcher: pan by dragging empty space, pinch anywhere to zoom, double-tap empty space for the module list,
/// drag from an outlet (right edge) to an inlet or parameter inlet (left edge) to connect,
/// tap a cable to select it (× deletes), double-tap a cable to delete it straight away.
#if os(iOS)
private let cableHitRadius: CGFloat = 24     // fingers are wide
private let panThreshold: CGFloat = 10
private let deleteButtonSize: CGFloat = 34
#else
private let cableHitRadius: CGFloat = 10
private let panThreshold: CGFloat = 3
private let deleteButtonSize: CGFloat = 24
#endif
struct PatchCanvasView: View {
    #if os(macOS)
    static let swiftUIPinch = true
    #else
    static let swiftUIPinch = false
    #endif
    @ObservedObject var model: AppModel
    /// pan / zoom: the canvas re-renders on these, the boxes layer doesn't
    @ObservedObject private var viewport: Viewport
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _viewport = ObservedObject(wrappedValue: model.viewport)
    }
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var marquee: CGRect?                // selection box being drawn (view coordinates)
    @State private var finderHeight: CGFloat = 420
    /// True only while two fingers are pinching. GestureState resets itself however the pinch ends —
    /// including when iPadOS cancels it — so box dragging can never get stuck "paused".
    @GestureState private var pinching = false
    @StateObject private var hover = HoverState()
    @FocusState private var canvasFocused: Bool
    /// the canvas's left edge in the window, last seen
    @State private var canvasLeft: CGFloat?
    #if os(macOS)
    @State private var scrollMonitor: Any?
    @State private var magnifyMonitor: Any?
    /// the canvas's frame in window coordinates (top-left origin), read by the scroll monitor
    @State private var canvasFrameBox = FrameBox()
    #endif

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                // the boxes live in their own native layer that pan / zoom slide around directly:
                // moving SwiftUI's own copy made it re-place every box, every port and every gesture
                // on each frame — panning a 26-box patch took a whole core
                NodesHost(model: model, hover: hover)
                // the cable you're dragging: a light layer on top, so following the pointer
                // doesn't redraw every box and cable
                if model.pendingCable != nil { PendingCableView(model: model).allowsHitTesting(false) }
                if let m = marquee ?? model.rightMarquee {
                    Rectangle().fill(Theme.text.opacity(0.06))
                        .overlay(Rectangle().stroke(Theme.text.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: m.width, height: m.height)
                        .offset(x: m.minX, y: m.minY)
                        .allowsHitTesting(false)
                }
                cableDeleteButton
                PortHoverOverlay(model: model, hover: hover)
                if model.finderAt != nil || model.showColours || model.boxMenu != nil {
                    // a menu is open: the first touch anywhere else closes it — straight away, without
                    // waiting to see whether it's a double-tap (that wait was the lag)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.finderAt = nil; model.showColours = false; model.boxMenu = nil }
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in model.finderAt = nil; model.showColours = false; model.boxMenu = nil })
                }
                if let bm = model.boxMenu {
                    let x = min(max(bm.at.x, 8), max(geo.size.width - BoxMenuView.width - 8, 8))
                    let y = min(max(bm.at.y, 8), max(geo.size.height - 110, 8))
                    BoxMenuView(model: model, id: bm.id).offset(x: x, y: y)
                }
                if let at = model.finderAt {
                    // keep the whole list on screen: open it where you tapped, but shift it up/left
                    // when that would run off an edge (and scroll inside it if the screen is too short)
                    let s = model.toScreen(at)
                    let maxH = max(geo.size.height - 16, 120)
                    let h = min(finderHeight, maxH)
                    let x = min(max(s.x, 8), max(geo.size.width - ObjectFinder.size.width - 8, 8))
                    let y = min(max(s.y, 8), max(geo.size.height - h - 8, 8))
                    ObjectFinder(model: model, canvasPoint: at, maxHeight: maxH, contentHeight: $finderHeight)
                        .offset(x: x, y: y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // Pencil hover (iPad Pro) and mouse pointer: highlight the port under the tip
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): hover.point = p
                case .ended: hover.point = nil
                }
            }
            #if os(iOS)
            .background(PencilBridge(
                onTap: {
                    if let c = model.selectedCable { model.removeCable(c) }
                    else { for id in model.selectedNodes { model.toggleBypass(id) } }
                },
                onSqueeze: { loc in
                    if model.finderAt != nil { model.finderAt = nil; return }
                    let p = loc ?? hover.point ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 3)
                    model.clearSelection()
                    model.finderAt = model.toCanvas(p)
                }))
            #endif
            // pinch anywhere — over boxes too — to zoom around your fingers. (On the iPad the boxes' layer does
            // the pinching for the whole canvas — two pinch handlers fought each other.)
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinching) { _, state, _ in state = true }
                    .onChanged { v in
                        if zoomStart == nil { zoomStart = model.viewScale }
                        let old = model.viewScale
                        let new = min(max((zoomStart ?? 1) * v.magnification, 0.12), 2.0)
                        let anchor = v.startLocation
                        let cx = (anchor.x - model.viewOffset.width) / old
                        let cy = (anchor.y - model.viewOffset.height) / old
                        model.viewScale = new
                        model.viewOffset = CGSize(width: anchor.x - cx * new, height: anchor.y - cy * new)
                    }
                    .onEnded { _ in zoomStart = nil },
                including: Self.swiftUIPinch ? .all : .subviews
            )
            .onChange(of: pinching) { _, on in
                model.isZooming = on
                if !on { zoomStart = nil }
            }
            .coordinateSpace(name: "canvas")
            #if os(macOS)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { canvasFrameBox.frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in canvasFrameBox.frame = f }
            })
            .onAppear { installScrollZoom() }
            .onDisappear {
                if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
                if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
            }
            #endif
            .onAppear { model.viewSize = geo.size }
            .onChange(of: geo.size) { _, s in model.viewSize = s }
            // the browser opening / closing moves the canvas's left edge: move the view the other way,
            // so the patch stays put on screen
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { model.canvasGlobalOrigin = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { x in
                if let old = canvasLeft, old != x {
                    model.viewOffset = CGSize(width: model.viewOffset.width - (x - old), height: model.viewOffset.height)
                }
                canvasLeft = x
            }
        }
        #if os(macOS)
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onDeleteCommand { if model.finderAt == nil { model.removeSelection() } }
        #endif
    }

    #if os(macOS)
    /// Scrolling over the canvas (mouse wheel or two-finger trackpad) zooms around the pointer, like the
    /// pinch. Drag empty space to pan. Scrolling the module list or the file browser is left alone.
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        let model = model
        let frameBox = canvasFrameBox
        // trackpad pinch with the pointer over a box: the boxes live in their own layer, which the
        // canvas's pinch gesture doesn't see — zoom from here (over empty canvas the gesture does it)
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let loc = content.convert(event.locationInWindow, from: nil)
            let p = CGPoint(x: loc.x, y: content.isFlipped ? loc.y : content.bounds.height - loc.y)
            let consumed: Bool = MainActor.assumeIsolated {
                let frame = frameBox.frame
                guard frame.width > 0, frame.contains(p) else { return false }
                let anchor = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
                guard model.hasContent(at: model.toCanvas(anchor)) else { return false }
                model.isZooming = event.phase != .ended && event.phase != .cancelled
                model.zoom(by: 1 + event.magnification, around: anchor)
                return true
            }
            return consumed ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, let content = window.contentView, window.isVisible else { return event }
            let loc = content.convert(event.locationInWindow, from: nil)
            let p = CGPoint(x: loc.x, y: content.isFlipped ? loc.y : content.bounds.height - loc.y)
            let precise = event.hasPreciseScrollingDeltas
            // "away from you" (wheel up / fingers up) zooms in, whatever the natural-scrolling setting
            let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            let dy = event.isDirectionInvertedFromDevice ? -raw : raw
            // trackpad: smooth, proportional; mouse wheel: a fixed 10 % per notch (ignores acceleration)
            let factor: CGFloat = precise ? exp(min(max(dy, -40), 40) * 0.005) : (dy > 0 ? 1.1 : (dy < 0 ? 1 / 1.1 : 1))
            let consumed: Bool = MainActor.assumeIsolated {
                let frame = frameBox.frame
                if model.finderAt != nil { return false }                          // let the list scroll
                if frame.width > 0 && (p.x < frame.minX || p.y < frame.minY) { return false }   // file browser / top bar
                let anchor = frame.width > 0 && frame.contains(p)
                    ? CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
                    : CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 2)
                if factor != 1 { model.zoom(by: factor, around: anchor) }
                return true
            }
            return consumed ? nil : event
        }
    }
    #endif

    // MARK: Background: pan, zoom, taps

    private var background: some View {
        GeometryReader { g in
            // zoomed far out: every 4th dot (then every 16th) so the grid stays visible but calm
            let step: CGFloat = {
                var st = 24 * model.viewScale
                while st < 8 { st *= 4 }
                return st
            }()
            let ox = model.viewOffset.width.truncatingRemainder(dividingBy: step)
            let oy = model.viewOffset.height.truncatingRemainder(dividingBy: step)
            // the dots are drawn once (for this zoom and window size) and only slid along while panning:
            // redrawing them every frame was most of the cost of panning an empty canvas
            GridDots(step: step, size: g.size, colourVersion: CustomColours.version, light: Theme.light)
                .equatable()
                .offset(x: (ox > 0 ? ox - step : ox), y: (oy > 0 ? oy - step : oy))
        }
        .clipped()
        .background(CanvasBackground().id(CustomColours.version))     // colour, and the picture if one is set
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: panThreshold)
                .onChanged { v in
                    if model.isZooming { panStart = nil; marquee = nil; return }
                    // select tool (or ⇧-drag on Mac): draw a selection box instead of panning
                    if marquee != nil || (panStart == nil && (model.selectMode || ModuleBox.shiftHeld)) {
                        marquee = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                         width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                        return
                    }
                    if panStart == nil { panStart = model.viewOffset }
                    guard let s = panStart else { return }
                    model.viewOffset = CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height)
                }
                .onEnded { _ in
                    if let m = marquee {
                        let a = model.toCanvas(CGPoint(x: m.minX, y: m.minY)), b = model.toCanvas(CGPoint(x: m.maxX, y: m.maxY))
                        model.select(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), adding: ModuleBox.shiftHeld)
                    }
                    marquee = nil
                    panStart = nil
                }
        )
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { v in
                    if let c = hitCable(v.location) {          // double-tap a cable: delete it
                        model.removeCable(c)
                        return
                    }
                    model.clearSelection()
                    model.finderAt = model.toCanvas(v.location)
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                    canvasFocused = true
                    model.isZooming = false          // belt and braces: a tap always clears it
                    if model.finderAt != nil { model.finderAt = nil; return }
                    if let c = hitCable(v.location) {
                        model.selectedNodes = []
                        model.selectedCable = c
                    } else {
                        model.clearSelection()
                        model.selectMode = false          // tapping away leaves the select tool
                        model.showColours = false         // … and closes the colours / help panels
                        model.helpMode = false
                    }
                })
        )
    }

    // MARK: Cables

    /// Left-to-right cable: leaves an outlet heading right, enters an inlet heading right.
    func cablePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        addCable(&p, a, b, scale: model.viewScale)
        return p
    }

    private func endpoints(_ c: PatchCable) -> (CGPoint, CGPoint)? {
        guard let ai = model.patch.index(of: c.fromNode), let bi = model.patch.index(of: c.toNode) else { return nil }
        let a = model.patch.nodes[ai], b = model.patch.nodes[bi]
        guard let sa = ModuleRegistry.spec(a.kind), let sb = ModuleRegistry.spec(b.kind),
              c.fromPort < BoxLayout.ports(a, sa, model.hw).outs.count,
              let dest = BoxLayout.destination(b, sb, model.hw, port: c.toPort) else { return nil }
        return (model.toScreen(BoxLayout.outlet(a, sa, model.hw, c.fromPort)), model.toScreen(dest))
    }

    @ViewBuilder private var cableDeleteButton: some View {
        if let id = model.selectedCable, let c = model.patch.cables.first(where: { $0.id == id }),
           let (a, b) = endpoints(c) {
            let path = cablePath(a, b)
            let mid = path.trimmedPath(from: 0, to: 0.5).currentPoint ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            Button { model.removeCable(id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: deleteButtonSize, height: deleteButtonSize)
                    .foregroundStyle(Theme.inverse)
                    .background(Circle().fill(Theme.selected))
            }
            .buttonStyle(.plain)
            .position(mid)
        }
    }

    private func hitCable(_ p: CGPoint) -> UUID? {
        if model.hideCables { return nil }
        var best: (UUID, CGFloat)?
        for c in model.patch.cables {
            guard let (a, b) = endpoints(c) else { continue }
            let path = cablePath(a, b)
            for k in 0...24 {
                guard let q = path.trimmedPath(from: 0, to: CGFloat(k) / 24).currentPoint else { continue }
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < cableHitRadius && d < (best?.1 ?? .infinity) { best = (c.id, d) }
            }
        }
        return best?.0
    }
}

/// Module picker that opens where you double-click: every module, grouped, one click to add.
struct ObjectFinder: View {
    @ObservedObject var model: AppModel
    let canvasPoint: CGPoint
    var maxHeight: CGFloat = .infinity
    @Binding var contentHeight: CGFloat

    static let size = CGSize(width: 584, height: 420)
    private static let columns: [[String]] = [["I/O", "Clock", "Utility", "Dynamics"],
                                              ["Sequencing", "Instruments"],
                                              ["Modulation", "Loop & Grain"],
                                              ["Effects"]]

    var body: some View {
        ScrollView(.vertical) {
            list
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.size.width, height: min(contentHeight, maxHeight))
        // shadow on the panel's shape only — on the whole view SwiftUI would shadow every line of text
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.box)
            .shadow(color: .black.opacity(Theme.light ? 0.18 : 0.6), radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = model.replaceTarget, let n = model.patch.nodes.first(where: { $0.id == t }) {
                Text("replace \(model.label(for: n)) with…")
                    .font(Theme.monoSmall).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.top, 8)
            }
            columns
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.columns.indices, id: \.self) { c in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.columns[c], id: \.self) { cat in
                        Text(cat.lowercased())
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 10)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(ModuleRegistry.all.filter { $0.category == cat }, id: \.kind) { s in
                            ModuleItem(spec: s) { create(s) }
                        }
                    }
                }
                .frame(width: (Self.size.width - CGFloat(Self.columns.count - 1)) / CGFloat(Self.columns.count), alignment: .leading)
                if c < Self.columns.count - 1 {
                    Rectangle().fill(Theme.border.opacity(0.5)).frame(width: 1)
                }
            }
        }
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.size.width)
    }

    private func create(_ s: ModuleSpec) {
        if let target = model.replaceTarget {
            model.replaceNode(target, with: s.kind)
        } else {
            model.addNode(kind: s.kind, at: canvasPoint)
        }
        model.finderAt = nil
    }
}

/// Right-click (long-press on iPad) a box's title bar: duplicate, replace, and the highlight colours.
/// Drawn like the module list.
struct BoxMenuView: View {
    @ObservedObject var model: AppModel
    let id: UUID
    static let width: CGFloat = 190

    var body: some View {
        let cur = model.patch.nodes.first { $0.id == id }?.highlight
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "duplicate") { model.duplicate(id); model.boxMenu = nil }
            MenuRow(title: "replace…") { model.boxMenu = nil; model.beginReplace(id) }
            Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1).padding(.vertical, 4)
            Text("highlight").font(Theme.monoSmall).foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).padding(.bottom, 4)
            HStack(spacing: 6) {
                swatch(nil, on: cur == nil)
                ForEach(AppModel.highlightColours, id: \.self) { hex in swatch(hex, on: cur == hex) }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .padding(.top, 6)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.box)
            .shadow(color: .black.opacity(Theme.light ? 0.18 : 0.6), radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
    }

    /// One colour circle (nil = no highlight: an empty circle with a slash). The current one has a ring.
    private func swatch(_ hex: String?, on: Bool) -> some View {
        Button { model.setHighlight(id, hex); model.boxMenu = nil } label: {
            ZStack {
                if let hex, let c = Color(hex: hex) {
                    Circle().fill(c)
                } else {
                    Circle().stroke(Theme.dim, lineWidth: 1)
                    Path { p in p.move(to: CGPoint(x: 4, y: 14)); p.addLine(to: CGPoint(x: 14, y: 4)) }
                        .stroke(Theme.dim, lineWidth: 1)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().stroke(on ? Theme.text : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono)
                .foregroundStyle(hover ? Theme.inverse : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(hover ? Theme.text : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ModuleItem: View {
    let spec: ModuleSpec
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(spec.name)
                .font(Theme.mono)
                .foregroundStyle(hover ? Theme.inverse : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(hover ? Theme.text : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(spec.summary)
    }
}

#if os(macOS)
/// Reference box so the (long-lived) scroll monitor always sees the canvas's current frame.
final class FrameBox { var frame: CGRect = .zero }
#endif


/// A group's lighter backdrop (like a Grasshopper group): drag it — its name or any empty part — to move
/// every box in it, tap it to select them all, double-tap the name to rename.
struct GroupBackdrop: View {
    @ObservedObject var model: AppModel
    let group: PatchGroup
    let rect: CGRect
    @State private var dragging = false
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var focused: Bool
    @Environment(\.hostedNodes) private var hosted

    var body: some View {
        let selected = group.members.allSatisfy { model.selectedNodes.contains($0) }
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.text.opacity(Theme.boxIsLight ? 0.07 : 0.09))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Theme.text.opacity(0.6) : Theme.text.opacity(0.18), lineWidth: 1))
            if renaming {
                TextField("", text: $name)
                    .textFieldStyle(.plain).font(Theme.title).foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { model.renameGroup(group.id, name); renaming = false }
                    .onAppear { focused = true }
                    .frame(width: 160)
                    .padding(.leading, 10).padding(.top, 7)
            } else {
                Text(group.name).font(Theme.title).foregroundStyle(Theme.dim)
                    .padding(.leading, 10).padding(.top, 7)
                    .onTapGesture(count: 2) { name = group.name; renaming = true }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .onTapGesture { model.selectGroup(group) }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: hosted ? .global : .named("canvas"))
                .onChanged { v in
                    if model.isZooming { return }
                    if !dragging {
                        dragging = true
                        model.selectGroup(group)
                        model.beginGroupDrag()
                    }
                    model.groupDrag(by: CGSize(width: v.translation.width / model.viewScale,
                                               height: v.translation.height / model.viewScale))
                }
                .onEnded { _ in
                    dragging = false
                    model.endGroupDrag()
                    model.scheduleAutosave()
                }
        )
        .onChange(of: focused) { _, f in if !f && renaming { model.renameGroup(group.id, name); renaming = false } }
        .helpTopic(model, "group-\(group.id)", group.name,
                   "A group. Drag its backdrop to move all its boxes, tap it to select them, double-tap the name to rename. Ungroup from the top bar.")
    }
}

/// All the boxes (and group backdrops), in canvas units. Equatable on the model alone, so when the canvas
/// re-renders for a pan or zoom this whole layer is skipped — it only updates when the patch does.
struct NodesLayer: View, Equatable {
    @ObservedObject var model: AppModel
    static func == (a: NodesLayer, b: NodesLayer) -> Bool { a.model === b.model }
    var body: some View {
        ZStack(alignment: .topLeading) {
            // group backdrops sit behind their boxes
            ForEach(model.groups) { g in
                if let r = model.groupRect(g) {
                    DragShift(drag: model.dragState, ids: Set(g.members)) {
                        GroupBackdrop(model: model, group: g, rect: r)
                    }
                    .offset(x: r.minX, y: r.minY)
                }
            }
            ForEach(model.patch.nodes) { n in
                if n.kind == "text" {
                    DragShift(drag: model.dragState, ids: [n.id]) { FreeText(model: model, node: n) }
                        .offset(x: n.x, y: n.y)
                } else if let spec = ModuleRegistry.spec(n.kind) {
                    DragShift(drag: model.dragState, ids: [n.id]) { ModuleBox(model: model, node: n, spec: spec) }
                        .offset(x: n.x, y: n.y)
                }
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }
}


/// The canvas's dot grid, one step bigger than the window each way so it can slide by up to a step.
private struct GridDots: View, Equatable {
    let step: CGFloat
    let size: CGSize
    let colourVersion: Int
    let light: Bool
    var body: some View {
        Canvas { ctx, sz in
            var dots = Path()      // all the dots as one shape, one fill
            var y: CGFloat = 0
            while y < sz.height {
                var x: CGFloat = 0
                while x < sz.width {
                    dots.addRect(CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(Theme.gridDot))
        }
        .frame(width: size.width + 2 * step, height: size.height + 2 * step)
        .allowsHitTesting(false)
    }
}

/// One cable's curve, from outlet a to inlet b, at a zoom.
func addCable(_ p: inout Path, _ a: CGPoint, _ b: CGPoint, scale: CGFloat) {
    p.move(to: a)
    let d = min(140 * scale, max(30 * scale, abs(b.x - a.x) * 0.45 + abs(b.y - a.y) * 0.15))
    p.addCurve(to: b, control1: CGPoint(x: a.x + d, y: a.y), control2: CGPoint(x: b.x - d, y: b.y))
}

/// The cable being dragged out of a port, in canvas-view coordinates.
private struct PendingCableView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Canvas { ctx, _ in
            guard let pc = model.pendingCable, let i = model.patch.index(of: pc.node),
                  let spec = ModuleRegistry.spec(model.patch.nodes[i].kind) else { return }
            let n = model.patch.nodes[i]
            guard let anchor = pc.fromOutput ? BoxLayout.outlet(n, spec, model.hw, pc.port)
                                             : BoxLayout.destination(n, spec, model.hw, port: pc.port) else { return }
            let start = model.toScreen(anchor)
            var p = Path()
            if pc.fromOutput { addCable(&p, start, pc.point, scale: model.viewScale) } else { addCable(&p, pc.point, start, scale: model.viewScale) }
            ctx.stroke(p, with: .color(Theme.text),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 4]))
        }
    }
}

/// Shifts its content while it's being dragged — the only thing that changes on each pointer move.
/// (The box itself isn't rebuilt: only this wrapper reads the drag.) A group backdrop follows when all its
/// boxes are dragged together.
struct DragShift<Content: View>: View {
    @ObservedObject var drag: DragState
    let ids: Set<UUID>
    @ViewBuilder let content: () -> Content
    var body: some View {
        let moving = !ids.isEmpty && ids.isSubset(of: drag.ids)
        content().offset(moving ? drag.delta : .zero)
    }
}
