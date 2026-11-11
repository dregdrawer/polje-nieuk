import SwiftUI
import PoljeNieukCore

struct ModuleBox: View {
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let node: PatchNode
    let spec: ModuleSpec
    @State private var dragStart: CGPoint?
    @State private var groupDrag = false
    static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
    @State private var dropTargeted = false

    private var hw: HardwareCounts { model.hw }
    private var selected: Bool { model.selectedNodes.contains(node.id) }
    private var isHardware: Bool { node.kind == "in" || node.kind == "out" }
    private var width: CGFloat { BoxLayout.width(node) }
    @Environment(\.hostedNodes) private var hosted
    /// Where drags are measured: the canvas — or, when the boxes sit in their own layer (see NodesHost), that layer.
    private var boxSpace: CoordinateSpace { hosted ? .global : .named("canvas") }
    /// A drag location in canvas-view coordinates, whichever space it was measured in.
    private func viewPoint(_ p: CGPoint) -> CGPoint { hosted ? model.fromGlobal(p) : p }

    /// Whether any of this box is on screen (with a margin): off-screen boxes don't redraw their displays.
    private func onScreen(_ h: CGFloat) -> Bool { Self.isOnScreen(model, node, width, h) }
    static func isOnScreen(_ model: AppModel, _ node: PatchNode, _ width: CGFloat, _ h: CGFloat) -> Bool {
        if model.threeD { return false }           // 3D: displays hold still (a box in perspective is costly to redraw)
        _ = model.viewportSettled                  // re-checked once panning / zooming pauses
        let v = model.viewSize
        guard v.width > 0 else { return true }
        let s = model.viewScale, o = model.viewOffset
        let r = CGRect(x: node.x * s + o.width, y: node.y * s + o.height, width: width * s, height: h * s)
        return r.intersects(CGRect(origin: .zero, size: v).insetBy(dx: -80, dy: -80))
    }

    var body: some View {
        let h = BoxLayout.height(node, spec, hw)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.box)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(selected ? Theme.selected : Theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                header
                if !node.collapsed {
                    VStack(alignment: .leading, spacing: 0) {
                        if BoxLayout.sideDisplay(spec.kind) {
                            // faders / knobs sit beside their outlets (no dead space under the port rows)
                            ZStack(alignment: .topLeading) {
                                portRows
                                    .contentShape(Rectangle())
                                    .onTapGesture { tapSelect() }
                                    .gesture(moveGesture)
                                    .background(DragZone(model: model, id: node.id, key: 1, inset: 16))
                                ReadoutView(kind: spec.kind, node: model.node(node.id), model: model, patchNode: node, spec: spec)
                                    .frame(width: max(width - 20 - BoxLayout.sideOutletColumn, 10), height: BoxLayout.readoutHeight(node))
                                    .padding(.leading, 10)
                            }
                            .frame(height: BoxLayout.bodyHeight(node, spec, hw), alignment: .top)
                        } else {
                            portRows
                                .contentShape(Rectangle())
                                .onTapGesture { tapSelect() }
                                .gesture(moveGesture)
                                .background(DragZone(model: model, id: node.id, key: 1, inset: 16))
                            if BoxLayout.hasReadout(spec.kind) {
                                ReadoutView(kind: spec.kind, node: model.node(node.id), model: model, patchNode: node, spec: spec)
                                    .frame(height: BoxLayout.readoutHeight(node))
                                    .padding(.horizontal, 10)
                            }
                        }
                        params
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                    }
                    .opacity(node.bypassed ? 0.35 : 1)
                } else {
                    collapsedRows
                        .contentShape(Rectangle())
                        .onTapGesture { tapSelect() }
                        .gesture(moveGesture)
                        .background(DragZone(model: model, id: node.id, key: 2, inset: 16))
                    if BoxLayout.hasReadout(spec.kind) {
                        ReadoutView(kind: spec.kind, node: model.node(node.id), model: model, patchNode: node, spec: spec)
                            .frame(height: BoxLayout.readoutHeight(node))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .opacity(node.bypassed ? 0.35 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
            ports
                .allowsHitTesting(!model.threeD)       // patching cables needs the flat view
        }
        .frame(width: width, height: h)
        .environment(\.liveDisplaysOn, onScreen(h))
        .environment(\.liveOpacity, node.bypassed ? 0.35 : 1)
        .helpTopic(model, "box-\(node.id)", PortHelp.module(spec).0, PortHelp.module(spec).1)
        .overlay(alignment: .bottomTrailing) {
            if !model.threeD && !node.collapsed && (BoxLayout.resizable(node.kind).width || BoxLayout.resizable(node.kind).height) {
                resizeGrip
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 3).stroke(Theme.text, lineWidth: 2)
                    .background(Theme.text.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.node(node.id) is SampleBufferNode, let u = urls.first else { return false }
            return model.loadAudio(u, into: node.id)
        } isTargeted: { t in
            dropTargeted = t && model.node(node.id) is SampleBufferNode
        }
    }

    // MARK: Header (drag to move, tap to select)

    private var header: some View {
        HStack(spacing: 6) {
            if spec.bypass != .none {
                Button { model.toggleBypass(node.id) } label: {
                    Circle()
                        .fill(node.bypassed ? Color.clear : Theme.text)
                        .overlay(Circle().stroke(node.bypassed ? Theme.dim : Theme.text, lineWidth: 1))
                        .frame(width: 9, height: 9)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.bypassed ? "Bypassed — click to switch on" : "On — click to bypass")
                .padding(.leading, -4)
            }
            HStack(spacing: 0) {
                Text(spec.name).font(Theme.title)
                    .foregroundStyle(node.bypassed ? Theme.dim : Theme.text)
                    .strikethrough(node.bypassed, color: Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .background(DragZone(model: model, id: node.id, key: 0))   // grab the title to move the box
            if AppModel.patternKinds.contains(node.kind) && !node.collapsed {
                ClearPatternButton { model.clearPattern(node.id) }
            }
            if model.canAutomate(spec) && !node.collapsed {
                AutoRecordButton(model: model, id: node.id)
                if model.hasAutomation(node) {                       // only when there's something to remove
                Button { model.clearAutomation(node.id) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 15, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset automation: remove this box's recorded movements")
                .helpTopic(model, "autoreset-\(node.id)", "Reset automation",
                           "Removes every recorded movement in this box. Parameters stay where they are.")
                }
            }
            if model.node(node.id) is SampleBufferNode {
                Menu {
                    Button("Load audio file…") { model.audioImportTarget = node.id }
                    let sources = model.patch.nodes.filter { $0.id != node.id && model.node($0.id) is SampleBufferNode }
                    if !sources.isEmpty {
                        Section("Copy audio from") {
                            ForEach(sources) { src in
                                Button(model.label(for: src)) { model.copyBuffer(from: src.id, to: node.id) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.dim).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Load or copy audio")
            }
            if selected {
                iconButton("xmark") { model.removeNode(node.id) }
            }
            iconButton(node.collapsed ? "chevron.down" : "chevron.up") { model.toggleCollapsed(node.id) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: BoxLayout.header)
        .overlay(alignment: .bottom) {
            if !node.collapsed { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.duplicate(node.id) }
        // long-press the title: replace this box with another module
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 4) { model.beginReplace(node.id) }
        .onTapGesture { tapSelect() }
        .gesture(moveGesture)
        .help(spec.summary)
    }

    private func tapSelect() {
        // select tool on, or ⇧ held (Mac): add / remove this box from the selection
        if model.selectMode || Self.shiftHeld { model.toggleSelected(node.id) } else { model.select(node.id) }
    }

    /// Drag the title bar — or the empty space between the inlets and outlets — to move the box.
    private var moveGesture: some Gesture {
            DragGesture(minimumDistance: 2, coordinateSpace: boxSpace)
                .onChanged { v in
                    if model.isZooming || model.nativeDrag { return }      // the canvas is moving it directly
                    // 3D: the finger's place on the tilted board decides where the box goes
                    if model.threeD { model.move3D(node.id, from: v.startLocation, to: v.location); return }
                    if dragStart == nil {
                        dragStart = CGPoint(x: node.x, y: node.y)
                        groupDrag = model.selectedNodes.contains(node.id) && model.selectedNodes.count > 1
                        if groupDrag { model.beginGroupDrag() } else { model.select(node.id) }
                    }
                    guard dragStart != nil else { return }
                    let d = CGSize(width: v.translation.width / model.viewScale, height: v.translation.height / model.viewScale)
                    if groupDrag {
                        model.groupDrag(by: d)                          // the whole selection moves together
                    } else {
                        model.dragMove([node.id], by: d)
                        model.updateInsertCandidate(for: node.id, at: viewPoint(v.location))
                    }
                }
                .onEnded { _ in
                    if model.threeD { model.end3DMove(); model.scheduleAutosave(); return }
                    guard dragStart != nil else { return }
                    dragStart = nil
                    if groupDrag { model.endGroupDrag() } else { model.endDragMove(); model.finishInsert(node.id) }
                    groupDrag = false
                    model.scheduleAutosave()
                }
    }

    // MARK: Resize grip (bottom-right corner): drag to resize, double-tap for the default size

    @State private var resizeStart: CGSize?

    private var resizeGrip: some View {
        Canvas { ctx, size in
            // one small dot in the corner: "this box can be resized"
            ctx.fill(Path(ellipseIn: CGRect(x: size.width - 7, y: size.height - 7, width: 3, height: 3)),
                     with: .color(Theme.dim))
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.resizeNode(node.id, width: nil, display: nil)
            model.scheduleAutosave()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: boxSpace)
                .onChanged { v in
                    if model.isZooming { return }
                    if resizeStart == nil {
                        resizeStart = CGSize(width: BoxLayout.width(node), height: BoxLayout.readoutHeight(node))
                    }
                    guard let s = resizeStart else { return }
                    let can = BoxLayout.resizable(node.kind)
                    let dx = v.translation.width / model.viewScale, dy = v.translation.height / model.viewScale
                    model.resizeNode(node.id,
                                     width: can.width ? s.width + dx : nil,
                                     display: can.height ? s.height + dy : nil)
                }
                .onEnded { _ in resizeStart = nil; model.scheduleAutosave() }
        )
        .help("Drag to resize · double-click for the default size")
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.dim).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Inlet / outlet label rows (with per-channel meters on in~/out~)

    @ViewBuilder private var portRows: some View {
        let p = BoxLayout.ports(node, spec, hw)
        let rows = BoxLayout.portRows(node, spec, hw)
        let outLabels = !BoxLayout.rowOutlets(node.kind)      // div~: outlets live on their parameter rows
        if rows > 0 {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        Text(r < p.ins.count ? p.ins[r] : "")
                            .frame(minWidth: 0, alignment: .leading)
                        if isHardware {
                            ChannelMeter(node: model.node(node.id), channel: r)
                        } else if node.kind == "mix" && r < p.ins.count {
                            // each mixer input's level (after its fader), right beside its inlet
                            ChannelMeter(node: model.node(node.id), channel: MixerLayout.channelMeterBase + r)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Text(outLabels && r < p.outs.count ? p.outs[r] : "")
                            .frame(minWidth: 0, alignment: .trailing)
                    }
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.dim)
                    .frame(height: BoxLayout.portRow)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }

    /// Collapsed: one small row per patched port so its cable stays attached to something labelled.
    @ViewBuilder private var collapsedRows: some View {
        let left = BoxLayout.collapsedLeft(node, spec), right = BoxLayout.collapsedRight(node, spec)
        let rows = max(left.count, right.count)
        if rows > 0 {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack {
                        Text(r < left.count ? BoxLayout.inletName(spec, left[r]) : "")
                        Spacer(minLength: 4)
                        Text(r < right.count ? spec.outputs[right[r]] : "")
                    }
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .frame(height: BoxLayout.portRow)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }

    // MARK: Parameters

    @ViewBuilder private var params: some View {
        let triggers = spec.params.indices.filter { spec.params[$0].isTrigger }
        VStack(spacing: 3) {
            if !triggers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(triggers, id: \.self) { i in
                        TriggerButton(title: spec.params[i].name, isRec: spec.params[i].key == "rec") {
                            model.fire(node.id, i)
                        }
                    }
                }
                .frame(height: BoxLayout.row - 3)
            }
            ForEach(BoxLayout.rowParams(spec, node), id: \.self) { i in
                let automated = model.isAutomated(node, i, spec)
                ParamRow(spec: spec.params[i], value: model.value(node, i, spec),
                         live: model.isModulated(node.id, i) || automated ? model.node(node.id) : nil, index: i,
                         automated: automated, width: width - 16) { v in
                    if !model.isZooming { model.setParam(node.id, i, v) }
                }
                .frame(height: BoxLayout.row - 3)
                .helpTopic(model, "param-\(node.id)-\(i)", PortHelp.param(spec, spec.params[i]).0, PortHelp.param(spec, spec.params[i]).1)
            }
        }
    }

    // MARK: Ports (circles; inlets left, outlets right, parameter inlets on each row)

    private var ports: some View {
        let h = BoxLayout.height(node, spec, hw)
        let p = BoxLayout.ports(node, spec, hw)
        let visibleIns = node.collapsed ? BoxLayout.collapsedLeft(node, spec).filter { $0 < kParamPortBase } : Array(p.ins.indices)
        let visibleOuts = node.collapsed ? BoxLayout.collapsedRight(node, spec) : Array(p.outs.indices)
        let collapsedParams = node.collapsed ? BoxLayout.collapsedLeft(node, spec).filter { $0 >= kParamPortBase } : []
        return ZStack(alignment: .topLeading) {
            ForEach(visibleIns, id: \.self) { i in
                portCircle(isOutput: false, port: i, size: BoxLayout.port)
                    .position(x: 0, y: BoxLayout.inlet(node, spec, hw, i).y - node.y)
            }
            ForEach(visibleOuts, id: \.self) { i in
                portCircle(isOutput: true, port: i, size: BoxLayout.port)
                    .position(x: width, y: BoxLayout.outlet(node, spec, hw, i).y - node.y)
            }
            ForEach(collapsedParams, id: \.self) { port in
                if let y = BoxLayout.paramRowY(node, spec, hw, port - kParamPortBase) {
                    portCircle(isOutput: false, port: port, size: BoxLayout.paramPort).position(x: 0, y: y)
                }
            }
            if !node.collapsed {
                ForEach(BoxLayout.rowParams(spec, node), id: \.self) { i in
                    if let y = BoxLayout.paramRowY(node, spec, hw, i) {
                        portCircle(isOutput: false, port: kParamPortBase + i, size: BoxLayout.paramPort)
                            .position(x: 0, y: y)
                    }
                }
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
        .overlay(alignment: .topLeading) { activityDots(visibleOuts) }
    }

    /// A small dot left of each outlet's label that lights with the signal leaving it
    /// (clock ticks, gates, LFO swings, audio). Only while audio runs.
    @ViewBuilder private func activityDots(_ outs: [Int]) -> some View {
        if model.isRunning, !outs.isEmpty, node.kind != "in", let dsp = model.node(node.id) {   // in~ has meters
            let ys = outs.map { BoxLayout.outlet(node, spec, hw, $0).y - node.y }
            let names = outs.map { $0 < spec.outputs.count ? spec.outputs[$0] : "" }
            // gates and triggers blink on / off; smooth signals (LFOs, envelopes, audio) fade with their level
            let gate = names.map { node.kind == "div" || ["gate", "pulse", "trig", "t1", "t2", "t3"].contains($0) }
            let w = width
            LiveCanvas(signature: {
                // only when a dot turns on or off (checked 10 times a second)
                var h = 0
                for (j, k) in outs.enumerated() where k < spec.outputs.count {
                    LiveSig.mix(&h, gate[j] ? (dsp.outLevel[k] * 4 > 0.1 ? 1 : 0) : LiveSig.q(min(max(dsp.outLevel[k] * 4, 0), 1), 4))
                }
                return h
            }, every: 2) { ctx, _ in
                for (j, k) in outs.enumerated() where k < spec.outputs.count {
                    let lv = dsp.outLevel[k]
                    // same steps as the redraw check: on / off for gates, 5 brightness steps otherwise
                    let a: CGFloat = !lv.isFinite ? 0 : gate[j] ? (lv * 4 > 0.1 ? 1 : 0) : CGFloat((min(max(lv * 4, 0), 1) * 4).rounded() / 4)
                    let lit = a > 0.02
                    // beside the outlet's label — or, on div~, just after the row's name ("out 1"), clear of
                    // the value (values like ÷25 are wide enough to run under a dot near the right edge)
                    let x = BoxLayout.rowOutlets(node.kind) && !node.collapsed ? 8 + 8 + 5 * 5.45 + 14 : w - 10 - CGFloat(names[j].count) * 5.45 - 8
                    let r = CGRect(x: x - 3, y: ys[j] - 3, width: 6, height: 6)
                    if lit {
                        ctx.fill(Path(ellipseIn: r), with: .color(Theme.text.opacity(0.35 + 0.65 * a)))     // lit: a plain dot
                    } else {
                        // idle: a hollow ring
                        ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.dim.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
            .frame(width: w, height: BoxLayout.height(node, spec, hw))
            .allowsHitTesting(false)
        }
    }

    private func portCircle(isOutput: Bool, port: Int, size: CGFloat) -> some View {
        let connected = model.isPortConnected(node.id, port: port, output: isOutput)
        return Circle()
            .fill(isOutput || connected ? Theme.text : Theme.box)
            .overlay(Circle().stroke(port >= kParamPortBase && !connected ? Theme.faint : Theme.text, lineWidth: 1))
            .frame(width: size, height: size)
            .frame(width: 22, height: 18)
            .helpTopic(model, "port-\(node.id)-\(isOutput)-\(port)",
                       PortHelp.describe(spec, port: port, output: isOutput).0, PortHelp.describe(spec, port: port, output: isOutput).1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: boxSpace)
                    .onChanged { v in
                        if model.pendingCable == nil && !isOutput && connected {
                            // dragging a plugged inlet picks its cable up so you can move it elsewhere
                            if model.pickUpCable(into: node.id, port: port, at: viewPoint(v.location)) { return }
                        }
                        if model.pendingCable == nil || model.pendingCable?.node == node.id {
                            model.pendingCable = PendingCable(node: model.pendingCable?.node ?? node.id,
                                                              port: model.pendingCable?.port ?? port,
                                                              fromOutput: model.pendingCable?.fromOutput ?? isOutput,
                                                              point: viewPoint(v.location))
                        } else {
                            model.pendingCable?.point = viewPoint(v.location)
                        }
                    }
                    .onEnded { v in model.finishCable(at: viewPoint(v.location)) }
            )
    }
}

struct TriggerButton: View {
    let title: String
    let isRec: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.monoSmall.weight(.bold))
                .foregroundStyle(isRec ? Theme.rec : Theme.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 2).fill(Theme.row))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Number-box row: drag horizontally to change, double-tap to reset, ▾ rows open a menu.
/// When a cable drives the parameter, a white tick shows the live value.
struct ParamRow: View {
    let spec: ParamSpec
    let value: Float
    let live: DSPNode?
    let index: Int
    var automated = false
    /// The row's width, known from the box (no GeometryReader: hundreds of those re-ran on every pan frame).
    var width: CGFloat = 170
    let onChange: (Float) -> Void
    @State private var dragStart: Float?
    @State private var showOptions = false
    private var rowH: CGFloat { BoxLayout.row - 3 }

    var body: some View {
        switch spec.kind {
        case .toggle:
            Button { onChange(value > 0.5 ? 0 : 1) } label: {
                rowContent(fill: value > 0.5 ? 1 : 0, valueText: value > 0.5 ? "on" : "off",
                           recOn: value > 0.5 && spec.key == "rec")
            }
            .buttonStyle(.plain)
        case .choice(let options):
            // click anywhere on the row for the whole list; slide across it to step through the options
                rowContent(fill: CGFloat(spec.normalized(value)), valueText: spec.display(value), recOn: false, trailingSpace: 16)
                    .overlay(alignment: .trailing) {
                        Text("▾").font(Theme.mono).foregroundStyle(Theme.dim).frame(width: 18, height: rowH)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStart == nil { dragStart = spec.normalized(value) }
                                let n = (dragStart ?? 0) + Float(v.translation.width / max(width, 1))
                                onChange(spec.value(fromNormalized: n))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    // a plain click (no slide) opens the list — straight away, no double-click wait
                    .onTapGesture { showOptions = true }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(options.indices, id: \.self) { i in
                                    let on = Int(value.rounded()) == i
                                    Button { onChange(Float(i)); showOptions = false } label: {
                                        HStack(spacing: 6) {
                                            Text(on ? "✓" : " ").frame(width: 12)
                                            Text(options[i])
                                            Spacer(minLength: 0)
                                        }
                                        .font(Theme.mono)
                                        .foregroundStyle(on ? Theme.text : Theme.dim)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minWidth: 180, maxHeight: 420)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(Theme.box)
                    }
        default:
                rowContent(fill: CGFloat(spec.normalized(value)), valueText: spec.display(value), recOn: false)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStart == nil { dragStart = spec.normalized(value) }
                                let n = (dragStart ?? 0) + Float(v.translation.width / max(width, 1))
                                onChange(spec.value(fromNormalized: n))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .onTapGesture(count: 2) { onChange(spec.def) }
        }
    }

    @ViewBuilder
    private func rowContent(fill: CGFloat, valueText: String, recOn: Bool, trailingSpace: CGFloat = 0) -> some View {
        if let live {
            // a live row (modulated or automated): drawn natively in one go — a tick redraws only this row
            let name = spec.name, automated = automated, idx = index, sp = spec
            LiveCanvas(signature: {
                var h = LiveSig.q(sp.normalized(live.params[idx]), 240)
                LiveSig.mix(&h, sp.display(live.params[idx]).hashValue)
                return h
            }, every: 2) { ctx, size in
                let v = live.params[idx]
                let n = CGFloat(sp.normalized(v))
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
                if automated {
                    // the bar follows what the automation is playing
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * n, height: size.height)), with: .color(Theme.fill))
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(Theme.rec))
                } else {
                    // the knob's own position, and a tick where the modulation has taken it
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * fill, height: size.height)),
                             with: .color(recOn ? Theme.rec.opacity(0.5) : Theme.fill))
                    ctx.fill(Path(CGRect(x: max(0, size.width * n - 1), y: 0, width: 2, height: size.height)), with: .color(Theme.text))
                }
                ctx.draw(LiveText(name, size: 11, color: Theme.dim), at: CGPoint(x: 6, y: size.height / 2), anchor: .leading)
                ctx.draw(LiveText(sp.display(v), size: 11, color: Theme.text),
                         at: CGPoint(x: size.width - 6 - trailingSpace, y: size.height / 2), anchor: .trailing)
            }
        } else {
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.row)
                Rectangle().fill(recOn ? Theme.rec.opacity(0.5) : Theme.fill)
                    .frame(width: width * fill)
                HStack {
                    Text(spec.name).foregroundStyle(Theme.dim)
                    Spacer(minLength: 4)
                    Text(valueText).foregroundStyle(recOn ? Theme.rec : Theme.text)
                }
                .font(Theme.mono)
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.trailing, 6 + trailingSpace)
            }
        }
    }
}

/// Automation record: hold it and move things in the box (a quick tap latches it on; tap again to stop).
struct AutoRecordButton: View {
    let model: AppModel   // not observed: the box re-renders when its BoxKey changes (see NodesHost)
    let id: UUID
    @State private var pressStart: Date?
    @State private var stopOnRelease = false

    var body: some View {
        let on = model.autoRecording.contains(id)
        ZStack {
            Circle().fill(on ? Theme.rec : Color.clear)
            Circle().stroke(on ? Theme.rec : Theme.dim, lineWidth: 1)
            Circle().fill(on ? Color.white.opacity(0.9) : Theme.dim).frame(width: 3, height: 3)
        }
        .frame(width: 9, height: 9)
        .frame(width: 15, height: 18)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    stopOnRelease = model.autoRecording.contains(id)
                    if !stopOnRelease { model.startAutoRecord(id) }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStart ?? Date())
                    pressStart = nil
                    // a long hold is momentary; a quick tap latches (and the next tap stops)
                    if stopOnRelease || held > 0.35 { model.stopAutoRecord(id) }
                }
        )
        .help("Automation: hold and move this box's controls to record them (4-bar loop). Tap to latch.")
        .helpTopic(model, "autorec-\(id)", "Record automation",
                   "Hold and move this box's controls: the movements are recorded into a 4-bar loop and play back. A quick tap latches recording on; tap again to stop.")
    }
}
