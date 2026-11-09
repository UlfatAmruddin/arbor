import Foundation

/// The only code that knows what a tag collection's search looks like (FE-081).
public enum TagCollectionQuery {
    public static let maxNameBytes = 255
    private static let prefix = "tag:\""
    private static let suffix = "\""

    /// Everything that carries any tag.
    public static let allTagged = SearchRequest(query: "tag:*")

    /// Spotlight's form of `allTagged`.
    public static var allTaggedSpotlightQuery: String? {
        guard case .success(let expression) = AQSParser.parse(allTagged.query) else { return nil }
        return SpotlightPredicate.make(expression, matchContents: false)?.query
    }

    /// nil when the name can't be searched for exactly; the parser round trip covers what the grammar can't express.
    public static func request(for name: String) -> SearchRequest? {
        guard isShowable(name) else { return nil }
        let query = prefix + name + suffix
        guard case .success(let parsed) = AQSParser.parse(query),
              parsed == .term(SearchTerm(.tags, .text(name, .contains))) else { return nil }
        return SearchRequest(query: query)
    }

    /// The tag a request collects. Comparing keys also rejects any extra scope, origin or option.
    public static func tagName(in request: SearchRequest) -> String? {
        let query = request.query
        guard query.utf8.count <= prefix.utf8.count + maxNameBytes + suffix.utf8.count,
              query.hasPrefix(prefix), query.hasSuffix(suffix), query.count > prefix.count else { return nil }
        let name = String(query.dropFirst(prefix.count).dropLast(suffix.count))
        guard let expected = Self.request(for: name), Location.search(expected).key == Location.search(request).key else { return nil }
        return name
    }

    /// What a tab and breadcrumb call this collection; nil for any other search.
    public static func title(of request: SearchRequest) -> String? {
        request == allTagged ? L10n.tr("Tags") : tagName(in: request)
    }

    private static func isShowable(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxNameBytes && !name.unicodeScalars.contains(where: isForbidden)
    }

    /// Controls and direction overrides (they would show as different text); emoji sequences need the joiner, so it stays.
    /// Quotes are checked here because the parser compares Characters and misses one joined to another scalar.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            || ["\u{22}", "\u{201C}", "\u{201D}"].contains(scalar)
    }
}
