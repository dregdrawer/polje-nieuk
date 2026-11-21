import SwiftUI
import UniformTypeIdentifiers
import PoljeNieukCore

public struct PoljeNieukRootView: View {
    @StateObject private var model = AppModel()
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmNew = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // its own view, redrawn only when something it shows changes: as part of this one it was rebuilt
            // (all four layouts, every module in the add menu) and the whole window re-measured on every
            // change to the patch — ~30 ms per step of a slider on a big patch
            TopBar(model: model, state: BarState(model), exporting: $exporting, importing: $importing,
                   confirmNew: $confirmNew)
                .equatable()
            if let err = model.audioError {
                Text(err)
                    .font(Theme.mono)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.rec.opacity(0.75))
            }
            HStack(spacing: 0) {
                if model.showFiles {
                    FileBrowserView(model: model)
                    Rectangle().fill(Theme.border).frame(width: 1)
                }
                PatchCanvasView(model: model)
                    .id(model.colourVersion)             // custom colours: redraw the canvas, keep the top bar (and the palette) open
                    .overlay(alignment: .bottomLeading) {
                        if model.helpMode { HelpPanel(model: model) }
                    }

            }
        }
        .id(model.lightScheme)                       // rebuild the content with the new colours (audio keeps running)
        // the colours panel lives outside the canvas, so redrawing the canvas for a new colour never
        // disturbs the colour picker you're using
        .overlay(alignment: .topTrailing) {
            if model.showColours { ColourMenu(model: model).padding(.top, 34) }
        }
        .background(Theme.bg)
        .preferredColorScheme(model.lightScheme ? .light : .dark)
        .environment(\.helpModeOn, model.helpMode)
        .tint(Theme.selected)
        .onAppear { model.startAudio() }
        .fileExporter(isPresented: $exporting, document: exporting ? PatchFile(patch: model.patch) : nil,   // only when saving: a new copy on every change re-measured the window
                      contentType: .json, defaultFilename: "My Patch") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Patch.self, from: data) {
                model.load(p.migrated())
            } else {
                model.audioError = "Couldn't read that patch file."
            }
        }
        .background(
            Color.clear.fileImporter(isPresented: Binding(get: { model.audioImportTarget != nil },
                                                          set: { if !$0 { model.audioImportTarget = nil } }),
                                     allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { model.loadAudio(from: url) } else { model.audioImportTarget = nil }
            }
        )
        .confirmationDialog("Clear the canvas?", isPresented: $confirmNew) {
            Button(model.hasUserDefault ? "New patch (your default)" : "New patch", role: .destructive) { model.newPatch() }
            Button("Empty canvas", role: .destructive) { model.load(Patch()) }
            if model.hasUserDefault {
                Button("Built-in starter", role: .destructive) { model.load(DefaultPatch.builtIn()) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

}


/// The tempo in the top bar. Following the modular it just shows the measured tempo ("EXT");
/// on the internal clock, drag up / down on it to change it (1 BPM per step) or double-click to type one.
struct TempoField: View {
    @ObservedObject var model: AppModel
    @State private var dragStart: Double?
    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let editable = model.tempoEditable
        Group {
            if typing {
                HStack(spacing: 3) {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .frame(width: 40)
                        .focused($focused)
                        .onSubmit(commit)
                        .onAppear { focused = true }
                    Text("bpm")
                }
            } else {
                Text(String(format: "%@ %5.1f bpm", model.externalClock ? "EXT" : "INT",
                            min(max(fin(Float(editable ? model.setTempo : model.bpm)), 0), 999)))
                    .foregroundStyle(editable ? Theme.text : (model.externalClock ? Theme.text : Theme.dim))
                    .underline(editable, color: Theme.faint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard editable else { return }
            text = String(format: "%.0f", model.setTempo)
            typing = true
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard editable, !typing else { return }
                if dragStart == nil { dragStart = model.setTempo }
                // up or right = faster; 1 BPM per 3 points
                let d = (v.translation.width - v.translation.height) / 3
                model.setTempo(((dragStart ?? 120) + Double(d)).rounded())
            }
            .onEnded { _ in dragStart = nil })
        .onChange(of: focused) { _, f in if !f && typing { commit() } }
        .help(editable ? "Tempo: drag up / down to change, double-click to type" : "Tempo from the modular's clock")
        .helpTopic(model, "tb-tempo", "tempo",
                   editable ? "The internal clock's tempo. Drag up or down on it to change it, or double-click and type a value (20–300 BPM)."
                            : "The tempo measured from the modular's clock (clock on external). Switch clock to internal to set it here.")
    }

    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { model.setTempo(v) }
        typing = false
    }
}

/// What the top bar shows. The bar redraws only when this changes (not on every change to the patch).
struct BarState: Equatable {
    var running, lightScheme, helpMode, selectMode, showFiles, hideCables, threeD, hasUserDefault: Bool
    var canUndo, canRedo, allCollapsed, groupsSelected, cableSelected: Bool
    var selected: Int
    var inputUID, outputUID: String?
    var inputName, outputName, audioStatus: String
    var hwIn, hwOut: Int
    var inputs, outputs: [DeviceChoice]
    var sections: [String]
    var lifted: [Bool]
    @MainActor init(_ m: AppModel) {
        running = m.isRunning; lightScheme = m.lightScheme; helpMode = m.helpMode; selectMode = m.selectMode
        showFiles = m.showFiles; hideCables = m.hideCables; threeD = m.threeD; hasUserDefault = m.hasUserDefault
        canUndo = m.canUndo; canRedo = m.canRedo; allCollapsed = m.allCollapsed
        groupsSelected = !m.selectedGroups.isEmpty; cableSelected = m.selectedCable != nil
        selected = m.selectedNodes.count
        inputUID = m.inputUID; outputUID = m.outputUID
        inputName = m.inputName; outputName = m.outputName; audioStatus = m.audioStatus
        hwIn = m.hw.inputs; hwOut = m.hw.outputs
        inputs = m.inputChoices; outputs = m.outputChoices
        // one pass over the boxes: which sections are in the patch, and whether all of a section is lifted
        var up: [String: Bool] = [:]
        for n in m.patch.nodes {
            guard let c = ModuleRegistry.spec(n.kind)?.category else { continue }
            up[c] = (up[c] ?? true) && (n.z ?? 0) > 0.5
        }
        sections = ModuleRegistry.categories.filter { up[$0] != nil }
        lifted = sections.map { up[$0] ?? false }
    }
}

/// The bar along the top: audio, devices, tempo, cpu, edit buttons, menus.
struct TopBar: View, Equatable {
    let model: AppModel        // not observed: it redraws when `state` changes
    let state: BarState
    @Binding var exporting: Bool
    @Binding var importing: Bool
    @Binding var confirmNew: Bool

    nonisolated static func == (a: TopBar, b: TopBar) -> Bool { a.state == b.state }

    var body: some View { topBar }

    private func deviceMenu(label: String, current: String, choices: [DeviceChoice], selected: String,
                            pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(choices) { c in
                Button { pick(c.id) } label: { Text((c.id == selected ? "✓ " : "   ") + c.name) }
            }
            Divider()
            Button("Refresh devices") { model.refreshDevices() }
        } label: {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.dim)
                Text(current).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .font(Theme.barFont)
            .frame(minHeight: 26).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpTopic(model, "tb-\(label)", label == "IN" ? "audio input" : "audio output",
                   label == "IN" ? "Chooses the audio interface you record from — e.g. the disting NT. Its channels become in's outlets."
                                 : "Chooses where sound goes. Its channels become out's inlets. Changing it never changes the input.")
    }

    /// The full bar when the window is wide enough; then one without the status / cpu text; then a compact
    /// one (no device names either); and as a last resort the compact one scrolls sideways.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false)
            barContent(compact: false, stats: false)        // device names stay; status and cpu text go first
            barContent(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { barContent(compact: true) }
        }
        .buttonStyle(.borderless)
        .font(Theme.barFont)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// A top-bar button label: one word. Toggles show bright when on, dim when off; plain actions are mid-tone.
    private func word(_ w: String, on: Bool) -> some View {
        Text(w).font(Theme.barFont).foregroundStyle(on ? Theme.text : Theme.dim).fixedSize()
            .padding(.horizontal, 3).frame(minHeight: 26).contentShape(Rectangle())
    }

    /// A top-bar icon with a finger-sized tap area (easy on the iPad).
    private func icon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .regular))
            .foregroundStyle(on ? Theme.text : Theme.dim)
            .frame(width: 30, height: 26).contentShape(Rectangle())
    }

    private func drawnIcon<S: Shape>(_ shape: S, on: Bool, size: CGFloat = 15) -> some View {
        shape.stroke(on ? Theme.text : Theme.dim, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .frame(width: 30, height: 26).contentShape(Rectangle())
    }

    private func short(_ s: String) -> String { s.count > 10 ? String(s.prefix(9)) + "…" : s }

    private func barContent(compact: Bool, stats: Bool = true) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            Text("polje nieuk").font(Theme.barFontBold).foregroundStyle(Theme.text)
                .padding(.trailing, 4)

            Button {
                model.isRunning ? model.stopAudio() : model.restartAudio()
            } label: {
                word("audio", on: model.isRunning)
            }
            .buttonStyle(.plain)
            .help(model.isRunning ? "Stop audio" : "Start audio")
            .helpTopic(model, "tb-power", "audio on / off", "Starts or stops the audio engine.")

            deviceMenu(label: "IN", current: model.inputUID == "none" ? "off" : (model.isRunning ? (compact ? "" : "\(model.inputName) · \(model.hw.inputs)ch") : "—"),
                       choices: model.inputChoices, selected: model.inputUID ?? "") { model.selectInput($0) }
            #if os(macOS)
            deviceMenu(label: "OUT", current: model.outputUID == "off" ? "off" : (model.isRunning ? (compact ? "" : "\(model.outputName) · \(model.hw.outputs)ch") : "—"),
                       choices: model.outputChoices, selected: model.outputUID ?? "") { model.selectOutput($0) }
            #else
            deviceMenu(label: "OUT", current: model.outputUID == "off" ? "off" : (model.isRunning ? (compact ? "" : "\(model.outputName) · \(model.hw.outputs)ch") : "—"),
                       choices: model.outputChoices, selected: model.outputUID ?? "") { model.selectOutput($0) }
            RoutePickerButton()
                .frame(width: 22, height: 22)
                .help("AirPlay / Bluetooth output")
            #endif

            if !compact && stats {
                Text(model.audioStatus).font(Theme.barFont).foregroundStyle(Theme.dim).lineLimit(1)
            }

            Spacer(minLength: 8)

            // only re-rendered when what it shows changes (tempo, clock source, cpu) — it sits in all four
            // bar layouts the window picks between, so re-rendering it every tick was costly
            HStack(spacing: 10) {
                // the tempo re-renders only when the tempo or clock source changes
                LiveView(signature: {
                    var h = LiveSig.q(Float(model.tempoEditable ? model.setTempo : model.bpm), 10)
                    LiveSig.mix(&h, model.externalClock ? 1 : 0)
                    return h
                }) {
                    TempoField(model: model)            // kept in the compact bar too, so it's always settable
                }
                // the cpu figure is drawn natively: as a SwiftUI text, its update every second re-laid-out the
                // whole window (20–100 ms) — a box being dragged then jumped
                if !compact && stats {
                    BarLiveText(width: 54, signature: { Int(fin(model.appCPU) * 100) }) {
                        (String(format: "cpu %3.0f%%", min(fin(model.appCPU) * 100, 999)), model.appCPU > 0.85 ? Theme.rec : Theme.dim)
                    }
                    .help("cpu: everything the app uses — sound and drawing the screen. 100 % is one full core.")
                    .helpTopic(model, "tb-cpu", "cpu", "How much the app uses — sound and drawing the screen together. 100 % is one full core. If the iPad gets warm, this is the number to watch.")
                }
            }
            .font(Theme.barFont)
            .lineLimit(1)
            .fixedSize()

            Button { model.undo() } label: { icon("arrow.uturn.backward", on: state.canUndo).accessibilityLabel("undo") }
                .disabled(!state.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
                .helpTopic(model, "tb-undo", "undo", "Steps back through your edits — moves, cables, knob turns, added or deleted boxes. ⌘Z on the Mac.")
            Button { model.redo() } label: { icon("arrow.uturn.forward", on: state.canRedo).accessibilityLabel("redo") }
                .disabled(!state.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
                .helpTopic(model, "tb-redo", "redo", "Steps forward again after an undo. ⇧⌘Z on the Mac.")

            Button { model.lightScheme.toggle() } label: {
                icon(model.lightScheme ? "moon" : "sun.max", on: false).accessibilityLabel(model.lightScheme ? "dark scheme" : "light scheme")     // what you'd switch to
            }
            .help(model.lightScheme ? "Dark scheme" : "Light scheme")
            .helpTopic(model, "tb-scheme", "light / dark", "Switches the whole app between the dark and light colour schemes.")

            Button { model.helpMode.toggle() } label: {
                icon(model.helpMode ? "questionmark.circle.fill" : "questionmark.circle", on: model.helpMode).accessibilityLabel("help")
            }
            .help("Help: point at anything to see what it does")
            .helpTopic(model, "tb-help", "help", "Switches help on: point at anything to see what it does. Tap it again to switch help off.")

            Menu {
                ForEach(ModuleRegistry.categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(ModuleRegistry.all.filter { $0.category == cat }, id: \.kind) { s in
                            Button("\(s.name)  —  \(s.summary)") { model.addNode(kind: s.kind, at: model.viewCenterInCanvas) }
                        }
                    }
                }
            } label: {
                icon("plus", on: false).accessibilityLabel("add a module")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .help("Add a module")

            Button { model.selectMode.toggle() } label: {
                icon(model.selectMode ? "rectangle.dashed.badge.record" : "rectangle.dashed", on: model.selectMode)
                    .accessibilityLabel("select")
            }
            .help("Select tool: drag empty space to box-select, tap titles to add / remove (⇧ does the same on Mac)")
            .helpTopic(model, "tb-select", "select tool", "When on, dragging empty space draws a selection box and tapping a box's title adds or removes it. On the Mac you can also hold ⇧. Then duplicate, switch off or delete the whole selection with the buttons next to it, or drag any selected box to move them all.")
            if model.selectedNodes.count > 0 {
                Button { model.duplicateSelection() } label: { word("duplicate", on: false) }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Duplicate selection (⌘D)")
                    .helpTopic(model, "tb-dup", "duplicate", "Copies the selected boxes and the cables between them. ⌘D on the Mac.")
                if model.selectedNodes.count >= 2 {
                    Button { model.groupSelection() } label: { word("group", on: false) }
                        .help("Group the selection: one backdrop, moves together")
                        .helpTopic(model, "tb-group", "group", "Puts the selected boxes on a shared backdrop. Drag the backdrop to move them all together.")
                }
                if !model.selectedGroups.isEmpty {
                    Button { model.ungroupSelection() } label: { word("ungroup", on: false) }
                        .help("Remove the group (the boxes stay where they are)")
                }
                Button { model.bypassSelection() } label: { word("bypass", on: false) }
                    .help("Switch the selection off / on")
                    .helpTopic(model, "tb-bypass", "switch off / on", "Bypasses every selected box — or switches them all back on if they're all off.")
                Text("\(model.selectedNodes.count)").font(Theme.barFont).foregroundStyle(Theme.dim)
            }

            Button { model.removeSelection() } label: { icon("trash", on: !(model.selectedNodes.isEmpty && model.selectedCable == nil)).accessibilityLabel("delete") }
                .disabled(model.selectedNodes.isEmpty && model.selectedCable == nil)
                .help("Delete selection")
                .helpTopic(model, "tb-delete", "delete", "Deletes the selected boxes or cable.")

            Button { model.showFiles.toggle() } label: { word("browser", on: model.showFiles) }
                .buttonStyle(.plain)
                .help("Show / hide the browser")
                .helpTopic(model, "tb-files", "browser", "Shows your audio files. Drag one onto a looper, sampler or stretch to load it.")

            Menu {
                // real toggles: the system draws the tick in its own column, so every label lines up
                Toggle("Hide cables", isOn: Binding(get: { model.hideCables }, set: { model.hideCables = $0 }))
                Button("Colours…") { model.showColours.toggle() }
                Divider()
                Button("Tidy") { model.tidy() }
                Button(state.allCollapsed ? "Unfold all" : "Fold all") { model.toggleCollapseAll() }
                Divider()
                Toggle("3D", isOn: Binding(get: { model.threeD }, set: { model.threeD = $0 }))
                Menu("Lift in 3D") {
                    ForEach(state.sections, id: \.self) { cat in
                        Toggle(cat, isOn: Binding(get: { model.sectionLifted(cat) }, set: { _ in model.toggleLift(cat) }))
                    }
                    Divider()
                    Button("Layers by section") { model.layerBySection() }
                    Button("Put everything down") { model.putEverythingDown() }
                }
                Divider()
                Button("Reset view") { model.viewScale = 1; model.viewOffset = CGSize(width: 30, height: 30) }
            } label: {
                word("view", on: false)
            }
            .fixedSize()
            .helpTopic(model, "tb-view", "view", "How the patch is shown: hide the cables, colours, tidy, fold all boxes, 3D (and lifting sections in 3D), reset the zoom.")

            Menu {
                Button("New…") { confirmNew = true }
                Button("Open…") { importing = true }
                Button("Save As…") { exporting = true }
                Divider()
                Button("Set as default") { model.setAsDefault() }
                Button("Reset default") { model.resetDefault() }
                    .disabled(!model.hasUserDefault)
            } label: {
                word("file", on: false)
            }
            .fixedSize()
        }
    }
}
