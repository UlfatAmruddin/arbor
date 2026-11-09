import Foundation
import Testing
@testable import ArborCore

/// A fixed clock: Saturday 7 November 2026, 15:30 UTC, weeks starting Sunday.
private let utc = TimeZone(secondsFromGMT: 0)!
private var calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    c.firstWeekday = 1
    return c
}()
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 15, minute: 30))!

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }

private func parse(_ text: String) -> Result<SearchExpression, SearchSyntaxError> {
    AQSParser.parse(text, now: now, calendar: calendar)
}

private func tree(_ text: String) -> String {
    switch parse(text) {
    case .success(let e): return e.debugDescription
    case .failure(let error): return "error: " + error.message
    }
}

private func error(_ text: String) -> String? {
    if case .failure(let e) = parse(text) { return e.message }
    return nil
}

private func expression(_ text: String) throws -> SearchExpression { try parse(text).get() }

@Suite("AQS parsing (FE-134, FE-236)")
struct AQSParsingTests {
    @Test func freeTextAndPhrases() {
        #expect(tree("report") == "report")
        #expect(tree("annual report") == "(annual AND report)")
        #expect(tree("\"annual report\"") == "annual report")
        #expect(tree("*.txt") == "~*.txt")
        #expect(tree("re?ort") == "~re?ort")
        #expect(tree("  spaced   out  ") == "(spaced AND out)")
    }

    @Test func booleanOperatorsAreUppercaseOnly() {
        #expect(tree("cats OR dogs") == "(cats OR dogs)")
        #expect(tree("cats AND dogs") == "(cats AND dogs)")
        #expect(tree("cats or dogs") == "((cats AND or) AND dogs)")
        #expect(tree("cats and dogs") == "((cats AND and) AND dogs)")
    }

    /// Documented: "apple AND pear OR plum" = "(apple AND pear) OR plum" (W11).
    @Test func mixedAndOrFoldLeftToRight() {
        #expect(tree("apple AND pear OR plum") == "((apple AND pear) OR plum)")
        // Not conventional precedence: OR before AND still binds first when it comes first.
        #expect(tree("apple OR pear AND plum") == "((apple OR pear) AND plum)")
        #expect(tree("apple OR pear plum") == "((apple OR pear) AND plum)")
        #expect(tree("a b OR c") == "((a AND b) OR c)")
        #expect(tree("a OR b OR c AND d") == "(((a OR b) OR c) AND d)")
    }

    @Test func parenthesesOverrideLeftToRight() {
        #expect(tree("apple AND (pear OR plum)") == "(apple AND (pear OR plum))")
        #expect(tree("(a OR b) AND (c OR d)") == "((a OR b) AND (c OR d))")
        #expect(tree("((a))") == "a")
    }

    @Test func negation() {
        #expect(tree("social NOT security") == "(social AND NOT security)")
        #expect(tree("NOT draft") == "NOT draft")
        #expect(tree("report -draft") == "(report AND NOT draft)")
        #expect(tree("-name:tmp") == "NOT name:tmp")
        #expect(tree("-(a OR b)") == "NOT (a OR b)")
        #expect(tree("a - b") == "((a AND -) AND b)")   // a lone dash is just text
    }

    @Test func nameAndExtension() {
        #expect(tree("name:report") == "name:report")
        #expect(tree("filename:report") == "name:report")
        #expect(tree("name:\"q3 report\"") == "name:q3 report")
        #expect(tree("name:=report.txt") == "name:=report.txt")
        #expect(tree("name:~<rep") == "name:~<rep")
        #expect(tree("ext:.txt") == "ext:=txt")
        #expect(tree("ext:txt") == "ext:=txt")
        #expect(tree("fileextension:pdf") == "ext:=pdf")
        #expect(tree("ext:(txt OR md)") == "(ext:=txt OR ext:=md)")
        #expect(tree("ext:do*") == "ext:~do*")
    }

    @Test func kinds() {
        #expect(tree("kind:folder") == "kind:folder")
        #expect(tree("kind:folders") == "kind:folder")
        #expect(tree("kind:pics") == "kind:picture")
        #expect(tree("kind:docs") == "kind:document")
        #expect(tree("kind:music") == "kind:music")
        #expect(tree("kind:videos") == "kind:video")
        #expect(tree("kind:text") == "kind:text")
        #expect(tree("kind:\"saved search\"") == "kind:savedsearch")
        #expect(tree("kind:<>folder") == "NOT kind:folder")
        #expect(error("kind:game")?.contains("no macOS equivalent") == true)
        #expect(error("kind:recordedtv")?.contains("Recorded TV") == true)
        #expect(error("kind:spaceship")?.contains("isn't a kind") == true)
    }

    @Test func typeAndFolder() {
        #expect(tree("type:pdf") == "type:pdf")
        #expect(tree("folder:projects") == "folderpath:projects")
        #expect(tree("folderpath:projects") == "folderpath:projects")
    }

    @Test func sizes() {
        let mb: Int64 = 1 << 20
        #expect(tree("size:>1MB") == "size:[\(mb + 1)..)")
        #expect(tree("size:>=1MB") == "size:[\(mb)..)")
        #expect(tree("size:<1KB") == "size:[..1024)")
        #expect(tree("size:<=1KB") == "size:[..1025)")
        #expect(tree("size:500") == "size:[500..501)")
        #expect(tree("size:5MB") == "size:[\(5 * mb)..\(6 * mb))")
        #expect(tree("size:1MB..5MB") == "size:[\(mb)..\(5 * mb + 1))")
        #expect(tree("System.Size:5kb..10kb") == "size:[5120..10241)")
        #expect(tree("size:empty") == "size:[0..1)")
        #expect(tree("size:tiny") == "size:[1..16384)")
        #expect(tree("size:small") == "size:[16384..\(mb))")
        #expect(tree("size:medium") == "size:[\(mb)..\(128 * mb))")
        #expect(tree("size:large") == "size:[\(128 * mb)..\(1024 * mb))")
        #expect(tree("size:huge") == "size:[\(1024 * mb)..\(4096 * mb))")
        #expect(tree("size:gigantic") == "size:[\(4096 * mb)..)")
        #expect(tree("size:>large") == "size:[\(1024 * mb)..)")
        #expect(tree("size:<>empty") == "NOT size:[0..1)")
        #expect(error("size:big")?.contains("isn't a size") == true)
        #expect(error("size:5MB..1MB")?.contains("ends before it starts") == true)
        #expect(error("size:~<5")?.contains("isn't supported") == true)
    }

    @Test func relativeDates() throws {
        func range(_ text: String) throws -> (Date?, Date?) {
            guard case .term(let t) = try expression(text), case .dateRange(let lo, let hi) = t.test else {
                Issue.record("not a date range: \(text)"); return (nil, nil)
            }
            return (lo, hi)
        }
        #expect(try range("datemodified:today") == (day(2026, 11, 7), day(2026, 11, 8)))
        #expect(try range("modified:yesterday") == (day(2026, 11, 6), day(2026, 11, 7)))
        #expect(try range("date:this week") == (day(2026, 11, 1), day(2026, 11, 8)))   // Sunday start
        #expect(try range("datemodified:last week") == (day(2026, 10, 25), day(2026, 11, 1)))
        #expect(try range("datemodified:this month") == (day(2026, 11, 1), day(2026, 12, 1)))
        #expect(try range("datemodified:last month") == (day(2026, 10, 1), day(2026, 11, 1)))
        #expect(try range("datemodified:this year") == (day(2026, 1, 1), day(2027, 1, 1)))
        #expect(try range("datemodified:last year") == (day(2025, 1, 1), day(2026, 1, 1)))
        #expect(try range("datemodified:\"last week\"") == (day(2026, 10, 25), day(2026, 11, 1)))
        #expect(try range("datecreated:today") == (day(2026, 11, 7), day(2026, 11, 8)))
        #expect(try expression("created:today").properties == [.dateCreated])
    }

    @Test func explicitDatesAndRanges() throws {
        func range(_ text: String) throws -> (Date?, Date?) {
            guard case .term(let t) = try expression(text), case .dateRange(let lo, let hi) = t.test else { return (nil, nil) }
            return (lo, hi)
        }
        #expect(try range("date:11/13/2026") == (day(2026, 11, 13), day(2026, 11, 14)))
        #expect(try range("date:11/13/21") == (day(2021, 11, 13), day(2021, 11, 14)))
        #expect(try range("date:2026-11-13") == (day(2026, 11, 13), day(2026, 11, 14)))
        #expect(try range("date:2026-02") == (day(2026, 2, 1), day(2026, 3, 1)))
        #expect(try range("date:2025") == (day(2025, 1, 1), day(2026, 1, 1)))
        #expect(try range("date:>11/13/21") == (day(2021, 11, 14), nil))
        #expect(try range("date:>=11/13/21") == (day(2021, 11, 13), nil))
        #expect(try range("date:<11/13/21") == (nil, day(2021, 11, 13)))
        #expect(try range("date:11/13/21..11/15/21") == (day(2021, 11, 13), day(2021, 11, 16)))
        #expect(try range("datemodified:2026-01-01..today") == (day(2026, 1, 1), day(2026, 11, 8)))
        #expect(error("date:2/30/2026")?.contains("isn't a date") == true)
        #expect(error("date:someday")?.contains("isn't a date") == true)
    }

    @Test func tagsAuthorsContents() {
        #expect(tree("tag:work") == "tags:work")
        #expect(tree("tags:work") == "tags:work")
        #expect(tree("author:(theresa OR lee)") == "(author:theresa OR author:lee)")
        #expect(tree("author:(theresa OR lee) folder:MyDocs") == "((author:theresa OR author:lee) AND folderpath:MyDocs)")
        #expect(tree("content:invoice") == "content:invoice")
        #expect(tree("content:\"due date\"") == "content:due date")
    }

    /// FE-237: canonical names work regardless of the UI language and mean the same as mnemonics.
    @Test func canonicalNamesMatchMnemonics() throws {
        #expect(try expression("System.Size:>1kb") == expression("size:>1kb"))
        #expect(try expression("system.size:>1kb") == expression("size:>1kb"))
        #expect(try expression("System.FileName:report") == expression("name:report"))
        #expect(try expression("System.ItemNameDisplay:report") == expression("name:report"))
        #expect(try expression("System.FileExtension:pdf") == expression("ext:pdf"))
        #expect(try expression("System.Kind:picture") == expression("kind:picture"))
        #expect(try expression("System.DateModified:today") == expression("datemodified:today"))
        #expect(try expression("System.DateCreated:today") == expression("datecreated:today"))
        #expect(try expression("System.Keywords:work") == expression("tags:work"))
        #expect(try expression("System.Author:lee") == expression("author:lee"))
        #expect(try expression("System.Search.Contents:x") == expression("content:x"))
        #expect(try expression("System.ItemFolderPathDisplay:docs") == expression("folder:docs"))
        // Every canonical name resolves to the property whose raw value it is.
        for p in SearchProperty.allCases { #expect(SearchProperty.lookup(p.canonicalName) == p) }
    }

    @Test func documentedCanonicalOperators() {
        #expect(tree("System.FileName:~\"Mic?osoft W*d\"") == "name:~Mic?osoft W*d")
        #expect(tree("System.Author:~!\"sanjay\"") == "NOT author:sanjay")
        #expect(tree("System.Keywords:=[]") == "tags:[]")
        #expect(tree("author:<>[]") == "NOT author:[]")
        #expect(tree("name:<>report") == "NOT name:=report")
    }

    /// FE-237: localized labels from other UI languages and unknown properties are rejected visibly.
    @Test func unknownAndLocalizedPropertiesAreRejected() {
        #expect(error("größe:>1MB")?.contains("isn't a search property") == true)
        #expect(error("taille:>1MB")?.contains("isn't a search property") == true)
        #expect(error("System.Music.Artist:queen")?.contains("isn't a search property") == true)
        #expect(error("foo:bar")?.contains("put it in quotes") == true)
        // Not property-shaped: plain text.
        #expect(tree("12:30") == "12:30")
        #expect(tree("\"foo:bar\"") == "foo:bar")
    }

    @Test func malformedQueriesExplainThemselves() {
        #expect(error("(report")?.contains("missing its closing") == true)
        #expect(error("report)")?.contains("without a matching") == true)
        #expect(error("\"report")?.contains("quotation mark") == true)
        #expect(error("AND report")?.contains("before it") == true)
        #expect(error("report OR")?.contains("after it") == true)
        #expect(error("report NOT")?.contains("after it") == true)
        #expect(error("name:")?.contains("Type a value") == true)
        #expect(error("size:>")?.contains("Type a value") == true)
        #expect(error("name:>report")?.contains("compares numbers or dates") == true)
        #expect(error("name:(a name:b)")?.contains("inside another") == true)
        #expect(error("\"\"")?.contains("empty") == true)
        #expect(error("")?.contains("Type something") == true)
        #expect(error("name:[]")?.contains("can't match") == true)
    }
}

// MARK: - Evaluation

private func candidate(_ name: String, folder: String = "/Users/me/Docs", isFolder: Bool = false, size: Int64? = 10,
                       modified: Date? = now, type: String? = nil, tags: [String]? = [], text: String? = nil) -> SearchCandidate {
    SearchCandidate(name: name, folderPath: folder, isFolder: isFolder, size: isFolder ? nil : size, modified: modified,
                    created: modified, typeIdentifier: type, typeDescription: isFolder ? "Folder" : "Plain Text Document",
                    tags: tags, authors: nil,
                    contentContains: text.map { t in { t.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } })
}

private func matches(_ query: String, _ c: SearchCandidate, contents: Bool = false) throws -> SearchTruth {
    SearchEvaluator(try expression(query), matchContents: contents).evaluate(c).truth
}

@Suite("Search evaluation")
struct SearchEvaluationTests {
    @Test func freeTextMatchesNamesIgnoringCaseAndAccents() throws {
        #expect(try matches("report", candidate("Q3 Report.pdf")) == .yes)
        #expect(try matches("resume", candidate("Résumé.docx")) == .yes)
        #expect(try matches("budget", candidate("Q3 Report.pdf")) == .no)
        #expect(try matches("q3 report", candidate("Report Q3.pdf")) == .yes)
        #expect(try matches("\"q3 report\"", candidate("Report Q3.pdf")) == .no)
    }

    @Test func wildcards() throws {
        #expect(try matches("*.txt", candidate("notes.txt")) == .yes)
        #expect(try matches("*.txt", candidate("notes.txt.bak")) == .no)
        #expect(try matches("re?ort*", candidate("Report final.doc")) == .yes)
        #expect(TextMatcher.wildcard("abcabc", "*c*c") == true)
        #expect(TextMatcher.wildcard("abc", "a*b") == false)
        #expect(TextMatcher.wildcard("", "*") == true)
    }

    @Test func extensionIsWholeAndFoldersHaveNone() throws {
        #expect(try matches("ext:doc", candidate("a.doc")) == .yes)
        #expect(try matches("ext:doc", candidate("a.docx")) == .no)
        #expect(try matches("ext:.DOC", candidate("a.doc")) == .yes)
        #expect(try matches("ext:txt", candidate("archive.txt", isFolder: true)) == .no)
        #expect(try matches("type:.txt", candidate("a.txt")) == .yes)
        #expect(try matches("type:\"plain text\"", candidate("a.md")) == .yes)
    }

    @Test func kindsUseUniformTypes() throws {
        #expect(try matches("kind:folder", candidate("Sub", isFolder: true)) == .yes)
        #expect(try matches("kind:folder", candidate("a.txt")) == .no)
        #expect(try matches("kind:picture", candidate("a.png", type: "public.png")) == .yes)
        #expect(try matches("kind:picture", candidate("a.jpg")) == .yes)    // from the extension
        #expect(try matches("kind:music", candidate("a.mp3", type: "public.mp3")) == .yes)
        #expect(try matches("kind:video", candidate("a.mov", type: "com.apple.quicktime-movie")) == .yes)
        #expect(try matches("kind:document", candidate("a.pdf", type: "com.adobe.pdf")) == .yes)
        #expect(try matches("kind:document", candidate("a.png", type: "public.png")) == .no)
        #expect(try matches("kind:text", candidate("a.swift", type: "public.swift-source")) == .yes)
        #expect(try matches("kind:program", candidate("Calc.app", type: "com.apple.application-bundle")) == .yes)
        #expect(try matches("kind:savedsearch", candidate("q.arborsearch")) == .yes)
    }

    @Test func sizesSkipFolders() throws {
        #expect(try matches("size:>1KB", candidate("a.bin", size: 4096)) == .yes)
        #expect(try matches("size:>1KB", candidate("a.bin", size: 1024)) == .no)
        #expect(try matches("size:>=1KB", candidate("a.bin", size: 1024)) == .yes)
        #expect(try matches("size:empty", candidate("a.bin", size: 0)) == .yes)
        #expect(try matches("size:<1MB", candidate("Sub", isFolder: true)) == .no)
        #expect(try matches("size:1KB..2KB", candidate("a.bin", size: 2048)) == .yes)
        #expect(try matches("size:1KB..2KB", candidate("a.bin", size: 2049)) == .no)
    }

    @Test func dates() throws {
        #expect(try matches("datemodified:today", candidate("a", modified: now)) == .yes)
        #expect(try matches("datemodified:yesterday", candidate("a", modified: now)) == .no)
        #expect(try matches("datemodified:this week", candidate("a", modified: day(2026, 11, 2))) == .yes)
        #expect(try matches("datemodified:today", candidate("a", modified: nil)) == .unknown)
    }

    @Test func tagsAndUnknownMetadata() throws {
        #expect(try matches("tag:work", candidate("a", tags: ["Work"])) == .yes)
        #expect(try matches("tag:wor", candidate("a", tags: ["Work"])) == .no)   // tags compare whole
        #expect(try matches("tag:work", candidate("a", tags: nil)) == .unknown)
        #expect(try matches("tags:=[]", candidate("a", tags: [])) == .yes)
        #expect(try matches("author:lee", candidate("a")) == .unknown)          // authors aren't read directly
        #expect(try matches("folder:docs", candidate("a")) == .yes)
        #expect(try matches("folder:music", candidate("a")) == .no)
    }

    @Test func contents() throws {
        let c = candidate("notes.txt", text: "The invoice is due Friday")
        #expect(try matches("content:invoice", c) == .yes)
        #expect(try matches("content:\"due friday\"", c) == .yes)
        #expect(try matches("content:refund", c) == .no)
        #expect(try matches("content:invoice", candidate("photo.png")) == .unknown)   // can't read
        #expect(try matches("content:invoice", candidate("Sub", isFolder: true)) == .no)
        // Free text matches contents only with the File contents option.
        #expect(try matches("invoice", c) == .no)
        #expect(try matches("invoice", c, contents: true) == .yes)
        #expect(try matches("notes", c, contents: true) == .yes)
    }

    /// Kleene logic: an unknown part never becomes a false "no match" or a false "match".
    @Test func threeValuedLogic() throws {
        let png = candidate("invoice.png")
        #expect(try matches("invoice OR content:x", png) == .yes)
        #expect(try matches("invoice AND content:x", png) == .unknown)
        #expect(try matches("budget AND content:x", png) == .no)
        #expect(try matches("budget OR content:x", png) == .unknown)
        #expect(try matches("NOT content:x", png) == .unknown)
        #expect(try matches("NOT invoice", png) == .no)
    }

    @Test func reasons() throws {
        let c = candidate("notes.txt", text: "invoice")
        #expect(SearchEvaluator(try expression("notes")).evaluate(c).reasons == [.name])
        #expect(SearchEvaluator(try expression("invoice"), matchContents: true).evaluate(c).reasons == [.contents])
        #expect(SearchEvaluator(try expression("ext:txt size:<1KB")).evaluate(c).reasons
                == [.property(.fileExtension), .property(.size)])
        #expect(SearchReason.archiveEntry("a/b.txt").label == "In archive: a/b.txt")
    }

    /// FE-236 against data: left-to-right gives a different answer than AND-before-OR precedence.
    @Test func leftToRightChangesResults() throws {
        // "apple OR pear AND plum": AQS = (apple OR pear) AND plum; conventional = apple OR (pear AND plum).
        let apple = candidate("apple.txt")
        #expect(try matches("apple OR pear AND plum", apple) == .no)
        #expect(try matches("apple OR (pear AND plum)", apple) == .yes)
        #expect(try matches("apple OR pear AND plum", candidate("apple plum.txt")) == .yes)
    }
}

@Suite("Spotlight translation (FE-143)")
struct SpotlightPredicateTests {
    func predicate(_ q: String, contents: Bool = false) throws -> SpotlightPredicate? {
        SpotlightPredicate.make(try expression(q), matchContents: contents)
    }

    @Test func basicTerms() throws {
        #expect(try predicate("report")?.query == "kMDItemFSName == \"*report*\"cd")
        #expect(try predicate("report")?.isExact == true)
        #expect(try predicate("ext:pdf")?.query == "kMDItemFSName == \"*.pdf\"c")
        #expect(try predicate("content:invoice")?.query == "kMDItemTextContent == \"*invoice*\"cd")
        #expect(try predicate("size:>1KB")?.query == "kMDItemFSSize >= 1025")
        #expect(try predicate("kind:picture")?.query == "kMDItemContentTypeTree == \"public.image\"")
        #expect(try predicate("tag:work")?.query == "kMDItemUserTags == \"work\"cd")
        #expect(try predicate("datemodified:today")?.query
                == "(kMDItemFSContentChangeDate >= $time.iso(2026-11-07T00:00:00Z) && kMDItemFSContentChangeDate < $time.iso(2026-11-08T00:00:00Z))")
        #expect(try predicate("invoice", contents: true)?.query
                == "(kMDItemFSName == \"*invoice*\"cd || kMDItemTextContent == \"*invoice*\"cd)")
    }

    @Test func escaping() throws {
        #expect(try predicate("\"say hi\"")?.query == "kMDItemFSName == \"*say hi*\"cd")
        #expect(SpotlightPredicate.escape("a\"b\\c*d?", keepWildcards: false) == "a\\\"b\\\\c\\*d\\?")
        #expect(SpotlightPredicate.escape("a*b?", keepWildcards: true) == "a*b*")
        #expect(SpotlightPredicate.escape("$time.today", keepWildcards: true) == "\\$time.today")
        #expect(try predicate("\"$time.today\"")?.query == "kMDItemFSName == \"*\\$time.today*\"cd")
    }

    @Test func untranslatablePartsMakeASuperset() throws {
        let and = try predicate("report folder:docs")
        #expect(and?.query == "kMDItemFSName == \"*report*\"cd")
        #expect(and?.isExact == false)
        #expect(try predicate("report OR folder:docs") == nil)
        #expect(try predicate("folder:docs") == nil)
    }

    @Test func negationIsPushedDown() throws {
        #expect(try predicate("NOT report")?.query == "kMDItemFSName != \"*report*\"cd")
        #expect(try predicate("NOT (a OR b)")?.query == "(kMDItemFSName != \"*a*\"cd && kMDItemFSName != \"*b*\"cd)")
        // Optional attributes are never negated (files without authors would vanish).
        #expect(try predicate("NOT author:lee") == nil)
        #expect(try predicate("report NOT content:x")?.isExact == false)
    }

    @Test func indexStateParsing() {
        #expect(SpotlightIndexState.parse(mdutilOutput: "/:\n\tIndexing enabled. ") == .enabled)
        #expect(SpotlightIndexState.parse(mdutilOutput: "/Volumes/USB:\n\tIndexing disabled.") == .disabled)
        #expect(SpotlightIndexState.parse(mdutilOutput: "Error: unknown indexing state.") == .unknown)
    }
}

@Suite("Search options editing (FE-136)")
struct QueryEditorTests {
    @Test func addsReplacesAndRemoves() {
        #expect(AQSQueryEditor.setting(.dateModified, to: "today", in: "report") == "report datemodified:today")
        #expect(AQSQueryEditor.setting(.dateModified, to: "last week", in: "report datemodified:today")
                == "report datemodified:\"last week\"")
        #expect(AQSQueryEditor.setting(.dateModified, to: nil, in: "report datemodified:last week size:large")
                == "report size:large")
        #expect(AQSQueryEditor.setting(.size, to: "large", in: "") == "size:large")
        #expect(AQSQueryEditor.setting(.kind, to: "picture", in: "a (kind:music OR b)") == "a (kind:music OR b) kind:picture")
        #expect(AQSQueryEditor.setting(.dateModified, to: nil, in: "System.DateModified:today x") == "x")
    }

    @Test func readsActiveRestrictions() {
        #expect(AQSQueryEditor.restrictions(.dateModified, in: "report datemodified:last week") == ["datemodified:last week"])
        #expect(AQSQueryEditor.restrictions(.kind, in: "report") == [])
    }
}
