import SwiftUI

/// Daemon sidebar shown in Haunted-connected terminal windows. Each daemon is
/// a group; under it are the sessions currently running on that daemon, plus a
/// "new session" action. Selecting a session opens a new tab attached to it;
/// selecting "new session" creates a fresh one. The list refreshes on a short
/// poll.
struct HauntedSidebarView: View {
    let session: HauntedSession
    /// (daemon, sessionName?) — nil sessionName means "create a new session".
    let onOpen: (HauntedDaemon, String?) -> Void

    @State private var daemons: [HauntedDaemon] = []
    @State private var sessionsByDaemon: [String: [HauntedDaemonSession]] = [:]
    @State private var expanded: Set<String> = []
    @State private var errorMessage: String?
    @State private var loaded = false

    private var consoleHost: String {
        URL(string: session.consoleURL)?.host ?? session.consoleURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Haunted")
                    .font(.headline)
                Text(consoleHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)

            Divider()

            if loaded && daemons.isEmpty && errorMessage == nil {
                Text("No daemons enrolled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(daemons) { daemon in
                        DaemonGroup(
                            daemon: daemon,
                            sessions: sessionsByDaemon[daemon.id] ?? [],
                            isExpanded: expanded.contains(daemon.id),
                            toggle: { toggle(daemon) },
                            onOpenSession: { onOpen(daemon, $0) },
                            onNewSession: { onOpen(daemon, nil) },
                            onKillSession: { kill(daemon: daemon, session: $0) })
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await poll() }
    }

    private func toggle(_ daemon: HauntedDaemon) {
        if expanded.contains(daemon.id) {
            expanded.remove(daemon.id)
        } else {
            expanded.insert(daemon.id)
        }
    }

    private func kill(daemon: HauntedDaemon, session sessionName: String) {
        // Optimistically drop it from the list; the next poll reconciles.
        sessionsByDaemon[daemon.id]?.removeAll { $0.name == sessionName }
        Task {
            do {
                let token = try await session.accessToken()
                try await HauntedConsoleAPI.killSession(
                    consoleURL: session.consoleURL,
                    token: token,
                    daemonID: daemon.id,
                    sessionName: sessionName)
            } catch {
                errorMessage = "kill failed: \(error.localizedDescription)"
            }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let token = try await session.accessToken()
                let fresh = try await HauntedConsoleAPI.daemons(
                    consoleURL: session.consoleURL, token: token)
                daemons = fresh.sorted { $0.name < $1.name }
                errorMessage = nil

                // On first load, expand online daemons so sessions are visible.
                if !loaded {
                    expanded = Set(fresh.filter { $0.online }.map { $0.id })
                }

                // Refresh sessions for online daemons.
                for daemon in daemons where daemon.online {
                    if let sessions = try? await HauntedConsoleAPI.daemonSessions(
                        consoleURL: session.consoleURL,
                        token: token,
                        daemonID: daemon.id) {
                        sessionsByDaemon[daemon.id] =
                            sessions.sorted { $0.name < $1.name }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            loaded = true
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
    }
}

private struct DaemonGroup: View {
    let daemon: HauntedDaemon
    let sessions: [HauntedDaemonSession]
    let isExpanded: Bool
    let toggle: () -> Void
    let onOpenSession: (String) -> Void
    let onNewSession: () -> Void
    let onKillSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Circle()
                        .fill(daemon.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(daemon.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .disabled(!daemon.online)
            .opacity(daemon.online ? 1 : 0.5)

            if isExpanded && daemon.online {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
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
}

private struct SessionRow: View {
    let session: HauntedDaemonSession
    let action: () -> Void
    let onKill: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.name)
                    .lineLimit(1)
                if session.attachedClients > 0 {
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
        .help(session.attachedClients > 0
              ? "Reattach \(session.name) (moves it to this tab)"
              : "Attach \(session.name) in a new tab")
        .contextMenu {
            Button("Attach in New Tab") { action() }
            Divider()
            Button("Kill Session", role: .destructive) { onKill() }
        }
    }
}
