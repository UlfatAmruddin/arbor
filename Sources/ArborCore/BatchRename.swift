import Foundation

/// One item taking part in a multi-item or batch rename.
public struct RenameCandidate: Sendable, Equatable {
    public let url: URL
    public let isFolder: Bool
    public var name: String { url.lastPathComponent }
    public var folder: URL { url.deletingLastPathComponent() }

    public init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }
}

/// Explorer's basic multi-item rename (FE-089): select several items, press F2, type one name, and
/// every item becomes "Name (1).ext", "Name (2).ext"… in view order, each keeping its own extension.
public enum MultiRename {
    /// The base name the user meant. The edit box shows the edited item's extension, so a typed
    /// "Holiday.jpg" for a .jpg means "Holiday" (each item keeps its own extension).
    public static func base(fromTyped typed: String, editedName: String, editedIsFolder: Bool) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !editedIsFolder, let ext = NameRules.splitExtension(editedName, treatAsFolder: false).ext else { return t }
        let suffix = "." + ext
        if t.count > suffix.count, t.lowercased().hasSuffix(suffix.lowercased()) { return String(t.dropLast(suffix.count)) }
        return t
    }

    /// New names, one per item, in the given (view) order. Numbers taken by items outside the batch
    /// (`isTakenOutside(name, folder)`) are skipped, so nothing is ever overwritten.
    public static func names(base: String, items: [RenameCandidate],
                             isTakenOutside: (String, URL) -> Bool) -> [String] {
        var used: [URL: Set<String>] = [:]
        var n = 1
        return items.map { item in
            let ext = NameRules.splitExtension(item.name, treatAsFolder: item.isFolder).ext
            while true {
                let candidate = ext.map { "\(base) (\(n)).\($0)" } ?? "\(base) (\(n))"
                n += 1
                let key = candidate.lowercased()
                if used[item.folder, default: []].contains(key) { continue }
                if isTakenOutside(candidate, item.folder) { continue }
                used[item.folder, default: []].insert(key)
                return candidate
            }
        }
    }
}

// MARK: - Advanced batch rename (FE-103)

public enum RenameCaseStyle: String, Sendable, CaseIterable {
    case unchanged, lower, upper, title, sentence

    public var title: String {
        switch self {
        case .unchanged: return L10n.tr("Don't change")
        case .lower: return L10n.tr("lowercase")
        case .upper: return L10n.tr("UPPERCASE")
        case .title: return L10n.tr("Title Case")
        case .sentence: return L10n.tr("Sentence case")
        }
    }

    public func apply(_ s: String) -> String {
        switch self {
        case .unchanged: return s
        case .lower: return s.lowercased()
        case .upper: return s.uppercased()
        case .title: return s.capitalized
        case .sentence:
            let lower = s.lowercased()
            guard let first = lower.firstIndex(where: \.isLetter) else { return lower }
            return lower.replacingCharacters(in: first...first, with: String(lower[first]).uppercased())
        }
    }
}

public enum ExtensionHandling: Equatable, Sendable {
    case keep, lowercase, uppercase, remove
    case change(to: String)
}

public struct BatchRenameOptions: Equatable, Sendable {
    public var find = ""
    public var replace = ""
    public var useRegex = false
    public var matchCase = false
    /// Find and replace (and case changes) also see the extension.
    public var includeExtension = false
    public var caseStyle: RenameCaseStyle = .unchanged
    public var prefix = ""
    public var suffix = ""
    public var numbering = false
    public var numberStart = 1
    public var numberStep = 1
    /// Minimum digits, zero padded ("007").
    public var numberDigits = 1
    public var numberAtStart = false
    /// Text between the name and the number.
    public var numberSeparator = " "
    public var extensionHandling: ExtensionHandling = .keep

    public init() {}
}

public enum BatchRenameStatus: Equatable, Sendable {
    case unchanged
    case ok
    /// Another item outside the batch already has this name.
    case exists
    /// Two items in the batch would get the same name.
    case duplicate
    case invalid(String)

    public var isProblem: Bool {
        switch self {
        case .exists, .duplicate, .invalid: return true
        default: return false
        }
    }

    public var text: String {
        switch self {
        case .unchanged: return L10n.tr("Unchanged")
        case .ok: return L10n.tr("OK")
        case .exists: return L10n.tr("Name already exists")
        case .duplicate: return L10n.tr("Duplicate name")
        case .invalid(let why): return why
        }
    }
}

public struct BatchRenameRow: Equatable, Sendable {
    public let item: RenameCandidate
    public let newName: String
    public let status: BatchRenameStatus
}

public struct BatchRenamePreview: Equatable, Sendable {
    public let rows: [BatchRenameRow]
    public var problemCount: Int { rows.filter(\.status.isProblem).count }
    public var changeCount: Int { rows.filter { $0.status == .ok }.count }
    public var canApply: Bool { problemCount == 0 && changeCount > 0 }
    /// The renames to perform, only when there are no problems.
    public var plan: [(url: URL, newName: String)] {
        rows.filter { $0.status == .ok }.map { ($0.item.url, $0.newName) }
    }
}

public enum BatchRenameError: Error, Equatable, LocalizedError {
    case badPattern(String)
    case failed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .badPattern(let why): return L10n.format("The regular expression isn't valid: %@", "\(why)")
        case .failed(let name, let reason): return L10n.format("Couldn't rename “%@”: %@", "\(name)", "\(reason)")
        }
    }
}

public enum BatchRenamer {
    /// The new name for one item (index = position in the batch, for numbering).
    public static func transform(_ item: RenameCandidate, index: Int, options o: BatchRenameOptions) throws -> String {
        var (base, ext) = NameRules.splitExtension(item.name, treatAsFolder: item.isFolder)
        if o.includeExtension {
            base = item.name
            ext = nil
        }
        if !o.find.isEmpty {
            if o.useRegex {
                let regex: NSRegularExpression
                do { regex = try NSRegularExpression(pattern: o.find, options: o.matchCase ? [] : [.caseInsensitive]) } catch {
                    throw BatchRenameError.badPattern(error.localizedDescription)
                }
                base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: o.replace)
            } else {
                base = base.replacingOccurrences(of: o.find, with: o.replace, options: o.matchCase ? [] : [.caseInsensitive])
            }
        }
        if o.includeExtension {
            (base, ext) = NameRules.splitExtension(o.caseStyle.apply(base), treatAsFolder: item.isFolder)
        } else {
            base = o.caseStyle.apply(base)
        }
        base = o.prefix + base + o.suffix
        if o.numbering {
            let number = o.numberStart + index * o.numberStep
            let digits = String(abs(number))
            let padded = (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, o.numberDigits - digits.count)) + digits
            base = o.numberAtStart ? padded + o.numberSeparator + base : base + o.numberSeparator + padded
        }
        if !item.isFolder {
            switch o.extensionHandling {
            case .keep: break
            case .lowercase: ext = ext?.lowercased()
            case .uppercase: ext = ext?.uppercased()
            case .remove: ext = nil
            case .change(let to):
                let clean = to.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                ext = clean.isEmpty ? nil : clean
            }
        }
        return ext.map { "\(base).\($0)" } ?? base
    }

    /// Computes every new name and flags problems before anything is renamed.
    /// `existingNames(folder)` lists what is in a folder now (all entries, batch members included).
    /// Names are compared case-insensitively: on the default Mac volume "a.txt" and "A.txt" collide.
    public static func preview(_ items: [RenameCandidate], options: BatchRenameOptions,
                               existingNames: (URL) -> [String]) throws -> BatchRenamePreview {
        let proposed = try items.enumerated().map { try transform($1, index: $0, options: options) }
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

        // Final names per folder: batch items' new names plus untouched entries outside the batch.
        var batchKeys: [URL: [String: Int]] = [:]
        for (i, item) in items.enumerated() { batchKeys[item.folder, default: [:]][key(proposed[i]), default: 0] += 1 }
        var outside: [URL: Set<String>] = [:]
        for folder in Set(items.map(\.folder)) {
            let members = Set(items.filter { $0.folder == folder }.map { key($0.name) })
            outside[folder] = Set(existingNames(folder).map(key)).subtracting(members)
        }
        let rows = items.enumerated().map { i, item -> BatchRenameRow in
            let name = proposed[i]
            let status: BatchRenameStatus
            if let problem = NameRules.validate(name) {
                status = .invalid(problem.errorDescription ?? "Invalid name")
            } else if name.trimmingCharacters(in: .whitespaces).isEmpty || name.hasPrefix(".") && !item.name.hasPrefix(".") {
                status = .invalid(name.hasPrefix(".") ? L10n.tr("Would become hidden") : L10n.tr("A name can't be empty."))
            } else if (batchKeys[item.folder]?[key(name)] ?? 0) > 1 {
                status = .duplicate
            } else if outside[item.folder]?.contains(key(name)) == true {
                status = .exists
            } else {
                status = name == item.name ? .unchanged : .ok
            }
            return BatchRenameRow(item: item, newName: name, status: status)
        }
        return BatchRenamePreview(rows: rows)
    }

    /// Renames everything in `plan` or nothing. Names that swap or shift between batch members are
    /// handled by renaming through temporary names first. On any failure, completed renames are
    /// reverted and the error is thrown. Never overwrites an item (Renamer refuses).
    /// Returns (old URL, new URL) pairs.
    @discardableResult
    public static func apply(_ plan: [(url: URL, newName: String)], fileManager: FileManager = .default) throws -> [(from: URL, to: URL)] {
        let changes = plan.filter { $0.url.lastPathComponent != $0.newName }
        guard !changes.isEmpty else { return [] }
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        let sourceKeys = Set(changes.map { "\($0.url.deletingLastPathComponent().path)/\(key($0.url.lastPathComponent))" })
        let needsTemp = changes.contains { change in
            let target = "\(change.url.deletingLastPathComponent().path)/\(key(change.newName))"
            return sourceKeys.contains(target) && key(change.url.lastPathComponent) != key(change.newName)
        }

        var done: [(from: URL, to: URL)] = []
        func rollback() {
            for step in done.reversed() { try? fileManager.moveItem(at: step.to, to: step.from) }
        }
        do {
            if needsTemp {
                var staged: [(original: URL, temp: URL, newName: String)] = []
                for change in changes {
                    let temp = try Renamer.rename(change.url, to: ".arbor-batch-\(UUID().uuidString)", fileManager: fileManager)
                    done.append((change.url, temp))
                    staged.append((change.url, temp, change.newName))
                }
                for item in staged {
                    let final = try Renamer.rename(item.temp, to: item.newName, fileManager: fileManager)
                    done.append((item.temp, final))
                }
                return staged.map { ($0.original, $0.original.deletingLastPathComponent().appendingPathComponent($0.newName)) }
            }
            for change in changes {
                let final = try Renamer.rename(change.url, to: change.newName, fileManager: fileManager)
                done.append((change.url, final))
            }
            return done
        } catch {
            rollback()
            let failing = changes.first { c in !done.contains { $0.from == c.url } }?.url.lastPathComponent ?? ""
            throw BatchRenameError.failed(name: failing, reason: error.localizedDescription)
        }
    }

    /// The plan that undoes `applied` (new names back to old names).
    public static func reversePlan(_ applied: [(from: URL, to: URL)]) -> [(url: URL, newName: String)] {
        applied.map { ($0.to, $0.from.lastPathComponent) }
    }
}
