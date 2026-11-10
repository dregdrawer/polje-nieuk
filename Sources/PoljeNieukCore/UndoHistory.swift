import Foundation

/// Undo / redo for the patch: a stack of whole-patch snapshots. The app commits a snapshot once an edit
/// has settled (so dragging a knob or a box is one step, not hundreds).
public struct UndoHistory: Sendable {
    public private(set) var committed: Patch
    public private(set) var undoStack: [Patch] = []
    public private(set) var redoStack: [Patch] = []
    public let limit: Int

    public init(committed: Patch, limit: Int = 200) { self.committed = committed; self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Record `current` as a step if it differs from the last committed state. A new edit clears redo.
    public mutating func commit(_ current: Patch) {
        guard current != committed else { return }
        undoStack.append(committed)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        committed = current
    }

    /// The patch to go back to (the caller commits `current` first).
    public mutating func undo() -> Patch? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(committed)
        committed = prev
        return prev
    }

    public mutating func redo() -> Patch? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(committed)
        committed = next
        return next
    }

    /// After loading or normalising a patch without making it an undo step.
    public mutating func reset(to p: Patch, keepHistory: Bool) {
        committed = p
        if !keepHistory { undoStack.removeAll(); redoStack.removeAll() }
    }
}
