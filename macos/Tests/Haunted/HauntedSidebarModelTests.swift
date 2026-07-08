import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.4 — MOD-01…11.
///
/// The model owns the poll loop, so the behavior worth pinning is what it does
/// to already-loaded data when the mesh misbehaves: a transient CLI failure must
/// not flash the sidebar to empty, and a poll must not undo the user's
/// collapses. §5.4 makes it instantiable and injects the client, the poll
/// interval, and the kill action — without which every one of these tests would
/// spawn `dedmeshctl` and wait ten seconds.
@MainActor
struct HauntedSidebarModelTests {
    // MARK: Fakes

    /// Records calls and replays scripted answers. `@unchecked Sendable`: it is
    /// only ever touched from the main actor, but `HauntedSessionListing` is
    /// `Sendable` because the real one crosses to a subprocess.
    final class FakeListing: HauntedSessionListing, @unchecked Sendable {
        private let lock = NSLock()
        private var _workstationCalls = 0
        private var _sessionCalls: [String] = []

        /// Answers for successive `workstations` calls; the last repeats.
        var workstationResults: [Result<[HauntedWorkstation], any Error>] = [.success([])]
        /// Per-target session answers. A missing target throws.
        var sessionsByTarget: [String: [HauntedWorkstationSession]] = [:]

        var workstationCalls: Int {
            lock.lock(); defer { lock.unlock() }; return _workstationCalls
        }
        var sessionCalls: [String] {
            lock.lock(); defer { lock.unlock() }; return _sessionCalls
        }

        func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation] {
            lock.lock()
            let index = min(_workstationCalls, workstationResults.count - 1)
            _workstationCalls += 1
            let result = workstationResults[index]
            lock.unlock()
            return try result.get()
        }

        func sessions(
            identity: HauntedClientIdentity, target: String
        ) async throws -> [HauntedWorkstationSession] {
            lock.lock()
            _sessionCalls.append(target)
            let sessions = sessionsByTarget[target]
            lock.unlock()
            guard let sessions else { throw HauntedCLIError(message: "unreachable") }
            return sessions
        }
    }

    private static let identity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/nonexistent"), console: "c.example.com:9443")
    private static let otherIdentity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/elsewhere"), console: "c.example.com:9443")

    private static func workstation(_ target: String, online: Bool) -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: String(target.split(separator: "/")[1]),
            app: "haunted", online: online, state: nil, error: nil)
    }

    private static func session(_ name: String) -> HauntedWorkstationSession {
        HauntedWorkstationSession(
            name: name, pid: 1, clients: 0, cols: 80, rows: 24, created: 0, title: nil)
    }

    /// A model whose poll loop runs fast and whose kill action is observable.
    /// `pollInterval` is short but not zero: a zero interval spins the loop.
    private func makeModel(
        _ client: FakeListing,
        pollInterval: TimeInterval = 3600,
        refreshDelay: TimeInterval = 0.05,
        killed: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) -> HauntedSidebarModel {
        HauntedSidebarModel(
            client: client,
            killSession: { _, target, name in killed(target, name) },
            pollInterval: pollInterval,
            refreshDelay: refreshDelay)
    }

    /// Spins the main runloop until `condition` holds or the deadline passes.
    /// Polling beats a fixed sleep: the loop under test is asynchronous, and a
    /// sleep tuned to a fast machine is a flake on a slow one.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        _ what: @autoclosure () -> String = "condition"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Bool(false), "timed out waiting for \(what())")
    }

    // MARK: MOD-01/02 — start()

    @Test("MOD-01: start twice with the same identity runs one poll loop")
    func startIsIdempotent() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded }, "first load")
        let after = client.workstationCalls

        model.start(identity: Self.identity)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.workstationCalls == after, "a second start must not re-poll")
    }

    @Test("MOD-02: start with a different identity restarts the poll")
    func startWithNewIdentityRestarts() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let after = client.workstationCalls

        model.start(identity: Self.otherIdentity)
        try await waitUntil({ client.workstationCalls > after }, "re-poll after re-login")
    }

    /// MOD-11. `pollTask` stays non-nil after cancellation, so a `start()` that
    /// only checked for nil would refuse to ever resume polling.
    @Test("MOD-11: a stopped poll resumes on the next start, keeping its data")
    func stoppedPollResumes() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let after = client.workstationCalls

        model.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.workstations.count == 1, "stopping must not discard data")

        model.start(identity: Self.identity)
        try await waitUntil({ client.workstationCalls > after }, "poll resumes")
    }

    // MARK: MOD-03/04 — error handling

    /// MOD-03. The sidebar must not blink to empty because one `dedmeshctl`
    /// invocation failed; the user is looking at a list of machines, not a
    /// liveness indicator.
    @Test("MOD-03: a failing poll sets errorMessage and retains the workstations")
    func failingPollRetainsData() async throws {
        let client = FakeListing()
        client.workstationResults = [
            .success([Self.workstation("a/b/haunted", online: false)]),
            .failure(HauntedCLIError(message: "mesh down")),
        ]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.errorMessage != nil }, "the failure lands")

        #expect(model.errorMessage == "mesh down")
        #expect(model.workstations.map(\.target) == ["a/b/haunted"], "data must survive")
    }

    @Test("MOD-04: a recovering poll clears errorMessage")
    func recoveringPollClearsError() async throws {
        let client = FakeListing()
        client.workstationResults = [
            .failure(HauntedCLIError(message: "mesh down")),
            .success([Self.workstation("a/b/haunted", online: false)]),
        ]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.errorMessage == nil && !model.workstations.isEmpty },
                            "recovery")
    }

    // MARK: MOD-05/06 — expansion state

    @Test("MOD-05: the first load auto-expands online workstations only")
    func firstLoadExpandsOnline() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([
            Self.workstation("a/on/haunted", online: true),
            Self.workstation("a/off/haunted", online: false),
        ])]
        client.sessionsByTarget = ["a/on/haunted": []]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        #expect(model.expanded == ["a/on/haunted"])
    }

    /// MOD-06. Re-deriving the expansion set every ten seconds would reopen
    /// whatever the user just collapsed.
    @Test("MOD-06: a later poll does not re-derive expansion, so a collapse survives")
    func laterPollKeepsUserCollapse() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/on/haunted", online: true)])]
        client.sessionsByTarget = ["a/on/haunted": []]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        try #require(model.expanded == ["a/on/haunted"])

        model.toggle(Self.workstation("a/on/haunted", online: true))
        #expect(model.expanded.isEmpty)

        let calls = client.workstationCalls
        try await waitUntil({ client.workstationCalls > calls + 1 }, "two more polls")
        #expect(model.expanded.isEmpty, "the poll must not reopen a collapsed workstation")
    }

    // MARK: MOD-07 — kill

    @Test("MOD-07: kill removes the session optimistically and delegates")
    func killIsOptimistic() async throws {
        let client = FakeListing()
        let workstation = Self.workstation("a/b/haunted", online: true)
        client.workstationResults = [.success([workstation])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("one"), Self.session("two")]]

        var killedWith: (String, String)?
        let model = makeModel(client, killed: { killedWith = ($0, $1) })
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 2 })

        model.kill(workstation: workstation, session: "one")
        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["two"],
                "the row disappears before the daemon has answered")
        #expect(killedWith?.0 == "a/b/haunted")
        #expect(killedWith?.1 == "one")
    }

    @Test("MOD-07: kill before any identity is set is a no-op")
    func killWithoutIdentity() {
        var killCount = 0
        let model = makeModel(FakeListing(), killed: { _, _ in killCount += 1 })
        model.kill(workstation: Self.workstation("a/b/haunted", online: true), session: "one")
        #expect(killCount == 0)
    }

    // MARK: MOD-08 — the change notification

    @Test("MOD-08: hauntedSessionsDidChange refreshes sessions after the delay")
    func notificationTriggersRefresh() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("one")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let before = client.sessionCalls.count

        NotificationCenter.default.post(name: .hauntedSessionsDidChange, object: nil)
        try await waitUntil({ client.sessionCalls.count > before }, "the debounced refresh")
    }

    // MARK: EXIT-03 — a session that ended must leave the sidebar

    /// TEST_PLAN §4.7. The remote shell exited (`exit`, ctrl-D), the daemon
    /// reaped the session, and `Ghostty.App`'s child-exited hook posted
    /// `.hauntedSessionsDidChange`. The refresh that follows must *remove* the
    /// row, not merely stop adding to it — a lingering row invites a click that
    /// reattaches to a corpse.
    @Test("EXIT-03: a session reaped by the daemon disappears on the next refresh")
    func endedSessionLeavesTheSidebar() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("work"), Self.session("other")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 2 })

        // The user typed `exit` in "work": the daemon no longer lists it.
        client.sessionsByTarget["a/b/haunted"] = [Self.session("other")]
        NotificationCenter.default.post(name: .hauntedSessionsDidChange, object: nil)

        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 1 },
                            "the dead session's row is dropped")
        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["other"])
    }

    /// The last session ending leaves an empty list, not a stale one.
    @Test("EXIT-03: the last session ending empties the workstation's list")
    func lastSessionEndingEmptiesList() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("work")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 1 })

        client.sessionsByTarget["a/b/haunted"] = []
        await model.refreshSessions()
        #expect(model.sessionsByTarget["a/b/haunted"]?.isEmpty == true)
    }

    // MARK: MOD-09/10 — ordering and partial failure

    @Test("MOD-09: workstations sort by target, sessions by name")
    func ordering() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([
            Self.workstation("a/z/haunted", online: true),
            Self.workstation("a/a/haunted", online: true),
        ])]
        client.sessionsByTarget = [
            "a/z/haunted": [Self.session("zeta"), Self.session("alpha")],
            "a/a/haunted": [],
        ]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/z/haunted"] != nil })

        #expect(model.workstations.map(\.target) == ["a/a/haunted", "a/z/haunted"])
        #expect(model.sessionsByTarget["a/z/haunted"]?.map(\.name) == ["alpha", "zeta"])
    }

    /// MOD-10. A mesh blip on one daemon must not empty the whole sidebar.
    @Test("MOD-10: one workstation's session listing failing leaves the others intact")
    func partialSessionFailure() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([
            Self.workstation("a/good/haunted", online: true),
            Self.workstation("a/bad/haunted", online: true),
        ])]
        // "a/bad/haunted" is absent, so the fake throws for it.
        client.sessionsByTarget = ["a/good/haunted": [Self.session("one")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })

        #expect(model.sessionsByTarget["a/good/haunted"]?.map(\.name) == ["one"])
        #expect(model.sessionsByTarget["a/bad/haunted"] == nil)
        #expect(model.workstations.count == 2, "both rows still show")
    }

    /// Offline workstations are never listed — an offline daemon has no sessions
    /// to report and the attempt would just fail slowly.
    @Test("MOD-10: offline workstations are not queried for sessions")
    func offlineWorkstationsNotQueried() async throws {
        let client = FakeListing()
        client.workstationResults = [.success([Self.workstation("a/off/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        #expect(client.sessionCalls.isEmpty)
    }
}
