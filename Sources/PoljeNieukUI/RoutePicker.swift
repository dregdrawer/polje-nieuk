#if os(iOS)
import SwiftUI
import AVKit

/// Apple's system output picker (AirPlay, Bluetooth, and the other outputs iPadOS offers).
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(white: 0.55, alpha: 1)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
