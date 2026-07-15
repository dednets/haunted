import Foundation
import Testing
@testable import Ghostty

/// CRSH — the Sentry crash-envelope uploader (HauntedCrashReporter).
/// Serialized: HauntedStubURLProtocol's handler is process-global.
@Suite(.serialized)
struct HauntedCrashReporterTests {
    // CRSH-01: the production DSN derives exactly the DedNets envelope
    // endpoint and an auth header carrying the key.
    @Test func productionDSNDerivesEnvelopeEndpoint() throws {
        let endpoint = try #require(HauntedCrashReporter.endpoint(dsn: HauntedCrashReporter.dsn))
        #expect(endpoint.url.absoluteString
            == "https://o4511347549077504.ingest.de.sentry.io/api/4511714765570128/envelope/")
        #expect(endpoint.authHeader.contains("sentry_key=8fb11b26aba9b04c2351b2c2131ec630"))
        #expect(endpoint.authHeader.contains("sentry_version=7"))
    }

    // CRSH-02: fork invariant: crash reports go to the DedNets org and
    // nowhere else. The same class of guard as UPD-01 (Sparkle feed): a
    // rebase or careless edit must not point crash data at another project.
    @Test func dsnIsPinnedToDedNets() {
        #expect(HauntedCrashReporter.dsn.contains("@o4511347549077504.ingest.de.sentry.io/"))
        #expect(!HauntedCrashReporter.dsn.contains("ghostty"))
        #expect(HauntedCrashReporter.dsn.hasPrefix("https://"))
    }

    // CRSH-03: malformed DSNs are refused, never mangled into a guess.
    @Test(arguments: [
        "https://o123.ingest.sentry.io/456",           // no key
        "http://key@o123.ingest.sentry.io/456",        // not https
        "https://key@o123.ingest.sentry.io/",          // no project
        "https://key@o123.ingest.sentry.io/not-a-num", // non-numeric project
        "",
    ])
    func malformedDSNRefused(dsn: String) {
        #expect(HauntedCrashReporter.endpoint(dsn: dsn) == nil)
    }

    // CRSH-04: the crash dir mirrors src/crash/dir.zig — XDG_STATE_HOME wins,
    // otherwise ~/.local/state/ghostty/crash.
    @Test func crashDirMatchesZigTransport() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        #expect(HauntedCrashReporter.crashDir(env: [:], home: home).path
            == "/Users/nobody/.local/state/ghostty/crash")
        #expect(HauntedCrashReporter.crashDir(env: ["XDG_STATE_HOME": "/tmp/xstate"], home: home).path
            == "/tmp/xstate/ghostty/crash")
    }

    // CRSH-05: only .ghosttycrash files qualify, oldest first, capped per
    // launch, oversized envelopes skipped.
    @Test func pendingReportsFiltersSortsAndCaps() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, _ data: Data, age: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        // Seven envelopes (cap is 5), oldest = e7 … newest = e1.
        for i in 1...7 {
            try write("e\(i).ghosttycrash", Data("envelope-\(i)".utf8), age: TimeInterval(i * 60))
        }
        try write("notes.txt", Data("not a crash".utf8), age: 600)
        try write("huge.ghosttycrash",
                  Data(count: HauntedCrashReporter.maxEnvelopeBytes + 1), age: 999)

        let pending = HauntedCrashReporter.pendingReports(in: dir)
        #expect(pending.count == HauntedCrashReporter.maxUploadsPerLaunch)
        #expect(pending.map(\.lastPathComponent)
            == ["e7.ghosttycrash", "e6.ghosttycrash", "e5.ghosttycrash",
                "e4.ghosttycrash", "e3.ghosttycrash"])
        // A missing directory is an empty queue, not an error.
        #expect(HauntedCrashReporter.pendingReports(
            in: dir.appendingPathComponent("nope")).isEmpty)
    }

    // CRSH-06: an accepted envelope is POSTed verbatim (body + auth header)
    // and deleted; a refused one stays queued.
    @Test func submitPostsAndDeletesOnlyOnAcceptance() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("aa.ghosttycrash")
        let refused = dir.appendingPathComponent("bb.ghosttycrash")
        try Data("accepted-envelope".utf8).write(to: ok)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: ok.path)
        try Data("refused-envelope".utf8).write(to: refused)

        HauntedStubURLProtocol.reset { request in
            let status = HauntedStubURLProtocol.body(of: request)
                == Data("accepted-envelope".utf8) ? 200 : 500
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        defer { HauntedStubURLProtocol.reset() }

        let accepted = await HauntedCrashReporter.submitPending(
            in: dir, session: HauntedStubURLProtocol.makeSession())

        #expect(accepted == 1)
        #expect(!FileManager.default.fileExists(atPath: ok.path))
        #expect(FileManager.default.fileExists(atPath: refused.path))

        let requests = HauntedStubURLProtocol.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString
                == "https://o4511347549077504.ingest.de.sentry.io/api/4511714765570128/envelope/")
            #expect(request.value(forHTTPHeaderField: "X-Sentry-Auth")?
                .contains("sentry_key=8fb11b26aba9b04c2351b2c2131ec630") == true)
            #expect(request.value(forHTTPHeaderField: "Content-Type")
                == "application/x-sentry-envelope")
        }
    }
}
