import SwiftUI
import PoljeNieukCore

/// One app-wide tick that drives every live display (meters, waveforms, playheads, live values):
/// 20 Hz while audio runs, 4 Hz when it's off (nothing on screen is moving then). A plain Timer in the
/// .common run-loop mode, so it keeps going when the window isn't the active one.
///
/// This is the *only* thing that redraws live displays — they don't follow the screen's refresh rate
/// (120 Hz on ProMotion iPads made every display redraw four times as often, for no visible gain).
@MainActor
final class Ticker {
    static let shared = Ticker()
    private(set) var frame = 0
    private var timer: Timer?
    private(set) var rate: Double = 0
    /// Every live display on screen (weakly held): each is asked on every tick whether it changed.
    private let slots = NSHashTable<LiveSlot>.weakObjects()

    private init() { setRate(60) }

    func register(_ slot: LiveSlot) { slots.add(slot) }

    /// Ticks three times per base frame: displays that glide continuously (an LFO's dot, playheads)
    /// redraw on every tick — the screen's 60 fps — the rest on every third (20 Hz, as before).
    static let substeps = 3
    /// Audio on: 60 Hz (20 Hz for most displays). Audio off: 12 Hz (4 Hz).
    func setActive(_ on: Bool) { setRate(on ? 60 : 12) }

    private func setRate(_ hz: Double) {
        guard hz != rate else { return }
        rate = hz
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2 / hz
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Checks each display's fingerprint and wakes only the ones that changed — when nothing on screen moves,
    /// SwiftUI isn't woken at all (waking every display every tick was most of the app's CPU).
    private func tick() {
        frame &+= 1
        for slot in slots.allObjects { slot.poll(frame) }
    }
}

/// One live display's link to the tick: holds its fingerprint and tells only its own view to update.
@MainActor
final class LiveSlot: ObservableObject {
    var signature: (() -> Int)?
    /// Poll every Nth tick: 2 for small indicators (dots, meters, live values — 10 Hz looks the same).
    var every = 1
    /// Moves continuously (LFO dot, playheads): redrawn at the full tick rate, so it glides instead of stepping.
    var smooth = false
    private(set) var version = 0
    private var last = Int.min
    init() { Ticker.shared.register(self) }
    /// When the view re-renders anyway (an edit): pick up a change right now instead of at the next tick.
    func current() -> Int {
        if let sig = signature?(), sig != last { last = sig; version &+= 1 }
        return version
    }
    @discardableResult func poll(_ frame: Int) -> Bool {
        // gliding displays: 30 fps (smooth to the eye at a fraction of 60's cost); the rest: 20 fps
        let step = smooth ? max(every, 1) * 2 : max(every, 1) * Ticker.substeps
        if step > 1 && frame % step != 0 { return false }
        let s = signature?() ?? frame              // no fingerprint: it moves every tick (an LFO wave …)
        if s != last { last = s; version &+= 1; objectWillChange.send(); return true }
        return false
    }
}

private struct LiveDisplaysOnKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False for boxes scrolled off screen: their live displays hold still (no redraws) until they're back.
    var liveDisplaysOn: Bool {
        get { self[LiveDisplaysOnKey.self] }
        set { self[LiveDisplaysOnKey.self] = newValue }
    }
}

/// Re-renders its content on every tick (only while on screen). Give it a `signature` — a cheap number
/// that changes when what it shows changes (a quantised level, a step index …) — and it only re-renders
/// then: most of the time nothing moves, and skipping those redraws is most of the app's CPU.
struct LiveView<Content: View>: View {
    @Environment(\.liveDisplaysOn) private var on
    private let signature: (() -> Int)?
    private let content: () -> Content
    let every: Int
    init(signature: (() -> Int)? = nil, every: Int = 1, @ViewBuilder _ content: @escaping () -> Content) {
        self.signature = signature; self.every = every; self.content = content
    }
    var body: some View {
        if on { Ticking(signature: signature, content: content, every: every) } else { content() }
    }
    private struct Ticking: View {
        @StateObject private var slot = LiveSlot()
        let signature: (() -> Int)?
        let content: () -> Content
        let every: Int
        var body: some View {
            slot.every = every
            slot.signature = signature                 // the latest one (it captures the current state)
            return Unchanged(key: LiveSig.styled(slot.current()), content: content).equatable()
        }
    }
    private struct Unchanged: View, Equatable {
        let key: Int
        let content: () -> Content
        static func == (a: Unchanged, b: Unchanged) -> Bool { a.key == b.key }
        var body: some View { content() }
    }
}

/// A Canvas that redraws on every tick while on screen — or, with a `signature`, only when that changes.
///
/// Why this exists: Canvas only redraws when SwiftUI sees one of its inputs change. Live displays read
/// audio-thread memory SwiftUI can't observe, so a plain Canvas froze until you touched something.
struct LiveCanvas: View {
    @Environment(\.liveDisplaysOn) private var on
    @Environment(\.canvasZoom) private var zoom
    var signature: (() -> Int)? = nil
    let draw: (GraphicsContext, CGSize) -> Void

    var every = 1
    /// glides continuously (an LFO's dot, a playhead): redrawn at 60 fps instead of 20
    var smooth = false
    init(signature: (() -> Int)? = nil, every: Int = 1, smooth: Bool = false, draw: @escaping (GraphicsContext, CGSize) -> Void) {
        self.signature = signature; self.every = every; self.smooth = smooth; self.draw = draw
    }

    var body: some View {
        if on { Ticking(signature: signature, draw: draw, zoom: zoom, every: every, smooth: smooth) } else { Drawn(draw: draw, zoom: zoom, tick: 0) }
    }

    private struct Ticking: View {
        // held, not observed: this view must not wake on every tick — only the small view below does
        @State private var slot = LiveSlot()
        let signature: (() -> Int)?
        let draw: (GraphicsContext, CGSize) -> Void
        let zoom: CGFloat
        let every: Int
        let smooth: Bool
        var body: some View {
            let _ = configure()
            // drawn in place at every zoom. (A nested native view per display was cheaper, but native views
            // don't scale properly inside the zoomed canvas: keys~ drew its keyboard shrunk into a corner.)
            Observing(slot: slot, draw: draw, zoom: zoom)
        }
        private func configure() {
            slot.every = every
            slot.smooth = smooth
            slot.signature = signature
            _ = slot.current()                          // an edit shows straight away
        }
    }

    /// Drawn in place, woken by its own slot (only this view redraws on a tick).
    private struct Observing: View {
        @ObservedObject var slot: LiveSlot
        let draw: (GraphicsContext, CGSize) -> Void
        let zoom: CGFloat
        var body: some View { Drawn(draw: draw, zoom: zoom, tick: LiveSig.styled(slot.version)).equatable() }
    }

    private struct Drawn: View, Equatable {
        let draw: (GraphicsContext, CGSize) -> Void
        let zoom: CGFloat
        let tick: Int
        // the draw closure reads live memory itself: only the tick (or signature) and zoom decide a redraw
        static func == (a: Drawn, b: Drawn) -> Bool { a.tick == b.tick && a.zoom == b.zoom }
        var body: some View {
            // The patch is zoomed with a scale transform, which would magnify this Canvas's pixels. So when
            // zoomed in, draw it at the zoomed size and shrink it back: after the zoom it's 1:1 with the screen.
            let z = max(min(zoom, 3), 1)
            if z <= 1.01 {
                // not zoomed in: a plain Canvas (no measuring container — that cost a layout pass every tick)
                Canvas { ctx, size in
                    _ = tick
                    draw(ctx, size)
                }
            } else {
            GeometryReader { geo in
                Canvas { ctx, size in
                    _ = tick
                    if z > 1.01 {
                        var c = ctx
                        c.scaleBy(x: z, y: z)
                        draw(c, CGSize(width: size.width / z, height: size.height / z))
                    } else {
                        draw(ctx, size)
                    }
                }
                .frame(width: geo.size.width * (z > 1.01 ? z : 1), height: geo.size.height * (z > 1.01 ? z : 1))
                .scaleEffect(z > 1.01 ? 1 / z : 1, anchor: .topLeading)
            }
            }
        }
    }
}

/// Signature helpers: fold values into one Int, quantised so tiny wobbles don't count as a change.
enum LiveSig {
    @inline(__always) static func q(_ v: Float, _ steps: Float = 64) -> Int {
        v.isFinite ? Int((min(max(v, -1e6), 1e6) * steps).rounded()) : 0
    }
    @inline(__always) static func mix(_ h: inout Int, _ v: Int) { h = h &* 31 &+ v }
    /// A run of floats (a pattern, latched keys …): changes when any of them does.
    static func floats(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        var h = n
        for i in 0..<n { h = h &* 1_000_003 &+ Int(p[i].bitPattern) }
        return h
    }
    static func floats(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Int { floats(UnsafePointer(p), n) }
    /// The first `n` readouts, quantised.
    static func readouts(_ node: DSPNode?, _ n: Int, steps: Float = 128) -> Int {
        guard let node else { return 0 }
        var h = 0
        for i in 0..<min(n, DSPNode.readoutCount) { mix(&h, q(node.readouts[i], steps)) }
        return h
    }
    /// A box's settings and saved arrays (whatever the view draws from the patch): order doesn't matter.
    static func patch(_ n: PatchNode) -> Int {
        var h = 0
        for (k, v) in n.params { h = h &+ (k.hashValue ^ Int(v.bitPattern) &* 2_654_435_761) }
        for (k, v) in n.data { h = h &+ (k.hashValue ^ v.count &* 40503); for x in v.prefix(600) { h = h &* 31 &+ Int(x.bitPattern) } }
        mix(&h, Int((n.w ?? 0) * 8)); mix(&h, Int((n.dh ?? 0) * 8)); mix(&h, n.collapsed ? 1 : 0)
        return h
    }
    /// A signature plus the colour scheme, so switching dark / light or a custom colour still repaints.
    @MainActor static func styled(_ v: Int) -> Int { (v &* 31 &+ CustomColours.version) &* 2 &+ (Theme.light ? 1 : 0) }
}

private struct CanvasZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// How far the patch is zoomed in, so live displays can draw at full sharpness.
    var canvasZoom: CGFloat {
        get { self[CanvasZoomKey.self] }
        set { self[CanvasZoomKey.self] = newValue }
    }
}
