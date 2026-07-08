import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.5 — LOG-01…05, `HauntedCLI.login`.
///
/// `login` is the one function that drives all three seams at once: it redeems a
/// one-time code over HTTP (§5.2), writes the console's CA into the state dir on
/// a real filesystem rooted somewhere disposable (§5.3), then shells out to
/// `haunted enroll` (§5.1). The artifacts it leaves behind — a directory mode
/// and a `ca.pem` — are the ones `hasLogin` later reads to decide whether this
/// machine is enrolled, and the argv it builds carries a console-supplied token
/// and client name. So the assertions here are on the exact mode, the exact
/// bytes, and the exact command string.
///
/// LOG-05 (and the LOG-03 leftover) remain **characterization** tests: they pin
/// what the code does today, not what it ought to do — a failed enroll still
/// leaves `ca.pem` behind, making `hasLogin` half-true. That is TEST_PLAN §11
/// D4, still open. LOG-04 was a characterization test until the 0700 chmod
/// landed; it is now a regression test.
@Suite(.serialized)
struct HauntedCLILoginTests {
    // MARK: Fixtures

    /// Not a real certificate — nothing here parses it. Multi-line on purpose:
    /// `ca.pem` round-trips through `String.write(to:atomically:encoding:)`, and
    /// a single-line fixture would not notice a newline-mangling regression.
    static let caPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBkTCB+wIJAKZ7Z3xkQ0AAMA0GCSqGSIb3DQEBCwUA
    -----END CERTIFICATE-----

    """

    /// The console's `/client-login/redeem` response body. Encoded from a
    /// dictionary rather than a string literal so the multi-line PEM is escaped
    /// by the same JSON rules the real console uses.
    static func redeemBody(
        token: String = "tok-123",
        username: String = "alice",
        clientName: String = "macbook",
        controlPort: String = "8443",
        caPEM: String = HauntedCLILoginTests.caPEM
    ) throws -> Data {
        try JSONEncoder().encode([
            "token": token,
            "username": username,
            "client_name": clientName,
            "control_port": controlPort,
            "ca_pem": caPEM,
        ])
    }

    /// The POSIX mode bits of `url`, or nil when it does not exist.
    private func mode(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// The single `haunted enroll` command `login` shells out to, or nil if it
    /// never got that far.
    private func enrollCommand(_ runner: FakeProcessRunner) -> String? {
        runner.invocations.first { $0.kind == .run }?.command
    }

    // MARK: LOG-01

    @Test("LOG-01: state dir is 0700, ca.pem written, enroll gets host:controlPort")
    func happyPath() async throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }

        LoginStubURLProtocol.respondOK(try Self.redeemBody(controlPort: "8443"))
        defer { LoginStubURLProtocol.reset() }

        let runner = FakeProcessRunner()
        let consoleURL = try #require(URL(string: "https://console.example.com"))

        try await HauntedCLI.login(
            consoleURL: consoleURL,
            requestID: "req-1",
            code: "code-1",
            runner: runner,
            session: LoginStubURLProtocol.makeSession(),
            fs: fs)

        let stateDir = HauntedClientIdentity.defaultStateDir(fs)
        let caFile = stateDir.appendingPathComponent("ca.pem")

        // The state dir holds key.pem after enrollment, so 0700 is the whole
        // point of passing `attributes:` to createDirectory.
        #expect(mode(stateDir) == 0o700)
        let written = try String(contentsOf: caFile, encoding: .utf8)
        #expect(written == Self.caPEM)

        // Exactly one child process: the enroll. The redeem is HTTP, not a fork.
        #expect(runner.invocations.count == 1)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.kind == .run)
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments.first == "-lc")

        // Verbatim argv: the token and client name are console-controlled and
        // reach a CLI with no `--` end-of-options marker. `'haunted'` unquoted
        // to a bare tool name because HauntedTempFileSystem reports no
        // executable candidates — resolve() must not depend on this machine.
        let expected = "'haunted' enroll --console 'console.example.com:8443' "
            + "--ca '\(caFile.path)' --token 'tok-123' --name 'macbook' "
            + "--state-dir '\(stateDir.path)'"
        #expect(enrollCommand(runner) == expected)
    }

    // MARK: LOG-02

    @Test("LOG-02: empty control_port defaults to 9443")
    func emptyControlPortDefaults() async throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }

        LoginStubURLProtocol.respondOK(try Self.redeemBody(controlPort: ""))
        defer { LoginStubURLProtocol.reset() }

        let runner = FakeProcessRunner()
        let consoleURL = try #require(URL(string: "https://console.example.com:8080/some/path"))

        try await HauntedCLI.login(
            consoleURL: consoleURL,
            requestID: "req-1",
            code: "code-1",
            runner: runner,
            session: LoginStubURLProtocol.makeSession(),
            fs: fs)

        // The console *control* port (mTLS) is not the console's HTTP port: the
        // 8080 in the URL must not leak into the enroll address. Matched with
        // the colon because the bare "8080" could appear by chance in the
        // temp root's UUID, which is hex.
        let command = try #require(enrollCommand(runner))
        #expect(command.contains("--console 'console.example.com:9443'"))
        #expect(!command.contains(":8080"))
    }

    // MARK: LOG-03

    @Test("LOG-03: console URL with no host throws before enrolling")
    func missingHostRejected() async throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }

        LoginStubURLProtocol.respondOK(try Self.redeemBody())
        defer { LoginStubURLProtocol.reset() }

        let runner = FakeProcessRunner()
        // Passes `isAllowedConsoleScheme` (https) but `URL.host` is nil, so the
        // guard between the ca.pem write and enroll is the one that fires.
        let consoleURL = try #require(URL(string: "https:///"))

        var thrown: Error?
        do {
            try await HauntedCLI.login(
                consoleURL: consoleURL,
                requestID: "req-1",
                code: "code-1",
                runner: runner,
                session: LoginStubURLProtocol.makeSession(),
                fs: fs)
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? HauntedCLIError)
        #expect(error.message == "Invalid Console URL")
        // No enroll: the token never reaches a subprocess.
        #expect(runner.invocations.isEmpty)

        // CHARACTERIZATION. TEST_PLAN §4.5 predicts "nothing written" for
        // LOG-03. That is not what happens: the host guard sits *after* the
        // createDirectory + ca.pem write, so a hostless URL still leaves a
        // state dir and a CA behind. Same leftover as LOG-05; asserted here so
        // the plan's expectation and the code's behavior stop disagreeing
        // silently. Not called a defect — see §10 open question 2.
        let stateDir = HauntedClientIdentity.defaultStateDir(fs)
        #expect(LoginStubURLProtocol.requestCount == 1, "redeem ran before the guard")
        #expect(mode(stateDir) == 0o700)
        #expect(FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("ca.pem").path))
    }

    // MARK: LOG-04

    @Test("LOG-04: a pre-existing 0755 state dir is narrowed to 0700")
    func existingStateDirIsNarrowed() async throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }

        let stateDir = HauntedClientIdentity.defaultStateDir(fs)
        try FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        #expect(mode(stateDir) == 0o755, "fixture precondition")

        LoginStubURLProtocol.respondOK(try Self.redeemBody())
        defer { LoginStubURLProtocol.reset() }

        let runner = FakeProcessRunner()
        let consoleURL = try #require(URL(string: "https://console.example.com"))

        try await HauntedCLI.login(
            consoleURL: consoleURL,
            requestID: "req-1",
            code: "code-1",
            runner: runner,
            session: LoginStubURLProtocol.makeSession(),
            fs: fs)

        // Regression test. `createDirectory(withIntermediateDirectories: true,
        // attributes:)` applies `attributes` only to directories it actually
        // creates — an existing directory is a silent no-op, no error and no
        // chmod. login() used to rely on that call alone, so a pre-existing
        // 0755 dir stayed group/world-readable while `haunted enroll` wrote
        // `key.pem`, the client's mTLS private key, into it.
        //
        // Enrollment proceeded normally either way, which is why this was easy
        // to miss: the only observable is the mode.
        #expect(mode(stateDir) == 0o700, "key.pem's directory must not be world-readable")
        #expect(enrollCommand(runner)?.contains("enroll") == true)
    }

    // MARK: LOG-05

    @Test("LOG-05: a failed enroll leaves ca.pem behind")
    func failedEnrollLeavesCAFile() async throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }

        LoginStubURLProtocol.respondOK(try Self.redeemBody())
        defer { LoginStubURLProtocol.reset() }

        let runner = FakeProcessRunner(runHandler: { _ in
            throw HauntedCLIError(message: "enroll: join token already used")
        })
        let consoleURL = try #require(URL(string: "https://console.example.com"))

        var thrown: Error?
        do {
            try await HauntedCLI.login(
                consoleURL: consoleURL,
                requestID: "req-1",
                code: "code-1",
                runner: runner,
                session: LoginStubURLProtocol.makeSession(),
                fs: fs)
        } catch {
            thrown = error
        }

        // The CLI's stderr is what explains the failure to the user.
        let error = try #require(thrown as? HauntedCLIError)
        #expect(error.message == "enroll: join token already used")
        #expect(runner.invocations.count == 1)

        // CHARACTERIZATION, not an agreed defect — TEST_PLAN §10 open question 2.
        //
        // login() has no rollback: `ca.pem` was written before enroll ran and
        // stays on disk after it fails. The content is a public CA certificate,
        // so this is not a secret leak. What it does do is make `hasLogin()`
        // half-true — that predicate requires all four of cert.pem, key.pem,
        // settings.json and ca.pem, and a failed login now supplies one of
        // them. Today the other three are missing, so `load()` still correctly
        // reports "not enrolled".
        //
        // The sharper edge, unasserted because it needs a second scenario: a
        // *re-*login that fails has already overwritten the ca.pem of a
        // still-valid enrollment with a different console's CA.
        let stateDir = HauntedClientIdentity.defaultStateDir(fs)
        let caFile = stateDir.appendingPathComponent("ca.pem")
        #expect(FileManager.default.fileExists(atPath: caFile.path))
        let leftover = try String(contentsOf: caFile, encoding: .utf8)
        #expect(leftover == Self.caPEM)
        #expect(HauntedClientIdentity.load(fs: fs) == nil, "ca.pem alone is not a login")
    }
}

/// A private twin of `HauntedStubURLProtocol`.
///
/// Not a reuse failure: `URLProtocol` subclasses are instantiated by Foundation
/// with no injectable context, so the handler *must* be static — and static
/// means the suite that owns it must be the only suite writing it. swift-testing
/// serializes tests *within* a `.serialized` suite but still runs different
/// suites in parallel, so sharing `HauntedStubURLProtocol` with
/// HauntedLoginAPITests would let its `reset(handler:)` clobber ours mid-test.
/// One class per serialized suite is what actually makes the stub hermetic.
///
/// Non-final, like its twin: `canInit`/`canonicalRequest` are `class func`
/// overrides, and swiftlint's static_over_final_class rejects those in a final
/// class.
private class LoginStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentHandler: Handler = { _ in
        throw URLError(.unsupportedURL)
    }
    nonisolated(unsafe) private static var served = 0

    /// How many requests Foundation actually issued. `0` is how "no network
    /// call happened" is asserted.
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    static func reset(handler: @escaping Handler = { _ in throw URLError(.unsupportedURL) }) {
        lock.lock()
        currentHandler = handler
        served = 0
        lock.unlock()
    }

    /// Installs a 200 handler returning `data`, and clears the counter.
    static func respondOK(_ data: Data) {
        reset { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (response, data)
        }
    }

    /// A URLSession that reaches nothing but this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.served += 1
        let handler = Self.currentHandler
        Self.lock.unlock()

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
