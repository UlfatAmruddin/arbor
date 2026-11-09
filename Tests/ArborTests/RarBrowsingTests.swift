import Foundation
import Testing
@testable import Arbor
@testable import ArborCore

/// A .rar browses through the same read-only provider as every other archive (FE-167).
@Suite struct RarBrowsingTests {
    @Test func aRarIsReadOnlyLikeOtherArchives() {
        let location = Location.archive(URL(fileURLWithPath: "/Users/me/a.rar"), innerPath: "")
        let provider = ArchiveProvider()
        #expect(provider.handles(location))
        #expect(!provider.allowsItemEditing(in: location))
        #expect(provider.targetFolder(for: location) == nil)
        for action in LocationAction.allCases where action != .copy {
            #expect(provider.limitation(of: action, in: location) != nil, "\(action)")
        }
        #expect(provider.limitation(of: .copy, in: location) == nil)
    }
}
