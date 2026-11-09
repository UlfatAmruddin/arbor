import AppKit
import ArborCore

/// Folder Options "Wrap long file names" (FE-055): its script step; the rows live in `NameWrapRows`.
enum NameWrapFeature: ExplorerFeature {
    static let id = "name-wrap"

    static func register() {
        DebugScript.registerStep("namewrap") { path, window in
            guard let details = window?.itemView as? DetailsViewController else { return 0.3 }
            PerformanceDebug.append(details.nameWrapReport(), to: path)
            return 0.3
        }
    }
}
