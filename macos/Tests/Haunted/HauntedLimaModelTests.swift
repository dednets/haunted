import Testing
import Foundation
@testable import Ghostty

/// The Lima manager pipelines (LIMOD-*): create → start → enrolled-probe →
/// mint → enroll ordering, the already-enrolled short-circuit, per-stage
/// failure, and delete's stop → delete → revoke with the revoke failure
/// downgraded to a warning. All driven through one FakeProcessRunner so the
/// ordering assertion reads straight off `invocations`.
@MainActor
struct HauntedLimaModelTests {
    // MARK: Harness

    struct Harness {
        let model: HauntedLimaModel
        let runner: FakeProcessRunner
        let fs: HauntedTempFileSystem
        let identity: HauntedClientIdentity
        let suite: String

        func tearDown() {
            fs.remove()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    /// A model whose limactl/dedmeshctl exist, whose state dir holds a
    /// pinnable ca.pem, and whose every child process is the injected fake.
    /// One runner serves as both the short and the long runner, so the
    /// invocation log is a single ordered timeline.
    private func makeHarness(
        runHandler: @escaping FakeProcessRunner.RunHandler
    ) throws -> Harness {
        var fs = HauntedTempFileSystem()
        try fs.createRoots()
        let home = fs.homeDirectory.path
        fs.executables = ["\(home)/.local/bin/limactl", "\(home)/.local/bin/dedmeshctl"]

        let stateDir = fs.homeDirectory.appendingPathComponent(".config/haunted")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try HauntedLimaCLITests.caPEM.write(
            to: stateDir.appendingPathComponent("ca.pem"), atomically: true, encoding: .utf8)

        let suite = "lima-model-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("https://web.example.com", forKey: "HauntedConsoleURL")

        let runner = FakeProcessRunner(runHandler: runHandler)
        let model = HauntedLimaModel(
            env: HauntedLimaCLI.Environment(runner: runner, longRunner: runner, fs: fs),
            defaults: defaults)
        let identity = HauntedClientIdentity(
            stateDir: stateDir, console: "c.example.com:9443")
        return Harness(model: model, runner: runner, fs: fs, identity: identity, suite: suite)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        _ what: @autoclosure () -> String = "condition"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Bool(false), "timed out waiting for \(what())")
    }

    /// The index of the first invocation whose command contains `marker`.
    private func indexOf(_ marker: String, in runner: FakeProcessRunner) -> Int? {
        runner.invocations.firstIndex { $0.command?.contains(marker) == true }
    }

    // MARK: LIMOD-01 — the create pipeline

    @Test("LIMOD-01: createAndEnroll runs create → start → probe → mint → enroll, in order")
    func createPipelineOrdering() async throws {
        let harness = try makeHarness { command in
            if command.contains(".config/dedmesh") {
                throw HauntedCLIError(message: "not enrolled") // probe: exit 1
            }
            if command.contains("workstation token") {
                return Data(#"{"token":"dn_00ff","daemon":"tester-ws9"}"#.utf8)
            }
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.createAndEnroll(
            spec: HauntedLimaVMSpec(name: "ws9"), identity: harness.identity)
        try await waitUntil({ harness.model.ops["ws9"] == nil }, "the pipeline finishes")

        let markers = ["create --name='ws9'", "start 'ws9'", ".config/dedmesh",
                       "workstation token 'ws9'", "install.sh"]
        let indices = markers.map { indexOf($0, in: harness.runner) }
        for (marker, index) in zip(markers, indices) {
            #expect(index != nil, "\(marker) never ran")
        }
        #expect(indices.compactMap { $0 } == indices.compactMap { $0 }.sorted(),
                "stages ran out of order: \(harness.runner.invocations.compactMap(\.command))")

        // The enroll carries the pinned CA and the persisted web base.
        let enroll = try #require(harness.runner.invocations
            .compactMap(\.command).first { $0.contains("install.sh") })
        #expect(enroll.contains("https://web.example.com/install.sh"))
        #expect(enroll.contains("--ca-fingerprint"))
        #expect(enroll.contains("dn_00ff"))
        #expect(enroll.contains("--workstation"))
        // The VM keeps the bare name; --name is the console-derived
        // username-prefixed daemon name from the mint reply.
        #expect(enroll.contains("shell 'ws9'"))
        #expect(enroll.contains("tester-ws9"))

        // The VM definition was written under Application Support.
        let yaml = harness.fs.applicationSupportDirectory
            .appendingPathComponent("HauntedTerminal/lima/ws9.yaml")
        #expect(FileManager.default.fileExists(atPath: yaml.path))
    }

    // MARK: LIMOD-02 — the already-enrolled short-circuit

    @Test("LIMOD-02: an already-enrolled VM skips mint and enroll")
    func alreadyEnrolledShortCircuit() async throws {
        let harness = try makeHarness { command in
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data() // the probe succeeds: dedmesh config exists in the VM
        }
        defer { harness.tearDown() }

        harness.model.createAndEnroll(
            spec: HauntedLimaVMSpec(name: "ws9"), identity: harness.identity)
        try await waitUntil({ harness.model.ops["ws9"] == nil })

        let commands = harness.runner.invocations.compactMap(\.command)
        #expect(commands.contains { $0.contains(".config/dedmesh") })
        #expect(!commands.contains { $0.contains("workstation token") },
                "a token was minted for an enrolled VM — burned for nothing")
        #expect(!commands.contains { $0.contains("install.sh") })
    }

    // MARK: LIMOD-03 — per-stage failure

    @Test("LIMOD-03: a failing stage parks the VM at .failed and stops the pipeline")
    func stageFailureStopsPipeline() async throws {
        let harness = try makeHarness { command in
            if command.contains("start 'ws9'") {
                throw HauntedCLIError(message: "vz says no")
            }
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.createAndEnroll(
            spec: HauntedLimaVMSpec(name: "ws9"), identity: harness.identity)
        try await waitUntil({
            if case .failed = harness.model.ops["ws9"] { return true }
            return false
        }, "the failure lands")

        #expect(harness.model.ops["ws9"] == .failed("vz says no"))
        let commands = harness.runner.invocations.compactMap(\.command)
        #expect(!commands.contains { $0.contains(".config/dedmesh") }, "no stage after the failure")
        #expect(!commands.contains { $0.contains("install.sh") })

        // The failed badge is dismissible, and clears exactly that state.
        harness.model.clearFailure(name: "ws9")
        #expect(harness.model.ops["ws9"] == nil)
    }

    // MARK: LIMOD-04 — delete

    @Test("LIMOD-04: delete runs stop → delete --force → console revoke, in order")
    func deleteOrdering() async throws {
        let harness = try makeHarness { command in
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.delete(name: "ws9", consoleDaemon: "tester-ws9",
                             identity: harness.identity)
        try await waitUntil({ harness.model.ops["ws9"] == nil })

        // The VM operations use the bare name; the console revoke uses the
        // FULL stored daemon name from the merged console ref.
        let markers = ["stop 'ws9'", "delete --force 'ws9'", "workstation rm 'tester-ws9'"]
        let indices = markers.compactMap { indexOf($0, in: harness.runner) }
        #expect(indices.count == 3, "delete steps missing: \(harness.runner.invocations.compactMap(\.command))")
        #expect(indices == indices.sorted(), "delete steps out of order")
        #expect(harness.model.warningMessage == nil)
    }

    @Test("LIMOD-04b: a failed console revoke is a warning, not a failed delete")
    func revokeFailureDowngraded() async throws {
        let harness = try makeHarness { command in
            if command.contains("workstation rm") {
                throw HauntedCLIError(message: "console unreachable")
            }
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.delete(name: "ws9", consoleDaemon: "tester-ws9",
                             identity: harness.identity)
        try await waitUntil({ harness.model.warningMessage != nil }, "the warning lands")

        #expect(harness.model.ops["ws9"] == nil, "the delete itself succeeded")
        #expect(harness.model.warningMessage?.contains("console unreachable") == true)
        #expect(harness.model.warningMessage?.contains("ws9") == true)
    }

    @Test("LIMOD-04c: a failed VM delete is a real failure and skips the revoke")
    func deleteFailureSkipsRevoke() async throws {
        let harness = try makeHarness { command in
            if command.contains("delete --force") {
                throw HauntedCLIError(message: "vm is wedged")
            }
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.delete(name: "ws9", consoleDaemon: "tester-ws9",
                             identity: harness.identity)
        try await waitUntil({
            if case .failed = harness.model.ops["ws9"] { return true }
            return false
        })

        #expect(harness.model.ops["ws9"] == .failed("vm is wedged"))
        #expect(!harness.runner.invocations.compactMap(\.command)
            .contains { $0.contains("workstation rm") },
            "the console row must survive while the VM still exists")
    }

    // MARK: LIMOD-05 — refresh and availability

    @Test("LIMOD-05: refresh flips available with limactl and keeps data on a failed list")
    func refreshAvailability() async throws {
        let harness = try makeHarness { command in
            if command.contains(" list --json") {
                return Data(#"[{"name":"ws1","status":"Running"}]"#.utf8)
            }
            return Data()
        }
        defer { harness.tearDown() }

        await harness.model.refresh()
        #expect(harness.model.available)
        #expect(harness.model.instances == [HauntedLimaInstance(name: "ws1", status: "Running")])

        // No limactl → no affordances, instances cleared.
        var bare = HauntedTempFileSystem()
        try bare.createRoots()
        defer { bare.remove() }
        let noLima = HauntedLimaModel(
            env: HauntedLimaCLI.Environment(
                runner: harness.runner, longRunner: harness.runner, fs: bare))
        await noLima.refresh()
        #expect(!noLima.available)
        #expect(noLima.instances.isEmpty)
    }

    @Test("LIMOD-06: an in-flight op blocks a second op on the same VM")
    func busyGuard() async throws {
        let gate = GateHandler()
        let harness = try makeHarness { command in
            if command.contains("start 'ws9'") { gate.waitUntilOpened() }
            if command.contains(" list --json") { return Data("[]".utf8) }
            return Data()
        }
        defer { harness.tearDown() }

        harness.model.start(name: "ws9")
        try await waitUntil({ harness.model.isBusy("ws9") })
        harness.model.stop(name: "ws9") // must be refused while starting
        gate.open()
        try await waitUntil({ harness.model.ops["ws9"] == nil })

        let commands = harness.runner.invocations.compactMap(\.command)
        #expect(!commands.contains { $0.contains("stop 'ws9'") },
                "a second op ran while the first was in flight")
    }
}

/// A tiny latch the fake runner can block on, so a test can hold one stage
/// open long enough to prove the busy guard.
final class GateHandler: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func waitUntilOpened() { semaphore.wait() }
}
