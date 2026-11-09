import Foundation
import Testing
@testable import ArborCore

private func plist(_ value: Any, _ format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
}

private func setAttribute(_ data: Data, on url: URL) {
    _ = data.withUnsafeBytes { setxattr(url.path, FinderMetadata.tagAttribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
}

@Suite("Finder tag attribute (FE-081)")
struct FinderTagAttributeTests {
    @Test(arguments: [
        ("Red\n6", "Red", 6), ("Work", "Work", 0), ("Bad\n99", "Bad", 0), ("x\n-1", "x", 0),
        ("two\nlines\n3", "two\nlines", 3), ("Word\nfive", "Word", 0),
    ]) func storedEntries(entry: String, name: String, color: Int) {
        let tag = FinderTag(storedEntry: entry)
        #expect(tag.name == name)
        #expect(tag.colorIndex == color)
    }

    @Test func parsesBinaryAndXMLPlists() throws {
        let expected = [FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "Work")]
        #expect(FinderMetadata.parseTagAttribute(try plist(["Red\n6", "Work\n0"])) == expected)
        #expect(FinderMetadata.parseTagAttribute(try plist(["Red\n6", "Work\n0"], .xml)) == expected)
    }

    @Test func unexpectedShapesGiveNothing() throws {
        #expect(FinderMetadata.parseTagAttribute(try plist(["a": "b"])).isEmpty)
        #expect(FinderMetadata.parseTagAttribute(try plist([1, 2])).isEmpty)
        #expect(FinderMetadata.parseTagAttribute(try plist([String]())).isEmpty)
        #expect(FinderMetadata.parseTagAttribute(Data("not a plist".utf8)).isEmpty)
        #expect(FinderMetadata.parseTagAttribute(Data()).isEmpty)
    }

    @Test func entriesPerFileAreCapped() throws {
        let many = (0..<5_000).map { "t\($0)" }
        #expect(FinderMetadata.parseTagAttribute(try plist(many)).count == FinderMetadata.maxTagsPerFile)
        #expect(FinderMetadata.finderTags(fromStored: many).count == FinderMetadata.maxTagsPerFile)
    }

    @Test func emptyNamesAreDropped() {
        #expect(FinderMetadata.finderTags(fromStored: ["", "\n3", "ok"]) == [FinderTag(name: "ok")])
    }

    @Test func readsATaggedFile() throws {
        let fx = try Fixture()
        let file = try fx.file("a.txt")
        try FinderMetadata.setTags(["Red", "Work"], on: file)
        let tags = FinderMetadata.finderTags(of: file)
        #expect(tags.map(\.name) == ["Red", "Work"])
        #expect(tags.allSatisfy { FinderTag.colorRange.contains($0.colorIndex) })
    }

    @Test func noAttributeGivesNothing() throws {
        let fx = try Fixture()
        #expect(FinderMetadata.finderTags(of: try fx.file("a.txt")).isEmpty)
        #expect(FinderMetadata.finderTags(of: fx.url("missing.txt")).isEmpty)
    }

    @Test func attributeOverTheLimitIsNotRead() throws {
        let fx = try Fixture()
        let file = try fx.file("big.txt")
        let padding = String(repeating: "x", count: FinderMetadata.tagAttributeByteLimit)
        let data = try plist(["Red\n6", padding])
        #expect(data.count > FinderMetadata.tagAttributeByteLimit)
        setAttribute(data, on: file)
        #expect(FinderMetadata.finderTags(of: file).isEmpty)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fx = try Fixture()
        let target = try fx.file("target.txt")
        try FinderMetadata.setTags(["Red"], on: target)
        let link = fx.url("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(FinderMetadata.finderTags(of: link).isEmpty)
    }
}

@Suite("Tag collection query (FE-081)")
struct TagCollectionQueryTests {
    static let accepted = ["Red", "a b", "a:b", "AND", "NOT", "(x)", "a*b", "?", "-x", "back\\slash", "a&b=c", "$time.today", "$time.today x", "a$b", "$",
                           "👩‍💻", "日本語", "Ünï", "tag:\u{00A0}x", String(repeating: "é", count: 127)]
    static let rejected = ["\"x", "x\"", "“x", "x”", "[]", "", " x", "x ", "\tx", "a\u{0}b", "a\nb", "a\u{7F}b", "a\u{85}b",
                           "a\u{202E}b", "a\u{2066}b", String(repeating: "x", count: 256), "\u{0301}x",
                           "x\u{0600}\" &&", "a\"\u{0301}b", "x\u{0600}“y"]

    @Test(arguments: accepted) func acceptedNamesRoundTrip(name: String) throws {
        let request = try #require(TagCollectionQuery.request(for: name))
        #expect(request.scope == nil && request.recursive && request.options.isEmpty)
        #expect(request.query == "tag:\"\(name)\"")
        #expect(try AQSParser.parse(request.query).get() == .term(SearchTerm(.tags, .text(name, .contains))))
        #expect(TagCollectionQuery.tagName(in: request) == name)
    }

    @Test(arguments: rejected) func rejectedNames(name: String) {
        #expect(TagCollectionQuery.request(for: name) == nil)
    }

    /// A predicate MDQuery refuses would end the session with no results.
    @Test(arguments: accepted) func everyAcceptedNameMakesAValidSpotlightQuery(name: String) throws {
        let request = try #require(TagCollectionQuery.request(for: name))
        let predicate = try #require(SpotlightPredicate.make(try AQSParser.parse(request.query).get(), matchContents: false))
        #expect(predicate.isExact)
        #expect(NSPredicate(fromMetadataQueryString: predicate.query) != nil)
    }

    @Test func predicateEscapesEveryMetacharacter() throws {
        func query(_ name: String) throws -> String {
            let request = try #require(TagCollectionQuery.request(for: name))
            return try #require(SpotlightPredicate.make(try AQSParser.parse(request.query).get(), matchContents: false)).query
        }
        #expect(try query("Work") == #"kMDItemUserTags == "Work"cd"#)
        #expect(try query("a*b") == #"kMDItemUserTags == "a\*b"cd"#)
        #expect(try query("a?b") == #"kMDItemUserTags == "a\?b"cd"#)
        #expect(try query("a\\b") == #"kMDItemUserTags == "a\\b"cd"#)
        #expect(try query("$time.today") == #"kMDItemUserTags == "\$time.today"cd"#)
        #expect(try query("*\u{0301}") == "kMDItemUserTags == \"\\*\u{0301}\"cd")
    }

    /// One Character to Swift, but MDQuery reads the quote alone and an unescaped one raises an exception Swift can't catch.
    @Test(arguments: ["x\u{0600}\" &&", "a\"\u{0301}b", "$\u{0301}", "\\\u{0301}"]) func escapingSeesJoinedScalars(value: String) {
        let escaped = SpotlightPredicate.quoted(SpotlightPredicate.escape(value, keepWildcards: false))
        #expect(NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \(escaped)cd") != nil)
        let scalars = Array(SpotlightPredicate.escape(value, keepWildcards: false).unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "\"" || scalar == "$" {
            #expect(index > 0 && scalars[index - 1] == "\\")
        }
    }

    /// Unescaped, MDQuery turns these into a date and drops the rest of the string.
    @Test(arguments: ["$time.today", "$time.today x", "$time.now(-1)"]) func timeSubstitutionsStayLiteral(name: String) throws {
        let request = try #require(TagCollectionQuery.request(for: name))
        let query = try #require(SpotlightPredicate.make(try AQSParser.parse(request.query).get(), matchContents: false)).query
        let format = try #require(NSPredicate(fromMetadataQueryString: query)).predicateFormat
        #expect(format.contains("\"\(name)\""))
    }

    @Test func allTaggedQuery() throws {
        #expect(TagCollectionQuery.allTaggedSpotlightQuery == #"kMDItemUserTags == "*"cd"#)
        #expect(NSPredicate(fromMetadataQueryString: try #require(TagCollectionQuery.allTaggedSpotlightQuery)) != nil)
        let evaluator = SearchEvaluator(try AQSParser.parse(TagCollectionQuery.allTagged.query).get(), matchContents: false)
        #expect(evaluator.evaluate(file(tags: ["Anything"])).truth == .yes)
        #expect(evaluator.evaluate(file(tags: [])).truth == .no)
    }

    @Test func wholeTagMatchOnly() throws {
        let request = try #require(TagCollectionQuery.request(for: "Work"))
        let evaluator = SearchEvaluator(try AQSParser.parse(request.query).get(), matchContents: false)
        #expect(evaluator.evaluate(file(tags: ["Work"])).truth == .yes)
        #expect(evaluator.evaluate(file(tags: ["wörk"])).truth == .yes)
        #expect(evaluator.evaluate(file(tags: ["Workshop"])).truth == .no)
        let literal = try #require(TagCollectionQuery.request(for: "a*b"))
        let exact = SearchEvaluator(try AQSParser.parse(literal.query).get(), matchContents: false)
        #expect(exact.evaluate(file(tags: ["a*b"])).truth == .yes)
        #expect(exact.evaluate(file(tags: ["axxb"])).truth == .no)
    }

    private func file(tags: [String]) -> SearchCandidate {
        SearchCandidate(name: "a.txt", folderPath: "/Users/me", isFolder: false, size: 1, modified: nil, created: nil,
                        typeIdentifier: nil, typeDescription: nil, tags: tags, authors: nil, contentContains: nil)
    }

    @Test func tagNameIsAStrictInverse() throws {
        let base = try #require(TagCollectionQuery.request(for: "Work"))
        var scoped = base; scoped.scope = URL(fileURLWithPath: "/Users/me")
        var extra = base; extra.extraScopes = [URL(fileURLWithPath: "/Volumes/USB")]
        var origin = base; origin.originKey = "home"
        var flat = base; flat.recursive = false
        var options = base; options.options = .contents
        for request in [scoped, extra, origin, flat, options] { #expect(TagCollectionQuery.tagName(in: request) == nil) }
        for query in [#"tag:"Work" report"#, #"tag:"Work" OR "x""#, "tag:Work", #"tags:"Work""#, #"tag:"""#, "tag:*", "report"] {
            #expect(TagCollectionQuery.tagName(in: SearchRequest(query: query)) == nil)
        }
    }

    @Test func oversizedQueriesAreRefusedBeforeParsing() {
        let query = "tag:\"" + String(repeating: "x", count: 1_000_000) + "\""
        #expect(TagCollectionQuery.tagName(in: SearchRequest(query: query)) == nil)
    }
}

@Suite("Tag collection locations (FE-081)")
struct TagLocationTests {
    @Test(arguments: ["Red", "a b&c=d", "👩‍💻", "(x)", "a*b"]) func keysRoundTrip(name: String) throws {
        let location = Location.search(try #require(TagCollectionQuery.request(for: name)))
        #expect(Location(key: location.key) == location)
        #expect(location.displayName == name)
        #expect(location.parent() == nil)
    }

    @Test func titles() {
        #expect(Location.search(TagCollectionQuery.allTagged).displayName == "Tags")
        #expect(Location.search(SearchRequest(query: "report")).displayName == "Search Results")
        let scoped = SearchRequest(query: #"tag:"Work""#, scope: URL(fileURLWithPath: "/Users/me/Stuff"))
        #expect(Location.search(scoped).displayName.hasPrefix("Search Results in "))
    }
}

@Suite("Tag catalog (FE-081)")
struct TagCatalogTests {
    /// `NSWorkspace.fileLabels` on an English system.
    static let labels = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    @Test func systemTagsFollowFindersSidebar() {
        let catalog = TagCatalog(systemLabels: Self.labels)
        #expect(catalog.tags.map(\.name) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        #expect(catalog.tags.map(\.colorIndex) == [6, 7, 5, 2, 4, 3, 1])
    }

    @Test func toleratesShortAndOddLabelLists() {
        #expect(TagCatalog(systemLabels: []).tags.isEmpty)
        #expect(TagCatalog(systemLabels: ["None", "Gray", ""]).tags.map(\.name) == ["Gray"])
        #expect(TagCatalog(systemLabels: ["None", "Same", "same"]).tags.count == 1)
        #expect(TagCatalog(systemLabels: ["None", "bad\"name"]).tags.isEmpty)
    }

    @Test func customTagsSortAfterSystemTags() {
        var catalog = TagCatalog(systemLabels: Self.labels)
        for name in ["Zeta", "item 10", "item 2"] { catalog.insert(FinderTag(name: name, colorIndex: 4)) }
        #expect(catalog.tags.suffix(3).map(\.name) == ["item 2", "item 10", "Zeta"])
    }

    @Test func foldedDuplicatesAreOneRow() {
        var catalog = TagCatalog(systemLabels: [])
        for name in ["Work", "work", "WÖRK", "ｗｏｒｋ"] { catalog.insert(FinderTag(name: name)) }
        #expect(catalog.custom.count == 1)
    }

    @Test func aSystemTagKeepsItsNameAndColour() {
        var catalog = TagCatalog(systemLabels: Self.labels)
        catalog.insert(FinderTag(name: "red", colorIndex: 2))
        #expect(catalog.custom.isEmpty)
        #expect(catalog.tag(named: "RED") == FinderTag(name: "Red", colorIndex: 6))
    }

    @Test func highestColourWinsWhicheverCameFirst() {
        for colors in [[0, 4, 2], [2, 4, 0], [4, 0, 2]] {
            var catalog = TagCatalog(systemLabels: [])
            for color in colors { catalog.insert(FinderTag(name: "Work", colorIndex: color)) }
            #expect(catalog.tag(named: "Work")?.colorIndex == 4)
        }
    }

    @Test func unrepresentableNamesAreDropped() {
        var catalog = TagCatalog(systemLabels: [])
        for name in ["q\"x", "[]", " edge", "ctl\u{7}", "", String(repeating: "x", count: 300)] { catalog.insert(FinderTag(name: name)) }
        #expect(catalog.custom.isEmpty)
    }

    @Test func anUnrepresentableSpellingCantReplaceAGoodOne() {
        var catalog = TagCatalog(systemLabels: [])
        catalog.insert(FinderTag(name: "x", colorIndex: 2))
        catalog.insert(FinderTag(name: "\u{0301}x", colorIndex: 5))   // folds to "x" but can't be searched for
        #expect(catalog.custom == [FinderTag(name: "x", colorIndex: 2)])
    }

    @Test func capIsEnforced() {
        var catalog = TagCatalog(systemLabels: [])
        for i in 0..<(TagCatalog.maxCustomTags * 3) { catalog.insert(FinderTag(name: "tag\(i)")) }
        #expect(catalog.custom.count == TagCatalog.maxCustomTags)
    }

    @Test func resultDoesNotDependOnArrivalOrder() {
        var input: [FinderTag] = []
        for i in 0..<(TagCatalog.maxCustomTags + 60) {
            input.append(FinderTag(name: "tag \(i)", colorIndex: i % 3 == 0 ? 3 : 0))
            input.append(FinderTag(name: "TAG \(i)", colorIndex: i % 3 == 1 ? 5 : 0))
        }
        let reference = catalog(input)
        #expect(reference.custom.count == TagCatalog.maxCustomTags)
        for seed in 0..<20 {
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            #expect(catalog(input.shuffled(using: &generator)) == reference)
        }
    }

    private func catalog(_ tags: [FinderTag]) -> TagCatalog {
        var result = TagCatalog(systemLabels: Self.labels)
        tags.forEach { result.insert($0) }
        return result
    }

    @Test func systemOnlyDropsCustomTags() {
        var catalog = TagCatalog(systemLabels: Self.labels)
        catalog.insert(FinderTag(name: "Work"))
        #expect(catalog.systemOnly == TagCatalog(systemLabels: Self.labels))
    }

    @Test func mergingKeepsBothSides() {
        var a = TagCatalog(systemLabels: []), b = TagCatalog(systemLabels: [])
        a.insert(FinderTag(name: "A"))
        b.insert(FinderTag(name: "B", colorIndex: 3))
        #expect(a.merging(b).custom.map(\.name) == ["A", "B"])
    }

    @Test func rebasingKeepsCustomTagsOverNewLabels() {
        var catalog = TagCatalog(systemLabels: Self.labels)
        catalog.insert(FinderTag(name: "Work", colorIndex: 4))
        catalog.insert(FinderTag(name: "Rouge"))
        let french = ["Aucune", "Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"]
        let rebased = catalog.rebased(onSystemLabels: french)
        #expect(rebased.system.first == FinderTag(name: "Rouge", colorIndex: 6))
        #expect(rebased.custom == [FinderTag(name: "Work", colorIndex: 4)])
    }
}

/// xorshift64: repeatable shuffles.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite("Tag refresh policy (FE-081)")
struct TagRefreshPolicyTests {
    @Test func theFirstRunMayStart() {
        #expect(TagRefreshPolicy.mayStart(isRunning: false, lastStart: nil, now: 0))
    }

    @Test func onlyOneRunAtATime() {
        #expect(!TagRefreshPolicy.mayStart(isRunning: true, lastStart: nil, now: 0))
        #expect(!TagRefreshPolicy.mayStart(isRunning: true, lastStart: 0, now: 1_000))
    }

    @Test func atMostOnceAMinute() {
        let interval = TagRefreshPolicy.minimumInterval
        #expect(interval == 60)
        #expect(!TagRefreshPolicy.mayStart(isRunning: false, lastStart: 100, now: 100))
        #expect(!TagRefreshPolicy.mayStart(isRunning: false, lastStart: 100, now: 100 + interval - 0.001))
        #expect(TagRefreshPolicy.mayStart(isRunning: false, lastStart: 100, now: 100 + interval))
    }
}

@Suite("Tag harvest (FE-081)")
struct TagHarvestTests {
    let labels = TagCatalogTests.labels

    @Test func systemTagsNeedNoReads() {
        var harvest = TagHarvest(catalog: TagCatalog(systemLabels: labels))
        let reads = (0..<1_000).filter { _ in harvest.add([FinderTag(name: "Red"), FinderTag(name: "blue")]) }
        #expect(reads.isEmpty)
    }

    @Test func aColourFromTheIndexNeedsNoRead() {
        var harvest = TagHarvest(catalog: TagCatalog(systemLabels: labels))
        let wanted = harvest.add([FinderTag(name: "Work", colorIndex: 4)])
        #expect(!wanted)
    }

    @Test func eachCustomNameIsSampledAFixedNumberOfTimes() {
        var harvest = TagHarvest(catalog: TagCatalog(systemLabels: labels))
        let reads = (0..<1_000).filter { _ in harvest.add([FinderTag(name: "Work")]) }.count
        #expect(reads == TagHarvest.samplesPerName)
    }

    @Test func readingStopsOnceAColourIsKnown() {
        var harvest = TagHarvest(catalog: TagCatalog(systemLabels: labels))
        let first = harvest.add([FinderTag(name: "Work")])
        harvest.addColors([FinderTag(name: "Work", colorIndex: 2)])
        let second = harvest.add([FinderTag(name: "Work")])
        #expect(first && !second)
        #expect(harvest.catalog.tag(named: "Work")?.colorIndex == 2)
    }

    @Test func totalReadsAreBoundedEvenWithEndlessNames() {
        var harvest = TagHarvest(catalog: TagCatalog(systemLabels: []))
        // Descending, so every new name enters the catalog and pushes another out.
        let reads = (0..<20_000).reversed().filter { harvest.add([FinderTag(name: "n\(100_000 + $0)")]) }.count
        #expect(reads == TagHarvest.maxColorReads)
    }
}
