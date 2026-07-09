import AppKit
import Combine
import SwiftUI
import GhosttyKit

/// Associates Ghostty windows and surfaces with the enrolled DedMesh client
/// identity so the workstation sidebar can open attached tabs and splits
/// inherit the workstation of the surface they were created from.
///
/// There is no session/token state here: authentication is the client mTLS
/// certificate in the identity's state dir, and every attach/list/kill is a
/// CLI invocation that reads it (HauntedCLI).
final class HauntedManager {
    static let shared = HauntedManager()

    /// NSMapTable-compatible box for the value-typed identity.
    private final class ClientRef {
        let identity: HauntedClientIdentity
        init(_ identity: HauntedClientIdentity) { self.identity = identity }
    }

    /// What a surface/tab is attached to: which workstation (target), and
    /// which session name.
    private final class Attachment {
        let identity: HauntedClientIdentity
        let target: String?
        let sessionName: String?

        init(identity: HauntedClientIdentity, target: String?, sessionName: String?) {
            self.identity = identity
            self.target = target
            self.sessionName = sessionName
        }
    }

    /// Surface → attachment. Weak keys, so entries disappear with surfaces.
    private let surfaces = NSMapTable<Ghostty.SurfaceView, Attachment>
        .weakToStrongObjects()

    /// Tab/window controller → identity, for the sidebar and new-tab actions.
    private let controllers = NSMapTable<TerminalController, ClientRef>
        .weakToStrongObjects()

    /// (target, session name) → the tab showing it, so a sidebar click on an
    /// already-open session focuses its tab instead of opening a duplicate.
    private let sessionTabs = NSMapTable<NSString, TerminalController>(
        keyOptions: .copyIn, valueOptions: .weakMemory)

    /// Session name generated in splitConfiguration and consumed by the
    /// immediately-following surfaceCreated (both run synchronously on the
    /// main thread during a split).
    private var pendingSplitSessionName: String?

    private init() {}

    /// U+0001 separates the two halves so no (target, session) pair can collide
    /// with another: it cannot appear in a target, and isValidSessionName bars
    /// it from a session name.
    static func tabKey(_ target: String, _ sessionName: String) -> NSString {
        "\(target)\u{1}\(sessionName)" as NSString
    }

    /// Must satisfy the daemon's session_name_valid() — see isValidSessionName.
    ///
    /// 16 hex digits, not 8: a collision means two tabs share a tabKey, so a
    /// sidebar click focuses the wrong session (or `haunted` attaches where it
    /// should create). At 32 bits the birthday bound makes that a ~1-in-10⁴
    /// event across a few thousand sessions — small, but for free it can be
    /// 64 bits and negligible. Well inside HAUNTED_SESSION_NAME_MAX (63).
    static func generateSessionName() -> String {
        "gui-" + String(UUID().uuidString.replacingOccurrences(
            of: "-", with: "").prefix(16)).lowercased()
    }

    func identity(for controller: TerminalController) -> HauntedClientIdentity? {
        controllers.object(forKey: controller)?.identity
    }

    /// True if a tab in this app currently shows the session — the sidebar
    /// highlights those rows so "which of these am I already looking at?"
    /// has an answer without clicking through.
    @MainActor
    func isSessionOpen(target: String, sessionName: String) -> Bool {
        guard let controller = sessionTabs.object(
            forKey: Self.tabKey(target, sessionName)) else { return false }
        return controller.window != nil
    }

    /// What to do with the tab showing a session we are about to kill.
    enum SessionTabClose: Equatable {
        /// The window has sibling tabs; close just this one.
        case closeTab
        /// This is the window's only tab. Do NOT tear the window down — that
        /// crashed: `window.close()` frees the attached `SurfaceView` while
        /// libghostty is still delivering surface actions (a scrollbar update)
        /// into it, a use-after-free. Empty the window to the "Nothing here"
        /// state instead, which is also the UX we want: the sidebar stays.
        case emptyState
    }

    /// Pure so the crash-avoidance rule is testable without a live window:
    /// only the *last* tab becomes the empty state; any other closes normally.
    static func sessionTabClosePlan(siblingTabCount: Int) -> SessionTabClose {
        siblingTabCount > 1 ? .closeTab : .emptyState
    }

    /// Kills a session and updates the tab showing it. Tab first: the surface's
    /// attach exits when the session dies, and with wait-after-command that
    /// would strand an exit banner the user has to close by hand.
    @MainActor
    func killSession(
        identity: HauntedClientIdentity,
        target: String,
        sessionName: String
    ) {
        if let controller = sessionTabs.object(forKey: Self.tabKey(target, sessionName)) {
            let tabs = controller.window?.tabGroup?.windows.count ?? 1
            switch Self.sessionTabClosePlan(siblingTabCount: tabs) {
            case .closeTab:
                controller.window?.close()
            case .emptyState:
                enterEmptyState(controller)
            }
        }
        Task {
            do {
                try await HauntedCLI.killSession(
                    identity: identity, target: target, sessionName: sessionName)
            } catch {
                NSLog("[haunted] kill %@ on %@ failed: %@",
                      sessionName, target, "\(error)")
            }
            NotificationCenter.default.post(
                name: .hauntedSessionsDidChange, object: nil)
        }
    }

    /// Closes every open tab attached to `target`, used when that workstation is
    /// removed from the console. The daemon is no longer reachable, so there is
    /// nothing to kill over the mesh — the tabs can only be closed locally;
    /// otherwise each one reconnect-loops for ~3 minutes and then strands a dead
    /// exit banner the user must dismiss by hand.
    @MainActor
    func closeTabs(forTarget target: String) {
        let prefix = "\(target)\u{1}"
        guard let keys = sessionTabs.keyEnumerator().allObjects as? [NSString] else { return }
        // Collect distinct controllers first: one window may hold several of the
        // target's sessions as tabs, and closing/emptying it invalidates the
        // other keys mid-enumeration.
        var doomed: [TerminalController] = []
        for key in keys where (key as String).hasPrefix(prefix) {
            if let controller = sessionTabs.object(forKey: key),
               !doomed.contains(where: { $0 === controller }) {
                doomed.append(controller)
            }
        }
        for controller in doomed {
            let tabs = controller.window?.tabGroup?.windows.count ?? 1
            switch Self.sessionTabClosePlan(siblingTabCount: tabs) {
            case .closeTab:
                controller.window?.close()
            case .emptyState:
                enterEmptyState(controller)
            }
        }
    }

    /// Drops a Haunted window to the "Nothing here" empty state: sidebar still
    /// shown, terminal area replaced by a placeholder, no attached session and
    /// no local shell. Sets the flag *before* emptying the surface tree so the
    /// fork's "empty tree closes the window" reaction yields to the placeholder.
    @MainActor
    private func enterEmptyState(_ controller: TerminalController) {
        // No longer attached to anything, so forget the tab mapping — a stale
        // entry would make a later sidebar click focus this now-empty tab.
        removeSessionTabs(for: controller)
        controller.hauntedEmptyState = true
        controller.surfaceTree = .init()
    }

    /// Forget every (target, session) → controller mapping pointing at this
    /// controller. NSMapTable has no reverse lookup, so we sweep the keys.
    @MainActor
    private func removeSessionTabs(for controller: TerminalController) {
        guard let keys = sessionTabs.keyEnumerator().allObjects as? [NSString] else { return }
        for key in keys where sessionTabs.object(forKey: key) === controller {
            sessionTabs.removeObject(forKey: key)
        }
    }

    /// The workstation target the controller's focused (or root) surface is
    /// attached to.
    @MainActor
    func target(for controller: TerminalController) -> String? {
        if let focused = controller.focusedSurface,
           let info = surfaces.object(forKey: focused) {
            return info.target
        }
        if let root = controller.surfaceTree.root?.leftmostLeaf(),
           let info = surfaces.object(forKey: root) {
            return info.target
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

    /// Opens a new tab with a fresh session on the focused window's
    /// workstation (⌘T). Falls back to the first online workstation when the
    /// focused window has none yet.
    @MainActor
    func newTabOnCurrentDaemon(from parent: TerminalController) async {
        guard let identity = self.identity(for: parent) else { return }
        var target = self.target(for: parent)
        if target == nil {
            let workstations = (try? await HauntedCLI.workstations(
                identity: identity)) ?? []
            target = workstations.first { $0.online }?.target
        }
        guard let target else { return }
        openTab(from: parent, target: target,
                sessionName: Self.generateSessionName(), create: true)
    }

    // MARK: Session entry points

    /// Opens the Haunted window for the enrolled identity, resuming where the
    /// user left off: the last-attached workstation/session when that
    /// workstation is still online (sessions persist in its haunted-daemon
    /// across Terminal quits), else the first online workstation's persistent
    /// "default" session, else a plain shell so the sidebar is visible and
    /// the user can click a workstation once one comes online.
    @MainActor
    func openWindow(
        identity: HauntedClientIdentity,
        workstations: [HauntedWorkstation],
        lastSessions: [HauntedWorkstationSession] = []
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        switch HauntedSessionRouter.route(
            lastAttached: Self.lastAttached,
            workstations: workstations,
            sessionsOnLastTarget: lastSessions) {
        case .resume(let target, let sessionName):
            NSLog("[haunted] openWindow: resume target=%@ session=%@",
                  target, sessionName)
            // create:false — resume never mints a session. The router only
            // returns .resume when the session is known to still exist.
            let config = buildConfiguration(
                target: target, sessionName: sessionName, create: false)
            let controller = TerminalController.newWindow(
                appDelegate.ghostty, withBaseConfig: config)
            register(controller, identity: identity,
                     target: target, sessionName: sessionName)
        case .empty:
            NSLog("[haunted] openWindow: empty state (nothing to resume)")
            openEmptyWindow(appDelegate: appDelegate, identity: identity)
        }
    }

    /// Opens a Haunted window straight into the "Nothing here" empty state:
    /// sidebar plus a placeholder, no attached session and no local shell. A
    /// throwaway shell surface is created by `newWindow` and torn down before
    /// the window is presented; that is cheaper than teaching `newWindow` to
    /// start surfaceless, and invisible to the user.
    @MainActor
    private func openEmptyWindow(
        appDelegate: AppDelegate,
        identity: HauntedClientIdentity
    ) {
        let controller = TerminalController.newWindow(
            appDelegate.ghostty, withBaseConfig: Ghostty.SurfaceConfiguration())
        register(controller, identity: identity, target: nil, sessionName: nil)
        controller.hauntedEmptyState = true
        controller.surfaceTree = .init()
    }

    /// The workstation target of the last session the user attached to, for
    /// deciding at startup whether to fetch its session list (to confirm the
    /// remembered session still exists before resuming it).
    @MainActor
    var lastAttachedTarget: String? { Self.lastAttached?.target }

    /// Last (workstation, session) the user attached to, persisted so a
    /// relaunch lands back in it. GUI-generated split/tab session names are
    /// as valid here as "default": the daemon keeps them alive across quits.
    private static var lastAttached: (target: String, session: String)? {
        get {
            guard let target = UserDefaults.standard.string(forKey: "HauntedLastTarget"),
                  let session = UserDefaults.standard.string(forKey: "HauntedLastSession")
            else { return nil }
            return (target, session)
        }
        set {
            UserDefaults.standard.set(newValue?.target, forKey: "HauntedLastTarget")
            UserDefaults.standard.set(newValue?.session, forKey: "HauntedLastSession")
        }
    }

    /// Handles a sidebar click: if a tab already shows this session, focus it
    /// (and do nothing if it is already frontmost); otherwise open a new tab.
    /// A nil sessionName means "new session" — a fresh generated name.
    @MainActor
    func focusOrOpen(
        from parent: TerminalController,
        workstation: HauntedWorkstation,
        sessionName: String?
    ) {
        let name = sessionName ?? Self.generateSessionName()
        if let existing = sessionTabs.object(forKey: Self.tabKey(workstation.target, name)),
           let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // A generated name is created; existing sessions are attached as-is.
        let create = sessionName == nil
        // Opening from an empty-state window fills that window in place rather
        // than leaving a lingering "Nothing here" tab behind a new one.
        if parent.hauntedEmptyState {
            attachInPlace(controller: parent, target: workstation.target,
                          sessionName: name, create: create)
            return
        }
        openTab(from: parent, target: workstation.target,
                sessionName: name, create: create)
    }

    /// Replaces an empty-state window's placeholder with a live attached
    /// surface, reusing the same window and its already-attached sidebar.
    @MainActor
    private func attachInPlace(
        controller: TerminalController,
        target: String,
        sessionName: String,
        create: Bool
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let app = appDelegate.ghostty.app,
              let identity = self.identity(for: controller)
        else { return }
        let config = buildConfiguration(
            target: target, sessionName: sessionName, create: create)
        // Clear the flag before installing the surface so the surfaceTree
        // change is treated as a real attach, not another empty transition.
        controller.hauntedEmptyState = false
        controller.surfaceTree = .init(view: Ghostty.SurfaceView(app, baseConfig: config))
        register(controller, identity: identity,
                 target: target, sessionName: sessionName)
    }

    /// Opens a new tab attached to a named session on a workstation.
    @MainActor
    func openTab(
        from parent: TerminalController,
        target: String,
        sessionName: String,
        create: Bool
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let identity = self.identity(for: parent)
        else { return }
        let config = buildConfiguration(
            target: target, sessionName: sessionName, create: create)
        guard let controller = TerminalController.newTab(
            appDelegate.ghostty, from: parent.window, withBaseConfig: config)
        else { return }
        register(controller, identity: identity,
                 target: target, sessionName: sessionName)
    }

    // MARK: Split inheritance (hooks called from BaseTerminalController)

    /// What a split inherits from the surface it was created from. Pure: the
    /// interesting decision, extracted from `splitConfiguration`, which cannot
    /// run without a live `Ghostty.SurfaceView`.
    enum SplitPlan: Equatable {
        /// The parent is attached to a workstation; the child opens a fresh
        /// session on that same workstation.
        case inherit(target: String, sessionName: String)
        /// The parent is a plain local shell (or not ours). Whatever config the
        /// caller had is used unchanged, and no session name is pending.
        case passthrough
    }

    static func splitPlan(
        parentTarget: String?,
        generateName: () -> String = generateSessionName
    ) -> SplitPlan {
        guard let parentTarget else { return .passthrough }
        return .inherit(target: parentTarget, sessionName: generateName())
    }

    /// If a split's parent surface belongs to a workstation, the child
    /// attaches to a fresh session on the same workstation. Synchronous: the
    /// attach command authenticates from the state dir, no token to mint.
    ///
    /// `@MainActor` because it writes `pendingSplitSessionName`, which the
    /// `@MainActor` `surfaceCreated` reads immediately afterwards — both run on
    /// the main thread inside `BaseTerminalController.newSplit`, and saying so
    /// is what keeps that hand-off from being a data race.
    @MainActor
    func splitConfiguration(
        parent: Ghostty.SurfaceView,
        base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        // Clear first. A previous split whose surface creation failed never
        // reached surfaceCreated, so its name is still sitting here; leaving it
        // would let the *next* split — including one from a plain-shell parent,
        // which returns early below — adopt a session name that was minted for
        // a different surface.
        pendingSplitSessionName = nil

        guard let info = surfaces.object(forKey: parent) else { return base }
        switch Self.splitPlan(parentTarget: info.target) {
        case .passthrough:
            return base
        case .inherit(let target, let sessionName):
            pendingSplitSessionName = sessionName
            return buildConfiguration(
                target: target, sessionName: sessionName, create: true)
        }
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
            Attachment(identity: info.identity,
                       target: info.target, sessionName: name),
            forKey: surface)

        // Index this split's session to the controller whose tab contains it.
        if let target = info.target, let name,
           let controller = TerminalController.all.first(
            where: { $0.surfaceTree.contains(surface) }) {
            sessionTabs.setObject(controller, forKey: Self.tabKey(target, name))
        }
    }

    // MARK: Internals

    @MainActor
    private func register(
        _ controller: TerminalController,
        identity: HauntedClientIdentity,
        target: String?,
        sessionName: String?
    ) {
        controllers.setObject(ClientRef(identity), forKey: controller)
        if let view = controller.surfaceTree.root?.leftmostLeaf() {
            surfaces.setObject(
                Attachment(identity: identity,
                           target: target, sessionName: sessionName),
                forKey: view)
        }
        if let target, let sessionName {
            sessionTabs.setObject(controller, forKey: Self.tabKey(target, sessionName))
            Self.lastAttached = (target, sessionName)
            NotificationCenter.default.post(
                name: .hauntedSessionsDidChange, object: nil)
        }
        attachSidebar(to: controller, identity: identity)
        if let target, let sessionName {
            showConnecting(on: controller, identity: identity,
                           target: target, sessionName: sessionName)
        }
    }

    /// The surface runs the attach through the user's login shell, so PATH
    /// resolves `haunted`/`dedmeshctl` and the mTLS state dir does the
    /// authenticating — no secrets in the environment.
    private func buildConfiguration(
        target: String,
        sessionName: String,
        create: Bool
    ) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.initialInput = HauntedCLI.attachCommand(
            target: target, sessionName: sessionName, create: create) + "\n"
        // A dying attach must leave a visible corpse (exit banner), not
        // silently close the surface — an empty surface tree closes the whole
        // window, which reads as the app crashing.
        config.waitAfterCommand = true
        return config
    }

    /// Shows the connecting overlay over the new tab's terminal and hides it
    /// once the daemon reports a client attached to the session (checked on
    /// a quick dedicated poll), or after a timeout — reconnect-loop output
    /// is intentional UX, so a slow attach becomes visible rather than
    /// hidden forever.
    @MainActor
    private func showConnecting(
        on controller: TerminalController,
        identity: HauntedClientIdentity,
        target: String,
        sessionName: String
    ) {
        guard let container = controller.window?.contentView
            as? HauntedContainerView else { return }
        let daemon = target.split(separator: "/").dropFirst().first
            .map(String.init) ?? target
        container.showConnectingOverlay(text: "Connecting to \(daemon)…")

        Task { @MainActor [weak container] in
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let sessions = try? await HauntedCLI.sessions(
                    identity: identity, target: target),
                   sessions.contains(where: { $0.name == sessionName && $0.clients > 0 }) {
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            container?.hideConnectingOverlay()
        }
    }

    // MARK: Sidebar

    @MainActor
    private func attachSidebar(
        to controller: TerminalController,
        identity: HauntedClientIdentity
    ) {
        guard let window = controller.window,
              let terminalView = window.contentView,
              !(terminalView is HauntedContainerView) else { return }

        let sidebar = HauntedSidebarView(identity: identity) { [weak self, weak controller] workstation, sessionName in
            guard let self, let controller else { return }
            Task { @MainActor in
                self.focusOrOpen(from: controller,
                                 workstation: workstation,
                                 sessionName: sessionName)
            }
        }
        window.contentView = HauntedContainerView(
            sidebar: NSHostingView(rootView: sidebar),
            terminal: terminalView)
    }
}

extension Notification.Name {
    /// Posted after this app opens or kills a session, so the sidebar can
    /// refresh right away instead of waiting out its poll interval.
    static let hauntedSessionsDidChange =
        Notification.Name("HauntedSessionsDidChange")
}

/// Sidebar geometry shared by every window/tab: the user's chosen width and
/// whether the sidebar is collapsed to its thin icon strip. Persisted, and
/// observable both by the SwiftUI sidebar (to render the collapsed strip and
/// the toggle button) and by each window's HauntedContainerView (to drive
/// the AppKit width constraint) — so a resize or toggle in one tab applies
/// to all of them.
@MainActor
final class HauntedSidebarLayout: ObservableObject {
    static let shared = HauntedSidebarLayout()
    static let collapsedWidth: CGFloat = 30
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 480

    /// Duration of the width animation; content fade is sequenced around it.
    static let animationDuration: TimeInterval = 0.2

    /// Where `width`/`collapsed` persist. Injectable so tests get a scratch
    /// suite instead of poisoning the user's real sidebar geometry.
    private let defaults: UserDefaults

    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: "HauntedSidebarWidth") }
    }
    /// The persisted collapsed state — drives the sidebar WIDTH. Restored on
    /// launch, so quitting collapsed reopens collapsed.
    @Published var collapsed: Bool {
        didSet { defaults.set(collapsed, forKey: "HauntedSidebarCollapsed") }
    }
    /// Transient: whether the full sidebar CONTENT is shown (opacity 1) vs.
    /// faded out. Sequenced separately from `collapsed` so the content fades
    /// in only after the sidebar finishes widening, and fades out before it
    /// narrows — never scaling/clipping mid-transition.
    @Published var contentVisible: Bool

    /// Where the *user* last asked to be, as opposed to where the animation has
    /// got to. `collapsed` and `contentVisible` each lag it by one animation
    /// step, so neither can answer "did the user change their mind?" — see
    /// setCollapsed.
    private var desiredCollapsed: Bool

    var effectiveWidth: CGFloat { collapsed ? Self.collapsedWidth : width }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: "HauntedSidebarWidth")
        width = saved >= Self.minWidth ? min(CGFloat(saved), Self.maxWidth) : 220
        let startCollapsed = defaults.bool(forKey: "HauntedSidebarCollapsed")
        collapsed = startCollapsed
        contentVisible = !startCollapsed
        desiredCollapsed = startCollapsed
    }

    /// Toggle/collapse with the fade sequencing:
    ///  - expand:  widen first (content hidden), then fade content in;
    ///  - collapse: fade content out first, then narrow.
    ///
    /// Both deferred closures re-check `desiredCollapsed`, not the property they
    /// are about to write. Guarding on `contentVisible`/`collapsed` instead would
    /// strand a reversal made inside the animation window: collapsing sets
    /// `contentVisible = false` but leaves `collapsed == false` until the closure
    /// runs, so an immediate `setCollapsed(false)` saw "already expanded", took
    /// the early return, and the pending closure then collapsed the sidebar the
    /// user had just asked to reopen.
    func setCollapsed(_ value: Bool) {
        guard value != desiredCollapsed else { return }
        desiredCollapsed = value
        if value {
            contentVisible = false // view fades out over animationDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration) {
                if self.desiredCollapsed { self.collapsed = true }
            }
        } else {
            collapsed = false // width animates open
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.animationDuration + 0.02) {
                if !self.desiredCollapsed { self.contentVisible = true }
            }
        }
    }

    /// Width proposal from the drag divider. Dragging a collapsed sidebar
    /// open past a small threshold expands it — the natural gesture when the
    /// strip is too thin to host much UI.
    func propose(width proposed: CGFloat) {
        if collapsed {
            if proposed > Self.minWidth / 2 {
                width = max(Self.minWidth, min(proposed, Self.maxWidth))
                setCollapsed(false)
            }
            return
        }
        width = max(Self.minWidth, min(proposed, Self.maxWidth))
    }
}

/// The grab handle between sidebar and terminal: shows a resize cursor,
/// drags the sidebar width, double-click toggles collapsed.
final class HauntedSidebarDivider: NSView {
    var onPropose: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        line.intersection(dirtyRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStartX = event.locationInWindow.x
        dragStartWidth = HauntedSidebarLayout.shared.effectiveWidth
    }

    override func mouseDragged(with event: NSEvent) {
        onPropose?(dragStartWidth + (event.locationInWindow.x - dragStartX))
    }
}

/// Workstation sidebar on the left (user-resizable, collapsible to a thin
/// strip), a drag divider, and the terminal filling the rest.
final class HauntedContainerView: NSView {
    private let terminalArea: NSView
    private var connectingOverlay: NSView?
    private var emptyStateView: NSView?
    private var sidebarWidth: NSLayoutConstraint!
    private var wasCollapsed: Bool
    private var layoutObserver: AnyCancellable?

    init(sidebar: NSView, terminal: NSView) {
        terminalArea = terminal
        wasCollapsed = HauntedSidebarLayout.shared.collapsed
        super.init(frame: terminal.frame)
        let divider = HauntedSidebarDivider()
        addSubview(sidebar)
        addSubview(divider)
        addSubview(terminal)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        sidebarWidth = sidebar.widthAnchor.constraint(
            equalToConstant: HauntedSidebarLayout.shared.effectiveWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidth,
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 6),
            terminal.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        divider.onPropose = { HauntedSidebarLayout.shared.propose(width: $0) }
        divider.onDoubleClick = {
            let l = HauntedSidebarLayout.shared
            l.setCollapsed(!l.collapsed)
        }
        layoutObserver = HauntedSidebarLayout.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Collapse/expand animates; live drag tracks the cursor directly.
    private func applyLayout() {
        let layout = HauntedSidebarLayout.shared
        let target = layout.effectiveWidth
        if layout.collapsed != wasCollapsed {
            wasCollapsed = layout.collapsed
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = HauntedSidebarLayout.animationDuration
                ctx.allowsImplicitAnimation = true
                sidebarWidth.animator().constant = target
                layoutSubtreeIfNeeded()
            }
        } else if sidebarWidth.constant != target {
            sidebarWidth.constant = target
        }
        window?.invalidateCursorRects(for: self)
    }

    /// Covers the terminal area (not the sidebar) while an attach is being
    /// established, hiding shell startup and the typed attach command until
    /// the remote session actually paints.
    func showConnectingOverlay(text: String) {
        hideConnectingOverlay(animated: false)

        let overlay = NSVisualEffectView()
        overlay.material = .windowBackground
        overlay.blendingMode = .withinWindow
        overlay.state = .active

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        overlay.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor),
            overlay.topAnchor.constraint(equalTo: terminalArea.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor),
            overlay.trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        connectingOverlay = overlay
    }

    func hideConnectingOverlay(animated: Bool = true) {
        guard let overlay = connectingOverlay else { return }
        connectingOverlay = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                overlay.animator().alphaValue = 0
            }, completionHandler: { overlay.removeFromSuperview() })
        } else {
            overlay.removeFromSuperview()
        }
    }

    /// The "Nothing here" state: covers the terminal area (not the sidebar) with
    /// a placeholder when the window has no attached session — at startup with
    /// nothing to resume, or after the last session in the window is killed.
    /// Idempotent, so a redundant show is a no-op rather than a stack of covers.
    func showEmptyState() {
        // A stale connecting overlay would sit on top of the placeholder.
        hideConnectingOverlay(animated: false)
        guard emptyStateView == nil else { return }

        let overlay = NSVisualEffectView()
        overlay.material = .windowBackground
        overlay.blendingMode = .withinWindow
        overlay.state = .active

        let label = NSTextField(labelWithString: "Nothing here")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        overlay.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor),
            overlay.topAnchor.constraint(equalTo: terminalArea.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor),
            overlay.trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        emptyStateView = overlay
    }

    func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
    }
}
