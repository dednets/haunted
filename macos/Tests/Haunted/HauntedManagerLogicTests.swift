import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.3 — NAME-01, TAB-05.
///
/// Only the pure helpers are reachable in Phase 1; the routing and split tests
/// wait on the §5.4 extraction.
struct HauntedManagerLogicTests {
    /// NAME-01. Generated names must satisfy the daemon's `session_name_valid()`
    /// — `gui-` plus 8 lowercase hex digits does, and stays well under
    /// HAUNTED_SESSION_NAME_MAX.
    @Test("NAME-01: generated session names are well-formed and unique")
    func generatedSessionNames() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            let name = HauntedManager.generateSessionName()
            #expect(name.count == 12)
            #expect(name.hasPrefix("gui-"))
            #expect(name.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(isValidSessionName(name), "\(name) would be dropped at decode")
            #expect(seen.insert(name).inserted, "collision on \(name)")
        }
    }

    /// TAB-05. The U+0001 separator is doing real work: without it,
    /// ("a/b", "c") and ("a", "b/c") would collide and a sidebar click could
    /// focus the wrong tab.
    @Test("TAB-05: tabKey does not collide across the target/session boundary")
    func tabKeySeparator() {
        #expect(HauntedManager.tabKey("a/b", "c") != HauntedManager.tabKey("a", "b/c"))
        #expect(HauntedManager.tabKey("a", "b") == HauntedManager.tabKey("a", "b"))
        #expect(HauntedManager.tabKey("a/b", "c") as String == "a/b\u{1}c")
    }

    /// The separator is only safe because neither half can contain it — the
    /// decode filters guarantee that.
    @Test("TAB-05: U+0001 cannot appear in either half of a tabKey")
    func tabKeySeparatorIsUnrepresentable() {
        #expect(!isSafeCLIArgument("a\u{1}b"))
        #expect(!isValidSessionName("a\u{1}b"))
    }
}
