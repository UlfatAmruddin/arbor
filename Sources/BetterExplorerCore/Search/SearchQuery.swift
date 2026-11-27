import Foundation
import UniformTypeIdentifiers

// Search query model (spec §10, FE-134, FE-236, FE-237): `AQSParser` builds it, `SearchEvaluator`
// and `SpotlightPredicate` consume it.

/// Identified by the canonical Windows property name, independent of UI language (FE-237).
public enum SearchProperty: String, CaseIterable, Sendable {
    case name = "System.FileName"
    case fileExtension = "System.FileExtension"
    case kind = "System.Kind"
    case type = "System.ItemTypeText"
    case size = "System.Size"
    case dateModified = "System.DateModified"
    case dateCreated = "System.DateCreated"
    case tags = "System.Keywords"
    case author = "System.Author"
    case contents = "System.Search.Contents"
    case folderPath = "System.ItemFolderPathDisplay"

    public enum ValueType: Sendable { case text, size, date, kind }

    public var canonicalName: String { rawValue }

    /// Written by the Search options menu.
    public var keyword: String {
        switch self {
        case .name: return "name"
        case .fileExtension: return "ext"
        case .kind: return "kind"
        case .type: return "type"
        case .size: return "size"
        case .dateModified: return "datemodified"
        case .dateCreated: return "datecreated"
        case .tags: return "tags"
        case .author: return "author"
        case .contents: return "content"
        case .folderPath: return "folderpath"
        }
    }

    public var label: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .fileExtension: return L10n.tr("Extension")
        case .kind: return L10n.tr("Kind")
        case .type: return L10n.tr("Type")
        case .size: return L10n.tr("Size")
        case .dateModified: return L10n.tr("Date modified")
        case .dateCreated: return L10n.tr("Date created")
        case .tags: return L10n.tr("Tags")
        case .author: return L10n.tr("Author")
        case .contents: return L10n.tr("Contents")
        case .folderPath: return L10n.tr("Folder")
        }
    }

    public var valueType: ValueType {
        switch self {
        case .size: return .size
        case .dateModified, .dateCreated: return .date
        case .kind: return .kind
        default: return .text
        }
    }

    /// English only (DEC-search-6).
    public static let mnemonics: [String: SearchProperty] = [
        "name": .name, "filename": .name, "file": .name,
        "ext": .fileExtension, "fileext": .fileExtension, "fileextension": .fileExtension, "extension": .fileExtension,
        "kind": .kind,
        "type": .type, "filetype": .type,
        "size": .size,
        "date": .dateModified, "datemodified": .dateModified, "modified": .dateModified,
        "datecreated": .dateCreated, "created": .dateCreated,
        "tag": .tags, "tags": .tags, "keyword": .tags, "keywords": .tags,
        "author": .author, "authors": .author,
        "content": .contents, "contents": .contents,
        "folder": .folderPath, "folderpath": .folderPath, "path": .folderPath,
    ]

    /// Lowercased, including documented synonyms.
    public static let canonicalNames: [String: SearchProperty] = [
        "system.filename": .name, "system.itemnamedisplay": .name, "system.itemname": .name,
        "system.fileextension": .fileExtension,
        "system.kind": .kind, "system.kindtext": .kind,
        "system.itemtypetext": .type, "system.itemtype": .type,
        "system.size": .size,
        "system.datemodified": .dateModified,
        "system.datecreated": .dateCreated,
        "system.keywords": .tags,
        "system.author": .author,
        "system.search.contents": .contents,
        "system.itemfolderpathdisplay": .folderPath, "system.itemfoldernamedisplay": .folderPath,
    ]

    public static func lookup(_ name: String) -> SearchProperty? {
        let key = name.lowercased()
        return mnemonics[key] ?? canonicalNames[key]
    }
}

/// Windows kinds with a macOS equivalent, plus archive and font.
public enum SearchKind: String, CaseIterable, Sendable {
    case folder, document, picture, music, video, text, program, link, archive, email, contact,
         calendar, playlist, savedSearch, font, communication, unknown

    public var title: String {
        switch self {
        case .folder: return L10n.tr("Folder")
        case .document: return L10n.tr("Document")
        case .picture: return L10n.tr("Picture")
        case .music: return L10n.tr("Music")
        case .video: return L10n.tr("Video")
        case .text: return L10n.tr("Text")
        case .program: return L10n.tr("Program")
        case .link: return L10n.tr("Link")
        case .archive: return L10n.tr("Archive")
        case .email: return L10n.tr("E-mail")
        case .contact: return L10n.tr("Contact")
        case .calendar: return L10n.tr("Calendar")
        case .playlist: return L10n.tr("Playlist")
        case .savedSearch: return L10n.tr("Saved search")
        case .font: return L10n.tr("Font")
        case .communication: return L10n.tr("Communication")
        case .unknown: return L10n.tr("Unknown")
        }
    }

    public var keyword: String {
        switch self {
        case .savedSearch: return "savedsearch"
        case .email: return "email"
        default: return rawValue.lowercased()
        }
    }

    static let aliases: [String: SearchKind] = [
        "folder": .folder, "folders": .folder, "directory": .folder,
        "document": .document, "documents": .document, "doc": .document, "docs": .document,
        "picture": .picture, "pictures": .picture, "pic": .picture, "pics": .picture, "image": .picture,
        "images": .picture, "photo": .picture, "photos": .picture,
        "music": .music, "audio": .music, "song": .music, "songs": .music,
        "video": .video, "videos": .video, "movie": .video, "movies": .video,
        "text": .text,
        "program": .program, "programs": .program, "app": .program, "apps": .program,
        "application": .program, "applications": .program,
        "link": .link, "links": .link, "shortcut": .link, "shortcuts": .link, "alias": .link,
        "archive": .archive, "archives": .archive, "compressed": .archive, "zip": .archive,
        "email": .email, "e-mail": .email, "mail": .email,
        "contact": .contact, "contacts": .contact,
        "calendar": .calendar,
        "playlist": .playlist, "playlists": .playlist,
        "savedsearch": .savedSearch, "saved search": .savedSearch, "search": .savedSearch,
        "font": .font, "fonts": .font,
        "communication": .communication, "communications": .communication,
        "unknown": .unknown,
    ]

    /// Windows-only kinds: explained, never faked (DEC-019).
    public static let windowsOnly: [String: String] = [
        "game": "Game", "games": "Game",
        "instantmessage": "Instant Message", "instant message": "Instant Message", "im": "Instant Message",
        "journal": "Journal", "recordedtv": "Recorded TV", "recorded tv": "Recorded TV", "tv": "Recorded TV",
        "webhistory": "Web history", "web history": "Web history", "history": "Web history",
        "feed": "Feed", "feeds": "Feed", "task": "Task", "tasks": "Task", "note": "Note", "notes": "Note",
    ]

    public static func lookup(_ value: String) -> SearchKind? { aliases[value.lowercased()] }

    /// No disk access.
    public func matches(typeIdentifier: String?, isFolder: Bool, isPackage: Bool, isSymbolicLink: Bool, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let type = typeIdentifier.flatMap { UTType($0) } ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext))
        func conforms(_ list: [UTType]) -> Bool { type.map { t in list.contains { t.conforms(to: $0) } } ?? false }
        func identifier(_ ids: [String]) -> Bool { ids.compactMap { UTType($0) }.contains { type?.conforms(to: $0) == true } }
        switch self {
        case .folder: return isFolder
        case .document:
            guard !isFolder else { return false }
            return conforms([.compositeContent, .pdf, .rtf, .rtfd, .presentation, .spreadsheet, .plainText, .flatRTFD])
                || identifier(["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                               "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers",
                               "com.apple.iwork.keynote.sffkey", "org.oasis-open.opendocument.text",
                               "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
                               "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt"])
        case .picture: return !isFolder && conforms([.image])
        case .music: return !isFolder && conforms([.audio])
        case .video: return !isFolder && conforms([.movie, .video])
        case .text: return !isFolder && conforms([.text])
        case .program: return conforms([.application, .applicationBundle, .unixExecutable, .executable])
        case .link: return isSymbolicLink || conforms([.aliasFile, .symbolicLink, .internetShortcut])
                || identifier(["com.apple.web-internet-location", "com.microsoft.internet-shortcut"]) || ext == "url"
        case .archive: return !isFolder && (conforms([.archive, .zip, .gzip, .bz2, .diskImage]) || ["zip", "tar", "tgz", "7z", "rar", "xz"].contains(ext))
        case .email: return conforms([.emailMessage]) || identifier(["com.apple.mail.emlx"]) || ext == "eml" || ext == "emlx"
        case .contact: return conforms([.vCard, .contact])
        case .calendar: return conforms([.calendarEvent]) || identifier(["com.apple.ical.ics"]) || ext == "ics"
        case .playlist: return conforms([.m3uPlaylist, .playlist]) || ["m3u", "m3u8", "pls"].contains(ext)
        case .savedSearch: return ["arborsearch", "savedsearch", "search-ms"].contains(ext)
        case .font: return conforms([.font])
        case .communication:
            return SearchKind.email.matches(typeIdentifier: typeIdentifier, isFolder: isFolder, isPackage: isPackage,
                                            isSymbolicLink: isSymbolicLink, name: name)
                || SearchKind.contact.matches(typeIdentifier: typeIdentifier, isFolder: isFolder, isPackage: isPackage,
                                              isSymbolicLink: isSymbolicLink, name: name)
        case .unknown:
            guard !isFolder else { return false }
            guard let type else { return true }
            return type.isDynamic || type == .data || type == .item
        }
    }

    /// nil when Spotlight can't express it.
    var spotlightTypes: [String]? {
        switch self {
        case .folder: return ["public.folder"]
        case .document: return ["public.composite-content", "com.adobe.pdf", "public.rtf", "public.presentation",
                                "public.spreadsheet", "public.plain-text", "org.openxmlformats.wordprocessingml.document",
                                "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"]
        case .picture: return ["public.image"]
        case .music: return ["public.audio"]
        case .video: return ["public.movie"]
        case .text: return ["public.text"]
        case .program: return ["com.apple.application", "public.executable"]
        case .archive: return ["public.archive", "com.apple.disk-image"]
        case .email: return ["public.email-message", "com.apple.mail.emlx"]
        case .contact: return ["public.vcard", "public.contact"]
        case .calendar: return ["public.calendar-event"]
        case .playlist: return ["public.playlist", "public.m3u-playlist"]
        case .font: return ["public.font"]
        case .communication: return ["public.email-message", "com.apple.mail.emlx", "public.vcard", "public.contact"]
        case .link, .savedSearch, .unknown: return nil
        }
    }
}

/// Always ignores case, diacritics and width.
public enum TextMatchMode: String, Sendable {
    case contains, equals, beginsWith, wildcard
}

public enum SearchTest: Equatable, Sendable {
    case text(String, TextMatchMode)
    /// Half-open [lower, upper); nil bounds are open.
    case sizeRange(lower: Int64?, upper: Int64?)
    /// Half-open [lower, upper).
    case dateRange(lower: Date?, upper: Date?)
    case kind(SearchKind)
    /// `prop:=[]`.
    case isEmpty
}

/// A nil property means free text.
public struct SearchTerm: Equatable, Sendable {
    public var property: SearchProperty?
    public var test: SearchTest

    public init(_ property: SearchProperty?, _ test: SearchTest) {
        self.property = property
        self.test = test
    }

    public static func freeText(_ value: String, _ mode: TextMatchMode = .contains) -> SearchTerm {
        SearchTerm(nil, .text(value, mode))
    }
}

/// Mixed AND/OR fold strictly left to right, like AQS (FE-236).
public indirect enum SearchExpression: Equatable, Sendable {
    case term(SearchTerm)
    case and(SearchExpression, SearchExpression)
    case or(SearchExpression, SearchExpression)
    case not(SearchExpression)

    public var terms: [SearchTerm] {
        switch self {
        case .term(let t): return [t]
        case .and(let a, let b), .or(let a, let b): return a.terms + b.terms
        case .not(let e): return e.terms
        }
    }

    public var properties: Set<SearchProperty> { Set(terms.compactMap(\.property)) }

    /// Unambiguous form for tests and logs.
    public var debugDescription: String {
        switch self {
        case .term(let t): return t.debugDescription
        case .and(let a, let b): return "(\(a.debugDescription) AND \(b.debugDescription))"
        case .or(let a, let b): return "(\(a.debugDescription) OR \(b.debugDescription))"
        case .not(let e): return "NOT \(e.debugDescription)"
        }
    }
}

extension SearchTerm {
    public var debugDescription: String {
        let prefix = property.map { $0.keyword + ":" } ?? ""
        switch test {
        case .text(let v, let mode):
            switch mode {
            case .contains: return prefix + v
            case .equals: return prefix + "=" + v
            case .beginsWith: return prefix + "~<" + v
            case .wildcard: return prefix + "~" + v
            }
        case .sizeRange(let lo, let hi): return prefix + "[\(lo.map(String.init) ?? "")..\(hi.map(String.init) ?? ""))"
        case .dateRange(let lo, let hi):
            let f = ISO8601DateFormatter()
            return prefix + "[\(lo.map(f.string(from:)) ?? "")..\(hi.map(f.string(from:)) ?? ""))"
        case .kind(let k): return prefix + k.keyword
        case .isEmpty: return prefix + "[]"
        }
    }
}

/// The message is shown to the user.
public struct SearchSyntaxError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
