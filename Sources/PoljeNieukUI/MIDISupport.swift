import SwiftUI
import PoljeNieukCore

// MIDI in the UI: the top bar's midi menu (which devices are on) and the midi box's device pickers.

extension AppModel {
    /// Top bar: every MIDI device, tick to switch it on / off (keyboards, sequencers and "all devices" boxes use these).
    func midiBarMenu() -> [MenuItem] {
        let hub = MIDIHub.shared
        var items: [MenuItem] = [.section("receive from")]
        items += hub.sources.isEmpty ? [MenuItem(title: "no MIDI devices", enabled: false)]
            : hub.sources.map { d in
                MenuItem(title: d.name, checked: hub.isOn(input: d.name), keepOpen: true) { hub.setInput(d.name, on: !hub.isOn(input: d.name)) }
            }
        items += [.divider, .section("send to")]
        items += hub.destinations.isEmpty ? [MenuItem(title: "no MIDI devices", enabled: false)]
            : hub.destinations.map { d in
                MenuItem(title: d.name, checked: hub.isOn(output: d.name), keepOpen: true) { hub.setOutput(d.name, on: !hub.isOn(output: d.name)) }
            }
        items += [.divider, MenuItem(title: "Refresh MIDI devices", action: { hub.rescan() })]
        return items
    }

    /// The midi box: which device it listens to / sends to.
    func midiDeviceMenu(_ id: UUID, input: Bool) -> [MenuItem] {
        let hub = MIDIHub.shared
        let key = input ? MIDIBoxLayout.inKey : MIDIBoxLayout.outKey
        let current = PluginCatalog.text(patch.nodes.first { $0.id == id }?.data[key])
        let pick: (String) -> Void = { [weak self] name in self?.setData(id, key, PluginCatalog.codes(name)) }
        var items = [MenuItem(title: "all devices (on in the midi menu)", checked: current.isEmpty) { pick("") }]
        if !input { items.append(MenuItem(title: "none", checked: current == "none") { pick("none") }) }
        items.append(.divider)
        let list = input ? hub.sources : hub.destinations
        items += list.map { d in MenuItem(title: d.name, checked: current == d.name) { pick(d.name) } }
        if !current.isEmpty && current != "none" && !list.contains(where: { $0.name == current }) {
            items.append(MenuItem(title: current + "  (not connected)", checked: true, enabled: false))
        }
        return items
    }
}

final class MIDIBoxDisplay: NativeDisplay {
    private func row(_ k: Int, _ r: CGRect) -> CGRect { CGRect(x: r.minX, y: r.minY + 4 + CGFloat(k) * 22, width: r.width, height: 19) }
    private var mnode: MIDIBoxNode? { dsp as? MIDIBoxNode }

    override func parts(_ r: CGRect) -> [LivePart] {
        let inner = r
        return [part("midi", inner, signature: { [weak self] in
            guard let self, let n = self.mnode else { return 0 }
            return Int(n.readouts[1]) | Int(n.readouts[2]) << 1 | Int(n.readouts[3]) << 2
                | (n.inName.hashValue & 0xFFFF) << 4 ^ n.outName.hashValue
        }) { [weak self] g, _ in
            guard let self else { return }
            let n = self.mnode
            for k in 0..<2 {
                let q = self.row(k, r).offsetBy(dx: -inner.minX, dy: -inner.minY)
                g.fill(Path(roundedRect: q, cornerRadius: 2), with: .color(Theme.row))
                let name = k == 0 ? (n?.inName ?? "") : (n?.outName ?? "")
                let missing = (Int(n?.readouts[3] ?? 0) >> k) & 1 == 1
                let shown = name.isEmpty ? "all devices" : (missing ? name + " (not connected)" : name)
                let lit = (n?.readouts[k + 1] ?? 0) > 0
                g.fill(Path(ellipseIn: CGRect(x: q.minX + 6, y: q.midY - 3, width: 6, height: 6)),
                       with: .color(lit ? Theme.text : Theme.faint))
                g.draw(LiveText(k == 0 ? "in" : "out", size: 9, color: Theme.dim), at: CGPoint(x: q.minX + 17, y: q.midY), anchor: .leading)
                g.draw(LiveText(fitText(shown + "  ▾", size: 10, width: q.width - 46), size: 10, color: missing ? Theme.dim : Theme.text),
                       at: CGPoint(x: q.minX + 40, y: q.midY), anchor: .leading)
            }
        }]
    }

    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        row(0, r).contains(p) || row(1, r).contains(p)
    }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard !info.moved else { return }
        for k in 0..<2 where row(k, r).contains(p) {
            let q = row(k, r)
            model.panelMenu = .init(items: model.midiDeviceMenu(id, input: k == 0),
                                    at: model.toScreen(CGPoint(x: node.x + q.minX, y: node.y + q.maxY + 2)))
        }
    }
}
