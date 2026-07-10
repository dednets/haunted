import AppKit
import SwiftUI

/// What the sidebar model reads from — and writes to — the mesh. A seam, so
/// the poll loop can be driven without spawning `dedmeshctl`/`haunted` (§5.4).
protocol HauntedSessionListing: Sendable {
    func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation]
    func sessions(
        identity: HauntedClientIdentity, target: String
    ) async throws -> [HauntedWorkstationSession]
    /// Persists a workstation daemon's display color on the console
    /// (nil = back to the default).
    func setWorkstationColor(
        identity: HauntedClientIdentity, daemon: String, color: String?
    ) async throws
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

    func setWorkstationColor(
        identity: HauntedClientIdentity, daemon: String, color: String?
    ) async throws {
        try await HauntedCLI.setWorkstationColor(
            identity: identity, daemon: daemon, color: color)
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
        limaRefresh: { await HauntedLimaModel.shared.refresh() })

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
    /// Piggybacks the Lima manager's refresh on this model's poll loop
    /// (nil = no Lima integration; see `shared`).
    private let limaRefresh: (@MainActor () async -> Void)?

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
        refreshDelay: TimeInterval = 1.2,
        limaRefresh: (@MainActor () async -> Void)? = nil
    ) {
        self.client = client
        self.killSession = killSession
        self.closeWorkstation = closeWorkstation
        self.pollInterval = pollInterval
        self.refreshDelay = refreshDelay
        self.limaRefresh = limaRefresh
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
            await limaRefresh?()
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
    /// "This computer": open a plain local terminal on this Mac.
    let onOpenLocal: () -> Void

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
                    // Always first and always available: a regular terminal on
                    // this Mac, exactly upstream Ghostty's default surface.
                    LocalComputerRow(onOpen: onOpenLocal)

                    ForEach(mergedRows) { row in
                        if let workstation = row.workstation {
                            WorkstationGroup(
                                workstation: workstation,
                                displayName: row.displayName,
                                sessions: model.sessionsByTarget[workstation.id] ?? [],
                                isExpanded: model.expanded.contains(workstation.id),
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

/// "This computer": a regular terminal on this Mac — upstream Ghostty's
/// default surface, no attach command, no mesh in the path. Always present
/// and always enabled: the local machine needs no daemon to be reachable.
/// Laid out to line up with the workstation rows (16pt icon slot where their
/// chevron sits).
private struct LocalComputerRow: View {
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                Image(systemName: "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                HStack(spacing: 6) {
                    Text("This computer")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.secondary.opacity(0.15) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open a regular terminal on this Mac")
        .padding(.leading, 2)
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
