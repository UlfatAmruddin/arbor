import Foundation

/// XML found inside a file, hostile until it has passed every bound here: plain UTF-8, no DTD, limited size and depth (FE-152).
enum SafeXML {
    static let maxBytes = 4 << 20
    static let maxDepth = 64

    struct Name: Hashable {
        let uri: String
        let local: String
    }

    /// Parsing and writing back keep everything that is in the text.
    private static let fidelity: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace, .nodePreserveCDATA, .nodePreservePrefixes,
                                                    .nodePreserveAttributeOrder, .nodePreserveNamespaceOrder, .nodePreserveQuotes]

    /// nil when `data` fails a bound or isn't well formed.
    static func document(_ data: Data) -> XMLDocument? {
        guard events(data) != nil, let document = try? XMLDocument(data: data, options: fidelity), document.dtd == nil else { return nil }
        return document
    }

    static func serialized(_ document: XMLDocument) -> Data { document.xmlData(options: fidelity) }

    /// For an XMP packet, which has no XML declaration and mustn't gain one ahead of its opening instruction.
    static func serializedWithoutDeclaration(_ document: XMLDocument) -> Data {
        Data((document.children ?? []).map { $0.xmlString(options: fidelity) }.joined().utf8)
    }

    /// A new element for `name` under `scope`, using the prefix already bound there or declaring `preferredPrefix` on itself.
    static func element(_ name: Name, preferredPrefix: String, in scope: XMLElement) -> XMLElement {
        let bound = scope.resolvePrefix(forNamespaceURI: name.uri)
        let prefix = bound ?? preferredPrefix
        let element = XMLElement(name: prefix.isEmpty ? name.local : "\(prefix):\(name.local)", uri: name.uri)
        if bound == nil, let declaration = XMLNode.namespace(withName: prefix, stringValue: name.uri) as? XMLNode { element.addNamespace(declaration) }
        return element
    }

    // MARK: A second parser's view, for proving a rewrite

    enum Event: Equatable {
        case open(name: Name, qualified: String, attributes: [Name: String], namespaces: [String: String])
        case close
        case text(String)
        case comment(String)
        case instruction(String, String)
    }

    /// The document as a stream of events, leaving out elements and attributes `isEdited` names; nil when it fails a bound or isn't well formed.
    /// Formatting between elements isn't part of it, so a removed element can't be mistaken for other damage.
    static func events(_ data: Data, skipping isEdited: @escaping (_ name: Name, _ parent: Name?) -> Bool = { _, _ in false }) -> [Event]? {
        guard isPlainUTF8(data) else { return nil }
        let collector = EventCollector(isEdited: isEdited)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        return parser.parse() && !collector.tooDeep ? collector.events : nil
    }

    /// Anything else (UTF-16, a declared legacy encoding, a DOCTYPE that could expand or fetch entities) is refused before a parser sees it.
    private static func isPlainUTF8(_ data: Data) -> Bool {
        guard data.count <= maxBytes, String(data: data, encoding: .utf8) != nil, !data.contains(0) else { return false }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard body.first == UInt8(ascii: "<"), data.range(of: Data("<!DOCTYPE".utf8)) == nil else { return false }
        return declaresOnlyUTF8(body)
    }

    private static func declaresOnlyUTF8(_ body: Data) -> Bool {
        guard body.starts(with: Data("<?xml".utf8)) else { return true }
        guard let end = body.prefix(512).range(of: Data("?>".utf8)) else { return false }
        let declaration = String(decoding: body[body.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        guard let key = declaration.range(of: "encoding") else { return true }
        let rest = declaration[key.upperBound...].drop { " \t\r\n=".contains($0) }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return false }
        let value = rest.dropFirst().prefix { $0 != quote }
        return value == "utf-8" || value == "utf8"
    }

    private final class EventCollector: NSObject, XMLParserDelegate {
        private(set) var events: [Event] = []
        private(set) var tooDeep = false
        private let isEdited: (Name, Name?) -> Bool
        private var path: [Name] = []
        private var scopes: [[String: String]] = []
        private var pending: [String: String] = [:]
        private var text = ""
        private var skipping = 0

        init(isEdited: @escaping (Name, Name?) -> Bool) { self.isEdited = isEdited }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { pending[prefix] = uri }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard path.count < SafeXML.maxDepth else {
                tooDeep = true
                parser.abortParsing()
                return
            }
            let element = Name(uri: namespaceURI ?? "", local: name), parent = path.last
            let declared = pending
            pending = [:]
            path.append(element)
            scopes.append(declared)
            if skipping > 0 {
                skipping += 1
                return
            }
            flushText(isLeaf: false)
            if isEdited(element, parent) {
                skipping = 1
                return
            }
            var named: [Name: String] = [:]
            for (key, value) in attributes {
                let attribute = resolved(key)
                if !isEdited(attribute, element) { named[attribute] = value }
            }
            events.append(.open(name: element, qualified: qualifiedName ?? name, attributes: named, namespaces: declared))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            scopes.removeLast()
            if skipping > 0 {
                skipping -= 1
                text = ""
                return
            }
            var isLeaf = false
            if case .open? = events.last { isLeaf = true }
            flushText(isLeaf: isLeaf)
            events.append(.close)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if skipping == 0 { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if skipping == 0 { text += String(decoding: block, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            guard skipping == 0 else { return }
            flushText(isLeaf: false)
            events.append(.comment(comment))
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            guard skipping == 0 else { return }
            flushText(isLeaf: false)
            events.append(.instruction(target, data ?? ""))
        }

        private func flushText(isLeaf: Bool) {
            defer { text = "" }
            if !text.isEmpty, isLeaf || !text.allSatisfy(\.isWhitespace) { events.append(.text(text)) }
        }

        private func resolved(_ qualified: String) -> Name {
            guard let colon = qualified.firstIndex(of: ":") else { return Name(uri: "", local: qualified) }
            let prefix = String(qualified[..<colon])
            let uri = scopes.reversed().lazy.compactMap { $0[prefix] }.first ?? prefix
            return Name(uri: uri, local: String(qualified[qualified.index(after: colon)...]))
        }
    }
}

extension XMLElement {
    var safeName: SafeXML.Name { SafeXML.Name(uri: uri ?? "", local: localName ?? name ?? "") }

    var childElements: [XMLElement] { children?.compactMap { $0 as? XMLElement } ?? [] }

    /// The text inside, and whether text is all there is: a comment or child element would be lost by replacing it.
    var plainText: (text: String, isPlain: Bool) {
        var text = "", isPlain = true
        for child in children ?? [] {
            if child.kind == .text { text += child.stringValue ?? "" } else { isPlain = false }
        }
        return (text, isPlain)
    }

    /// Takes this element out of its parent.
    func removeFromParent() {
        (parent as? XMLElement)?.removeChild(at: index)
    }
}
