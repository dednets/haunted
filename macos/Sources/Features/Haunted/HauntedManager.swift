import AppKit
import SwiftUI
import GhosttyKit

/// An authenticated Haunted Console session held by the GUI. Only the
/// persistent refresh token is kept (in the Keychain); short-lived access
/// tokens are minted on demand and cached until they near expiry. The
/// password never leaves the login window.
final class HauntedSession {
    let consoleURL: String
    private let refreshToken: String
    private var cachedAccess: String?
    private var cachedExpiry = Date.distantPast

    init(consoleURL: String, refreshToken: String,
         initialAccess: String? = nil, initialExpiry: Date = .distantPast) {
        self.consoleURL = consoleURL
        self.refreshToken = refreshToken
        self.cachedAccess = initialAccess
        self.cachedExpiry = initialExpiry
    }

    /// Returns a valid access token, refreshing from the persistent refresh
    /// token when the cached one is missing or within a minute of expiry.
    func accessToken() async throws -> String {
        if let cachedAccess, cachedExpiry > Date().addingTimeInterval(60) {
            return cachedAccess
        }
        let result = try await HauntedConsoleAPI.refresh(
            consoleURL: consoleURL, refreshToken: refreshToken)
        cachedAccess = result.token
        cachedExpiry = result.expiresAt
        return result.token
    }

    /// Returns the cached access token if still valid, without a network
    /// call. Used by the synchronous split path; the sidebar poll keeps the
    /// cache warm.
    func cachedToken() -> String? {
        guard let cachedAccess, cachedExpiry > Date() else { return nil }
        return cachedAccess
    }
}

/// Associates Ghostty windows and surfaces with a Haunted Console session so
/// the daemon sidebar can open attached tabs and splits inherit the daemon of
/// the surface they were created from.
final class HauntedManager {
    static let shared = HauntedManager()

    /// What a surface/tab is attached to: which daemon, and which session
    /// name (nil means the in-terminal picker chooses).
    private final class Attachment {
        let session: HauntedSession
        let daemonName: String?
        let sessionName: String?

        init(session: HauntedSession, daemonName: String?, sessionName: String?) {
            self.session = session
            self.daemonName = daemonName
            self.sessionName = sessionName
        }
    }

    /// Surface → attachment. Weak keys, so entries disappear with surfaces.
    private let surfaces = NSMapTable<Ghostty.SurfaceView, Attachment>
        .weakToStrongObjects()

    /// Tab/window controller → session, for the sidebar and new-tab actions.
    private let controllers = NSMapTable<TerminalController, HauntedSession>
        .weakToStrongObjects()

    /// (daemon, session name) → the tab showing it, so a sidebar click on an
    /// already-open session focuses its tab instead of opening a duplicate.
    private let sessionTabs = NSMapTable<NSString, TerminalController>(
        keyOptions: .copyIn, valueOptions: .weakMemory)

    /// Session name generated in splitConfiguration and consumed by the
    /// immediately-following surfaceCreated (both run synchronously on the
    /// main thread during a split).
    private var pendingSplitSessionName: String?

    private init() {}

    private func tabKey(_ daemonName: String, _ sessionName: String) -> NSString {
        "\(daemonName)\u{1}\(sessionName)" as NSString
    }

    private func generateSessionName() -> String {
        "gui-" + String(UUID().uuidString.replacingOccurrences(
            of: "-", with: "").prefix(8)).lowercased()
    }

    func session(for controller: TerminalController) -> HauntedSession? {
        controllers.object(forKey: controller)
    }

    /// The daemon a controller's focused (or root) surface is attached to.
    @MainActor
    func daemonName(for controller: TerminalController) -> String? {
        if let focused = controller.focusedSurface,
           let info = surfaces.object(forKey: focused) {
            return info.daemonName
        }
        if let root = controller.surfaceTree.root?.leftmostLeaf(),
           let info = surfaces.object(forKey: root) {
            return info.daemonName
        }
        return nil
    }

    /// True if at least one Haunted terminal window is open.
    @MainActor
    var hasWindow: Bool {
        controllers.keyEnumerator().allObjects.contains { ($0 as? TerminalController)?.window != nil }
    }

    /// Focuses an existing Haunted window if one is open. Returns whether it did.
    @MainActor
    @discardableResult
    func focusExistingWindow() -> Bool {
        for case let controller as TerminalController in controllers.keyEnumerator().allObjects {
            if let window = controller.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
        }
        return false
    }

    /// Opens a new tab with a fresh session on the focused window's daemon
    /// (⌘T). Falls back to the first online daemon when the focused window has
    /// none yet.
    @MainActor
    func newTabOnCurrentDaemon(from parent: TerminalController) async {
        guard let session = self.session(for: parent) else { return }
        var name = daemonName(for: parent)
        if name == nil {
            let daemons = (try? await HauntedConsoleAPI.daemons(
                consoleURL: session.consoleURL,
                token: try await session.accessToken())) ?? []
            name = daemons.first { $0.online }?.name
        }
        guard let daemonName = name else { return }
        await openTab(from: parent,
                      daemon: HauntedDaemon(id: "", name: daemonName, online: true),
                      sessionName: generateSessionName())
    }

    // MARK: Session entry points

    /// Opens the Haunted window for a freshly authenticated session. If a
    /// daemon is online it attaches to that daemon's default session;
    /// otherwise it opens a plain shell so the sidebar is visible and the
    /// user can click a daemon once one comes online. It never drops into the
    /// in-terminal picker — the sidebar is the picker.
    @MainActor
    func openWindow(session: HauntedSession, daemons: [HauntedDaemon]) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let daemonName = daemons.first { $0.online }?.name

        // The initial/restore window reattaches the daemon's persistent
        // "default" session so resuming lands back where the user left off;
        // sidebar tabs and splits create fresh sessions.
        let config: Ghostty.SurfaceConfiguration
        if daemonName != nil,
           let attached = await surfaceConfiguration(
            session: session, daemonName: daemonName, sessionName: "default") {
            config = attached
        } else {
            // No daemon online yet: a plain shell alongside the sidebar.
            config = Ghostty.SurfaceConfiguration()
        }

        let controller = TerminalController.newWindow(
            appDelegate.ghostty, withBaseConfig: config)
        register(controller, session: session,
                 daemonName: daemonName, sessionName: "default")
    }

    /// Handles a sidebar click: if a tab already shows this session, focus it
    /// (and do nothing if it is already frontmost); otherwise open a new tab.
    /// A nil sessionName means "new session" — a fresh generated name.
    @MainActor
    func focusOrOpen(
        from parent: TerminalController,
        daemon: HauntedDaemon,
        sessionName: String?
    ) async {
        let name = sessionName ?? generateSessionName()
        if let existing = sessionTabs.object(forKey: tabKey(daemon.name, name)),
           let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        await openTab(from: parent, daemon: daemon, sessionName: name)
    }

    /// Opens a new tab attached to a named session on a daemon (created if it
    /// does not exist).
    @MainActor
    func openTab(
        from parent: TerminalController,
        daemon: HauntedDaemon,
        sessionName: String
    ) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let session = self.session(for: parent),
              let config = await surfaceConfiguration(
                session: session,
                daemonName: daemon.name,
                sessionName: sessionName)
        else { return }
        guard let controller = TerminalController.newTab(
            appDelegate.ghostty, from: parent.window, withBaseConfig: config)
        else { return }
        register(controller, session: session,
                 daemonName: daemon.name, sessionName: sessionName)
    }

    // MARK: Split inheritance (hooks called from BaseTerminalController)

    /// If a split's parent surface belongs to a Haunted daemon, the child
    /// attaches to a fresh session on the same daemon. Uses the session's
    /// cached access token (kept warm by the sidebar poll) so this stays
    /// synchronous, as the split code path requires.
    func splitConfiguration(
        parent: Ghostty.SurfaceView,
        base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        guard let info = surfaces.object(forKey: parent),
              let daemonName = info.daemonName,
              let token = info.session.cachedToken() else { return base }
        // A split opens a fresh session on the parent's daemon. Generate its
        // name here and hand it to the surfaceCreated call that follows.
        let name = generateSessionName()
        pendingSplitSessionName = name
        return buildConfiguration(
            consoleURL: info.session.consoleURL,
            accessToken: token,
            daemonName: daemonName,
            sessionName: name)
    }

    /// Propagates the parent surface's association to a new split surface, and
    /// indexes the split's session to its owning tab so a sidebar click on it
    /// focuses that tab.
    @MainActor
    func surfaceCreated(
        _ surface: Ghostty.SurfaceView,
        splitFrom parent: Ghostty.SurfaceView
    ) {
        guard let info = surfaces.object(forKey: parent) else { return }
        let name = pendingSplitSessionName
        pendingSplitSessionName = nil
        surfaces.setObject(
            Attachment(session: info.session,
                       daemonName: info.daemonName, sessionName: name),
            forKey: surface)

        // Index this split's session to the controller whose tab contains it.
        if let daemonName = info.daemonName, let name,
           let controller = TerminalController.all.first(
            where: { $0.surfaceTree.contains(surface) }) {
            sessionTabs.setObject(controller, forKey: tabKey(daemonName, name))
        }
    }

    // MARK: Internals

    @MainActor
    private func register(
        _ controller: TerminalController,
        session: HauntedSession,
        daemonName: String?,
        sessionName: String?
    ) {
        controllers.setObject(session, forKey: controller)
        if let view = controller.surfaceTree.root?.leftmostLeaf() {
            surfaces.setObject(
                Attachment(session: session,
                           daemonName: daemonName, sessionName: sessionName),
                forKey: view)
        }
        if let daemonName, let sessionName {
            sessionTabs.setObject(controller, forKey: tabKey(daemonName, sessionName))
        }
        attachSidebar(to: controller, session: session)
    }

    private func surfaceConfiguration(
        session: HauntedSession,
        daemonName: String?,
        sessionName: String?
    ) async -> Ghostty.SurfaceConfiguration? {
        guard let token = try? await session.accessToken() else { return nil }
        return buildConfiguration(
            consoleURL: session.consoleURL,
            accessToken: token,
            daemonName: daemonName,
            sessionName: sessionName)
    }

    private func buildConfiguration(
        consoleURL: String,
        accessToken: String,
        daemonName: String?,
        sessionName: String?
    ) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["HAUNTED_CONSOLE"] = consoleURL
        config.environmentVariables["HAUNTED_CONSOLE_TOKEN"] = accessToken
        // Run through the login shell so the user's PATH resolves the helper.
        var command = "exec haunted-console-connect --attach raw"
        if let daemonName {
            command += " --daemon \(shellQuote(daemonName))"
            if let sessionName {
                // Attach the named session, creating it if it does not exist.
                command += " --session \(shellQuote(sessionName)) --create"
            }
        }
        config.initialInput = command + "\n"
        return config
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Sidebar

    @MainActor
    private func attachSidebar(
        to controller: TerminalController,
        session: HauntedSession
    ) {
        guard let window = controller.window,
              let terminalView = window.contentView,
              !(terminalView is HauntedContainerView) else { return }

        let sidebar = HauntedSidebarView(session: session) {
            [weak self, weak controller] daemon, sessionName in
            guard let self, let controller else { return }
            Task { await self.focusOrOpen(
                from: controller, daemon: daemon, sessionName: sessionName) }
        }
        window.contentView = HauntedContainerView(
            sidebar: NSHostingView(rootView: sidebar),
            terminal: terminalView)
    }
}

/// Fixed-width daemon sidebar on the left, terminal filling the rest.
final class HauntedContainerView: NSView {
    init(sidebar: NSView, terminal: NSView) {
        super.init(frame: terminal.frame)
        addSubview(sidebar)
        addSubview(terminal)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            terminal.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
