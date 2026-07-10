import Foundation
import Security

/// The enrolled DedMesh client identity on disk. Enrollment (`haunted enroll`)
/// stores an mTLS key + certificate plus the console address and a CA copy in
/// the state dir, so holding a state dir with a certificate is the entire
/// "logged in" state — there are no passwords or tokens in the GUI.
struct HauntedClientIdentity: Equatable {
    let stateDir: URL
    /// Console control address (host:port), read from the persisted settings.
    /// Display only; the CLI resolves it from the state dir itself.
    let console: String?

    /// A function of the injected filesystem, not a stored property: the home
    /// directory it hangs off is unmovable in a test (see HauntedFileSystem).
    static func defaultStateDir(_ fs: HauntedFileSystem = .real) -> URL {
        fs.homeDirectory
            .appendingPathComponent(".config/haunted", isDirectory: true)
    }

    static func legacyStateDir(_ fs: HauntedFileSystem = .real) -> URL {
        fs.homeDirectory
            .appendingPathComponent(".config/haunted/client", isDirectory: true)
    }

    /// Returns the identity if the default state dir holds an enrolled
    /// certificate, else nil (enrollment needed).
    static func load(fs: HauntedFileSystem = .real) -> HauntedClientIdentity? {
        let dir = [defaultStateDir(fs), legacyStateDir(fs)].first { hasLogin($0, fs) }
            ?? defaultStateDir(fs)
        guard hasLogin(dir, fs) else { return nil }
        struct Settings: Decodable { let console: String? }
        var console: String?
        let settings = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settings),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            console = decoded.console
        }
        return HauntedClientIdentity(stateDir: dir, console: console)
    }

    private static func hasLogin(_ dir: URL, _ fs: HauntedFileSystem) -> Bool {
        let cert = dir.appendingPathComponent("cert.pem")
        let key = dir.appendingPathComponent("key.pem")
        let settings = dir.appendingPathComponent("settings.json")
        let ca = dir.appendingPathComponent("ca.pem")
        for url in [cert, key, settings, ca] {
            guard fs.isReadableFile(atPath: url.path) else {
                return false
            }
        }
        return true
    }
}

struct HauntedClientLoginStart: Decodable {
    let id: String
    let url: String
}

struct HauntedClientLoginRedeem: Decodable {
    let token: String
    let username: String
    let clientName: String
    let controlPort: String
    let caPEM: String

    enum CodingKeys: String, CodingKey {
        case token
        case username
        case clientName = "client_name"
        case controlPort = "control_port"
        case caPEM = "ca_pem"
    }
}

extension URL {
    /// The client-login flow exchanges a redeemable code for an mTLS client
    /// certificate, so a plaintext hop is a credential-interception risk.
    /// Loopback stays allowed over http for local console dev.
    var isAllowedConsoleScheme: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        return loopbackHosts.contains(host?.lowercased() ?? "")
    }
}

enum HauntedClientLoginAPI {
    /// What the console shows the user when approving this device. A live
    /// lookup against the local machine, hoisted out of `start` so the request
    /// body a test asserts on is a value the test chose.
    static func defaultDeviceLabel() -> String {
        Host.current().localizedName ?? Host.current().name ?? "terminal"
    }

    static func start(
        consoleURL: URL,
        session: URLSession = .shared,
        deviceLabel: String = defaultDeviceLabel()
    ) async throws -> HauntedClientLoginStart {
        try await post(
            consoleURL: consoleURL,
            path: "/api/v0/client-login/start",
            body: ["client_name": "term", "device_label": deviceLabel],
            session: session
        )
    }

    static func redeem(
        consoleURL: URL,
        id: String,
        code: String,
        session: URLSession = .shared
    ) async throws -> HauntedClientLoginRedeem {
        try await post(
            consoleURL: consoleURL,
            path: "/api/v0/client-login/redeem",
            body: ["id": id, "code": code],
            session: session
        )
    }

    private static func post<T: Decodable>(
        consoleURL: URL,
        path: String,
        body: [String: String],
        session: URLSession
    ) async throws -> T {
        guard consoleURL.isAllowedConsoleScheme else {
            throw HauntedCLIError(message: "Console URL must use https")
        }
        guard var components = URLComponents(url: consoleURL, resolvingAgainstBaseURL: false) else {
            throw HauntedCLIError(message: "Invalid Console URL")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw HauntedCLIError(message: "Invalid Console URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HauntedCLIError(message: "No HTTP response from Console")
        }
        guard http.statusCode < 300 else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HauntedCLIError(message: text.isEmpty
                ? "Console returned HTTP \(http.statusCode)"
                : text)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension HauntedClientLoginStart {
    /// The browser URL that approves this login request. The console chooses
    /// this string, so a compromised or MITM'd console would otherwise pick
    /// what `NSWorkspace.shared.open` launches — `javascript:`, `file://` or
    /// any registered app scheme. Only http(s) console origins may escape into
    /// the browser; everything else is rejected rather than opened.
    func approvalURL(base consoleURL: URL) -> URL? {
        if let absolute = URL(string: url), absolute.scheme != nil {
            return absolute.isAllowedConsoleScheme ? absolute : nil
        }
        guard var components = URLComponents(url: consoleURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if let rel = URL(string: url), url.hasPrefix("/") {
            components.path = rel.path
            components.query = rel.query
            guard let resolved = components.url, resolved.isAllowedConsoleScheme else {
                return nil
            }
            return resolved
        }
        return nil
    }
}

extension HauntedClientIdentity {
    /// The console's host, for display. Splitting on the first `:` would cut a
    /// bracketed IPv6 literal in half (`"[::1]:9443"` → `"["`), so parse the
    /// value as a URL authority instead.
    ///
    /// Note `URLComponents.host` *keeps* the brackets (`"[::1]"`) while
    /// `URL.host` strips them (`"::1"` — which is what isAllowedConsoleScheme's
    /// loopback set matches against). The two APIs disagree; the bracketed form
    /// is the right one to show a human, so do not "unify" them.
    var consoleHost: String {
        guard let console else { return "DedMesh" }
        return URLComponents(string: "//\(console)")?.host ?? console
    }

    /// The enrolled identity ("username/client-name") from the client
    /// certificate's CN — the same subject the console authenticates, so the
    /// sidebar shows exactly who the mesh thinks we are. Nil if the cert is
    /// unreadable (the caller should fall back to omitting the line).
    ///
    /// Only the *first* PEM block is decoded. `cert.pem` may hold a chain
    /// (leaf + intermediates); concatenating every block's base64 and decoding
    /// the result yields either the leaf alone (when its DER length happens to
    /// be a multiple of 3) or, more often, invalid DER — and the sidebar
    /// silently drops the identity line. The leaf is always first.
    /// The signed-in username: the certificate CN's first component
    /// ("username/client-name"). Nil when the cert is unreadable.
    var username: String? {
        certIdentity?.components(separatedBy: "/").first
    }

    var certIdentity: String? {
        let certFile = stateDir.appendingPathComponent("cert.pem")
        guard let pem = try? String(contentsOf: certFile, encoding: .utf8) else {
            return nil
        }
        var base64 = ""
        var inCertificate = false
        for line in pem.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN CERTIFICATE") {
                inCertificate = true
            } else if trimmed.hasPrefix("-----END CERTIFICATE") {
                break // leaf complete; ignore any intermediates that follow
            } else if inCertificate, !trimmed.isEmpty {
                base64 += trimmed
            }
        }
        guard !base64.isEmpty,
              let der = Data(base64Encoded: base64),
              let cert = SecCertificateCreateWithData(nil, der as CFData)
        else { return nil }
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        return cn as String?
    }
}

/// A workstation this client may reach, as listed by
/// `dedmeshctl workstations -json`.
struct HauntedWorkstation: Decodable, Identifiable, Equatable {
    let target: String // username/daemon/app — pass to attach
    let daemon: String // display name
    let app: String
    let online: Bool
    let state: String?
    let error: String?
    /// The console-stored display color ("#rrggbb", validated at the decode
    /// boundary — see normalizedColor); nil = default. Old `dedmeshctl` /
    /// console builds omit it entirely.
    let color: String?

    init(
        target: String, daemon: String, app: String, online: Bool,
        state: String?, error: String?, color: String? = nil
    ) {
        self.target = target
        self.daemon = daemon
        self.app = app
        self.online = online
        self.state = state
        self.error = error
        self.color = color
    }

    var id: String { target }
    var status: String {
        if online {
            return "online"
        }
        if let state, state != "active" {
            return state
        }
        return "offline"
    }

    /// Canonicalizes a display color coming out of remote-controlled JSON:
    /// exactly `#` + six ASCII hex digits, lowercased; anything else — wrong
    /// length, wrong characters, fullwidth lookalikes — degrades to nil (the
    /// default tint) rather than reaching the UI. Byte-wise on UTF-8 like
    /// isValidSessionName, so no Unicode "hex digit" generosity applies.
    static func normalizedColor(_ value: String?) -> String? {
        guard let value else { return nil }
        let lower = value.lowercased()
        let bytes = Array(lower.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return nil }
        for byte in bytes.dropFirst() {
            let isHex = (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            guard isHex else { return nil }
        }
        return lower
    }

    /// A copy whose color survived normalization (nil otherwise). Applied at
    /// the decode boundary so nothing downstream ever sees a raw color.
    func normalizingColor() -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: daemon, app: app, online: online,
            state: state, error: error, color: Self.normalizedColor(color))
    }

    /// A copy carrying `color` verbatim — the optimistic local recolor (the
    /// caller passes an already-normalized palette value or nil).
    func withColor(_ color: String?) -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: daemon, app: app, online: online,
            state: state, error: error, color: color)
    }
}

/// A session running on a workstation's Haunted daemon, as listed by
/// `haunted list --target … --json`.
struct HauntedWorkstationSession: Decodable, Identifiable, Equatable {
    let name: String
    let pid: UInt32
    let clients: Int
    let cols: Int
    let rows: Int
    let created: UInt64
    /// The session's terminal title (OSC 0/2, else its foreground process
    /// name). Absent from daemons predating MSG_SESSION_LIST_V2.
    let title: String?

    var id: String { name }

    /// What the sidebar shows: the human-facing title when the daemon knows
    /// one, else the session name (IDs like gui-1a2b3c4d mean nothing).
    /// Titles are attacker-influenced (any program in the session sets them),
    /// so control and format characters — C0/C1, DEL, bidi overrides that
    /// could visually spoof a row — are stripped before display. The `name`
    /// fallback needs no stripping: isValidSessionName rejected anything
    /// outside [A-Za-z0-9_-] at the decode boundary.
    var displayTitle: String {
        guard let title, !title.isEmpty else { return name }
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate: return false
            default: return true
            }
        }))
        return cleaned.isEmpty ? name : cleaned
    }
}

/// One row of `dedmeshctl workstations -json -sessions`: the flat workstation
/// ref plus the console's snapshot session summaries and — for workstations
/// the call queried live — the fresh titled list. Exactly one of `live` /
/// `liveError` is present for a queried workstation; both absent means "not
/// queried this round" (a collapsed row), and `live: []` means "queried, zero
/// sessions" — the caller must clear its cache, not keep stale rows.
struct HauntedWorkstationListing: Decodable, Equatable {
    let workstation: HauntedWorkstation
    /// The console's last-snapshot summaries (≤30s stale, never titled).
    let sessions: [HauntedWorkstationSession]
    /// The fresh end-to-end list (titles included), when queried.
    let live: [HauntedWorkstationSession]?
    let liveError: String?

    enum CodingKeys: String, CodingKey {
        case sessions
        case live
        case liveError = "live_error"
    }

    init(
        workstation: HauntedWorkstation,
        sessions: [HauntedWorkstationSession] = [],
        live: [HauntedWorkstationSession]? = nil,
        liveError: String? = nil
    ) {
        self.workstation = workstation
        self.sessions = sessions
        self.live = live
        self.liveError = liveError
    }

    init(from decoder: Decoder) throws {
        // The ref keys are flat on the same object (pinned by a golden test
        // on the Go side), so the workstation decodes from the same decoder.
        workstation = try HauntedWorkstation(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(
            [HauntedWorkstationSession].self, forKey: .sessions) ?? []
        live = try container.decodeIfPresent(
            [HauntedWorkstationSession].self, forKey: .live)
        liveError = try container.decodeIfPresent(String.self, forKey: .liveError)
    }

    /// A copy that survived the decode boundary: color normalized, session
    /// records with names outside the daemon grammar dropped (both lists are
    /// remote-controlled JSON, same rules as decodeSessions).
    func sanitized() -> HauntedWorkstationListing {
        HauntedWorkstationListing(
            workstation: workstation.normalizingColor(),
            sessions: sessions.filter { isValidSessionName($0.name) },
            live: live.map { $0.filter { isValidSessionName($0.name) } },
            liveError: liveError)
    }
}

struct HauntedCLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `target` and session `name` values end up as positional/flag arguments to
/// the `haunted` CLI (see attachCommand/killSession below), whose hand-rolled
/// arg parser has no `--` end-of-options marker — a value starting with `-`
/// risks being misread as one of the CLI's own flags rather than the
/// positional it's meant to be (e.g. a compromised console returning a
/// crafted session name). Both values come from remote-controlled JSON
/// (`dedmeshctl workstations -json`, `haunted list --json`), so reject them
/// at that decode boundary rather than at each call site.
///
/// Control and format scalars are rejected too: `name` is interpolated into
/// attach-loop.sh's OSC-0 title sequence, where a BEL would terminate the
/// sequence early and inject the remainder into the *local* terminal, and it
/// is the sidebar's fallback display string when a session has no title.
func isSafeCLIArgument(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-") else { return false }
    return !value.unicodeScalars.contains { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}

/// Join tokens as the console mints them: `dn_` + lowercase hex
/// (store.newToken). The token is interpolated into a single-quoted string
/// inside the Lima enroll command, so anything outside this exact grammar is
/// rejected rather than passed along — a console (or MITM'd `dedmeshctl`)
/// answer cannot smuggle shell into the VM bootstrap.
func isValidJoinToken(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count > 3,
          bytes[0] == UInt8(ascii: "d"), bytes[1] == UInt8(ascii: "n"),
          bytes[2] == UInt8(ascii: "_") else { return false }
    return bytes.dropFirst(3).allSatisfy { byte in
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }
}

/// Session names as the daemon defines them: `session_name_valid()` in
/// `apps/haunted-daemon/src/session.c` accepts exactly `[A-Za-z0-9_-]{1,63}`,
/// so the daemon can never legitimately report a name outside that set — one
/// that arrives anyway came from a tampered-with list response. We additionally
/// reject a leading `-`, which the daemon permits but which the CLI's arg
/// parser would read as a flag (see isSafeCLIArgument).
func isValidSessionName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 63, !value.hasPrefix("-") else {
        return false
    }
    return value.utf8.allSatisfy { byte in
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }
}

/// Shells out to the `haunted` / `dedmeshctl` CLIs, which own all mesh
/// transport and mTLS state. Helper binaries are resolved to absolute paths:
/// the app is often launched with no useful PATH (Finder/Dock, or a
/// non-interactive `zsh -lc`, which never sources .zshrc), so "it's on my
/// PATH" is true in the user's terminal and false inside the app.
enum HauntedCLI {
    /// The app's own copy wins, then well-known install locations most
    /// specific first. PATH remains the last resort for setups that install
    /// elsewhere.
    ///
    /// The bundle carries `haunted` and `dedmeshctl` (Contents/MacOS, copied
    /// in by the Make recipes) so a drag-install is complete and a Sparkle
    /// update replaces app and CLIs atomically — version skew between the two
    /// already shipped a breakage once (LOOP-08). Only those pure-client CLIs
    /// may live in the bundle: `dedmeshd` self-updates by rewriting its own
    /// executable, which inside the bundle would break the code-signing seal,
    /// so the daemons stay under `~/.local/bin` and simply never hit the
    /// bundle probe.
    static func resolve(
        _ tool: String,
        fs: HauntedFileSystem = .real,
        bundledTools: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
    ) -> String {
        if let bundled = bundledTools?.appendingPathComponent(tool).path,
           fs.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let home = fs.homeDirectory.path
        let candidates = [
            "\(home)/.local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
        ]
        for path in candidates where fs.isExecutableFile(atPath: path) {
            return path
        }
        return tool
    }

    /// The decode boundary for `dedmeshctl workstations -json`. Split out from
    /// the process call so the JSON contract is testable without a subprocess.
    static func decodeWorkstations(_ data: Data) throws -> [HauntedWorkstation] {
        try JSONDecoder().decode([HauntedWorkstation].self, from: data)
            .filter { isSafeCLIArgument($0.target) }
            .map { $0.normalizingColor() }
    }

    /// The decode boundary for `haunted list --json`.
    static func decodeSessions(_ data: Data) throws -> [HauntedWorkstationSession] {
        try JSONDecoder().decode([HauntedWorkstationSession].self, from: data)
            .filter { isValidSessionName($0.name) }
    }

    /// The decode boundary for `dedmeshctl workstations -json -sessions`.
    static func decodeWorkstationListings(_ data: Data) throws -> [HauntedWorkstationListing] {
        try JSONDecoder().decode([HauntedWorkstationListing].self, from: data)
            .filter { isSafeCLIArgument($0.workstation.target) }
            .map { $0.sanitized() }
    }

    static func workstations(
        identity: HauntedClientIdentity,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws -> [HauntedWorkstation] {
        let data = try await runner.run(
            "\(quote(resolve("dedmeshctl", fs: fs))) workstations -json -state-dir \(quote(identity.stateDir.path))")
        return try decodeWorkstations(data)
    }

    /// The multiplexed sidebar poll: ONE `dedmeshctl` invocation (one Console
    /// mTLS session) returns every workstation with summaries, fanning out
    /// live titled session lists for `live` targets only. `live` values came
    /// out of remote-controlled JSON, so they are re-checked at this argv
    /// boundary; a comma would smuggle a second target into the flag.
    static func workstationSessions(
        identity: HauntedClientIdentity,
        live: [String],
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws -> [HauntedWorkstationListing] {
        let safe = live.filter { isSafeCLIArgument($0) && !$0.contains(",") }
        let liveArg = safe.isEmpty ? "none" : safe.joined(separator: ",")
        let data = try await runner.run(
            "\(quote(resolve("dedmeshctl", fs: fs))) workstations -json -sessions -live \(quote(liveArg)) -state-dir \(quote(identity.stateDir.path))")
        return try decodeWorkstationListings(data)
    }

    static func sessions(
        identity: HauntedClientIdentity,
        target: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws -> [HauntedWorkstationSession] {
        let data = try await runner.run(
            "\(quote(resolve("haunted", fs: fs))) list --json --state-dir \(quote(identity.stateDir.path)) --target \(quote(target))")
        return try decodeSessions(data)
    }

    static func killSession(
        identity: HauntedClientIdentity,
        target: String,
        sessionName: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws {
        _ = try await runner.run(
            "\(quote(resolve("haunted", fs: fs))) kill \(quote(sessionName)) --state-dir \(quote(identity.stateDir.path)) --target \(quote(target))")
    }

    /// Sets (or, with nil, clears) a workstation daemon's display color on the
    /// console, via `dedmeshctl workstation color`. `daemon` came out of the
    /// workstation list (remote JSON), so it is re-checked at this call
    /// boundary; `color` must be an already-normalized "#rrggbb" — anything
    /// else is refused rather than interpolated into an argv.
    static func setWorkstationColor(
        identity: HauntedClientIdentity,
        daemon: String,
        color: String?,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws {
        guard isSafeCLIArgument(daemon) else {
            throw HauntedCLIError(message: "invalid daemon name")
        }
        let value: String
        if let color {
            guard HauntedWorkstation.normalizedColor(color) == color else {
                throw HauntedCLIError(message: "invalid color")
            }
            value = color
        } else {
            value = "default"
        }
        _ = try await runner.run(
            "\(quote(resolve("dedmeshctl", fs: fs))) workstation color \(quote(daemon)) \(quote(value)) -state-dir \(quote(identity.stateDir.path))")
    }

    /// Mints a single-use daemon join token for a workstation under this
    /// client's own account, via `dedmeshctl workstation token -json` (the
    /// mesh mint path — the Terminal holds no console API token). The console
    /// derives and returns the username-prefixed daemon name the VM must
    /// enroll as. The reply is remote-controlled JSON, so the token is
    /// validated against the exact `dn_<hex>` grammar and the daemon name
    /// against the daemon grammar before either may reach an argv.
    static func mintWorkstationToken(
        identity: HauntedClientIdentity,
        workstation: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws -> (token: String, daemon: String) {
        guard isValidWorkstationName(workstation) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        let data = try await runner.run(
            "\(quote(resolve("dedmeshctl", fs: fs))) workstation token \(quote(workstation)) -json -state-dir \(quote(identity.stateDir.path))")
        struct Reply: Decodable {
            let token: String
            let daemon: String
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              isValidJoinToken(reply.token), isValidDaemonName(reply.daemon) else {
            throw HauntedCLIError(message: "console returned a malformed join token reply")
        }
        return (token: reply.token, daemon: reply.daemon)
    }

    /// Revokes one of this client's own daemons on the console (`dedmeshctl
    /// workstation rm`) — the cleanup half of deleting a Lima workstation VM.
    static func revokeWorkstation(
        identity: HauntedClientIdentity,
        daemon: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws {
        guard isSafeCLIArgument(daemon) else {
            throw HauntedCLIError(message: "invalid daemon name")
        }
        _ = try await runner.run(
            "\(quote(resolve("dedmeshctl", fs: fs))) workstation rm \(quote(daemon)) -state-dir \(quote(identity.stateDir.path))")
    }

    /// One-time enrollment: join token → client mTLS certificate (plus the
    /// persisted console settings) in the default state dir.
    static func enroll(
        console: String,
        caFile: String,
        token: String,
        name: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        fs: HauntedFileSystem = .real
    ) async throws {
        _ = try await runner.run(
            "\(quote(resolve("haunted", fs: fs))) enroll --console \(quote(console)) --ca \(quote(caFile)) "
                + "--token \(quote(token)) --name \(quote(name)) "
                + "--state-dir \(quote(HauntedClientIdentity.defaultStateDir(fs).path))")
    }

    static func login(
        consoleURL: URL,
        requestID: String,
        code: String,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        session: URLSession = .shared,
        fs: HauntedFileSystem = .real
    ) async throws {
        let redeemed = try await HauntedClientLoginAPI.redeem(
            consoleURL: consoleURL, id: requestID, code: code, session: session)
        let stateDir = HauntedClientIdentity.defaultStateDir(fs)
        try FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory's `attributes:` apply only to directories it actually
        // creates — an existing 0755 dir is left as-is. `haunted enroll` is
        // about to write key.pem (the client's mTLS private key) here, so
        // narrow the mode unconditionally.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
        let caFile = stateDir.appendingPathComponent("ca.pem")
        try redeemed.caPEM.write(to: caFile, atomically: true, encoding: .utf8)
        guard let host = consoleURL.host else {
            throw HauntedCLIError(message: "Invalid Console URL")
        }
        let controlPort = redeemed.controlPort.isEmpty ? "9443" : redeemed.controlPort
        try await enroll(
            console: "\(host):\(controlPort)",
            caFile: caFile.path,
            token: redeemed.token,
            name: redeemed.clientName,
            runner: runner,
            fs: fs)
    }

    /// The command a terminal tab runs to attach to a workstation session.
    /// create=true for fresh session names (the daemon does not create on
    /// raw attach).
    ///
    /// This command may ONLY use flags the OLDEST deployed `haunted` CLI
    /// understands (`--create`). The tab-scoped kill grace for `gui-*`
    /// sessions is deliberately NOT emitted here: it is `haunted
    /// attach-remote`'s own default — when the app briefly passed
    /// `--kill-grace` itself, every attach through an older `~/.local/bin/
    /// haunted` died on a usage error and the reconnect loop spun uselessly.
    /// The CLI knows its own flags; the app must keep working across skew.
    ///
    /// The heavy lifting lives in a generated helper script (attachLoopPath):
    /// initialInput is TYPED into the starting shell and echoed raw back at
    /// the user, so it must stay one short ASCII line — the script's first
    /// act is to wipe the screen, erasing that echo.
    static func attachCommand(
        target: String,
        sessionName: String,
        create: Bool,
        fs: HauntedFileSystem = .real
    ) -> String {
        var cmd = "exec \(quote(attachLoopPath(fs: fs))) \(quote(target)) \(quote(sessionName))"
        if create { cmd += " --create" }
        return cmd
    }

    /// Writes (once per launch) and returns the attach-loop helper: a bounded
    /// reconnect loop, because a console restart or network blip drops the
    /// transport while the session it fronts is still alive on the
    /// workstation — quietly reattaching beats stranding the user on an exit
    /// banner. Growing backoff capped at 10s, 20 attempts ≈ 3 minutes of
    /// riding out mesh re-convergence (the workstation daemon reconnects on
    /// its own backoff; attach attempts during its gap fail instantly).
    /// A clean exit (detach / session killed) breaks the loop; ctrl-c during
    /// the backoff cancels it; spent retries exit nonzero so
    /// wait-after-command shows the failure.
    ///
    /// The write-once cache is keyed on the script path rather than a plain
    /// bool: a different Application Support root is a different script, and
    /// claiming it exists because some other root's copy was written would hand
    /// out a path to a file that was never created.
    private static var wroteAttachLoop: Set<String> = []
    static func attachLoopPath(fs: HauntedFileSystem = .real) -> String {
        let dir = fs.applicationSupportDirectory
            .appendingPathComponent("HauntedTerminal", isDirectory: true)
        let script = dir.appendingPathComponent("attach-loop.sh")
        if wroteAttachLoop.contains(script.path) { return script.path }

        // ASCII only: this file's output lands in a terminal whose charset
        // is not yet negotiated when the loop starts.
        let body = """
        #!/bin/sh
        # Generated by Haunted Terminal at launch; edits are overwritten.
        # usage: attach-loop.sh TARGET SESSION [attach-remote flags...]
        # Extra flags (--create, --kill-grace N) pass through to attach-remote
        # on EVERY retry: a reconnect must re-arm the tab-scoped kill grace,
        # since an attach clears it daemon-side.
        TARGET=$1; SESSION=$2; shift 2
        # Wipe the echoed invocation and title the tab after the session
        # (instead of this script's exec line). This title only has to survive
        # until attach: the daemon then pushes the session's real title and
        # `haunted` retitles the tab, keeping it current from there on.
        printf '\\033[2J\\033[H\\033]0;%s\\007' "$SESSION on ${TARGET#*/}"
        trap 'echo; echo "[haunted] reconnect cancelled"; exit 130' INT
        attempt=0; delay=2
        while :; do
            \(quote(resolve("haunted", fs: fs))) attach-remote --target "$TARGET" "$@" "$SESSION"
            code=$?
            [ $code -eq 0 ] && exit 0
            attempt=$((attempt+1))
            [ $attempt -ge 20 ] && { echo "[haunted] giving up after 20 attempts (exit $code)"; exit $code; }
            echo "[haunted] connection lost (exit $code); reconnecting ($attempt/20) in ${delay}s, ctrl-c to stop"
            sleep $delay
            delay=$((delay+2)); [ $delay -gt 10 ] && delay=10
        done
        """
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            wroteAttachLoop.insert(script.path)
        } catch {
            NSLog("[haunted] cannot write attach-loop helper: %@", "\(error)")
        }
        return script.path
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
