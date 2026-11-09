import Testing
@testable import Arbor
@testable import ArborCore

@Suite("Finder tags feature (FE-081)")
struct FinderTagsFeatureTests {
    /// The getter lives with the feature and the check box in the catalog; they must not drift apart.
    @Test func showTagsDefaultMatchesTheCatalog() throws {
        let item = try #require(FolderOptionsCatalog.all.first { $0.key == "navShowTags" })
        #expect(item.defaultValue == .bool(Prefs.navShowTags))
    }
}
