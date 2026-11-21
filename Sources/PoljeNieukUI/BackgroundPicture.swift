import SwiftUI
#if os(iOS)
import PhotosUI
#else
import UniformTypeIdentifiers
#endif

/// A photo behind the whole canvas (colours panel → background picture). It fills the window and stays
/// still while you pan and zoom. The picture is copied into the app's own folder, so it survives the
/// original being moved or deleted.
@MainActor enum BackgroundPicture {
    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("polje nieuk", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("background-picture")
    }
    private static var loaded = false
    private static var cached: Image?

    /// The picture, or nil when none is set.
    static var image: Image? {
        if !loaded {
            loaded = true
            #if os(iOS)
            cached = UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
            #else
            cached = NSImage(contentsOf: url).map { Image(nsImage: $0) }
            #endif
        }
        return cached
    }
    static var isSet: Bool { image != nil }

    /// Use these image bytes as the background (false if they aren't a picture).
    @discardableResult static func set(_ data: Data) -> Bool {
        #if os(iOS)
        guard UIImage(data: data) != nil else { return false }
        #else
        guard NSImage(data: data) != nil else { return false }
        #endif
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        loaded = false
        CustomColours.version &+= 1
        return true
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        loaded = false
        CustomColours.version &+= 1
    }
}

/// The canvas background: the scheme's colour, with the picture (if any) filling the window on top of it.
struct CanvasBackground: View {
    var body: some View {
        ZStack {
            Theme.bg
            if let img = BackgroundPicture.image {
                img.resizable().scaledToFill()
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// The "background picture" row of the colours panel.
struct BackgroundPictureRow: View {
    @ObservedObject var model: AppModel
    #if os(iOS)
    @State private var item: PhotosPickerItem?
    #endif

    var body: some View {
        HStack {
            Text("background picture").font(Theme.mono).foregroundStyle(Theme.text)
            Spacer()
            #if os(iOS)
            PhotosPicker(selection: $item, matching: .images) {
                Text(BackgroundPicture.isSet ? "change…" : "choose…").font(Theme.monoSmall)
            }
            .onChange(of: item) { _, new in
                guard let new else { return }
                Task {
                    if let data = try? await new.loadTransferable(type: Data.self), BackgroundPicture.set(data) { model.coloursChanged() }
                    item = nil
                }
            }
            #else
            Button(BackgroundPicture.isSet ? "change…" : "choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                panel.message = "A picture to fill the background"
                if panel.runModal() == .OK, let u = panel.url, let data = try? Data(contentsOf: u), BackgroundPicture.set(data) {
                    model.coloursChanged()
                }
            }
            .font(Theme.monoSmall)
            #endif
            Button { BackgroundPicture.remove(); model.coloursChanged() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.dim)
            .opacity(BackgroundPicture.isSet ? 1 : 0.3)
            .disabled(!BackgroundPicture.isSet)
            .help("No picture: just the background colour")
        }
    }
}
