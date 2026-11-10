// Draws the app icon: the words "polje nieuk", white on black, in the app's monospaced type.
// Usage: swift scripts/make-icon.swift   (writes App/Assets.xcassets/AppIcon.appiconset + build/polje nieuk.iconset)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

/// macStyle: rounded square inset on a transparent canvas (macOS Big Sur+ grid).
/// Otherwise: full-bleed square (iPadOS applies its own mask).
func render(size: Int, macStyle: Bool, small: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let tile: CGRect
    if macStyle {
        // the small sizes (menus, lists, ⌘-Tab at 16 / 32 pt) fill their square: at that size the usual
        // margin read as a grey frame. Bigger ones keep the macOS margin so they match other Dock icons.
        let inset = small ? 0 : s * 100 / 1024
        tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let r = tile.width * (small ? 0.18 : 0.225)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).fill()
    } else {
        tile = CGRect(x: 0, y: 0, width: s, height: s)
        NSColor.black.setFill()
        tile.fill()
    }

    // Two lines, "polje" over "nieuk", the widest line filling ~58% of the tile.
    let lines = ["polje", "nieuk"]
    var fontSize = tile.width * 0.2
    func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
         .foregroundColor: NSColor.white,
         .kern: -size * 0.02]
    }
    let widest = lines.map { ($0 as NSString).size(withAttributes: attrs(fontSize)).width }.max() ?? 1
    fontSize *= tile.width * 0.58 / widest
    let a = attrs(fontSize)
    let font = a[.font] as! NSFont
    // Centre the pair optically on their x-height boxes (y grows upwards here).
    // draw(at:) places the bottom of the line box (baseline + descender) at the given y.
    let lead = fontSize * 1.08                        // baseline-to-baseline distance
    let lowerBaseline = tile.midY - (lead + font.xHeight) / 2
    for (i, line) in lines.enumerated() {
        let baseline = lowerBaseline + lead * CGFloat(lines.count - 1 - i)
        let lw = (line as NSString).size(withAttributes: a).width
        (line as NSString).draw(at: CGPoint(x: tile.midX - lw / 2, y: baseline + font.descender), withAttributes: a)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let assets = root.appendingPathComponent("App/Assets.xcassets")
let appicon = assets.appendingPathComponent("AppIcon.appiconset")
let iconset = root.appendingPathComponent(".build/polje nieuk.iconset")
try? fm.removeItem(at: appicon)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: appicon, withIntermediateDirectories: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var images: [[String: String]] = []

// iPadOS / iOS: one 1024 image, system applies the mask.
try render(size: 1024, macStyle: false).write(to: appicon.appendingPathComponent("icon-ios-1024.png"))
images.append(["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])

// macOS: every size, rounded tile.
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon-mac-\(pt)@\(scale)x.png"
        let data = render(size: px, macStyle: true, small: pt <= 32)
        try data.write(to: appicon.appendingPathComponent(name))
        try data.write(to: iconset.appendingPathComponent(scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: appicon.appendingPathComponent("Contents.json"))
print("Wrote \(appicon.path) and \(iconset.path)")
