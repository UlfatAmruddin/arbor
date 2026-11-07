import Foundation
import UniformTypeIdentifiers

// The query model behind Explorer-style search (spec §10, FE-134, FE-236, FE-237).
// `AQSParser` turns typed text into a `SearchExpression`; `SearchEvaluator` tests files against it;
// `SpotlightPredicate` translates it for the Spotlight index.

/// A searchable property. Its identity is the canonical Windows property name, which never depends on
/// the UI language (FE-237). The words users type ("name:", "size:") are English mnemonics that map here.
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

    /// The mnemonic Arbor writes when it adds a restriction (Search options menu).
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

    /// Label for match reasons ("Matched: Name").
    public var label: String {
        switch self {
        case .name: return "Name"
        case .fileExtension: return "Extension"
        case .kind: return "Kind"
        case .type: return "Type"
        case .size: return "Size"
        case .dateModified: return "Date modified"
        case .dateCreated: return "Date created"
        case .tags: return "Tags"
        case .author: return "Author"
        case .contents: return "Contents"
        case .folderPath: return "Folder"
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

    /// English mnemonics accepted in the search box (the UI is English; see DEC-search-6).
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

    /// Canonical names, including documented synonyms. Matched case-insensitively.
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

    /// Resolves a typed property name (mnemonic or canonical). Nil for anything unknown.
    public static func lookup(_ name: String) -> SearchProperty? {
        let key = name.lowercased()
        return mnemonics[key] ?? canonicalNames[key]
    }
}

/// Windows "Kind" values with a real macOS equivalent, plus a few Arbor extensions (archive, font).
public enum SearchKind: String, CaseIterable, Sendable {
    case folder, document, picture, music, video, text, program, link, archive, email, contact,
         calendar, playlist, savedSearch, font, communication, unknown

    /// Title as it appears in Explorer's Search options ▸ Kind menu.
    public var title: String {
        switch self {
        case .folder: return "Folder"
        case .document: return "Document"
        case .picture: return "Picture"
        case .music: return "Music"
        case .video: return "Video"
        case .text: return "Text"
        case .program: return "Program"
        case .link: return "Link"
        case .archive: return "Archive"
        case .email: return "E-mail"
        case .contact: return "Contact"
        case .calendar: return "Calendar"
        case .playlist: return "Playlist"
        case .savedSearch: return "Saved search"
        case .font: return "Font"
        case .communication: return "Communication"
        case .unknown: return "Unknown"
        }
    }

    /// The value Arbor writes after `kind:`.
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

    /// Explorer kinds that only exist on Windows (DEC-019: explained, never faked).
    public static let windowsOnly: [String: String] = [
        "game": "Game", "games": "Game",
        "instantmessage": "Instant Message", "instant message": "Instant Message", "im": "Instant Message",
        "journal": "Journal", "recordedtv": "Recorded TV", "recorded tv": "Recorded TV", "tv": "Recorded TV",
        "webhistory": "Web history", "web history": "Web history", "history": "Web history",
        "feed": "Feed", "feeds": "Feed", "task": "Task", "tasks": "Task", "note": "Note", "notes": "Note",
    ]

    public static func lookup(_ value: String) -> SearchKind? { aliases[value.lowercased()] }

    /// Classifies an item using its uniform type (no disk access).
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

    /// Spotlight content types for the index query (nil = not expressible).
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

/// How a text value is compared. Comparison ignores case, diacritics and width.
public enum TextMatchMode: String, Sendable {
    case contains, equals, beginsWith, wildcard
}

/// What one restriction tests.
public enum SearchTest: Equatable, Sendable {
    case text(String, TextMatchMode)
    /// Half-open byte range [lower, upper). nil bounds are open.
    case sizeRange(lower: Int64?, upper: Int64?)
    /// Half-open date range [lower, upper).
    case dateRange(lower: Date?, upper: Date?)
    case kind(SearchKind)
    /// The property has no value (`System.Keywords:=[]`).
    case isEmpty
}

/// A free-text word or phrase (property nil) or a property restriction.
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

/// A parsed query. Mixed AND/OR are folded strictly left to right, like AQS (FE-236).
public indirect enum SearchExpression: Equatable, Sendable {
    case term(SearchTerm)
    case and(SearchExpression, SearchExpression)
    case or(SearchExpression, SearchExpression)
    case not(SearchExpression)

    /// Every term, for capability checks ("does this query need file contents?").
    public var terms: [SearchTerm] {
        switch self {
        case .term(let t): return [t]
        case .and(let a, let b), .or(let a, let b): return a.terms + b.terms
        case .not(let e): return e.terms
        }
    }

    public var properties: Set<SearchProperty> { Set(terms.compactMap(\.property)) }

    /// A compact, unambiguous rendering used by tests and logs, e.g. `((a AND b) OR name~=c)`.
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

/// A query the parser rejected. The message is shown to the user; nothing is silently ignored.
public struct SearchSyntaxError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
