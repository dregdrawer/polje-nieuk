// plugin box: picking a plugin, mapping its knobs, its editor window, and keeping its state in the patch.
import SwiftUI
import PoljeNieukCore
import PluginBridge
import CoreAudioKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension AppModel {
    /// Installed plugins (scanned once; "Rescan" scans again).
    static var pluginCache: [PluginInfo]?
    var plugins: [PluginInfo] {
        if let c = Self.pluginCache { return c }
        let c = PluginCatalog.cached ?? PluginCatalog.scan()
        Self.pluginCache = c
        return c
    }

    func pluginNode(_ id: UUID) -> PluginNode? { host.node(id) as? PluginNode }

    /// Put a plugin in the box (one undo step). Its knobs map to its first four parameters.
    func choosePlugin(_ id: UUID, _ info: PluginInfo?) {
        guard let i = patch.index(of: id) else { return }
        PluginWindows.close(id)
        checkpointNow()
        let pid = info.map { PluginCatalog.codes($0.id) } ?? []
        patch.nodes[i].data["plugin"] = pid
        patch.nodes[i].data["pname"] = info.map { PluginCatalog.codes($0.name) } ?? []
        patch.nodes[i].data["state"] = []
        patch.nodes[i].data["map"] = (0..<PluginLayout.macros).map(Float.init)
        if let n = pluginNode(id) {
            n.setData("state", [])
            n.setData("map", patch.nodes[i].data["map"]!)
            n.setData("pname", patch.nodes[i].data["pname"]!)
            n.setData("plugin", pid)
        }
        checkpointNow()
        scheduleAutosave()
    }

    /// Knob k now moves parameter `param` of the plugin (-1: nothing). The knob jumps to where it is.
    func mapPluginKnob(_ id: UUID, _ k: Int, _ param: Int) {
        guard let i = patch.index(of: id), let n = pluginNode(id), let spec = ModuleRegistry.spec("plugin") else { return }
        checkpointNow()
        var m = patch.nodes[i].data["map"] ?? (0..<PluginLayout.macros).map(Float.init)
        while m.count < PluginLayout.macros { m.append(-1) }
        m[k] = Float(param)
        patch.nodes[i].data["map"] = m
        if let v = n.knobValue(for: param) {
            let pi = PluginLayout.firstMacro + k
            patch.nodes[i].params[spec.params[pi].key] = v
            n.base[pi] = v
        }
        n.setData("map", m)
        checkpointNow()
        scheduleAutosave()
    }

    /// The plugin's state into the patch (after its editor closes, before saving).
    func storePluginState(_ id: UUID) {
        guard let i = patch.index(of: id), let n = pluginNode(id), let s = n.captureState() else { return }
        if patch.nodes[i].data["state"] != s { patch.nodes[i].data["state"] = s }
    }
    func storeAllPluginStates() {
        for n in patch.nodes where n.kind == "plugin" { storePluginState(n.id) }
    }
    /// For the autosave: the same, into a copy (the screen's patch doesn't change).
    func withPluginStates(_ p: Patch) -> Patch {
        var p = p
        for (i, n) in p.nodes.enumerated() where n.kind == "plugin" {
            if let s = pluginNode(n.id)?.captureState() { p.nodes[i].data["state"] = s }
        }
        return p
    }

    func pluginMenu(_ id: UUID) -> [MenuItem] {
        let n = pluginNode(id)
        var items: [MenuItem] = []
        if let p = n?.plugin {
            items.append(.section(p.name))
            items.append(MenuItem(title: "Open editor", action: { [weak self] in self.map { PluginWindows.open(id, model: $0) } }))
            items.append(MenuItem(title: "Remove plugin", action: { [weak self] in self?.choosePlugin(id, nil) }))
            items.append(.divider)
        }
        let all = plugins
        let cur = n?.pluginID ?? ""
        func byVendor(_ list: [PluginInfo]) -> [MenuItem] {
            var groups: [(String, [PluginInfo])] = []
            for p in list {
                let v = p.vendor.isEmpty ? "other" : p.vendor
                if let k = groups.firstIndex(where: { $0.0 == v }) { groups[k].1.append(p) } else { groups.append((v, [p])) }
            }
            return groups.map { v, ps in
                MenuItem(title: "\(v)  (\(ps.count))", submenu: ps.map { p in
                    MenuItem(title: p.name, checked: p.id == cur, action: { [weak self] in self?.choosePlugin(id, p) })
                })
            }
        }
        let inst = all.filter { $0.format == "AU" && $0.instrument }, fx = all.filter { $0.format == "AU" && !$0.instrument }
        let vst = all.filter { $0.format == "VST3" }
        if !inst.isEmpty { items.append(MenuItem(title: "Instruments (AU)", submenu: byVendor(inst))) }
        if !fx.isEmpty { items.append(MenuItem(title: "Effects (AU)", submenu: byVendor(fx))) }
        if !vst.isEmpty { items.append(MenuItem(title: "VST3", submenu: byVendor(vst))) }
        if all.isEmpty { items.append(MenuItem(title: "no plugins found", enabled: false)) }
        items.append(.divider)
        items.append(MenuItem(title: "Rescan plugins", action: { Self.pluginCache = nil; PluginCatalog.cached = nil }))
        return items
    }

    func pluginKnobMenu(_ id: UUID, _ k: Int) -> [MenuItem] {
        guard let n = pluginNode(id), let p = n.plugin else { return [MenuItem(title: "no plugin loaded", enabled: false)] }
        let cur = Int(n.map[k])
        let names = p.paramNames
        var items: [MenuItem] = [.section("knob \(k + 1) moves"),
                                 MenuItem(title: "nothing", checked: cur < 0, action: { [weak self] in self?.mapPluginKnob(id, k, -1) })]
        func row(_ i: Int) -> MenuItem {
            MenuItem(title: names[i].isEmpty ? "parameter \(i + 1)" : names[i], checked: i == cur,
                     action: { [weak self] in self?.mapPluginKnob(id, k, i) })
        }
        let count = min(names.count, 1024)
        if count <= 40 {
            items += (0..<count).map(row)
        } else {
            for start in stride(from: 0, to: count, by: 40) {
                let end = min(start + 40, count)
                items.append(MenuItem(title: "\(start + 1)–\(end)  \(names[start])…", submenu: (start..<end).map(row)))
            }
        }
        return items
    }
}

// MARK: - the display: name (click for the list), edit, what each knob moves

final class PluginDisplay: NativeDisplay {
    private func nameRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: r.minY + 4, width: r.width - 44, height: 20) }
    private func editRect(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 40, y: r.minY + 4, width: 40, height: 20) }
    private func knobRect(_ k: Int, _ r: CGRect) -> CGRect { CGRect(x: r.minX, y: r.minY + 42 + CGFloat(k) * 15, width: r.width, height: 14) }
    private var pnode: PluginNode? { dsp as? PluginNode }

    override func parts(_ r: CGRect) -> [LivePart] {
        let inner = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        return [part("plugin", inner, signature: { [weak self] in
            guard let n = self?.pnode else { return 0 }
            return n.generation &* 4 &+ (n.loading ? 1 : 0) &+ (n.plugin == nil ? 2 : 0)
        }) { [weak self] g, _ in
            guard let self else { return }
            let o = CGPoint(x: -inner.minX, y: -inner.minY)
            func at(_ q: CGRect) -> CGRect { q.offsetBy(dx: o.x, dy: o.y) }
            let n = self.pnode, p = n?.plugin
            let nr = at(self.nameRect(r)), er = at(self.editRect(r))
            g.fill(Path(roundedRect: nr, cornerRadius: 2), with: .color(Theme.row))
            let saved = PluginCatalog.text(self.node.data["pname"])
            let title = p?.name ?? (saved.isEmpty ? "choose a plugin…" : saved)
            g.draw(LiveText(fitText(title + "  ▾", size: 11, width: nr.width - 12), size: 11, color: p == nil && saved.isEmpty ? Theme.dim : Theme.text, bold: p != nil),
                   at: CGPoint(x: nr.minX + 6, y: nr.midY), anchor: .leading)
            g.fill(Path(roundedRect: er, cornerRadius: 2), with: .color(p == nil ? Theme.row.opacity(0.5) : Theme.row))
            g.draw(LiveText("edit", size: 9, color: p == nil ? Theme.faint : Theme.text), at: CGPoint(x: er.midX, y: er.midY))
            // what it is, or why it isn't there
            var line: String
            if n?.loading == true { line = "loading…" }
            else if let s = n?.status, !s.isEmpty { line = s }
            else if let p { line = [p.vendor, p.format, p.isInstrument ? "instrument" : "effect"].filter { !$0.isEmpty }.joined(separator: " · ") }
            else if !saved.isEmpty { line = "not installed here" }
            else { line = "AU / VST3 effects and instruments" }
            g.draw(LiveText(fitText(line, size: 8, width: r.width - 4), size: 8, color: Theme.faint),
                   at: CGPoint(x: nr.minX + 2, y: nr.maxY + 8), anchor: .leading)
            // knob k → parameter
            for k in 0..<PluginLayout.macros {
                let kr = at(self.knobRect(k, r))
                let i = n.map { Int($0.map[k]) } ?? -1
                let pname: String
                if let p, i >= 0, i < p.paramNames.count { pname = p.paramNames[i].isEmpty ? "parameter \(i + 1)" : p.paramNames[i] }
                else { pname = i < 0 ? "—" : "parameter \(i + 1)" }
                g.fill(Path(roundedRect: kr, cornerRadius: 2), with: .color(Theme.row.opacity(0.6)))
                g.draw(LiveText("knob \(k + 1)", size: 8, color: Theme.dim), at: CGPoint(x: kr.minX + 5, y: kr.midY), anchor: .leading)
                g.draw(LiveText(fitText(pname, size: 9, width: kr.width - 60), size: 9, color: Theme.text),
                       at: CGPoint(x: kr.minX + 50, y: kr.midY), anchor: .leading)
            }
        }]
    }

    private func show(_ items: [MenuItem], _ at: CGPoint) {
        model.panelMenu = .init(items: items, at: model.toScreen(CGPoint(x: node.x + at.x, y: node.y + at.y)))
    }

    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        nameRect(r).contains(p) || editRect(r).contains(p) || (0..<PluginLayout.macros).contains { knobRect($0, r).contains(p) }
    }
    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        guard !info.moved else { return }
        if nameRect(r).contains(p) { show(model.pluginMenu(id), CGPoint(x: nameRect(r).minX, y: nameRect(r).maxY + 2)); return }
        if editRect(r).contains(p) { if pnode?.plugin != nil { PluginWindows.open(id, model: model) }; return }
        for k in 0..<PluginLayout.macros where knobRect(k, r).contains(p) {
            show(model.pluginKnobMenu(id, k), CGPoint(x: knobRect(k, r).minX, y: knobRect(k, r).maxY + 2)); return
        }
    }
}

// MARK: - the plugin's own editor

@MainActor enum PluginWindows {
    #if os(macOS)
    final class Entry: NSObject, NSWindowDelegate {
        let id: UUID
        weak var model: AppModel?
        let window: NSWindow
        let plugin: HostedPlugin
        var timer: Timer?
        init(id: UUID, model: AppModel, window: NSWindow, plugin: HostedPlugin) {
            self.id = id; self.model = model; self.window = window; self.plugin = plugin
        }
        func windowWillClose(_ notification: Notification) {
            timer?.invalidate()
            if let v = plugin as? VST3Plugin { pnvst3_close_editor(v.handle) }
            model?.storePluginState(id)
            model?.scheduleAutosave()
            open.removeValue(forKey: id)
        }
    }
    static var open: [UUID: Entry] = [:]

    static func close(_ id: UUID) { open[id]?.window.close() }

    static func open(_ id: UUID, model: AppModel) {
        if let e = open[id] { e.window.makeKeyAndOrderFront(nil); return }
        guard let n = model.pluginNode(id), let p = n.plugin else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = p.name
        w.isReleasedWhenClosed = false
        let e = Entry(id: id, model: model, window: w, plugin: p)
        w.delegate = e
        func show() {
            if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0 !== w && $0.isVisible }) {
                let f = main.frame
                w.setFrameTopLeftPoint(NSPoint(x: f.midX - w.frame.width / 2, y: f.maxY - 80))
            } else { w.center() }
            w.level = .floating
            w.makeKeyAndOrderFront(nil)
            open[id] = e
            // pass parameter moves from the box's knobs on to the editor; close if the box goes away
            e.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak e] _ in
                MainActor.assumeIsolated {
                    guard let e else { return }
                    guard let m = e.model, let cur = m.pluginNode(e.id)?.plugin, cur === e.plugin else { e.window.close(); return }
                    cur.idle()
                }
            }
        }
        if let v = p as? VST3Plugin {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            w.contentView = view
            var width: Int32 = 0, height: Int32 = 0
            let ctx = Unmanaged.passUnretained(w).toOpaque()
            let ok = pnvst3_open_editor(v.handle, Unmanaged.passUnretained(view).toOpaque(), &width, &height, { ctx, w, h in
                guard let ctx else { return }
                let win = Unmanaged<NSWindow>.fromOpaque(ctx).takeUnretainedValue()
                win.setContentSize(NSSize(width: CGFloat(w), height: CGFloat(h)))
            }, ctx)
            guard ok != 0 else { model.audioError = "\(p.name) has no editor."; return }
            if width > 0, height > 0 { w.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height))) }
            show()
        } else if let a = p as? AUPlugin {
            a.au.requestViewController { vc in
                DispatchQueue.main.async {
                    guard let vc else { model.audioError = "\(p.name) has no editor."; return }
                    var size = vc.preferredContentSize
                    if size.width < 50 || size.height < 50 { size = vc.view.frame.size }
                    if size.width < 50 || size.height < 50 { size = NSSize(width: 480, height: 320) }
                    w.contentViewController = vc
                    w.setContentSize(size)
                    w.styleMask.insert(.resizable)
                    show()
                }
            }
        }
    }
    #else
    static func close(_ id: UUID) {
        if let vc = shown[id] { vc.dismiss(animated: true); shown[id] = nil }
    }
    static var shown: [UUID: UIViewController] = [:]

    static func open(_ id: UUID, model: AppModel) {
        guard let n = model.pluginNode(id), let a = n.plugin as? AUPlugin else { return }
        a.au.requestViewController { vc in
            DispatchQueue.main.async {
                guard let vc else { model.audioError = "\(a.name) has no editor."; return }
                let holder = PluginSheet(id: id, model: model, content: vc, title: a.name)
                let nav = UINavigationController(rootViewController: holder)
                nav.modalPresentationStyle = .formSheet
                var size = vc.preferredContentSize
                if size.width < 50 || size.height < 50 { size = CGSize(width: 640, height: 420) }
                nav.preferredContentSize = CGSize(width: size.width, height: size.height + 50)
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
                while let next = top?.presentedViewController { top = next }
                top?.present(nav, animated: true)
                shown[id] = nav
            }
        }
    }

    final class PluginSheet: UIViewController {
        let id: UUID
        weak var model: AppModel?
        let content: UIViewController
        init(id: UUID, model: AppModel, content: UIViewController, title: String) {
            self.id = id; self.model = model; self.content = content
            super.init(nibName: nil, bundle: nil)
            self.title = title
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            addChild(content)
            content.view.frame = view.bounds
            content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(content.view)
            content.didMove(toParent: self)
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
            model?.storePluginState(id)
            model?.scheduleAutosave()
            PluginWindows.shown[id] = nil
        }
    }
    #endif
}
