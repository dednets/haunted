import Foundation

/// Where a freshly opened Haunted window should land, given what the user was
/// last attached to and which workstations the console currently reports.
///
/// Pure, and deliberately separate from `HauntedManager.openWindow` — the
/// decision is the interesting part and `openWindow` needs `NSApp.delegate`,
/// a Ghostty instance, and a real window to say anything at all.
enum HauntedSessionRouter {
    enum Route: Equatable {
        /// Resume the exact session the user left; it survives in the
        /// workstation's haunted-daemon across Terminal quits.
        case resume(target: String, session: String)
        /// The workstation's persistent "default" session (created on first use).
        case fresh(target: String)
        /// Nothing reachable: a plain local shell, with the sidebar still shown
        /// so the user can click a workstation once one comes online. The one
        /// place a Haunted window legitimately hosts an unattached shell.
        case plainShell
    }

    /// The last-attached workstation wins, but only while it is still online —
    /// attaching to an offline daemon would hang on the reconnect loop instead
    /// of showing the user something useful.
    static func route(
        lastAttached: (target: String, session: String)?,
        workstations: [HauntedWorkstation]
    ) -> Route {
        if let last = lastAttached,
           workstations.contains(where: { $0.target == last.target && $0.online }) {
            return .resume(target: last.target, session: last.session)
        }
        if let online = workstations.first(where: { $0.online }) {
            return .fresh(target: online.target)
        }
        return .plainShell
    }
}
