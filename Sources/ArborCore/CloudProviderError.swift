import FileProvider
import Foundation

/// Reads what a provider's own error says (FE-192, FE-195). Only error codes count, never the wording.
public enum CloudProviderError {
    private static let signInCodes: [String: Set<Int>] = [
        NSFileProviderErrorDomain: [NSFileProviderError.Code.notAuthenticated.rawValue],
        NSURLErrorDomain: [NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication],
    ]
    /// A provider's error can nest or even contain itself.
    private static let maxErrorsExamined = 16
    public static let maxMessageLength = 300

    /// Providers often wrap the real error, so the underlying ones count too.
    public static func requiresSignIn(_ error: Error) -> Bool {
        var waiting = [error as NSError]
        var examined = 0
        while let next = waiting.popLast(), examined < maxErrorsExamined {
            examined += 1
            if signInCodes[next.domain]?.contains(next.code) == true { return true }
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError { waiting.append(underlying) }
            if let several = next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { waiting += several.prefix(maxErrorsExamined) }
        }
        return false
    }

    /// A provider's failure text as plain, bounded display text.
    public static func message(_ error: Error) -> String { message(error.localizedDescription) }

    public static func message(_ text: String) -> String { UntrustedText.display(text, limit: maxMessageLength) }

    /// `ARBOR_TEST_CLOUD_ROOT_ERROR`: the failures a simulated provider's root listing can have.
    public static func simulatedListingFailure(_ word: String) -> Error? {
        switch word {
        case "signin":
            return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn't be completed. Not signed in.",
                NSUnderlyingErrorKey: NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.notAuthenticated.rawValue),
            ])
        case "failed":
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.serverUnreachable.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "The server is unreachable."])
        default:
            return nil
        }
    }
}

/// A root that can't be listed until the user signs in, worded for the status bar and the alert.
public struct CloudSignInNeeded: LocalizedError, Equatable, Sendable {
    public let provider: String
    public let detail: String

    public init(provider: String, detail: String) {
        self.provider = provider
        self.detail = detail
    }

    public var errorDescription: String? {
        detail.isEmpty ? L10n.format("Sign in to %@ to see this folder.", provider)
                       : L10n.format("Sign in to %@ to see this folder. It reported: %@", provider, detail)
    }
}
