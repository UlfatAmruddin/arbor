import Foundation

/// docProps/core.xml (FE-152): only the six edited elements change; unknown elements, namespaces and every other property stay.
enum OfficeCoreProperties {
    private static let cp = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    private static let dc = "http://purl.org/dc/elements/1.1/"
    private static let root = SafeXML.Name(uri: cp, local: "coreProperties")

    private static func name(_ field: EmbeddedField) -> SafeXML.Name? {
        switch field {
        case .title: return SafeXML.Name(uri: dc, local: "title")
        case .subject: return SafeXML.Name(uri: dc, local: "subject")
        case .author: return SafeXML.Name(uri: dc, local: "creator")
        case .keywords: return SafeXML.Name(uri: cp, local: "keywords")
        case .category: return SafeXML.Name(uri: cp, local: "category")
        case .comment: return SafeXML.Name(uri: dc, local: "description")
        default: return nil
        }
    }

    private static func properties(_ xml: Data) -> (document: XMLDocument, root: XMLElement)? {
        guard let document = SafeXML.document(xml), let element = document.rootElement(), element.safeName == root else { return nil }
        return (document, element)
    }

    /// nil when the part can't be understood. A repeated element, or one holding markup (keywords with language parts), is shown but not offered.
    static func fields(_ xml: Data) -> [EmbeddedField: EmbeddedReader.Raw]? {
        guard let (_, element) = properties(xml) else { return nil }
        var fields: [EmbeddedField: EmbeddedReader.Raw] = [:]
        for field in EmbeddedField.allCases {
            guard let name = name(field) else { continue }
            let found = element.childElements.filter { $0.safeName == name }
            guard let first = found.first else { continue }
            let text = first.plainText
            if found.count == 1, text.isPlain, text.text.isEmpty { continue }
            fields[field] = EmbeddedReader.Raw(text: text.text, canEdit: found.count == 1 && text.isPlain)
        }
        return fields
    }

    /// The part with `edits` applied in place; "" removes the element. nil when that can't be done exactly.
    static func edited(_ xml: Data, _ edits: [EmbeddedField: String]) -> Data? {
        guard let (document, element) = properties(xml) else { return nil }
        for (field, value) in edits {
            guard let name = name(field) else { return nil }
            let found = element.childElements.filter { $0.safeName == name }
            guard found.count <= 1 else { return nil }
            if value.isEmpty {
                found.first?.removeFromParent()
            } else if let existing = found.first {
                guard existing.plainText.isPlain else { return nil }
                existing.stringValue = value
            } else {
                let added = SafeXML.element(name, preferredPrefix: name.uri == cp ? "cp" : "dc", in: element)
                added.stringValue = value
                element.addChild(added)
            }
        }
        return SafeXML.serialized(document)
    }

    /// True when the two parts differ only in the elements `edits` names, as seen by a second, independent parser.
    static func sameApart(from edits: [EmbeddedField: String], _ before: Data, _ after: Data) -> Bool {
        let edited = Set(edits.keys.compactMap(name))
        let skip: (SafeXML.Name, SafeXML.Name?) -> Bool = { name, parent in parent == root && edited.contains(name) }
        guard let old = SafeXML.events(before, skipping: skip), let new = SafeXML.events(after, skipping: skip) else { return false }
        return old == new
    }
}
