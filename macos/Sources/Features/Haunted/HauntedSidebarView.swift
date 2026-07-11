import AppKit
import SwiftUI

/// What the sidebar model reads from — and writes to — the mesh. A seam, so
/// the poll loop can be driven without spawning `dedmeshctl`/`haunted` (§5.4).
protocol HauntedSessionListing: Sendable {
    /// One poll: every reachable workstation (console session summaries
    /// included) plus fresh titled session lists for the `live` targets.
    /// Empty `live` fetches the list alone. ONE Console mTLS session however
    /// many targets are queried — the whole point (performance.md item 1).
    func list(
        identity: HauntedClientIdentity, live: [String]
    ) async throws -> [HauntedWorkstationListing]
    /// Persists a workstation daemon's display color on the console
    /// (nil = back to the default).
    func setWorkstationColor(
        identity: HauntedClientIdentity, daemon: String, color: String?
    ) async throws
}

/// The real one: the CLIs own all mesh transport and mTLS state.
///
/// A class, not a struct, for the legacy latch: an old `dedmeshctl` on PATH
/// predates `-sessions`, fails the first multiplexed call with Go's
/// flag-parse error, and this listing then falls back — once, latched — to
/// today's 1 + N shape (plain list + one `haunted list` per live target)
/// instead of paying a doomed probe every 4s.
final class HauntedCLISessionListing: HauntedSessionListing, @unchecked Sendable {
    private let runner: HauntedProcessRunning
    private let fs: HauntedFileSystem
    private let lock = NSLock()
    private var _legacyCLI = false

    init(
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) {
        self.runner = runner
        self.fs = fs
    }

    /// Whether the installed dedmeshctl was seen rejecting `-sessions`.
    var legacyCLI: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _legacyCLI }
        set { lock.lock(); _legacyCLI = newValue; lock.unlock() }
    }

    /// Go's flag package explains an unknown flag with exactly this phrase on
    /// stderr, which `run` surfaces as the error message. Loose, substring,
    /// case-insensitive: cosmetic coupling whose worst failure mode is
    /// staying on the legacy path.
    static func isLegacyFlagError(_ message: String) -> Bool {
        message.lowercased().contains("flag provided but not defined")
    }

    func list(
        identity: HauntedClientIdentity, live: [String]
    ) async throws -> [HauntedWorkstationListing] {
        if !legacyCLI {
            do {
                return try await HauntedCLI.workstationSessions(
                    identity: identity, live: live, runner: runner, fs: fs)
            } catch let error as HauntedCLIError
                where Self.isLegacyFlagError(error.message) {
                legacyCLI = true // probed once; never retried this launch
            }
        }
        return try await legacyList(identity: identity, live: live)
    }

    /// The pre-`-sessions` shape: one Console session for the list, one per
    /// live target for its sessions. No summaries (old CLIs don't emit them).
    private func legacyList(
        identity: HauntedClientIdentity, live: [String]
    ) async throws -> [HauntedWorkstationListing] {
        let workstations = try await HauntedCLI.workstations(
            identity: identity, runner: runner, fs: fs)
        let wanted = Set(live)
        var out: [HauntedWorkstationListing] = []
        for workstation in workstations {
            var liveSessions: [HauntedWorkstationSession]?
            var liveError: String?
            if workstation.online, wanted.contains(workstation.target) {
                do {
                    liveSessions = try await HauntedCLI.sessions(
                        identity: identity, target: workstation.target,
                        runner: runner, fs: fs)
                } catch {
                    liveError = error.localizedDescription
                }
            }
            out.append(HauntedWorkstationListing(
                workstation: workstation, live: liveSessions, liveError: liveError))
        }
        return out
    }

    func setWorkstationColor(
        identity: HauntedClientIdentity, daemon: String, color: String?
    ) async throws {
        try await HauntedCLI.setWorkstationColor(
            identity: identity, daemon: daemon, color: color,
            runner: runner, fs: fs)
    }
}

/// The color choices offered on a workstation row, plus "Default". A fixed
/// palette rather than a color picker: eight distinguishable hues that read at
/// sidebar-text size, whose values are exactly what the console stores.
enum HauntedWorkstationPalette {
    struct Preset: Identifiable, Equatable {
        let name: String
        let hex: String // "#rrggbb", lowercase — the stored form
        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "Red", hex: "#e5484d"),
        Preset(name: "Orange", hex: "#f76b15"),
        Preset(name: "Amber", hex: "#ffc53d"),
        Preset(name: "Green", hex: "#30a46c"),
        Preset(name: "Teal", hex: "#12a594"),
        Preset(name: "Blue", hex: "#0090ff"),
        Preset(name: "Purple", hex: "#8e4ec6"),
        Preset(name: "Pink", hex: "#d6409f"),
    ]

    /// Parses an already-normalized "#rrggbb" into 0…1 components. Pure, so
    /// the mapping is testable without SwiftUI. Nil for anything that is not
    /// exactly that shape (the decode boundary should have caught it, but the
    /// renderer must not trust that).
    static func hexToRGB(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard HauntedWorkstation.normalizedColor(hex) == hex else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

/// One open LOCAL terminal tab, as the sidebar's "This computer" group lists
/// them. The id is the hosting tab controller's identity — stable for the
/// tab's life, and what focusing resolves by.
struct HauntedLocalTab: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
}

/// One sidebar row after joining the console's workstation list with the
/// host's local Lima VMs: console-only (a remote workstation, or an orphan a
/// failed revoke left behind), Lima-only (a VM that has not enrolled/come
/// online yet), or both (a GUI-managed workstation).
struct HauntedSidebarRow: Identifiable, Equatable {
    let workstation: HauntedWorkstation?
    let lima: HauntedLimaInstance?
    let op: HauntedLimaModel.Op?

    /// True when the console row belongs to the signed-in user (always true
    /// for Lima-only rows: local VMs are ours by definition). Gates every
    /// Lima affordance on console rows.
    let owned: Bool

    /// What the sidebar shows and what keys the Lima ops: the console daemon
    /// name with the caller's own "<username>-" prefix stripped — which is
    /// also the local VM name. Console names stay prefixed (collision-free
    /// across accounts); Haunted displays the bare name.
    let displayName: String

    var id: String { workstation?.id ?? "lima:\(lima?.name ?? "")" }
}

/// The Lima operations a sidebar row can request; the view dispatches them to
/// HauntedLimaModel (with an NSAlert in front of the destructive ones).
enum HauntedLimaAction {
    case start
    case stop
    case enroll
    case delete
    case revokeConsole
    case dismissError
}

enum HauntedSidebarMerge {
    /// Joins console workstations with local Lima VMs by daemon name — but
    /// only for rows the caller's own username owns: a local VM named like
    /// ANOTHER user's daemon (targets can be shared in a picker some day)
    /// must never merge, or its menu would offer to delete someone else's
    /// machine. `username` comes from the client certificate CN; nil (an
    /// unreadable cert) merges nothing.
    static func mergeRows(
        workstations: [HauntedWorkstation],
        lima: [HauntedLimaInstance],
        ops: [String: HauntedLimaModel.Op],
        username: String?
    ) -> [HauntedSidebarRow] {
        var rows: [HauntedSidebarRow] = []
        var claimed = Set<String>()
        for workstation in workstations {
            let owned = username.map { workstation.target.hasPrefix($0 + "/") } ?? false
            // Console daemon names carry the "<username>-" prefix; the local
            // VM (and the display) use the bare name — join on that.
            let display = owned
                ? workstationDisplayName(daemon: workstation.daemon, username: username)
                : workstation.daemon
            let vm = owned ? lima.first { $0.name == display } : nil
            if let vm { claimed.insert(vm.name) }
            // Ops key by VM/display name; an unowned row must not pick up an
            // op that belongs to a same-named LOCAL VM (its own separate row).
            rows.append(HauntedSidebarRow(
                workstation: workstation, lima: vm,
                op: owned ? ops[display] : nil, owned: owned,
                displayName: display))
        }
        for vm in lima where !claimed.contains(vm.name) {
            rows.append(HauntedSidebarRow(
                workstation: nil, lima: vm, op: ops[vm.name], owned: true,
                displayName: vm.name))
        }
        return rows.sorted { $0.displayName < $1.displayName }
    }
}

/// Shared state behind every sidebar instance. Each tab's window hosts its
/// own HauntedSidebarView, but they all render THIS one model: tab switches
/// show identical, already-loaded data (no flicker, no reload), and the
/// single poll loop lives here — owned by the app, not by any view — so
/// SwiftUI cancelling a hidden tab's `.task` can neither kill polling nor
/// reset the data. Expansion state is shared too: the sidebar reads as one
/// persistent surface that every tab happens to show.
@MainActor
final class HauntedSidebarModel: ObservableObject {
    static let shared = HauntedSidebarModel(
        // Lima VM state rides the same 4s cadence as the workstation list —
        // one poll loop for the whole sidebar. Only the production singleton
        // hooks it up: the default (nil) keeps tests hermetic, since
        // HauntedLimaModel.shared would probe the real filesystem for limactl.
        isAppActive: { NSApplication.shared.isActive },
        wakesOnAppActivation: true,
        limaRefresh: { await HauntedLimaModel.shared.refresh() },
        localTabsProvider: { HauntedManager.shared.localTabs() })

    @Published var workstations: [HauntedWorkstation] = []
    @Published var sessionsByTarget: [String: [HauntedWorkstationSession]] = [:]
    @Published var expanded: Set<String> = []
    @Published var errorMessage: String?
    @Published var loaded = false
    /// The open local terminal tabs ("This computer"), refreshed on the same
    /// poll (and change notification) as everything else.
    @Published var localTabs: [HauntedLocalTab] = []
    /// Whether the "This computer" group shows its tabs. Separate from
    /// `expanded` (workstation ids) so reconcile() never touches it.
    @Published var localExpanded = true

    private let client: HauntedSessionListing
    /// Killing a session closes its tab, which only `HauntedManager` can do.
    /// Injected so a test can observe the request without a window.
    private let killSession: @MainActor (HauntedClientIdentity, String, String) -> Void
    /// Closing every tab of a removed workstation is likewise `HauntedManager`'s
    /// job; injected so the removal reconciliation is observable without windows.
    private let closeWorkstation: @MainActor (String) -> Void
    /// The poll cadence while the app is active. Each cycle costs ONE Console
    /// mTLS session — a single multiplexed `dedmeshctl workstations -sessions`
    /// carrying the host list plus live session lists for the expanded rows
    /// (see refreshSessions).
    private let pollInterval: TimeInterval
    /// The (slower) cadence while the app is inactive or occluded: nobody is
    /// watching the sidebar, so trade latency for a fraction of the mesh
    /// traffic. Reactivation wakes the loop immediately, so the slow interval
    /// never delays what the user sees on return.
    private let inactivePollInterval: TimeInterval
    /// Whether the app is frontmost/visible; drives which interval a cycle
    /// sleeps. Injected so tests stay hermetic (default: always active).
    private let isAppActive: @MainActor () -> Bool
    /// Attach/kill take a moment to land daemon-side, so the change
    /// notification refreshes after a beat rather than racing the daemon.
    private let refreshDelay: TimeInterval
    /// Piggybacks the Lima manager's refresh on this model's poll loop
    /// (nil = no Lima integration; see `shared`).
    private let limaRefresh: (@MainActor () async -> Void)?
    /// Source of the open local tabs (the manager's registry in production;
    /// injected so tests stay hermetic).
    private let localTabsProvider: @MainActor () -> [HauntedLocalTab]

    private var identity: HauntedClientIdentity?
    private var pollTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private var activeObserver: (any NSObjectProtocol)?
    /// refreshSessions coalescing: a request arriving while one runs sets
    /// `refreshPending` instead of launching a second round of subprocesses;
    /// the in-flight pass re-runs once at the end. Both are main-actor state.
    private var refreshing = false
    private var refreshPending = false

    init(
        client: HauntedSessionListing = HauntedCLISessionListing(),
        killSession: @escaping @MainActor (HauntedClientIdentity, String, String) -> Void = {
            HauntedManager.shared.killSession(
                identity: $0, target: $1, sessionName: $2)
        },
        closeWorkstation: @escaping @MainActor (String) -> Void = {
            HauntedManager.shared.closeTabs(forTarget: $0)
        },
        pollInterval: TimeInterval = 4,
        inactivePollInterval: TimeInterval = 30,
        isAppActive: @escaping @MainActor () -> Bool = { true },
        // Wake the poll on NSApplication reactivation. Off by default so test
        // models never react to the host app's own activation events.
        wakesOnAppActivation: Bool = false,
        refreshDelay: TimeInterval = 1.2,
        limaRefresh: (@MainActor () async -> Void)? = nil,
        localTabsProvider: @escaping @MainActor () -> [HauntedLocalTab] = { [] }
    ) {
        self.client = client
        self.killSession = killSession
        self.closeWorkstation = closeWorkstation
        self.pollInterval = pollInterval
        self.inactivePollInterval = inactivePollInterval
        self.isAppActive = isAppActive
        self.refreshDelay = refreshDelay
        self.limaRefresh = limaRefresh
        self.localTabsProvider = localTabsProvider
        observer = NotificationCenter.default.addObserver(
            forName: .hauntedSessionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.refreshDelay * 1_000_000_000))
                await self.refreshSessions()
            }
        }
        // Coming back to the app must not wait out the slow inactive interval:
        // restart the poll for an immediate fresh cycle.
        if wakesOnAppActivation {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.restartPoll() }
            }
        }
    }

    deinit {
        // Block-based observers outlive their target; without this a test's
        // model keeps answering notifications meant for the next one.
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        pollTask?.cancel()
    }

    /// Idempotent: the first sidebar starts the poll loop, later ones just
    /// render. A changed identity (re-login) restarts it.
    ///
    /// A *cancelled* poll task counts as no poll task — `pollTask` stays
    /// non-nil after cancellation, so testing it alone would refuse to ever
    /// resume polling.
    func start(identity: HauntedClientIdentity) {
        if self.identity == identity, let pollTask, !pollTask.isCancelled { return }
        self.identity = identity
        pollTask?.cancel()
        loaded = false
        pollTask = Task { [weak self] in await self?.poll() }
    }

    /// Stops the poll loop without discarding what it last saw.
    func stop() {
        pollTask?.cancel()
    }

    /// Restarts the poll for an immediate cycle without discarding data (used
    /// when the app reactivates so a slow inactive sleep doesn't delay the
    /// refresh). A no-op until the first `start` has set an identity.
    private func restartPoll() {
        guard identity != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.poll() }
    }

    func toggle(_ workstation: HauntedWorkstation) {
        if expanded.contains(workstation.id) {
            expanded.remove(workstation.id)
        } else {
            expanded.insert(workstation.id)
            // Expanding reveals a workstation whose sessions may be stale (it
            // was skipped while collapsed) — fetch them now rather than
            // leaving the empty list until the next poll.
            Task { [weak self] in await self?.refreshSessions() }
        }
    }

    func kill(workstation: HauntedWorkstation, session sessionName: String) {
        guard let identity else { return }
        // Optimistically drop it from the list; the change notification's
        // refresh reconciles.
        sessionsByTarget[workstation.id]?.removeAll { $0.name == sessionName }
        killSession(identity, workstation.target, sessionName)
    }

    /// Sets (nil clears) a workstation's display color: an optimistic local
    /// recolor — of every row on that daemon, since the color is per-daemon
    /// console state — then the console write. On failure the error surfaces
    /// in the sidebar and the next poll reverts the tint to the stored truth;
    /// on success the next poll simply confirms what is already shown.
    func setColor(workstation: HauntedWorkstation, color: String?) {
        guard let identity else { return }
        workstations = workstations.map {
            $0.daemon == workstation.daemon ? $0.withColor(color) : $0
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.setWorkstationColor(
                    identity: identity, daemon: workstation.daemon, color: color)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Absorb a topology change between two successful polls: hosts the console
    /// added since `previous`, and hosts it removed. Runs only inside the poll's
    /// success path, so a transient CLI failure (which leaves `workstations`
    /// untouched) can never be mistaken for every host being removed.
    ///
    /// - Removed hosts: close their open tabs (the daemon is gone; a tab left
    ///   attached only reconnect-loops and then strands a dead banner) and drop
    ///   their now-unreachable sessions and expansion state.
    /// - Newly-appeared online hosts: expand them so their sessions are visible.
    ///   Only the new ones — re-deriving expansion for hosts already present
    ///   would reopen whatever the user just collapsed (MOD-06). On the first
    ///   poll `previous` is empty, so this expands every online host, which is
    ///   the first-load behavior (MOD-05).
    private func reconcile(previous: [HauntedWorkstation], fresh: [HauntedWorkstation]) {
        let previousIDs = Set(previous.map { $0.id })
        let freshIDs = Set(fresh.map { $0.id })

        for removed in previousIDs.subtracting(freshIDs) {
            sessionsByTarget[removed] = nil
            expanded.remove(removed)
            // `id` is the target ("user/daemon/app"); closeWorkstation takes the
            // target. They are the same string here, but resolve it explicitly.
            if let target = previous.first(where: { $0.id == removed })?.target {
                closeWorkstation(target)
            }
        }

        for workstation in fresh
        where workstation.online && !previousIDs.contains(workstation.id) {
            expanded.insert(workstation.id)
        }
    }

    /// Retitles one session's row from a locally-observed title change (the
    /// daemon pushes titles to attached clients instantly, so a session open
    /// in this app never has to wait for the next list poll to catch up with
    /// its own tab). A session the model has not seen yet is skipped — the
    /// row itself arrives via refresh, title included.
    func applyLocalTitle(target: String, sessionName: String, title: String) {
        guard var sessions = sessionsByTarget[target],
              let index = sessions.firstIndex(where: { $0.name == sessionName }),
              sessions[index].title != title else { return }
        let old = sessions[index]
        sessions[index] = HauntedWorkstationSession(
            name: old.name, pid: old.pid, clients: old.clients,
            cols: old.cols, rows: old.rows, created: old.created, title: title)
        sessionsByTarget[target] = sessions
    }

    /// One refresh cycle: a SINGLE `client.list` call carries the workstation
    /// list (summaries included) and the live titled session lists for every
    /// EXPANDED online workstation — one Console mTLS session per cycle,
    /// however many rows are open (performance.md item 1; the old shape was
    /// 1 + N sessions). Rules:
    ///
    ///  - **Only EXPANDED online workstations are queried live.** A collapsed
    ///    group renders no sessions, so fetching its titles is pure waste; it
    ///    seeds from the console's snapshot summaries instead, so expanding
    ///    shows an instant (title-less) list while the on-expand refresh
    ///    fetches titles.
    ///  - **Overlapping calls coalesce.** The poll loop and the change
    ///    notification both call this; a request arriving mid-run sets a
    ///    pending flag and the in-flight pass re-runs once, rather than firing
    ///    a second concurrent subprocess.
    ///  - **One workstation's live failure must not blank the others**: its
    ///    row keeps the sessions it last showed (`liveError` rows), and a
    ///    whole-call failure keeps everything (no flash-to-empty).
    func refreshSessions() async {
        localTabs = localTabsProvider()
        guard let identity else { return }
        if refreshing {
            refreshPending = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshPending = false
            let requested = workstations
                .filter { $0.online && expanded.contains($0.id) }
                .map(\.target)
            do {
                let listings = try await client.list(identity: identity, live: requested)
                errorMessage = nil
                apply(listings: listings, requested: Set(requested))
            } catch {
                // Keep the last-known workstations: a transient CLI failure
                // must not flash the sidebar to empty.
                errorMessage = error.localizedDescription
            }
        } while refreshPending
    }

    /// Folds one poll answer into the model: the host list (+ reconcile), then
    /// per-row sessions — fresh titled `live` when queried, untouched on a
    /// per-row `liveError` (a mesh blip must not blank a list the user is
    /// looking at), seeded from the snapshot summaries when never loaded.
    private func apply(listings: [HauntedWorkstationListing], requested: Set<String>) {
        let fresh = listings.map(\.workstation)
        let previous = workstations
        workstations = fresh.sorted { $0.target < $1.target }
        reconcile(previous: previous, fresh: fresh)

        for listing in listings {
            let id = listing.workstation.id
            if let live = listing.live {
                sessionsByTarget[id] = live.sorted { $0.name < $1.name }
            } else if listing.liveError == nil, sessionsByTarget[id] == nil {
                sessionsByTarget[id] = listing.sessions.sorted { $0.name < $1.name }
            }
        }

        // reconcile may have auto-expanded hosts this pass did not query live
        // (the first load, or a host that just appeared): run a follow-up pass
        // so their titles arrive now, not at the next interval. Terminates:
        // the re-run requests exactly the expanded set, after which nothing
        // is missing.
        let missing = workstations.contains {
            $0.online && expanded.contains($0.id) && !requested.contains($0.target)
        }
        if missing { refreshPending = true }
    }

    private func poll() async {
        while !Task.isCancelled {
            guard identity != nil else { return }
            await limaRefresh?()
            await refreshSessions()
            loaded = true
            // Nobody watching → poll far less often (reactivation restarts the
            // loop, so the slow interval never delays what the user sees).
            let interval = isAppActive() ? pollInterval : inactivePollInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

/// Workstation sidebar shown in Haunted-connected terminal windows. Each
/// workstation the enrolled client may reach is a group; under it are the
/// sessions currently running on that workstation's Haunted daemon, plus a
/// "new session" action. Clicking an online workstation's name attaches to
/// its persistent "default" session (creating it on first use); the chevron
/// expands the session list. Rows for sessions already open in this app are
/// highlighted. Purely a renderer over HauntedSidebarModel.shared.
struct HauntedSidebarView: View {
    let identity: HauntedClientIdentity
    /// (workstation, sessionName?) — nil sessionName means "create a new session".
    let onOpen: (HauntedWorkstation, String?) -> Void
    /// "This computer": open a plain local terminal on this Mac.
    let onOpenLocal: () -> Void
    /// Focus an already-open local tab (a "This computer" child row).
    let onFocusLocalTab: (ObjectIdentifier) -> Void
    /// The (target, session) of the tab hosting THIS sidebar — the row the
    /// sidebar highlights as current. Re-evaluated on every render, so an
    /// empty-state window that attaches in place starts highlighting without
    /// a new sidebar.
    let currentSession: @MainActor () -> (target: String, name: String)?
    /// The hosting tab's identity, to highlight it under "This computer"
    /// when the host tab is itself a local terminal.
    let hostTabID: ObjectIdentifier?

    @ObservedObject private var model = HauntedSidebarModel.shared
    @ObservedObject private var layout = HauntedSidebarLayout.shared
    @ObservedObject private var limaModel = HauntedLimaModel.shared
    @State private var showCreateSheet = false

    /// The signed-in username (certificate CN) — the merge's cross-user guard
    /// and the display-name prefix stripper.
    private var username: String? { identity.username }

    private var mergedRows: [HauntedSidebarRow] {
        HauntedSidebarMerge.mergeRows(
            workstations: model.workstations,
            lima: limaModel.available ? limaModel.instances : [],
            ops: limaModel.ops,
            username: username)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full content is always laid out; only its opacity animates, so
            // the fade never fights the width animation (which is AppKit's).
            fullSidebar
                .opacity(layout.contentVisible ? 1 : 0)
                .allowsHitTesting(layout.contentVisible)
                .animation(.easeInOut(duration: HauntedSidebarLayout.animationDuration),
                           value: layout.contentVisible)

            // The show button belongs to the collapsed strip; it's visible
            // only once the sidebar has actually narrowed (collapsed) and the
            // content has faded out.
            if layout.collapsed && !layout.contentVisible {
                collapsedStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.start(identity: identity) }
    }

    /// The hidden state: a thin icon-only strip whose single button brings
    /// the sidebar back.
    private var collapsedStrip: some View {
        VStack {
            Button {
                layout.setCollapsed(false)
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show workstations")
            .padding(.top, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var fullSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Haunted")
                            .font(.headline)
                        HauntedAlphaBadge()
                    }
                    Text(identity.consoleHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let who = identity.certIdentity {
                        Text("@" + who)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help("Enrolled client identity (certificate CN)")
                    }
                }
                Spacer(minLength: 0)
                Button {
                    layout.setCollapsed(true)
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide workstations (drag the divider to resize)")
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)

            Divider()

            if model.loaded && model.workstations.isEmpty && model.errorMessage == nil {
                Text("No workstations")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Always first and always available: a regular terminal on
                    // this Mac, exactly upstream Ghostty's default surface —
                    // rendered like the workstations: expandable, its open
                    // tabs listed, plus a "New session" action.
                    LocalComputerGroup(
                        tabs: model.localTabs,
                        isExpanded: model.localExpanded,
                        hostTabID: hostTabID,
                        toggle: { model.localExpanded.toggle() },
                        onOpen: onOpenLocal,
                        onFocusTab: onFocusLocalTab)

                    ForEach(mergedRows) { row in
                        if let workstation = row.workstation {
                            WorkstationGroup(
                                workstation: workstation,
                                displayName: row.displayName,
                                sessions: model.sessionsByTarget[workstation.id] ?? [],
                                isExpanded: model.expanded.contains(workstation.id),
                                currentSessionName: currentSession().flatMap {
                                    $0.target == workstation.target ? $0.name : nil
                                },
                                lima: row.lima,
                                limaOp: row.op,
                                // A console row with no local VM offers the
                                // manual revoke only when it is ours and the
                                // manager exists at all (the orphan a failed
                                // delete-revoke leaves behind).
                                offersConsoleRevoke: row.owned && row.lima == nil
                                    && limaModel.available,
                                toggle: { model.toggle(workstation) },
                                onOpenPrimary: {
                                    model.expanded.insert(workstation.id)
                                    onOpen(workstation, "default")
                                },
                                onOpenSession: { onOpen(workstation, $0) },
                                onNewSession: { onOpen(workstation, nil) },
                                onKillSession: {
                                    model.kill(workstation: workstation, session: $0)
                                },
                                onSetColor: {
                                    model.setColor(workstation: workstation, color: $0)
                                },
                                onLimaAction: { handleLima($0, row: row) })
                        } else if let vm = row.lima {
                            LimaVMRow(
                                vm: vm, op: row.op,
                                onAction: { handleLima($0, row: row) })
                        }
                    }

                    if limaModel.available {
                        Button {
                            showCreateSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.caption)
                                Text("New workstation…")
                                    .font(.callout)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .help("Create a Lima VM and enroll it as a workstation")
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            if let warning = limaModel.warningMessage {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            LimaCreateSheet(
                // Uniqueness is checked against the BARE names the sheet
                // deals in: local VM names plus console daemons with the
                // user's prefix stripped.
                existingNames: Set(limaModel.instances.map(\.name))
                    .union(model.workstations.map {
                        workstationDisplayName(daemon: $0.daemon, username: username)
                    }),
                onCreate: { spec in
                    limaModel.createAndEnroll(spec: spec, identity: identity)
                })
        }
    }

    private func handleLima(_ action: HauntedLimaAction, row: HauntedSidebarRow) {
        // Lima ops key by the local VM / display name; the console revoke
        // needs the FULL stored daemon name from the console ref.
        let name = row.displayName
        switch action {
        case .start:
            limaModel.start(name: name)
        case .stop:
            limaModel.stop(name: name)
        case .enroll:
            limaModel.enroll(name: name, identity: identity)
        case .delete:
            confirm(
                "Delete workstation “\(name)”?",
                detail: "The Lima VM and its disk are destroyed and the "
                    + "workstation is removed from the Console. This cannot "
                    + "be undone.",
                button: "Delete"
            ) {
                limaModel.delete(name: name,
                                 consoleDaemon: row.workstation?.daemon,
                                 identity: identity)
            }
        case .revokeConsole:
            guard let daemon = row.workstation?.daemon else { return }
            confirm(
                "Remove “\(name)” from the Console?",
                detail: "The daemon and everything it published are deleted; "
                    + "its certificate stops working. There is no local VM to "
                    + "remove.",
                button: "Remove"
            ) {
                limaModel.revokeConsole(name: name, daemon: daemon, identity: identity)
            }
        case .dismissError:
            limaModel.clearFailure(name: name)
        }
    }

    /// The one NSAlert shape every destructive Lima action goes through.
    private func confirm(
        _ message: String, detail: String, button: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}

private struct WorkstationGroup: View {
    let workstation: HauntedWorkstation
    /// The name the row shows: the console daemon name with the user's own
    /// "<username>-" prefix stripped (console names stay prefixed).
    let displayName: String
    let sessions: [HauntedWorkstationSession]
    let isExpanded: Bool
    /// The session name the hosting tab is attached to on THIS workstation
    /// (nil when the host tab looks elsewhere) — the row highlighted as
    /// current, beyond the open-in-this-app accent.
    let currentSessionName: String?
    /// The local Lima VM backing this workstation (merged by name), if any.
    let lima: HauntedLimaInstance?
    let limaOp: HauntedLimaModel.Op?
    /// Console-only owned row: offer "Remove from Console…" (the orphan a
    /// failed delete-revoke leaves behind).
    let offersConsoleRevoke: Bool
    let toggle: () -> Void
    let onOpenPrimary: () -> Void
    let onOpenSession: (String) -> Void
    let onNewSession: () -> Void
    let onKillSession: (String) -> Void
    /// nil = back to the default color.
    let onSetColor: (String?) -> Void
    let onLimaAction: (HauntedLimaAction) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse sessions" : "Show sessions")
                .disabled(!workstation.online)

                Button(action: onOpenPrimary) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .foregroundStyle(nameColor)
                        if let limaOp, limaOp.isInFlight {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: 10, height: 10)
                            Text(limaOp.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if case .failed(let message) = limaOp {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .help(message)
                        } else if let lima, lima.isRunning, !workstation.online {
                            // The VM runs but its daemon has not come online
                            // (booting, or dedmeshd died inside): distinguish
                            // this from a plain offline host.
                            Text("Lima: Running")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(hovering && workstation.online
                                  ? Color.secondary.opacity(0.15) : Color.clear))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(workstation.online
                      ? "Open a terminal on \(displayName) (its persistent default session)"
                      : workstation.error ?? "\(workstation.target) (\(workstation.status))")
                .disabled(!workstation.online)
            }
            .opacity(workstation.online ? 1 : 0.5)
            .padding(.leading, 2)
            // Attached to the row, NOT inside the .disabled buttons: the color
            // is console state, so an offline workstation's row keeps its menu.
            .contextMenu {
                colorMenu
                limaMenu
            }

            if isExpanded && workstation.online {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isOpenHere: HauntedManager.shared.isSessionOpen(
                            target: workstation.target, sessionName: session.name),
                        isCurrent: session.name == currentSessionName,
                        action: { onOpenSession(session.name) },
                        onKill: { onKillSession(session.name) })
                }
                Button(action: onNewSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption2)
                        Text("New session")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.leading, 26)
                    .padding(.trailing, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The user-chosen color menu. Checkmark on the current choice; picking
    /// one recolors locally at once and persists via the model.
    @ViewBuilder private var colorMenu: some View {
        Menu("Color") {
            ForEach(HauntedWorkstationPalette.presets) { preset in
                Button {
                    onSetColor(preset.hex)
                } label: {
                    Text(workstation.color == preset.hex ? "✓ \(preset.name)" : preset.name)
                }
            }
            Divider()
            Button {
                onSetColor(nil)
            } label: {
                Text(workstation.color == nil ? "✓ Default" : "Default")
            }
        }
    }

    /// The Lima section of the row menu: VM lifecycle for merged rows, the
    /// orphan console revoke for console-only owned rows. Destructive and
    /// state-changing actions vanish while an op is in flight.
    @ViewBuilder private var limaMenu: some View {
        if let lima {
            Divider()
            if limaOp?.isInFlight != true {
                if lima.isRunning {
                    Button("Stop VM") { onLimaAction(.stop) }
                } else {
                    Button("Start VM") { onLimaAction(.start) }
                }
                Button("Delete Workstation…", role: .destructive) {
                    onLimaAction(.delete)
                }
            }
            if case .failed = limaOp {
                Button("Dismiss Error") { onLimaAction(.dismissError) }
            }
        } else if offersConsoleRevoke, limaOp?.isInFlight != true {
            Divider()
            Button("Remove from Console…", role: .destructive) {
                onLimaAction(.revokeConsole)
            }
        }
    }

    /// The workstation name's tint: the user-chosen color when set, else the
    /// default label color. The status dot keeps its online/error semantics —
    /// the color rides the NAME, never the dot.
    private var nameColor: Color {
        guard let hex = workstation.color,
              let rgb = HauntedWorkstationPalette.hexToRGB(hex) else { return .primary }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var statusColor: Color {
        if workstation.online {
            return .green
        }
        if workstation.state == "error" {
            return .red
        }
        return Color.secondary.opacity(0.4)
    }
}

private struct SessionRow: View {
    let session: HauntedWorkstationSession
    let isOpenHere: Bool
    /// The hosting tab shows exactly this session: render selected, matching
    /// the tab bar's own highlight.
    let isCurrent: Bool
    let action: () -> Void
    let onKill: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(isOpenHere ? Color.accentColor : Color.secondary)
                Text(session.displayTitle)
                    .fontWeight(isOpenHere ? .medium : .regular)
                    .lineLimit(1)
                if session.clients > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                Text("\(session.cols)×\(session.rows)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.leading, 26)
            .padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.22)
                        : hovering ? Color.secondary.opacity(0.15) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOpenHere
              ? "\(session.name) — open in this window; click to focus its tab"
              : session.clients > 0
                  ? "Reattach \(session.name) (moves it to this tab)"
                  : "Attach \(session.name) in a new tab")
        .contextMenu {
            Button("Attach in New Tab") { action() }
            Divider()
            Button("Kill Session", role: .destructive) { onKill() }
        }
    }
}

/// "This computer": a regular terminal on this Mac — upstream Ghostty's
/// default surface, no attach command, no mesh in the path. Rendered like a
/// workstation group: chevron, the open local tabs as child rows (the
/// hosting tab highlighted), and a "New session" action. Clicking the name
/// opens a new local terminal; clicking a child row focuses that tab.
private struct LocalComputerGroup: View {
    let tabs: [HauntedLocalTab]
    let isExpanded: Bool
    /// The hosting tab's identity: when it is one of `tabs`, that row renders
    /// selected — the sidebar mirror of the tab bar's highlight.
    let hostTabID: ObjectIdentifier?
    let toggle: () -> Void
    let onOpen: () -> Void
    let onFocusTab: (ObjectIdentifier) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse local tabs" : "Show local tabs")

                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("This computer")
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(hovering ? Color.secondary.opacity(0.15) : Color.clear))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Open a regular terminal on this Mac")
            }
            .padding(.leading, 2)

            if isExpanded {
                ForEach(tabs) { tab in
                    LocalTabRow(
                        tab: tab,
                        isCurrent: tab.id == hostTabID,
                        action: { onFocusTab(tab.id) })
                }
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption2)
                        Text("New session")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.leading, 26)
                    .padding(.trailing, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One open local terminal tab under "This computer".
private struct LocalTabRow: View {
    let tab: HauntedLocalTab
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                Text(tab.title)
                    .fontWeight(isCurrent ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.leading, 26)
            .padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.22)
                        : hovering ? Color.secondary.opacity(0.15) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isCurrent
              ? "\(tab.title) — this tab"
              : "Focus \(tab.title)")
    }
}

/// A Lima VM the console does not (yet) list as a workstation: created but
/// not enrolled, still booting, or enrolled under a name the console has
/// since revoked. Hollow dot — there is no daemon whose online/error state
/// the filled dot could report.
private struct LimaVMRow: View {
    let vm: HauntedLimaInstance
    let op: HauntedLimaModel.Op?
    let onAction: (HauntedLimaAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                .frame(width: 8, height: 8)
            Text(vm.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            if let op, op.isInFlight {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
                Text(op.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = op {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help(message)
            }
            Spacer(minLength: 0)
            Text(op?.isInFlight == true ? "" : vm.status)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.leading, 24)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .help("Lima VM \(vm.name) (\(vm.status)) — not a workstation yet")
        .contextMenu {
            if op?.isInFlight != true {
                if vm.isRunning {
                    Button("Stop VM") { onAction(.stop) }
                    Button("Enroll as Workstation") { onAction(.enroll) }
                } else {
                    Button("Start VM") { onAction(.start) }
                }
                Divider()
                Button("Delete VM…", role: .destructive) { onAction(.delete) }
            }
            if case .failed = op {
                Button("Dismiss Error") { onAction(.dismissError) }
            }
        }
    }
}

/// The "New workstation…" form: a name under the daemon grammar, explicitly
/// chosen exposed directories (none by default — a workstation exports a
/// shell over the mesh, so every mount is an explicit decision), and sizing.
private struct LimaCreateSheet: View {
    let existingNames: Set<String>
    let onCreate: (HauntedLimaVMSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cpus = 2
    @State private var memoryGiB = 2
    @State private var mounts: [MountDraft] = []

    struct MountDraft: Identifiable {
        let id = UUID()
        let path: String
        var writable: Bool
    }

    private var nameError: String? {
        if name.isEmpty { return nil }
        if !isValidWorkstationName(name) {
            return "a-z, 0-9, - and _, starting with a letter or digit, max 32"
        }
        if existingNames.contains(name) {
            return "a VM or workstation with this name already exists"
        }
        return nil
    }

    private var canCreate: Bool { !name.isEmpty && nameError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New workstation")
                .font(.headline)

            TextField("Name (e.g. ws1)", text: $name)
                .textFieldStyle(.roundedBorder)
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Stepper("CPUs: \(cpus)", value: $cpus, in: 1...16)
            Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 1...64)

            Divider()

            Text("Exposed directories")
                .font(.subheadline)
            Text("The VM sees nothing from this Mac unless you add it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($mounts) { $mount in
                HStack(spacing: 6) {
                    Text(mount.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Toggle("writable", isOn: $mount.writable)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                    Button {
                        mounts.removeAll { $0.id == mount.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove this directory")
                }
            }
            Button("Add directory…") { addMount() }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(HauntedLimaVMSpec(
                        name: name, cpus: cpus, memoryGiB: memoryGiB,
                        mounts: mounts.map {
                            HauntedLimaMount(path: $0.path, writable: $0.writable)
                        }))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func addMount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Expose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !mounts.contains(where: { $0.path == url.path }) else { return }
        mounts.append(MountDraft(path: url.path, writable: false))
    }
}

/// The "ALPHA" pre-release pill shown beside the Haunted title — the same
/// amber marker the Console and the landing page carry, so the product reads
/// as Alpha wherever a user meets it.
struct HauntedAlphaBadge: View {
    private static let amber = Color(red: 0.96, green: 0.71, blue: 0.27)

    var body: some View {
        Text("ALPHA")
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Self.amber)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.amber.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.amber.opacity(0.35), lineWidth: 1))
            .accessibilityLabel("Alpha release")
    }
}
