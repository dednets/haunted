import Testing
import AppKit
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

    /// KILL-01. Killing the *last* session in a window must not close the
    /// window: `window.close()` freed the attached SurfaceView while libghostty
    /// was still delivering a surface action into it (a use-after-free that
    /// aborted the app). The last tab drops to the "Nothing here" empty state;
    /// only a window that still has sibling tabs closes the tab normally.
    @Test("KILL-01: last tab → empty state, more tabs → close the tab")
    func lastSessionEmptiesInsteadOfClosing() {
        #expect(HauntedManager.sessionTabClosePlan(siblingTabCount: 1) == .emptyState)
        // A tab group's count includes this tab, so "> 1" means real siblings.
        #expect(HauntedManager.sessionTabClosePlan(siblingTabCount: 2) == .closeTab)
        #expect(HauntedManager.sessionTabClosePlan(siblingTabCount: 5) == .closeTab)
    }

    /// A count of 0 should never happen (a window showing a session has at
    /// least its own tab), but if it does, empty is the safe, non-crashing
    /// choice — never a close that could re-trigger the teardown crash.
    @Test("KILL-01: a degenerate zero count still avoids closing")
    func zeroTabCountAvoidsClose() {
        #expect(HauntedManager.sessionTabClosePlan(siblingTabCount: 0) == .emptyState)
    }

    // MARK: LAND-01…04 — sessionLanded (the ⌘T/⌘D → sidebar hand-off)

    /// Scripted per-call answers; the last repeats. Local rather than shared:
    /// `HauntedSidebarModelTests.FakeListing` answers statically per target,
    /// and these cases are about the *sequence* of polls.
    private final class ScriptedListing: HauntedSessionListing, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<[HauntedWorkstationSession], any Error>]
        private var _calls = 0

        init(_ answers: [Result<[HauntedWorkstationSession], any Error>]) {
            self.answers = answers
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }; return _calls
        }

        func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation] {
            []
        }

        func sessions(
            identity: HauntedClientIdentity, target: String
        ) async throws -> [HauntedWorkstationSession] {
            lock.lock()
            let index = min(_calls, answers.count - 1)
            _calls += 1
            let result = answers[index]
            lock.unlock()
            return try result.get()
        }
    }

    private static let identity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/nonexistent"), console: nil)

    private static func session(_ name: String, clients: Int) -> HauntedWorkstationSession {
        HauntedWorkstationSession(
            name: name, pid: 1, clients: clients, cols: 80, rows: 24,
            created: 0, title: nil)
    }

    /// LAND-01. A ⌘T tab / ⌘D split runs `haunted attach --create` inside its
    /// surface; the session exists daemon-side only once that lands. The
    /// sidebar is told the moment it does, so the new row appears in ~a
    /// second instead of waiting out the next poll.
    @Test("LAND-01: landed as soon as the daemon lists the session with a client")
    func landedOnFirstSighting() async {
        let listing = ScriptedListing([
            .success([Self.session("gui-abc", clients: 1)]),
        ])
        let landed = await HauntedManager.sessionLanded(
            identity: Self.identity, target: "u/ws/haunted", sessionName: "gui-abc",
            listing: listing, pollEvery: 0.01, deadline: 1)
        #expect(landed)
        #expect(listing.calls == 1, "no extra polls once seen")
    }

    /// LAND-02. Listed but with no client yet means the attach is still in
    /// flight — keep polling until it is real.
    @Test("LAND-02: a session without an attached client is not yet landed")
    func keepsPollingUntilClientAttaches() async {
        let listing = ScriptedListing([
            .success([Self.session("gui-abc", clients: 0)]),
            .success([Self.session("gui-abc", clients: 0)]),
            .success([Self.session("gui-abc", clients: 1)]),
        ])
        let landed = await HauntedManager.sessionLanded(
            identity: Self.identity, target: "u/ws/haunted", sessionName: "gui-abc",
            listing: listing, pollEvery: 0.01, deadline: 5)
        #expect(landed)
        #expect(listing.calls == 3)
    }

    /// LAND-03. An attach that never lands gives up at the deadline — false,
    /// not forever. (The poll loop then owns eventual consistency.)
    @Test("LAND-03: gives up at the deadline when the session never appears")
    func givesUpAtDeadline() async {
        let listing = ScriptedListing([.success([])])
        let landed = await HauntedManager.sessionLanded(
            identity: Self.identity, target: "u/ws/haunted", sessionName: "gui-abc",
            listing: listing, pollEvery: 0.01, deadline: 0.1)
        #expect(!landed)
        #expect(listing.calls >= 2, "it polled rather than checking once")
    }

    /// LAND-04. A listing that throws (mesh blip mid-attach) is retried, not
    /// fatal — and still bounded by the deadline.
    @Test("LAND-04: listing failures are retried until the deadline")
    func listingFailuresRetried() async {
        let listing = ScriptedListing([
            .failure(HauntedCLIError(message: "mesh down")),
            .success([Self.session("gui-abc", clients: 1)]),
        ])
        let landed = await HauntedManager.sessionLanded(
            identity: Self.identity, target: "u/ws/haunted", sessionName: "gui-abc",
            listing: listing, pollEvery: 0.01, deadline: 5)
        #expect(landed)
        #expect(listing.calls == 2)
    }

    // MARK: CLOSE-01…03 — ⌘W kills the remote session by default

    /// CLOSE-01. THE BUG: closing a Haunted tab only detached the persistent
    /// remote session — it kept running on the workstation — while the dialog
    /// claimed "the process will be killed". The DEFAULT ⌘W action (Enter →
    /// the first NSAlert button) must map to `.close`, which exits the remote
    /// session like typing `exit`. "Run in Background" is the second button,
    /// everything else (Escape, dismissed sheet, or no dialog at all) cancels.
    @Test("CLOSE-01: the default close action kills the session; second detaches; else cancels")
    func closeTabChoiceMapping() {
        #expect(HauntedManager.closeTabChoice(for: .alertFirstButtonReturn) == .close)
        #expect(HauntedManager.closeTabChoice(for: .alertSecondButtonReturn) == .runInBackground)
        #expect(HauntedManager.closeTabChoice(for: .alertThirdButtonReturn) == .cancel)
        // No dialog could be shown (already-open alert, no window) → do nothing:
        // never silently close-and-kill, never silently detach.
        #expect(HauntedManager.closeTabChoice(for: nil) == .cancel)
    }

    /// CLOSE-02. Button order is load-bearing: NSAlert makes the first-added
    /// button the default (Enter) and lays them out right-to-left, so the
    /// titles must be [Close, Run in Background, Cancel] to render as
    /// "Cancel   Run in Background   Close" with Close as the Enter default.
    @Test("CLOSE-02: Close is the default button; Cancel is present for Escape")
    func closeTabButtonOrder() {
        #expect(HauntedManager.closeTabButtonTitles.first == "Close",
                "the first NSAlert button is the Enter default — it must be Close")
        #expect(HauntedManager.closeTabButtonTitles == ["Close", "Run in Background", "Cancel"])
        #expect(HauntedManager.closeTabButtonTitles.contains("Cancel"),
                "a button titled Cancel is what gives Escape its key equivalent")
    }

    /// CLOSE-03. `Close` must actually issue a `haunted kill` per session over
    /// the CLI — one for every split's session, with its own target/name — not
    /// merely tear down the tab (which is all the old path did). Verified
    /// through the process seam, so no window or live daemon is needed.
    @Test("CLOSE-03: killSessionsRemote issues one `haunted kill` per session")
    func killSessionsRemoteFansOut() async {
        let runner = FakeProcessRunner()
        let sessions = [
            HauntedManager.SessionRef(target: "luiz/ws1/haunted", sessionName: "gui-aaaa"),
            HauntedManager.SessionRef(target: "luiz/ws1/haunted", sessionName: "gui-bbbb"),
        ]
        await HauntedManager.killSessionsRemote(
            identity: Self.identity, sessions: sessions, runner: runner)

        let kills = runner.invocations.compactMap { $0.command }
            .filter { $0.contains(" kill ") }
        #expect(kills.count == 2, "expected one kill per session, got \(kills.count)")
        #expect(kills.contains { $0.contains("kill 'gui-aaaa'") && $0.contains("--target 'luiz/ws1/haunted'") })
        #expect(kills.contains { $0.contains("kill 'gui-bbbb'") && $0.contains("--target 'luiz/ws1/haunted'") })
    }

    /// A tab with no attached session (plain shell / empty state) has nothing
    /// to kill: an empty list issues no CLI calls at all.
    @Test("CLOSE-03: no sessions → no kill invocations")
    func killSessionsRemoteEmptyIsNoOp() async {
        let runner = FakeProcessRunner()
        await HauntedManager.killSessionsRemote(
            identity: Self.identity, sessions: [], runner: runner)
        #expect(runner.invocations.isEmpty)
    }
}
