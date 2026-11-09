import FileProvider
import Foundation
import Testing
@testable import ArborCore

@Suite("Cloud folder names (FE-195)")
struct CloudFolderNameTests {
    @Test(arguments: [
        ("OneDrive-Personal", "OneDrive", "Personal", CloudAccountKind.personal),
        ("onedrive-PERSONAL", "OneDrive", "PERSONAL", .personal),
        ("OneDrive-Contoso Ltd", "OneDrive", "Contoso Ltd", .workOrSchool),
        ("OneDrive-Contoso (UK)", "OneDrive", "Contoso (UK)", .workOrSchool),
        ("OneDrive-Personal (1)", "OneDrive", "Personal (1)", .unknown),
        ("OneDrive-jane@example.com", "OneDrive", "jane@example.com", .unknown),
        ("GoogleDrive-jane@example.com", "Google Drive", "jane@example.com", .unknown),
        ("GoogleDrive-jane@gmail.com", "Google Drive", "jane@gmail.com", .personal),
        ("GoogleDrive-jane@GoogleMail.com", "Google Drive", "jane@GoogleMail.com", .personal),
        ("GoogleDrive-jane@gmail.com.example.org", "Google Drive", "jane@gmail.com.example.org", .unknown),
        ("GoogleDrive-a@gmail.com@example.org", "Google Drive", "a@gmail.com@example.org", .unknown),
        ("Dropbox-Personal", "Dropbox", "Personal", .personal),
        ("Dropbox (Personal)", "Dropbox", "Personal", .personal),
        ("Dropbox (Business)", "Dropbox", "Business", .workOrSchool),
        ("Dropbox (Acme-Corp)", "Dropbox", "Acme-Corp", .workOrSchool),
        ("Dropbox-Acme", "Dropbox", "Acme", .workOrSchool),
        ("AcmeSync-work", "AcmeSync", "work", .unknown),
        ("SharePoint-Contoso", "SharePoint", "Contoso", .workOrSchool),
    ]) func accountForms(_ name: String, _ provider: String, _ account: String, _ kind: CloudAccountKind) {
        let identity = CloudFolderName.parse(name)
        #expect(identity.provider == provider)
        #expect(identity.account == account)
        #expect(identity.accountKind == kind)
    }

    @Test(arguments: ["OneDrive", "Dropbox", "GoogleDrive", "Box-Box", "Box-", "Dropbox ()", "Dropbox-Dropbox", "GoogleDrive-Google Drive"])
    func noAccountIsUnknown(_ name: String) {
        let identity = CloudFolderName.parse(name)
        #expect(identity.account == nil)
        #expect(identity.accountKind == .unknown)
    }

    @Test func sharedLibrariesAreTheOrganizations() {
        let named = CloudFolderName.parse("OneDrive-SharedLibraries-Contoso")
        #expect(named.provider == "OneDrive" && named.account == "Contoso shared libraries" && named.accountKind == .workOrSchool)
        #expect(CloudFolderName.parse("OneDrive-SharedLibraries").account == "Shared libraries")
    }

    @Test(arguments: ["", "-", "--", " ", "(", ")", " ()", "- (x)", "\u{202E}", "\u{0}\u{7F}"])
    func degenerateNamesStillHaveALabel(_ name: String) {
        let identity = CloudFolderName.parse(name)
        #expect(!identity.provider.isEmpty)
        #expect(identity.accountKind == .unknown)
        #expect(identity.entry == nil)
    }

    @Test func aPrefixMustBeTheWholeWord() {
        for name in ["OneDriveEvil-Personal", "xOneDrive-Personal", "One Drive-Personal", "Dropboxx (Business)"] {
            let identity = CloudFolderName.parse(name)
            #expect(identity.entry == nil, "\(name)")
            #expect(identity.accountKind == .unknown, "\(name)")
        }
    }

    @Test func hostileNamesBecomePlainBoundedText() {
        let identity = CloudFolderName.parse("OneDrive-Ev\u{202E}il\nCo\u{200B}rp\u{0}")
        #expect(identity.account == "EvilCorp")
        let long = CloudFolderName.parse("OneDrive-" + String(repeating: "x", count: 100_000))
        #expect((long.account?.count ?? 0) <= CloudFolderName.maxLength + 1)
    }

    @Test func navigationTitleSaysTheKindOnce() {
        func root(_ name: String) -> CloudRoot {
            let id = CloudFolderName.parse(name)
            return CloudRoot(url: URL(fileURLWithPath: "/Users/me/x"), provider: id.provider, account: id.account, kind: .fileProvider, accountKind: id.accountKind, entry: id.entry)
        }
        #expect(root("OneDrive-Personal").navigationTitle == "OneDrive – Personal")
        #expect(root("OneDrive-Contoso").navigationTitle == "OneDrive – Contoso (Work/School)")
        #expect(root("Dropbox").navigationTitle == "Dropbox (Account unknown)")
        #expect(root("GoogleDrive-a@gmail.com").navigationTitle == "Google Drive – a@gmail.com (Personal)")
        let iCloud = CloudRoot(url: URL(fileURLWithPath: "/Users/me/i"), provider: "iCloud Drive", account: nil, kind: .iCloud, entry: CloudProviderCatalog.iCloud)
        #expect(iCloud.navigationTitle == "iCloud Drive")
    }

    @Test func detectionUsesTheParserAndReadsNoContent() throws {
        let fx = try Fixture()
        _ = try fx.folder("Library/CloudStorage/OneDrive-Contoso")
        _ = try fx.folder("Library/CloudStorage/Dropbox (Business)")
        let roots = CloudRoots.detect(home: fx.root)
        #expect(roots.map(\.displayName) == ["Dropbox – Business", "OneDrive – Contoso"])
        #expect(roots.map(\.accountKind) == [.workOrSchool, .workOrSchool])
        #expect(roots.allSatisfy { $0.kind == .fileProvider && $0.entry != nil })
    }

    @Test func simulatedStorageIsAlwaysATestRoot() throws {
        let fx = try Fixture()
        _ = try fx.folder("s/OneDrive-Personal")
        let roots = CloudRoots.testRoots(environment: ["ARBOR_TEST_CLOUD_STORAGE": fx.url("s").path])
        #expect(roots.map(\.kind) == [.test])
        #expect(roots.first?.accountKind == .personal)
    }
}

@Suite("Cloud provider table (FE-192)")
struct CloudProviderTableTests {
    @Test func prefixesAreUniqueLowercaseWords() {
        let prefixes = CloudProviderCatalog.entries.map(\.folderPrefix)
        #expect(Set(prefixes).count == prefixes.count)
        for prefix in prefixes {
            #expect(!prefix.isEmpty && prefix == prefix.lowercased() && !prefix.contains("-") && !prefix.contains(" "))
        }
    }

    @Test func identifiersAreReverseDNSConstants() {
        for identifier in CloudProviderCatalog.entries.flatMap(\.bundleIdentifiers) {
            #expect(identifier.split(separator: ".").count >= 3, "\(identifier)")
            #expect(identifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }, "\(identifier)")
        }
    }

    @Test(arguments: [("OneDrive-Personal", "com.microsoft.OneDrive"), ("GoogleDrive-a@b.org", "com.google.drivefs"),
                      ("Dropbox", "com.getdropbox.dropbox"), ("Box-Box", "com.box.desktop")])
    func mainProvidersHandOffToTheirApp(_ folder: String, _ identifier: String) {
        let entry = CloudFolderName.parse(folder).entry
        #expect(entry?.handoff(isInstalled: { $0 == identifier }) == .application(bundleIdentifier: identifier))
    }

    @Test func nothingIsOfferedWithoutTheApp() {
        for entry in CloudProviderCatalog.entries { #expect(entry.handoff(isInstalled: { _ in false }) == nil) }
    }

    @Test func theStoreEditionOfOneDriveCounts() {
        let entry = CloudProviderCatalog.entry(forFolderPrefix: "OneDrive")
        #expect(entry?.handoff(isInstalled: { $0 == "com.microsoft.OneDrive-mac" }) == .application(bundleIdentifier: "com.microsoft.OneDrive-mac"))
    }

    @Test func iCloudOpensItsSettingsPane() {
        let entry = CloudProviderCatalog.iCloud
        #expect(entry.handoff(isInstalled: { _ in false }) == .settingsPane(entry.settingsPane!))
        #expect(entry.settingsPane?.scheme == "x-apple.systempreferences")
        #expect(entry.commandTitle(needsSignIn: false) == "Open iCloud Settings")
        #expect(entry.commandTitle(needsSignIn: true) == "Sign in to iCloud Drive")
        #expect(CloudProviderCatalog.entry(forFolderPrefix: "") == nil)
    }

    @Test func titlesNameTheTableEntry() {
        let entry = CloudProviderCatalog.entry(forFolderPrefix: "dropbox")
        #expect(entry?.commandTitle(needsSignIn: false) == "Open Dropbox")
        #expect(entry?.commandTitle(needsSignIn: true) == "Sign in to Dropbox")
    }
}

@Suite("Cloud provider errors (FE-192, FE-195)")
struct CloudProviderErrorTests {
    private let signedOut = NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.notAuthenticated.rawValue)

    private func wrapped(_ error: NSError, depth: Int) -> NSError {
        (0..<depth).reduce(error) { inner, _ in NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: inner]) }
    }

    @Test func notSignedInIsRecognized() {
        #expect(CloudProviderError.requiresSignIn(signedOut))
        #expect(CloudProviderError.requiresSignIn(NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)))
        #expect(CloudProviderError.requiresSignIn(wrapped(signedOut, depth: 3)))
        #expect(CloudProviderError.requiresSignIn(NSError(domain: "x", code: 1, userInfo: [NSMultipleUnderlyingErrorsKey: [NSError(domain: "y", code: 2), signedOut]])))
    }

    @Test func otherFailuresAreNot() {
        let others = [
            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.serverUnreachable.rawValue),
            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.insufficientQuota.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: "AcmeSync", code: NSFileProviderError.Code.notAuthenticated.rawValue),
        ]
        for error in others { #expect(!CloudProviderError.requiresSignIn(error), "\(error)") }
    }

    @Test func theWordingNeverCounts() {
        let error = NSError(domain: "AcmeSync", code: 7, userInfo: [NSLocalizedDescriptionKey: "You are not signed in. Please sign in."])
        #expect(!CloudProviderError.requiresSignIn(error))
    }

    @Test func aDeepOrWideChainEnds() {
        #expect(!CloudProviderError.requiresSignIn(wrapped(NSError(domain: "x", code: 1), depth: 100)))
        #expect(!CloudProviderError.requiresSignIn(wrapped(signedOut, depth: 64)), "past the limit proves nothing")
        let wide = (0..<100).map { NSError(domain: "x", code: $0) }
        #expect(!CloudProviderError.requiresSignIn(NSError(domain: "x", code: 0, userInfo: [NSMultipleUnderlyingErrorsKey: wide])))
    }

    @Test func aFailingListingBecomesSignInOnlyForTheCode() {
        #expect(DirectoryLister.map(signedOut, path: "/Users/me/x") == .signInRequired(path: "/Users/me/x", message: CloudProviderError.message(signedOut)))
        #expect(CloudEnumeration(listingError: ListingError.signInRequired(path: "/x", message: "m")) == .signInRequired("m"))
        let gone = ListingError.notFound(path: "/x")
        #expect(CloudEnumeration(listingError: gone) == .failed(CloudProviderError.message(gone)))
    }

    @Test func theSimulatedFailuresUseRealCodes() throws {
        let signIn = try #require(CloudProviderError.simulatedListingFailure("signin"))
        #expect(CloudProviderError.requiresSignIn(signIn))
        let failed = try #require(CloudProviderError.simulatedListingFailure("failed"))
        #expect(!CloudProviderError.requiresSignIn(failed))
        #expect(CloudProviderError.simulatedListingFailure("bogus") == nil)
    }

    @Test func statusCarriesBothKeysOnce() {
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, downloadError: "a", uploadError: "b")) == .error("a · b"))
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, downloadError: "a", uploadError: "a")) == .error("a"))
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, uploadError: "b")) == .error("b"))
    }

    @Test func aFailureOutranksEverythingAndStaysPlainText() {
        let hostile = UbiquityInfo(isUbiquitous: true, download: .current, isDownloading: true, downloadError: "Bad\u{202E}\nname\u{0}", hasConflicts: true)
        #expect(CloudStatusMapper.status(hostile) == .error("Badname"))
        let long = CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, downloadError: String(repeating: "x", count: 100_000)))
        if case .error(let text) = long { #expect(text.count <= CloudProviderError.maxMessageLength + 1) } else { Issue.record("not an error") }
        #expect(CloudStatusMapper.status(UbiquityInfo(isUbiquitous: true, downloadError: "\u{202E}")) == .error(""))
    }

    @Test func signInIsItsOwnStatus() {
        let info = UbiquityInfo(isUbiquitous: true, downloadError: "Not signed in", authenticationRequired: true)
        let status = CloudStatusMapper.status(info)
        #expect(status == .signInRequired("Not signed in"))
        #expect(status.title == "Sign in required: Not signed in")
        #expect(status.isFailure && status.needsProviderHandoff)
        #expect(CloudStatus.conflict.needsProviderHandoff && !CloudStatus.conflict.isFailure)
        #expect(!CloudStatus.availableOnDevice.needsProviderHandoff && !CloudStatus.unknown.needsProviderHandoff)
    }

    @Test func aFolderWordingIsPlain() {
        #expect(CloudSignInNeeded(provider: "OneDrive", detail: "").localizedDescription == "Sign in to OneDrive to see this folder.")
        #expect(CloudSignInNeeded(provider: "OneDrive", detail: "x").localizedDescription == "Sign in to OneDrive to see this folder. It reported: x")
    }

    @Test func testStatusesTakeTheRealRoute() {
        #expect(CloudRoots.parseTestStatuses("a=error:Quota\u{202E} full")["a"] == .error("Quota full"))
    }
}

@Suite("Cloud capability probe (FE-198)")
struct CloudCapabilityProbeTests {
    private let full = UbiquityInfo(isUbiquitous: true, download: .current, isDownloading: false, isUploading: false, isUploaded: true, hasConflicts: false)

    private func probe(_ rows: [UbiquityInfo?]) -> CloudCapabilityProbe {
        var probe = CloudCapabilityProbe()
        for (index, row) in rows.enumerated() { probe.observe(row, item: "/r/\(index)") }
        return probe
    }

    @Test func nothingIsAssumedBeforeAnythingIsSeen() {
        let empty = CloudCapabilityProbe()
        #expect(empty.enumeration == .notChecked && empty.sampled == 0 && empty.commandLimitation(provider: "P") == nil)
        #expect(empty.summary(provider: "P") == "What P reports hasn't been checked yet. Open this folder to check.")
    }

    @Test func aFullReportBlocksNothing() {
        let seen = probe([full, full, full])
        #expect(seen.commandLimitation(provider: "P") == nil)
        #expect(seen.notReported.isEmpty && seen.enumeration == .succeeded)
        #expect(seen.summary(provider: "P") == "Listing works. Reports cloud item, download state, downloading, uploading, uploaded, conflicts.")
    }

    @Test func errorKeysAreNeverCountedMissing() {
        #expect(!probe([full]).notReported.contains(.downloadError) && !probe([full]).notReported.contains(.uploadError))
        let failing = probe([UbiquityInfo(isUbiquitous: true, downloadError: "x")])
        #expect(failing.reported.contains(.downloadError) && !failing.reported.contains(.uploadError))
    }

    @Test func fewRowsDecideNothing() {
        #expect(probe([UbiquityInfo(), UbiquityInfo()]).commandLimitation(provider: "P") == nil)
        let reason = probe([UbiquityInfo(), UbiquityInfo(), UbiquityInfo()]).commandLimitation(provider: "P")
        #expect(reason?.hasPrefix("P doesn't report these items to macOS") == true)
    }

    @Test func aRowReadAgainCountsOnce() {
        var seen = CloudCapabilityProbe()
        for _ in 0..<10 { seen.observe(UbiquityInfo(), item: "/same") }
        #expect(seen.sampled == 1 && seen.commandLimitation(provider: "P") == nil)
    }

    @Test func unreadableRowsEstablishNothing() {
        let seen = probe([nil, nil, nil, nil])
        #expect(seen.sampled == 0 && seen.enumeration == .notChecked && seen.commandLimitation(provider: "P") == nil)
    }

    @Test func oneUbiquitousRowIsEnough() {
        var rows = [UbiquityInfo(isUbiquitous: false), UbiquityInfo(isUbiquitous: false), UbiquityInfo(isUbiquitous: true, download: .notDownloaded)]
        #expect(probe(rows).commandLimitation(provider: "P") == nil)
        rows[2].download = nil
        #expect(probe(rows).commandLimitation(provider: "P")?.contains("whether items are on this Mac") == true)
    }

    @Test func theSampleIsBoundedButFailuresStillCount() {
        var seen = probe(Array(repeating: full, count: CloudCapabilityProbe.sampleLimit))
        seen.observe(UbiquityInfo(isUbiquitous: true, downloadError: "x", authenticationRequired: true), item: "/late")
        #expect(seen.sampled == CloudCapabilityProbe.sampleLimit && seen.needsSignIn && seen.reported.contains(.downloadError))
    }

    @Test func aFailedListingIsKeptOverLaterRows() {
        var seen = CloudCapabilityProbe()
        seen.recordListing(.failed("no"))
        seen.observe(full, item: "/a")
        #expect(seen.enumeration == .failed("no"))
        #expect(seen.summary(provider: "P").hasPrefix("Listing failed: no"))
        seen.recordListing(.succeeded)
        #expect(seen.enumeration == .succeeded)
    }

    @Test func signInBlocksCommands() {
        var seen = probe([full, full, full])
        seen.recordListing(.signInRequired("m"))
        #expect(seen.needsSignIn)
        #expect(seen.commandLimitation(provider: "P") == "Sign in to P first.")
        seen.recordListing(.succeeded)
        #expect(!seen.needsSignIn)
    }

    @Test func theLogIsFixedWords() {
        #expect(probe([full]).logDescription == "listing=ok sampled=1 ubiquitous=1 reports=ubiquitous,download,downloading,uploading,uploaded,conflicts signin=no")
        #expect(CloudCapabilityProbe().logDescription == "listing=not-checked sampled=0 ubiquitous=0 reports=- signin=no")
    }

    @Test func simulatedKeysAnswerOnlyWhatTheySay() throws {
        #expect(CloudRoots.simulatedInfo(reporting: nil) == nil)
        #expect(CloudRoots.simulatedInfo(reporting: "") == nil)
        #expect(CloudRoots.simulatedInfo(reporting: "none") == UbiquityInfo())
        let some = try #require(CloudRoots.simulatedInfo(reporting: "ubiquitous, uploaded"))
        #expect(probe([some]).reported == [.ubiquitous, .uploaded])
        let signedOut = try #require(CloudRoots.simulatedInfo(reporting: "signin"))
        #expect(CloudStatusMapper.status(signedOut) == .signInRequired("The operation couldn't be completed. Not signed in."))
    }

    @Test func eachRootHasItsOwnProbeThatExpires() {
        var cache = CloudCapabilityCache()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(cache.probe(forRoot: "/a", at: start) == nil)
        #expect(cache.update(root: "/a", at: start) { $0.observe(UbiquityInfo(isUbiquitous: true), item: "/a/1") })
        #expect(!cache.update(root: "/a", at: start.addingTimeInterval(1)) { $0.observe(UbiquityInfo(isUbiquitous: true), item: "/a/2") }, "a new count isn't a visible change")
        #expect(cache.probe(forRoot: "/a", at: start)?.sampled == 2)
        #expect(cache.probe(forRoot: "/b", at: start) == nil)
        #expect(cache.probe(forRoot: "/a", at: start.addingTimeInterval(CloudCapabilityCache.lifetime)) != nil)
        #expect(cache.probe(forRoot: "/a", at: start.addingTimeInterval(CloudCapabilityCache.lifetime + 1)) == nil)
        cache.update(root: "/a", at: start.addingTimeInterval(CloudCapabilityCache.lifetime + 1)) { $0.observe(UbiquityInfo(), item: "/a/1") }
        #expect(cache.probe(forRoot: "/a", at: start.addingTimeInterval(CloudCapabilityCache.lifetime + 2))?.sampled == 1, "an expired probe starts over")
    }

    @Test func updatesDoNotKeepAnOldClock() {
        var cache = CloudCapabilityCache()
        let start = Date(timeIntervalSince1970: 1_000)
        cache.update(root: "/a", at: start) { $0.observe(UbiquityInfo(), item: "/a/1") }
        cache.update(root: "/a", at: start.addingTimeInterval(200)) { $0.observe(UbiquityInfo(), item: "/a/2") }
        #expect(cache.probe(forRoot: "/a", at: start.addingTimeInterval(CloudCapabilityCache.lifetime + 1)) == nil, "new rows don't extend a result")
    }

    @Test func theFirstRowChangesTheTooltipEvenWhenItReportsNothing() {
        var cache = CloudCapabilityCache()
        let now = Date(timeIntervalSince1970: 1_000)
        cache.update(root: "/a", at: now) { $0.recordListing(.succeeded) }
        #expect(cache.update(root: "/a", at: now) { $0.observe(UbiquityInfo(), item: "/a/1") }, "it gains “Reports no status.”")
        #expect(!cache.update(root: "/a", at: now) { $0.observe(UbiquityInfo(), item: "/a/2") })
    }

    @Test func invalidationIsPerRootOrAll() {
        var cache = CloudCapabilityCache()
        let now = Date()
        cache.update(root: "/a", at: now) { $0.recordListing(.signInRequired("m")) }
        cache.update(root: "/b", at: now) { $0.recordListing(.succeeded) }
        #expect(cache.rootsNeedingSignIn == ["/a"])
        cache.invalidate(root: "/a")
        #expect(cache.probe(forRoot: "/a", at: now) == nil && cache.probe(forRoot: "/b", at: now) != nil)
        cache.invalidateAll()
        #expect(cache.probe(forRoot: "/b", at: now) == nil)
    }

    @Test func theTooltipIsOneReadOnlyBlockOfPlainText() {
        let id = CloudFolderName.parse("OneDrive-Contoso")
        let root = CloudRoot(url: URL(fileURLWithPath: "/Users/me/Library/CloudStorage/OneDrive-Con\u{202E}toso"), provider: id.provider, account: id.account, kind: .fileProvider, accountKind: id.accountKind, entry: id.entry)
        var seen = probe([full])
        seen.recordListing(.signInRequired("m"))
        let lines = CloudRootDescription.tooltip(root, probe: seen).components(separatedBy: "\n")
        #expect(lines[0] == "OneDrive – Contoso")
        #expect(lines[1] == "Work/School account")
        #expect(lines[2] == "Sign in to OneDrive")
        #expect(lines[3].hasPrefix("Listing needs sign-in."))
        #expect(lines[4] == "/Users/me/Library/CloudStorage/OneDrive-Contoso")
        let unknown = CloudRoot(url: URL(fileURLWithPath: "/Users/me/d"), provider: "Dropbox", account: nil, kind: .fileProvider, accountKind: .unknown)
        #expect(CloudRootDescription.tooltip(unknown, probe: nil).components(separatedBy: "\n")[1] == "Account unknown")
    }
}
