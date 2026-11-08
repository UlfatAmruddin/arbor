import Foundation
import Testing
@testable import ArborCore

struct PanePreviewTests {
    private func file(_ name: String) -> FileItem { FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isFolder: false) }

    @Test func textFilesShowTheirIconInsteadOfABlankPage() {
        for name in ["table.csv", "notes.txt", "readme.md", "data.json", "app.log", "main.swift", "script.py", "page.html",
                     "list.tsv", "conf.yaml", "run.sh", "doc.rtf"] {
            #expect(ThumbnailPolicy.panePreview(file(name), iconsOnly: false) == .icon, "\(name)")
        }
    }

    @Test func picturesVideosAndDocumentsGetThumbnails() {
        #expect(ThumbnailPolicy.panePreview(file("photo.jpg"), iconsOnly: false) == .thumbnail)
        #expect(ThumbnailPolicy.panePreview(file("clip.mov"), iconsOnly: false) == .thumbnail)
        for name in ["paper.pdf", "letter.docx", "budget.xlsx", "talk.pptx", "notes.pages", "book.epub"] {
            #expect(ThumbnailPolicy.panePreview(file(name), iconsOnly: false) == .page, "\(name)")
        }
    }

    @Test func iconsOnlyFoldersAndUnknownTypesKeepIcons() {
        #expect(ThumbnailPolicy.panePreview(file("photo.jpg"), iconsOnly: true) == .icon)
        #expect(ThumbnailPolicy.panePreview(FileItem(url: URL(fileURLWithPath: "/tmp/p.jpg"), name: "p.jpg", isFolder: true),
                                            iconsOnly: false) == .icon)
        #expect(ThumbnailPolicy.panePreview(file("README"), iconsOnly: false) == .icon)
        #expect(ThumbnailPolicy.panePreview(file("x.unknownext"), iconsOnly: false) == .icon)
    }
}
