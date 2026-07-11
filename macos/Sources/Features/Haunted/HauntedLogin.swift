import AppKit
import SwiftUI
import GhosttyKit

/// DedMesh Console integration: startup refuses to open a terminal until the
/// app has an enrolled client identity in ~/.config/haunted.
final class HauntedLoginController: NSWindowController {
    static let shared = HauntedLoginController()

    /// Installs the "Log in with DedMesh Console…" item in the File menu.
    /// Called once from applicationDidFinishLaunching. The startup window
    /// itself is opened by `startup()` from applicationDidBecomeActive.
    static func install() {
        installMenuItem()
    }

    /// Entry point for launch, dock-reopen, and ⌘N. The app is always in
    /// Haunted mode: focus an existing Haunted window, else auto-connect with
    /// the enrolled identity, else prompt for enrollment. It never opens a
    /// plain local terminal.
    @MainActor
    static func startup() {
        if HauntedManager.shared.focusExistingWindow() { return }
        guard let identity = HauntedClientIdentity.load() else {
            shared.showLogin(nil)
            return
        }
        connect(identity: identity)
    }

    /// Auto-connect: only open a Haunted window after the enrolled identity
    /// can authenticate and list workstations. Offline workstations still mean
    /// the user is logged in; show the Haunted window/sidebar instead of
    /// returning to login. A revoked/broken identity falls back to login.
    @MainActor
    private static func connect(identity: HauntedClientIdentity) {
        Task { @MainActor in
            let justStarted = await HauntedWorkstationSupervisor.ensureRunning()
            do {
                let workstations = justStarted
                    ? try await waitForOnline(identity: identity)
                    : try await HauntedCLI.workstations(identity: identity)
                NSLog("[haunted] startup: %d workstation(s) via %@",
                      workstations.count, identity.consoleHost)
                // Only fetch the last target's sessions when it is actually
                // online — the router needs the list to confirm the remembered
                // session still exists before resuming it (else it must never
                // create one, so it lands on the empty state instead).
                let lastSessions = await lastSessions(
                    identity: identity, workstations: workstations)
                HauntedManager.shared.openWindow(
                    identity: identity, workstations: workstations,
                    lastSessions: lastSessions)
            } catch {
                NSLog("[haunted] startup: workstation list failed (%@)",
                      "\(error)")
                shared.showLoginMessage(error.localizedDescription)
            }
        }
    }

    /// The sessions on the last-attached workstation, or `[]` when there is no
    /// remembered target or it is not currently online. The router uses this to
    /// decide whether the remembered session still exists (resume) or is gone
    /// (empty state); a failed list is treated as "no sessions", i.e. empty.
    @MainActor
    private static func lastSessions(
        identity: HauntedClientIdentity,
        workstations: [HauntedWorkstation]
    ) async -> [HauntedWorkstationSession] {
        guard let target = HauntedManager.shared.lastAttachedTarget,
              workstations.contains(where: { $0.target == target && $0.online })
        else { return [] }
        return (try? await HauntedCLI.sessions(
            identity: identity, target: target)) ?? []
    }

    /// Right after a cold-launch spawn of the local workstation daemons,
    /// dedmeshd still needs a moment to connect to the console and register —
    /// give it a few quick retries before falling back to a plain shell, so
    /// launching Haunted lands directly on the local workstation instead of
    /// requiring the user to reopen it once it comes online.
    @MainActor
    private static func waitForOnline(
        identity: HauntedClientIdentity
    ) async throws -> [HauntedWorkstation] {
        var workstations: [HauntedWorkstation] = []
        for attempt in 0..<6 {
            workstations = try await HauntedCLI.workstations(identity: identity)
            if workstations.contains(where: { $0.online }) { break }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return workstations
    }

    private static func installMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let fileMenu = mainMenu.item(withTitle: "File")?.submenu
            ?? (mainMenu.items.count > 1 ? mainMenu.items[1].submenu : nil)
        guard let fileMenu else { return }

        let item = NSMenuItem(
            title: "Log in with DedMesh Console…",
            action: #selector(showLogin(_:)),
            keyEquivalent: "L")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = shared
        fileMenu.insertItem(NSMenuItem.separator(), at: 0)
        fileMenu.insertItem(item, at: 0)
    }

    private init() {
        let window = HauntedEditableWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Log in with DedMesh Console"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = HauntedLoginView { [weak self] in
            self?.openTerminal()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc func showLogin(_ sender: Any?) {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func showLoginMessage(_ message: String) {
        if let hosting = window?.contentViewController as? NSHostingController<HauntedLoginView> {
            hosting.rootView = HauntedLoginView(initialMessage: message) { [weak self] in
                self?.openTerminal()
            }
        }
        showLogin(nil)
    }

    /// Login finished: the state dir now holds the certificate. Auto-connect
    /// and close the login window.
    private func openTerminal() {
        guard let identity = HauntedClientIdentity.load() else { return }
        Task { @MainActor in
            Self.connect(identity: identity)
            self.window?.close()
        }
    }
}

/// A standalone window that handles the standard editing shortcuts itself.
///
/// The Terminal's main menu binds ⌘V/⌘C/⌘X to Ghostty's *terminal* paste/copy
/// actions. When this login window is key there is no terminal surface in the
/// responder chain, so those menu items are disabled — and a disabled menu
/// item with a key equivalent SWALLOWS the shortcut, so ⌘V never reaches the
/// login text field's editor (the reason the code field could not be pasted
/// into). `performKeyEquivalent` runs before the main menu gets the event, so
/// routing the standard editing selectors to the first responder here wins.
final class HauntedEditableWindow: NSWindow {
    /// The editing selector a ⌘-<key> chord should send to the first responder,
    /// or nil if it is not an editing shortcut. Pure, so it is unit-tested
    /// (LGED-01) without a live window.
    static func editingSelector(forCommandKey key: String) -> Selector? {
        switch key {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSResponder.selectAll(_:))
        case "z": return Selector(("undo:"))
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let key = event.charactersIgnoringModifiers,
           let selector = Self.editingSelector(forCommandKey: key),
           NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct HauntedLoginView: View {
    // The console a fresh install signs in to. A SHIPPED build (the DMG on
    // releases.dednets.com) must default to production; every dev build —
    // Xcode Debug, `make haunted-run` — defaults to staging so local work
    // never enrolls a Terminal against the production console by accident.
    //
    // The discriminator is HAUNTED_RELEASE, a compilation condition that ONLY
    // scripts/build-app-dist.sh injects (via SWIFT_ACTIVE_COMPILATION_CONDITIONS).
    // Keying on it — not `#if DEBUG` — is deliberate: `make haunted-run` builds
    // the ReleaseLocal config, identical to an ad-hoc release, so a config check
    // can't tell dev from shipped. Guarded by HauntedLoginDefaultTests (staging
    // in every non-release build) and the strings gate in build-app-dist.sh
    // (production in the shipped bundle, never staging).
    #if HAUNTED_RELEASE
    static let defaultConsoleURL = "https://console.dednets.com"
    #else
    static let defaultConsoleURL = "https://console.staging.dednets.com"
    #endif

    @State private var consoleURL = UserDefaults.standard.string(
        forKey: "HauntedConsoleURL") ?? HauntedLoginView.defaultConsoleURL
    @State private var requestID = ""
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var waitingForCode = false

    let onLoggedIn: () -> Void

    /// The whole login flow — start, then redeem inside `HauntedCLI.login` —
    /// runs over this one session, so a test can stand the console up in-process.
    private let session: URLSession

    init(
        initialMessage: String? = nil,
        session: URLSession = .shared,
        onLoggedIn: @escaping () -> Void
    ) {
        self.onLoggedIn = onLoggedIn
        self.session = session
        _errorMessage = State(initialValue: initialMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DedMesh Console")
                .font(.headline)
            Text("Log in once. Haunted stores the Terminal certificate in ~/.config/haunted and connects automatically after that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Console URL", text: $consoleURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(waitingForCode || busy)

            if waitingForCode {
                TextField("8-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: code) { value in
                        code = String(value.filter(\.isNumber).prefix(8))
                    }
                    .onSubmit { finishLogin() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }

            HStack {
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(waitingForCode ? "Finish Login" : "Log In") {
                    waitingForCode ? finishLogin() : beginLogin()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || consoleURL.isEmpty || (waitingForCode && code.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func beginLogin() {
        guard !busy, let url = URL(string: consoleURL), url.isAllowedConsoleScheme else {
            errorMessage = "Enter an https:// Console URL."
            return
        }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let request = try await HauntedClientLoginAPI.start(
                    consoleURL: url, session: session)
                guard let approvalURL = request.approvalURL(base: url) else {
                    throw HauntedCLIError(message: "Console returned an invalid approval URL.")
                }
                requestID = request.id
                waitingForCode = true
                UserDefaults.standard.set(consoleURL, forKey: "HauntedConsoleURL")
                NSWorkspace.shared.open(approvalURL)
                errorMessage = "Approve the request in the Console, then enter the temporary code here."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishLogin() {
        guard !busy, let url = URL(string: consoleURL), !requestID.isEmpty else {
            return
        }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await HauntedCLI.login(
                    consoleURL: url,
                    requestID: requestID,
                    code: code,
                    session: session)
                code = ""
                requestID = ""
                waitingForCode = false
                onLoggedIn()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
