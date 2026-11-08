import Foundation
import Testing
@testable import ArborCore

@Suite("Type-to-select through the input method (FE-068)")
struct TypeSelectInputTests {
    @Test func typedCharactersGoToTheInputMethod() {
        #expect(TypeSelectRouting.goesToInputMethod(characters: "a", command: false, control: false, typeSelectActive: false, composing: false))
        #expect(TypeSelectRouting.goesToInputMethod(characters: "か", command: false, control: false, typeSelectActive: false, composing: false))
        // ⌘ and ⌃ combinations are shortcuts; arrows and function keys belong to the list.
        #expect(!TypeSelectRouting.goesToInputMethod(characters: "a", command: true, control: false, typeSelectActive: false, composing: false))
        #expect(!TypeSelectRouting.goesToInputMethod(characters: "a", command: false, control: true, typeSelectActive: false, composing: false))
        #expect(!TypeSelectRouting.goesToInputMethod(characters: "\u{F701}", command: false, control: false, typeSelectActive: false, composing: false))
        #expect(!TypeSelectRouting.goesToInputMethod(characters: "\r", command: false, control: false, typeSelectActive: false, composing: false))
    }

    @Test func spaceContinuesANameOnly() {
        #expect(!TypeSelectRouting.goesToInputMethod(characters: " ", command: false, control: false, typeSelectActive: false, composing: false))
        #expect(TypeSelectRouting.goesToInputMethod(characters: " ", command: false, control: false, typeSelectActive: true, composing: false))
    }

    @Test func whileComposingEveryKeyBelongsToTheInputMethod() {
        for characters in ["\u{F701}", "\r", "\u{1B}", " ", "\t"] {
            #expect(TypeSelectRouting.goesToInputMethod(characters: characters, command: false, control: false,
                                                        typeSelectActive: false, composing: true))
        }
    }

    @Test func committedWordsSelectByPrefix() {
        let names = ["apple.txt", "banana.txt", "カタカナ.txt", "かな.txt", "漢字.txt"]
        var select = TypeSelect()
        let now = Date()
        #expect(select.input("かな", at: now, names: names, current: 0) == 3)
        var fresh = TypeSelect()
        #expect(fresh.input("漢", at: now, names: names, current: 0) == 4)
        // Half-width katakana typed through an input method still finds the full-width name.
        var width = TypeSelect()
        #expect(width.input("ｶﾀ", at: now, names: names, current: 0) == 2)
    }
}
