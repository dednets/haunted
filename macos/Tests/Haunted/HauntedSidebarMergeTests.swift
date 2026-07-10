import Testing
import Foundation
@testable import Ghostty

/// The sidebar's console-workstations × local-Lima-VMs join (MERGE-*).
/// Pure — the state matrix is the whole point: merged, console-only,
/// Lima-only, op attachment, and the cross-user guard.
struct HauntedSidebarMergeTests {
    private static func workstation(
        _ target: String, online: Bool = true
    ) -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: String(target.split(separator: "/")[1]),
            app: "haunted", online: online, state: nil, error: nil)
    }

    private static func vm(_ name: String, status: String = "Running") -> HauntedLimaInstance {
        HauntedLimaInstance(name: name, status: status)
    }

    @Test("MERGE-01: a console workstation and its local VM become one row (prefixed names)")
    func mergesByName() {
        // The console stores "alice-box"; the local VM and the display use
        // the bare "box".
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/alice-box/haunted")],
            lima: [Self.vm("box")],
            ops: [:],
            username: "alice")
        #expect(rows.count == 1)
        #expect(rows[0].workstation?.target == "alice/alice-box/haunted")
        #expect(rows[0].lima == Self.vm("box"))
        #expect(rows[0].owned)
        #expect(rows[0].displayName == "box")
    }

    @Test("MERGE-01b: a legacy unprefixed console daemon still merges by its bare name")
    func legacyUnprefixedMerges() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/box/haunted")],
            lima: [Self.vm("box")],
            ops: [:],
            username: "alice")
        #expect(rows.count == 1)
        #expect(rows[0].lima == Self.vm("box"))
        #expect(rows[0].displayName == "box")
    }

    @Test("MERGE-02: console-only and Lima-only rows stay separate rows")
    func unmatchedRowsStandAlone() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/remote/haunted")],
            lima: [Self.vm("fresh", status: "Stopped")],
            ops: [:],
            username: "alice")
        #expect(rows.count == 2)
        let console = rows.first { $0.workstation != nil }
        let local = rows.first { $0.workstation == nil }
        #expect(console?.lima == nil, "a remote workstation gets no Lima menu")
        #expect(console?.owned == true)
        #expect(local?.lima == Self.vm("fresh", status: "Stopped"))
        #expect(local?.owned == true, "a local VM is ours by definition")
    }

    /// A local VM named like ANOTHER user's daemon must not merge: its menu
    /// would offer to stop/delete a machine that is not ours. The VM still
    /// shows — as its own local row, and the foreign daemon keeps its FULL
    /// name (no stripping of someone else's prefix).
    @Test("MERGE-03: cross-user same-name rows never merge")
    func crossUserNeverMerges() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/alice-box/haunted")],
            lima: [Self.vm("box")],
            ops: ["box": .starting],
            username: "bob")
        #expect(rows.count == 2)
        let console = rows.first { $0.workstation != nil }
        #expect(console?.lima == nil)
        #expect(console?.owned == false)
        #expect(console?.displayName == "alice-box",
                "another user's prefix is part of the name, not decoration")
        #expect(console?.op == nil,
                "an op on OUR VM must not decorate someone else's console row")
        let local = rows.first { $0.workstation == nil }
        #expect(local?.lima == Self.vm("box"))
        #expect(local?.op == .starting)
    }

    @Test("MERGE-04: an unreadable certificate (nil username) merges nothing")
    func nilUsernameMergesNothing() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/box/haunted")],
            lima: [Self.vm("box")],
            ops: [:],
            username: nil)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.lima == nil || $0.workstation == nil })
    }

    @Test("MERGE-05: ops ride the row that owns them (keyed by bare name)")
    func opsAttach() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/alice-box/haunted")],
            lima: [Self.vm("box"), Self.vm("fresh")],
            ops: ["box": .stopping, "fresh": .creating, "ghost": .deleting],
            username: "alice")
        #expect(rows.count == 2)
        #expect(rows.first { $0.displayName == "box" }?.op == .stopping)
        #expect(rows.first { $0.displayName == "fresh" }?.op == .creating)
    }

    /// An owned console row with no VM behind it (the orphan a failed
    /// delete-revoke leaves) still carries its op — that is where the manual
    /// revoke's spinner shows.
    @Test("MERGE-05b: an owned console-only row still carries its op")
    func orphanCarriesOp() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/alice-gone/haunted", online: false)],
            lima: [],
            ops: ["gone": .deleting],
            username: "alice")
        #expect(rows.count == 1)
        #expect(rows[0].lima == nil)
        #expect(rows[0].displayName == "gone")
        #expect(rows[0].op == .deleting)
    }

    @Test("MERGE-06: rows sort by DISPLAY name across both sources")
    func ordering() {
        // "alice-zeta" displays (and sorts) as "zeta" — after the local VMs.
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [Self.workstation("alice/alice-zeta/haunted")],
            lima: [Self.vm("alpha"), Self.vm("mid")],
            ops: [:],
            username: "alice")
        #expect(rows.map(\.displayName) == ["alpha", "mid", "zeta"])
    }

    /// Same daemon name under two different owners in the console list (bob
    /// shares a picker with alice some day): only OUR row may claim the VM.
    @Test("MERGE-07: the VM merges into the owned row, not a same-named foreign one")
    func vmClaimsOwnedRowOnly() {
        let rows = HauntedSidebarMerge.mergeRows(
            workstations: [
                Self.workstation("bob/box/haunted"),
                Self.workstation("alice/alice-box/haunted"),
            ],
            lima: [Self.vm("box")],
            ops: [:],
            username: "alice")
        #expect(rows.count == 2)
        let mine = rows.first { $0.workstation?.target == "alice/alice-box/haunted" }
        let theirs = rows.first { $0.workstation?.target == "bob/box/haunted" }
        #expect(mine?.lima != nil)
        #expect(theirs?.lima == nil)
    }
}
