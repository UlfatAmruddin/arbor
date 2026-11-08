import AppKit
import ArborCore

/// Undo Move / Redo Move (QA-CORE-5). Nothing touches the disk on the main thread: the plan and the
/// same-volume renames run on a background queue, and items on another volume go back through a normal
/// move job in `OperationCenter` (progress window, pause, cancel, journal, conflict prompts, each original
/// removed only after its own copy). Undo never overwrites: gone items and taken places are reported.
extension OperationCenter {
    /// Where the items of one step ended up, filled in when the step finishes.
    final class MoveStepResult {
        var moved: [MoveBack.Item] = []
        var done = false
    }

    /// Registers one undo (or redo) step that moves `items()` back. While it runs it registers its own
    /// inverse right away (AppKit requires that), which acts on what the step actually moved.
    func registerMoveStep(_ items: @escaping () -> [MoveBack.Item]?) {
        undoManager.registerUndo(withTarget: self) { center in
            let result = MoveStepResult()
            center.registerMoveStep { result.done ? result.moved.map { MoveBack.Item(from: $0.to, to: $0.from) } : nil }
            center.undoManager.setActionName("Move")
            guard let list = items() else {
                result.done = true
                center.report("The previous Undo or Redo is still moving items.", "Wait until it has finished, then try again.")
                return
            }
            center.moveBack(list) { moved in
                result.moved = moved
                result.done = true
            }
        }
    }

    /// Moves each item from `from` to `to`, then calls `completion` (main queue) with the items that
    /// arrived (`to` = where each one is now).
    func moveBack(_ items: [MoveBack.Item], completion: @escaping ([MoveBack.Item]) -> Void) {
        let window = BrowserWindowController.active?.window
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = MoveBack.plan(items)
            let (renamed, failed) = Self.rename(plan.renames)
            DispatchQueue.main.async {
                var moved = renamed
                var refused = (plan.refused + failed).map(\.from.lastPathComponent)
                let group = DispatchGroup()
                for transfer in plan.transfers {
                    group.enter()
                    self.start(.move, sources: transfer.items.map(\.from), destination: transfer.folder, window: window,
                               registersUndo: false) { report in
                        // The job keeps the names the items have now; give back the old ones where they were changed.
                        let fixes = MoveBack.renamesAfterTransfer(transfer.items, committed: report.committed)
                        DispatchQueue.global(qos: .userInitiated).async {
                            let (fixed, unfixed) = Self.rename(fixes)
                            DispatchQueue.main.async {
                                for pair in report.committed {
                                    let item = transfer.items.first { $0.from.standardizedFileURL == pair.source.standardizedFileURL }
                                    let now = fixed.first { $0.from == pair.destination }?.to ?? pair.destination
                                    if let item { moved.append(MoveBack.Item(from: item.from, to: now)) }
                                }
                                refused += unfixed.map { "\($0.from.lastPathComponent) (back in its folder, but “\($0.to.lastPathComponent)” is taken)" }
                                group.leave()
                            }
                        }
                    }
                }
                group.notify(queue: .main) {
                    if !refused.isEmpty {
                        self.report("Some items couldn't be moved back.",
                                    "They were changed or their original location is taken:\n" + refused.joined(separator: ", "))
                    }
                    completion(moved)
                }
            }
        }
    }

    /// Same-volume moves: one rename each, never over an existing item.
    private static func rename(_ items: [MoveBack.Item]) -> (done: [MoveBack.Item], failed: [MoveBack.Item]) {
        var done: [MoveBack.Item] = []
        var failed: [MoveBack.Item] = []
        for item in items {
            if renamex_np(item.from.path, item.to.path, UInt32(RENAME_EXCL)) == 0 { done.append(item) } else { failed.append(item) }
        }
        return (done, failed)
    }
}
