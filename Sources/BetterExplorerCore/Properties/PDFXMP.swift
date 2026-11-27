import Foundation

/// A PDF's XMP packet (FE-152): only the Dublin Core and PDF properties matching the four fields change; every other element stays.
enum PDFXMP {
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let dc = "http://purl.org/dc/elements/1.1/"
    private static let pdf = "http://ns.adobe.com/pdf/1.3/"
    private static let description = SafeXML.Name(uri: rdf, local: "Description")
    private static let title = SafeXML.Name(uri: dc, local: "title")
    private static let summary = SafeXML.Name(uri: dc, local: "description")
    private static let creator = SafeXML.Name(uri: dc, local: "creator")
    private static let subjects = SafeXML.Name(uri: dc, local: "subject")
    private static let keywords = SafeXML.Name(uri: pdf, local: "Keywords")

    /// The properties each field is stored in.
    private static func properties(_ field: EmbeddedField) -> [SafeXML.Name] {
        switch field {
        case .title: return [title]
        case .subject: return [summary]
        case .author: return [creator]
        case .keywords: return [keywords, subjects]
        default: return []
        }
    }

    /// The packet, its rdf:Description elements, and the prefix its RDF uses.
    private struct Packet {
        let document: XMLDocument
        let descriptions: [XMLElement]
        let rdfPrefix: String

        func elements(_ name: SafeXML.Name) -> [XMLElement] { descriptions.flatMap { $0.childElements.filter { $0.safeName == name } } }

        func attributes(_ name: SafeXML.Name) -> [(owner: XMLElement, node: XMLNode)] {
            descriptions.compactMap { owner in owner.attribute(forLocalName: name.local, uri: name.uri).map { (owner, $0) } }
        }
    }

    private static func packet(_ data: Data) -> Packet? {
        guard let document = SafeXML.document(data), let root = document.rootElement() else { return nil }
        var rdfRoot = root
        if root.safeName != SafeXML.Name(uri: rdf, local: "RDF") {
            let children = root.childElements
            guard root.safeName.uri == "adobe:ns:meta/", children.count == 1, let only = children.first,
                  only.safeName == SafeXML.Name(uri: rdf, local: "RDF") else { return nil }
            rdfRoot = only
        }
        let descriptions = rdfRoot.childElements
        guard !descriptions.isEmpty, descriptions.allSatisfy({ $0.safeName == description }) else { return nil }
        return Packet(document: document, descriptions: descriptions, rdfPrefix: rdfRoot.prefix ?? "rdf")
    }

    /// nil when the packet can't be understood; then the file is read-only.
    static func fields(_ data: Data) -> [EmbeddedField: EmbeddedReader.Raw]? {
        guard let packet = packet(data) else { return nil }
        var fields: [EmbeddedField: EmbeddedReader.Raw] = [:]
        fields[.title] = list(title, in: packet, separator: "; ")
        fields[.subject] = list(summary, in: packet, separator: "; ")
        fields[.author] = list(creator, in: packet, separator: "; ")
        fields[.keywords] = keywordText(packet)
        return fields
    }

    /// One value in an rdf:Alt or rdf:Seq can be rewritten; several (other languages, several authors) are shown but not offered.
    private static func list(_ name: SafeXML.Name, in packet: Packet, separator: String) -> EmbeddedReader.Raw? {
        let found = packet.elements(name)
        guard let element = found.first else { return packet.attributes(name).isEmpty ? nil : EmbeddedReader.Raw(text: "", canEdit: false) }
        guard found.count == 1, packet.attributes(name).isEmpty, let items = items(of: element) else {
            return EmbeddedReader.Raw(text: element.plainText.text, canEdit: false)
        }
        guard !items.isEmpty else { return nil }
        let shown = items.first { $0.language == "x-default" } ?? items[0]
        let text = name == title || name == summary ? shown.text : items.map(\.text).joined(separator: separator)
        return EmbeddedReader.Raw(text: text, canEdit: items.count == 1 && items[0].isPlain)
    }

    private static func items(of property: XMLElement) -> [(text: String, language: String?, isPlain: Bool)]? {
        guard let container = container(of: property) else { return nil }
        var found: [(String, String?, Bool)] = []
        for item in container.childElements {
            guard item.safeName == SafeXML.Name(uri: rdf, local: "li") else { return nil }
            let text = item.plainText
            found.append((text.text, item.attribute(forName: "xml:lang")?.stringValue, text.isPlain))
        }
        return found
    }

    /// The single rdf:Alt, Seq or Bag inside a property, with nothing but white space beside it.
    private static func container(of property: XMLElement) -> XMLElement? {
        let elements = property.childElements
        guard elements.count == 1, let only = elements.first, only.safeName.uri == rdf, ["Alt", "Seq", "Bag"].contains(only.safeName.local),
              property.plainText.text.allSatisfy(\.isWhitespace) else { return nil }
        return only
    }

    /// pdf:Keywords when present, else Dublin Core's list of subjects.
    private static func keywordText(_ packet: Packet) -> EmbeddedReader.Raw? {
        let elements = packet.elements(keywords), attributes = packet.attributes(keywords)
        let bags = packet.elements(subjects)
        let bagIsUsable = bags.count <= 1 && packet.attributes(subjects).isEmpty && bags.allSatisfy { items(of: $0) != nil }
        if elements.count + attributes.count > 0 {
            let text: (text: String, isPlain: Bool) = elements.first?.plainText ?? (attributes.first?.node.stringValue ?? "", true)
            return EmbeddedReader.Raw(text: text.text, canEdit: elements.count + attributes.count == 1 && text.isPlain && bagIsUsable)
        }
        guard let bag = bags.first else { return nil }
        let entries = items(of: bag) ?? []
        guard !entries.isEmpty || !bagIsUsable else { return nil }
        return EmbeddedReader.Raw(text: entries.map(\.text).joined(separator: ", "), canEdit: bagIsUsable && entries.allSatisfy(\.isPlain))
    }

    // MARK: Writing

    /// The packet with `edits` applied; nil when it can't be done without touching anything else.
    static func edited(_ data: Data, _ edits: [EmbeddedField: String]) -> Data? {
        guard let packet = packet(data) else { return nil }
        for (field, value) in edits {
            switch field {
            case .title, .subject: guard setList(field == .title ? title : summary, "Alt", [value], in: packet) else { return nil }
            case .author: guard setList(creator, "Seq", [value], in: packet) else { return nil }
            case .keywords:
                guard setKeywords(value, in: packet) else { return nil }
                if !packet.elements(subjects).isEmpty {
                    let parts = value.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard setList(subjects, "Bag", parts, in: packet) else { return nil }
                }
            default: return nil
            }
        }
        return SafeXML.serializedWithoutDeclaration(packet.document)
    }

    /// Replaces the items of an existing list, keeping a single item's language, or adds the property; no values removes it.
    private static func setList(_ name: SafeXML.Name, _ kind: String, _ values: [String], in packet: Packet) -> Bool {
        let found = packet.elements(name)
        guard found.count <= 1, packet.attributes(name).isEmpty else { return false }
        if values.allSatisfy(\.isEmpty) {
            found.first?.removeFromParent()
            return true
        }
        let container: XMLElement
        if let property = found.first {
            guard let existing = self.container(of: property), let current = items(of: property) else { return false }
            if current.count == 1, values.count == 1, let item = existing.childElements.first {
                item.stringValue = values[0]
                return true
            }
            container = existing
            container.setChildren(nil)
        } else {
            guard let owner = packet.descriptions.first else { return false }
            let property = SafeXML.element(name, preferredPrefix: name.uri == dc ? "dc" : "pdf", in: owner)
            container = XMLElement(name: "\(packet.rdfPrefix):\(kind)", uri: rdf)
            property.addChild(container)
            owner.addChild(property)
        }
        for value in values {
            let item = XMLElement(name: "\(packet.rdfPrefix):li", uri: rdf)
            if kind == "Alt", let language = XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as? XMLNode { item.addAttribute(language) }
            item.stringValue = value
            container.addChild(item)
        }
        return true
    }

    private static func setKeywords(_ value: String, in packet: Packet) -> Bool {
        let elements = packet.elements(keywords), attributes = packet.attributes(keywords)
        guard elements.count + attributes.count <= 1 else { return false }
        if let element = elements.first {
            if value.isEmpty { element.removeFromParent() } else { element.stringValue = value }
        } else if let attribute = attributes.first {
            if value.isEmpty { attribute.owner.removeAttribute(forName: attribute.node.name ?? "") } else { attribute.node.stringValue = value }
        } else if !value.isEmpty, let owner = packet.descriptions.first {
            let element = SafeXML.element(keywords, preferredPrefix: "pdf", in: owner)
            element.stringValue = value
            owner.addChild(element)
        }
        return true
    }

    /// True when the two packets differ only in the properties `edits` names, as seen by a second, independent parser.
    static func sameApart(from edits: [EmbeddedField: String], _ before: Data, _ after: Data) -> Bool {
        let edited = Set(edits.keys.flatMap(properties))
        let skip: (SafeXML.Name, SafeXML.Name?) -> Bool = { name, parent in parent == description && edited.contains(name) }
        guard let old = SafeXML.events(before, skipping: skip), let new = SafeXML.events(after, skipping: skip) else { return false }
        return old == new
    }
}
