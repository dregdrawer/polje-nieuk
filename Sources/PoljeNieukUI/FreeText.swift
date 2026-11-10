import SwiftUI
import PoljeNieukCore

/// Free-floating text on the canvas, like a Max comment or a Grasshopper scribble: no box, just words.
/// Drag it to move · tap to select · double-tap (double-click) to edit · a new one opens for typing.
struct FreeText: View {
    @ObservedObject var model: AppModel
    let node: PatchNode
    @State private var editing = false
    @State private var draft = ""
    @State private var dragStart: CGPoint?
    @State private var groupDrag = false
    @FocusState private var focused: Bool
    @Environment(\.hostedNodes) private var hosted

    private var selected: Bool { model.selectedNodes.contains(node.id) }
    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        Group {
            if editing {
                TextField("text", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Self.font)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .lineLimit(1...200)
                    // as wide as the longest line (plus room to type), every line visible
                    .frame(width: max(editWidth, 80), height: editHeight, alignment: .topLeading)
                    .onChange(of: draft) { _, v in model.setText(node.id, v) }
                    .onChange(of: focused) { _, f in if !f { finish() } }
                    .onSubmit { finish() }
                    // focus once the field is really on screen (straight away is too early inside the canvas)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
            } else {
                Text((node.text ?? "").isEmpty ? "text" : node.text!)
                    .font(Self.font)
                    .foregroundStyle((node.text ?? "").isEmpty ? Theme.faint : Theme.text)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        // a finger-sized touch area (reaches past the words), and the drag wins over the canvas pan
        .contentShape(Rectangle().inset(by: editing ? 0 : -10))
        .highPriorityGesture(move, including: editing ? .subviews : .all)
        .onTapGesture(count: 2) { if !editing { startEditing() } }
        .onTapGesture {
            guard !editing else { return }
            if model.selectMode || ModuleBox.shiftHeld { model.toggleSelected(node.id) } else { model.select(node.id) }
        }
        .overlay(alignment: .topLeading) {
            if editing {
                // while typing: drag the grip to move the text
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 2) { Circle().frame(width: 2.5, height: 2.5); Circle().frame(width: 2.5, height: 2.5) }
                    }
                }
                .foregroundStyle(Theme.dim)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
                .offset(x: -24, y: -4)
                .highPriorityGesture(move)
            }
        }
        .overlay {
            if selected || editing {
                Rectangle().stroke(Theme.dim.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected && !editing {
                Button { model.removeNode(node.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 14, y: -8)
            }
        }
        .onAppear { if node.text == nil { startEditing() } }
        // tapping the canvas (or another box) deselects: that ends editing too
        .onChange(of: selected) { _, sel in if !sel && editing { finish() } }       // a fresh one is ready to type into
        .help("Text · drag to move · double-click to edit")
    }

    private var editWidth: CGFloat {
        let longest = draft.components(separatedBy: "\n").map(\.count).max() ?? 0
        return CGFloat(longest + 4) * 7.3
    }
    private var editHeight: CGFloat { CGFloat(max(draft.components(separatedBy: "\n").count, 1)) * 15 + 1 }

    private func startEditing() {
        draft = node.text ?? ""
        model.select(node.id)
        editing = true
    }

    private func finish() {
        guard editing else { return }
        editing = false
        model.setText(node.id, draft.trimmingCharacters(in: .whitespacesAndNewlines))
        // an empty note that was never written in goes away
        if (model.patch.nodes.first { $0.id == node.id }?.text ?? "").isEmpty { model.removeNode(node.id) }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: hosted ? .named(NodesHost.space) : .named("canvas"))
            .onChanged { v in
                if model.isZooming { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: node.x, y: node.y)
                    groupDrag = selected && model.selectedNodes.count > 1
                    if groupDrag { model.beginGroupDrag() } else { model.select(node.id) }
                }
                guard let s = dragStart else { return }
                let d = CGSize(width: v.translation.width / model.viewScale, height: v.translation.height / model.viewScale)
                if groupDrag { model.groupDrag(by: d) } else { model.moveNode(node.id, to: CGPoint(x: s.x + d.width, y: s.y + d.height)) }
            }
            .onEnded { _ in
                dragStart = nil
                if groupDrag { model.endGroupDrag() }
                groupDrag = false
                model.scheduleAutosave()
            }
    }
}
