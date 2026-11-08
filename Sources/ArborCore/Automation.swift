import Foundation
import Security

/// Every `ARBOR_*` read goes here: distribution builds ignore them, so other local code cannot drive Arbor with its privacy grants.
public enum Automation {
    public static let prefix = "ARBOR_"
    /// Set by scripts/sign-and-notarize.sh, because ad-hoc signed distribution builds have no Team ID.
    public static let distributionKey = "ArborDistribution"

    /// Off when signed with a Team ID (Developer ID) or marked for distribution; checked once.
    public static let isEnabled: Bool = allows(teamIdentifier: ownTeamIdentifier(), appleSigned: ownCodeIsAppleSigned(),
                                               markedDistribution: Bundle.main.object(forInfoDictionaryKey: distributionKey) as? Bool == true)

    /// The `ARBOR_*` variables, read live; empty in a distribution build.
    public static var environment: [String: String] { filter(ProcessInfo.processInfo.environment, enabled: isEnabled) }

    static func allows(teamIdentifier: String?, appleSigned: Bool, markedDistribution: Bool) -> Bool {
        if markedDistribution { return false }
        // Apple's own tools (the test runner) carry a Team ID too.
        return teamIdentifier == nil || appleSigned
    }

    static func filter(_ environment: [String: String], enabled: Bool) -> [String: String] {
        enabled ? environment.filter { $0.key.hasPrefix(prefix) } : [:]
    }

    private static func ownCode() -> SecCode? {
        var code: SecCode?
        return SecCodeCopySelf([], &code) == errSecSuccess ? code : nil
    }

    private static func ownTeamIdentifier() -> String? {
        guard let code = ownCode() else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func ownCodeIsAppleSigned() -> Bool {
        var requirement: SecRequirement?
        guard let code = ownCode(), SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
