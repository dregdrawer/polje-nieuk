import SwiftUI
import PoljeNieukCore

/// Help mode: the ? button in the top bar. While it's on, pointing at something (mouse, trackpad,
/// or Apple Pencil hover on iPad) shows what it is and how to use it in a panel.
struct HelpTopic: Equatable {
    let id: String
    let title: String
    let body: String
}

extension View {
    /// Explain this view in the help panel while help mode is on.
    func helpTopic(_ model: AppModel, _ id: String, _ title: String, _ body: String) -> some View {
        modifier(HelpHover(model: model, topic: HelpTopic(id: id, title: title, body: body)))
    }
}

/// Only while help mode is on: hover areas cost on every frame the canvas moves (and the model isn't watched
/// here, so the hundreds of these don't all re-run whenever anything in the patch changes).
private struct HelpHover: ViewModifier {
    let model: AppModel
    let topic: HelpTopic
    @Environment(\.helpModeOn) private var on
    func body(content: Content) -> some View {
        if on {
            content.onHover { inside in model.hoverHelp(topic, inside: inside) }
        } else {
            content
        }
    }
}

private struct HelpModeOnKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var helpModeOn: Bool {
        get { self[HelpModeOnKey.self] }
        set { self[HelpModeOnKey.self] = newValue }
    }
}

/// The panel in the bottom-left corner of the canvas.
struct HelpPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let t = model.helpTopics.last
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t?.title ?? "help").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button { model.helpMode = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            Text(t?.body ?? "Point at anything — a box, an inlet or outlet, a parameter, a button up top — to see what it does.")
                .font(Theme.monoSmall).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        // shadow on the panel's shape only — on the whole view SwiftUI would shadow every line of text
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.box)
            .shadow(color: .black.opacity(Theme.light ? 0.18 : 0.35), radius: 8))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
        .padding(12)
    }
}

/// Plain-language descriptions of inlets and outlets, by their names.
enum PortHelp {
    static func describe(_ spec: ModuleSpec, port: Int, output: Bool) -> (String, String) {
        if port >= kParamPortBase {
            let i = port - kParamPortBase
            let p = i < spec.params.count ? spec.params[i] : nil
            return ("\(spec.name) · \(p?.name ?? "parameter") (CV in)",
                    "Patch any outlet here to move this parameter. ±1.0 (≈ ±10 V) sweeps its whole range; use atten to scale. A slider / knob patched here takes it over completely and moves with its row.")
        }
        let names = output ? spec.outputs : spec.inputs
        let name = port < names.count ? names[port] : "?"
        let n = name.lowercased()
        let kind = output ? "outlet" : "inlet"
        let what: String
        switch n {
        case "l", "r", "in", "out": what = output ? "Audio out — patch to out or into another box." : "Audio in."
        case "pitch": what = output ? "Pitch CV out, 1 V/oct (0.1 = one octave). Patch into a voice's pitch inlet or out to the modular." : "Pitch CV in, 1 V/oct (0.1 = one octave)."
        case "gate": what = output ? "Gate out: high while a note / step is on." : "Gate in: high starts, low releases."
        case "trig", "strum", "seed": what = output ? "Trigger pulses out." : "Trigger in: each rising edge fires it."
        case "clock", "t clk", "x clk": what = output ? "Clock pulses out." : "Clock in: pulses from the modular or clock drive it."
        case "reset": what = "Reset in: a pulse goes back to the start."
        case "sc": what = "Sidechain in: this signal drives the compression instead of the input."
        case "freeze": what = "Freeze in: high holds the current sound."
        case "vel": what = "Velocity CV out."
        case "rec": what = "Record gate in: a pulse starts / stops recording."
        case "play": what = "Play gate in: a pulse restarts playback."
        case "pulse": what = "Clock pulses at the chosen division."
        case "ramp": what = "A 0…1 ramp each beat — handy as a synced LFO."
        default:
            if n.hasPrefix("÷") { what = "Divided clock: fires once every \(n.dropFirst()) clock pulses (set below)." }
            else { what = output ? "Signal out." : "Signal in." }
        }
        return ("\(spec.name) · \(kind) \(name)", what + (output ? " Drag from here to an inlet or a parameter's ○ to connect." : " Drag an outlet here to connect; drag a plugged cable's end to move it."))
    }

    static func module(_ spec: ModuleSpec) -> (String, String) {
        var body = spec.summary + "."
        if !spec.inputs.isEmpty { body += "\nIn: " + spec.inputs.joined(separator: ", ") + "." }
        if !spec.outputs.isEmpty { body += "\nOut: " + spec.outputs.joined(separator: ", ") + "." }
        body += "\nDrag the title to move · double-click the title to duplicate · ○/● bypasses · corner dot resizes."
        return (spec.name, body)
    }

    static func param(_ spec: ModuleSpec, _ p: ParamSpec) -> (String, String) {
        var range = ""
        switch p.kind {
        case .choice(let o): range = "Choices: " + o.prefix(8).joined(separator: ", ") + (o.count > 8 ? " …" : "") + "."
        case .toggle: range = "On / off."
        case .trigger: range = "Press to fire."
        default: range = "Range \(p.display(p.min)) … \(p.display(p.max))\(p.unit.isEmpty ? "" : " " + p.unit)."
        }
        return ("\(spec.name) · \(p.name)", range + " Drag across the row to change it, double-tap to reset. The ○ on its left takes a CV / modulation cable.")
    }
}

/// The tidy button's icon: a # grid.
struct HashGridIcon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for f in [1.0 / 3, 2.0 / 3] {
            p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        return p
    }
}
