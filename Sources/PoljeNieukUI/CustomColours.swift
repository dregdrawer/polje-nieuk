import SwiftUI

/// User colours for the canvas background, the boxes ("windows") and the patch cords.
/// Kept separately for the dark and the light scheme, and remembered between launches.
enum CustomColours {
    enum Slot: String, CaseIterable {
        case background, windows, cables
        var title: String {
            switch self { case .background: return "background"; case .windows: return "windows"; case .cables: return "patch cords" }
        }
    }

    /// The settings key per scheme and slot, made once (this is asked for constantly while drawing).
    private static let keys: [Bool: [Slot: String]] = [true: Dictionary(uniqueKeysWithValues: Slot.allCases.map { ($0, "colour.light.\($0.rawValue)") }),
                                                       false: Dictionary(uniqueKeysWithValues: Slot.allCases.map { ($0, "colour.dark.\($0.rawValue)") })]
    private static func key(_ s: Slot) -> String { keys[Theme.light]![s]! }

    /// RGBA per key, cached so drawing never touches UserDefaults
    nonisolated(unsafe) private static var cache: [String: [Double]?] = [:]
    nonisolated(unsafe) private static var paletteCache: [String: WindowPalette?] = [:]

    private static func components(_ s: Slot) -> [Double]? {
        let k = key(s)
        if let c = cache[k] { return c }
        // numbers (as saved) or numeric strings; anything else is ignored
        let a = (UserDefaults.standard.array(forKey: k) ?? []).compactMap { v -> Double? in
            if let n = v as? NSNumber { return n.doubleValue }
            if let t = v as? String { return Double(t) }
            return nil
        }
        let ok: [Double]? = a.count == 4 && a.allSatisfy({ $0.isFinite }) ? a.map { min(max($0, 0), 1) } : nil
        cache[k] = ok
        return ok
    }

    static func colour(_ s: Slot) -> Color? {
        components(s).map { Color(.sRGB, red: $0[0], green: $0[1], blue: $0[2], opacity: 1) }
    }

    /// Bumped whenever any colour or the scheme changes — live displays fold it into their signature.
    nonisolated(unsafe) static var version = 0

    static func set(_ s: Slot, _ colour: Color?) {
        let k = key(s)
        version &+= 1
        paletteCache.removeAll()
        guard let colour, let rgba = rgba(colour) else {
            cache[k] = .some(nil)
            UserDefaults.standard.removeObject(forKey: k)
            return
        }
        cache[k] = rgba
        UserDefaults.standard.set(rgba, forKey: k)
    }

    /// Perceived brightness 0…1 of an sRGB colour.
    static func luminance(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }

    /// Everything drawn inside a box, derived from the custom window colour: rows, fills, borders and lines
    /// are steps of the same colour (lighter on a dark window, darker on a light one), and the text is
    /// light or dark — whichever reads on it.
    struct WindowPalette {
        let isLight: Bool
        let box, row, fill, border, faint, text, dim: Color
    }

    static func windowPalette() -> WindowPalette? {
        let k = key(.windows)
        if let p = paletteCache[k] { return p }
        guard let c = components(.windows) else { paletteCache[k] = .some(nil); return nil }
        let isLight = luminance(c) > 0.5
        let toward: Double = isLight ? 0 : 1                        // step toward black or white
        func step(_ a: Double) -> Color {
            Color(.sRGB, red: c[0] + (toward - c[0]) * a, green: c[1] + (toward - c[1]) * a,
                  blue: c[2] + (toward - c[2]) * a, opacity: 1)
        }
        let p = WindowPalette(isLight: isLight,
                              box: step(0), row: step(0.07), fill: step(0.22), border: step(0.24),
                              faint: step(0.34), text: step(0.9), dim: step(0.5))
        paletteCache[k] = p
        return p
    }

    /// Cords that show on a custom background when no cord colour is chosen.
    static func defaultCable() -> Color? {
        guard let c = components(.background) else { return nil }
        return luminance(c) > 0.5 ? Color(white: 0.35) : Color(white: 0.62)
    }

    /// Grid dots that show on a custom background (light dots on dark, dark dots on light).
    static func gridDot() -> Color? {
        guard let c = components(.background) else { return nil }
        return luminance(c) > 0.5 ? Color.black.opacity(0.12) : Color.white.opacity(0.09)
    }

    static func resetAll() { for s in Slot.allCases { set(s, nil) } }
    /// After switching scheme the other scheme's colours apply.
    static func schemeChanged() {
        version &+= 1; paletteCache.removeAll() }
    static var anyCustom: Bool { Slot.allCases.contains { colour($0) != nil } }

    private static func rgba(_ c: Color) -> [Double]? {
        #if os(macOS)
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent)]
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return [Double(r), Double(g), Double(b), Double(a)]
        #endif
    }
}

/// The palette popover: one picker per slot, plus reset.
struct ColourMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("colours · \(model.lightScheme ? "light" : "dark") scheme").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button { model.showColours = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            ForEach(CustomColours.Slot.allCases, id: \.self) { slot in
                HStack {
                    Text(slot.title).font(Theme.mono).foregroundStyle(Theme.text)
                    Spacer()
                    ColorPicker("", selection: binding(slot), supportsOpacity: false).labelsHidden()
                    Button { CustomColours.set(slot, nil); model.coloursChanged() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
                    .opacity(CustomColours.colour(slot) == nil ? 0.3 : 1)
                    .help("Back to the scheme's own \(slot.title) colour")
                }
            }
            BackgroundPictureRow(model: model)
            Divider()
            Button("Reset all to the scheme") { CustomColours.resetAll(); model.coloursChanged() }
                .font(Theme.monoSmall)
                .disabled(!CustomColours.anyCustom)
        }
        .padding(14)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.box)
            .shadow(color: .black.opacity(Theme.light ? 0.18 : 0.5), radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
        .padding(12)
        #if os(macOS)
        .onDisappear { NSColorPanel.shared.close() }       // the system colour window goes with it
        #endif
    }

    private func binding(_ slot: CustomColours.Slot) -> Binding<Color> {
        Binding(get: {
            switch slot {
            case .background: return Theme.bg
            case .windows: return Theme.box
            case .cables: return Theme.cable
            }
        }, set: { CustomColours.set(slot, $0); model.coloursChanged() })
    }
}
