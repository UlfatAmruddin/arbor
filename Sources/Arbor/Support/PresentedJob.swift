import Foundation

/// What conflict dialogs show for a job moving items out of a hidden staging folder (not its name).
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
