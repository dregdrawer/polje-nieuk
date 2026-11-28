import SwiftUI
import AVFoundation
import PoljeNieukCore

// arrange's display: toolbar (▶ ■, rec, loop, cut, dup track, del), bar ruler (drag it for the loop range),
// 1 … 32 track lanes with a header each (mute, solo, arm, volume, meter) and the clips with their waveforms.
// Clips move, trim at their edges, fade at their top corners, split (cut or double-click) and delete
// (the delete key too); overlapping clips crossfade. The grid gets finer as you zoom in.

/// Per-box view: scroll, zoom, selection, tool (not saved with the patch).
struct ArrangeViewState {
    var scroll: Double = 0            // beats at the lane area's left edge
    var ppb: CGFloat = 14             // points per beat
    var selected: Set<Int> = []
    /// a selected track (its header clicked): the strip under the tracks sets its level and pan
    var track: Int? = nil
    var cut = false
    var selecting = false             // the select tool: drag on empty space draws a selection band
    var band: CGRect? = nil
    var version = 0
}

/// A file being dragged over a box: where it would land.
struct ArrangeDropPreview {
    var lane: Int
    var start: Double
    var length: Double
    var name: String
    var path: String?
}

@MainActor enum ArrangeViews {
    static var state: [UUID: ArrangeViewState] = [:]
    static var preview: [UUID: ArrangeDropPreview] = [:]
    /// the box whose clip was clicked last (the delete key deletes that clip)
    static var focused: UUID?
    static func get(_ id: UUID) -> ArrangeViewState { state[id] ?? ArrangeViewState() }
    static func set(_ id: UUID, _ f: (inout ArrangeViewState) -> Void) {
        var s = get(id); f(&s); s.version &+= 1; state[id] = s
    }

    /// Grid lines: the finest of 1/32 notes … bars that stays at least 14 points apart.
    static func gridStep(_ ppb: CGFloat) -> Double {
        for step in [0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32] where CGFloat(step) * ppb >= 14 { return step }
        return 64
    }
    /// The snap (beats) for a box: its snap row, "auto" = the grid.
    static func snap(_ node: PatchNode, _ ppb: CGFloat) -> Double {
        let i = min(max(Int((node.params["snap"] ?? 1).rounded()), 0), ArrangeLayout.snapBeats.count - 1)
        let s = ArrangeLayout.snapBeats[i]
        return s < 0 ? min(gridStep(ppb), 4) : s
    }

    private static var lengths: [String: Double] = [:]
    static func seconds(_ url: URL) -> Double {
        if let s = lengths[url.path] { return s }
        let s = (try? AVAudioFile(forReading: url)).map { Double($0.length) / max($0.fileFormat.sampleRate, 1) } ?? 0
        lengths[url.path] = s
        return s
    }
}

/// Where things are inside arrange's display (`r` = the display, box points).
@MainActor struct ArrangeGeo {
    let r: CGRect
    /// all the tracks; the ones in view; their lane height
    let tracks: Int
    let first: Int, shown: Int
    let laneH: CGFloat
    static let headW: CGFloat = 76
    static let barW: CGFloat = 10
    init(_ r: CGRect, _ node: PatchNode) {
        self.r = r
        tracks = ArrangeLayout.count(node.params["tracks"])
        let v = BoxLayout.arrangeView(node)
        first = v.first; shown = v.shown
        laneH = max((r.height - BoxLayout.arrangeTop - BoxLayout.arrangeBottom) / CGFloat(max(v.shown, 1)), 6)
    }
    var visible: Range<Int> { first..<(first + shown) }
    /// scrollbars: the timeline (under the tracks) and the tracks (right of them)
    var hbar: CGRect { CGRect(x: area.minX, y: area.maxY + 3, width: area.width, height: 9) }
    var vbar: CGRect { CGRect(x: r.maxX - Self.barW + 2, y: area.minY, width: Self.barW - 3, height: area.height) }
    /// clip gain: works on the selected clips
    var gainBar: CGRect { CGRect(x: r.minX + Self.headW, y: r.maxY - 17, width: max((r.width - Self.headW) * 0.55 - 66, 40), height: 13) }
    /// transpose: the selected clips, in semitones
    var pitchBar: CGRect {
        let x = gainBar.maxX + 66 + 58
        return CGRect(x: x, y: gainBar.minY, width: max(r.maxX - x - 50, 30), height: 13)
    }
    var pitchLabel: CGRect { CGRect(x: gainBar.maxX + 66, y: gainBar.minY, width: 56, height: 13) }
    static let pitchRange: Float = 24
    static let trackMin: Float = -24, trackMax: Float = 6
    var gainLabel: CGRect { CGRect(x: r.minX, y: r.maxY - 17, width: Self.headW - 4, height: 13) }
    static let gainMin: Float = -24, gainMax: Float = 12
    var toolbar: CGRect { CGRect(x: r.minX, y: r.minY, width: r.width, height: 18) }
    var ruler: CGRect { CGRect(x: r.minX + Self.headW, y: r.minY + 21, width: r.width - Self.headW, height: 15) }
    var area: CGRect { CGRect(x: r.minX + Self.headW, y: r.minY + BoxLayout.arrangeTop, width: r.width - Self.headW - Self.barW, height: laneH * CGFloat(shown)) }
    func lane(_ k: Int) -> CGRect { CGRect(x: r.minX, y: r.minY + BoxLayout.arrangeTop + CGFloat(k - first) * laneH, width: r.width - Self.barW, height: laneH) }
    func header(_ k: Int) -> CGRect { let l = lane(k); return CGRect(x: l.minX, y: l.minY + 1, width: Self.headW - 4, height: l.height - 2) }
    func button(_ k: Int, _ b: Int) -> CGRect {            // 0 M, 1 S, 2 ●
        let h = header(k)
        return CGRect(x: h.minX + 18 + CGFloat(b) * 17, y: h.minY + 1, width: 15, height: min(12, max(h.height / 2 - 1, 6)))
    }
    func volume(_ k: Int) -> CGRect {
        let h = header(k)
        return CGRect(x: h.minX + 4, y: h.maxY - min(6, h.height / 3) - 1, width: h.width - 10, height: min(6, h.height / 3))
    }
    func laneAt(_ y: CGFloat) -> Int { first + min(max(Int(floor((y - area.minY) / laneH)), 0), shown - 1) }
    func x(_ beat: Double, _ v: ArrangeViewState) -> CGFloat { area.minX + CGFloat(beat - v.scroll) * v.ppb }
    func beat(_ x: CGFloat, _ v: ArrangeViewState) -> Double { v.scroll + Double((x - area.minX) / v.ppb) }
    func clipRect(_ c: ArrangeClip, _ v: ArrangeViewState) -> CGRect {
        let l = lane(c.track)
        return CGRect(x: x(c.start, v), y: l.minY + 1, width: CGFloat(c.length) * v.ppb, height: l.height - 2)
    }
    /// toolbar: ▶ ■ rec loop cut dup del … − +
    var tools: [(String, CGRect)] {
        let t = toolbar
        var out: [(String, CGRect)] = []
        var x = t.minX
        for (name, w) in [("play", 22.0), ("stop", 22.0), ("rec", 44.0), ("loop", 38.0), ("sel", 30.0), ("cut", 30.0), ("dup", 30.0), ("del", 30.0)] as [(String, CGFloat)] {
            out.append((name, CGRect(x: x, y: t.minY, width: w, height: t.height))); x += w + 4
        }
        out.append(("export", CGRect(x: t.maxX - 150, y: t.minY, width: 46, height: t.height)))
        out.append(("in", CGRect(x: t.maxX - 20, y: t.minY, width: 20, height: t.height)))
        out.append(("out", CGRect(x: t.maxX - 44, y: t.minY, width: 20, height: t.height)))
        return out
    }
}

final class ArrangeDisplay: NativeDisplay {
    private var an: ArrangeNode? { dsp as? ArrangeNode }
    private var view: ArrangeViewState { ArrangeViews.get(id) }
    private var trackCount: Int { ArrangeLayout.count(node.params["tracks"]) }

    // MARK: drawing

    override func parts(_ r: CGRect) -> [LivePart] {
        let geo = ArrangeGeo(r, node)
        // the waveforms, grid and ruler: redrawn only when clips, zoom or scroll change (they're the costly part)
        let main = part("arrange", r, sticky: true, signature: { [weak self] in
            guard let self, let n = self.an else { return 0 }
            var h = self.view.version &* 31 &+ ArrangeAudio.shared.generation
            for c in self.work ?? n.clips { LiveSig.mix(&h, Int(c.start * 1000) &+ c.track &* 7 &+ Int(c.length * 1000) &* 13 &+ Int(c.fadeIn * 100) &+ Int(c.fadeOut * 100) &* 3 &+ Int(c.gain * 100) &+ Int(c.transpose)) }
            LiveSig.mix(&h, LiveSig.q(n.readouts[ArrangeLayout.secondsPerBeatSlot], 1000))
            LiveSig.mix(&h, Int(n.loopRange.0 * 100) &+ Int(n.loopRange.1 * 1000))
            if let l = self.loopDrag { LiveSig.mix(&h, Int(l.0 * 100) &+ Int(l.1 * 1000)) }
            if let p = ArrangeViews.preview[self.id] { LiveSig.mix(&h, p.lane &+ Int(p.start * 100) &+ p.name.hashValue) }
            LiveSig.mix(&h, (self.node.params["loop"] ?? 0) > 0.5 ? 1 : 0)
            LiveSig.mix(&h, Int(self.node.params["tracks"] ?? 8) &* 100 &+ Int(self.node.params["vscroll"] ?? 0))
            LiveSig.mix(&h, Int((self.node.dh ?? 0) * 8) &+ Int((self.node.w ?? 0) * 8))
            return LiveSig.styled(h)
        }) { [weak self] g, _ in self?.drawMain(g, geo, chrome: false) }
        // the toolbar, track headers, scrollbars and the strip: cheap, redrawn on any change (levels, buttons …)
        let chrome = part("arrangeChrome", r, signature: { [weak self] in
            guard let self, let n = self.an else { return 0 }
            var h = self.view.version &* 31 &+ self.chromeTick
            LiveSig.mix(&h, LiveSig.patch(self.node))
            for c in self.work ?? n.clips { LiveSig.mix(&h, Int(c.gain * 1000) &+ Int(c.transpose)) }
            for v in self.trackWork ?? n.trackData { LiveSig.mix(&h, Int(v * 1000)) }
            LiveSig.mix(&h, self.model.transport == .play ? 1 : 0)
            LiveSig.mix(&h, n.clips.count)
            return LiveSig.styled(h)
        }) { [weak self] g, _ in self?.drawMain(g, geo, chrome: true) }
        let overlay = part("arrangePlay", r, signature: { [weak self] in
            guard let self, let n = self.an else { return 0 }
            var h = LiveSig.q(n.readouts[ArrangeLayout.posSlot] * Float(self.view.ppb), 1)
            LiveSig.mix(&h, LiveSig.q(n.readouts[ArrangeLayout.recSlot], 2))
            for t in 0..<self.trackCount { LiveSig.mix(&h, LiveSig.q(n.levels[t], 30)) }
            LiveSig.mix(&h, self.view.version)
            LiveSig.mix(&h, self.model.isRunning ? 1 : 0)
            return h
        }) { [weak self] g, _ in self?.drawLive(g, geo) }
        return [main, chrome, overlay]
    }

    private func drawMain(_ g: LiveGC, _ geo: ArrangeGeo, chrome: Bool) {
        guard let n = an else { return }
        let o = CGPoint(x: -geo.r.minX, y: -geo.r.minY)
        func at(_ q: CGRect) -> CGRect { q.offsetBy(dx: o.x, dy: o.y) }
        let v = view
        let spbSec = Double(max(n.readouts[ArrangeLayout.secondsPerBeatSlot], 0.01))
        // toolbar
        let recOn = (node.params["rec"] ?? 0) > 0.5, loopOn = (node.params["loop"] ?? 0) > 0.5
        let playing = model.transport == .play
        for (name, q) in geo.tools where chrome {
            let b = at(q)
            let on = (name == "rec" && recOn) || (name == "loop" && loopOn) || (name == "cut" && v.cut) || (name == "play" && playing)
                || (name == "sel" && v.selecting)
            let enabled = !((name == "dup" || name == "del") && v.selected.isEmpty)
            g.fill(Path(roundedRect: b, cornerRadius: 2), with: .color(on ? Theme.text : Theme.row))
            let col: Color = on ? Theme.inverse : (name == "rec" ? Theme.rec : (enabled ? Theme.text : Theme.faint))
            switch name {
            case "play":
                var p = Path()
                p.move(to: CGPoint(x: b.midX - 3, y: b.midY - 4.5)); p.addLine(to: CGPoint(x: b.midX + 4.5, y: b.midY)); p.addLine(to: CGPoint(x: b.midX - 3, y: b.midY + 4.5))
                p.closeSubpath()
                g.fill(p, with: .color(col))
            case "stop":
                g.fill(Path(CGRect(x: b.midX - 3.5, y: b.midY - 3.5, width: 7, height: 7)), with: .color(col))
            default:
                let label = ["export": "export", "rec": "● rec", "loop": "loop", "sel": "sel", "cut": "cut", "dup": "dup", "del": "del", "in": "+", "out": "−"][name] ?? name
                g.draw(LiveText(label, size: 9, color: col, bold: name == "rec"), at: CGPoint(x: b.midX, y: b.midY))
            }
        }
        // ruler: bars (and beats when there's room), the loop range
        let ru = at(geo.ruler)
        if !chrome { g.fill(Path(ru), with: .color(Theme.row)) }
        let (la, lb) = loopDrag ?? n.loopRange
        let lx0 = max(geo.x(la, v), geo.area.minX), lx1 = min(geo.x(lb, v), geo.area.maxX)
        if lx1 > lx0 && !chrome {
            g.fill(Path(CGRect(x: lx0 + o.x, y: ru.minY, width: lx1 - lx0, height: ru.height)), with: .color(loopOn ? Theme.fill : Theme.faint.opacity(0.5)))
        }
        let step = ArrangeViews.gridStep(v.ppb)
        let barPx = 4 * v.ppb
        let labelEvery = barPx >= 40 ? 1 : (barPx >= 20 ? 2 : (barPx >= 10 ? 4 : (barPx >= 5 ? 8 : 16)))
        let b0 = geo.beat(geo.area.minX, v), b1 = geo.beat(geo.area.maxX, v)
        var minor = Path(), beats = Path(), bars = Path()
        var k = Int(floor(max(b0, 0) / step))
        while Double(k) * step <= b1 {
            let b = Double(k) * step
            let x = geo.x(b, v) + o.x
            k += 1
            guard x >= ru.minX - 1 else { continue }
            let isBar = b.truncatingRemainder(dividingBy: 4) == 0, isBeat = b.truncatingRemainder(dividingBy: 1) == 0
            let line = CGRect(x: x, y: at(geo.area).minY, width: isBar ? 0.75 : 0.5, height: geo.area.height)
            if isBar { bars.addRect(line) } else if isBeat { beats.addRect(line) } else { minor.addRect(line) }
            if chrome { continue }
            if isBar {
                let bar = Int(b / 4)
                if bar % labelEvery == 0 { g.draw(LiveText("\(bar + 1)", size: 8, color: Theme.text), at: CGPoint(x: x + 3, y: ru.midY), anchor: .leading) }
            } else if isBeat && v.ppb >= 36 {
                g.draw(LiveText("\(Int(b / 4) + 1).\(Int(b.truncatingRemainder(dividingBy: 4)) + 1)", size: 7, color: Theme.dim), at: CGPoint(x: x + 2, y: ru.midY), anchor: .leading)
            }
        }
        // lanes
        let tracks = trackWork ?? n.trackData
        for k in geo.visible {
            let l = at(geo.lane(k))
            let h = at(geo.header(k))
            if !chrome {
                if k % 2 == 1 { g.fill(Path(CGRect(x: l.minX + ArrangeGeo.headW, y: l.minY, width: l.width - ArrangeGeo.headW, height: l.height)), with: .color(Theme.shade)) }
                if v.track == k && v.selected.isEmpty {
                    g.fill(Path(CGRect(x: l.minX + ArrangeGeo.headW, y: l.minY, width: l.width - ArrangeGeo.headW, height: l.height)), with: .color(Theme.selected.opacity(0.07)))
                }
                continue
            }
            g.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(Theme.row))
            if v.track == k && v.selected.isEmpty {
                g.stroke(Path(roundedRect: h.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(Theme.selected), lineWidth: 1.5)
            }
            let f = k * ArrangeLayout.trackFields
            let small = geo.laneH < 18
            g.draw(LiveText("\(k + 1)", size: small ? 8 : 10, color: Theme.text, bold: true), at: CGPoint(x: h.minX + 4, y: at(geo.button(k, 0)).midY), anchor: .leading)
            for (b, label) in ["M", "S", "●"].enumerated() {
                let q = at(geo.button(k, b))
                let on = tracks[f + 2 + b] > 0.5
                g.fill(Path(roundedRect: q, cornerRadius: 2), with: .color(on ? (b == 2 ? Theme.rec : Theme.text) : Theme.box))
                g.draw(LiveText(label, size: small ? 6 : 8, color: on ? Theme.inverse : (b == 2 ? Theme.rec : Theme.dim), bold: true), at: CGPoint(x: q.midX, y: q.midY))
            }
            let vq = at(geo.volume(k))
            g.fill(Path(roundedRect: vq, cornerRadius: 1), with: .color(Theme.box))
            g.fill(Path(roundedRect: CGRect(x: vq.minX, y: vq.minY, width: vq.width * CGFloat(min(max(tracks[f] / 2, 0), 1)), height: vq.height), cornerRadius: 1), with: .color(Theme.fill))
            g.fill(Path(CGRect(x: vq.minX + vq.width / 2, y: vq.minY - 1, width: 0.75, height: vq.height + 2)), with: .color(Theme.dim))
        }
        if chrome {
        // scrollbars
        let hb = at(geo.hbar)
        g.fill(Path(roundedRect: hb, cornerRadius: 3), with: .color(Theme.row))
        let total = contentBeats(n, geo, v)
        let tx = hb.minX + hb.width * CGFloat(v.scroll / total)
        let tw = max(hb.width * CGFloat(Double(geo.area.width / v.ppb) / total), 12)
        g.fill(Path(roundedRect: CGRect(x: min(tx, hb.maxX - tw), y: hb.minY + 1, width: tw, height: hb.height - 2), cornerRadius: 3), with: .color(Theme.fill))
        let vb = at(geo.vbar)
        g.fill(Path(roundedRect: vb, cornerRadius: 3), with: .color(Theme.row))
        let th = vb.height * CGFloat(geo.shown) / CGFloat(geo.tracks)
        let ty = vb.minY + vb.height * CGFloat(geo.first) / CGFloat(geo.tracks)
        g.fill(Path(roundedRect: CGRect(x: vb.minX + 1, y: ty, width: vb.width - 2, height: th), cornerRadius: 3),
               with: .color(geo.shown < geo.tracks ? Theme.fill : Theme.faint.opacity(0.4)))
        // clip gain (the selected clips; several move together) — or, with a track selected, its level and pan
        let sel = v.selected.filter { $0 < (work ?? n.clips).count }
        let gq = at(geo.gainBar), gl = at(geo.gainLabel)
        let trackMode = sel.isEmpty && v.track.map { $0 < geo.tracks } == true
        g.draw(LiveText(trackMode ? "track \((v.track ?? 0) + 1) level" : "clip gain", size: 9, color: sel.isEmpty && !trackMode ? Theme.faint : Theme.dim),
               at: CGPoint(x: gl.minX + 2, y: gl.midY), anchor: .leading)
        g.fill(Path(roundedRect: gq, cornerRadius: 2), with: .color(Theme.row))
        if trackMode, let k = v.track {
            let vol = tracks[k * ArrangeLayout.trackFields], pan = tracks[k * ArrangeLayout.trackFields + 1]
            let db = 20 * log10(max(vol, 1e-6))
            let f = vol <= 0.0001 ? 0 : CGFloat((min(max(db, ArrangeGeo.trackMin), ArrangeGeo.trackMax) - ArrangeGeo.trackMin) / (ArrangeGeo.trackMax - ArrangeGeo.trackMin))
            g.fill(Path(roundedRect: CGRect(x: gq.minX, y: gq.minY, width: gq.width * f, height: gq.height), cornerRadius: 2), with: .color(Theme.fill))
            let zero = gq.minX + gq.width * CGFloat(-ArrangeGeo.trackMin / (ArrangeGeo.trackMax - ArrangeGeo.trackMin))
            g.fill(Path(CGRect(x: zero, y: gq.minY - 1, width: 0.75, height: gq.height + 2)), with: .color(Theme.dim))
            g.draw(LiveText(vol <= 0.0001 ? "off" : String(format: "%+.1f dB", db), size: 9, color: Theme.text), at: CGPoint(x: gq.maxX + 6, y: gq.midY), anchor: .leading)
            let pq = at(geo.pitchBar), pl = at(geo.pitchLabel)
            g.draw(LiveText("pan", size: 9, color: Theme.dim), at: CGPoint(x: pl.minX, y: pl.midY), anchor: .leading)
            g.fill(Path(roundedRect: pq, cornerRadius: 2), with: .color(Theme.row))
            let x = pq.midX + pq.width / 2 * CGFloat(pan)
            g.fill(Path(CGRect(x: min(x, pq.midX), y: pq.minY, width: max(abs(x - pq.midX), 1.5), height: pq.height)), with: .color(Theme.fill))
            g.fill(Path(CGRect(x: pq.midX, y: pq.minY - 1, width: 0.75, height: pq.height + 2)), with: .color(Theme.dim))
            g.draw(LiveText(abs(pan) < 0.01 ? "C" : String(format: "%@%.0f", pan < 0 ? "L" : "R", abs(pan) * 100), size: 9, color: Theme.text),
                   at: CGPoint(x: pq.maxX + 6, y: pq.midY), anchor: .leading)
        } else if let first = sel.min() {
            let db = 20 * log10(max((work ?? n.clips)[first].gain, 1e-6))
            let f = CGFloat((min(max(db, ArrangeGeo.gainMin), ArrangeGeo.gainMax) - ArrangeGeo.gainMin) / (ArrangeGeo.gainMax - ArrangeGeo.gainMin))
            g.fill(Path(roundedRect: CGRect(x: gq.minX, y: gq.minY, width: gq.width * f, height: gq.height), cornerRadius: 2), with: .color(Theme.fill))
            let zero = gq.minX + gq.width * CGFloat(-ArrangeGeo.gainMin / (ArrangeGeo.gainMax - ArrangeGeo.gainMin))
            g.fill(Path(CGRect(x: zero, y: gq.minY - 1, width: 0.75, height: gq.height + 2)), with: .color(Theme.dim))
            g.draw(LiveText(String(format: "%+.1f dB", db) + (sel.count > 1 ? "  ×\(sel.count)" : ""), size: 9, color: Theme.text),
                   at: CGPoint(x: gq.maxX + 6, y: gq.midY), anchor: .leading)
            let c = (work ?? n.clips)[first]
            var name = c.file < n.files.count ? (n.files[c.file] as NSString).lastPathComponent : ""
            if sel.count > 1 { name += "  + \(sel.count - 1) more" }
            g.draw(LiveText(fitText(name, size: 8, width: gq.width - 10), size: 8, color: Theme.text), at: CGPoint(x: gq.minX + 5, y: gq.midY), anchor: .leading)
        } else {
            g.draw(LiveText("select a clip", size: 8, color: Theme.faint), at: CGPoint(x: gq.midX, y: gq.midY))
        }
        if !trackMode {
        let pq = at(geo.pitchBar), pl = at(geo.pitchLabel)
        g.draw(LiveText("transpose", size: 9, color: sel.isEmpty ? Theme.faint : Theme.dim), at: CGPoint(x: pl.minX, y: pl.midY), anchor: .leading)
        g.fill(Path(roundedRect: pq, cornerRadius: 2), with: .color(Theme.row))
        let mid0 = pq.midX
        g.fill(Path(CGRect(x: mid0, y: pq.minY - 1, width: 0.75, height: pq.height + 2)), with: .color(Theme.dim))
        if let first = sel.min() {
            let st = (work ?? n.clips)[first].transpose
            let x = pq.minX + pq.width * CGFloat((st + ArrangeGeo.pitchRange) / (2 * ArrangeGeo.pitchRange))
            g.fill(Path(CGRect(x: min(x, mid0), y: pq.minY, width: abs(x - mid0), height: pq.height)), with: .color(Theme.fill))
            g.draw(LiveText(String(format: "%+.0f st", st), size: 9, color: Theme.text), at: CGPoint(x: pq.maxX + 6, y: pq.midY), anchor: .leading)
        }
        }
        return
        }
        g.fill(minor, with: .color(Theme.border.opacity(0.22)))
        g.fill(beats, with: .color(Theme.border.opacity(0.45)))
        g.fill(bars, with: .color(Theme.border.opacity(0.9)))
        // clips
        let clips = work ?? n.clips
        let area = at(geo.area)
        g.clipped(to: Path(area)) { g in
            for (i, c) in clips.enumerated() where geo.visible.contains(c.track) {
                let q = at(geo.clipRect(c, v))
                guard q.maxX >= area.minX, q.minX <= area.maxX else { continue }
                let name = c.file < n.files.count ? (n.files[c.file] as NSString).lastPathComponent : "?"
                let missing = c.file < n.files.count && ArrangeAudio.shared.isMissing(n.files[c.file])
                drawClip(g, q, c, n.audio(for: c), spbSec: spbSec * c.speed, v: v, area: area, selected: v.selected.contains(i),
                         label: missing ? "missing: " + name : name, missing: missing)
            }
            // the loop: a line at each end, down through the tracks
            for b in [la, lb] {
                let x = geo.x(b, v) + o.x
                guard x >= area.minX - 1 && x <= area.maxX + 1 else { continue }
                g.fill(Path(CGRect(x: x - 0.75, y: area.minY, width: 1.5, height: area.height)),
                       with: .color(loopOn ? Theme.selected.opacity(0.8) : Theme.dim.opacity(0.5)))
            }
            if let band = v.band {
                let q = at(band)
                g.fill(Path(q), with: .color(Theme.selected.opacity(0.08)))
                g.stroke(Path(q.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.selected), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            // a file being dragged in: where it would land
            if let p = ArrangeViews.preview[id], geo.visible.contains(p.lane) {
                let l = at(geo.lane(p.lane))
                let q = CGRect(x: geo.x(p.start, v) + o.x, y: l.minY + 1, width: max(CGFloat(p.length) * v.ppb, 30), height: l.height - 2)
                let c = ArrangeClip(track: p.lane, start: p.start, length: p.length, file: 0)
                let audio = p.path.flatMap { ArrangeAudio.shared.audio($0) }
                drawClip(g, q, c, audio, spbSec: spbSec, v: v, area: area, selected: true, label: p.name, missing: false, ghost: true)
            }
        }
    }

    /// One clip: its box, the waveform (from the overview zoomed out, the samples zoomed in), fades, name.
    private func drawClip(_ g: LiveGC, _ q: CGRect, _ c: ArrangeClip, _ a: ClipAudio?, spbSec: Double, v: ArrangeViewState,
                          area: CGRect, selected: Bool, label: String, missing: Bool, ghost: Bool = false) {
        g.fill(Path(roundedRect: q, cornerRadius: 2), with: .color(Theme.fill.opacity(ghost ? 0.35 : 0.55)))
        if let a {
            var path = Path()
            let mid = q.midY, half = q.height / 2 - 2
            let x0 = max(q.minX, area.minX), x1 = min(q.maxX, area.maxX)
            let fpp = spbSec * a.rate / Double(v.ppb)              // file frames per point
            let gain = c.gain
            if fpp < 1.5 {
                // zoomed right in: the samples themselves, as a line
                var x = x0, first = true
                while x <= x1 {
                    let pos = (c.offset + Double(x - q.minX) / Double(v.ppb) * spbSec) * a.rate
                    let k = Int(pos)
                    guard k >= 0, k + 1 < a.frames else { x += 1; continue }
                    let f = Float(pos - Double(k))
                    let s = ((a.left[k] + (a.left[k + 1] - a.left[k]) * f) + (a.right[k] + (a.right[k + 1] - a.right[k]) * f)) * 0.5 * gain
                    let pt = CGPoint(x: x, y: mid - CGFloat(min(max(s, -1), 1)) * half)
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    x += 1
                }
                g.stroke(path, with: .color(Theme.text.opacity(ghost ? 0.5 : 0.85)), lineWidth: 1)
            } else {
                var x = x0
                while x < x1 {
                    let f0 = Int((c.offset + Double(x - q.minX) / Double(v.ppb) * spbSec) * a.rate)
                    let f1 = max(Int((c.offset + Double(x + 1 - q.minX) / Double(v.ppb) * spbSec) * a.rate), f0 + 1)
                    if f0 >= 0 && f0 < a.frames {
                        // the real shape: lowest and highest sample under this point (from the summaries)
                        var (lo, hi) = a.minMax(f0, f1)
                        lo = max(lo * gain, -1); hi = min(hi * gain, 1)
                        let top = mid - CGFloat(hi) * half, bottom = mid - CGFloat(lo) * half
                        path.addRect(CGRect(x: x, y: top, width: 1, height: max(bottom - top, 0.75)))
                    }
                    x += 1
                }
                g.fill(path, with: .color(Theme.text.opacity(ghost ? 0.45 : 0.75)))
            }
        }
        if c.fadeIn > 0 || c.fadeOut > 0 {
            var fp = Path()
            if c.fadeIn > 0 { fp.move(to: CGPoint(x: q.minX, y: q.maxY)); fp.addLine(to: CGPoint(x: q.minX + CGFloat(c.fadeIn) * v.ppb, y: q.minY)) }
            if c.fadeOut > 0 { fp.move(to: CGPoint(x: q.maxX - CGFloat(c.fadeOut) * v.ppb, y: q.minY)); fp.addLine(to: CGPoint(x: q.maxX, y: q.maxY)) }
            g.stroke(fp, with: .color(Theme.text), lineWidth: 1)
        }
        if !ghost {
            for hx in [q.minX + CGFloat(c.fadeIn) * v.ppb, q.maxX - CGFloat(c.fadeOut) * v.ppb] {
                g.fill(Path(CGRect(x: hx - 2.5, y: q.minY, width: 5, height: 5)), with: .color(Theme.text))
            }
        }
        let text = a == nil && !missing ? "loading… " + label : label
        if q.width > 30 && q.height > 10 {
            g.draw(LiveText(fitText(text, size: 8, width: q.width - 10), size: 8, color: missing ? Theme.rec : Theme.text),
                   at: CGPoint(x: max(q.minX, area.minX) + 5, y: q.minY + 6), anchor: .leading)
        }
        g.stroke(Path(roundedRect: q.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
                 with: .color(selected ? Theme.selected : Theme.border), style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: ghost ? [3, 2] : []))
    }

    private func drawLive(_ g: LiveGC, _ geo: ArrangeGeo) {
        guard let n = an else { return }
        let o = CGPoint(x: -geo.r.minX, y: -geo.r.minY)
        let v = view
        let pos = Double(n.readouts[ArrangeLayout.posSlot])
        let area = geo.area.offsetBy(dx: o.x, dy: o.y)
        // the take being recorded: a red block on each armed lane, from where it started to now
        if n.readouts[ArrangeLayout.recSlot] > 0.75 {
            let start = Double(n.readouts[ArrangeLayout.recStartSlot])
            for k in geo.visible where n.trackData[k * ArrangeLayout.trackFields + 4] > 0.5 {
                let l = geo.lane(k).offsetBy(dx: o.x, dy: o.y)
                let x0 = max(geo.x(start, v) + o.x, area.minX), x1 = min(geo.x(pos, v) + o.x, area.maxX)
                if x1 > x0 { g.fill(Path(CGRect(x: x0, y: l.minY + 1, width: x1 - x0, height: l.height - 2)), with: .color(Theme.rec.opacity(0.35))) }
            }
        }
        let px = geo.x(pos, v) + o.x
        if px >= area.minX && px <= area.maxX {
            g.fill(Path(CGRect(x: px - 0.5, y: area.minY - 17, width: 1.5, height: area.height + 17)), with: .color(n.readouts[ArrangeLayout.recSlot] > 0.75 ? Theme.rec : Theme.selected))
        }
        for k in geo.visible {
            let h = geo.header(k).offsetBy(dx: o.x, dy: o.y)
            let m = CGFloat(min(n.levels[k], 1))
            g.fill(Path(CGRect(x: h.maxX - 4, y: h.maxY - h.height * m, width: 2.5, height: h.height * m)),
                   with: .color(m > 0.95 ? Theme.meterRed : Theme.meterGreen))
        }
        let waiting = n.readouts[ArrangeLayout.recSlot] > 0.25 && n.readouts[ArrangeLayout.recSlot] < 0.75
        let bar = Int(floor(max(pos, 0) / 4)) + 1, beat = Int(floor(max(pos, 0).truncatingRemainder(dividingBy: 4))) + 1
        let t = geo.toolbar.offsetBy(dx: o.x, dy: o.y)
        g.draw(LiveText(waiting ? "rec waits for the bar" : "\(bar).\(beat)", size: 9, color: waiting ? Theme.rec : Theme.dim),
               at: CGPoint(x: t.maxX - 156, y: t.midY), anchor: .trailing)
    }

    // MARK: editing

    private enum Op {
        case move(anchor: ArrangeClip, group: [Int], copy: Bool), trimL(Int, ArrangeClip), trimR(Int, ArrangeClip)
        case band(Set<Int>)
        case fadeIn(Int, ArrangeClip), fadeOut(Int, ArrangeClip)
        case loop(Double), pan(Double), volume(Int, Float), gain([Int: Float]), pitch([Int: ArrangeClip]), trackLevel(Int), trackPan(Int), hscroll(Double), vscroll(Int)
    }
    private var op: Op?
    /// bumped for changes only the toolbar / headers / strip show
    private var chromeTick = 0
    private var work: [ArrangeClip]?
    private var trackWork: [Float]?
    private var loopDrag: (Double, Double)?

    /// How long the arrangement is, for the timeline's scrollbar: past the last clip, the loop and the view.
    private func contentBeats(_ n: ArrangeNode, _ geo: ArrangeGeo, _ v: ArrangeViewState) -> Double {
        let lastClip = n.clips.map(\.end).max() ?? 0
        return max(lastClip + 16, n.loopRange.1 + 16, v.scroll + Double(geo.area.width / v.ppb), 64)
    }
    private func scrollTracks(to f: Int, _ geo: ArrangeGeo) {
        let first = min(max(f, 0), max(geo.tracks - geo.shown, 0))
        model.setViewParam(id, "vscroll", Float(first))
    }
    private var spbSec: Double { Double(max(an?.readouts[ArrangeLayout.secondsPerBeatSlot] ?? 0.5, 0.01)) }
    /// seconds of the clip's file one beat plays (faster when transposed up)
    private func cs(_ c: ArrangeClip) -> Double { spbSec * c.speed }
    private func snapped(_ b: Double, _ info: PointerInfo) -> Double {
        let g = ArrangeViews.snap(node, view.ppb)
        return g > 0 && !info.command ? (b / g).rounded() * g : b
    }
    /// Part of a clip, from beat `from` to `to` (nil when nothing of it is in there).
    private func crop(_ c: ArrangeClip, _ from: Double, _ to: Double) -> ArrangeClip? {
        let s = max(c.start, from), e = min(c.end, to)
        guard e - s > 0.001 else { return nil }
        var m = c
        m.offset = c.offset + (s - c.start) * cs(c)
        m.start = s; m.length = e - s
        if s > c.start { m.fadeIn = 0 }
        if e < c.end { m.fadeOut = 0 }
        m.fadeIn = min(m.fadeIn, m.length); m.fadeOut = min(m.fadeOut, m.length - m.fadeIn)
        return m
    }
    /// Clip `i` (just trimmed) wins: whatever it now covers on its track is cut out of the other clips there.
    private func carve(_ clips: [ArrangeClip], keeping i: Int) -> [ArrangeClip] {
        let m = clips[i]
        var out: [ArrangeClip] = []
        for (k, c) in clips.enumerated() {
            if k == i || c.track != m.track || c.end <= m.start || c.start >= m.end { out.append(c); continue }
            if let before = crop(c, -.infinity, m.start) { out.append(before) }
            if let after = crop(c, m.end, .infinity) { out.append(after) }
        }
        // the trimmed clip keeps its place in the list (it stays selected)
        let j = out.firstIndex { $0 == m } ?? 0
        return j == min(i, out.count - 1) ? out : { var o = out; let x = o.remove(at: j); o.insert(x, at: min(i, o.count)); return o }()
    }
    private func commit(_ clips: [ArrangeClip]) { model.setData(id, ArrangeLayout.clipsKey, ArrangeClip.encode(clips)) }
    private func select(_ s: Set<Int>) {
        ArrangeViews.set(id) { $0.selected = s; if !s.isEmpty { $0.track = nil } }
        ArrangeViews.focused = s.isEmpty ? nil : id
    }
    private func redraw() { ArrangeViews.set(id) { _ in } }

    /// The clip under a point, and which part of it: 0 body, 1 left edge, 2 right edge, 3 fade-in handle, 4 fade-out handle.
    private func hit(_ p: CGPoint, _ geo: ArrangeGeo) -> (Int, Int)? {
        guard let n = an, geo.area.contains(p) else { return nil }
        let v = view
        for (i, c) in n.clips.enumerated().reversed() where geo.visible.contains(c.track) {
            let q = geo.clipRect(c, v)
            guard q.insetBy(dx: -3, dy: -3).contains(p) else { continue }
            let fi = q.minX + CGFloat(c.fadeIn) * v.ppb, fo = q.maxX - CGFloat(c.fadeOut) * v.ppb
            if p.y < q.minY + 10 && abs(p.x - fi) < 8 { return (i, 3) }
            if p.y < q.minY + 10 && abs(p.x - fo) < 8 { return (i, 4) }
            let edge = min(6, q.width / 4)
            if p.x < q.minX + edge { return (i, 1) }
            if p.x > q.maxX - edge { return (i, 2) }
            return (i, 0)
        }
        return nil
    }

    override func press(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) -> Bool {
        let geo = ArrangeGeo(r, node)
        guard let n = an else { return false }
        op = nil; work = nil; trackWork = nil; loopDrag = nil
        if geo.toolbar.contains(p) { return true }
        if geo.hbar.insetBy(dx: 0, dy: -2).contains(p) {
            // the timeline's scrollbar: grab the thumb, or click beside it to jump there
            let total = contentBeats(n, geo, view), visible = Double(geo.area.width / view.ppb)
            let thumbX = geo.hbar.minX + geo.hbar.width * CGFloat(view.scroll / total)
            let thumbW = max(geo.hbar.width * CGFloat(visible / total), 12)
            if p.x < thumbX || p.x > thumbX + thumbW {
                let s = max(Double((p.x - geo.hbar.minX) / geo.hbar.width) * total - visible / 2, 0)
                ArrangeViews.set(id) { $0.scroll = s }
            }
            op = .hscroll(view.scroll)
            return true
        }
        if geo.vbar.insetBy(dx: -2, dy: 0).contains(p) {
            let thumbY = geo.vbar.minY + geo.vbar.height * CGFloat(geo.first) / CGFloat(geo.tracks)
            let thumbH = geo.vbar.height * CGFloat(geo.shown) / CGFloat(geo.tracks)
            if p.y < thumbY || p.y > thumbY + thumbH {
                scrollTracks(to: Int((p.y - geo.vbar.minY) / geo.vbar.height * CGFloat(geo.tracks)) - geo.shown / 2, geo)
            }
            op = .vscroll(Int((node.params["vscroll"] ?? 0).rounded()))
            return true
        }
        if let k = view.track, view.selected.isEmpty, k < geo.tracks {
            if geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) { op = .trackLevel(k); return true }
            if geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) { op = .trackPan(k); return true }
        }
        if geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) {
            let sel = view.selected.filter { $0 < n.clips.count }
            guard !sel.isEmpty else { return true }
            op = .gain(Dictionary(uniqueKeysWithValues: sel.map { ($0, n.clips[$0].gain) }))
            return true
        }
        if geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) {
            let sel = view.selected.filter { $0 < n.clips.count }
            guard !sel.isEmpty else { return true }
            op = .pitch(Dictionary(uniqueKeysWithValues: sel.map { ($0, n.clips[$0]) }))
            return true
        }
        if geo.ruler.contains(p) { op = .loop(snapped(geo.beat(p.x, view), info)); return true }
        for k in geo.visible where geo.header(k).contains(p) {
            if geo.volume(k).insetBy(dx: 0, dy: -3).contains(p) { op = .volume(k, n.trackData[k * ArrangeLayout.trackFields]); return true }
            if !(0..<3).contains(where: { geo.button(k, $0).contains(p) }) {
                // the header itself: select the track (its level and pan go on the strip below)
                ArrangeViews.set(id) { $0.track = k; $0.selected = [] }
                ArrangeViews.focused = nil
            }
            return true
        }
        guard geo.area.contains(p) else { return false }
        if let (i, zone) = hit(p, geo) {
            let c = n.clips[i]
            if info.shift {                                    // shift: add it to / take it out of the selection
                var s = view.selected
                if s.contains(i) { s.remove(i) } else { s.insert(i) }
                select(s)
                op = .band(s)
                return true
            }
            if !view.selected.contains(i) { select([i]) }
            if view.cut || info.clickCount == 2 { select([i]); return true }          // split on release
            switch zone {
            case 1: select([i]); op = .trimL(i, c)
            case 2: select([i]); op = .trimR(i, c)
            case 3: select([i]); op = .fadeIn(i, c)
            case 4: select([i]); op = .fadeOut(i, c)
            default: op = .move(anchor: c, group: Array(view.selected).sorted(), copy: info.option)    // the whole selection moves
            }
        } else if view.selecting || info.shift {
            let keep = info.shift ? view.selected : []
            select(keep)
            op = .band(keep)
        } else {
            select([])
            op = .pan(view.scroll)
        }
        return true
    }

    override func drag(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        let geo = ArrangeGeo(r, node)
        guard let n = an, let op else { return }
        let v = view
        let d = Double((p.x - info.start.x) / v.ppb)
        var clips = n.clips
        switch op {
        case .move(let anchor, let group, let copy):
            // the clip under the pointer snaps; the others keep their distance to it
            var dBeat = max(snapped(anchor.start + d, info), 0) - anchor.start
            var dTrack = geo.laneAt(p.y) - anchor.track
            let members = group.filter { $0 < clips.count }
            if let lo = members.map({ n.clips[$0].track }).min(), let hi = members.map({ n.clips[$0].track }).max() {
                dTrack = min(max(dTrack, -lo), geo.tracks - 1 - hi)
            }
            if let earliest = members.map({ n.clips[$0].start }).min() { dBeat = max(dBeat, -earliest) }
            for i in members {
                var m = n.clips[i]
                m.start += dBeat; m.track += dTrack
                if copy { clips.append(m) } else { clips[i] = m }
            }
            work = clips
        case .band(let keep):
            let band = CGRect(x: min(info.start.x, p.x), y: min(info.start.y, p.y), width: abs(p.x - info.start.x), height: abs(p.y - info.start.y))
            var s = keep
            for (i, c) in n.clips.enumerated() where geo.visible.contains(c.track) && geo.clipRect(c, v).intersects(band) { s.insert(i) }
            ArrangeViews.set(id) { $0.band = band; $0.selected = s }
            ArrangeViews.focused = s.isEmpty ? nil : id
            return
        case .trimL(let i, let c):
            let earliest = c.start - c.offset / cs(c)
            let s = min(max(snapped(c.start + d, info), earliest, 0), c.end - 1.0 / 64)
            var m = c
            m.offset = max(c.offset + (s - c.start) * cs(c), 0)
            m.start = s; m.length = c.end - s
            m.fadeIn = min(m.fadeIn, m.length)
            clips[i] = m; work = carve(clips, keeping: i)
        case .trimR(let i, let c):
            var latest = Double.infinity
            if let a = n.audio(for: c) { latest = c.start + (a.seconds - c.offset) / cs(c) }
            let e = max(min(snapped(c.end + d, info), latest), c.start + 1.0 / 64)
            var m = c
            m.length = e - c.start
            m.fadeOut = min(m.fadeOut, m.length)
            clips[i] = m; work = carve(clips, keeping: i)
        case .fadeIn(let i, let c):
            var m = c
            m.fadeIn = min(max(Double(p.x - geo.x(c.start, v)) / Double(v.ppb), 0), c.length - c.fadeOut)
            clips[i] = m; work = clips
        case .fadeOut(let i, let c):
            var m = c
            m.fadeOut = min(max(Double(geo.x(c.end, v) - p.x) / Double(v.ppb), 0), c.length - c.fadeIn)
            clips[i] = m; work = clips
        case .loop(let a):
            let b = snapped(geo.beat(p.x, v), info)
            loopDrag = (max(min(a, b), 0), max(max(a, b), 0))
        case .pan(let s):
            ArrangeViews.set(id) { $0.scroll = max(s - d, 0) }
            return
        case .gain(let start):
            // the first selected clip follows the pointer; the others move by the same number of dB
            guard let first = start.keys.min(), let g0 = start[first] else { return }
            let q = geo.gainBar
            let f = Float(min(max((p.x - q.minX) / q.width, 0), 1))
            let db = ArrangeGeo.gainMin + f * (ArrangeGeo.gainMax - ArrangeGeo.gainMin)
            let delta = db - 20 * log10(max(g0, 1e-6))
            for (i, g) in start where i < clips.count {
                clips[i].gain = min(max(g * powf(10, delta / 20), powf(10, ArrangeGeo.gainMin / 20)), powf(10, ArrangeGeo.gainMax / 20))
            }
            work = clips
        case .pitch(let start):
            // whole semitones; the clips keep playing the same stretch of audio (so they get shorter going up)
            guard let first = start.keys.min(), let c0 = start[first] else { return }
            let q = geo.pitchBar
            let st = (Float(min(max((p.x - q.minX) / q.width, 0), 1)) * 2 - 1) * ArrangeGeo.pitchRange
            let delta = st.rounded() - c0.transpose
            for (i, c) in start where i < clips.count {
                var m = c
                m.transpose = min(max(c.transpose + delta, -ArrangeGeo.pitchRange), ArrangeGeo.pitchRange)
                let k = c.speed / m.speed
                m.length = c.length * k; m.fadeIn = c.fadeIn * k; m.fadeOut = c.fadeOut * k
                clips[i] = m
            }
            work = clips
        case .hscroll(let s0):
            let total = contentBeats(n, geo, v)
            ArrangeViews.set(id) { $0.scroll = max(s0 + Double((p.x - info.start.x) / geo.hbar.width) * total, 0) }
            return
        case .vscroll(let f0):
            let rows = Int(((p.y - info.start.y) / geo.vbar.height * CGFloat(geo.tracks)).rounded())
            scrollTracks(to: f0 + rows, geo)
            return
        case .trackLevel(let k):
            var t = n.trackData
            let q = geo.gainBar
            let f = Float(min(max((p.x - q.minX) / q.width, 0), 1))
            t[k * ArrangeLayout.trackFields] = f < 0.01 ? 0 : min(powf(10, (ArrangeGeo.trackMin + f * (ArrangeGeo.trackMax - ArrangeGeo.trackMin)) / 20), 2)
            trackWork = t
            n.setData(ArrangeLayout.tracksKey, t)
            chromeTick &+= 1
            return                                          // only the strip / header change: the waveforms stay
        case .trackPan(let k):
            var t = n.trackData
            let q = geo.pitchBar
            var v = Float(min(max((p.x - q.minX) / q.width, 0), 1)) * 2 - 1
            if abs(v) < 0.04 { v = 0 }                        // easy to find the middle
            t[k * ArrangeLayout.trackFields + 1] = v
            trackWork = t
            n.setData(ArrangeLayout.tracksKey, t)
            chromeTick &+= 1
            return
        case .volume(let k, _):
            var t = n.trackData
            let q = geo.volume(k)
            t[k * ArrangeLayout.trackFields] = Float(min(max((p.x - q.minX) / q.width, 0), 1)) * 2
            trackWork = t
            n.setData(ArrangeLayout.tracksKey, t)          // heard while dragging; saved on release
            chromeTick &+= 1
            return
        }
        redraw()
    }

    override func release(_ p: CGPoint, _ r: CGRect, _ info: PointerInfo) {
        let geo = ArrangeGeo(r, node)
        defer {
            let hadBand = view.band != nil
            op = nil; work = nil; trackWork = nil; loopDrag = nil
            if hadBand { ArrangeViews.set(id) { $0.band = nil } } else { chromeTick &+= 1 }
        }
        guard let n = an else { return }
        if !info.moved {
            if geo.toolbar.contains(p) { tool(geo, p); return }
            if geo.ruler.contains(p) && info.clickCount == 2 { duplicateLoop(); return }
            if let k = view.track, view.selected.isEmpty, k < geo.tracks,
               geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) || geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) {
                let level = geo.gainBar.insetBy(dx: 0, dy: -3).contains(p)
                if info.clickCount == 2 {                  // back to 0 dB / the middle
                    var t = n.trackData
                    t[k * ArrangeLayout.trackFields + (level ? 0 : 1)] = level ? 1 : 0
                    model.setData(id, ArrangeLayout.tracksKey, t)
                } else {
                    drag(p, r, info)                       // a click jumps there
                    if let t = trackWork { model.setData(id, ArrangeLayout.tracksKey, t) }
                }
                return
            }
            if geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) {
                if info.clickCount == 2 {                  // back to 0
                    var clips = n.clips
                    for i in view.selected where i < clips.count {
                        let k = clips[i].speed
                        clips[i].transpose = 0; clips[i].length *= k; clips[i].fadeIn *= k; clips[i].fadeOut *= k
                    }
                    if !view.selected.isEmpty { commit(clips) }
                } else if case .pitch = op { drag(p, r, info); if let w = work { commit(w) } }
                return
            }
            if geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) {
                if info.clickCount == 2 {                  // back to 0 dB
                    var clips = n.clips
                    for i in view.selected where i < clips.count { clips[i].gain = 1 }
                    if !view.selected.isEmpty { commit(clips) }
                } else if case .gain = op { drag(p, r, info); if let w = work { commit(w) } }   // a click jumps there
                return
            }
            for k in geo.visible {
                for b in 0..<3 where geo.button(k, b).contains(p) {
                    var t = n.trackData
                    let f = k * ArrangeLayout.trackFields + 2 + b
                    t[f] = t[f] > 0.5 ? 0 : 1
                    model.setData(id, ArrangeLayout.tracksKey, t)
                    return
                }
                if geo.volume(k).insetBy(dx: 0, dy: -3).contains(p) && info.clickCount == 2 {
                    var t = n.trackData; t[k * ArrangeLayout.trackFields] = 1
                    model.setData(id, ArrangeLayout.tracksKey, t)
                    return
                }
            }
            if let (i, _) = hit(p, geo), view.cut || info.clickCount == 2, !info.shift { split(i, at: snapped(geo.beat(p.x, view), info)); return }
            return
        }
        if let w = work {
            commit(w)
            if case .move(_, let group, true) = op { select(Set((w.count - group.count)..<w.count)) }
        }
        if let t = trackWork { model.setData(id, ArrangeLayout.tracksKey, t) }
        // the ruler sets where the loop goes; the loop button alone switches looping on and off
        if let (a, b) = loopDrag, b - a > 0.05 { model.setData(id, ArrangeLayout.loopKey, [Float(a), Float(b)]) }
    }

    private func tool(_ geo: ArrangeGeo, _ p: CGPoint) {
        guard let (name, _) = geo.tools.first(where: { $0.1.contains(p) }) else { return }
        switch name {
        case "play": model.setTransport(.play)
        case "stop": model.setTransport(.stop)
        case "rec": setParam("rec", (node.params["rec"] ?? 0) > 0.5 ? 0 : 1)
        case "loop": setParam("loop", (node.params["loop"] ?? 0) > 0.5 ? 0 : 1)
        case "cut": ArrangeViews.set(id) { $0.cut.toggle(); if $0.cut { $0.selecting = false } }
        case "sel": ArrangeViews.set(id) { $0.selecting.toggle(); if $0.selecting { $0.cut = false } }
        case "dup": duplicateSelection()
        case "del": deleteSelection()
        case "export": export()
        case "in", "out":
            let f: CGFloat = name == "in" ? 1.5 : 1 / 1.5
            if (node.params["loop"] ?? 0) > 0.5, let n = an {
                // looping: zoom onto the loop (its middle in the middle of the view)
                let mid = (n.loopRange.0 + n.loopRange.1) / 2
                ArrangeViews.set(id) { s in
                    s.ppb = min(max(s.ppb * f, 0.5), 2000)
                    s.scroll = max(mid - Double(geo.area.width / 2 / s.ppb), 0)
                }
            } else {
                zoom(f, geo)
            }
        default: break
        }
    }

    /// Export the loop range: the mix, or (ticked) every track with clips there as its own file.
    private func export() {
        guard let n = an else { return }
        let (a, b) = n.loopRange
        let rate = n.sampleRate, sec = spbSec
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export the loop"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "arrangement bars \(Int(a / 4) + 1)-\(Int(ceil(b / 4))).wav"
        let stems = NSButton(checkboxWithTitle: "export as separate tracks (stems)", target: nil, action: nil)
        stems.state = UserDefaults.standard.bool(forKey: "arrangeStems") ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        stems.frame = NSRect(x: 16, y: 8, width: 300, height: 20)
        box.addSubview(stems)
        panel.accessoryView = box
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let asStems = stems.state == .on
        UserDefaults.standard.set(asStems, forKey: "arrangeStems")
        Self.write(n, a, b, rate, sec, to: url, stems: asStems)
        NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)])
        #else
        let dir = Recordings.directory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        Self.write(n, a, b, rate, sec, to: dir.appendingPathComponent("arrangement \(f.string(from: Date())).wav"), stems: true)
        model.audioError = "Exported the loop (mix and tracks) to Files › polje nieuk Recordings › Exports."
        #endif
    }
    private static func write(_ n: ArrangeNode, _ a: Double, _ b: Double, _ rate: Double, _ sec: Double, to url: URL, stems: Bool) {
        let r = n.render(from: a, to: b, rate: rate, secondsPerBeat: sec)
        if stems {
            let base = url.deletingPathExtension().lastPathComponent, dir = url.deletingLastPathComponent()
            for (t, audio) in r.tracks.sorted(by: { $0.key < $1.key }) {
                try? AudioFiles.write(audio, sampleRate: rate, to: dir.appendingPathComponent("\(base) - track \(t + 1).wav"))
            }
        }
        try? AudioFiles.write(r.mix, sampleRate: rate, to: url)
    }

    func zoom(_ f: CGFloat, _ geo: ArrangeGeo, around x: CGFloat? = nil) {
        let cx = x ?? geo.area.midX
        let b = geo.beat(cx, view)
        ArrangeViews.set(id) { s in
            s.ppb = min(max(s.ppb * f, 0.5), 2000)
            s.scroll = max(b - Double((cx - geo.area.minX) / s.ppb), 0)
        }
    }

    private func split(_ i: Int, at b: Double) {
        guard let n = an, i < n.clips.count else { return }
        let c = n.clips[i]
        guard b > c.start + 0.001 && b < c.end - 0.001 else { return }
        var left = c, right = c
        left.length = b - c.start; left.fadeOut = 0
        right.start = b; right.length = c.end - b; right.offset = c.offset + (b - c.start) * cs(c); right.fadeIn = 0
        var clips = n.clips
        clips[i] = left; clips.append(right)
        commit(clips)
        select([clips.count - 1])
    }
    /// Copies of clips right after them (a group keeps its shape, after its last end).
    private func duplicateNext(_ idx: [Int]) {
        guard let n = an else { return }
        let members = idx.filter { $0 < n.clips.count }
        guard let lo = members.map({ n.clips[$0].start }).min(), let hi = members.map({ n.clips[$0].end }).max() else { return }
        let copies = members.map { i -> ArrangeClip in var c = n.clips[i]; c.start += hi - lo; return c }
        commit(n.clips + copies)
        select(Set(n.clips.count..<(n.clips.count + copies.count)))
    }
    /// dup: one clip shorter than 8 seconds (or several): copies right after; one longer clip: a copy on a new track below.
    private func duplicateSelection() {
        guard let n = an else { return }
        let sel = view.selected.filter { $0 < n.clips.count }.sorted()
        guard !sel.isEmpty else { return }
        if sel.count == 1 && n.clips[sel[0]].length * spbSec >= 8 {
            model.arrangeInsertTrack(id, after: n.clips[sel[0]].track, copy: true, only: sel)
            select([])
        } else {
            duplicateNext(sel)
        }
    }
    private func deleteSelection() {
        guard let n = an else { return }
        let sel = view.selected
        commit(n.clips.enumerated().filter { !sel.contains($0.offset) }.map(\.element))
        select([])
    }
    /// Double-click on the ruler: everything inside the loop range is copied right after it, and what was after it
    /// moves that much later (clips across the edges are split there).
    private func duplicateLoop() {
        guard let n = an else { return }
        let (a, b) = n.loopRange
        let len = b - a
        guard len > 0.01 else { return }
        var out: [ArrangeClip] = [], copies: [ArrangeClip] = []
        for c in n.clips {
            // what stays: the part before b; what's after b moves on by the length of the loop
            if let before = crop(c, -.infinity, b) { out.append(before) }
            if var after = crop(c, b, .infinity) { after.start += len; out.append(after) }
            if var inside = crop(c, a, b) { inside.start += len; copies.append(inside) }
        }
        commit(out + copies)
        select(Set(out.count..<(out.count + copies.count)))
    }
    private func gain(_ i: Int, _ db: Float?) {
        guard let n = an, i < n.clips.count else { return }
        var clips = n.clips
        clips[i].gain = db.map { min(max(clips[i].gain * powf(10, $0 / 20), 0.0625), 4) } ?? 1
        commit(clips)
    }

    override func menu(_ p: CGPoint, _ r: CGRect) -> [MenuItem]? {
        let geo = ArrangeGeo(r, node)
        guard let n = an else { return nil }
        let m = model, nid = id
        for k in geo.visible where geo.header(k).contains(p) {
            return [.section("track \(k + 1)"),
                    MenuItem(title: "duplicate track", enabled: geo.tracks < ArrangeLayout.tracks) { m.arrangeInsertTrack(nid, after: k, copy: true) },
                    MenuItem(title: "insert an empty track below", enabled: geo.tracks < ArrangeLayout.tracks) { m.arrangeInsertTrack(nid, after: k, copy: false) },
                    MenuItem(title: "clear its clips") { [weak self] in
                        guard let self, let n = self.an else { return }
                        self.commit(n.clips.filter { $0.track != k }); self.select([])
                    },
                    MenuItem(title: "delete track", enabled: geo.tracks > 1) { m.arrangeDeleteTrack(nid, k) }]
        }
        if let (i, _) = hit(p, geo) {
            if !view.selected.contains(i) { select([i]) }
            let b = geo.beat(p.x, view)
            let c = n.clips[i]
            let db = 20 * log10(max(c.gain, 1e-6))
            return [.section(String(format: "clip  %+.1f dB", db)),
                    MenuItem(title: "split here") { [weak self] in self?.split(i, at: b) },
                    MenuItem(title: "duplicate (next to it)") { [weak self] in guard let self else { return }; self.duplicateNext(Array(self.view.selected)) },
                    MenuItem(title: "duplicate onto a new track") { m.arrangeInsertTrack(nid, after: c.track, copy: true, only: [i]) },
                    MenuItem(title: "duplicate the whole track") { m.arrangeInsertTrack(nid, after: c.track, copy: true) },
                    MenuItem(title: "delete") { [weak self] in self?.deleteSelection() },
                    .divider,
                    MenuItem(title: "louder (+1.5 dB)") { [weak self] in self?.gain(i, 1.5) },
                    MenuItem(title: "quieter (−1.5 dB)") { [weak self] in self?.gain(i, -1.5) },
                    MenuItem(title: "gain 0 dB") { [weak self] in self?.gain(i, nil) },
                    MenuItem(title: "remove fades") { [weak self] in
                        guard let self, let n = self.an, i < n.clips.count else { return }
                        var clips = n.clips; clips[i].fadeIn = 0; clips[i].fadeOut = 0
                        self.commit(clips)
                    }]
        }
        if geo.area.contains(p) {
            return [MenuItem(title: "zoom in") { [weak self] in self?.zoom(1.5, geo, around: p.x) },
                    MenuItem(title: "zoom out") { [weak self] in self?.zoom(1 / 1.5, geo, around: p.x) },
                    MenuItem(title: "back to the start") { [weak self] in guard let self else { return }; ArrangeViews.set(self.id) { $0.scroll = 0 } }]
        }
        return nil
    }

    override func help(_ p: CGPoint, _ r: CGRect) -> (String, String)? {
        let geo = ArrangeGeo(r, node)
        if let (name, _) = geo.tools.first(where: { $0.1.contains(p) }) {
            return [
                "play": ("play", "Starts the patch's transport (every clock, sequencer and arrange box). With loop on it starts at the loop."),
                "stop": ("stop", "Stops the transport; the next play starts from the beginning (or the loop's start)."),
                "rec": ("record armed tracks", "Records every armed track (● in its header) to its own file, from the next bar (or straight away when you press play). When you stop, each take lands as a clip where it was played."),
                "loop": ("loop", "Switches looping on and off. Drag on the bar ruler to set where the loop is."),
                "sel": ("select tool", "Drag on empty space to draw a box round clips and select them all. Shift-click adds or removes one. Move, duplicate (dup or ⌥-drag) and delete them together."),
                "cut": ("cut tool", "Click a clip to split it there (on the snap grid; hold ⌘ for anywhere). A double-click splits too, without the tool."),
                "dup": ("duplicate", "A clip shorter than 8 seconds (or several clips): a copy right after it. A longer clip: a copy on a new track below. Right-click a clip or a track header for the other kinds."),
                "del": ("delete", "Deletes the selected clips (the delete key does too)."),
                "export": ("export", "Saves the loop range as a WAV file (you choose where). Tick 'export as separate tracks' for stems: one file per track with clips in the loop. Only the clips are rendered, not what comes into the inlets."),
                "in": ("zoom in", "Zooms the timeline in (⌘ or ⌥ + scroll wheel too). The grid gets finer as you zoom."),
                "out": ("zoom out", "Zooms the timeline out."),
            ][name]
        }
        if geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) || geo.gainLabel.contains(p) {
            return ("clip gain", "The level of the selected clips, −24 … +12 dB (several selected clips all move by the same amount). Double-click: back to 0 dB. The waveform shows the change.")
        }
        if let k = view.track, view.selected.isEmpty, k < geo.tracks {
            if geo.gainBar.insetBy(dx: 0, dy: -3).contains(p) || geo.gainLabel.contains(p) {
                return ("track level", "Track \(k + 1)'s level, −24 … +6 dB (all the way left: off). Double-click: back to 0 dB. Click a clip to get clip gain here again.")
            }
            if geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) || geo.pitchLabel.contains(p) {
                return ("pan", "Track \(k + 1)'s place left – right. Double-click: back to the middle.")
            }
        }
        if geo.pitchBar.insetBy(dx: 0, dy: -3).contains(p) || geo.pitchLabel.contains(p) {
            return ("transpose", "Re-pitches the selected clips, −24 … +24 semitones, like changing a record's speed: up is higher and faster (the clip gets shorter so it plays the same audio), down is lower and slower. Double-click: back to 0.")
        }
        if geo.hbar.insetBy(dx: 0, dy: -2).contains(p) {
            return ("timeline scrollbar", "Drag it to move along the arrangement; click beside it to jump there. The scroll wheel zooms, a sideways swipe scrolls too.")
        }
        if geo.vbar.insetBy(dx: -2, dy: 0).contains(p) {
            return ("tracks scrollbar", "With more tracks than fit, drag it to see the others (make the box taller to see more at once). Their inlets and outlets move with them; cables to tracks out of view wait at the top or bottom edge.")
        }
        if geo.ruler.contains(p) {
            return ("bar ruler", "Drag along it to set the loop (the two lines through the tracks show it). Double-click it to duplicate everything inside the loop: the copy goes right after the loop and what came after moves later to make room.")
        }
        for k in geo.visible where geo.header(k).contains(p) {
            if geo.button(k, 0).contains(p) { return ("mute", "Silences track \(k + 1).") }
            if geo.button(k, 1).contains(p) { return ("solo", "Plays only the soloed tracks.") }
            if geo.button(k, 2).contains(p) { return ("arm", "Track \(k + 1) records its inlets (\(k + 1) L / R) when you press ● rec.") }
            if geo.volume(k).insetBy(dx: 0, dy: -3).contains(p) { return ("volume", "Drag for track \(k + 1)'s volume (the middle mark is unity). Double-click: back to unity.") }
            return ("track \(k + 1)", "Click to select the track: its level and pan show on the strip under the tracks. Its inlets on the left are heard through the track and are what it records; its outlets on the right carry the track alone. Right-click: duplicate, insert, clear or delete the track. The green bar is its level.")
        }
        if let (_, zone) = hit(p, geo) {
            switch zone {
            case 1: return ("clip start", "Drag to trim the clip's start (the audio stays where it is in time).")
            case 2: return ("clip end", "Drag to trim the clip's end.")
            case 3: return ("fade in", "Drag the little square right for a fade in.")
            case 4: return ("fade out", "Drag the little square left for a fade out.")
            default: return ("clip", "Drag to move (to another track too; ⌥ copies, ⌘ ignores the snap). Double-click to split. Overlapping clips on a track crossfade. Right-click for gain, fades, duplicate, delete.")
            }
        }
        if geo.area.contains(p) {
            return ("tracks", "Drop audio files here (from Finder, the browser or rec's list). Drag empty space to scroll (with the select tool: to select). The scroll wheel scrolls; with ⌘ or ⌥ it zooms.")
        }
        return nil
    }

    /// Mouse wheel / trackpad over the lanes: up / down zooms around the pointer, sideways scrolls
    /// (⌘ or ⌥ + wheel: scrolls too).
    func scroll(dx: CGFloat, dy: CGFloat, zoom z: Bool, at p: CGPoint, _ r: CGRect) {
        let geo = ArrangeGeo(r, node)
        if !z && abs(dy) >= abs(dx) {
            zoom(exp(min(max(dy, -60), 60) * 0.01), geo, around: p.x)
            return
        }
        let d = abs(dx) > abs(dy) ? -dx : -dy
        ArrangeViews.set(id) { $0.scroll = max($0.scroll + Double(d / $0.ppb), 0) }
    }
}

// MARK: - the model's side

extension AppModel {
    /// Where a dropped file would go on an arrange box: lane and (snapped) beat.
    private func arrangeSpot(_ id: UUID, at p: CGPoint, display r: CGRect) -> (lane: Int, start: Double, spbSec: Double)? {
        guard let i = patch.index(of: id), let n = host.node(id) as? ArrangeNode else { return nil }
        let node = patch.nodes[i]
        let geo = ArrangeGeo(r, node), v = ArrangeViews.get(id)
        let snap = ArrangeViews.snap(node, v.ppb)
        var start = max(geo.beat(p.x, v), 0)
        if snap > 0 { start = (start / snap).rounded(.down) * snap }
        return (geo.laneAt(p.y), start, Double(max(n.readouts[ArrangeLayout.secondsPerBeatSlot], 0.01)))
    }

    /// A file dragged over arrange: show where it would land (nil point: take the preview away).
    func arrangePreview(_ id: UUID, _ url: URL?, at p: CGPoint?, display r: CGRect) {
        guard let p, let spot = arrangeSpot(id, at: p, display: r) else {
            if ArrangeViews.preview.removeValue(forKey: id) != nil { ArrangeViews.set(id) { _ in } }
            return
        }
        let seconds = url.map { ArrangeViews.seconds($0) } ?? 0
        let name = url.map { $0.deletingPathExtension().lastPathComponent } ?? "drop audio here"
        ArrangeViews.preview[id] = ArrangeDropPreview(lane: spot.lane, start: spot.start,
                                                      length: seconds > 0 ? seconds / spot.spbSec : 4, name: name, path: url?.path)
        ArrangeViews.set(id) { _ in }
    }

    /// Files dropped on arrange (or dragged from rec's list): one clip each, at the lane and beat under the
    /// point, the next file on the next lane. Files from elsewhere are copied into the recordings folder.
    func arrangeDrop(_ id: UUID, _ urls: [URL], at p: CGPoint, display r: CGRect) -> Bool {
        arrangePreview(id, nil, at: nil, display: r)
        guard let i = patch.index(of: id), let n = host.node(id) as? ArrangeNode, let spot = arrangeSpot(id, at: p, display: r) else { return false }
        let count = ArrangeLayout.count(patch.nodes[i].params["tracks"])
        var lane = spot.lane
        var files = n.files, clips = n.clips
        for url in urls where AudioFiles.extensions.contains(url.pathExtension.lowercased()) {
            let local = Self.keepLocal(url)
            guard let f = try? AVAudioFile(forReading: local) else { continue }
            let seconds = Double(f.length) / max(f.fileFormat.sampleRate, 1)
            var k = files.firstIndex(of: local.path) ?? -1
            if k < 0 { files.append(local.path); k = files.count - 1 }
            clips.append(ArrangeClip(track: lane, start: spot.start, length: max(seconds / spot.spbSec, 1.0 / 64), file: k))
            lane = min(lane + 1, count - 1)
        }
        guard clips.count > n.clips.count else { return false }
        setData(id, [ArrangeLayout.filesKey: ArrangeClip.encodeFiles(files), ArrangeLayout.clipsKey: ArrangeClip.encode(clips)])
        ArrangeViews.set(id) { $0.selected = Set(n.clips.count..<clips.count) }
        ArrangeViews.focused = id
        return true
    }

    /// The delete key: the selected clip of the arrange box last clicked (unless other boxes are selected).
    func deleteArrangeClip() -> Bool {
        guard let id = ArrangeViews.focused, case let sel = ArrangeViews.get(id).selected, !sel.isEmpty,
              selectedNodes.isEmpty || selectedNodes == [id], selectedCable == nil,
              let n = host.node(id) as? ArrangeNode else { return false }
        let clips = n.clips.enumerated().filter { !sel.contains($0.offset) }.map(\.element)
        setData(id, ArrangeLayout.clipsKey, ArrangeClip.encode(clips))
        ArrangeViews.set(id) { $0.selected = [] }
        ArrangeViews.focused = nil
        return true
    }

    /// A new track below `t` (a copy of it, clips and settings, or an empty one); the tracks under it, and
    /// their cables, move down one.
    func arrangeInsertTrack(_ id: UUID, after t: Int, copy: Bool, only: [Int]? = nil) {
        guard let n = host.node(id) as? ArrangeNode, let i = patch.index(of: id) else { return }
        let count = ArrangeLayout.count(patch.nodes[i].params["tracks"])
        guard count < ArrangeLayout.tracks, t < count else { return }
        let F = ArrangeLayout.trackFields
        var clips = n.clips.map { c -> ArrangeClip in var c = c; if c.track > t { c.track += 1 }; return c }
        if copy {
            // a copy of the track's clips (or just the ones given) on the new track
            let source = only.map { o in o.filter { $0 < n.clips.count }.map { n.clips[$0] } } ?? n.clips.filter { $0.track == t }
            clips += source.map { var c = $0; c.track = t + 1; return c }
        }
        var tracks = n.trackData
        let row: [Float] = copy ? Array(tracks[(t * F)..<(t * F + F)]) : [1, 0, 0, 0, 0]
        tracks.insert(contentsOf: row, at: (t + 1) * F)
        tracks.removeLast(F)
        editNodeAndCables(id) { node, cables in
            node.params["tracks"] = Float(count + 1)
            node.data[ArrangeLayout.clipsKey] = ArrangeClip.encode(clips.filter { $0.track < ArrangeLayout.tracks })
            node.data[ArrangeLayout.tracksKey] = tracks
            cables = cables.compactMap { c in
                var c = c
                if c.toNode == id && c.toPort < kParamPortBase && c.toPort >= 2 * (t + 1) { c.toPort += 2; if c.toPort >= 2 * ArrangeLayout.tracks { return nil } }
                if c.fromNode == id && c.fromPort >= 3 + 2 * (t + 1) { c.fromPort += 2; if c.fromPort >= 3 + 2 * ArrangeLayout.tracks { return nil } }
                return c
            }
        }
        ArrangeViews.set(id) { $0.selected = [] }
    }

    /// Remove track `t`: its clips and cables go, the tracks under it move up.
    func arrangeDeleteTrack(_ id: UUID, _ t: Int) {
        guard let n = host.node(id) as? ArrangeNode, let i = patch.index(of: id) else { return }
        let count = ArrangeLayout.count(patch.nodes[i].params["tracks"])
        guard count > 1 else { return }
        let F = ArrangeLayout.trackFields
        let clips = n.clips.filter { $0.track != t }.map { c -> ArrangeClip in var c = c; if c.track > t { c.track -= 1 }; return c }
        var tracks = n.trackData
        tracks.removeSubrange((t * F)..<(t * F + F))
        tracks += [1, 0, 0, 0, 0]
        editNodeAndCables(id) { node, cables in
            node.params["tracks"] = Float(count - 1)
            node.data[ArrangeLayout.clipsKey] = ArrangeClip.encode(clips)
            node.data[ArrangeLayout.tracksKey] = tracks
            cables = cables.compactMap { c in
                var c = c
                if c.toNode == id && c.toPort < kParamPortBase {
                    if c.toPort / 2 == t { return nil }
                    if c.toPort / 2 > t { c.toPort -= 2 }
                }
                if c.fromNode == id && c.fromPort >= 3 {
                    if (c.fromPort - 3) / 2 == t { return nil }
                    if (c.fromPort - 3) / 2 > t { c.fromPort -= 2 }
                }
                return c
            }
        }
        ArrangeViews.set(id) { $0.selected = [] }
    }

    /// A file from outside the recordings folder: a copy inside it (so the patch keeps its audio).
    static func keepLocal(_ url: URL) -> URL {
        let rec = Recordings.directory.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(rec) { return url }
        let dir = Recordings.directory.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            // the same file already copied: use it; another with the same name: number this one
            let a = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            let b = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -2
            if a == b { return dest }
            var k = 2
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            repeat { dest = dir.appendingPathComponent("\(base) \(k).\(ext)"); k += 1 } while fm.fileExists(atPath: dest.path)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? fm.copyItem(at: url, to: dest)) != nil ? dest : url
    }

    /// An arrangement take finished: its files become clips on their tracks (one undo step).
    func addTakes(_ node: ArrangeNode, _ takes: [ArrangeTake]) {
        guard let id = host.nodes.first(where: { $0.value === node })?.key, patch.index(of: id) != nil else { return }
        var files = node.files, clips = node.clips
        for t in takes {
            files.append(t.url.path)
            clips.append(ArrangeClip(track: t.track, start: t.start, length: max(t.length, 1.0 / 64), file: files.count - 1))
        }
        setData(id, [ArrangeLayout.filesKey: ArrangeClip.encodeFiles(files), ArrangeLayout.clipsKey: ArrangeClip.encode(clips)])
    }

    /// The arrange box whose tracks / ruler are under a canvas point: its display, as a helper to act on.
    private func arrangeUnder(_ c: CGPoint) -> (ArrangeDisplay, CGPoint, CGRect)? {
        guard let i = topBox(at: c), patch.nodes[i].kind == "arrange", let spec = ModuleRegistry.spec("arrange") else { return nil }
        let n = patch.nodes[i]
        let geo = BoxGeo(n, spec, hw, selected: false, model: self)
        let p = CGPoint(x: c.x - n.x, y: c.y - n.y)
        guard let d = geo.display else { return nil }
        let ag = ArrangeGeo(d, n)
        guard ag.area.contains(p) || ag.ruler.contains(p) else { return nil }
        return (ArrangeDisplay(model: self, node: n, spec: spec), p, d)
    }

    /// The wheel over an arrange box's lanes zooms / scrolls its timeline. True when one took it.
    func scrollArrange(at c: CGPoint, dx: CGFloat, dy: CGFloat, zoom: Bool) -> Bool {
        guard let (disp, p, d) = arrangeUnder(c) else { return false }
        disp.scroll(dx: dx, dy: dy, zoom: zoom, at: p, d)
        return true
    }

    /// A pinch over an arrange box's lanes zooms its timeline (not the patch). True when one took it.
    func pinchArrange(at c: CGPoint, by factor: CGFloat) -> Bool {
        guard let (disp, p, d) = arrangeUnder(c) else { return false }
        if factor.isFinite && factor > 0 { disp.zoom(factor, ArrangeGeo(d, disp.node), around: p.x) }
        return true
    }
}
