import SwiftUI
import AVFoundation
import PoljeNieukCore

/// The file browser, like a DAW's: Places (your drive — home, Desktop, Documents, Downloads, Music,
/// iCloud Drive, every mounted drive — on Mac; this iPad's folders on iPad), your own Collections, and a
/// search box. Folders open as deep as you like; only audio files are listed. ▶ previews a file;
/// drag it onto a looper / sampler / stretch, or select one of those and click the file.
struct FileBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var refresh = 0
    @StateObject private var search = FileSearch()
    @StateObject private var preview = FilePreview.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("browser").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { model.addingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .help("Add a folder to Collections")
            }
            .buttonStyle(.borderless)
            .font(Theme.mono)
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // search: every place and collection, audio files whose name contains the text
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(Theme.dim)
                TextField("search", text: $search.query)
                    .textFieldStyle(.plain).font(Theme.mono).foregroundStyle(Theme.text)
                    .onSubmit { search.run(in: roots.map(\.url)) }
                    .onChange(of: search.query) { _, _ in search.run(in: roots.map(\.url)) }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.row))
            .padding(.horizontal, 8).padding(.vertical, 6)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !search.query.isEmpty {
                        searchResults
                    } else {
                        section("places")
                        ForEach(places, id: \.url) { p in
                            FolderNode(model: model, url: p.url, title: p.title, icon: p.icon, depth: 0, refresh: refresh, removable: false)
                        }
                        section("collections")
                        ForEach(model.browserFolders, id: \.self) { f in
                            FolderNode(model: model, url: f, title: f.lastPathComponent, icon: "folder", depth: 0, refresh: refresh, removable: true)
                        }
                        if model.browserFolders.isEmpty {
                            Button { model.addingFolder = true } label: {
                                Text("+ add a folder").font(Theme.monoSmall).foregroundStyle(Theme.dim)
                            }
                            .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 3)
                        }
                        Text("Drag a file onto a looper, sampler or stretch — or select one and click a file. ▶ previews.")
                            .font(Theme.monoSmall).foregroundStyle(Theme.faint)
                            .padding(10)
                    }
                }
            }
        }
        .frame(width: 260)
        .background(Theme.bar)
        .fileImporter(isPresented: $model.addingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addFolder(url) }
        }
        .onDisappear { preview.stop() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Theme.monoSmall).foregroundStyle(Theme.faint)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    @ViewBuilder private var searchResults: some View {
        if search.results.isEmpty {
            Text(search.searching ? "searching…" : "no audio files match")
                .font(Theme.monoSmall).foregroundStyle(Theme.faint).padding(10)
        }
        ForEach(search.results, id: \.self) { f in
            FileRow(model: model, url: f, depth: 0, showFolder: true)
        }
        if search.searching && !search.results.isEmpty {
            Text("searching…").font(Theme.monoSmall).foregroundStyle(Theme.faint).padding(10)
        }
    }

    struct Place { let title: String; let icon: String; let url: URL }

    /// The places shown at the top, in order. Only ones that exist (and can be listed) appear.
    private var places: [Place] {
        var p: [Place] = [Place(title: "Recordings", icon: "record.circle", url: Recordings.directory)]
        let fm = FileManager.default
        #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser
        p.append(Place(title: "Home", icon: "house", url: home))
        for (name, icon) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"), ("Music", "music.note")] {
            p.append(Place(title: name, icon: icon, url: home.appendingPathComponent(name)))
        }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { p.append(Place(title: "iCloud Drive", icon: "icloud", url: icloud)) }
        // every mounted drive (the start-up disk, external drives, SD cards …)
        let volumes = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for v in volumes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isRoot = (try? v.resolvingSymlinksInPath().path) == "/" || v.resolvingSymlinksInPath().path == "/"
            p.append(Place(title: v.lastPathComponent, icon: isRoot ? "internaldrive" : "externaldrive", url: isRoot ? URL(fileURLWithPath: "/") : v))
        }
        #else
        p.append(Place(title: "On this iPad (polje nieuk)", icon: "ipad", url: fm.urls(for: .documentDirectory, in: .userDomainMask)[0]))
        #endif
        return p.filter { fm.fileExists(atPath: $0.url.path) }
    }

    /// Where search looks: everything listed, except the whole start-up disk (home is already in).
    private var roots: [Place] {
        (places + model.browserFolders.map { Place(title: $0.lastPathComponent, icon: "folder", url: $0) })
            .filter { $0.url.path != "/" }
    }
}

/// Background file search: walks the given folders for audio files whose name contains the query.
@MainActor
public final class FileSearch: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [URL] = []
    @Published private(set) var searching = false
    private var current: CancelFlag?

    public final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        public init() {}
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    func run(in roots: [URL]) {
        current?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        results = []
        guard q.count >= 2 else { searching = false; current = nil; return }
        searching = true
        let flag = CancelFlag()
        current = flag
        // the home folder already contains Desktop / Documents / Music …: don't walk them twice
        let unique = roots.filter { r in !roots.contains { $0 != r && r.path.hasPrefix($0.path + "/") } }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.walk(unique, q, flag) { batch, done in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.current === flag else { return }   // a newer search replaced this one
                        self.results.append(contentsOf: batch)
                        if done { self.searching = false }
                    }
                }
            }
        }
    }

    /// All audio files under `roots` whose name contains `query` (synchronous; used by tests).
    nonisolated public static func find(_ query: String, in roots: [URL], limit: Int = 500) -> [URL] {
        final class Box: @unchecked Sendable { var urls: [URL] = [] }
        let box = Box()                                   // walk() reports synchronously on this thread
        walk(roots, query.lowercased(), CancelFlag()) { batch, _ in box.urls.append(contentsOf: batch) }
        return Array(box.urls.prefix(limit))
    }

    /// Runs off the main thread; reports results in batches.
    nonisolated private static func walk(_ roots: [URL], _ q: String, _ flag: CancelFlag,
                                         report: @escaping @Sendable ([URL], Bool) -> Void) {
        var batch: [URL] = [], total = 0
        outer: for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                if flag.cancelled { return }
                if u.lastPathComponent.lowercased().contains(q), AudioFiles.extensions.contains(u.pathExtension.lowercased()) {
                    batch.append(u); total += 1
                    if batch.count >= 25 { report(batch, false); batch = [] }
                    if total >= 500 { break outer }
                }
            }
        }
        report(batch, true)
    }
}

/// Plays a file straight to the system output for previewing (not through the patch).
@MainActor
final class FilePreview: ObservableObject {
    static let shared = FilePreview()
    @Published private(set) var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = 0.8
        p.play()
        player = p
        playing = url
        // clear the ▶ state when it finishes
        let d = p.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.1) { [weak self] in
            if self?.player === p { self?.stop() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}

private struct FolderNode: View {
    @ObservedObject var model: AppModel
    let url: URL
    let title: String
    var icon: String = "folder"
    let depth: Int
    let refresh: Int
    let removable: Bool
    @State private var open = false

    private var entries: (folders: [URL], files: [URL], denied: Bool) {
        _ = refresh
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                         options: [.skipsHiddenFiles]) else { return ([], [], true) }
        var folders: [URL] = [], files: [URL] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true && v?.isPackage != true { folders.append(u) }
            else if AudioFiles.extensions.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        return (folders.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending },
                files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending },
                false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    .frame(width: 8)
                Image(systemName: icon).font(.system(size: 10)).frame(width: 13)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if removable {
                    Button { model.removeFolder(url) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Remove from Collections")
                }
            }
            .font(Theme.mono)
            .foregroundStyle(Theme.text)
            .padding(.leading, CGFloat(10 + depth * 12)).padding(.trailing, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }

            if open {
                let e = entries
                ForEach(e.folders, id: \.self) { f in
                    FolderNode(model: model, url: f, title: f.lastPathComponent, depth: depth + 1, refresh: refresh, removable: false)
                }
                ForEach(e.files, id: \.self) { f in
                    FileRow(model: model, url: f, depth: depth + 1)
                }
                if e.denied {
                    Text("no access — allow it in System Settings › Privacy, or add it with +")
                        .font(Theme.monoSmall).foregroundStyle(Theme.faint)
                        .padding(.leading, CGFloat(22 + depth * 12)).padding(.trailing, 8).padding(.vertical, 3)
                } else if e.folders.isEmpty && e.files.isEmpty {
                    Text("no audio files").font(Theme.monoSmall).foregroundStyle(Theme.faint)
                        .padding(.leading, CGFloat(22 + depth * 12)).padding(.vertical, 3)
                }
            }
        }
    }
}

private struct FileRow: View {
    @ObservedObject var model: AppModel
    let url: URL
    let depth: Int
    var showFolder = false
    @ObservedObject private var preview = FilePreview.shared
    @State private var hover = false

    var body: some View {
        let playing = preview.playing == url
        HStack(spacing: 5) {
            Button { preview.toggle(url) } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 7))
                    .frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(playing ? Theme.text : Theme.faint)
            .help(playing ? "Stop preview" : "Preview")
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if showFolder {
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head).foregroundStyle(Theme.faint)
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.monoSmall)
        .foregroundStyle(hover || playing ? Theme.text : Theme.dim)
        .padding(.leading, CGFloat(10 + depth * 12)).padding(.trailing, 10).padding(.vertical, 3)
        .background(hover ? Theme.row : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.loadIntoSelection(url) }
        .draggable(url) {
            Label(url.lastPathComponent, systemImage: "waveform").font(Theme.mono).padding(6)
                .background(Theme.box).foregroundStyle(Theme.text)
        }
        .help("Drag onto a looper / sampler / stretch, or click to load into the selected one. ▶ previews.")
    }
}
