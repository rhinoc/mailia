import AppKit
import Testing
@testable import MailiaApp

@Test
func composerShortcutAndUndoOptionsAreUnique() {
    let shortcuts = MailiaComposerShortcut.uniqueSendOptions.map(\.rawValue)
    #expect(Set(shortcuts).count == shortcuts.count)

    let delays = MailiaComposerSettings.allowedUndoDelaySeconds
    #expect(Set(delays).count == delays.count)
}

@Test
func composerLineBreakShortcutDoesNotDuplicateEnabledSendShortcut() {
    for shortcut in MailiaComposerShortcut.uniqueSendOptions {
        let settings = MailiaComposerSettings(sendShortcut: shortcut)

        if shortcut == .off {
            #expect(settings.lineBreakShortcut == .enter)
        } else {
            #expect(settings.lineBreakShortcut != shortcut)
        }
    }
}

@Test
func composerShortcutMatchingHonorsConfiguredModifier() throws {
    let plainEnter = try returnKeyEvent(modifiers: [])
    let commandEnter = try returnKeyEvent(modifiers: [.command])
    let shiftEnter = try returnKeyEvent(modifiers: [.shift])
    let optionEnter = try returnKeyEvent(modifiers: [.option])

    #expect(MailiaComposerShortcut.enter.matches(plainEnter))
    #expect(!MailiaComposerShortcut.enter.matches(commandEnter))
    #expect(!MailiaComposerShortcut.enter.matches(shiftEnter))
    #expect(!MailiaComposerShortcut.enter.matches(optionEnter))

    #expect(MailiaComposerShortcut.commandEnter.matches(commandEnter))
    #expect(!MailiaComposerShortcut.commandEnter.matches(plainEnter))
    #expect(!MailiaComposerShortcut.commandEnter.matches(shiftEnter))
    #expect(!MailiaComposerShortcut.commandEnter.matches(optionEnter))

    #expect(MailiaComposerShortcut.shiftEnter.matches(shiftEnter))
    #expect(!MailiaComposerShortcut.shiftEnter.matches(plainEnter))
    #expect(!MailiaComposerShortcut.shiftEnter.matches(commandEnter))
    #expect(!MailiaComposerShortcut.shiftEnter.matches(optionEnter))

    #expect(!MailiaComposerShortcut.off.matches(plainEnter))
}

private func returnKeyEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    ))
}
