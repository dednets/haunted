import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.3 — OPEN-01…06 and the split-inheritance decision (SPL-01/02).
///
/// These are the decisions `openWindow` and `splitConfiguration` make; both
/// functions themselves need `NSApp.delegate`, a Ghostty instance and a live
/// `Ghostty.SurfaceView`, none of which a unit test can supply. §5.4 extracts
/// the decision so it can be checked without any of that.
struct HauntedSessionRouterTests {
    private func workstation(
        _ target: String, online: Bool
    ) -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: String(target.split(separator: "/")[1]),
            app: "haunted", online: online, state: nil, error: nil)
    }

    private func session(_ name: String) -> HauntedWorkstationSession {
        HauntedWorkstationSession(
            name: name, pid: 1, clients: 0, cols: 80, rows: 24,
            created: 0, title: nil)
    }

    // MARK: OPEN-01…06

    /// OPEN-01. Sessions persist in the workstation's haunted-daemon across
    /// Terminal quits, so resuming is the whole point of remembering — but only
    /// when that session is still there to resume.
    @Test("OPEN-01: last-attached workstation online and session still exists → resume")
    func resumesLastAttached() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: [workstation("alice/box/haunted", online: true)],
            sessionsOnLastTarget: [session("work")])
        #expect(route == .resume(target: "alice/box/haunted", session: "work"))
    }

    /// OPEN-02. The startup-never-creates rule. A remembered session that is no
    /// longer on the daemon (killed, or the daemon restarted) must NOT be
    /// resumed — resuming used to attach with `--create`, minting a fresh
    /// session on every launch. Nothing to resume → empty state.
    @Test("OPEN-02: remembered session no longer exists → empty (never re-create)")
    func emptyWhenRememberedSessionIsGone() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "gui-deadbeefdeadbeef"),
            workstations: [workstation("alice/box/haunted", online: true)],
            sessionsOnLastTarget: [session("default"), session("other")])
        #expect(route == .empty)
    }

    /// OPEN-03. Attaching to an offline daemon would hang on the reconnect loop
    /// rather than show anything useful, and we do not auto-attach to some other
    /// online workstation — that is a click the user has not made yet.
    @Test("OPEN-03: last-attached workstation offline → empty, not another workstation")
    func emptyWhenLastIsOffline() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: [
                workstation("alice/box/haunted", online: false),
                workstation("alice/other/haunted", online: true),
            ],
            sessionsOnLastTarget: [])
        #expect(route == .empty)
    }

    /// OPEN-04. No last-attached at all: a first-ever launch, or a cleared
    /// default. The sidebar appears with the "Nothing here" placeholder; the
    /// user picks a workstation. Startup never opens a session unprompted, even
    /// when one workstation is online and ready.
    @Test("OPEN-04: no last-attached, workstations online → empty (no auto-open)")
    func emptyWhenNothingRemembered() {
        let route = HauntedSessionRouter.route(
            lastAttached: nil,
            workstations: [
                workstation("alice/a/haunted", online: false),
                workstation("alice/b/haunted", online: true),
            ],
            sessionsOnLastTarget: [])
        #expect(route == .empty)
    }

    /// OPEN-05. Nothing online, nothing remembered → empty. (This is the case
    /// that used to be `.plainShell`; the shell is gone, replaced by the
    /// "Nothing here" placeholder.)
    @Test("OPEN-05: no workstation online → empty")
    func emptyWhenNothingOnline() {
        #expect(HauntedSessionRouter.route(
            lastAttached: nil,
            workstations: [workstation("alice/a/haunted", online: false)],
            sessionsOnLastTarget: []) == .empty)
    }

    /// OPEN-06. Remembered workstation is present but only listed offline while
    /// its session technically still shows in a stale list — offline wins, we
    /// do not attach into a reconnect hang.
    @Test("OPEN-06: session listed but workstation offline → empty")
    func offlineBeatsAStaleSessionList() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: [workstation("alice/box/haunted", online: false)],
            sessionsOnLastTarget: [session("work")])
        #expect(route == .empty)
    }

    /// The resumed session name is trusted from UserDefaults, not from the
    /// mesh — but it still has to be a name the daemon would accept, or the
    /// attach fails with a confusing error rather than a clean resume.
    @Test("OPEN-01: a resumed session name is one the daemon would accept")
    func resumedSessionNameIsValid() {
        guard case .resume(_, let session) = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "gui-0123456789abcdef"),
            workstations: [workstation("alice/box/haunted", online: true)],
            sessionsOnLastTarget: [self.session("gui-0123456789abcdef")])
        else { return #expect(Bool(false), "expected .resume") }
        #expect(isValidSessionName(session))
    }

    // MARK: SPL-01/02 — the split-inheritance decision

    /// SPL-01. A split of a Haunted surface opens a *fresh* session on the same
    /// workstation, never a second attach to the parent's session.
    @Test("SPL-01: split from a Haunted surface inherits the target, fresh session")
    func splitInheritsTarget() {
        let plan = HauntedManager.splitPlan(
            parentTarget: "alice/box/haunted", generateName: { "gui-0123456789abcdef" })
        #expect(plan == .inherit(target: "alice/box/haunted",
                                 sessionName: "gui-0123456789abcdef"))
    }

    /// SPL-02. A plain-shell parent has no target; the caller's own config must
    /// come back untouched and no session name may be left pending.
    @Test("SPL-02: split from a non-Haunted surface passes through")
    func splitPassesThroughWithoutTarget() {
        #expect(HauntedManager.splitPlan(parentTarget: nil) == .passthrough)
    }

    /// The generated name must survive the decode filter, or the session the
    /// split creates would be dropped from the sidebar it just appeared in.
    @Test("SPL-01: the inherited session name is a valid session name")
    func splitSessionNameIsValid() {
        guard case .inherit(_, let sessionName) = HauntedManager.splitPlan(
            parentTarget: "alice/box/haunted")
        else { return #expect(Bool(false), "expected .inherit") }
        #expect(isValidSessionName(sessionName))
        #expect(sessionName.hasPrefix("gui-"))
    }
}
