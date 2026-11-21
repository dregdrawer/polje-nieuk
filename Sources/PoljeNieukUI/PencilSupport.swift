import SwiftUI
import PoljeNieukCore

/// Where the Apple Pencil (hovering above the iPad) or the mouse pointer is, in canvas view coordinates.
final class HoverState: ObservableObject {
    @Published var point: CGPoint?
}

/// Lights up the port under the Pencil tip / pointer and shows its name before you touch,
/// so patching small ports is easy.
struct PortHoverOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: HoverState

    var body: some View {
        Canvas { ctx, _ in
            // while a cable is being dragged: the port it would connect to if let go here
            let pc = model.pendingCable
            guard let hp = pc?.point ?? hover.point, model.finderAt == nil else { return }
            let reach: CGFloat = pc == nil ? 22 : 24          // 24 = what finishCable connects to
            var best: (CGPoint, String, Bool, CGFloat)?
            let hw = model.hw, z = model.viewScale, o = model.viewOffset
            for n in model.patch.nodes {
                guard let spec = ModuleRegistry.spec(n.kind) else { continue }
                // only the boxes near the pointer (working out every port of every box on each change made
                // dragging a slider slow on a big patch)
                let r = CGRect(x: n.x * z + o.width, y: n.y * z + o.height,
                               width: BoxLayout.width(n) * z, height: BoxLayout.height(n, spec, hw) * z).insetBy(dx: -40, dy: -40)   // ports stick out past the edge
                guard r.contains(hp) else { continue }
                if let pc, n.id == pc.node { continue }
                for p in BoxLayout.visiblePorts(n, spec, hw) where pc.map({ p.output != $0.fromOutput }) ?? true {
                    let s = model.toScreen(p.point)
                    let d = hypot(s.x - hp.x, s.y - hp.y)
                    if d < reach && d < (best?.3 ?? .infinity) { best = (s, p.name, p.output, d) }
                }
            }
            guard let (pt, name, isOut, _) = best else { return }
            let r: CGFloat = 9
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                       with: .color(Theme.text), lineWidth: 1.5)
            let label = Text(name).font(Theme.mono).foregroundColor(Theme.inverse)
            let resolved = ctx.resolve(label)
            let sz = resolved.measure(in: CGSize(width: 300, height: 30))
            let x = isOut ? pt.x + 14 : pt.x - 14 - sz.width
            let box = CGRect(x: x - 5, y: pt.y - sz.height / 2 - 3, width: sz.width + 10, height: sz.height + 6)
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.text))
            ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
        }
        .allowsHitTesting(false)
    }
}

#if os(iOS)
import UIKit

/// Apple Pencil gestures:
///  • double-tap (Pencil 2 / Pro): delete the selected cable, or bypass/un-bypass the selected modules
///  • squeeze (Pencil Pro): open the module list right where the Pencil is hovering
struct PencilBridge: UIViewRepresentable {
    let onTap: () -> Void
    let onSqueeze: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var parent: PencilBridge
        init(_ p: PencilBridge) { parent = p }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            parent.onTap()
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            parent.onSqueeze(squeeze.hoverPose?.location)
        }
    }
}
#endif
