import SwiftUI
import Combine
import AVFoundation
import PoljeNieukCore

struct DeviceChoice: Identifiable, Hashable {
    let id: String      // device UID ("" = automatic, "none" = no input)
    let name: String
}

struct PendingCable: Equatable {
    var node: UUID
    var port: Int
    var fromOutput: Bool
    var point: CGPoint   // screen point (canvas view coordinates)
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var patch: Patch {
        didSet {
            if patch.cables != oldValue.cables { BoxLayout.rebuildUsage(patch) }
            if !restoringHistory { scheduleCheckpoint() }
        }
    }
    /// Undo / redo (whole-patch snapshots, one step per settled edit).
    @Published private(set) var history = UndoHistory(committed: Patch())
    private var restoringHistory = false
    private var checkpointWork: DispatchWorkItem?
    @Published var selectedNodes: Set<UUID> = []
    @Published var selectedCable: UUID?
    @Published var pendingCable: PendingCable?
    @Published var finderAt: CGPoint? {          // canvas point where the object box is being typed
        didSet { if finderAt == nil { replaceTarget = nil } }
    }
    /// Long-pressed box: the module list is open to replace it.
    @Published var replaceTarget: UUID?

    /// Long-press a box's title: open the module list to swap it for another module.
    func beginReplace(_ id: UUID) {
        guard let n = patch.nodes.first(where: { $0.id == id }) else { return }
        finderAt = CGPoint(x: n.x, y: n.y + 24)
        replaceTarget = id
    }

    func replaceNode(_ id: UUID, with kind: String) {
        guard let r = patch.replacing(id, with: kind) else { return }
        patch = r.patch
        selectedNodes = [r.newID]
        selectedCable = nil
        topologyChanged()
    }
    /// Pan and zoom live in their own object: only the canvas listens to it, so moving around doesn't make
    /// every box rebuild itself 120 times a second (it used to, and panning a big patch took over a core).
    let viewport = Viewport(
        offset: CGSize(width: UserDefaults.standard.object(forKey: "viewOffsetX") as? Double ?? 30,
                       height: UserDefaults.standard.object(forKey: "viewOffsetY") as? Double ?? 30),
        scale: min(max(UserDefaults.standard.object(forKey: "viewScale") as? Double ?? 1, 0.12), 2))
    var viewOffset: CGSize {
        get { viewport.offset }
        set { viewport.offset = newValue; scheduleViewSave() }
    }
    var viewScale: CGFloat {
        get { viewport.scale }
        set { viewport.scale = newValue; scheduleViewSave() }
    }
    /// The zoom the boxes' own layer was last drawn at (see NodesHost): while you pinch, that layer is just
    /// stretched; once you stop it redraws sharp at the new zoom.
    let hostedZoom = HostedZoom()
    /// Where the canvas view's top-left corner is in window coordinates (set by the canvas).
    var canvasGlobalOrigin: CGPoint = .zero
    /// A window-coordinate point (drags inside the boxes' own views are measured there) → canvas-view coordinates.
    func fromGlobal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - canvasGlobalOrigin.x, y: p.y - canvasGlobalOrigin.y) }
    /// Is there a box, note or group backdrop at this canvas point? (Elsewhere touches fall through to the canvas.)
    func hasContent(at c: CGPoint) -> Bool {
        let m: CGFloat = 14                        // ports stick out over the box edges
        for n in patch.nodes {
            let h: CGFloat
            if n.kind == "text" { h = BoxLayout.textSize(n).height }
            else if let spec = ModuleRegistry.spec(n.kind) { h = BoxLayout.height(n, spec, hw) } else { continue }
            if CGRect(x: n.x - m, y: n.y - m, width: BoxLayout.width(n) + 2 * m, height: h + 2 * m).contains(c) { return true }
        }
        return groups.contains { groupRect($0)?.contains(c) ?? false }
    }
    /// Bumped once panning / zooming pauses, so boxes re-check whether they're on screen.
    @Published private(set) var viewportSettled = 0
    private var settleWork: DispatchWorkItem?
    private var viewSaveWork: DispatchWorkItem?
    /// Zoom and position are remembered between launches.
    private func scheduleViewSave() {
        viewSaveWork?.cancel()
        let s = Double(viewScale), x = Double(viewOffset.width), y = Double(viewOffset.height)
        let w = DispatchWorkItem {
            let d = UserDefaults.standard
            d.set(s, forKey: "viewScale"); d.set(x, forKey: "viewOffsetX"); d.set(y, forKey: "viewOffsetY")
        }
        viewSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        settleWork?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.viewportSettled &+= 1
                if self.hostedZoom.scale != self.viewScale { self.hostedZoom.scale = self.viewScale }
                if self.hostedZoom.offset != self.viewOffset { self.hostedZoom.offset = self.viewOffset }
            }
        }
        settleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: settle)
    }

    /// Zoom by `factor` keeping the canvas point under `anchor` (view coordinates) still.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let old = viewScale
        let new = min(max(old * factor, 0.12), 2.0)
        guard new != old else { return }
        let cx = (anchor.x - viewOffset.width) / old, cy = (anchor.y - viewOffset.height) / old
        viewScale = new
        viewOffset = CGSize(width: anchor.x - cx * new, height: anchor.y - cy * new)
    }
    /// True while a pinch is in progress, so box drags / slider drags under the fingers are ignored.
    var isZooming = false
    @Published var viewSize: CGSize = .zero

    /// 3D mode (the cube in the top bar): the patch board tilts away in perspective and boxes can float
    /// at their own heights (PatchNode.z). Drag a box to move it on the board, its ↕ handle to raise it.
    @Published var threeD = false

    /// 3D mode: the camera — how steeply you look down at the board (degrees from flat) and its spin.
    @Published private(set) var orbitPitch: Double = 52
    @Published private(set) var orbitYaw: Double = 0
    func orbit(pitch: Double, yaw: Double) {
        orbitPitch = min(max(pitch, 8), 78)
        orbitYaw = yaw.truncatingRemainder(dividingBy: 360)
    }

    /// 3D menu: lift every box of one section (as in the device menu) — or put them down if they're all up.
    static let liftHeight = 170.0
    func sectionKinds(_ category: String) -> [Int] {
        patch.nodes.indices.filter { ModuleRegistry.spec(patch.nodes[$0].kind)?.category == category }
    }
    func sectionLifted(_ category: String) -> Bool {
        let ix = sectionKinds(category)
        return !ix.isEmpty && ix.allSatisfy { (patch.nodes[$0].z ?? 0) > 0.5 }
    }
    func toggleLift(_ category: String) {
        let up = !sectionLifted(category)
        for i in sectionKinds(category) { patch.nodes[i].z = up ? Self.liftHeight : nil }
        threeD = true
        scheduleAutosave()
    }
    /// Every section on its own level (in the device menu's order), the first one on the board.
    func layerBySection() {
        let order = ModuleRegistry.categories.filter { !sectionKinds($0).isEmpty }
        for (level, cat) in order.enumerated() {
            for i in sectionKinds(cat) { patch.nodes[i].z = level == 0 ? nil : Double(level) * 110 }
        }
        threeD = true
        scheduleAutosave()
    }
    func putEverythingDown() {
        for i in patch.nodes.indices where patch.nodes[i].z != nil { patch.nodes[i].z = nil }
        scheduleAutosave()
    }

    /// 3D mode: the camera as the 3D view draws it.
    var camera3D: BoardCamera {
        BoardCamera(viewSize: viewSize, tilt: orbitPitch * .pi / 180, yaw: orbitYaw * .pi / 180)
    }
    private var move3DGrab: (id: UUID, grab: CGSize)?
    /// 3D mode: drag a box by its title — `from` / `to` are screen points in the canvas.
    func move3D(_ id: UUID, from start: CGPoint, to now: CGPoint) {
        guard let i = patch.index(of: id) else { return }
        let cam = camera3D, s = Double(viewScale), o = viewOffset
        let n = patch.nodes[i], h = (n.z ?? 0) * s
        if move3DGrab?.id != id {
            let p = cam.unproject(start, h: h)
            move3DGrab = (id, CGSize(width: p.x - (n.x * s + o.width), height: p.y - (n.y * s + o.height)))
            select(id)
        }
        guard let g = move3DGrab?.grab else { return }
        let p = cam.unproject(now, h: h)
        moveNode(id, to: CGPoint(x: (p.x - g.width - o.width) / s, y: (p.y - g.height - o.height) / s))
    }
    func end3DMove() { move3DGrab = nil }

    /// 3D mode: set a box's height above the board.
    func setHeight(_ id: UUID, _ z: Double) {
        guard let i = patch.index(of: id) else { return }
        let v = min(max(z, 0), 900)
        patch.nodes[i].z = v < 0.5 ? nil : v
    }

    @Published var isRunning = false {
        didSet { if isRunning != oldValue { Ticker.shared.setActive(isRunning) } }
    }
    /// The whole app's CPU use (all threads, share of one core): drawing included, unlike `cpuLoad`.
    /// (not @Published: the top bar's live text reads it on its tick — publishing it rebuilt the whole window)
    private(set) var appCPU: Float = 0
    private var lastUsage: (cpu: Double, wall: Double)?

    private func sampleAppCPU() {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        let wall = ProcessInfo.processInfo.systemUptime
        if let last = lastUsage, wall - last.wall > 0.1 {
            let v = Float((cpu - last.cpu) / (wall - last.wall))
            appCPU = appCPU == 0 ? v : appCPU * 0.6 + v * 0.4
        }
        lastUsage = (cpu, wall)
    }
    /// Transport (▶ ❚❚ ■ on the clock box): the beat runs, holds, or rewinds to the start.
    @Published private(set) var transport: GraphHost.Transport = .play
    func setTransport(_ t: GraphHost.Transport) {
        transport = t
        host.transport(t)
    }
    @Published var audioStatus = "audio off"
    @Published var audioError: String?
    @Published var hw: HardwareCounts
    @Published var inputChoices: [DeviceChoice] = []
    @Published var outputChoices: [DeviceChoice] = []
    @Published var inputUID: String?
    /// Help mode (the ? button): pointing at things explains them in a panel.
    @Published var helpMode = false { didSet { if !helpMode { helpTopics = [] } } }
    /// What's under the pointer, innermost last (a parameter inside a box, say).
    @Published private(set) var helpTopics: [HelpTopic] = []
    func hoverHelp(_ t: HelpTopic, inside: Bool) {
        helpTopics.removeAll { $0.id == t.id }
        if inside { helpTopics.append(t) }
    }

    /// Bumped when a custom colour changes, so every view redraws with it.
    @Published private(set) var colourVersion = 0
    func coloursChanged() { colourVersion &+= 1 }
    /// The colours panel (palette button) is open.
    @Published var showColours = false
    /// View ▸ Hide cables: the patch cords aren't drawn (and can't be picked); patching still shows the one you drag.
    @Published var hideCables = UserDefaults.standard.bool(forKey: "hideCables") {
        didSet {
            UserDefaults.standard.set(hideCables, forKey: "hideCables")
            if hideCables { selectedCable = nil }
        }
    }

    /// Light / dark colour scheme for the whole app (remembered).
    @Published var lightScheme: Bool = Theme.light {
        didSet { Theme.light = lightScheme; CustomColours.schemeChanged(); UserDefaults.standard.set(lightScheme, forKey: "lightScheme") }
    }
    @Published var outputUID: String?
    @Published var inputName = "—"
    @Published var outputName = "—"
    // MARK: File browser
    @Published var showFiles = false
    @Published var browserFolders: [URL] = []
    @Published var addingFolder = false

    private func restoreFolders() {
        let datas = UserDefaults.standard.array(forKey: "browserFolders") as? [Data] ?? []
        var urls: [URL] = []
        for d in datas {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let u = try? URL(resolvingBookmarkData: d, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = u.startAccessingSecurityScopedResource()   // keep access for the session
                urls.append(u)
            }
        }
        browserFolders = urls
    }

    func addFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(options: opts, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            audioError = "Couldn't keep access to that folder."
            return
        }
        var datas = UserDefaults.standard.array(forKey: "browserFolders") as? [Data] ?? []
        datas.append(data)
        UserDefaults.standard.set(datas, forKey: "browserFolders")
        if !browserFolders.contains(url) { browserFolders.append(url) }
    }

    func removeFolder(_ url: URL) {
        guard let i = browserFolders.firstIndex(of: url) else { return }
        browserFolders.remove(at: i)
        var datas = UserDefaults.standard.array(forKey: "browserFolders") as? [Data] ?? []
        if i < datas.count { datas.remove(at: i) }
        UserDefaults.standard.set(datas, forKey: "browserFolders")
    }

    /// Module waiting for an audio file from the file picker.
    @Published var audioImportTarget: UUID? {
        didSet { if let t = audioImportTarget { importDestination = t } }
    }
    private var importDestination: UUID?

    let host = GraphHost()
    let io: AudioIO
    private var autosaveWork: DispatchWorkItem?
    private var bufferTimer: Timer?
    private var seenVersion: [ObjectIdentifier: Int] = [:]
    private var analyzeWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    public init() {
        io = AudioIO(host: host)
        let d = UserDefaults.standard
        hw = HardwareCounts(inputs: d.object(forKey: "hwInputs") as? Int ?? 12,
                            outputs: d.object(forKey: "hwOutputs") as? Int ?? 8)
        inputUID = d.string(forKey: "inputUID")
        outputUID = d.string(forKey: "outputUID")
        patch = PatchStore.loadAutosave() ?? DefaultPatch.make()
        patch = ControlLink.reconciled(patch)
        history = UndoHistory(committed: patch)
        BoxLayout.rebuildUsage(patch)
        followClockInputs()                     // just notes which clock inlets are patched
        host.load(patch)
        restoreFolders()
        restoreBuffers()
        bufferTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchBuffers() }
        }
        hostedZoom.scale = viewport.scale
        hostedZoom.offset = viewport.offset
        Ticker.shared.setActive(false)          // displays tick slowly until audio is on
        let cpuTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleAppCPU() }
        }
        RunLoop.main.add(cpuTimer, forMode: .common)
        #if os(iOS)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            // only plugging / unplugging: .override and the like come from our own start setting the route
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.scheduleRouteCheck() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .ended {
                MainActor.assumeIsolated { self?.restartAudio() }
            }
        })
        #endif
        #if os(macOS)
        io.onDevicesChanged = { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        io.onActiveDeviceChanged = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRestartCheck() }
        }
        #else
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio() }
        })
        #endif
    }

    // MARK: Audio

    private var restartCheck: DispatchWorkItem?
    #if os(iOS)
    /// The route audio last started on (AudioIO.routeSignature).
    private var startedRoute = ""
    private var routeCheck: DispatchWorkItem?
    /// An interface arriving or leaving sends several notices while the system switches over: wait for it to
    /// settle, then restart once — and only if what's connected really changed.
    private func scheduleRouteCheck() {
        routeCheck?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantsAudio else { return }
                if self.io.isStarting { self.scheduleRouteCheck(); return }
                if AudioIO.routeSignature() != self.startedRoute || !self.isRunning { self.restartAudio() }
            }
        }
        routeCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
    #endif
    private var lastDeviceUIDs: [String] = []

    #if os(macOS)
    private func devicesChanged() {
        io.listDevices { [weak self] all in
            MainActor.assumeIsolated {
                guard let self else { return }
                let uids = all.map(\.uid).sorted()
                guard uids != self.lastDeviceUIDs else { return }   // ignore our own aggregate appearing/disappearing
                self.lastDeviceUIDs = uids
                self.refreshDevices()
                self.scheduleRestartCheck()
            }
        }
    }
    #endif

    /// Debounced: restart the engine if a device in use vanished, changed rate, or a preferred one came back.
    private func scheduleRestartCheck() {
        restartCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning || self.wantsAudio, !self.io.isStarting else { return }
                #if os(macOS)
                self.io.checkNeedsRestart { needs in
                    MainActor.assumeIsolated { if needs && self.wantsAudio && !self.io.isStarting { self.restartAudio() } }
                }
                #endif
            }
        }
        restartCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func refreshDevices() {
        #if os(macOS)
        io.listDevices { [weak self] all in       // read in the background: the device list can stall too
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputChoices = [DeviceChoice(id: "none", name: "off"), DeviceChoice(id: "", name: "automatic (disting NT if connected)")]
                    + all.filter { $0.inputChannels > 0 }.map { DeviceChoice(id: $0.uid, name: "\($0.name)  (\($0.inputChannels) ch)") }
                self.outputChoices = [DeviceChoice(id: "off", name: "off (patch keeps running, silent)"), DeviceChoice(id: "", name: "default")]
                    + all.filter { $0.outputChannels > 0 }.map { DeviceChoice(id: $0.uid, name: "\($0.name)  (\($0.outputChannels) ch)") }
            }
        }
        #else
        inputChoices = [DeviceChoice(id: "none", name: "off"), DeviceChoice(id: "", name: "automatic")]
            + AudioIO.availableInputs().map { DeviceChoice(id: $0.uid, name: $0.name) }
        outputChoices = [DeviceChoice(id: "off", name: "off (patch keeps running, silent)"),
                         DeviceChoice(id: "", name: "connected device"),
                         DeviceChoice(id: "speaker", name: "iPad speakers")]
        #endif
    }

    func selectInput(_ uid: String) {
        inputUID = uid.isEmpty ? nil : uid
        UserDefaults.standard.set(inputUID, forKey: "inputUID")
        restartAudio()
    }

    func selectOutput(_ uid: String) {
        outputUID = uid.isEmpty ? nil : uid
        UserDefaults.standard.set(outputUID, forKey: "outputUID")
        restartAudio()
    }

    func startAudio() {
        refreshDevices()
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !granted { self.audioError = "Microphone/audio input permission is off — inputs will be silent." }
                    self.restartAudio()
                }
            }
        }
    }

    /// Whether the user wants audio on (so a hot-plugged device brings it back).
    private var wantsAudio = false

    /// Keeps macOS App Nap from throttling audio and displays while the engine runs.
    private var activity: NSObjectProtocol?

    private func holdActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Processing live audio")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    func stopAudio() {
        holdActivity(false)
        wantsAudio = false
        io.stop()                          // returns at once; the device is released in the background
        host.clearReadouts()
        isRunning = false
        audioStatus = "audio off"
    }

    private var slowStartNote: DispatchWorkItem?

    func restartAudio() {
        wantsAudio = true
        io.inputUID = inputUID
        io.muteOutput = outputUID == "off"
        #if os(macOS)
        io.outputUID = outputUID == "off" ? nil : outputUID      // off still clocks from the default output
        #else
        io.outputToSpeaker = outputUID == "speaker"
        #endif
        // The device work happens in the background (macOS / iPadOS audio can stall for seconds, e.g. while
        // an interface is plugged in or out); the window keeps working and says what it's waiting for.
        isRunning = false
        audioStatus = "starting audio…"
        slowStartNote?.cancel()
        let note = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.io.isStarting else { return }
                self.audioStatus = "waiting for the system audio…"
            }
        }
        slowStartNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: note)
        io.start(prepare: { [weak self] sr in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.host.setSampleRate(sr)
                self.host.prepareForStart()
            }
        }, done: { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.slowStartNote?.cancel()
                if let error {
                    self.isRunning = false
                    self.audioStatus = "audio off"
                    self.audioError = error.localizedDescription
                    return
                }
                self.isRunning = true
                #if os(iOS)
                self.startedRoute = AudioIO.routeSignature()
                #endif
                self.holdActivity(true)
                self.audioError = nil
                self.inputName = self.io.inputName
                self.outputName = self.io.outputName
                let counts = HardwareCounts(inputs: self.io.inputChannels, outputs: self.io.outputChannels)
                if counts != self.hw {
                    self.hw = counts
                    UserDefaults.standard.set(counts.inputs, forKey: "hwInputs")
                    UserDefaults.standard.set(counts.outputs, forKey: "hwOutputs")
                }
                let khz = self.io.sampleRate / 1000
                self.audioStatus = "\(khz.formatted(.number.precision(.fractionLength(0...1))))k · "
                    + "\(self.io.bufferFrames) · \(self.io.latencyMs.formatted(.number.precision(.fractionLength(1))))ms"
                self.refreshDevices()
            }
        })
    }

    var cpuLoad: Float { io.cpuLoad }
    var cpuPeak: Float { io.cpuPeak }
    var bpm: Double { host.clockBPM }
    var externalClock: Bool { host.externalClock }

    // MARK: Tempo (top bar)

    /// The clock box that sets the tempo, if any.
    private var clockNode: PatchNode? { patch.nodes.first { $0.kind == "clock" } }
    /// The tempo can be set from the top bar unless a clock is following the modular.
    var tempoEditable: Bool {
        guard let c = clockNode else { return true }
        return (c.params["source"] ?? 0) > 0.5            // internal
    }
    /// The tempo that's set (not the measured one).
    var setTempo: Double {
        if let c = clockNode { return Double(c.params["bpm"] ?? 120) }
        return patch.tempo ?? 120
    }
    func setTempo(_ bpm: Double) {
        let b = min(max(bpm.isFinite ? bpm : 120, 20), 300)
        if let c = clockNode, let spec = ModuleRegistry.spec("clock"), let i = spec.paramIndex("bpm") {
            setParam(c.id, i, Float(b))
        } else {
            patch.tempo = b
            host.defaultBPM = b
            scheduleAutosave()
        }
    }

    // MARK: Coordinates

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - viewOffset.width) / viewScale, y: (p.y - viewOffset.height) / viewScale)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * viewScale + viewOffset.width, y: p.y * viewScale + viewOffset.height)
    }

    var viewCenterInCanvas: CGPoint {
        toCanvas(CGPoint(x: viewSize.width / 2 - 90, y: viewSize.height / 3))
    }

    // MARK: Editing

    func node(_ id: UUID) -> DSPNode? { host.node(id) }

    func addNode(kind: String, at p: CGPoint) {
        guard ModuleRegistry.spec(kind) != nil else { return }
        let n = PatchNode(kind: kind, x: p.x.rounded(), y: p.y.rounded())
        patch.nodes.append(n)
        selectedNodes = [n.id]
        selectedCable = nil
        topologyChanged()
    }

    /// Copy a box (settings, collapsed/bypass state, and any recorded audio) — no cables.
    /// It appears just below-right of the original, on top of everything, selected.
    func duplicate(_ id: UUID) {
        guard let src = patch.nodes.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.x = src.x + 24
        copy.y = src.y + 24
        patch.nodes.append(copy)
        topologyChanged()
        if let a = host.node(id) as? SampleBufferNode, let b = host.node(copy.id) as? SampleBufferNode {
            let audio = a.snapshot()
            if !audio.isEmpty { b.load(audio) }
        }
        copyRackPads(from: id, to: copy.id)
        select(copy.id)
    }

    func removeSelection() {
        if let c = selectedCable {
            patch.cables.removeAll { $0.id == c }
            selectedCable = nil
            topologyChanged()
            return
        }
        guard !selectedNodes.isEmpty else { return }
        let ids = selectedNodes
        patch.nodes.removeAll { ids.contains($0.id) }
        patch.cables.removeAll { ids.contains($0.fromNode) || ids.contains($0.toNode) }
        if let gs = patch.groups {
            patch.groups = gs.map { g -> PatchGroup in var g = g; g.members.removeAll { ids.contains($0) }; return g }
                .filter { $0.members.count >= 2 }
        }
        selectedNodes = []
        topologyChanged()
    }

    func removeNode(_ id: UUID) {
        try? FileManager.default.removeItem(at: sampleURL(id))
        selectedNodes = [id]
        selectedCable = nil
        removeSelection()
    }

    func removeCable(_ id: UUID) {
        patch.cables.removeAll { $0.id == id }
        if selectedCable == id { selectedCable = nil }
        topologyChanged()
    }

    func select(_ id: UUID) {
        selectedNodes = [id]
        selectedCable = nil
    }

    // MARK: Multi-selection (select tool, ⇧-click, marquee)

    /// Select tool on: dragging empty canvas draws a selection box, tapping a box title adds / removes it.
    @Published var selectMode = false

    func toggleSelected(_ id: UUID) {
        if selectedNodes.contains(id) { selectedNodes.remove(id) } else { selectedNodes.insert(id) }
        selectedCable = nil
    }

    /// Select every box that overlaps `rect` (canvas coordinates).
    func select(in rect: CGRect, adding: Bool) {
        let hits = patch.nodes.filter { n in
            guard let spec = ModuleRegistry.spec(n.kind) else { return false }
            let r = CGRect(x: n.x, y: n.y, width: BoxLayout.width(n), height: BoxLayout.height(n, spec, hw))
            return r.intersects(rect)
        }.map(\.id)
        selectedNodes = adding ? selectedNodes.union(hits) : Set(hits)
        selectedCable = nil
    }

    /// Duplicate the selected boxes together with the cables between them; the copies become the selection.
    func duplicateSelection() {
        let ids = selectedNodes
        guard !ids.isEmpty else { return }
        var map: [UUID: UUID] = [:]
        var copies: [PatchNode] = []
        for n in patch.nodes where ids.contains(n.id) {
            var c = n
            c.id = UUID()
            c.x = n.x + 30; c.y = n.y + 30
            map[n.id] = c.id
            copies.append(c)
        }
        patch.nodes.append(contentsOf: copies)
        for c in patch.cables where ids.contains(c.fromNode) && ids.contains(c.toNode) {
            patch.cables.append(PatchCable(fromNode: map[c.fromNode]!, fromPort: c.fromPort, toNode: map[c.toNode]!, toPort: c.toPort))
        }
        topologyChanged()
        for (old, new) in map {
            if let a = host.node(old) as? SampleBufferNode, let b = host.node(new) as? SampleBufferNode {
                let audio = a.snapshot()
                if !audio.isEmpty { b.load(audio) }
            }
            copyRackPads(from: old, to: new)
        }
        selectedNodes = Set(map.values)
    }

    // MARK: Groups

    var groups: [PatchGroup] { patch.groups ?? [] }

    /// Group the selected boxes (taking them out of any other group).
    func groupSelection() {
        let ids = patch.nodes.map(\.id).filter { selectedNodes.contains($0) }
        guard ids.count >= 2 else { return }
        var gs = groups.map { g -> PatchGroup in var g = g; g.members.removeAll { ids.contains($0) }; return g }
        gs.removeAll { $0.members.count < 2 }
        var k = gs.count + 1
        while gs.contains(where: { $0.name == "group \(k)" }) { k += 1 }
        gs.append(PatchGroup(name: "group \(k)", members: ids))
        patch.groups = gs
        scheduleAutosave()
    }

    /// The groups the selection touches.
    var selectedGroups: [PatchGroup] { groups.filter { $0.members.contains { selectedNodes.contains($0) } } }

    func ungroupSelection() {
        let hit = Set(selectedGroups.map(\.id))
        guard !hit.isEmpty else { return }
        patch.groups = groups.filter { !hit.contains($0.id) }
        scheduleAutosave()
    }

    func selectGroup(_ g: PatchGroup) {
        selectedNodes = Set(g.members)
        selectedCable = nil
    }

    func renameGroup(_ id: UUID, _ name: String) {
        guard var gs = patch.groups, let i = gs.firstIndex(where: { $0.id == id }) else { return }
        gs[i].name = name.isEmpty ? gs[i].name : name
        patch.groups = gs
        scheduleAutosave()
    }

    /// The backdrop rectangle of a group (canvas coordinates): its boxes plus a margin, with room for the name.
    func groupRect(_ g: PatchGroup) -> CGRect? {
        var r: CGRect?
        for id in g.members {
            guard let n = patch.nodes.first(where: { $0.id == id }), let spec = ModuleRegistry.spec(n.kind) else { continue }
            let b = CGRect(x: n.x, y: n.y, width: BoxLayout.width(n), height: BoxLayout.height(n, spec, hw))
            r = r.map { $0.union(b) } ?? b
        }
        return r.map { CGRect(x: $0.minX - 14, y: $0.minY - 30, width: $0.width + 28, height: $0.height + 44) }
    }

    /// Switch the selected boxes off — or, if they're all off already, back on.
    func bypassSelection() {
        let ids = patch.nodes.filter { selectedNodes.contains($0.id) && (ModuleRegistry.spec($0.kind)?.bypass ?? .none) != .none }
        guard !ids.isEmpty else { return }
        let allOff = ids.allSatisfy(\.bypassed)
        for n in ids where n.bypassed == allOff { toggleBypass(n.id) }
    }

    /// Move every selected box along with the one being dragged.
    private var groupDragStart: [UUID: CGPoint] = [:]
    func beginGroupDrag() {
        groupDragStart = Dictionary(uniqueKeysWithValues: patch.nodes.filter { selectedNodes.contains($0.id) }.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
    }
    func groupDrag(by d: CGSize) { dragMove(Set(groupDragStart.keys), by: d) }
    func endGroupDrag() { endDragMove(); groupDragStart = [:] }

    /// While boxes are dragged only this changes — the patch is written once, when they're let go.
    /// (Writing the patch on every pointer move made every box on screen rebuild itself each time.)
    let dragState = DragState()
    /// Where each box can be grabbed (box coordinates, unzoomed) — see DragZone.
    var dragZones: [UUID: [Int: CGRect]] = [:]
    /// The canvas is moving a box straight from the pointer: the boxes' own drag gestures stand aside.
    var nativeDrag = false
    private var nativeGroup = false, nativeID: UUID?

    /// The canvas's own box drags (from DragZones). `point` is in canvas-view coordinates.
    func nativeDragBegan(_ id: UUID) {
        nativeID = id
        nativeGroup = selectedNodes.contains(id) && selectedNodes.count > 1
        // selecting re-renders the box (its × button appears): done when it's let go, so the first movement
        // shows straight away instead of after that
        if nativeGroup { beginGroupDrag() }
    }
    func nativeDragMoved(by screen: CGSize, at point: CGPoint) {
        guard let id = nativeID else { return }
        let d = CGSize(width: screen.width / viewScale, height: screen.height / viewScale)
        if nativeGroup { groupDrag(by: d) } else {
            dragMove([id], by: d)
            updateInsertCandidate(for: id, at: point)
        }
    }
    func nativeDragEnded() {
        guard let id = nativeID else { return }
        nativeID = nil
        if nativeGroup { endGroupDrag() } else { endDragMove(); finishInsert(id); select(id) }
        nativeGroup = false
        scheduleAutosave()
    }
    func dragMove(_ ids: Set<UUID>, by d: CGSize) {
        if dragState.ids != ids { dragState.ids = ids }
        dragState.delta = d
        dragState.moved?()
    }
    func endDragMove() {
        let d = dragState.delta, ids = dragState.ids
        guard !ids.isEmpty else { return }
        var p = patch
        for i in p.nodes.indices where ids.contains(p.nodes[i].id) {
            p.nodes[i].x = max(-2000, (p.nodes[i].x + d.width).rounded())
            p.nodes[i].y = max(-2000, (p.nodes[i].y + d.height).rounded())
        }
        patch = p
        dragState.ids = []
        dragState.delta = .zero
    }

    func clearSelection() {
        selectedNodes = []
        selectedCable = nil
    }

    func moveNode(_ id: UUID, to p: CGPoint) {
        guard let i = patch.index(of: id) else { return }
        patch.nodes[i].x = max(-2000, p.x.rounded())
        patch.nodes[i].y = max(-2000, p.y.rounded())
    }

    /// Resize a box (canvas points). nil restores the module's default size.
    func resizeNode(_ id: UUID, width: CGFloat?, display: CGFloat?) {
        guard let i = patch.index(of: id) else { return }
        let n = patch.nodes[i]
        patch.nodes[i].w = width.map { Double(max($0, BoxLayout.defaultWidth(n)).rounded()) }
        patch.nodes[i].dh = display.map { Double(max($0, BoxLayout.defaultReadoutHeight(n)).rounded()) }
    }

    func toggleBypass(_ id: UUID) {
        guard let i = patch.index(of: id) else { return }
        patch.nodes[i].bypassed.toggle()
        let on = !patch.nodes[i].bypassed
        if on, let spec = ModuleRegistry.spec(patch.nodes[i].kind), spec.bypass == .through,
           !(host.node(id) is SampleBufferNode) {
            // switching an effect back on: start with empty buffers, not whatever it held when switched off
            host.renew(id, in: patch)
            restoreBuffers()
        } else {
            host.node(id)?.bypassed = patch.nodes[i].bypassed
        }
        scheduleAutosave()
    }

    // MARK: Drop a box onto a cable

    /// Cable(s) a dragged box would be inserted into (highlighted while dragging).
    @Published var insertCandidates: Set<UUID> = []

    private func bezierPoint(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        // same curve as the drawn cables (screen space)
        let d = min(140 * viewScale, max(30 * viewScale, abs(b.x - a.x) * 0.45 + abs(b.y - a.y) * 0.15))
        let c1 = CGPoint(x: a.x + d, y: a.y), c2 = CGPoint(x: b.x - d, y: b.y)
        let u = 1 - t
        return CGPoint(x: u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x,
                       y: u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y)
    }

    private func cableScreenEnds(_ c: PatchCable) -> (CGPoint, CGPoint)? {
        guard let ai = patch.index(of: c.fromNode), let bi = patch.index(of: c.toNode) else { return nil }
        let a = patch.nodes[ai], b = patch.nodes[bi]
        guard let sa = ModuleRegistry.spec(a.kind), let sb = ModuleRegistry.spec(b.kind),
              let dest = BoxLayout.destination(b, sb, hw, port: c.toPort) else { return nil }
        return (toScreen(BoxLayout.outlet(a, sa, hw, c.fromPort)), toScreen(dest))
    }

    /// While dragging box `id`, find an audio cable under the pointer it could be inserted into.
    func updateInsertCandidate(for id: UUID, at screen: CGPoint) {
        guard let n = patch.nodes.first(where: { $0.id == id }), let spec = ModuleRegistry.spec(n.kind),
              !spec.inputs.isEmpty, !spec.outputs.isEmpty,
              !patch.cables.contains(where: { $0.fromNode == id || $0.toNode == id }) else {
            if !insertCandidates.isEmpty { insertCandidates = [] }
            return
        }
        var best: (PatchCable, CGFloat)?
        for c in patch.cables where c.toPort < kParamPortBase {
            guard let (a, b) = cableScreenEnds(c) else { continue }
            for k in 0...32 {
                let q = bezierPoint(a, b, CGFloat(k) / 32)
                let d = hypot(q.x - screen.x, q.y - screen.y)
                if d < 26 && d < (best?.1 ?? .infinity) { best = (c, d) }
            }
        }
        guard let (c, _) = best else { if !insertCandidates.isEmpty { insertCandidates = [] }; return }
        // a stereo pair between the same two boxes goes through together
        let pair = patch.cables.filter { $0.fromNode == c.fromNode && $0.toNode == c.toNode && $0.toPort < kParamPortBase }
        let ids = Set(pair.map(\.id))
        if ids != insertCandidates { insertCandidates = ids }
    }

    /// Box `id` was dropped: wire it in between the highlighted cable(s).
    func finishInsert(_ id: UUID) {
        defer { insertCandidates = [] }
        guard !insertCandidates.isEmpty, let n = patch.nodes.first(where: { $0.id == id }),
              let spec = ModuleRegistry.spec(n.kind) else { return }
        let old = patch.cables.filter { insertCandidates.contains($0.id) }.sorted { $0.toPort < $1.toPort }
        guard !old.isEmpty else { return }
        // L / R — or A / B (scope): the second side of a stereo pair goes through the second channel
        let lIn = spec.inputs.firstIndex(of: "L") ?? 0
        let rIn = spec.inputs.firstIndex(of: "R") ?? spec.inputs.firstIndex(of: "B")
        let lOut = spec.outputs.firstIndex { $0.hasSuffix("L") } ?? 0
        let rOut = spec.outputs.firstIndex { $0.hasSuffix("R") } ?? spec.outputs.firstIndex(of: "B")
        func isRight(_ c: PatchCable, _ k: Int) -> Bool {
            if let a = patch.nodes.first(where: { $0.id == c.fromNode }), let sa = ModuleRegistry.spec(a.kind),
               c.fromPort < sa.outputs.count, sa.outputs[c.fromPort].hasSuffix("R") { return true }
            if let b = patch.nodes.first(where: { $0.id == c.toNode }), let sb = ModuleRegistry.spec(b.kind),
               c.toPort < sb.inputs.count, sb.inputs[c.toPort] == "R" { return true }
            return old.count > 1 && k > 0      // e.g. out 1 / 2: the second one is the right side
        }
        patch.cables.removeAll { insertCandidates.contains($0.id) }
        var made = Set<String>()
        for (k, c) in old.enumerated() {
            let right = isRight(c, k)
            let inP = right ? (rIn ?? lIn) : lIn
            let outP = right ? (rOut ?? lOut) : lOut
            let inKey = "\(c.fromNode)-\(c.fromPort)-\(inP)"
            if !made.contains(inKey) {
                patch.cables.append(PatchCable(fromNode: c.fromNode, fromPort: c.fromPort, toNode: id, toPort: inP))
                made.insert(inKey)
            }
            patch.cables.append(PatchCable(fromNode: id, fromPort: outP, toNode: c.toNode, toPort: c.toPort))
        }
        topologyChanged()
    }

    // MARK: Layout helpers

    var allCollapsed: Bool { !patch.nodes.isEmpty && patch.nodes.allSatisfy { $0.collapsed } }

    /// Collapse every box, or expand them all if they're all collapsed already.
    func toggleCollapseAll() {
        let target = !allCollapsed
        for i in patch.nodes.indices { patch.nodes[i].collapsed = target }
        scheduleAutosave()
    }

    private var layoutTimer: Timer?

    /// Tidy: signal flow left → right, chains kept in order and lined up, controllers in a row on top,
    /// unpatched boxes underneath, notes travel with their box (TidyLayout). Glides into place.
    func tidy() {
        isZooming = false
        guard !patch.nodes.isEmpty else { return }
        animateLayout(to: TidyLayout.layout(patch, hw))
        viewOffset = CGSize(width: 20, height: 20)
    }

    private func animateLayout(to target: [UUID: CGPoint]) {
        layoutTimer?.invalidate()
        let start = Dictionary(uniqueKeysWithValues: patch.nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        let steps = 18
        var step = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                step += 1
                let u = Double(step) / Double(steps)
                let e = 1 - pow(1 - u, 3)              // ease out
                for i in self.patch.nodes.indices {
                    let id = self.patch.nodes[i].id
                    guard let a = start[id], let b = target[id] else { continue }
                    self.patch.nodes[i].x = a.x + (b.x - a.x) * e
                    self.patch.nodes[i].y = a.y + (b.y - a.y) * e
                }
                if step >= steps { timer.invalidate(); self.scheduleAutosave() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        layoutTimer = t
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = patch.index(of: id) else { return }
        patch.nodes[i].collapsed.toggle()
        scheduleAutosave()
    }

    func setParam(_ id: UUID, _ index: Int, _ value: Float, linked: Bool = true) {
        guard let i = patch.index(of: id), let spec = ModuleRegistry.spec(patch.nodes[i].kind),
              index < spec.params.count else { return }
        let key = spec.params[index].key
        // dragging a choice row sends the same value many times — only real changes do anything
        // (each change redraws the patch, so this matters on a big one)
        if !spec.params[index].isTrigger, (patch.nodes[i].params[key] ?? spec.params[index].def) == value { return }
        defer { if linked { syncLinked(id, spec, index, value) } }
        if spec.kind == "chord", let mi = spec.paramIndex("mode") {
            // picking a chord type means "free"; a degree / size / scale means "in key" — so the change is heard
            let wants: Float? = key == "type" ? 1 : (["degree", "size", "scale"].contains(key) ? 0 : nil)
            if let w = wants, (patch.nodes[i].params["mode"] ?? spec.params[mi].def) != w {
                patch.nodes[i].params["mode"] = w
                host.node(id)?.base[mi] = w
            }
        }
        if spec.kind == "seq", key == "len", let seq = host.node(id) as? SeqNode {
            // growing past the old length: the new steps start as copies of the pattern (16 → 32 plays it twice)
            let old = SeqNode.length(patch.nodes[i].params[key] ?? spec.params[index].def), new = SeqNode.length(value)
            if new > old {
                for k in old..<new { seq.pitches[k] = seq.pitches[k % old]; seq.gates[k] = seq.gates[k % old] }
                patch.nodes[i].data["pitch"] = (0..<SeqNode.steps).map { seq.pitches[$0] }
                patch.nodes[i].data["gate"] = (0..<SeqNode.steps).map { seq.gates[$0] }
            }
        }
        if key == "div", Self.patternKinds.contains(spec.kind) {
            rescalePattern(id, spec, from: patch.nodes[i].params[key] ?? spec.params[index].def, to: value)
        }
        if autoRecording.contains(id) && !spec.params[index].isTrigger {
            recordAutomation(id, index, value, previous: patch.nodes[i].params[key] ?? spec.params[index].def)
        }
        patch.nodes[i].params[key] = value
        host.node(id)?.base[index] = value
        followSync(i, id, spec, key)
        switch (spec.kind, key) {
        case ("sampler", "sens"):
            scheduleAnalysis(id)
        case ("peq", "bands"):
            // spread the active bands across the spectrum when switching 3 / 5 / 8
            let n = ParametricEQ.bandCount(value)
            for (b, f) in ParametricEQ.defaultFrequencies(n).enumerated() {
                let fi = ParametricEQ.freqIndex(b), qi = ParametricEQ.qIndex(b)
                let q: Float = (b == 0 || b == n - 1) ? 0.7 : 1
                patch.nodes[i].params[spec.params[fi].key] = f
                patch.nodes[i].params[spec.params[qi].key] = q
                host.node(id)?.base[fi] = f
                host.node(id)?.base[qi] = q
            }
        default: break
        }
        scheduleAutosave()
    }

    // MARK: Automation (hold the header's record icon and move things: the box's changes loop for 4 bars)

    /// Boxes whose automation record button is held (or latched).
    @Published private(set) var autoRecording: Set<UUID> = []
    /// Per recording box: parameter → last lane slot written.
    private var autoTouched: [UUID: [Int: Int]] = [:]
    private var autoTimer: Timer?

    func hasAutomation(_ node: PatchNode) -> Bool { node.data.keys.contains { $0.hasPrefix("auto.") } }

    func isAutomated(_ node: PatchNode, _ index: Int, _ spec: ModuleSpec) -> Bool {
        index < spec.params.count && node.data[DSPNode.autoKey(spec.params[index].key)] != nil
    }

    /// Only boxes with something to automate get the icons.
    func canAutomate(_ spec: ModuleSpec) -> Bool {
        spec.kind != "out" && spec.kind != "in" && spec.params.contains { !$0.isTrigger }   // not on the hardware boxes
    }

    func startAutoRecord(_ id: UUID) {
        guard !autoRecording.contains(id), host.node(id) != nil else { return }
        autoRecording.insert(id)
        (host.node(id) as? KeysNode)?.recordingKeys = true      // keys: the notes you play are recorded too
        autoTouched[id] = [:]
        if autoTimer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            autoTimer = t
        }
    }

    /// Release: the touched lanes go into the patch (one undo step) and start playing back.
    func stopAutoRecord(_ id: UUID) {
        guard autoRecording.contains(id) else { return }
        autoTick()
        autoRecording.remove(id)
        let touched = autoTouched.removeValue(forKey: id) ?? [:]
        if autoRecording.isEmpty { autoTimer?.invalidate(); autoTimer = nil }
        guard let n = host.node(id), let i = patch.index(of: id) else { return }
        if let k = n as? KeysNode {
            k.recordingKeys = false
            if k.recordedKeys {
                k.recordedKeys = false
                patch.nodes[i].data[KeysNode.laneKey] = Array(UnsafeBufferPointer(start: k.keyLane, count: DSPNode.autoSlots))
                scheduleAutosave()
            }
        }
        for p in touched.keys {
            let lane = Array(UnsafeBufferPointer(start: n.autoLane + p * DSPNode.autoSlots, count: DSPNode.autoSlots))
            patch.nodes[i].data[DSPNode.autoKey(n.spec.params[p].key)] = lane
            n.autoHold[p] = false
        }
        if !touched.isEmpty { scheduleAutosave() }
    }

    /// Reset: every lane of the box goes; parameters stay where they are now.
    func clearAutomation(_ id: UUID) {
        guard let i = patch.index(of: id) else { return }
        if autoRecording.contains(id) { stopAutoRecord(id) }
        let n = host.node(id)
        // leave each parameter at the value it is playing right now
        if let n, let spec = ModuleRegistry.spec(patch.nodes[i].kind) {
            for (k, p) in spec.params.enumerated() where n.autoOn[k] && !p.isTrigger {
                let v = n.params[k]
                if v.isFinite { patch.nodes[i].params[p.key] = v; n.base[k] = v }
            }
        }
        patch.nodes[i].data = patch.nodes[i].data.filter { !$0.key.hasPrefix("auto.") }
        n?.loadAutomation(patch.nodes[i].data)
        if let n { for (key, start) in n.defaultData where key.hasPrefix("auto.") { n.setData(key, start) } }   // keys notes
        scheduleAutosave()
    }

    private func recordAutomation(_ id: UUID, _ index: Int, _ value: Float, previous: Float) {
        guard let n = host.node(id) else { return }
        let slot = min(Int(n.autoPosition), DSPNode.autoSlots - 1)
        let lane = n.autoLane + index * DSPNode.autoSlots
        if autoTouched[id]?[index] == nil {
            // first touch: a new lane starts out holding the value the parameter had
            if !n.autoOn[index] {
                lane.update(repeating: previous, count: DSPNode.autoSlots)
                n.autoOn[index] = true
                n.autoCount += 1
            }
            n.autoHold[index] = true
            autoTouched[id, default: [:]][index] = slot
        }
        lane[slot] = value
    }

    /// While recording: every touched parameter keeps writing its current value as the loop moves on.
    private func autoTick() {
        for id in autoRecording {
            guard let n = host.node(id), let touched = autoTouched[id] else { continue }
            let cur = min(Int(n.autoPosition), DSPNode.autoSlots - 1)
            for (p, last) in touched {
                let lane = n.autoLane + p * DSPNode.autoSlots
                let v = n.base[p]
                var k = last, guardCount = 0
                while k != cur && guardCount < DSPNode.autoSlots {
                    k = (k + 1) % DSPNode.autoSlots
                    lane[k] = v
                    guardCount += 1
                }
                lane[cur] = v
                autoTouched[id]?[p] = cur
            }
        }
    }

    /// Drum rolls / piano roll: the clear (bin) button in the title bar. Undo brings the pattern back.
    static let patternKinds: Set<String> = ["rack", "drumsynth", "drums", "roll"]
    func clearPattern(_ id: UUID) {
        guard let n = patch.nodes.first(where: { $0.id == id }) else { return }
        switch n.kind {
        case "rack": setData(id, "hits", [Float](repeating: 0, count: RackLayout.pads * RackLayout.steps))
        case "drumsynth": setData(id, "hits", [Float](repeating: 0, count: DrumSynthLayout.voices * DrumSynthLayout.steps))
        case "drums": setData(id, "hits", [Float](repeating: 0, count: DrumsNode.steps * DrumsNode.lanes))
        case "roll": setData(id, "grid", [Float](repeating: 0, count: RollNode.steps * RollNode.rows))
        default: break
        }
    }

    /// A slide across the division row starts from one snapshot, so passing 1/16T on the way from
    /// 1/16 to 1/32 doesn't smear the pattern.
    private var rescaleBase: [UUID: (div: Float, values: [Float], len: Int)] = [:]
    private var rescaleEnd: [UUID: DispatchWorkItem] = [:]

    /// A drum / piano roll's division changed: keep the pattern in time (length and steps follow).
    private func rescalePattern(_ id: UUID, _ spec: ModuleSpec, from old: Float, to new: Float) {
        guard let n = host.node(id), let i = patch.index(of: id), let li = spec.paramIndex("len") else { return }
        let (key, lanes, empty, ptr): (String, Int, Float, UnsafeMutablePointer<Float>)
        switch n {
        case let r as RackNode: (key, lanes, empty, ptr) = ("hits", RackLayout.pads, 0, r.hits)
        case let d as DrumSynthNode: (key, lanes, empty, ptr) = ("hits", DrumSynthLayout.voices, 0, d.hits)
        case let d as DrumsNode: (key, lanes, empty, ptr) = ("hits", DrumsNode.lanes, 0, d.hits)
        case let r as RollNode: (key, lanes, empty, ptr) = ("grid", RollNode.rows, 0, r.grid)
        default: return
        }
        let steps = 32
        if rescaleBase[id] == nil {
            let len = Int((patch.nodes[i].params["len"] ?? spec.params[li].def).rounded())
            rescaleBase[id] = (old, Array(UnsafeBufferPointer(start: ptr, count: lanes * steps)), len)
        }
        guard let base = rescaleBase[id] else { return }
        let r = PatternRescale.rescale(base.values, lanes: lanes, steps: steps, length: base.len,
                                       fromDivision: base.div, toDivision: new, empty: empty)
        setData(id, key, r.values, step: false)
        patch.nodes[i].params["len"] = Float(r.length)
        n.base[li] = Float(r.length)
        rescaleEnd[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rescaleBase[id] = nil } }
        rescaleEnd[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// The coloured frame around a box (nil = none). One undo step.
    static let highlightColours: [(name: String, hex: String)] = [
        ("red", "#e5484d"), ("orange", "#f76b15"), ("yellow", "#ffc53d"), ("green", "#30a46c"),
        ("teal", "#12a594"), ("blue", "#0090ff"), ("purple", "#8e4ec6"), ("pink", "#e93d82")]
    func setHighlight(_ id: UUID, _ hex: String?) {
        guard let i = patch.index(of: id), patch.nodes[i].highlight != hex else { return }
        checkpoint()
        patch.nodes[i].highlight = hex
        checkpoint()
        scheduleAutosave()
    }

    /// text boxes
    func setText(_ id: UUID, _ text: String) {
        guard let i = patch.index(of: id) else { return }
        patch.nodes[i].text = text.isEmpty ? nil : text
        scheduleAutosave()
    }

    /// Boxes with sync / division / a free time or rate (delay, lfo, tremolo …): moving the division
    /// switches sync on, moving the free time / rate switches it off — no separate trip to the sync row.
    static let freeTimingKeys: Set<String> = ["time", "rate"]
    private func followSync(_ i: Int, _ id: UUID, _ spec: ModuleSpec, _ key: String) {
        guard let si = spec.paramIndex("sync"), spec.paramIndex("div") != nil,
              key == "div" || (Self.freeTimingKeys.contains(key) && Self.freeTimingKeys.contains(where: { spec.paramIndex($0) != nil }))
        else { return }
        let want: Float = key == "div" ? 1 : 0
        guard patch.nodes[i].params["sync"] ?? spec.params[si].def != want else { return }
        patch.nodes[i].params["sync"] = want
        host.node(id)?.base[si] = want
    }

    /// Save a module's pattern/step array (and hand it to the running module).
    /// Pattern edits (a tap or a painted stroke on a roll, the bin) arrive once, when the finger lifts, so
    /// each is its own undo step straight away — quick taps don't merge. A knob still settling is committed
    /// first, as its own step. `step: false` (sliding the division) leaves it to the usual pause instead.
    func setData(_ id: UUID, _ key: String, _ values: [Float], step: Bool = true) {
        setData(id, [key: values], step: step)
    }

    /// Several arrays from one edit (seq pitch + gate): one undo step.
    func setData(_ id: UUID, _ entries: [String: [Float]], step: Bool = true) {
        guard let i = patch.index(of: id) else { return }
        if step && !restoringHistory { checkpoint() }
        for (key, values) in entries {
            patch.nodes[i].data[key] = values
            host.node(id)?.setData(key, values)
        }
        if step && !restoringHistory { checkpoint() }
        scheduleAutosave()
    }

    func value(_ node: PatchNode, _ index: Int, _ spec: ModuleSpec) -> Float {
        node.params[spec.params[index].key] ?? spec.params[index].def
    }

    func fire(_ id: UUID, _ index: Int) {
        host.node(id)?.base[index] = 1
    }

    /// A parameter shows the modulation marker only for real modulation — a slider / knob patched into it
    /// is the same control as its own row, so the row itself moves instead.
    /// A fingerprint of what box `id` shows besides its own settings: its cables, selection, audio on / off.
    func boxRev(_ id: UUID) -> Int {
        var h = Hasher()
        for c in patch.cables where c.fromNode == id || c.toNode == id { h.combine(c) }
        h.combine(selectedNodes.contains(id)); h.combine(isRunning); h.combine(hw.inputs); h.combine(hw.outputs)
        return h.finalize()
    }

    func isModulated(_ id: UUID, _ param: Int) -> Bool {
        patch.cables.contains { c in
            c.toNode == id && c.toPort == kParamPortBase + param && !isControlNode(c.fromNode)
        }
    }

    private func isControlNode(_ id: UUID) -> Bool { ControlLink.isControl(patch, id) }

    /// slider / knob and the parameters they're patched into are locked together, both ways
    /// (rules in ControlLink, which the self-test checks).
    private func syncLinked(_ id: UUID, _ spec: ModuleSpec, _ index: Int, _ value: Float) {
        for u in ControlLink.updates(patch, changed: id, index: index, value: value) {
            setParam(u.node, u.index, u.value, linked: false)
        }
    }

    func isPortConnected(_ id: UUID, port: Int, output: Bool) -> Bool {
        output ? patch.cables.contains { $0.fromNode == id && $0.fromPort == port }
               : patch.cables.contains { $0.toNode == id && $0.toPort == port }
    }

    // MARK: Cables

    func finishCable(at screen: CGPoint) {
        defer { pendingCable = nil }
        guard let pc = pendingCable else { return }
        let p = toCanvas(screen)
        let radius = 24 / viewScale
        var best: (node: UUID, port: Int, d: CGFloat)?
        func consider(_ id: UUID, _ port: Int, _ q: CGPoint?) {
            guard let q else { return }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < radius && d < (best?.d ?? .infinity) { best = (id, port, d) }
        }
        for n in patch.nodes where n.id != pc.node {
            guard let spec = ModuleRegistry.spec(n.kind) else { continue }
            let ports = BoxLayout.ports(n, spec, hw)
            if n.collapsed {
                // collapsed boxes only accept drops on the ports they still show
                if pc.fromOutput {
                    for k in BoxLayout.collapsedLeft(n, spec) { consider(n.id, k, BoxLayout.destination(n, spec, hw, port: k)) }
                } else {
                    for k in BoxLayout.collapsedRight(n, spec) { consider(n.id, k, BoxLayout.outlet(n, spec, hw, k)) }
                }
                continue
            }
            if pc.fromOutput {
                for k in ports.ins.indices { consider(n.id, k, BoxLayout.inlet(n, spec, hw, k)) }
                if !n.collapsed {
                    for k in BoxLayout.rowParams(spec, n) {
                        consider(n.id, kParamPortBase + k, BoxLayout.paramInlet(n, spec, hw, k))
                    }
                }
            } else {
                for k in ports.outs.indices { consider(n.id, k, BoxLayout.outlet(n, spec, hw, k)) }
            }
        }
        guard let b = best else { return }
        if pc.fromOutput {
            connect(from: pc.node, pc.port, to: b.node, b.port)
        } else {
            connect(from: b.node, b.port, to: pc.node, pc.port)
        }
    }

    func connect(from a: UUID, _ ap: Int, to b: UUID, _ bp: Int) {
        var bp = bp
        // a fader / knob dropped on a mixer's channel inlet means "this controls that channel":
        // it links to the channel's level (a steady voltage into an audio inlet would do nothing audible)
        if isControlNode(a), bp < kParamPortBase, bp < MixerLayout.maxChannels,
           patch.nodes.first(where: { $0.id == b })?.kind == "mix",
           let level = ModuleRegistry.spec("mix")?.paramIndex("g\(bp + 1)") {
            bp = kParamPortBase + level
        }
        guard !patch.cables.contains(where: { $0.fromNode == a && $0.fromPort == ap && $0.toNode == b && $0.toPort == bp })
        else { return }
        patch.cables.append(PatchCable(fromNode: a, fromPort: ap, toNode: b, toPort: bp))
        // patching a fader / knob into a parameter: it picks up where the parameter is, so nothing jumps
        if isControlNode(a), bp >= kParamPortBase,
           let t = patch.nodes.first(where: { $0.id == b }), let ts = ModuleRegistry.spec(t.kind) {
            let pi = bp - kParamPortBase
            if pi < ts.params.count && !ts.params[pi].isTrigger {
                setParam(a, ControlsLayout.valueIndex(ap), ts.params[pi].normalized(value(t, pi, ts)), linked: false)
            }
        }
        topologyChanged()
    }

    // MARK: Patch files

    /// New: a fresh copy of your default patch (its audio comes along), or the built-in starter.
    func newPatch() {
        guard let saved = PatchStore.loadUserDefault() else { load(DefaultPatch.builtIn()); return }
        let (p, map) = saved.withFreshIDs()
        let fm = FileManager.default, src = PatchStore.defaultAudioDirectory, dst = Self.samplesDirectory
        for (old, new) in map {
            for (a, b) in audioFileNames(old).map({ ($0, $0.replacingOccurrences(of: old.uuidString, with: new.uuidString)) }) {
                let from = src.appendingPathComponent(a), to = dst.appendingPathComponent(b)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.removeItem(at: to)
                try? fm.copyItem(at: from, to: to)
            }
        }
        load(p)
    }

    @Published private(set) var hasUserDefault = PatchStore.hasUserDefault

    /// more → Set as default: New starts from this patch from now on (audio included).
    func setAsDefault() {
        flushBuffersToDisk()
        let fm = FileManager.default, dir = PatchStore.defaultAudioDirectory
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        for n in patch.nodes {
            for name in audioFileNames(n.id) {
                let from = Self.samplesDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.copyItem(at: from, to: dir.appendingPathComponent(name))
            }
        }
        if let data = try? PatchStore.encode(patch) { try? data.write(to: PatchStore.defaultURL, options: .atomic) }
        hasUserDefault = PatchStore.hasUserDefault
    }

    /// more → Reset default: New goes back to the built-in starter.
    func resetDefault() {
        let fm = FileManager.default
        try? fm.removeItem(at: PatchStore.defaultURL)
        try? fm.removeItem(at: PatchStore.defaultAudioDirectory)
        hasUserDefault = PatchStore.hasUserDefault
    }

    /// The audio files a box can own (buffer, rack pads and their names).
    private func audioFileNames(_ id: UUID) -> [String] {
        ["\(id.uuidString).caf"] + (0..<RackLayout.pads).flatMap { ["\(id.uuidString)-pad\($0).caf", "\(id.uuidString)-pad\($0).txt"] }
    }

    func load(_ p: Patch) {
        patch = p
        clearSelection()
        topologyChanged()
    }

    // MARK: Undo / redo

    var canUndo: Bool { history.canUndo || patch != history.committed }
    var canRedo: Bool { history.canRedo && patch == history.committed }

    /// Commit the current patch as an undo step once edits pause (a whole drag = one step).
    private func scheduleCheckpoint() {
        checkpointWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkpoint() } }
        checkpointWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func checkpoint() {
        checkpointWork?.cancel()
        checkpointWork = nil
        history.commit(patch)
    }

    func undo() {
        checkpoint()                                  // an edit still settling counts as the step to undo
        guard let p = history.undo() else { return }
        restore(p)
    }

    func redo() {
        checkpoint()
        guard let p = history.redo() else { return }
        restore(p)
    }

    private func restore(_ p: Patch) {
        restoringHistory = true
        defer { restoringHistory = false }
        patch = p
        selectedNodes = selectedNodes.filter { id in p.nodes.contains { $0.id == id } }
        selectedCable = nil
        pendingCable = nil
        topologyChanged()
        history.reset(to: patch, keepHistory: true)  // linked controls may normalise it: not a new step
    }

    /// clock: whether its clock inlet had a cable last time we looked.
    private var clockInletPatched: [UUID: Bool] = [:]

    /// Patching into a clock's clock inlet switches it to external; taking the cable out, back to internal.
    private func followClockInputs() {
        var seen: [UUID: Bool] = [:]
        for i in patch.nodes.indices where patch.nodes[i].kind == "clock" {
            let id = patch.nodes[i].id
            let patched = patch.cables.contains { $0.toNode == id && $0.toPort == 0 }
            if !restoringHistory, let was = clockInletPatched[id], was != patched {
                patch.nodes[i].params["source"] = patched ? 0 : 1
            }
            seen[id] = patched
        }
        clockInletPatched = seen
    }

    private func topologyChanged() {
        followClockInputs()
        patch = ControlLink.reconciled(patch)      // linked rows show what the faders / knobs set
        host.load(patch)
        restoreBuffers()
        scheduleAutosave()
    }

    // MARK: Audio buffers (looper / sampler / stretch)

    static var samplesDirectory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("polje nieuk/Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sampleURL(_ id: UUID) -> URL { Self.samplesDirectory.appendingPathComponent("\(id.uuidString).caf") }

    /// Give freshly created buffer modules back the audio they had last time.
    private func restoreBuffers() {
        restoreRacks()
        for n in patch.nodes {
            guard let dsp = host.node(n.id), let b = dsp as? SampleBufferNode,
                  seenVersion[ObjectIdentifier(dsp)] == nil else { continue }
            seenVersion[ObjectIdentifier(dsp)] = b.contentVersion
            let url = sampleURL(n.id)
            guard FileManager.default.fileExists(atPath: url.path),
                  let audio = try? AudioFiles.read(url, sampleRate: host.sampleRate, maxSeconds: 120) else { continue }
            b.load(audio)
            (dsp as? SamplerNode)?.analyze()
            seenVersion[ObjectIdentifier(dsp)] = b.contentVersion
        }
    }

    /// Polled 4× a second: after a recording/overdub/load finishes, re-slice and save to disk.
    /// Write every buffer's audio now (not on the next poll), e.g. before Set as default copies the files.
    private func flushBuffersToDisk() {
        for n in patch.nodes {
            guard let dsp = host.node(n.id), let b = dsp as? SampleBufferNode, !b.waveRecording else { continue }
            let audio = b.snapshot(), url = sampleURL(n.id)
            if audio.isEmpty { try? FileManager.default.removeItem(at: url) }
            else { try? AudioFiles.write(audio, sampleRate: host.sampleRate, to: url) }
            seenVersion[ObjectIdentifier(dsp)] = b.contentVersion
        }
    }

    private func watchBuffers() {
        let sr = host.sampleRate
        for n in patch.nodes {
            guard let dsp = host.node(n.id), let b = dsp as? SampleBufferNode, !b.waveRecording else { continue }
            let key = ObjectIdentifier(dsp)
            guard seenVersion[key] != b.contentVersion else { continue }
            seenVersion[key] = b.contentVersion
            (dsp as? SamplerNode)?.analyze()
            let audio = b.snapshot(), url = sampleURL(n.id)
            DispatchQueue.global(qos: .utility).async {
                if audio.isEmpty { try? FileManager.default.removeItem(at: url) }
                else { try? AudioFiles.write(audio, sampleRate: sr, to: url) }
            }
        }
    }

    func loadAudio(from url: URL) {
        guard let id = importDestination else { return }
        audioImportTarget = nil
        loadAudio(url, into: id)
    }

    /// Loads an audio file into a looper / sampler / stretch (file picker, browser drag, or Finder drop).
    @discardableResult
    // MARK: rack pads

    /// Where a rack's pad sample (and its name) is kept.
    private func padURL(_ id: UUID, _ k: Int) -> URL { Self.samplesDirectory.appendingPathComponent("\(id.uuidString)-pad\(k).caf") }
    private func padNameURL(_ id: UUID, _ k: Int) -> URL { Self.samplesDirectory.appendingPathComponent("\(id.uuidString)-pad\(k).txt") }
    private var restoredRacks: Set<ObjectIdentifier> = []

    /// Load audio files into rack pads, from pad `k` on (several files fill the next pads). Reading, resampling
    /// and saving the copy happen in the background; the drop returns at once (it used to freeze the app until the
    /// file was decoded).
    @discardableResult
    func loadPads(_ id: UUID, from k: Int, _ urls: [URL]) -> Bool {
        guard host.node(id) is RackNode, !urls.isEmpty, k >= 0, k < RackLayout.pads else { return false }
        let jobs = Array(urls.prefix(RackLayout.pads - k).enumerated().map { (k + $0.offset, $0.element) })
        let sr = host.sampleRate
        let padFiles = jobs.map { (padURL(id, $0.0), padNameURL(id, $0.0)) }
        loadingPads[id, default: []].formUnion(jobs.map(\.0))
        DispatchQueue.global(qos: .userInitiated).async {
            for (n, (pad, url)) in jobs.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                let result = Result { try AudioFiles.read(url, sampleRate: sr, maxSeconds: 20) }
                if scoped { url.stopAccessingSecurityScopedResource() }
                let name = url.deletingPathExtension().lastPathComponent
                if case .success(let audio) = result, !audio.isEmpty {
                    try? AudioFiles.write(audio, sampleRate: sr, to: padFiles[n].0)
                    try? name.write(to: padFiles[n].1, atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadingPads[id]?.remove(pad)
                    switch result {
                    case .success(let audio) where !audio.isEmpty:
                        (self.host.node(id) as? RackNode)?.load(pad: pad, audio, name: name)
                        self.audioError = nil
                        if n == 0, let spec = ModuleRegistry.spec("rack"), let i = spec.paramIndex("sel") { self.setParam(id, i, Float(pad)) }
                    case .success:
                        self.audioError = "\(url.lastPathComponent) has no audio."
                    case .failure(let e):
                        self.audioError = "Couldn't read \(url.lastPathComponent): \(e.localizedDescription)"
                    }
                    self.objectWillChange.send()
                }
            }
        }
        return true
    }
    @discardableResult
    func loadPad(_ id: UUID, _ k: Int, from url: URL) -> Bool { loadPads(id, from: k, [url]) }
    /// rack pads whose sample is being read (the pad shows "loading…").
    @Published var loadingPads: [UUID: Set<Int>] = [:]

    /// Back to the built-in sound on pad `k`.
    func resetPad(_ id: UUID, _ k: Int) {
        guard let rack = host.node(id) as? RackNode else { return }
        rack.resetPad(k)
        try? FileManager.default.removeItem(at: padURL(id, k))
        try? FileManager.default.removeItem(at: padNameURL(id, k))
        objectWillChange.send()
    }

    /// Load each rack's saved pad samples once (when its engine node is created).
    private func restoreRacks() {
        for n in patch.nodes where n.kind == "rack" {
            guard let rack = host.node(n.id) as? RackNode, !restoredRacks.contains(ObjectIdentifier(rack)) else { continue }
            restoredRacks.insert(ObjectIdentifier(rack))
            for k in 0..<RackLayout.pads {
                let url = padURL(n.id, k)
                guard FileManager.default.fileExists(atPath: url.path),
                      let audio = try? AudioFiles.read(url, sampleRate: host.sampleRate, maxSeconds: 20) else { continue }
                let name = (try? String(contentsOf: padNameURL(n.id, k), encoding: .utf8)) ?? "sample"
                rack.load(pad: k, audio, name: name)
            }
        }
    }

    /// A copied rack gets the same pad samples.
    private func copyRackPads(from a: UUID, to b: UUID) {
        guard host.node(a) is RackNode, let rb = host.node(b) as? RackNode else { return }
        for k in 0..<RackLayout.pads {
            let src = padURL(a, k)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: padURL(b, k))
            try? FileManager.default.copyItem(at: padNameURL(a, k), to: padNameURL(b, k))
            if let audio = try? AudioFiles.read(src, sampleRate: host.sampleRate, maxSeconds: 20) {
                rb.load(pad: k, audio, name: (try? String(contentsOf: padNameURL(a, k), encoding: .utf8)) ?? "sample")
            }
        }
    }

    func loadAudio(_ url: URL, into id: UUID) -> Bool {
        guard let b = host.node(id) as? SampleBufferNode else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let audio = try AudioFiles.read(url, sampleRate: host.sampleRate,
                                            maxSeconds: Double(b.bufferCapacity) / host.sampleRate)
            guard !audio.isEmpty else { audioError = "That file has no audio."; return false }
            b.load(audio)
            audioError = nil
            return true
        } catch {
            audioError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// Click a file in the browser: load it into the selected looper / sampler / stretch.
    func loadIntoSelection(_ url: URL) {
        if let rackID = selectedNodes.first(where: { host.node($0) is RackNode }),
           let n = patch.nodes.first(where: { $0.id == rackID }) {
            loadPad(rackID, Int((n.params["sel"] ?? 0).rounded()), from: url)
            return
        }
        guard let id = selectedNodes.first(where: { host.node($0) is SampleBufferNode }) else {
            audioError = "Select a looper, sampler, stretch or rack first — or drag the file onto one (or onto a rack pad)."
            return
        }
        loadAudio(url, into: id)
    }

    // MARK: Cable re-patching

    /// Grab the most recent cable plugged into an inlet: it comes off and follows the pointer from its source.
    func pickUpCable(into node: UUID, port: Int, at point: CGPoint) -> Bool {
        guard let c = patch.cables.last(where: { $0.toNode == node && $0.toPort == port }) else { return false }
        patch.cables.removeAll { $0.id == c.id }
        topologyChanged()
        pendingCable = PendingCable(node: c.fromNode, port: c.fromPort, fromOutput: true, point: point)
        return true
    }

    func copyBuffer(from src: UUID, to dst: UUID) {
        guard let a = host.node(src) as? SampleBufferNode, let b = host.node(dst) as? SampleBufferNode else { return }
        let audio = a.snapshot()
        guard !audio.isEmpty else { audioError = "That module has no audio yet."; return }
        b.load(audio.prefix(b.bufferCapacity))
    }

    /// "looper 2" style names, for menus.
    func label(for n: PatchNode) -> String {
        let name = ModuleRegistry.spec(n.kind)?.name ?? n.kind
        let same = patch.nodes.filter { $0.kind == n.kind }
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == n.id }) else { return name }
        return "\(name) \(i + 1)"
    }

    /// Tap on a sampler waveform: play the slice under the finger.
    func audition(_ id: UUID, at x: Double) {
        guard let s = host.node(id) as? SamplerNode else { return }
        s.auditionSlice = s.slice(at: x)
    }

    private func scheduleAnalysis(_ id: UUID) {
        analyzeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { (self?.host.node(id) as? SamplerNode)?.analyze() }
        }
        analyzeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func scheduleAutosave() {
        autosaveWork?.cancel()
        let snapshot = patch
        let work = DispatchWorkItem { PatchStore.saveAutosave(snapshot) }
        autosaveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Pan and zoom of the canvas (see AppModel.viewport).
@MainActor
/// Where the boxes' layer was last laid out (NodesHost): its zoom, which that layer redraws at, and its
/// pan offset, which places it. Between those moments pan / zoom only move it as a picture.
final class HostedZoom: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    /// how far the layer reaches past the window on each side
    @Published var margin: CGFloat = 600
}

/// Boxes being dragged and how far (canvas points): only the dragged boxes and their cables follow it.
final class DragState: ObservableObject {
    @Published var ids: Set<UUID> = []
    @Published var delta: CGSize = .zero
    /// The boxes' container moves the dragged boxes right here, in the same step as the pointer event
    /// (going through a queued notification put them a frame or more behind the pointer).
    var moved: (() -> Void)?
    func offset(_ id: UUID) -> CGSize { ids.contains(id) ? delta : .zero }
}

final class Viewport: ObservableObject {
    @Published var offset: CGSize
    @Published var scale: CGFloat
    init(offset: CGSize, scale: CGFloat) { self.offset = offset; self.scale = scale }
}
