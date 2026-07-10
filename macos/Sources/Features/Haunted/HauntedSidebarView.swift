import SwiftUI

/// What the sidebar model reads from the mesh. A seam, so the poll loop can be
/// driven without spawning `dedmeshctl`/`haunted` (§5.4).
protocol HauntedSessionListing: Sendable {
    func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation]
    func sessions(
        identity: HauntedClientIdentity, target: String
    ) async throws -> [HauntedWorkstationSession]
}

/// The real one: the CLIs own all mesh transport and mTLS state.
struct HauntedCLISessionListing: HauntedSessionListing {
    func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation] {
        try await HauntedCLI.workstations(identity: identity)
    }

    func sessions(
        identity: HauntedClientIdentity, target: String
    ) async throws -> [HauntedWorkstationSession] {
        try await HauntedCLI.sessions(identity: identity, target: target)
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
    static let shared = HauntedSidebarModel()

    @Published var workstations: [HauntedWorkstation] = []
    @Published var sessionsByTarget: [String: [HauntedWorkstationSession]] = [:]
    @Published var expanded: Set<String> = []
    @Published var errorMessage: String?
    @Published var loaded = false

    private let client: HauntedSessionListing
    /// Killing a session closes its tab, which only `HauntedManager` can do.
    /// Injected so a test can observe the request without a window.
    private let killSession: @MainActor (HauntedClientIdentity, String, String) -> Void
    /// Closing every tab of a removed workstation is likewise `HauntedManager`'s
    /// job; injected so the removal reconciliation is observable without windows.
    private let closeWorkstation: @MainActor (String) -> Void
    private let pollInterval: TimeInterval
    /// Attach/kill take a moment to land daemon-side, so the change
    /// notification refreshes after a beat rather than racing the daemon.
    private let refreshDelay: TimeInterval

    private var identity: HauntedClientIdentity?
    private var pollTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

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
        refreshDelay: TimeInterval = 1.2
    ) {
        self.client = client
        self.killSession = killSession
        self.closeWorkstation = closeWorkstation
        self.pollInterval = pollInterval
        self.refreshDelay = refreshDelay
        observer = NotificationCenter.default.addObserver(
            forName: .hauntedSessionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.refreshDelay * 1_000_000_000))
                await self.refreshSessions()
            }
        }
    }

    deinit {
        // Block-based observers outlive their target; without this a test's
        // model keeps answering notifications meant for the next one.
        if let observer { NotificationCenter.default.removeObserver(observer) }
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

    func toggle(_ workstation: HauntedWorkstation) {
        if expanded.contains(workstation.id) {
            expanded.remove(workstation.id)
        } else {
            expanded.insert(workstation.id)
        }
    }

    func kill(workstation: HauntedWorkstation, session sessionName: String) {
        guard let identity else { return }
        // Optimistically drop it from the list; the change notification's
        // refresh reconciles.
        sessionsByTarget[workstation.id]?.removeAll { $0.name == sessionName }
        killSession(identity, workstation.target, sessionName)
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

    /// One workstation's failure must not blank the others: a mesh blip on one
    /// daemon should not empty the whole sidebar.
    func refreshSessions() async {
        guard let identity else { return }
        for workstation in workstations where workstation.online {
            if let sessions = try? await client.sessions(
                identity: identity, target: workstation.target) {
                sessionsByTarget[workstation.id] =
                    sessions.sorted { $0.name < $1.name }
            }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            guard let identity else { return }
            do {
                let fresh = try await client.workstations(identity: identity)
                let previous = workstations
                workstations = fresh.sorted { $0.target < $1.target }
                errorMessage = nil

                reconcile(previous: previous, fresh: fresh)

                await refreshSessions()
            } catch {
                // Keep the last-known workstations: a transient CLI failure must
                // not flash the sidebar to empty.
                errorMessage = error.localizedDescription
            }
            loaded = true
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
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

    @ObservedObject private var model = HauntedSidebarModel.shared
    @ObservedObject private var layout = HauntedSidebarLayout.shared

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
                    Text("Haunted")
                        .font(.headline)
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
                    ForEach(model.workstations) { workstation in
                        WorkstationGroup(
                            workstation: workstation,
                            sessions: model.sessionsByTarget[workstation.id] ?? [],
                            isExpanded: model.expanded.contains(workstation.id),
                            toggle: { model.toggle(workstation) },
                            onOpenPrimary: {
                                model.expanded.insert(workstation.id)
                                onOpen(workstation, "default")
                            },
                            onOpenSession: { onOpen(workstation, $0) },
                            onNewSession: { onOpen(workstation, nil) },
                            onKillSession: {
                                model.kill(workstation: workstation, session: $0)
                            })
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
        }
    }
}

private struct WorkstationGroup: View {
    let workstation: HauntedWorkstation
    let sessions: [HauntedWorkstationSession]
    let isExpanded: Bool
    let toggle: () -> Void
    let onOpenPrimary: () -> Void
    let onOpenSession: (String) -> Void
    let onNewSession: () -> Void
    let onKillSession: (String) -> Void

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

                Button(action: onOpenPrimary) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(workstation.daemon)
                            .fontWeight(.medium)
                            .lineLimit(1)
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
                      ? "Open a terminal on \(workstation.daemon) (its persistent default session)"
                      : workstation.error ?? "\(workstation.target) (\(workstation.status))")
            }
            .disabled(!workstation.online)
            .opacity(workstation.online ? 1 : 0.5)
            .padding(.leading, 2)

            if isExpanded && workstation.online {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isOpenHere: HauntedManager.shared.isSessionOpen(
                            target: workstation.target, sessionName: session.name),
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
                    .fill(hovering ? Color.secondary.opacity(0.15) : Color.clear))
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
