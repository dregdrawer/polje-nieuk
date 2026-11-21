import SwiftUI
import UniformTypeIdentifiers
import PoljeNieukCore

enum PatchStore {
    static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("polje nieuk", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("autosave.json")
    }

    static func loadAutosave() -> Patch? {
        guard let data = try? Data(contentsOf: autosaveURL) else { return nil }
        return (try? JSONDecoder().decode(Patch.self, from: data))?.migrated()
    }

    static func saveAutosave(_ patch: Patch) {
        guard let data = try? encode(patch) else { return }
        try? data.write(to: autosaveURL, options: .atomic)
    }

    // MARK: Your default patch (more → Set as default)

    static var defaultURL: URL { autosaveURL.deletingLastPathComponent().appendingPathComponent("default.json") }
    /// Audio that belongs to the default patch (looper / sampler buffers, rack pads), by box ID.
    static var defaultAudioDirectory: URL {
        let d = autosaveURL.deletingLastPathComponent().appendingPathComponent("Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var hasUserDefault: Bool { FileManager.default.fileExists(atPath: defaultURL.path) }

    static func loadUserDefault() -> Patch? {
        guard let data = try? Data(contentsOf: defaultURL) else { return nil }
        return (try? JSONDecoder().decode(Patch.self, from: data))?.migrated()
    }

    static func encode(_ patch: Patch) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(patch)
    }
}

/// A patch as a document for the system Save / Open panels (plain JSON).
struct PatchFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var patch: Patch

    init(patch: Patch) { self.patch = patch }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        patch = try JSONDecoder().decode(Patch.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PatchStore.encode(patch))
    }
}

public enum DefaultPatch {
    /// The starter patch (first launch, New, "Load starter patch"): in, clock, mix, out — nothing patched yet.
    /// What New starts from: your own default (more → Set as default) if you've set one, else the built-in one.
    public static func make() -> Patch {
        if let p = PatchStore.loadUserDefault() { return p.withFreshIDs().patch }
        return builtIn()
    }

    public static func builtIn() -> Patch {
        var p = Patch()
        // in grows with the interface's channel count, so it sits under the clock and has room below
        let clock = PatchNode(kind: "clock", x: 30, y: 40)
        let hwIn = PatchNode(kind: "in", x: 30, y: 260)
        let mix = PatchNode(kind: "mix", x: 230, y: 40)
        let hwOut = PatchNode(kind: "out", x: 470, y: 40)
        p.nodes = [hwIn, clock, mix, hwOut]
        return p
    }
}
