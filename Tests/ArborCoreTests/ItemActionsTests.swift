import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArborCore

// MARK: - New ▸ templates (FE-088)

@Suite struct NewItemTemplateTests {
    @Test func windowsNamesAndNumbering() {
        var taken: Set<String> = []
        let first = NewItemTemplates.uniqueName(base: "New Text Document", ext: "txt") { taken.contains($0) }
        #expect(first == "New Text Document.txt")
        taken.insert(first)
        #expect(NewItemTemplates.uniqueName(base: "New Text Document", ext: "txt") { taken.contains($0) } == "New Text Document (2).txt")
        taken.insert("New Text Document (2).txt")
        #expect(NewItemTemplates.uniqueName(base: "New Text Document", ext: "txt") { taken.contains($0) } == "New Text Document (3).txt")
        #expect(NewItemTemplates.bitmap.baseName + "." + NewItemTemplates.bitmap.fileExtension == "New Bitmap image.bmp")
        #expect(NewItemTemplates.richText.baseName == "New Rich Text Document")
        #expect(NewItemTemplates.all.map(\.menuTitle) == ["Bitmap image", "Rich Text Document", "Text Document"])
    }

    @Test func bitmapIsAValidWhitePixel() throws {
        let data = NewItemTemplates.bitmap.contents
        #expect(data.count == 58)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.bmp.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1 && image.height == 1)
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try #require(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.99 && color.greenComponent > 0.99 && color.blueComponent > 0.99)
    }

    @Test func richTextIsReadable() throws {
        let text = try NSAttributedString(data: NewItemTemplates.richText.contents,
                                          options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func textDocumentIsEmpty() {
        #expect(NewItemTemplates.text.contents.isEmpty)
    }

    @Test func createNeverOverwrites() throws {
        let fx = try Fixture()
        try fx.file("New Text Document.txt", "keep me")
        let url = try NewItemTemplates.create(NewItemTemplates.text, in: fx.root)
        #expect(url.lastPathComponent == "New Text Document (2).txt")
        #expect(fx.read("New Text Document.txt") == "keep me")
        let bmp = try NewItemTemplates.create(NewItemTemplates.bitmap, in: fx.root)
        #expect(bmp.lastPathComponent == "New Bitmap image.bmp")
        #expect(try Data(contentsOf: bmp) == NewItemTemplates.bitmap.contents)
    }
}

// MARK: - Shortcuts (FE-092)

@Suite struct ShortcutNamingTests {
    @Test func windowsShortcutNames() {
        var taken: Set<String> = []
        #expect(ShortcutNaming.shortcutName(for: "Report.pdf") { taken.contains($0) } == "Report.pdf - Shortcut")
        taken.insert("Report.pdf - Shortcut")
        #expect(ShortcutNaming.shortcutName(for: "Report.pdf") { taken.contains($0) } == "Report.pdf - Shortcut (2)")
        #expect(ShortcutNaming.symbolicLinkName(for: "Photos") { _ in false } == "Photos - Symbolic link")
    }

    @Test func wizardDefaultNames() {
        #expect(ShortcutNaming.wizardDefaultName(for: URL(fileURLWithPath: "/tmp/notes.txt"), isFolder: false) == "notes")
        #expect(ShortcutNaming.wizardDefaultName(for: URL(fileURLWithPath: "/tmp/My.Folder"), isFolder: true) == "My.Folder")
        #expect(ShortcutNaming.wizardDefaultName(for: URL(string: "https://example.com/a")!, isFolder: false) == "example.com")
    }

    @Test func webLocationRoundTrip() throws {
        let url = try #require(WebLocation.parseWebAddress("www.example.com/path"))
        #expect(url.absoluteString == "https://www.example.com/path")
        #expect(WebLocation.parseWebAddress("/Users/x") == nil)
        #expect(WebLocation.parseWebAddress("https://") == nil)
        let data = try WebLocation.data(for: url)
        #expect(WebLocation.url(from: data) == url)
    }
}

// MARK: - Multi-item rename (FE-089)

@Suite struct MultiRenameTests {
    let folder = URL(fileURLWithPath: "/tmp/f")
    func item(_ name: String, folder isFolder: Bool = false) -> RenameCandidate {
        RenameCandidate(url: folder.appendingPathComponent(name), isFolder: isFolder)
    }

    @Test func typedExtensionIsStripped() {
        #expect(MultiRename.base(fromTyped: "Holiday.jpg", editedName: "a.jpg", editedIsFolder: false) == "Holiday")
        #expect(MultiRename.base(fromTyped: "Holiday", editedName: "a.jpg", editedIsFolder: false) == "Holiday")
        #expect(MultiRename.base(fromTyped: "v1.2", editedName: "Folder", editedIsFolder: true) == "v1.2")
        #expect(MultiRename.base(fromTyped: ".jpg", editedName: "a.jpg", editedIsFolder: false) == ".jpg")
    }

    @Test func numbersInOrderKeepingExtensions() {
        let names = MultiRename.names(base: "Holiday", items: [item("b.jpg"), item("a.PNG"), item("Folder", folder: true), item("README")]) { _, _ in false }
        #expect(names == ["Holiday (1).jpg", "Holiday (2).PNG", "Holiday (3)", "Holiday (4)"])
    }

    @Test func skipsNumbersTakenOutsideTheBatch() {
        let names = MultiRename.names(base: "Holiday", items: [item("x.jpg"), item("y.jpg")]) { name, _ in name == "Holiday (1).jpg" }
        #expect(names == ["Holiday (2).jpg", "Holiday (3).jpg"])
    }
}

// MARK: - Advanced batch rename (FE-103)

@Suite struct BatchRenameTests {
    let folder = URL(fileURLWithPath: "/tmp/f")
    func items(_ names: [String]) -> [RenameCandidate] {
        names.map { RenameCandidate(url: folder.appendingPathComponent($0), isFolder: !$0.contains(".")) }
    }
    func preview(_ names: [String], existing: [String]? = nil, _ configure: (inout BatchRenameOptions) -> Void) throws -> BatchRenamePreview {
        var o = BatchRenameOptions()
        configure(&o)
        return try BatchRenamer.preview(items(names), options: o) { _ in existing ?? names }
    }

    @Test func findReplacePlainAndRegex() throws {
        let p = try preview(["IMG_001.JPG", "img_002.jpg"]) { $0.find = "img_"; $0.replace = "Photo " }
        #expect(p.rows.map(\.newName) == ["Photo 001.JPG", "Photo 002.jpg"])
        let cased = try preview(["IMG_001.JPG", "img_002.jpg"]) { $0.find = "img_"; $0.replace = "x"; $0.matchCase = true }
        #expect(cased.rows.map(\.newName) == ["IMG_001.JPG", "x002.jpg"])
        #expect(cased.rows.map(\.status) == [.unchanged, .ok])
        let regex = try preview(["IMG_001.JPG", "IMG_020.JPG"]) { $0.find = #"IMG_0*(\d+)"#; $0.replace = "Shot $1"; $0.useRegex = true }
        #expect(regex.rows.map(\.newName) == ["Shot 1.JPG", "Shot 20.JPG"])
        // The extension is protected unless included.
        let ext = try preview(["a.txt"]) { $0.find = "txt"; $0.replace = "md" }
        #expect(ext.rows[0].newName == "a.txt")
        let withExt = try preview(["a.txt"]) { $0.find = "txt"; $0.replace = "md"; $0.includeExtension = true }
        #expect(withExt.rows[0].newName == "a.md")
    }

    @Test func badRegexThrows() {
        #expect(throws: BatchRenameError.self) { try preview(["a.txt"]) { $0.find = "("; $0.useRegex = true } }
    }

    @Test func caseInsertNumberAndExtension() throws {
        let p = try preview(["my FILE.Txt", "other.TXT"]) { o in
            o.caseStyle = .sentence
            o.prefix = "2026 "
            o.numbering = true
            o.numberStart = 7
            o.numberDigits = 3
            o.numberSeparator = "_"
            o.extensionHandling = .lowercase
        }
        #expect(p.rows.map(\.newName) == ["2026 My file_007.txt", "2026 Other_008.txt"])
        let title = try preview(["hello world.md"]) { $0.caseStyle = .title; $0.extensionHandling = .change(to: ".txt") }
        #expect(title.rows[0].newName == "Hello World.txt")
        let front = try preview(["a.md", "b.md"]) { $0.numbering = true; $0.numberAtStart = true; $0.numberSeparator = " - "; $0.numberStep = 10 }
        #expect(front.rows.map(\.newName) == ["1 - a.md", "11 - b.md"])
        let upper = try preview(["Folder"]) { $0.caseStyle = .upper; $0.extensionHandling = .remove }
        #expect(upper.rows[0].newName == "FOLDER")
    }

    @Test func detectsConflicts() throws {
        // Two items would get the same name.
        let dup = try preview(["a.txt", "b.txt"]) { $0.find = "[ab]"; $0.replace = "c"; $0.useRegex = true }
        #expect(dup.rows.map(\.status) == [.duplicate, .duplicate])
        #expect(!dup.canApply)
        // Target exists outside the batch (case-insensitive, like the default Mac volume).
        let exists = try preview(["a.txt"], existing: ["a.txt", "B.TXT"]) { $0.find = "a"; $0.replace = "b" }
        #expect(exists.rows[0].status == .exists)
        // Swapping names inside the batch is fine.
        let swap = try preview(["1.txt", "2.txt"]) { $0.numbering = true; $0.numberStart = 2; $0.numberStep = -1; $0.find = #"\d"#; $0.useRegex = true; $0.numberSeparator = "" }
        #expect(swap.rows.map(\.newName) == ["2.txt", "1.txt"])
        #expect(swap.canApply)
        // A batch member that keeps its name blocks others from taking it.
        let blocked = try preview(["a.txt", "b.txt"]) { $0.find = "b"; $0.replace = "a" }
        #expect(blocked.rows.map(\.status) == [.duplicate, .duplicate])
        // Invalid names.
        let slash = try preview(["a.txt"]) { $0.find = "a"; $0.replace = "x/y" }
        #expect(slash.rows[0].status.isProblem)
        let hidden = try preview(["a.txt"]) { $0.prefix = "." }
        #expect(hidden.rows[0].status.isProblem)
        let caseOnly = try preview(["a.txt"]) { $0.caseStyle = .upper }
        #expect(caseOnly.rows[0].newName == "A.txt")
        #expect(caseOnly.rows[0].status == .ok)
    }

    @Test func applySwapsAndUndoes() throws {
        let fx = try Fixture()
        try fx.file("1.txt", "one")
        try fx.file("2.txt", "two")
        try fx.file("3.txt", "three")
        let applied = try BatchRenamer.apply([(fx.url("1.txt"), "2.txt"), (fx.url("2.txt"), "3.txt"), (fx.url("3.txt"), "1.txt")])
        #expect(applied.count == 3)
        #expect(fx.read("2.txt") == "one" && fx.read("3.txt") == "two" && fx.read("1.txt") == "three")
        #expect(fx.names("").filter { !$0.hasPrefix(".") } == ["1.txt", "2.txt", "3.txt"])
        try BatchRenamer.apply(BatchRenamer.reversePlan(applied))
        #expect(fx.read("1.txt") == "one" && fx.read("2.txt") == "two" && fx.read("3.txt") == "three")
    }

    @Test func applyIsAllOrNothing() throws {
        let fx = try Fixture()
        try fx.file("a.txt", "a")
        try fx.file("b.txt", "b")
        try fx.file("taken.txt", "keep")
        #expect(throws: BatchRenameError.self) {
            try BatchRenamer.apply([(fx.url("a.txt"), "new.txt"), (fx.url("b.txt"), "taken.txt")])
        }
        #expect(fx.read("a.txt") == "a" && fx.read("b.txt") == "b" && fx.read("taken.txt") == "keep")
        #expect(!fx.exists("new.txt"))
    }

    @Test func caseOnlyBatchRename() throws {
        let fx = try Fixture()
        try fx.file("photo.jpg", "p")
        let applied = try BatchRenamer.apply([(fx.url("photo.jpg"), "PHOTO.jpg")])
        #expect(applied.count == 1)
        #expect(fx.names("").contains("PHOTO.jpg"))
    }
}

// MARK: - Image rotation (FE-097)

@Suite struct ImageRotationTests {
    @Test func orientationGroup() {
        #expect(ExifOrientation.rotated(1, clockwise: true) == 6)
        #expect(ExifOrientation.rotated(6, clockwise: true) == 3)
        #expect(ExifOrientation.rotated(3, clockwise: true) == 8)
        #expect(ExifOrientation.rotated(8, clockwise: true) == 1)
        #expect(ExifOrientation.rotated(2, clockwise: true) == 7)
        for o in 1...8 {
            #expect(ExifOrientation.rotated(ExifOrientation.rotated(o, clockwise: true), clockwise: false) == o)
            var x = o
            for _ in 0..<4 { x = ExifOrientation.rotated(x, clockwise: true) }
            #expect(x == o)
        }
    }

    /// A 2×1 image: red on the left, blue on the right.
    func writeTestImage(_ url: URL, type: UTType) throws {
        let ctx = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    func pixels(_ url: URL) throws -> (w: Int, h: Int, colors: [String]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rep = NSBitmapImageRep(cgImage: image)
        var colors: [String] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                colors.append(c.redComponent > 0.5 ? "R" : c.blueComponent > 0.5 ? "B" : "?")
            }
        }
        return (image.width, image.height, colors)
    }

    @Test func pngRotatesPixelsLosslessly() throws {
        let fx = try Fixture()
        let url = fx.url("a.png")
        try writeTestImage(url, type: .png)
        #expect(try ImageRotator.rotate(url, clockwise: true) == .pixels)
        // Rotated clockwise: red (left) moves to the top.
        let cw = try pixels(url)
        #expect(cw.w == 1 && cw.h == 2 && cw.colors == ["R", "B"])
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 144)
        try ImageRotator.rotate(url, clockwise: false)
        let back = try pixels(url)
        #expect(back.w == 2 && back.h == 1 && back.colors == ["R", "B"])
        try ImageRotator.rotate(url, clockwise: false)
        let ccw = try pixels(url)
        #expect(ccw.colors == ["B", "R"])
        #expect(fx.names("").filter { $0.hasPrefix(".arbor") }.isEmpty)
    }

    @Test func jpegRotatesByTagOnly() throws {
        let fx = try Fixture()
        let url = fx.url("a.jpg")
        try writeTestImage(url, type: .jpeg)
        let before = try pixels(url)
        #expect(ImageRotator.orientation(of: url) == 1)
        #expect(try ImageRotator.rotate(url, clockwise: true) == .orientationTag)
        #expect(ImageRotator.orientation(of: url) == 6)
        let after = try pixels(url)
        #expect(after.w == before.w && after.h == before.h)   // stored pixels untouched
        try ImageRotator.rotate(url, clockwise: false)
        #expect(ImageRotator.orientation(of: url) == 1)
    }

    @Test func refusesUnsupported() throws {
        let fx = try Fixture()
        let url = try fx.file("not-an-image.png", "text")
        #expect(throws: ImageRotationError.self) { try ImageRotator.rotate(url, clockwise: true) }
        #expect(fx.read("not-an-image.png") == "text")
        #expect(!ImageRotator.canRotate(URL(fileURLWithPath: "/x.pdf")))
        #expect(ImageRotator.canRotate(URL(fileURLWithPath: "/x.JPG")))
    }
}

// MARK: - Drag sources and spring-loading (FE-108, FE-111)

@Suite struct DragPolishTests {
    @Test func overlappingSourcesAreDeduplicated() {
        let a = URL(fileURLWithPath: "/tmp/x/A")
        let inner = URL(fileURLWithPath: "/tmp/x/A/inner.txt")
        let b = URL(fileURLWithPath: "/tmp/x/B.txt")
        let ab = URL(fileURLWithPath: "/tmp/x/AB")
        #expect(DragSources.deduplicated([inner, a, b, b, ab]) == [a, b, ab])
        #expect(DragSources.deduplicated([b]) == [b])
    }

    @Test func springLoadingFiresOncePerHover() {
        var t = SpringLoadTracker(delay: 0.7, staleAfter: 0.4)
        let newA = t.hover("A", now: 0)
        #expect(newA)
        let due0_5 = t.due(now: 0.5)
        #expect(due0_5 == nil)
        t.hover("A", now: 0.6)
        let due0_7 = t.due(now: 0.7)
        #expect(due0_7 == "A")
        let due0_9 = t.due(now: 0.9)
        #expect(due0_9 == nil)            // once
        // Moving to another target restarts the delay.
        let newB = t.hover("B", now: 1.0)
        #expect(newB)
        t.hover("B", now: 1.5)
        let due1_6 = t.due(now: 1.6)
        #expect(due1_6 == nil)
        let due1_75 = t.due(now: 1.75)
        #expect(due1_75 == "B")
        // Leaving cancels.
        t.hover("C", now: 2.0)
        t.hover(nil, now: 2.3)
        let due2_8 = t.due(now: 2.8)
        #expect(due2_8 == nil)
        // A drag that went quiet (left the view) doesn't fire.
        t.hover("D", now: 3.0)
        let due3_8 = t.due(now: 3.8)
        #expect(due3_8 == nil)
        t.hover("E", now: 4.0)
        t.cancel()
        let due4_7 = t.due(now: 4.7)
        #expect(due4_7 == nil)
    }
}
