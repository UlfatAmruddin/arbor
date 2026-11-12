import CryptoKit
import Foundation
import Testing
@testable import ArborCore

@Suite("In-app updates: configuration (FE-259)")
struct UpdateConfigurationTests {
    let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func needsAnHTTPSFeedAndAKey() {
        #expect(UpdateConfiguration(feed: "https://example.com/releases/latest/download/appcast.xml", publicKey: key) != nil)
        #expect(UpdateConfiguration(feed: nil, publicKey: key) == nil)
        #expect(UpdateConfiguration(feed: "https://example.com/appcast.xml", publicKey: nil) == nil)
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "ftp://example.com/a.xml", "https:///appcast.xml",
                     "https://user:secret@example.com/appcast.xml", "https://example.com/appcast.xml#x", "not a url", ""] {
            #expect(UpdateConfiguration(feed: feed, publicKey: key) == nil, "\(feed)")
        }
        #expect(UpdateConfiguration(feed: "https://example.com/" + String(repeating: "a", count: 3000), publicKey: key) == nil)
    }

    @Test func plainHTTPOnlyForATestFeedOnThisMac() {
        #expect(UpdateConfiguration(feed: "http://127.0.0.1:8765/appcast.xml", publicKey: key) == nil)
        #expect(UpdateConfiguration(feed: "http://127.0.0.1:8765/appcast.xml", publicKey: key, allowsLoopback: true) != nil)
        #expect(UpdateConfiguration(feed: "http://localhost:8765/appcast.xml", publicKey: key, allowsLoopback: true) != nil)
        #expect(UpdateConfiguration(feed: "http://example.com/appcast.xml", publicKey: key, allowsLoopback: true) == nil)
        #expect(UpdateConfiguration(feed: "http://127.0.0.1.example.com/appcast.xml", publicKey: key, allowsLoopback: true) == nil)
    }

    @Test func theKeyIsThirtyTwoBytesOfBase64() {
        #expect(UpdateConfiguration.isPublicKey(key))
        #expect(!UpdateConfiguration.isPublicKey(Data(repeating: 7, count: 31).base64EncodedString()))
        #expect(!UpdateConfiguration.isPublicKey(Data(repeating: 7, count: 33).base64EncodedString()))
        #expect(!UpdateConfiguration.isPublicKey(String(repeating: "!", count: 44)))
        #expect(!UpdateConfiguration.isPublicKey(""))
    }

    @Test func headlessAndScriptedRunsHaveNoUpdater() {
        let feed = "https://example.com/appcast.xml", test = "http://127.0.0.1:9/appcast.xml"
        #expect(UpdateConfiguration.plan(feed: feed, publicKey: key, testFeed: nil, headless: false, scripted: false)
                == .run(UpdateConfiguration(feed: feed, publicKey: key)!))
        #expect(UpdateConfiguration.plan(feed: feed, publicKey: key, testFeed: nil, headless: true, scripted: false) == .off(.headless))
        #expect(UpdateConfiguration.plan(feed: feed, publicKey: key, testFeed: test, headless: true, scripted: true) == .off(.headless))
        #expect(UpdateConfiguration.plan(feed: feed, publicKey: key, testFeed: nil, headless: false, scripted: true) == .off(.scripted))
        #expect(UpdateConfiguration.plan(feed: nil, publicKey: nil, testFeed: nil, headless: false, scripted: false) == .off(.notConfigured))
    }

    @Test func aTestFeedReplacesTheFeedButNotTheKey() {
        let test = "http://127.0.0.1:9/appcast.xml"
        #expect(UpdateConfiguration.plan(feed: nil, publicKey: key, testFeed: test, headless: false, scripted: true)
                == .run(UpdateConfiguration(feed: test, publicKey: key, allowsLoopback: true)!))
        #expect(UpdateConfiguration.plan(feed: nil, publicKey: nil, testFeed: test, headless: false, scripted: true) == .off(.notConfigured))
        #expect(UpdateConfiguration.plan(feed: nil, publicKey: key, testFeed: "http://example.com/a.xml", headless: false, scripted: false)
                == .off(.notConfigured))
    }
}

@Suite("In-app updates: the Update button (FE-259)")
struct UpdateNoticeTests {
    @Test func aScheduledFindShowsTheButtonUntilSeen() {
        let found = UpdateNotice.none.after(.found(version: "0.4.0", shownByUpdater: false))
        #expect(found == .available(version: "0.4.0"))
        #expect(found.isAvailable)
        #expect(found.after(.seen) == .none)
        #expect(found.after(.finished) == .none)
    }

    @Test func aCheckTheUserAskedForShowsNoButton() {
        #expect(UpdateNotice.none.after(.found(version: "0.4.0", shownByUpdater: true)) == .none)
        #expect(UpdateNotice.available(version: "0.4.0").after(.found(version: "0.4.0", shownByUpdater: true)) == .none)
    }

    @Test func versionTextFromTheFeedIsShownOnlyWhenPlain() {
        #expect(UpdateNotice.displayVersion(" 0.4.0 ") == "0.4.0")
        #expect(UpdateNotice.displayVersion("1.0 (beta-2)") == "1.0 (beta-2)")
        for hostile in ["", "0.4.0\nSee https://evil.example", "0.4.0\u{202E}", "<b>0.4</b>", "0.4.0 – now", String(repeating: "9", count: 33)] {
            #expect(UpdateNotice.displayVersion(hostile) == nil, "\(hostile)")
        }
        #expect(UpdateNotice.none.after(.found(version: "<script>", shownByUpdater: false)) == .available(version: nil))
    }
}

@Suite("In-app updates: release notes from the changelog (FE-259)")
struct ReleaseNotesTests {
    let changelog = """
        # Changelog

        Intro with a [link](docs/SPEC.md).

        ## 0.3.10

        ### New
        - Ten.

        ## 0.3.1

        ### Fixed
        - Details: a rename stays open when you come back to Arbor or a custom
          icon turns up; neither keeps the half-typed name.
        - Address bar: `shell:downloads` & <b>tags</b> show as "written".

        ## 0.3.0

        ### New
        - Older.
        """

    @Test func takesOnlyThatVersionsSection() throws {
        let section = try #require(ReleaseNotes.section(for: "0.3.1", in: changelog))
        #expect(section.hasPrefix("### Fixed"))
        #expect(!section.contains("Ten."))
        #expect(!section.contains("Older."))
        #expect(ReleaseNotes.section(for: "0.3", in: changelog) == nil)
        #expect(ReleaseNotes.section(for: "9.9.9", in: changelog) == nil)
    }

    @Test func headingsBulletsAndContinuations() throws {
        let html = ReleaseNotes.html(fromMarkdown: try #require(ReleaseNotes.section(for: "0.3.1", in: changelog)))
        #expect(html == """
            <h3>Fixed</h3>
            <ul>
            <li>Details: a rename stays open when you come back to Arbor or a custom icon turns up; neither keeps the half-typed name.</li>
            <li>Address bar: <code>shell:downloads</code> &amp; &lt;b&gt;tags&lt;/b&gt; show as &quot;written&quot;.</li>
            </ul>
            """)
    }

    @Test func everyCharacterThatMattersIsEscaped() {
        #expect(ReleaseNotes.escape(#"<a href="x" onclick='y'>&</a>"#) == "&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;")
        let html = ReleaseNotes.html(fromMarkdown: "- `<script>alert(1)</script>`\n- [click](javascript:alert(1))\n\nA `lone tick")
        #expect(!html.contains("<script"))
        #expect(html.contains("<code>&lt;script&gt;alert(1)&lt;/script&gt;</code>"))
        #expect(html.contains("<li>[click](javascript:alert(1))</li>"))
        #expect(html.contains("<p>A `lone tick</p>"))
    }

    @Test func paragraphsAndListsEndAtBlankLinesAndHeadings() {
        let html = ReleaseNotes.html(fromMarkdown: "One line\nand more.\n\n- a\n- b\nAfter.\n#### Small\n##### Smaller")
        #expect(html == "<p>One line and more.</p>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>After.</p>\n<h4>Small</h4>\n<h5>Smaller</h5>")
    }
}

@Suite("In-app updates: the appcast (FE-259)")
struct AppcastTests {
    func item(notes: String = "<h3>New</h3>\n<ul>\n<li>A &amp; B</li>\n</ul>") -> AppcastItem {
        AppcastItem(shortVersion: "0.4.0", build: "512", minimumSystemVersion: "14.0",
                    downloadURL: URL(string: "https://example.com/releases/download/v0.4.0/Arbor-0.4.0.zip")!, length: 12_345,
                    edSignature: Data(repeating: 1, count: 64).base64EncodedString(), notesHTML: notes,
                    published: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func oneItemThatSparkleReads() throws {
        let xml = try Appcast.xml(item())
        let document = try XMLDocument(xmlString: xml)
        let entry = try #require(try document.nodes(forXPath: "/rss/channel/item").first as? XMLElement)
        func child(_ name: String) -> String? { entry.elements(forName: name).first?.stringValue }
        #expect(try document.nodes(forXPath: "/rss/channel/item").count == 1)
        #expect(child("sparkle:version") == "512")
        #expect(child("sparkle:shortVersionString") == "0.4.0")
        #expect(child("sparkle:minimumSystemVersion") == "14.0")
        #expect(child("pubDate") == "Fri, 15 Jan 2027 08:00:00 +0000")
        #expect(child("description") == item().notesHTML)
        let enclosure = try #require(entry.elements(forName: "enclosure").first)
        #expect(enclosure.attribute(forName: "url")?.stringValue == "https://example.com/releases/download/v0.4.0/Arbor-0.4.0.zip")
        #expect(enclosure.attribute(forName: "length")?.stringValue == "12345")
        #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == item().edSignature)
    }

    @Test func notesCannotBreakOutOfTheDescription() throws {
        let hostile = "</description><enclosure url=\"https://evil.example/x.zip\"/>]]>"
        let xml = try Appcast.xml(item(notes: hostile))
        let document = try XMLDocument(xmlString: xml)
        #expect(try document.nodes(forXPath: "//enclosure").count == 1)
        #expect((try document.nodes(forXPath: "//description").first)?.stringValue == hostile)
    }

    @Test func refusesWhatSparkleWouldMisread() {
        var bad = item(); bad.build = "512a"
        #expect(throws: AppcastError.self) { try Appcast.xml(bad) }
        bad = item(); bad.shortVersion = "0.4.0<"
        #expect(throws: AppcastError.self) { try Appcast.xml(bad) }
        bad = item(); bad.downloadURL = URL(string: "http://example.com/Arbor.zip")!
        #expect(throws: AppcastError.self) { try Appcast.xml(bad) }
        bad = item(); bad.length = 0
        #expect(throws: AppcastError.self) { try Appcast.xml(bad) }
        bad = item(); bad.edSignature = "abc"
        #expect(throws: AppcastError.self) { try Appcast.xml(bad) }
        #expect(throws: AppcastError.self) { try Appcast.xml(item(notes: "bell \u{07}")) }
    }

    @Test func aTestFeedMayDownloadFromThisMac() throws {
        var local = item(); local.downloadURL = URL(string: "http://127.0.0.1:8765/Arbor-0.4.0.zip")!
        #expect(try Appcast.xml(local).contains("http://127.0.0.1:8765/Arbor-0.4.0.zip"))
    }
}

@Suite("In-app updates: archive signatures (FE-259)")
struct UpdateSignatureTests {
    @Test func acceptsOnlyTheMatchingKeyAndBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("Arbor-0.4.0.zip bytes".utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(UpdateSignature.isValid(signature, of: data, publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature, of: data + Data([0]), publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateSignature.isValid(signature, of: data, publicKey: other))
        #expect(!UpdateSignature.isValid("not base64", of: data, publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature, of: data, publicKey: "short"))
    }
}
