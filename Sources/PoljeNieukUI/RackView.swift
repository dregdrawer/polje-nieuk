import SwiftUI
import PoljeNieukCore

/// rack~: the drum roll (one lane per pad) above a 4 × 4 pad grid, like a drum rack.
/// Pads: tap to play and select (its settings show as rows below), M / S mute and solo,
/// drop an audio file on a pad to load it (right-click / long-press: back to the built-in sound).
struct RackView: View {
    let node: RackNode
    @ObservedObject var model: AppModel
    let patchNode: PatchNode
    private var clocked: Bool { clockPatched(model, patchNode.id) }
    @State private var paint: Float?

    private var len: Int { Int((patchNode.params["len"] ?? 16).rounded()) }
    private var selected: Int { Int((patchNode.params["sel"] ?? 0).rounded()) }
    static let rollHeight: CGFloat = 16 * 9
    static let label: CGFloat = 64

    var body: some View {
        VStack(spacing: 8) {
            roll.frame(height: Self.rollHeight)
            pads
        }
    }

    // MARK: drum roll

    private var roll: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // lane names = pad names (tap: select that pad)
                VStack(spacing: 0) {
                    ForEach(0..<RackLayout.pads, id: \.self) { k in
                        Text(node.padNames[k]).font(.system(size: 7.5, design: .monospaced))
                            .foregroundStyle(k == selected ? Theme.text : Theme.dim)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(width: Self.label - 4, height: Self.rollHeight / 16, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { select(k); if !clocked { node.audition = k } }
                    }
                }
                .frame(width: Self.label)
                LiveCanvas(signature: {
                    var h = model.isRunning ? Int(node.readouts[0]) : -1
                    LiveSig.mix(&h, LiveSig.floats(node.hits, RackLayout.pads * RackLayout.steps))
                    LiveSig.mix(&h, LiveSig.patch(patchNode)); LiveSig.mix(&h, selected)
                    return h
                }) { ctx, size in drawRoll(ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let w = geo.size.width - Self.label
                            let cw = w / CGFloat(max(len, 1)), rh = Self.rollHeight / 16
                            let s = Int(v.location.x / cw), lane = Int(v.location.y / rh)
                            guard s >= 0 && s < len && lane >= 0 && lane < RackLayout.pads else { return }
                            let i = lane * RackLayout.steps + s
                            if paint == nil { paint = node.hits[i] > 0.5 ? 0 : 1 }
                            node.hits[i] = paint!
                        }
                        .onEnded { _ in
                            paint = nil
                            model.setData(patchNode.id, "hits", (0..<RackLayout.pads * RackLayout.steps).map { node.hits[$0] })
                        })
            }
        }
    }

    private func drawRoll(_ ctx: GraphicsContext, _ size: CGSize) {
        let cw = size.width / CGFloat(max(len, 1)), rh = size.height / 16
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        for lane in 0..<RackLayout.pads where lane % 2 == 1 {
            ctx.fill(Path(CGRect(x: 0, y: CGFloat(lane) * rh, width: size.width, height: rh)), with: .color(Theme.shade))
        }
        ctx.fill(Path(CGRect(x: 0, y: CGFloat(selected) * rh, width: size.width, height: rh)), with: .color(Theme.text.opacity(0.08)))
        drawStepGrid(ctx, size, steps: len, division: patchNode.params["div"])
        let ps = model.isRunning ? Int(node.readouts[0]) : -1
        if ps >= 0 && ps < len {
            ctx.fill(Path(CGRect(x: CGFloat(ps) * cw, y: 0, width: cw, height: size.height)), with: .color(Theme.text.opacity(0.12)))
        }
        for lane in 0..<RackLayout.pads {
            for s in 0..<len where node.hits[lane * RackLayout.steps + s] > 0.5 {
                let r = CGRect(x: CGFloat(s) * cw + 1, y: CGFloat(lane) * rh + 1, width: cw - 2, height: rh - 2)
                ctx.fill(Path(r), with: .color(s == ps ? Theme.text : Theme.text.opacity(0.8)))
            }
        }
    }

    // MARK: pads (4 × 4, pad 1 bottom-left)

    private var pads: some View {
        VStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { col in
                        pad((3 - row) * 4 + col)
                    }
                }
            }
        }
    }

    private func select(_ k: Int) {
        if let i = ModuleRegistry.spec("rack")?.paramIndex("sel") { model.setParam(patchNode.id, i, Float(k)) }
    }

    private func toggle(_ key: String) {
        guard let spec = ModuleRegistry.spec("rack"), let i = spec.paramIndex(key) else { return }
        model.setParam(patchNode.id, i, (patchNode.params[key] ?? 0) > 0.5 ? 0 : 1)
    }

    private func pad(_ k: Int) -> some View {
        let muted = (patchNode.params["m\(k + 1)"] ?? 0) > 0.5
        let solo = (patchNode.params["s\(k + 1)"] ?? 0) > 0.5
        return VStack(alignment: .leading, spacing: 2) {
            Text(node.padNames[k]).font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(muted ? Theme.faint : Theme.text)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                small("M", on: muted) { toggle("m\(k + 1)") }
                small("▶", on: false) { node.audition = k; select(k) }
                small("S", on: solo) { toggle("s\(k + 1)") }
            }
        }
        .padding(4)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(LiveCanvas(signature: { LiveSig.q(min(max(node.readouts[1 + k], 0), 1), 8) }, every: 2) { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
            let lv = CGFloat(min(max(node.readouts[1 + k], 0), 1))
            if lv > 0.01 { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.text.opacity(0.35 * lv))) }
        })
        .overlay(Rectangle().stroke(k == selected ? Theme.text : Theme.border, lineWidth: k == selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { select(k); if !clocked { node.audition = k } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            return model.loadPad(patchNode.id, k, from: u)
        }
        .contextMenu {
            Button("Back to the built-in \(RackLayout.kitNames[k])") { model.resetPad(patchNode.id, k) }
        }
        .help("\(node.padNames[k]) — tap to play (when no clock is patched in; ▶ always plays) · drop an audio file to load · M mute · S solo")
    }

    private func small(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? Theme.inverse : Theme.dim)
                .frame(width: 15, height: 12)
                .background(on ? Theme.text : Theme.box)
        }
        .buttonStyle(.plain)
    }
}

/// drumsynth~: same look and handling as rack~ — a drum roll (one lane per voice) above a row of
/// four pads with M ▶ S; tap a pad to play and select it (its settings show as rows below).
struct DrumSynthView: View {
    let node: DrumSynthNode
    @ObservedObject var model: AppModel
    let patchNode: PatchNode
    private var clocked: Bool { clockPatched(model, patchNode.id) }
    @State private var paint: Float?

    static let laneHeight: CGFloat = 14
    static let label: CGFloat = 52
    private var len: Int { Int((patchNode.params["len"] ?? 16).rounded()) }
    private var selected: Int { Int((patchNode.params["sel"] ?? 0).rounded()) }
    private let V = DrumSynthLayout.voices

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<V, id: \.self) { v in
                            Text(name(v)).font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(v == selected ? Theme.text : Theme.dim)
                                .lineLimit(1)
                                .frame(width: Self.label - 4, height: Self.laneHeight, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { select(v); if !clocked { node.audition = v } }
                        }
                    }
                    .frame(width: Self.label)
                    LiveCanvas(signature: {
                        var h = model.isRunning ? Int(node.readouts[0]) : -1
                        LiveSig.mix(&h, LiveSig.floats(node.hits, DrumSynthLayout.voices * DrumSynthLayout.steps))
                        LiveSig.mix(&h, LiveSig.patch(patchNode)); LiveSig.mix(&h, selected)
                        return h
                    }) { ctx, size in drawRoll(ctx, size) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let cw = (geo.size.width - Self.label) / CGFloat(max(len, 1))
                                let s = Int(v.location.x / cw), lane = Int(v.location.y / Self.laneHeight)
                                guard s >= 0 && s < len && lane >= 0 && lane < V else { return }
                                let i = lane * DrumSynthLayout.steps + s
                                if paint == nil { paint = node.hits[i] > 0.5 ? 0 : 1 }
                                node.hits[i] = paint!
                            }
                            .onEnded { _ in
                                paint = nil
                                model.setData(patchNode.id, "hits", (0..<V * DrumSynthLayout.steps).map { node.hits[$0] })
                            })
                }
            }
            .frame(height: Self.laneHeight * CGFloat(V))
            HStack(spacing: 4) { ForEach(0..<V, id: \.self) { pad($0) } }
        }
    }

    private func drawRoll(_ ctx: GraphicsContext, _ size: CGSize) {
        let cw = size.width / CGFloat(max(len, 1)), rh = Self.laneHeight
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
        for lane in 0..<V where lane % 2 == 1 {
            ctx.fill(Path(CGRect(x: 0, y: CGFloat(lane) * rh, width: size.width, height: rh)), with: .color(Theme.shade))
        }
        ctx.fill(Path(CGRect(x: 0, y: CGFloat(selected) * rh, width: size.width, height: rh)), with: .color(Theme.text.opacity(0.08)))
        drawStepGrid(ctx, size, steps: len, division: patchNode.params["div"])
        let ps = model.isRunning ? Int(node.readouts[0]) : -1
        if ps >= 0 && ps < len {
            ctx.fill(Path(CGRect(x: CGFloat(ps) * cw, y: 0, width: cw, height: size.height)), with: .color(Theme.text.opacity(0.12)))
        }
        for lane in 0..<V {
            for s in 0..<len where node.hits[lane * DrumSynthLayout.steps + s] > 0.5 {
                let r = CGRect(x: CGFloat(s) * cw + 1, y: CGFloat(lane) * rh + 1, width: cw - 2, height: rh - 2)
                ctx.fill(Path(r), with: .color(s == ps ? Theme.text : Theme.text.opacity(0.8)))
            }
        }
    }

    private func select(_ v: Int) {
        if let i = ModuleRegistry.spec("drumsynth")?.paramIndex("sel") { model.setParam(patchNode.id, i, Float(v)) }
    }

    /// The voice's name, or its engine's when it's been switched to another one.
    private func name(_ v: Int) -> String {
        let e = Int((patchNode.params["e\(v + 1)"] ?? Float(DrumSynthLayout.engines[v])).rounded())
        return DrumSynthLayout.label(v, engine: e)
    }

    private func toggle(_ key: String) {
        guard let spec = ModuleRegistry.spec("drumsynth"), let i = spec.paramIndex(key) else { return }
        model.setParam(patchNode.id, i, (patchNode.params[key] ?? 0) > 0.5 ? 0 : 1)
    }

    private func pad(_ v: Int) -> some View {
        let muted = (patchNode.params["m\(v + 1)"] ?? 0) > 0.5
        let solo = (patchNode.params["s\(v + 1)"] ?? 0) > 0.5
        return VStack(alignment: .leading, spacing: 2) {
            Text(name(v)).font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(muted ? Theme.faint : Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                small("M", on: muted) { toggle("m\(v + 1)") }
                small("▶", on: false) { node.audition = v; select(v) }
                small("S", on: solo) { toggle("s\(v + 1)") }
            }
        }
        .padding(4)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(LiveCanvas(signature: { LiveSig.q(min(max(node.readouts[1 + v], 0), 1), 8) }, every: 2) { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.row))
            let lv = CGFloat(min(max(node.readouts[1 + v], 0), 1))
            if lv > 0.01 { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.text.opacity(0.35 * lv))) }
        })
        .overlay(Rectangle().stroke(v == selected ? Theme.text : Theme.border, lineWidth: v == selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { select(v); if !clocked { node.audition = v } }
        .help("\(name(v)) — tap to play (when no clock is patched in; ▶ always plays) · M mute · S solo")
    }

    private func small(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? Theme.inverse : Theme.dim)
                .frame(width: 15, height: 12)
                .background(on ? Theme.text : Theme.box)
        }
        .buttonStyle(.plain)
    }
}

/// The step grid for drum / piano rolls and seq~: a faint line on every step, a stronger one on each beat
/// and the strongest on each bar — placed from the division, so 1/32 shows 8 steps per beat, 1/8 shows 2.
func drawStepGrid(_ ctx: GraphicsContext, _ size: CGSize, steps len: Int, division: Float?) {
    let cw = size.width / CGFloat(max(len, 1))
    let beats = Divisions.beats(division ?? Float(Divisions.index("1/16")))     // beats per step
    for s in 1..<max(len, 1) {
        let pos = Double(s) * beats                       // where this step starts, in beats
        let onBeat = abs(pos - pos.rounded()) < 1e-6
        let onBar = onBeat && Int(pos.rounded()) % 4 == 0
        let x = CGFloat(s) * cw
        if onBar {
            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.dim.opacity(0.7)))
        } else if onBeat {
            ctx.fill(Path(CGRect(x: x - 0.25, y: 0, width: 0.75, height: size.height)), with: .color(Theme.dim.opacity(0.45)))
        } else if cw >= 4 {
            ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(Theme.faint.opacity(0.45)))
        }
    }
}

/// A small "clear the pattern" button for the corner of a roll.
struct ClearPatternButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .frame(width: 15, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear the pattern (undo brings it back)")
    }
}

/// True when a cable feeds the clock inlet (inlet 0) of this box: pad taps then only select.
@MainActor func clockPatched(_ model: AppModel, _ id: UUID) -> Bool {
    model.patch.cables.contains { $0.toNode == id && $0.toPort == 0 }
}
