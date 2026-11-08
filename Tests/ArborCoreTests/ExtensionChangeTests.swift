import Foundation
import Testing
@testable import ArborCore

// The extension-change warning named an empty extension for dotfiles: renaming ".env" to ".env.local"
// said “If you change “.” to “.local”” (docs/ACCEPTANCE.md, T10).
@Suite("Extension change on rename")
struct ExtensionChangeTests {
    @Test func dotfileGainingAnExtensionIsAnAddition() {
        #expect(ExtensionChange.between(".env", ".env.local") == .added("local"))
        #expect(ExtensionChange.between("README", "README.md") == .added("md"))
    }

    @Test func droppingTheExtensionIsARemoval() {
        #expect(ExtensionChange.between("notes.txt", "notes") == .removed("txt"))
        #expect(ExtensionChange.between(".env.local", ".env") == .removed("local"))
    }

    @Test func changesKeepTheTypedSpelling() {
        #expect(ExtensionChange.between("a.txt", "a.md") == .changed(from: "txt", to: "md"))
    }

    @Test func sameExtensionInOtherCaseOrNoneIsUnchanged() {
        #expect(ExtensionChange.between("photo.JPG", "holiday.jpg") == .unchanged)
        #expect(ExtensionChange.between(".env", ".envrc") == .unchanged)
        #expect(ExtensionChange.between("Makefile", "makefile") == .unchanged)
    }
}
