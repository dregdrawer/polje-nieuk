import SwiftUI
import PoljeNieukCore

/// Black & white (or white & black in the light scheme). Colour only for meters and recording.
enum Theme {
    /// Light scheme on/off (persisted by AppModel). Every colour below follows it.
    nonisolated(unsafe) static var light = UserDefaults.standard.bool(forKey: "lightScheme")

    static var bg: Color { CustomColours.colour(.background) ?? defaultBg }
    static var defaultBg: Color { light ? Color(white: 0.94) : .black }
    static var gridDot: Color { CustomColours.gridDot() ?? (light ? Color.black.opacity(0.10) : Color.white.opacity(0.07)) }
    /// a custom window colour brings its own tones for everything drawn in and around the boxes
    private static var win: CustomColours.WindowPalette? { CustomColours.windowPalette() }
    /// whether boxes are light (scheme, or a light custom window colour) — for outlines that need contrast
    static var boxIsLight: Bool { win?.isLight ?? light }
    static var box: Color { win?.box ?? defaultBox }
    static var defaultBox: Color { light ? Color(white: 0.995) : Color(white: 0.055) }
    static var border: Color { win?.border ?? (light ? Color(white: 0.72) : Color(white: 0.24)) }
    static var selected: Color { win?.text ?? (light ? .black : .white) }
    static var text: Color { win?.text ?? (light ? Color(white: 0.08) : Color(white: 0.92)) }
    static var dim: Color { win?.dim ?? (light ? Color(white: 0.45) : Color(white: 0.5)) }
    static var faint: Color { win?.faint ?? (light ? Color(white: 0.72) : Color(white: 0.3)) }
    static var row: Color { win?.row ?? (light ? Color(white: 0.91) : Color(white: 0.1)) }
    static var fill: Color { win?.fill ?? (light ? Color(white: 0.78) : Color(white: 0.24)) }
    static var cable: Color { CustomColours.colour(.cables) ?? defaultCable }
    static var defaultCable: Color { CustomColours.defaultCable() ?? (light ? Color(white: 0.4) : Color(white: 0.55)) }
    static var bar: Color { win?.box ?? (light ? Color(white: 0.97) : .black) }
    /// text drawn on top of a `text`-coloured highlight
    static var inverse: Color { win?.box ?? (light ? .white : .black) }
    /// alternating-lane shading in the piano / drum roll
    static var shade: Color { boxIsLight ? Color.black.opacity(0.06) : Color.black.opacity(0.35) }
    // piano keys keep looking like a piano in both schemes
    static var keyWhite: Color { boxIsLight ? .white : Color(white: 0.92).opacity(0.85) }
    static var keyBlack: Color { boxIsLight ? Color(white: 0.15) : .black }
    static var keyWhiteLit: Color { boxIsLight ? Color(white: 0.62) : Color(white: 0.5) }
    static var keyBlackLit: Color { boxIsLight ? Color(white: 0.5) : Color(white: 0.92).opacity(0.75) }

    // the only colours
    static let rec = Color(red: 1.0, green: 0.23, blue: 0.2)
    static let meterGreen = Color(red: 0.25, green: 0.85, blue: 0.35)
    static let meterYellow = Color(red: 1.0, green: 0.82, blue: 0.2)
    static let meterRed = Color(red: 1.0, green: 0.23, blue: 0.2)

    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoSmall = Font.system(size: 9, design: .monospaced)
    static let title = Font.system(size: 11, weight: .semibold, design: .monospaced)
    /// The top bar: one size for every word and number in it, so they all sit on one line.
    static let barFont = Font.system(size: 10, design: .monospaced)
    static let barFontBold = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

/// Hardware channel counts the in/out boxes show ports for.
struct HardwareCounts: Equatable {
    var inputs: Int
    var outputs: Int
}

/// Box geometry, computed (not measured) so cables, ports and hit-testing always agree.
/// Signal flows left → right: inlets and parameter inlets on the left edge, outlets on the right.
/// Which ports of each box have cables (kept up to date by AppModel) — collapsed boxes show only these.
struct PortUsage {
    var ins = Set<Int>()     // audio inlets and parameter ports (≥ kParamPortBase)
    var outs = Set<Int>()
}

@MainActor
enum BoxLayout {
    static var usage: [UUID: PortUsage] = [:]

    static func rebuildUsage(_ patch: Patch) {
        var u: [UUID: PortUsage] = [:]
        for c in patch.cables {
            u[c.toNode, default: PortUsage()].ins.insert(c.toPort)
            u[c.fromNode, default: PortUsage()].outs.insert(c.fromPort)
        }
        usage = u
    }

    /// Collapsed: the patched ports, in display order (audio inlets first, then parameters in row order).
    static func collapsedLeft(_ node: PatchNode, _ spec: ModuleSpec) -> [Int] {
        let used = usage[node.id]?.ins ?? []
        let audio = spec.inputs.indices.filter { used.contains($0) }
        let params = rowParams(spec, node).map { kParamPortBase + $0 }.filter { used.contains($0) }
        let triggers = spec.params.indices.filter { spec.params[$0].isTrigger }.map { kParamPortBase + $0 }.filter { used.contains($0) }
        return audio + params + triggers
    }
    static func collapsedRight(_ node: PatchNode, _ spec: ModuleSpec) -> [Int] {
        let used = usage[node.id]?.outs ?? []
        return spec.outputs.indices.filter { used.contains($0) }
    }
    static func collapsedRows(_ node: PatchNode, _ spec: ModuleSpec) -> Int {
        max(collapsedLeft(node, spec).count, collapsedRight(node, spec).count)
    }
    private static func collapsedY(_ k: Int) -> CGFloat { header + 3 + CGFloat(k) * portRow + portRow / 2 }

    /// Label for any port number (audio inlet or parameter).
    static func inletName(_ spec: ModuleSpec, _ port: Int) -> String {
        if port >= kParamPortBase {
            let i = port - kParamPortBase
            return i < spec.params.count ? spec.params[i].name : "?"
        }
        return port < spec.inputs.count ? spec.inputs[port] : "?"
    }

    static let header: CGFloat = 22
    static let portRow: CGFloat = 15
    static let readout: CGFloat = 20
    static let row: CGFloat = 20
    static let port: CGFloat = 9
    static let paramPort: CGFloat = 7

    static func width(_ kind: String) -> CGFloat {
        switch kind {
        case "in", "out": return 132
        case "looper", "sampler": return 300
        case "stretch": return 280
        case "peq": return 320
        case "keys": return 300
        case "seq": return 320
        case "turing": return 220
        case "roll", "drums": return 410            // grid + outlet column beside it
        case "rack": return 480
        case "drumsynth": return 420
        case "fm": return 300
        case "plugin": return 240
        case "slider": return 200
        case "knob": return 240
        case "comp": return 240
        case "scope": return 320
        case "wave": return 300
        case "chord": return 220
        case "arrange": return 680
        default: return 186
        }
    }

    /// Width as drawn: the user's resized width, never narrower than the module's default.
    /// Default width for this box — slider / knob grow with their number of controls.
    static func defaultWidth(_ node: PatchNode) -> CGFloat {
        switch node.kind {
        case "slider": return max(width(node.kind), CGFloat(ControlsLayout.count(node.params["count"] ?? 2)) * 44 + 20 + sideOutletColumn)
        case "knob": return max(width(node.kind), CGFloat(min(ControlsLayout.count(node.params["count"] ?? 2), 4)) * 56 + 20 + sideOutletColumn)
        default: return width(node.kind)
        }
    }

    /// Default display height — knob gets a second row of full-size knobs past four.
    static func defaultReadoutHeight(_ node: PatchNode) -> CGFloat {
        if node.kind == "knob" && ControlsLayout.count(node.params["count"] ?? 2) > 4 { return readoutHeight(node.kind) * 2 - 10 }
        if node.kind == "arrange" { return arrangeTop + CGFloat(min(arrangeTracks(node), arrangeShown)) * arrangeLane + arrangeBottom }
        return readoutHeight(node.kind)
    }

    /// Free text: sized to what's written (monospaced 12 pt).
    static func textSize(_ node: PatchNode) -> CGSize {
        let lines = (node.text ?? "text").components(separatedBy: "\n")
        let longest = lines.map(\.count).max() ?? 4
        return CGSize(width: CGFloat(max(longest, 4)) * 7.3 + 14, height: CGFloat(max(lines.count, 1)) * 15 + 8)
    }

    static func width(_ node: PatchNode) -> CGFloat {
        if node.kind == "text" { return textSize(node).width }
        let d = defaultWidth(node)
        guard let w = node.w, w.isFinite else { return d }
        return min(max(CGFloat(w), d), 1600)
    }

    /// Display height as drawn: the user's resized height, never shorter than the default.
    /// samplerack / drumsynth: L, R, then one outlet per drum-roll row (a pad / voice on its own chain).
    static func hasLaneOutlets(_ kind: String) -> Bool { kind == "rack" || kind == "drumsynth" }

    /// arrange: toolbar + ruler at the top of its display, then one lane per track; each track's inlets and
    /// outlets sit level with its lane.
    static let arrangeTop: CGFloat = 38
    static let arrangeLane: CGFloat = 26
    /// under the lanes: the timeline's scrollbar, then the clip gain / transpose strip
    static let arrangeBottom: CGFloat = 36
    /// tracks a new box shows (taller boxes show more; the right-hand scrollbar reaches the rest)
    static let arrangeShown = 8
    /// The tracks in view: the first one, how many, how tall each lane is.
    static func arrangeView(_ node: PatchNode) -> (first: Int, shown: Int, laneH: CGFloat) {
        let n = arrangeTracks(node)
        let avail = max(readoutHeight(node) - arrangeTop - arrangeBottom, 8)
        let shown = min(n, max(1, Int((avail + 0.5) / arrangeLane)))
        let first = min(max(Int((node.params["vscroll"] ?? 0).rounded()), 0), n - shown)
        return (first, shown, avail / CGFloat(shown))
    }
    static func arrangeLaneVisible(_ node: PatchNode, _ lane: Int) -> Bool {
        let v = arrangeView(node)
        return lane >= v.first && lane < v.first + v.shown
    }
    static func arrangeTracks(_ node: PatchNode) -> Int { ArrangeLayout.count(node.params["tracks"]) }
    static func arrangeLaneHeight(_ node: PatchNode) -> CGFloat { arrangeView(node).laneH }
    /// A track's port: by its lane, or (scrolled out of view) on the top / bottom edge of the tracks.
    static func arrangePortY(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, lane: Int, second: Bool) -> CGFloat {
        let v = arrangeView(node)
        let top = header + portsHeight(node, spec, hw) + arrangeTop
        let k = lane - v.first
        if k < 0 { return top }
        if k >= v.shown { return top + CGFloat(v.shown) * v.laneH }
        return top + CGFloat(k) * v.laneH + v.laneH * (second ? 0.7 : 0.3)
    }

    /// rack / drumsynth: one drum-roll row. Making the box taller makes the rows taller (the pads keep their size).
    static func padLaneHeight(_ node: PatchNode) -> CGFloat {
        let (base, lanes): (CGFloat, Int) = node.kind == "rack" ? (RackView.rollHeight / CGFloat(RackLayout.pads), RackLayout.pads)
                                                                : (DrumSynthView.laneHeight, DrumSynthLayout.voices)
        return base + max(readoutHeight(node) - defaultReadoutHeight(node), 0) / CGFloat(lanes)
    }

    static func readoutHeight(_ node: PatchNode) -> CGFloat {
        let d = defaultReadoutHeight(node)
        guard d > 0, let h = node.dh, h.isFinite else { return d }
        return min(max(CGFloat(h), d), 1200)
    }

    /// Boxes with a display grow in both directions; the rest only get wider.
    static func resizable(_ kind: String) -> (width: Bool, height: Bool) {
        (kind != "in" && kind != "out", readoutHeight(kind) > 0)
    }

    static func hasReadout(_ kind: String) -> Bool {
        ["clock", "looper", "grain", "rec", "comp", "limit", "repeat", "gain", "mix", "smix",
         "sampler", "stretch", "peq", "keys", "seq", "turing", "roll", "drums", "slider", "knob", "lfo", "rack", "drumsynth", "scope", "wave", "chord", "fm", "plugin", "midi", "arrange"].contains(kind)
    }

    /// Height of the live area under the ports (waveforms and curves are taller).
    static func readoutHeight(_ kind: String) -> CGFloat {
        switch kind {
        case "rec": return 48 + 12 * 15 + 2     // REC / time, "open file location", the 12 newest recordings
        case "looper", "stretch": return 104
        case "sampler": return 122
        case "peq": return 150
        case "keys": return 72
        case "seq": return 100
        case "turing": return 74
        case "roll": return 168 + 34          // the grid, then the velocity lane
        case "drums": return 8 * portRow + 6    // one lane per outlet row, lined up
        case "slider": return 180
        case "knob": return 100
        case "rack": return 16 * 9 + 8 + 4 * 42 + 3 * 4 + 8
        case "drumsynth": return 4 * 14 + 8 + 42 + 8
        case "comp": return 92
        case "lfo": return 56
        case "fm": return 104                 // voice name, operators, the selected one's envelope
        case "plugin": return 104             // name + edit, what it is, what each knob moves
        case "midi": return 48                // in device, out device
        case "arrange": return 38 + 8 * 26 + 36   // toolbar, ruler, 8 lanes, scrollbar + clip strip
        case "clock": return 40               // tempo line + ▶ ❚❚ ■
        case "scope": return 160
        case "wave": return 170
        case "chord": return 58
        default: return hasReadout(kind) ? readout : 0
        }
    }

    /// Visible inlet/outlet names. in/out show as many ports as the interface has channels.
    static func ports(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts) -> (ins: [String], outs: [String]) {
        switch node.kind {
        // Show the interface's channels — and never hide a port that still has a cable
        // (e.g. when the disting is unplugged and a 1-channel mic takes over).
        case "in":
            let used = (usage[node.id]?.outs.max() ?? -1) + 1
            return ([], Array(spec.outputs.prefix(max(hw.inputs, used, 1))))
        case "out":
            let used = (usage[node.id]?.ins.filter { $0 < kParamPortBase }.max() ?? -1) + 1
            return (Array(spec.inputs.prefix(max(hw.outputs, used, 1))), [])
        case "mix": return (Array(spec.inputs.prefix(MixerLayout.channels(node.params["chans"] ?? 1))), spec.outputs)
        case "smix": return (Array(spec.inputs.prefix(2 * MixerLayout.channels(node.params["chans"] ?? 1))), spec.outputs)
        case "arrange":
            // a pair of inlets / outlets per track shown
            let n = arrangeTracks(node)
            return (Array(spec.inputs.prefix(2 * n)), Array(spec.outputs.prefix(3 + 2 * n)))
        case "div":
            // outlet labels follow each output's division
            return (spec.inputs, (0..<spec.outputs.count).map { k in
                let v = node.params["d\(k + 1)"] ?? Float(k + 1)
                return "÷\(v.isFinite ? Int(v.rounded()) : k + 1)"
            })
        case "slider", "knob":
            let used = (usage[node.id]?.outs.max() ?? -1) + 1
            return ([], Array(spec.outputs.prefix(max(ControlsLayout.count(node.params["count"] ?? 2), used))))
        default: return (spec.inputs, spec.outputs)
        }
    }

    static func hasTriggerRow(_ spec: ModuleSpec) -> Bool { spec.params.contains { $0.isTrigger } }

    /// Parameter indices drawn as rows (triggers share one button row above them).
    /// eq only shows the bands that are switched on.
    /// How many rows the box makes room for. samplerack / drumsynth: the most any pad's selection shows (the
    /// selected pad's rows plus other pads' rows with cables), so picking another pad doesn't resize the box.
    static func rowCount(_ spec: ModuleSpec, _ node: PatchNode) -> Int {
        guard spec.kind == "rack" || spec.kind == "drumsynth" else { return rowParams(spec, node).count }
        let pads = spec.kind == "rack" ? RackLayout.pads : DrumSynthLayout.voices
        var n = node, most = 0
        for k in 0..<pads { n.params["sel"] = Float(k); most = max(most, rowParams(spec, n).count) }
        return most
    }

    static func rowParams(_ spec: ModuleSpec, _ node: PatchNode) -> [Int] {
        var all = spec.params.indices.filter { !spec.params[$0].isTrigger }
        // roll: where its view sits is set by the scrollbar beside the grid, not a row
        if spec.kind == "roll" { all.removeAll { spec.params[$0].key == "low" } }
        // the algorithm/type selector is stored last (so old cables keep their slots) but shown first
        if let a = all.firstIndex(where: { spec.params[$0].key == "algo" }) { all.insert(all.remove(at: a), at: 0) }
        // voices is stored last too (old cables keep their slots); shown second, under the engine / shape
        if let a = all.firstIndex(where: { spec.params[$0].key == "voices" }) { all.insert(all.remove(at: a), at: min(1, all.count - 1)) }
        // attack is stored last too (old cables keep their slots) but sits just before decay
        if let a = all.firstIndex(where: { spec.params[$0].key == "attack" }),
           spec.params.contains(where: { $0.key == "decay" }) {
            let idx = all.remove(at: a)
            if let d = all.firstIndex(where: { spec.params[$0].key == "decay" }) { all.insert(idx, at: d) } else { all.append(idx) }
        }
        if spec.kind == "mix" || spec.kind == "smix" {
            let n = MixerLayout.channels(node.params["chans"] ?? 1)
            let showPans = (node.params["pans"] ?? 0) > 0.5
            let patched = usage[node.id]?.ins ?? []
            // channel count, every level, master, "show pans" — then, when shown, all the pans together below
            let levels = (0..<n).map { 1 + 2 * $0 }
            let pans = (0..<n).map { 2 + 2 * $0 }.filter { showPans || patched.contains(kParamPortBase + $0) }
            return [0] + levels + [MixerLayout.masterIndex, MixerLayout.showPansIndex] + pans
        }
        if spec.kind == "rack" {
            // the global rows, then only the selected pad's own (mute / solo live on the pads)
            let sel = Int((node.params["sel"] ?? 0).rounded())
            let b = RackLayout.base(min(max(sel, 0), RackLayout.pads - 1))
            let patched = usage[node.id]?.ins ?? []
            return (0..<RackLayout.globals).map { $0 } + (b..<b + 5).map { $0 }
                + all.filter { $0 >= RackLayout.globals && !($0 >= b && $0 < b + 5) && patched.contains(kParamPortBase + $0) }
        }
        if spec.kind == "fm" {
            // the main rows, then the selected operator's (the rest still play: a sysex voice sets them)
            let sel = min(max(Int((node.params["sel"] ?? 0).rounded()), 0), FMLayout.ops - 1)
            let b = FMLayout.base(sel)
            let patched = usage[node.id]?.ins ?? []
            let shown = FMLayout.shownGlobals + FMLayout.shownOp.map { b + $0 }
            return shown + all.filter { !shown.contains($0) && patched.contains(kParamPortBase + $0) }
        }
        if spec.kind == "drumsynth" {
            let sel = Int((node.params["sel"] ?? 0).rounded())
            let b = DrumSynthLayout.base(min(max(sel, 0), DrumSynthLayout.voices - 1))
            let patched = usage[node.id]?.ins ?? []
            let n = DrumSynthLayout.shown
            return (0..<DrumSynthLayout.globals).map { $0 } + (b..<b + n).map { $0 }
                + all.filter { $0 >= DrumSynthLayout.globals && !($0 >= b && $0 < b + n) && patched.contains(kParamPortBase + $0) }
        }
        if spec.kind == "slider" || spec.kind == "knob" {
            // the controls themselves live in the display; their rows appear only while CV is patched into them
            let patched = usage[node.id]?.ins ?? []
            return all.filter { $0 < 3 || patched.contains(kParamPortBase + $0) }
        }
        guard spec.kind == "peq" else { return all }
        let n = ParametricEQ.bandCount(node.params["bands"] ?? 0)
        return all.filter { $0 < 2 || ($0 - 2) / 3 < n }
    }

    /// div: each outlet sits on the right edge of its own "÷" parameter row, so the port rows above
    /// only hold the inlets (no dead space).
    static func rowOutlets(_ kind: String) -> Bool { kind == "div" }
    static func outletParam(_ kind: String, _ i: Int) -> Int? { kind == "div" ? DividerLayout.divIndex(i) : nil }

    static func portRows(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts) -> Int {
        let p = ports(node, spec, hw)
        if hasLaneOutlets(node.kind) { return max(p.ins.count, 2) }      // the pad / voice outlets sit beside the drum roll's rows
        if node.kind == "arrange" { return 3 }
        if node.kind == "slider" || node.kind == "knob" { return p.outs.count + 1 }   // the controls' outlets, then multi                            // mix L / R, multi; the tracks' ports sit by their lanes
        return rowOutlets(node.kind) ? p.ins.count : max(p.ins.count, p.outs.count)
    }

    /// slider / knob: the display sits beside the outlet column instead of under the port rows.
    static func sideDisplay(_ kind: String) -> Bool { ["slider", "knob", "drums", "roll"].contains(kind) }
    static let sideOutletColumn: CGFloat = 30

    /// Height of the part between the title and the parameter rows (ports + display).
    static func bodyHeight(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts) -> CGFloat {
        sideDisplay(node.kind) ? max(portsHeight(node, spec, hw), readoutHeight(node) + 6)
                               : portsHeight(node, spec, hw) + readoutHeight(node)
    }

    static func portsHeight(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts) -> CGFloat {
        let r = portRows(node, spec, hw)
        return r > 0 ? CGFloat(r) * portRow + 6 : 0
    }

    static func height(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts) -> CGFloat {
        if node.kind == "text" { return textSize(node).height }
        if node.collapsed {
            // title, patched ports, and the module's display (waveform, EQ curve, meters …)
            let r = collapsedRows(node, spec)
            let display = readoutHeight(node)
            return header + (r > 0 ? CGFloat(r) * portRow + 6 : 0) + (display > 0 ? display + 6 : 0)
        }
        let rows = rowCount(spec, node) + (hasTriggerRow(spec) ? 1 : 0)
        return header + bodyHeight(node, spec, hw)
            + (rows > 0 ? CGFloat(rows) * row + 4 : 0) + 4
    }

    static func inlet(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, _ i: Int) -> CGPoint {
        var y = header + 3 + CGFloat(i) * portRow + portRow / 2
        if node.kind == "arrange" && !node.collapsed { y = arrangePortY(node, spec, hw, lane: i / 2, second: i % 2 == 1) }
        if node.collapsed {
            y = collapsedLeft(node, spec).firstIndex(of: i).map(collapsedY) ?? header / 2
        }
        return CGPoint(x: node.x, y: node.y + y)
    }

    static func outlet(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, _ i: Int) -> CGPoint {
        var y = header + 3 + CGFloat(i) * portRow + portRow / 2
        if !node.collapsed, let pi = outletParam(node.kind, i), let ry = paramRowY(node, spec, hw, pi) { y = ry }
        if !node.collapsed && hasLaneOutlets(node.kind) && i >= 2 {
            // samplerack / drumsynth: pad (voice) k's outlet is level with its row in the drum roll
            let lane = padLaneHeight(node)
            y = header + portsHeight(node, spec, hw) + 4 + CGFloat(i - 2) * lane + lane / 2
        }
        if (node.kind == "slider" || node.kind == "knob") && !node.collapsed && i == ControlsLayout.multiOutlet {
            y = header + 3 + CGFloat(ports(node, spec, hw).outs.count) * portRow + portRow / 2
        }
        if node.kind == "arrange" && !node.collapsed && i >= 3 { y = arrangePortY(node, spec, hw, lane: (i - 3) / 2, second: (i - 3) % 2 == 1) }
        if node.collapsed {
            y = collapsedRight(node, spec).firstIndex(of: i).map(collapsedY) ?? header / 2
        }
        return CGPoint(x: node.x + width(node), y: node.y + y)
    }

    /// Local y (inside the box) of the centre of a parameter's row.
    static func paramRowY(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, _ param: Int) -> CGFloat? {
        if node.collapsed {
            return collapsedLeft(node, spec).firstIndex(of: kParamPortBase + param).map(collapsedY) ?? header / 2
        }
        guard let k = rowParams(spec, node).firstIndex(of: param) else { return nil }
        let k2 = k + (hasTriggerRow(spec) ? 1 : 0)
        return header + bodyHeight(node, spec, hw)
            + 2 + CGFloat(k2) * row + (row - 3) / 2
    }

    static func paramInlet(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, _ param: Int) -> CGPoint? {
        guard let y = paramRowY(node, spec, hw, param) else { return nil }
        return CGPoint(x: node.x, y: node.y + y)
    }

    /// Every port currently drawn on a box (for Pencil/mouse hover highlighting).
    static func visiblePorts(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts)
        -> [(point: CGPoint, name: String, output: Bool, port: Int)] {
        var r: [(CGPoint, String, Bool, Int)] = []
        let p = ports(node, spec, hw)
        if node.collapsed {
            for k in collapsedLeft(node, spec) {
                if let pt = destination(node, spec, hw, port: k) { r.append((pt, inletName(spec, k), false, k)) }
            }
            for k in collapsedRight(node, spec) { r.append((outlet(node, spec, hw, k), spec.outputs[k], true, k)) }
        } else {
            for k in p.ins.indices { r.append((inlet(node, spec, hw, k), p.ins[k], false, k)) }
            for k in p.outs.indices { r.append((outlet(node, spec, hw, k), p.outs[k], true, k)) }
            for k in rowParams(spec, node) {
                if let pt = paramInlet(node, spec, hw, k) { r.append((pt, spec.params[k].name, false, kParamPortBase + k)) }
            }
        }
        return r.map { (point: $0.0, name: $0.1, output: $0.2, port: $0.3) }
    }

    /// Canvas position of a cable's destination, for an audio inlet or a parameter inlet.
    static func destination(_ node: PatchNode, _ spec: ModuleSpec, _ hw: HardwareCounts, port: Int) -> CGPoint? {
        if port >= kParamPortBase { return paramInlet(node, spec, hw, port - kParamPortBase) }
        guard port < ports(node, spec, hw).ins.count else { return nil }
        return inlet(node, spec, hw, port)
    }
}
