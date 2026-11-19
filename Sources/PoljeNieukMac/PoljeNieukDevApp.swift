import SwiftUI
import AppKit
import PoljeNieukUI

/// Unbundled macOS build for development (run straight from the terminal).
final class DevAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PoljeNieukDevApp: App {
    @NSApplicationDelegateAdaptor(DevAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("polje nieuk") {
            // the window's smallest size is fixed: the GeometryReader answers "how small can you be" without
            // measuring what's inside (the window re-measured every box and the bar on each change to the patch)
            GeometryReader { _ in PoljeNieukRootView() }.frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 860)
    }
}
