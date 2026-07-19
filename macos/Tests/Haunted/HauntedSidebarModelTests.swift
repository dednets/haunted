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
    ///
    /// `list` mirrors the real multiplexed CLI: one call answers the host list
    /// AND the live lists for the requested targets — a target present in
    /// `sessionsByTarget` answers live, a missing one answers a per-row
    /// `liveError` (the isolated-failure path), and every row carries its
    /// `summariesByTarget` snapshot.
    final class FakeListing: HauntedSessionListing, @unchecked Sendable {
        private let lock = NSLock()
        private var _listCalls = 0
        private var _liveArgs: [[String]] = []

        /// Answers for successive `list` calls; the last repeats.
        var nodeResults: [Result<[HauntedNode], any Error>] = [.success([])]
        /// Per-target LIVE answers. A requested target missing here gets a
        /// per-row liveError instead.
        var sessionsByTarget: [String: [HauntedNodeSession]] = [:]
        /// Per-target console snapshot summaries (never titled in production;
        /// these fakes don't enforce that).
        var summariesByTarget: [String: [HauntedNodeSession]] = [:]
        /// What `setNodeColor` answers; recorded calls in `colorCalls`.
        var setColorResult: Result<Void, any Error> = .success(())
        private var _colorCalls: [(daemon: String, color: String?)] = []

        var listCalls: Int {
            lock.lock(); defer { lock.unlock() }; return _listCalls
        }
        /// The `live` argument of every `list` call, in order — what MOD-16
        /// pins: the poll asks live lists for exactly the expanded rows.
        var liveArgs: [[String]] {
            lock.lock(); defer { lock.unlock() }; return _liveArgs
        }
        /// Every live target ever requested, flattened (the old per-target
        /// query log's analog).
        var liveRequests: [String] { liveArgs.flatMap { $0 } }
        var colorCalls: [(daemon: String, color: String?)] {
            lock.lock(); defer { lock.unlock() }; return _colorCalls
        }

        /// When true, `list` records the call and then spins until it is
        /// cleared — lets a test hold one refresh in-flight to observe
        /// coalescing (MOD-18).
        var listHold: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _listHold }
            set { lock.lock(); _listHold = newValue; lock.unlock() }
        }
        private var _listHold = false

        func list(
            identity: HauntedClientIdentity, live: [String]
        ) async throws -> [HauntedNodeListing] {
            lock.lock()
            let index = min(_listCalls, nodeResults.count - 1)
            _listCalls += 1
            _liveArgs.append(live)
            let result = nodeResults[index]
            lock.unlock()
            while listHold { await Task.yield() }
            let wanted = Set(live)
            lock.lock()
            let liveMap = sessionsByTarget
            let summaries = summariesByTarget
            lock.unlock()
            return try result.get().map { node in
                var liveOut: [HauntedNodeSession]?
                var liveError: String?
                if node.online, wanted.contains(node.target) {
                    if let sessions = liveMap[node.target] {
                        liveOut = sessions
                    } else {
                        liveError = "unreachable"
                    }
                }
                return HauntedNodeListing(
                    node: node,
                    sessions: summaries[node.target] ?? [],
                    live: liveOut, liveError: liveError)
            }
        }

        func setNodeColor(
            identity: HauntedClientIdentity, daemon: String, color: String?
        ) async throws {
            lock.lock()
            _colorCalls.append((daemon: daemon, color: color))
            let result = setColorResult
            lock.unlock()
            try result.get()
        }
    }

    private static let identity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/nonexistent"), console: "c.example.com:9443")
    private static let otherIdentity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/elsewhere"), console: "c.example.com:9443")

    private static func node(_ target: String, online: Bool) -> HauntedNode {
        HauntedNode(
            target: target, daemon: String(target.split(separator: "/")[1]),
            app: "haunted", online: online, state: nil, error: nil)
    }

    private static func session(_ name: String) -> HauntedNodeSession {
        HauntedNodeSession(
            name: name, pid: 1, clients: 0, cols: 80, rows: 24, created: 0, title: nil)
    }

    /// A model whose poll loop runs fast and whose kill action is observable.
    /// `pollInterval` is short but not zero: a zero interval spins the loop.
    private func makeModel(
        _ client: FakeListing,
        pollInterval: TimeInterval = 3600,
        refreshDelay: TimeInterval = 0.05,
        killed: @escaping @MainActor (String, String) -> Void = { _, _ in },
        closedNode: @escaping @MainActor (String) -> Void = { _ in },
        localTabsProvider: @escaping @MainActor () -> [HauntedLocalTab] = { [] }
    ) -> HauntedSidebarModel {
        HauntedSidebarModel(
            client: client,
            killSession: { _, target, name in killed(target, name) },
            closeNode: closedNode,
            pollInterval: pollInterval,
            refreshDelay: refreshDelay,
            localTabsProvider: localTabsProvider)
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
        client.nodeResults = [.success([Self.node("a/b/haunted", online: false)])]
        // Cross-test isolation: other suites post .hauntedSessionsDidChange;
        // a huge refreshDelay keeps those from inflating this test's counts.
        let model = makeModel(client, refreshDelay: 3600)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded }, "first load")
        let after = client.listCalls

        model.start(identity: Self.identity)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.listCalls == after, "a second start must not re-poll")
    }

    @Test("MOD-02: start with a different identity restarts the poll")
    func startWithNewIdentityRestarts() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let after = client.listCalls

        model.start(identity: Self.otherIdentity)
        try await waitUntil({ client.listCalls > after }, "re-poll after re-login")
    }

    /// MOD-11. `pollTask` stays non-nil after cancellation, so a `start()` that
    /// only checked for nil would refuse to ever resume polling.
    @Test("MOD-11: a stopped poll resumes on the next start, keeping its data")
    func stoppedPollResumes() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let after = client.listCalls

        model.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.nodes.count == 1, "stopping must not discard data")

        model.start(identity: Self.identity)
        try await waitUntil({ client.listCalls > after }, "poll resumes")
    }

    // MARK: MOD-03/04 — error handling

    /// MOD-03. The sidebar must not blink to empty because one `dedmeshctl`
    /// invocation failed; the user is looking at a list of machines, not a
    /// liveness indicator.
    @Test("MOD-03: a failing poll sets errorMessage and retains the nodes")
    func failingPollRetainsData() async throws {
        let client = FakeListing()
        client.nodeResults = [
            .success([Self.node("a/b/haunted", online: false)]),
            .failure(HauntedCLIError(message: "mesh down")),
        ]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.errorMessage != nil }, "the failure lands")

        #expect(model.errorMessage == "mesh down")
        #expect(model.nodes.map(\.target) == ["a/b/haunted"], "data must survive")
    }

    @Test("MOD-04: a recovering poll clears errorMessage")
    func recoveringPollClearsError() async throws {
        let client = FakeListing()
        client.nodeResults = [
            .failure(HauntedCLIError(message: "mesh down")),
            .success([Self.node("a/b/haunted", online: false)]),
        ]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.errorMessage == nil && !model.nodes.isEmpty },
                            "recovery")
    }

    // MARK: MOD-05/06 — expansion state

    @Test("MOD-05: the first load auto-expands online nodes only")
    func firstLoadExpandsOnline() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([
            Self.node("a/on/haunted", online: true),
            Self.node("a/off/haunted", online: false),
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
        client.nodeResults = [.success([Self.node("a/on/haunted", online: true)])]
        client.sessionsByTarget = ["a/on/haunted": []]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        try #require(model.expanded == ["a/on/haunted"])

        model.toggle(Self.node("a/on/haunted", online: true))
        #expect(model.expanded.isEmpty)

        let calls = client.listCalls
        try await waitUntil({ client.listCalls > calls + 1 }, "two more polls")
        #expect(model.expanded.isEmpty, "the poll must not reopen a collapsed node")
    }

    // MARK: MOD-07 — kill

    @Test("MOD-07: kill removes the session optimistically and delegates")
    func killIsOptimistic() async throws {
        let client = FakeListing()
        let node = Self.node("a/b/haunted", online: true)
        client.nodeResults = [.success([node])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("one"), Self.session("two")]]

        var killedWith: (String, String)?
        let model = makeModel(client, killed: { killedWith = ($0, $1) })
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 2 })

        model.kill(node: node, session: "one")
        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["two"],
                "the row disappears before the daemon has answered")
        #expect(killedWith?.0 == "a/b/haunted")
        #expect(killedWith?.1 == "one")
    }

    @Test("MOD-07: kill before any identity is set is a no-op")
    func killWithoutIdentity() {
        var killCount = 0
        let model = makeModel(FakeListing(), killed: { _, _ in killCount += 1 })
        model.kill(node: Self.node("a/b/haunted", online: true), session: "one")
        #expect(killCount == 0)
    }

    // MARK: MOD-08 — the change notification

    @Test("MOD-08: hauntedSessionsDidChange refreshes sessions after the delay")
    func notificationTriggersRefresh() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("one")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let before = client.liveRequests.count

        NotificationCenter.default.post(name: .hauntedSessionsDidChange, object: nil)
        try await waitUntil({ client.liveRequests.count > before }, "the debounced refresh")
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
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
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
    @Test("EXIT-03: the last session ending empties the node's list")
    func lastSessionEndingEmptiesList() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
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

    @Test("MOD-09: nodes sort by target, sessions by name")
    func ordering() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([
            Self.node("a/z/haunted", online: true),
            Self.node("a/a/haunted", online: true),
        ])]
        client.sessionsByTarget = [
            "a/z/haunted": [Self.session("zeta"), Self.session("alpha")],
            "a/a/haunted": [],
        ]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/z/haunted"] != nil })

        #expect(model.nodes.map(\.target) == ["a/a/haunted", "a/z/haunted"])
        #expect(model.sessionsByTarget["a/z/haunted"]?.map(\.name) == ["alpha", "zeta"])
    }

    /// MOD-10. A mesh blip on one daemon must not empty the whole sidebar:
    /// its row answers `live_error` and keeps whatever it last showed.
    @Test("MOD-10: one node's live listing failing leaves the others intact")
    func partialSessionFailure() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([
            Self.node("a/good/haunted", online: true),
            Self.node("a/bad/haunted", online: true),
        ])]
        // "a/bad/haunted" is absent, so the fake answers its row with a
        // liveError instead of a live list.
        client.sessionsByTarget = ["a/good/haunted": [Self.session("one")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })

        #expect(model.sessionsByTarget["a/good/haunted"]?.map(\.name) == ["one"])
        #expect(model.sessionsByTarget["a/bad/haunted"]?.isEmpty != false,
                "the failed row shows nothing, not garbage")
        #expect(model.nodes.count == 2, "both rows still show")
    }

    /// MOD-10. A row that HAD sessions keeps them across a live failure —
    /// the user is looking at that list, and a blip must not blank it.
    @Test("MOD-10: a live failure keeps the sessions the row last showed")
    func liveFailureKeepsPreviousSessions() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("work")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 1 })

        // The daemon wedges: live queries now fail for this target.
        client.sessionsByTarget = [:]
        await model.refreshSessions()
        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["work"],
                "the last-known sessions survive a live failure")
    }

    /// Offline nodes are never queried live — an offline daemon has no
    /// sessions to report and the attempt would just fail slowly.
    @Test("MOD-10: offline nodes are not queried for sessions")
    func offlineNodesNotQueried() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/off/haunted", online: false)])]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        #expect(client.liveRequests.isEmpty)
    }

    // MARK: MOD-14 — local title pushes

    /// A session open in this app gets its title pushed by the daemon to the
    /// attached client instantly (that is what retitles the tab). The sidebar
    /// row must follow the tab, not the next list poll — the gap between the
    /// two is the reported "top tab updates immediately, sidebar takes ages".
    @Test("MOD-14: applyLocalTitle retitles a known session without a poll")
    func localTitleAppliesImmediately() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("work")]]
        let model = makeModel(client, refreshDelay: 3600) // notification cross-talk isolation
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 1 })
        let before = client.listCalls

        model.applyLocalTitle(target: "a/b/haunted", sessionName: "work", title: "htop")

        let session = try #require(model.sessionsByTarget["a/b/haunted"]?.first)
        #expect(session.title == "htop")
        #expect(session.displayTitle == "htop")
        #expect(client.listCalls == before, "no CLI round-trip")
        // Only the title moved; identity/geometry are the daemon's to change.
        #expect(session.name == "work")
        #expect(session.cols == 80)
    }

    @Test("MOD-14: applyLocalTitle for an unknown session or target is a no-op")
    func localTitleUnknownIsNoOp() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
        client.sessionsByTarget = ["a/b/haunted": [Self.session("work")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.count == 1 })

        model.applyLocalTitle(target: "a/b/haunted", sessionName: "ghost", title: "htop")
        model.applyLocalTitle(target: "a/nowhere/haunted", sessionName: "work", title: "htop")

        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["work"],
                "no row is fabricated for a session the daemon has not listed")
        #expect(model.sessionsByTarget["a/b/haunted"]?.first?.title == nil)
        #expect(model.sessionsByTarget["a/nowhere/haunted"] == nil)
    }

    // MARK: MOD-12/13 — the console topology changed under us

    /// A host removed on the console vanishes from the next poll. Dropping its
    /// row is not enough: its open tabs would otherwise reconnect-loop for
    /// minutes and then strand a dead banner, and its sessions would linger in
    /// the model. The removal has to close those tabs and prune the sessions.
    @Test("MOD-12: a node removed from the poll closes its tabs and drops its sessions")
    func removedNodeClosesTabs() async throws {
        let client = FakeListing()
        let a = Self.node("u/a/haunted", online: true)
        let b = Self.node("u/b/haunted", online: true)
        // The first cycle consumes TWO answers (the auto-expand follow-up
        // pass re-lists to fetch the new hosts' titles); b is gone from the
        // next cycle — the admin removed it on the console.
        client.nodeResults = [.success([a, b]), .success([a, b]), .success([a])]
        client.sessionsByTarget = [
            "u/a/haunted": [Self.session("s1")],
            "u/b/haunted": [Self.session("s2")],
        ]
        var closed: [String] = []
        let model = makeModel(client, pollInterval: 0.05, refreshDelay: 3600,
                              closedNode: { closed.append($0) })
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["u/b/haunted"] != nil },
                            "b's sessions loaded on the first poll")

        try await waitUntil(
            { !model.nodes.contains { $0.id == "u/b/haunted" } },
            "b drops off on the second poll")

        #expect(closed == ["u/b/haunted"],
                "the removed host's tabs are closed exactly once")
        #expect(model.sessionsByTarget["u/b/haunted"] == nil,
                "its stale sessions are pruned")
        #expect(!model.expanded.contains("u/b/haunted"))
        #expect(model.sessionsByTarget["u/a/haunted"] != nil,
                "the surviving host is untouched")
    }

    /// A host added on the console appears on the next poll. It must arrive
    /// *expanded* so its sessions are visible — the first-load auto-expand
    /// (MOD-05) otherwise never fires for a host that shows up later, and the
    /// user sees a bare collapsed row that reads as "add didn't work".
    @Test("MOD-13: a node appearing on a later poll is auto-expanded, and a collapse survives")
    func addedNodeAutoExpands() async throws {
        let client = FakeListing()
        let a = Self.node("u/a/haunted", online: true)
        let b = Self.node("u/b/haunted", online: true)
        // First cycle = two answers (follow-up pass); b appears after that.
        client.nodeResults = [.success([a]), .success([a]), .success([a, b])]
        client.sessionsByTarget = ["u/a/haunted": [], "u/b/haunted": []]
        let model = makeModel(client, pollInterval: 0.05, refreshDelay: 3600)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        model.toggle(a) // the user collapses the one host they can see
        try #require(!model.expanded.contains("u/a/haunted"))

        try await waitUntil({ model.nodes.contains { $0.id == "u/b/haunted" } },
                            "b appears on a later poll")

        #expect(model.expanded.contains("u/b/haunted"),
                "the newly-added host is expanded so its sessions show")
        #expect(!model.expanded.contains("u/a/haunted"),
                "and the user's collapse of the existing host survives")
    }

    // MARK: MOD-15 — the This-computer group's local tabs

    /// A mutable stand-in for the manager's registry, plus anchor objects for
    /// the ObjectIdentifier-based ids.
    final class LocalTabsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _tabs: [HauntedLocalTab] = []
        var tabs: [HauntedLocalTab] {
            get { lock.lock(); defer { lock.unlock() }; return _tabs }
            set { lock.lock(); _tabs = newValue; lock.unlock() }
        }
    }

    @Test("MOD-15: localTabs come from the injected provider, on poll and on the change notification")
    func localTabsRefresh() async throws {
        let anchor1 = NSObject()
        let anchor2 = NSObject()
        let box = LocalTabsBox()
        box.tabs = [HauntedLocalTab(id: ObjectIdentifier(anchor1), title: "zsh")]

        let client = FakeListing()
        client.nodeResults = [.success([])]
        let model = makeModel(client, localTabsProvider: { box.tabs })
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        #expect(model.localTabs == box.tabs, "the first poll populates the local tabs")

        // A new local tab appears (openLocalTab posts the change
        // notification): the debounced refresh picks it up without a poll.
        box.tabs = [
            HauntedLocalTab(id: ObjectIdentifier(anchor1), title: "zsh"),
            HauntedLocalTab(id: ObjectIdentifier(anchor2), title: "vim"),
        ]
        NotificationCenter.default.post(name: .hauntedSessionsDidChange, object: nil)
        try await waitUntil({ model.localTabs.count == 2 }, "the refresh lands")
        #expect(model.localTabs == box.tabs)
    }

    // MARK: MOD-16/17/18 — poll efficiency

    /// The poll's `live` argument is exactly the expanded online set: a
    /// collapsed group renders nothing, so fetching its titles is waste (its
    /// row still rides the ONE multiplexed call, summaries included). Expand
    /// fetches on the spot; collapse stops the live queries.
    @Test("MOD-16: live queries exactly the expanded set; expanding fetches immediately")
    func expandedOnlyQuerying() async throws {
        let client = FakeListing()
        let ws = Self.node("a/x/haunted", online: true)
        client.nodeResults = [.success([ws])]
        client.sessionsByTarget = ["a/x/haunted": [Self.session("one")]]
        let model = makeModel(client, refreshDelay: 3600) // notification cross-talk isolation
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        try #require(model.expanded.contains("a/x/haunted"), "online host auto-expands")
        #expect(client.liveArgs.last == ["a/x/haunted"],
                "the auto-expanded node is queried live on load")
        let afterLoad = client.liveRequests.count

        // Collapse → the next refresh still runs, but queries nothing live.
        model.toggle(ws)
        try #require(!model.expanded.contains("a/x/haunted"))
        await model.refreshSessions()
        #expect(client.liveArgs.last == [],
                "a collapsed node is not queried live")
        #expect(client.liveRequests.count == afterLoad)

        // Re-expand → fetched at once, not left to the next poll.
        model.toggle(ws)
        try await waitUntil({ client.liveRequests.count > afterLoad },
                            "expanding fetches sessions immediately")
        #expect(client.liveArgs.last == ["a/x/haunted"])
    }

    /// An inactive app polls on the slow interval — the node list is
    /// not re-fetched on the active cadence while nobody is watching.
    @Test("MOD-17: an inactive app backs off to the slow poll interval")
    func inactiveBackoff() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([])]
        let model = HauntedSidebarModel(
            client: client,
            killSession: { _, _, _ in },
            closeNode: { _ in },
            pollInterval: 0.05,
            inactivePollInterval: 3600,
            isAppActive: { false },
            refreshDelay: 3600) // notification cross-talk isolation
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded }, "the first poll completes")
        let after = client.listCalls
        // 6× the active interval: an active app would have re-polled several
        // times; an inactive one is asleep on the 3600s interval.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.listCalls == after,
                "an inactive app does not re-poll on the active interval")
    }

    /// The poll loop and the change notification both call refreshSessions;
    /// a request arriving mid-run coalesces into a single re-run rather than
    /// launching a concurrent second round of subprocesses.
    @Test("MOD-18: overlapping refreshes coalesce into one re-run")
    func refreshCoalesces() async throws {
        let client = FakeListing()
        let ws = Self.node("a/x/haunted", online: true)
        client.nodeResults = [.success([ws])]
        client.sessionsByTarget = ["a/x/haunted": [Self.session("one")]]
        let model = makeModel(client, refreshDelay: 3600) // notification cross-talk isolation
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        let base = client.listCalls

        // Hold the next refresh in list(), then fire it.
        client.listHold = true
        Task { await model.refreshSessions() }
        try await waitUntil({ client.listCalls == base + 1 },
                            "a refresh entered list() and is held")

        // Two more requests while one is in flight: no concurrent extra round.
        Task { await model.refreshSessions() }
        Task { await model.refreshSessions() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(client.listCalls == base + 1,
                "no concurrent round is launched while a refresh runs")

        // Releasing runs exactly one coalesced re-run.
        client.listHold = false
        try await waitUntil({ client.listCalls == base + 2 },
                            "the pending requests collapse into one re-run")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(client.listCalls == base + 2, "no further rounds")
    }

    // MARK: MOD-19 — console snapshot summaries seed unloaded rows

    /// A row whose live list has never loaded (here: its daemon wedged, so
    /// every live query fails) still shows the console's snapshot summaries —
    /// an instant title-less list instead of a blank group.
    @Test("MOD-19: summaries seed a row whose live list never loaded")
    func summariesSeedUnloadedRows() async throws {
        let client = FakeListing()
        client.nodeResults = [.success([Self.node("a/b/haunted", online: true)])]
        client.summariesByTarget = ["a/b/haunted": [Self.session("main")]]
        // No sessionsByTarget entry: every live query answers liveError.
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })
        #expect(model.sessionsByTarget["a/b/haunted"]?.map(\.name) == ["main"],
                "the snapshot summary shows despite the live failure")
    }

    /// Once a row has a live (titled) list, a later pass that did not query
    /// it must NOT downgrade it to the title-less summaries.
    @Test("MOD-19: summaries never overwrite an already-loaded live list")
    func summariesDoNotOverwriteLive() async throws {
        let client = FakeListing()
        let ws = Self.node("a/b/haunted", online: true)
        client.nodeResults = [.success([ws])]
        client.sessionsByTarget = ["a/b/haunted": [
            HauntedNodeSession(
                name: "work", pid: 1, clients: 0, cols: 80, rows: 24,
                created: 0, title: "vim"),
        ]]
        client.summariesByTarget = ["a/b/haunted": [Self.session("work")]] // no title
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.sessionsByTarget["a/b/haunted"]?.first?.title == "vim" })

        // Collapse: the row leaves the live set; its next listing carries
        // only summaries. The titled list must survive for the re-expand.
        model.toggle(ws)
        await model.refreshSessions()
        #expect(model.sessionsByTarget["a/b/haunted"]?.first?.title == "vim",
                "a collapsed row keeps its titled list; summaries only seed")
    }

    // MARK: MOD-20 — legacy dedmeshctl fallback

    /// The runner behind an old dedmeshctl: `-sessions` fails with Go's
    /// flag-parse error; the plain list and per-target `haunted list` answer.
    private func legacyRunner() -> FakeProcessRunner {
        FakeProcessRunner(runHandler: { command in
            if command.contains(" -sessions ") {
                throw HauntedCLIError(
                    message: "flag provided but not defined: -sessions")
            }
            if command.contains(" haunted -json ") {
                return Data(#"""
                [{"target":"a/b/haunted","daemon":"b","app":"haunted","online":true,"state":"active"}]
                """#.utf8)
            }
            if command.contains(" list --json ") {
                return Data(#"[{"name":"work","pid":1,"clients":0,"cols":80,"rows":24,"created":0}]"#.utf8)
            }
            throw HauntedCLIError(message: "unexpected command: \(command)")
        })
    }

    @Test("MOD-20: an old dedmeshctl latches the legacy 1+N fallback")
    func legacyFallbackLatches() async throws {
        let runner = legacyRunner()
        let listing = HauntedCLISessionListing(runner: runner, fs: HauntedTempFileSystem())

        let rows = try await listing.list(identity: Self.identity, live: ["a/b/haunted"])
        #expect(rows.count == 1)
        #expect(rows[0].node.target == "a/b/haunted")
        #expect(rows[0].live?.map(\.name) == ["work"],
                "the legacy path still delivers live sessions")
        #expect(listing.legacyCLI, "the failed probe latched")

        _ = try await listing.list(identity: Self.identity, live: ["a/b/haunted"])
        let probes = runner.invocations.filter {
            $0.command?.contains(" -sessions ") == true
        }
        #expect(probes.count == 1,
                "the -sessions probe is paid once, not once per poll")
    }

    @Test("MOD-20: a NON-flag error does not latch the legacy path")
    func ordinaryErrorDoesNotLatch() async throws {
        let runner = FakeProcessRunner(runHandler: { _ in
            throw HauntedCLIError(message: "mesh down")
        })
        let listing = HauntedCLISessionListing(runner: runner, fs: HauntedTempFileSystem())

        await #expect(throws: (any Error).self) {
            _ = try await listing.list(identity: Self.identity, live: [])
        }
        #expect(!listing.legacyCLI, "a transient failure must not demote the CLI")
    }

    @Test("MOD-20: isLegacyFlagError matches Go's flag error, loosely")
    func legacyFlagErrorMatching() {
        #expect(HauntedCLISessionListing.isLegacyFlagError(
            "flag provided but not defined: -sessions"))
        #expect(HauntedCLISessionListing.isLegacyFlagError(
            "dedmeshctl: Flag Provided But Not Defined: -live\nusage: ..."))
        #expect(!HauntedCLISessionListing.isLegacyFlagError("mesh down"))
        #expect(!HauntedCLISessionListing.isLegacyFlagError("connection refused"))
    }
}
