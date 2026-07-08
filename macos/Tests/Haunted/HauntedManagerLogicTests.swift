import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.3 — NAME-01, TAB-05.
///
/// Only the pure helpers are reachable in Phase 1; the routing and split tests
/// wait on the §5.4 extraction.
struct HauntedManagerLogicTests {
    /// NAME-01. Generated names must satisfy the daemon's `session_name_valid()`
    /// — `gui-` plus 16 lowercase hex digits does, and stays well under
    /// HAUNTED_SESSION_NAME_MAX.
    ///
    /// The uniqueness half of this test is a *statistical* claim and has to be
    /// justified, not hoped for. With n = 10 000 draws from N = 2^b:
    ///
    ///     P(collision) ≈ 1 − exp(−n(n−1) / 2N)
    ///
    /// At the original b = 32 that is **1.16% per run** — this test failed
    /// roughly 1 run in 86, forever, with a perfect RNG. At b = 64 it is
    /// 2.7e-12, i.e. never. Widening the generator is what makes the assertion
    /// legitimate; do not narrow it back without deleting the assertion.
    @Test("NAME-01: generated session names are well-formed and (statistically) unique")
    func generatedSessionNames() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            let name = HauntedManager.generateSessionName()
            #expect(name.count == 20)  // "gui-" + 16 hex
            #expect(name.hasPrefix("gui-"))
            #expect(name.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(isValidSessionName(name), "\(name) would be dropped at decode")
            #expect(seen.insert(name).inserted, "collision on \(name)")
        }
    }

    /// The 64-bit width the uniqueness assertion above depends on. If someone
    /// shortens the generator, this fails with an explanation rather than
    /// leaving NAME-01 to flake once every few hundred CI runs.
    @Test("NAME-01: the generator carries at least 64 bits of entropy")
    func generatorEntropyJustifiesUniquenessAssertion() {
        let hexDigits = HauntedManager.generateSessionName().dropFirst(4).count
        #expect(hexDigits >= 16, """
            \(hexDigits * 4) bits of entropy. NAME-01 draws 10k names and asserts \
            no collision; below 64 bits the birthday bound makes that assertion \
            flaky (at 32 bits: ~1.16% of runs fail).
            """)
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
