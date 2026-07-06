import AppKit
import SwiftUI
import GhosttyKit

/// Haunted Console integration: a login window that authenticates against a
/// Haunted Console (URL + username + password) and opens a terminal window
/// attached to one of the user's daemons through the Console relay.
///
/// The password never reaches the terminal: the login exchange happens here
/// and only the short-lived session token is handed to the spawned
/// `haunted-console-connect` process via its environment.
///
/// This feature is intentionally self-contained so the fork delta against
/// upstream Ghostty stays small.
final class HauntedLoginController: NSWindowController {
    static let shared = HauntedLoginController()

    /// Installs the "Connect to Haunted…" item in the File menu. Called once
    /// from applicationDidFinishLaunching. The startup window itself is opened
    /// by `startup()` from applicationDidBecomeActive.
    static func install() {
        installMenuItem()
    }

    /// Entry point for launch, dock-reopen, and ⌘N. The app is always in
    /// Haunted mode: focus an existing Haunted window, else restore a stored
    /// session, else prompt for login. It never opens a plain local terminal.
    @MainActor
    static func startup() {
        if HauntedManager.shared.focusExistingWindow() { return }
        guard HauntedKeychain.load() != nil else {
            shared.showLogin(nil)
            return
        }
        restoreStoredSession(onFailure: { shared.showLogin(nil) })
    }

    /// If the Keychain holds a valid refresh token, opens the Haunted window
    /// without prompting for a password; otherwise runs `onFailure`.
    private static func restoreStoredSession(onFailure: @escaping @MainActor () -> Void) {
        guard let stored = HauntedKeychain.load() else {
            Task { @MainActor in onFailure() }
            return
        }
        NSLog("[haunted] restore: found stored session for %@", stored.consoleURL)
        Task { @MainActor in
            let session = HauntedSession(
                consoleURL: stored.consoleURL,
                refreshToken: stored.refreshToken)
            do {
                _ = try await session.accessToken()
            } catch {
                NSLog("[haunted] restore: refresh failed (%@); prompting login", "\(error)")
                HauntedKeychain.clear(consoleURL: stored.consoleURL)
                onFailure()
                return
            }
            let daemons = (try? await HauntedConsoleAPI.daemons(
                consoleURL: stored.consoleURL,
                token: try await session.accessToken())) ?? []
            NSLog("[haunted] restore: opening window with %d daemon(s)", daemons.count)
            await HauntedManager.shared.openWindow(session: session, daemons: daemons)
        }
    }

    private static func installMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let fileMenu = mainMenu.item(withTitle: "File")?.submenu
            ?? (mainMenu.items.count > 1 ? mainMenu.items[1].submenu : nil)
        guard let fileMenu else { return }

        let item = NSMenuItem(
            title: "Connect to Haunted…",
            action: #selector(showLogin(_:)),
            keyEquivalent: "L")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = shared
        fileMenu.insertItem(NSMenuItem.separator(), at: 0)
        fileMenu.insertItem(item, at: 0)
    }

    private init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Connect to Haunted"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = HauntedLoginView { [weak self] consoleURL, tokens in
            self?.openTerminal(consoleURL: consoleURL, tokens: tokens)
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

    /// Persists the refresh token and opens the Haunted terminal window
    /// (daemon sidebar plus a tab attached to the first online daemon).
    private func openTerminal(consoleURL: String, tokens: HauntedTokens) {
        HauntedKeychain.save(.init(
            consoleURL: consoleURL, refreshToken: tokens.refreshToken))
        let session = HauntedSession(
            consoleURL: consoleURL,
            refreshToken: tokens.refreshToken,
            initialAccess: tokens.accessToken,
            initialExpiry: tokens.accessExpiresAt)
        Task { @MainActor in
            let daemons = (try? await HauntedConsoleAPI.daemons(
                consoleURL: consoleURL, token: tokens.accessToken)) ?? []
            await HauntedManager.shared.openWindow(session: session, daemons: daemons)
            self.window?.close()
        }
    }
}

struct HauntedLoginView: View {
    @State private var consoleURL = UserDefaults.standard.string(
        forKey: "HauntedConsoleURL") ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var busy = false

    let onAuthenticated: (String, HauntedTokens) -> Void

    private var submitDisabled: Bool {
        busy || consoleURL.isEmpty || username.isEmpty || password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Haunted Console")
                .font(.headline)
            Text("Sign in to list your daemons and attach to a session.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Console URL (https://…)", text: $consoleURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { signIn() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func signIn() {
        guard !submitDisabled else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let tokens = try await HauntedConsoleAPI.login(
                    consoleURL: consoleURL,
                    username: username,
                    password: password)
                UserDefaults.standard.set(consoleURL, forKey: "HauntedConsoleURL")
                password = ""
                onAuthenticated(consoleURL, tokens)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A daemon owned by the authenticated account, as reported by the Console.
struct HauntedDaemon: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let online: Bool
}

/// A session running on a daemon, as reported by the Console.
struct HauntedDaemonSession: Decodable, Identifiable, Equatable {
    let name: String
    let attachedClients: Int
    let cols: Int
    let rows: Int

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case attachedClients = "attached_clients"
        case cols
        case rows
    }
}

/// The token pair returned by a successful login.
struct HauntedTokens {
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
}

enum HauntedConsoleAPI {
    private struct LoginResponse: Decodable {
        let accessToken: String
        let expiresAt: Date
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
            case refreshToken = "refresh_token"
        }
    }

    private struct ErrorResponse: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }

        let error: Payload
    }

    /// Validates the Console base URL. Credentials and tokens travel on
    /// these requests: require TLS everywhere except explicit loopback
    /// development consoles.
    private static func baseURL(_ consoleURL: String) throws -> URL {
        guard let base = URL(string: consoleURL), let scheme = base.scheme else {
            throw loginError("enter a valid https Console URL")
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        switch scheme {
        case "https":
            return base
        case "http" where loopbackHosts.contains(base.host ?? ""):
            return base
        case "http":
            throw loginError("http is only allowed for localhost consoles; use https://")
        default:
            throw loginError("enter a valid https Console URL")
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }

    static func login(
        consoleURL: String,
        username: String,
        password: String
    ) async throws -> HauntedTokens {
        let base = try baseURL(consoleURL)
        var request = URLRequest(
            url: base.appendingPathComponent("v1/sessions"),
            timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ["username": username, "password": password])

        let data = try await send(request)
        let response = try decoder.decode(LoginResponse.self, from: data)
        guard let refresh = response.refreshToken else {
            throw loginError("Console did not issue a refresh token")
        }
        return HauntedTokens(
            accessToken: response.accessToken,
            accessExpiresAt: response.expiresAt,
            refreshToken: refresh)
    }

    /// Exchanges a persistent refresh token for a fresh access token.
    static func refresh(
        consoleURL: String,
        refreshToken: String
    ) async throws -> (token: String, expiresAt: Date) {
        let base = try baseURL(consoleURL)
        var request = URLRequest(
            url: base.appendingPathComponent("v1/tokens"),
            timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        let response = try decoder.decode(LoginResponse.self, from: data)
        return (response.accessToken, response.expiresAt)
    }

    /// Lists the account's daemons with their online state.
    static func daemons(
        consoleURL: String,
        token: String
    ) async throws -> [HauntedDaemon] {
        struct Response: Decodable {
            let daemons: [HauntedDaemon]
        }

        let base = try baseURL(consoleURL)
        var request = URLRequest(
            url: base.appendingPathComponent("v1/daemons"),
            timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        return try decoder.decode(Response.self, from: data).daemons
    }

    /// Lists the sessions running on a daemon.
    static func daemonSessions(
        consoleURL: String,
        token: String,
        daemonID: String
    ) async throws -> [HauntedDaemonSession] {
        struct Response: Decodable {
            let sessions: [HauntedDaemonSession]
        }

        let base = try baseURL(consoleURL)
        var request = URLRequest(
            url: base.appendingPathComponent("v1/daemons/\(daemonID)/sessions"),
            timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        return try decoder.decode(Response.self, from: data).sessions
    }

    /// Kills a session on a daemon.
    static func killSession(
        consoleURL: String,
        token: String,
        daemonID: String,
        sessionName: String
    ) async throws {
        let base = try baseURL(consoleURL)
        let encoded = sessionName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? sessionName
        var request = URLRequest(
            url: base.appendingPathComponent("v1/daemons/\(daemonID)/sessions/\(encoded)"),
            timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw loginError("unexpected response from Console")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw loginError(decoded.error.message)
            }
            throw loginError("request failed (HTTP \(http.statusCode))")
        }
        return data
    }

    private static func loginError(_ message: String) -> NSError {
        NSError(
            domain: "com.thenets.haunted",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// Decodes RFC 3339 timestamps with fractional seconds, matching the
    /// Console's `time.RFC3339Nano` output.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "invalid date: \(text)"))
        }
    }
}
