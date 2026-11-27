import Foundation
import Testing
@testable import BetterExplorer

/// The real file stays out of reach of anything scripted (registration suite).
extension FeatureRegistrationTests {
    @Test func aHeadlessRunHasNoAddressHistoryFile() {
        #expect(Self.problem == nil)
        #expect(AddressHistoryFeature.fileURL == nil)
    }
}
