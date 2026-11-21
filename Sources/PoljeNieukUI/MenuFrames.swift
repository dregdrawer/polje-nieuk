import SwiftUI

/// Where the open menus (and the top bar) are on screen, so a press anywhere else can close them and still
/// go on to do what it does (drag the canvas, move a box …) — Mac. On iPad a tap outside closes them.
@MainActor final class MenuFrames {
    static let shared = MenuFrames()
    var frames: [String: CGRect] = [:]
    func contains(_ p: CGPoint) -> Bool { frames.values.contains { $0.contains(p) } }
}

extension View {
    /// Registers this view's frame (in the window) under `key` while it's on screen.
    func menuFrame(_ key: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MenuFrames.shared.frames[key] = $0 }
            .onDisappear { MenuFrames.shared.frames[key] = nil }
    }
}

extension AppModel {
    var anyMenuOpen: Bool { barMenu != nil || panelMenu != nil || boxMenu != nil || finderAt != nil || showColours }
    func closeMenus() {
        if barMenu != nil { barMenu = nil }
        if panelMenu != nil { panelMenu = nil }
        if boxMenu != nil { boxMenu = nil }
        if finderAt != nil { finderAt = nil }
        if showColours { showColours = false }
    }
}
