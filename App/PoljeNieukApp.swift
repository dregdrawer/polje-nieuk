import SwiftUI
import PoljeNieukUI

@main
struct PoljeNieukApp: App {
    var body: some Scene {
        WindowGroup("polje nieuk") {
            PoljeNieukRootView()
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 500)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        #endif
    }
}
