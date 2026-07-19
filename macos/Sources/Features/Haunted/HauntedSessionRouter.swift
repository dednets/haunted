import Foundation

/// Where a freshly opened Haunted window should land, given what the user was
/// last attached to and which nodes/sessions the console currently
/// reports.
///
/// Pure, and deliberately separate from `HauntedManager.openWindow` — the
/// decision is the interesting part and `openWindow` needs `NSApp.delegate`,
/// a Ghostty instance, and a real window to say anything at all.
enum HauntedSessionRouter {
    enum Route: Equatable {
        /// Resume the exact session the user left; it survives in the
        /// node's haunted-daemon across Terminal quits.
        case resume(target: String, session: String)
        /// Nothing to resume: the window shows the sidebar with a "Nothing
        /// here" placeholder in the terminal area. Haunted never *creates* a
        /// session on its own — a session only ever appears from an explicit
        /// click (a node row, an existing session, or "New session").
        case empty
    }

    /// Resume the last-attached session, but only when its node is still
    /// online AND that exact session still exists on it. Two reasons, both of
    /// which used to be bugs:
    ///
    ///  - Attaching to an offline daemon would hang on the reconnect loop
    ///    instead of showing the user something useful.
    ///  - A remembered session that has since been killed (or a daemon that was
    ///    restarted) is *gone*; resuming it with `--create` would silently mint
    ///    a brand-new session on every launch — the "it starts a session by
    ///    itself" surprise. Startup must never create. If the session is not in
    ///    the list, fall through to `.empty` and let the user click.
    static func route(
        lastAttached: (target: String, session: String)?,
        nodes: [HauntedNode],
        sessionsOnLastTarget: [HauntedNodeSession]
    ) -> Route {
        guard let last = lastAttached,
              nodes.contains(where: { $0.target == last.target && $0.online }),
              sessionsOnLastTarget.contains(where: { $0.name == last.session })
        else {
            return .empty
        }
        return .resume(target: last.target, session: last.session)
    }
}
