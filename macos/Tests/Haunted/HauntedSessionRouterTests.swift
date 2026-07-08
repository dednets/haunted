import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.3 — OPEN-01…05 and the split-inheritance decision (SPL-01/02).
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

    // MARK: OPEN-01…05

    /// OPEN-01. Sessions persist in the workstation's haunted-daemon across
    /// Terminal quits, so resuming is the whole point of remembering.
    @Test("OPEN-01: last-attached workstation still online → resume that session")
    func resumesLastAttached() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: [workstation("alice/box/haunted", online: true)])
        #expect(route == .resume(target: "alice/box/haunted", session: "work"))
    }

    /// OPEN-02. Attaching to an offline daemon would hang on the reconnect loop
    /// rather than show anything useful, so fall through to one that is up.
    @Test("OPEN-02: last-attached workstation offline → first online, default session")
    func fallsBackWhenLastIsOffline() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: [
                workstation("alice/box/haunted", online: false),
                workstation("alice/other/haunted", online: true),
            ])
        #expect(route == .fresh(target: "alice/other/haunted"))
    }

    @Test("OPEN-03: no last-attached, one online → that one")
    func picksTheOnlyOnlineWorkstation() {
        let route = HauntedSessionRouter.route(
            lastAttached: nil,
            workstations: [
                workstation("alice/a/haunted", online: false),
                workstation("alice/b/haunted", online: true),
            ])
        #expect(route == .fresh(target: "alice/b/haunted"))
    }

    /// OPEN-04/05. The one place a Haunted window legitimately hosts an
    /// unattached local shell: nothing is reachable, but the sidebar must still
    /// appear so the user can click a workstation once one comes online.
    @Test("OPEN-04: no workstation online → plain shell")
    func plainShellWhenNothingOnline() {
        #expect(HauntedSessionRouter.route(
            lastAttached: nil,
            workstations: [workstation("alice/a/haunted", online: false)]) == .plainShell)
    }

    @Test("OPEN-05: last-attached set but the workstation list is empty → plain shell")
    func plainShellWhenListEmpty() {
        #expect(HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "work"),
            workstations: []) == .plainShell)
    }

    /// A last-attached target that is present *and* online must beat an earlier
    /// online workstation in the list — resume is not "first online".
    @Test("OPEN-01: resume wins over an earlier online workstation")
    func resumeBeatsListOrder() {
        let route = HauntedSessionRouter.route(
            lastAttached: ("alice/z/haunted", "work"),
            workstations: [
                workstation("alice/a/haunted", online: true),
                workstation("alice/z/haunted", online: true),
            ])
        #expect(route == .resume(target: "alice/z/haunted", session: "work"))
    }

    /// The resumed session name is trusted from UserDefaults, not from the
    /// mesh — but it still has to be a name the daemon would accept, or the
    /// attach fails with a confusing error rather than a clean create.
    @Test("OPEN-01: a resumed session name is one the daemon would accept")
    func resumedSessionNameIsValid() {
        guard case .resume(_, let session) = HauntedSessionRouter.route(
            lastAttached: ("alice/box/haunted", "gui-0123456789abcdef"),
            workstations: [workstation("alice/box/haunted", online: true)])
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
