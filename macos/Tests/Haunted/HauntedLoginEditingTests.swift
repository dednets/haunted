import AppKit
import Testing
@testable import Ghostty

/// LGED — the login window's editing-shortcut routing (HauntedEditableWindow).
///
/// The window exists because the Terminal's menu binds ⌘V to a terminal paste
/// that swallows the shortcut when the login field is focused. The key→selector
/// map is the testable core; the responder-chain dispatch is AppKit plumbing
/// verified by running the app.
struct HauntedLoginEditingTests {
    // LGED-01: the standard editing chords map to the standard responder
    // selectors — ⌘V above all, the shortcut that was being swallowed.
    @Test(arguments: [
        ("v", "paste:"),
        ("c", "copy:"),
        ("x", "cut:"),
        ("a", "selectAll:"),
        ("z", "undo:"),
    ])
    func commandKeyMapsToEditingSelector(key: String, selector: String) {
        let mapped = HauntedEditableWindow.editingSelector(forCommandKey: key)
        #expect(mapped.map(NSStringFromSelector) == selector)
    }

    // LGED-02: non-editing keys are left alone, so ⌘W/⌘N/⌘Q etc. still reach
    // the menu instead of being intercepted.
    @Test(arguments: ["w", "n", "q", "t", ""])
    func nonEditingKeysAreNotIntercepted(key: String) {
        #expect(HauntedEditableWindow.editingSelector(forCommandKey: key) == nil)
    }
}
