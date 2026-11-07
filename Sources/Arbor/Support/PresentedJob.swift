import Foundation

/// Wording and source that conflict dialogs show for a job whose transfer moves items out of a hidden
/// staging folder: "Extracting 2 items from Archive.zip to Reports", not the staging folder's name.
struct PresentedJob {
    var progressVerb: String
    var gerund: String
    var verb: String
    var pastVerb: String
    var source: URL

    static func extracting(_ archive: URL) -> PresentedJob {
        PresentedJob(progressVerb: "Extracting", gerund: "extracting", verb: "extract", pastVerb: "extracted", source: archive)
    }
}
