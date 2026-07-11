import Foundation

/// Submits Ghostty's locally-persisted crash reports to the DedNets Sentry
/// project (thenets/haunted-terminal-prod).
///
/// Upstream Ghostty deliberately never sends crash data: its Sentry transport
/// (src/crash/sentry.zig) writes each crash as a `<uuid>.ghosttycrash` file —
/// a complete, ready-to-ingest Sentry envelope — under the XDG state dir and
/// stops there. The fork keeps that offline capture (a crash with no network
/// is never lost) and drains the queue at launch: one POST per envelope to
/// Sentry's envelope endpoint, deleting on 2xx and keeping the file for the
/// next launch otherwise. Bounded per launch so a crash loop can't turn into
/// an upload storm.
enum HauntedCrashReporter {
    /// The DedNets ingest DSN. A DSN is routing information plus a public
    /// key — not a secret — and it is pinned here the same way the Sparkle
    /// feed is pinned in UpdateDelegate: crash reports must only ever reach
    /// the DedNets project (guarded by HauntedCrashReporterTests, and the
    /// bundle is checked for this host by scripts/build-app-dist.sh).
    static let dsn =
        "https://8fb11b26aba9b04c2351b2c2131ec630@o4511347549077504.ingest.de.sentry.io/4511714765570128"

    /// At most this many envelopes are submitted per launch; the rest wait.
    static let maxUploadsPerLaunch = 5

    /// Envelopes larger than this are pathological (the usual crash envelope
    /// is a few hundred KB) and are skipped rather than shipped.
    static let maxEnvelopeBytes = 20 << 20

    struct Endpoint: Equatable {
        let url: URL
        let authHeader: String
    }

    /// Derives Sentry's envelope-ingestion endpoint and auth header from a
    /// DSN (`https://<key>@<host>/<project-id>`).
    static func endpoint(dsn: String) -> Endpoint? {
        guard let parsed = URL(string: dsn),
              parsed.scheme == "https",
              let key = parsed.user, !key.isEmpty,
              let host = parsed.host, !host.isEmpty
        else { return nil }
        let project = parsed.lastPathComponent
        guard !project.isEmpty, project.allSatisfy(\.isNumber),
              let url = URL(string: "https://\(host)/api/\(project)/envelope/")
        else { return nil }
        return Endpoint(
            url: url,
            authHeader: "Sentry sentry_version=7, sentry_client=haunted-terminal, sentry_key=\(key)"
        )
    }

    /// Where the zig transport persists envelopes: `$XDG_STATE_HOME/ghostty/crash`,
    /// defaulting to `~/.local/state/ghostty/crash` (src/crash/dir.zig).
    static func crashDir(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let state = env["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("ghostty/crash")
        }
        return home.appendingPathComponent(".local/state/ghostty/crash")
    }

    /// The queued envelopes, oldest first, capped at `maxUploadsPerLaunch`;
    /// non-`.ghosttycrash` and oversized files are ignored.
    static func pendingReports(in dir: URL, fileManager: FileManager = .default) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let candidates = entries.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "ghosttycrash" else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let size = values?.fileSize, size > maxEnvelopeBytes { return nil }
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        return candidates
            .sorted { $0.1 < $1.1 }
            .prefix(maxUploadsPerLaunch)
            .map(\.0)
    }

    /// Fire-and-forget launch hook: drain the queue in the background.
    static func submitPending() {
        Task.detached(priority: .utility) {
            _ = await submitPending(in: crashDir(), session: .shared)
        }
    }

    /// Submits every pending envelope sequentially; returns how many were
    /// accepted (and therefore deleted). A refused or unreachable envelope
    /// stays queued for the next launch.
    @discardableResult
    static func submitPending(
        in dir: URL,
        session: URLSession,
        fileManager: FileManager = .default
    ) async -> Int {
        guard let endpoint = endpoint(dsn: dsn) else { return 0 }
        var accepted = 0
        for file in pendingReports(in: dir, fileManager: fileManager) {
            guard await submit(file, to: endpoint, session: session) else { continue }
            try? fileManager.removeItem(at: file)
            accepted += 1
        }
        return accepted
    }

    /// One envelope → one POST. True iff Sentry accepted it (2xx).
    static func submit(_ file: URL, to endpoint: Endpoint, session: URLSession) async -> Bool {
        guard let body = try? Data(contentsOf: file) else { return false }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(endpoint.authHeader, forHTTPHeaderField: "X-Sentry-Auth")
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
