import Foundation
import Testing
@testable import ArborCore

@Suite("File-list keyboard presets (FE-066)")
struct KeyboardPresetTests {
    private func command(_ preset: FileListKeyPreset, _ key: String) -> FileListCommand? {
        guard let parsed = KeyNames.parse(key) else { return nil }
        return preset.command(keyCode: parsed.code, modifiers: parsed.modifiers)
    }

    @Test func everyRowHasTheAgreedCommandInEachPreset() {
        let expected: [(key: String, windows: FileListCommand?, mac: FileListCommand?)] = [
            ("return", nil, .rename),
            ("enter", nil, .rename),
            ("cmd+down", nil, .open),
            ("delete", .back, nil),
            ("forwarddelete", .moveToTrash, nil),
            ("shift+forwarddelete", .deletePermanently, nil),
        ]
        #expect(FileListKeyPreset.rows.map(\.key) == expected.map(\.key))
        for row in expected {
            #expect(command(.windows, row.key) == row.windows, "\(row.key)")
            #expect(command(.mac, row.key) == row.mac, "\(row.key)")
        }
    }

    @Test func everyKeyParsesAndAppearsOnce() {
        var seen = Set<String>()
        for row in FileListKeyPreset.rows {
            guard let key = KeyNames.parse(row.key) else {
                Issue.record("\(row.key) is not a KeyNames spelling")
                continue
            }
            #expect(seen.insert("\(key.code) \(key.modifiers.sorted())").inserted, "\(row.key)")
        }
    }

    @Test func everyRowAssignsSomethingInSomePreset() {
        for row in FileListKeyPreset.rows { #expect(row.windows != nil || row.mac != nil, "\(row.key)") }
    }

    @Test func modifiersMustMatchExactly() {
        for key in ["cmd+return", "shift+return", "opt+return", "cmd+opt+down", "shift+cmd+down", "cmd+delete", "opt+cmd+delete",
                    "shift+delete", "cmd+forwarddelete", "down"] {
            #expect(command(.windows, key) == nil, "\(key)")
            #expect(command(.mac, key) == nil, "\(key)")
        }
    }

    @Test func theMacPresetNeverDeletesFromAPlainKey() {
        let destructive: Set<FileListCommand> = [.moveToTrash, .deletePermanently]
        for row in FileListKeyPreset.rows { #expect(row.mac.map { !destructive.contains($0) } ?? true, "\(row.key)") }
        #expect(command(.windows, "delete") == .back)   // FE-067: plain ⌫ never deletes in either preset
    }

    @Test func unknownStoredTextIsTheWindowsPreset() {
        #expect(FileListKeyPreset.standard == .windows)
        #expect(FileListKeyPreset(stored: "mac") == .mac)
        #expect(FileListKeyPreset(stored: "windows") == .windows)
        for damaged in ["", "junk", "Mac", "MAC", " mac", "1"] { #expect(FileListKeyPreset(stored: damaged) == .windows, "\(damaged)") }
    }

    @Test func onlyRenameAndOpenIgnoreKeyRepeat() {
        let once = FileListCommand.allCases.filter { !$0.repeatsWhileHeld }
        #expect(Set(once) == [.rename, .open])
    }

    @Test func folderOptionsOffersExactlyThePresets() throws {
        let item = try #require(FolderOptionsCatalog.item(FileListKeyPreset.preferenceKey))
        #expect(item.choices.map(\.value) == FileListKeyPreset.allCases.map(\.rawValue))
        #expect(item.choices.map(\.title) == FileListKeyPreset.allCases.map(\.title))
        #expect(item.defaultValue == .string(FileListKeyPreset.standard.rawValue))
        #expect(item.tab == .view)
        #expect(FolderOptionsCatalog.allDefaults[FileListKeyPreset.preferenceKey] == .string("windows"))
    }

    @Test func eachTitleSpellsOutTheKeysThatDiffer() {
        #expect(FileListKeyPreset.windows.title.contains("⌫ goes back"))
        #expect(FileListKeyPreset.windows.title.contains("fn⌫ moves to Trash"))
        #expect(FileListKeyPreset.mac.title.contains("Return renames"))
        #expect(FileListKeyPreset.mac.title.contains("⌘⌫ moves to Trash"))
    }
}
