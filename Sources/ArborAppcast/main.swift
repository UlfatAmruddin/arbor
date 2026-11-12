import ArborCore
import Foundation

// Writes the update feed for one release (FE-259); scripts/make-update.sh runs it. Logic lives in ArborCore.
let usage = """
    usage: ArborAppcast --app <Arbor.app> --archive <zip> --signature <base64> --url <download URL>
                        --changelog <CHANGELOG.md> --output <appcast.xml>
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ArborAppcast: \(message)\n".utf8))
    exit(1)
}

/// Reads at most `limit` bytes; a larger file is refused rather than cut.
func read(_ path: String, limit: Int) -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else { fail("can't read \(path)") }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1) else { fail("can't read \(path)") }
    guard data.count <= limit else { fail("\(path) is larger than \(limit) bytes") }
    return data
}

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let name = arguments.popFirst() {
    guard name.hasPrefix("--"), let value = arguments.popFirst() else { fail(usage) }
    options[String(name.dropFirst(2))] = value
}
let names = ["app", "archive", "signature", "url", "changelog", "output"]
guard Set(options.keys) == Set(names) else { fail(usage) }
let option = { (name: String) -> String in options[name] ?? "" }

let plistData = read(option("app") + "/Contents/Info.plist", limit: 1 << 20)
guard let info = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String,
      let minimum = info["LSMinimumSystemVersion"] as? String else { fail("the app's Info.plist lacks its versions") }
guard let publicKey = info["SUPublicEDKey"] as? String, UpdateConfiguration.isPublicKey(publicKey) else {
    fail("the app has no SUPublicEDKey: build it with ARBOR_UPDATE_FEED_URL and ARBOR_UPDATE_PUBLIC_KEY")
}

// Mapped, not copied; release archives are tens of megabytes.
let archivePath = option("archive")
guard let archive = try? Data(contentsOf: URL(fileURLWithPath: archivePath), options: .alwaysMapped) else { fail("can't read \(archivePath)") }
guard UpdateSignature.isValid(option("signature"), of: archive, publicKey: publicKey) else {
    fail("the signature doesn't match the app's SUPublicEDKey: SPARKLE_ED_PRIVATE_KEY and SPARKLE_ED_PUBLIC_KEY are not a pair")
}

guard let changelog = String(data: read(option("changelog"), limit: 4 << 20), encoding: .utf8) else { fail("CHANGELOG.md is not UTF-8") }
guard let section = ReleaseNotes.section(for: version, in: changelog), !section.isEmpty else {
    fail("CHANGELOG.md has no section “## \(version)”")
}
guard let url = URL(string: option("url")) else { fail("the download URL is not a URL") }

let item = AppcastItem(shortVersion: version, build: build, minimumSystemVersion: minimum, downloadURL: url,
                       length: archive.count, edSignature: option("signature"),
                       notesHTML: ReleaseNotes.html(fromMarkdown: section), published: Date())
do {
    try Data(try Appcast.xml(item).utf8).write(to: URL(fileURLWithPath: option("output")), options: .atomic)
} catch {
    fail("\(error)")
}
