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
            PoljeNieukRootView().frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 860)
    }
}
