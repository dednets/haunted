import Foundation
@testable import Ghostty

// Shared doubles for the Haunted seams (TEST_PLAN §5.1–§5.3). No @Test lives
// here, so this file is not a suite and gets no HAUNTED_MACOS_SUITES entry.

/// One recorded child-process launch. The whole point of the process seam: the
/// argv is the security-relevant artifact, so it is compared verbatim.
struct HauntedProcessInvocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case run
        case runToCompletion
        case spawnDetached
    }

    let kind: Kind
    let executable: String
    let arguments: [String]

    /// The shell string a `.run` invocation was asked to execute.
    var command: String? {
        kind == .run ? arguments.last : nil
    }
}

/// Records every launch in one ordered log, so an ordering assertion is a
/// one-liner over `invocations.map(\.kind)`.
///
/// `@unchecked Sendable` behind an NSLock, mirroring the OutputCollector the
/// real runner uses: swift-testing runs suites in parallel and `run` resumes on
/// whatever thread the concurrency pool hands it.
final class FakeProcessRunner: HauntedProcessRunning, @unchecked Sendable {
    typealias RunHandler = @Sendable (String) throws -> Data

    private let runHandler: RunHandler
    /// What `runToCompletion` reports for anything that is not `/usr/bin/pgrep`.
    private let exitStatus: Int32
    private let spawnSucceeds: Bool
    /// The command lines a fake `pgrep -f` matches against.
    private let processTable: [String]

    private var log: [HauntedProcessInvocation] = []
    private let lock = NSLock()

    init(
        runHandler: @escaping RunHandler = { _ in Data() },
        exitStatus: Int32 = 0,
        spawnSucceeds: Bool = true,
        processTable: [String] = []
    ) {
        self.runHandler = runHandler
        self.exitStatus = exitStatus
        self.spawnSucceeds = spawnSucceeds
        self.processTable = processTable
    }

    var invocations: [HauntedProcessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func run(_ command: String) async throws -> Data {
        record(.init(kind: .run, executable: "/bin/zsh", arguments: ["-lc", command]))
        return try runHandler(command)
    }

    @discardableResult
    func runToCompletion(executable: String, arguments: [String]) -> Int32 {
        record(.init(kind: .runToCompletion, executable: executable, arguments: arguments))
        guard executable == "/usr/bin/pgrep" else { return exitStatus }
        return pgrepStatus(arguments)
    }

    @discardableResult
    func spawnDetached(executable: String, arguments: [String]) -> Bool {
        record(.init(kind: .spawnDetached, executable: executable, arguments: arguments))
        return spawnSucceeds
    }

    private func record(_ invocation: HauntedProcessInvocation) {
        lock.lock()
        log.append(invocation)
        lock.unlock()
    }

    /// `pgrep -f PATTERN` treats PATTERN as an unanchored extended regular
    /// expression over the full command line, never as a literal substring.
    /// A substring-matching fake would quietly launder the metacharacters the
    /// supervisor hands it (SUP-08), so match with a real regex engine.
    /// Models `pgrep -f [--] PATTERN`. PATTERN is a regex, never a substring —
    /// a substring-matching fake would make SUP-08 pass and prove nothing. The
    /// optional `--` end-of-options marker is accepted because the real tool
    /// accepts it (verified against /usr/bin/pgrep), and the supervisor passes
    /// it so a config path beginning with `-` is not read as a flag.
    private func pgrepStatus(_ arguments: [String]) -> Int32 {
        var args = arguments
        guard args.first == "-f" else { return 2 }
        args.removeFirst()
        if args.first == "--" { args.removeFirst() }
        guard args.count == 1, let regex = try? NSRegularExpression(pattern: args[0])
        else {
            return 2 // pgrep's usage/syntax-error exit
        }
        let matched = processTable.contains { entry in
            regex.firstMatch(
                in: entry, range: NSRange(entry.startIndex..., in: entry)) != nil
        }
        return matched ? 0 : 1
    }
}

/// A real filesystem rooted somewhere disposable. Not an in-memory fake: the
/// production writes under test (`createDirectory(attributes:)` with 0700,
/// `setAttributes` 0755, `ca.pem`) are exactly the syscalls whose behavior the
/// LOG-* and LOOP-* cases assert, and a fake would assert only against itself.
///
/// Each instance owns a fresh root, so nothing is shared across parallel tests.
struct HauntedTempFileSystem: HauntedFileSystem {
    let root: URL
    let homeDirectory: URL
    let applicationSupportDirectory: URL

    /// `isExecutableFile` answers from this set rather than probing, because
    /// the `/opt/homebrew` and `/usr/local` tool candidates live outside any
    /// root: probing them for real would make `HauntedCLI.resolve` — and every
    /// command string built on it — depend on what the developer has installed.
    ///
    /// `var`, because a stub binary's path is only known once `root` exists.
    var executables: Set<String>

    init(executables: Set<String> = []) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("haunted-tests-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        applicationSupportDirectory = root
            .appendingPathComponent("appsupport", isDirectory: true)
        self.executables = executables
    }

    /// Creates both roots. Pair with `remove()` in a `defer`.
    func createRoots() throws {
        for dir in [homeDirectory, applicationSupportDirectory] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func isReadableFile(atPath path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)
    }
}

/// Answers the app's HTTP calls in-process. Foundation instantiates URLProtocol
/// subclasses itself and offers nowhere to hand one a collaborator, so the
/// handler and the request log are unavoidably static — the one global the
/// Haunted seams allow. Suites using it must be `@Suite(.serialized)`.
class HauntedStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentHandler: Handler = { _ in
        throw URLError(.unsupportedURL)
    }
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// Every request Foundation actually issued, bodies already drained into
    /// `httpBody`. `requests.isEmpty` is how "no network call happened" is
    /// asserted.
    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Installs `handler` and clears the log. Call at the top of every test.
    static func reset(handler: @escaping Handler = { _ in throw URLError(.unsupportedURL) }) {
        lock.lock()
        currentHandler = handler
        recorded = []
        lock.unlock()
    }

    /// A URLSession that reaches nothing but this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HauntedStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Foundation converts a POST's `httpBody` into an `httpBodyStream` before
    /// any URLProtocol sees the request, so reading `httpBody` here would
    /// silently observe nil. Drain the stream once, at the boundary.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var drained = request
        drained.httpBodyStream = nil
        drained.httpBody = Self.body(of: request)

        Self.lock.lock()
        Self.recorded.append(drained)
        let handler = Self.currentHandler
        Self.lock.unlock()

        do {
            let (response, data) = try handler(drained)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
