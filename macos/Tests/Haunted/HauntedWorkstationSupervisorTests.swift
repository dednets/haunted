import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.2 — SUP-01..09.
///
/// Everything here drives `HauntedWorkstationSupervisor.ensureRunning(env:)` end
/// to end, never the private helpers: the property SUP-04 protects is the *order*
/// of the child launches, and that only exists at the entry point.
///
/// Both seams are injected (§5.1 process, §5.3 filesystem), so no test forks a
/// process, reads the developer's `~/.config/dedmesh`, or depends on whether the
/// machine happens to have `haunted-daemon` installed. `HauntedTempFileSystem`
/// answers `isExecutableFile` from an explicit set, and every environment here
/// passes an empty one, so `HauntedCLI.resolve` deterministically falls through
/// to the bare tool name — the command strings below are exact, not
/// machine-dependent.
struct HauntedWorkstationSupervisorTests {
    // MARK: - Fixtures

    /// Builds a disposable HOME, optionally with `~/.config/dedmesh` and the
    /// named config files inside it. Caller owns teardown via `fs.remove()`.
    private func makeFileSystem(
        configDirExists: Bool = true,
        configFiles: [String] = []
    ) throws -> HauntedTempFileSystem {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        if configDirExists {
            let dir = configDir(fs)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in configFiles {
                try Data("# haunted test fixture\n".utf8)
                    .write(to: dir.appendingPathComponent(name))
            }
        }
        return fs
    }

    private func configDir(_ fs: HauntedTempFileSystem) -> URL {
        fs.homeDirectory.appendingPathComponent(".config/dedmesh", isDirectory: true)
    }

    private enum FixtureError: Error {
        case notInConfigDir(String)
    }

    /// The config URL the supervisor will actually observe, read back out of the
    /// same `contentsOfDirectory` listing `ensureRunning` enumerates.
    ///
    /// Deliberately not `configDir(fs).appendingPathComponent(name)`. macOS's
    /// temp root is `/var/folders/…`, a symlink into `/private/var/folders/…`, and
    /// `FileManager.contentsOfDirectory(at:)` returns the *resolved* spelling.
    /// Only that spelling ever reaches `pgrep`, so a fixture built from the
    /// unresolved one describes a process table the supervisor can never match —
    /// every "the daemon is already up" case would silently degrade into "no
    /// daemon is running". `URL.resolvingSymlinksInPath()` cannot bridge the gap
    /// either: it *strips* a leading `/private`, it never adds one.
    private func listedConfig(_ fs: HauntedTempFileSystem, _ name: String) throws -> URL {
        let listed = try fs.contentsOfDirectory(at: configDir(fs))
        guard let config = listed.first(where: { $0.lastPathComponent == name }) else {
            throw FixtureError.notInConfigDir(name)
        }
        return config
    }

    /// The command line a real `pgrep -f` would be scanning if a dedmeshd were
    /// already up for `config`. Pass a URL from `listedConfig`, never one built
    /// by hand — see that helper for why the spelling is load-bearing.
    private func runningDedmeshd(_ config: URL) -> [String] {
        ["dedmeshd -config \(config.path)"]
    }

    private func spawns(_ runner: FakeProcessRunner) -> [HauntedProcessInvocation] {
        runner.invocations.filter { $0.kind == .spawnDetached }
    }

    private func pgreps(_ runner: FakeProcessRunner) -> [HauntedProcessInvocation] {
        runner.invocations.filter { $0.executable == "/usr/bin/pgrep" }
    }

    // MARK: - SUP-01..03: nothing to supervise

    /// SUP-01. A pure client install has no `~/.config/dedmesh` at all. The
    /// supervisor must not merely skip the spawn — it must not run *anything*,
    /// including the unconditional `haunted-daemon --daemonize`.
    @Test("SUP-01: no ~/.config/dedmesh — returns false, launches nothing")
    func noConfigDirectory() async throws {
        let fs = try makeFileSystem(configDirExists: false)
        defer { fs.remove() }
        let runner = FakeProcessRunner()

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == false)
        #expect(runner.invocations.isEmpty)
    }

    /// SUP-02. The directory exists (some other dedmesh tool made it) but holds
    /// no config: this Mac is not enrolled as a workstation.
    @Test("SUP-02: config dir exists but is empty — returns false, launches nothing")
    func emptyConfigDirectory() async throws {
        let fs = try makeFileSystem()
        defer { fs.remove() }
        let runner = FakeProcessRunner()

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == false)
        #expect(runner.invocations.isEmpty)
    }

    /// SUP-03. Only `.toml` counts. A stray `a.conf` (or an editor's backup) is
    /// not a dedmeshd config and must not cause a daemon to be launched against
    /// it.
    @Test("SUP-03: non-.toml files are filtered out")
    func nonTomlFilesIgnored() async throws {
        let fs = try makeFileSystem(configFiles: ["a.conf", "b.toml.bak", "notes.txt"])
        defer { fs.remove() }
        let runner = FakeProcessRunner()

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == false)
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - SUP-04: spawn order

    /// SUP-04. `haunted-daemon --daemonize` must be launched *and waited on*
    /// before any `dedmeshd` is spawned. dedmeshd probes its workstation socket
    /// once at startup and only every 30s thereafter, so a dedmeshd that starts
    /// first reports the workstation offline for up to half a minute.
    ///
    /// This asserts the whole ordered launch log, which is only meaningful
    /// through `ensureRunning` — the private helpers know nothing about order.
    @Test("SUP-04: haunted-daemon is launched before dedmeshd")
    func spawnOrderHauntedDaemonFirst() async throws {
        let fs = try makeFileSystem(configFiles: ["one.toml"])
        defer { fs.remove() }
        // Empty process table: no dedmeshd is running, so one gets spawned.
        let runner = FakeProcessRunner(exitStatus: 0, processTable: [])

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == true)

        let invocations = runner.invocations
        #expect(invocations.map(\.kind) == [.runToCompletion, .runToCompletion, .spawnDetached])
        try #require(invocations.count == 3)

        // 1. haunted-daemon, waited on (it reports whether it started).
        #expect(invocations[0].executable == "/bin/zsh")
        #expect(invocations[0].arguments == ["-lc", "'haunted-daemon' --daemonize"])

        // 2. only then do we look for a dedmeshd...
        #expect(invocations[1].executable == "/usr/bin/pgrep")
        #expect(invocations[1].arguments.first == "-f")
        #expect(invocations[1].arguments.last?.hasPrefix("dedmeshd -config ") == true)
        // `.` is escaped for pgrep's ERE (SUP-08); the spawn below is not a regex.
        #expect(invocations[1].arguments.last?.hasSuffix("one\\.toml") == true)

        // 3. ...and only then spawn one, detached (it outlives this launch).
        #expect(invocations[2].executable == "/bin/zsh")
        try #require(invocations[2].arguments.count == 2)
        let command = invocations[2].arguments[1]
        #expect(command.hasPrefix("exec 'dedmeshd' -config '"))
        #expect(command.hasSuffix("one.toml'"))
    }

    /// SUP-04 (corollary). The pgrep pattern must reach pgrep as its own argv
    /// element. If it were ever folded into a `/bin/zsh -lc` string the shell
    /// would re-split it, and a config path containing a space would silently
    /// match nothing.
    @Test("SUP-04: the pgrep pattern is a single argv element, not a shell string")
    func pgrepPatternIsArgvNotShell() async throws {
        let fs = try makeFileSystem(configFiles: ["my config.toml"])
        defer { fs.remove() }
        let runner = FakeProcessRunner()

        _ = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        let probes = pgreps(runner)
        try #require(probes.count == 1)
        #expect(probes[0].executable == "/usr/bin/pgrep")
        // -f, --, PATTERN. The pattern is one element even though it holds a
        // space; a shell would have re-split it.
        #expect(probes[0].arguments.count == 3)
        // The `.` is escaped (SUP-08); the space is not a regex metacharacter.
        #expect(probes[0].arguments.last?.contains("my config\\.toml") == true,
                "pattern was \(probes[0].arguments.last ?? "nil")")
    }

    // MARK: - SUP-05: one of two already running

    /// SUP-05. Two configs, one daemon already up: exactly one new dedmeshd, and
    /// it is the one for the *other* config. Spawning a duplicate for `a.toml`
    /// would put two processes with one identity in front of the Console.
    @Test("SUP-05: two configs, one daemon running — exactly one dedmeshd spawned")
    func spawnsOnlyMissingDedmeshd() async throws {
        let fs = try makeFileSystem(configFiles: ["a.toml", "b.toml"])
        defer { fs.remove() }
        let running = try listedConfig(fs, "a.toml")
        let runner = FakeProcessRunner(processTable: runningDedmeshd(running))

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == true)
        // Both configs are probed. `contentsOfDirectory` gives no order guarantee,
        // so nothing here may depend on which was probed first.
        #expect(pgreps(runner).count == 2)

        let launched = spawns(runner)
        try #require(launched.count == 1)
        let command = launched[0].arguments.last ?? ""
        #expect(command.hasSuffix("b.toml'"))
        #expect(!command.contains("a.toml"))
    }

    // MARK: - SUP-06/07: what the return value means

    /// SUP-06. `haunted-daemon` exits 1 when its pidfile guard finds an existing
    /// instance — that is a normal, side-effect-free no-op, not a failure. It
    /// must not suppress the dedmeshd spawn, and `ensureRunning` must still
    /// report `true` because *something* was started.
    @Test("SUP-06: haunted-daemon already up (exit 1) — dedmeshd still spawned, returns true")
    func hauntedDaemonAlreadyRunning() async throws {
        let fs = try makeFileSystem(configFiles: ["one.toml"])
        defer { fs.remove() }
        // exitStatus applies to every non-pgrep runToCompletion: haunted-daemon
        // reports 1, the pidfile guard having refused a second instance.
        let runner = FakeProcessRunner(exitStatus: 1, processTable: [])

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == true, "a dedmeshd was spawned, so the caller must wait for it")
        #expect(spawns(runner).count == 1)
    }

    /// SUP-07. Everything is already up. `false` is load-bearing: the caller
    /// skips its online-wait and renders the sidebar immediately.
    @Test("SUP-07: nothing to start — returns false, no dedmeshd spawned")
    func nothingToStart() async throws {
        let fs = try makeFileSystem(configFiles: ["one.toml"])
        defer { fs.remove() }
        let running = try listedConfig(fs, "one.toml")
        let runner = FakeProcessRunner(exitStatus: 1, processTable: runningDedmeshd(running))

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == false)
        #expect(spawns(runner).isEmpty)
    }

    /// SUP-07 (control). The same fixture with a *stopped* daemon must return
    /// true — otherwise SUP-07 would pass for the wrong reason (e.g. the
    /// fake's pgrep matching everything).
    @Test("SUP-07: control — same config with no daemon running returns true")
    func nothingToStartControl() async throws {
        let fs = try makeFileSystem(configFiles: ["one.toml"])
        defer { fs.remove() }
        let runner = FakeProcessRunner(
            exitStatus: 1, processTable: ["dedmeshd -config /somewhere/else.toml"])

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == true)
        #expect(spawns(runner).count == 1)
    }

    // MARK: - SUP-08: pgrep -f takes an ERE (confirmed bug, expected red)

    /// SUP-08 — regression test for the fixed ERE-injection bug.
    /// See TEST_PLAN §4.2 SUP-08.
    ///
    /// `pgrep -f PATTERN` interprets PATTERN as a POSIX extended regular
    /// expression, not a literal. The supervisor used to hand it a raw filesystem
    /// path, so a config named `a+b.toml` produced a pattern in which `a+` means
    /// "one or more `a`" — it could never match the literal text `a+b`. pgrep
    /// exited 1, the supervisor concluded no daemon was running, and spawned a
    /// second `dedmeshd` for an identity that already had one. The two then
    /// fought the Console for that identity's connection.
    ///
    /// The fake's pgrep matches with a real regex engine for exactly this reason:
    /// a substring-matching fake would make this test pass and prove nothing.
    @Test("SUP-08: a config path with an ERE metacharacter must not double-spawn dedmeshd")
    func pgrepPatternIsEscaped() async throws {
        let fs = try makeFileSystem(configFiles: ["a+b.toml"])
        defer { fs.remove() }
        let config = try listedConfig(fs, "a+b.toml")
        // The daemon for this exact config IS running.
        let runner = FakeProcessRunner(exitStatus: 1, processTable: runningDedmeshd(config))

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        // Evidence: the path reached pgrep with its metacharacters escaped, and
        // behind a `--` so a leading `-` could not be read as a flag.
        let probes = pgreps(runner)
        try #require(probes.count == 1)
        #expect(probes[0].arguments.contains("--"))
        #expect(probes[0].arguments.last?.contains("a\\+b\\.toml") == true,
                "pattern was \(probes[0].arguments.last ?? "nil")")

        #expect(
            spawns(runner).isEmpty,
            "a dedmeshd is already running for \(config.path); spawning a second one makes two processes fight the Console for one identity")
        #expect(started == false)
    }

    /// The escaper itself. Every POSIX ERE metacharacter must survive as a
    /// literal; backslash must be escaped first or it re-escapes the rest.
    /// Cross-checked against the real /usr/bin/pgrep, not only this fake.
    @Test("SUP-08: eresEscaped neutralizes every ERE metacharacter", arguments: [
        ("a+b", "a\\+b"),
        ("a.b", "a\\.b"),
        ("a*b", "a\\*b"),
        ("a?b", "a\\?b"),
        ("a(b)c", "a\\(b\\)c"),
        ("a[b]c", "a\\[b\\]c"),
        ("a{1}b", "a\\{1\\}b"),
        ("a|b", "a\\|b"),
        ("^ab$", "\\^ab\\$"),
        ("a\\b", "a\\\\b"),           // backslash escaped exactly once
        ("plain/path.toml", "plain/path\\.toml"),
        ("no-metachars_here", "no-metachars_here"),
    ])
    func eresEscaping(input: String, expected: String) {
        #expect(HauntedWorkstationSupervisor.eresEscaped(input) == expected)
    }

    /// The escaped pattern must match its own literal text under a real regex
    /// engine — the property that actually matters, rather than the exact
    /// spelling of the escape.
    @Test("SUP-08: an escaped path matches itself and nothing adjacent")
    func eresEscapedRoundTrips() throws {
        let path = "/home/u/.config/dedmesh/a+b.toml"
        let regex = try NSRegularExpression(
            pattern: HauntedWorkstationSupervisor.eresEscaped(path))
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        #expect(matches(path))
        #expect(!matches("/home/u/.config/dedmesh/ab.toml"), "the `a+` wildcard must be dead")
        #expect(!matches("/home/u/.config/dedmesh/aab.toml"))
        #expect(!matches("/home/u/Xconfig/dedmesh/a+b.toml"), "the `.` wildcard must be dead")
    }

    /// The other direction of SUP-08, which the plan did not name: an unescaped
    /// `a+b.toml` pattern also *falsely matches* a daemon running `ab.toml`, so a
    /// daemon that should start never does. Both were verified against the real
    /// /usr/bin/pgrep, not just this fake.
    @Test("SUP-08: an escaped pattern must not match a different daemon's config")
    func pgrepPatternDoesNotFalselyMatch() async throws {
        let fs = try makeFileSystem(configFiles: ["a+b.toml"])
        defer { fs.remove() }
        let config = try listedConfig(fs, "a+b.toml")

        // A *different* daemon is running: ab.toml, which the unescaped ERE
        // `a+b\.toml` would have matched.
        let other = config.deletingLastPathComponent().appendingPathComponent("ab.toml")
        let runner = FakeProcessRunner(exitStatus: 1, processTable: runningDedmeshd(other))

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(spawns(runner).count == 1,
                "no daemon is running a+b.toml; one must be started")
        #expect(started == true)
    }

    /// SUP-08 (sanity). Strip the metacharacter and the very same fixture
    /// detects the daemon. This is what pins the failure above on the ERE, not
    /// on the fixture.
    @Test("SUP-08: sanity — a metacharacter-free config path is detected correctly")
    func plainPathIsDetected() async throws {
        let fs = try makeFileSystem(configFiles: ["ab.toml"])
        defer { fs.remove() }
        let running = try listedConfig(fs, "ab.toml")
        let runner = FakeProcessRunner(exitStatus: 1, processTable: runningDedmeshd(running))

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(spawns(runner).isEmpty)
        #expect(started == false)
    }

    // MARK: - SUP-09: pgrep cannot be launched

    /// SUP-09. `/usr/bin/pgrep` missing (or not executable) makes `Process.run()`
    /// throw; the runner reports -1. The supervisor must not crash, and must
    /// treat "could not ask" as "not running" — the fail-safe direction here is
    /// to start the daemon, since a workstation with no dedmeshd is useless
    /// while a duplicate is merely noisy.
    ///
    /// TEST_PLAN's "returns false" for this row is the private
    /// `isDedmeshdRunning` helper's answer; `ensureRunning` necessarily returns
    /// true, because it did start something.
    @Test("SUP-09: pgrep cannot be launched — no crash, daemon treated as not running")
    func pgrepMissing() async throws {
        let fs = try makeFileSystem(configFiles: ["one.toml"])
        defer { fs.remove() }
        let runner = MissingPgrepRunner()

        let started = await HauntedWorkstationSupervisor.ensureRunning(
            env: .init(runner: runner, fs: fs))

        #expect(started == true)
        let launched = runner.invocations.filter { $0.kind == .spawnDetached }
        #expect(launched.count == 1)
        #expect(launched.first?.arguments.last?.contains("one.toml") == true)
    }

    /// A runner whose `/usr/bin/pgrep` never launches, reporting -1 exactly as
    /// `HauntedProcessRunner.runToCompletion` does when `Process.run()` throws.
    /// `FakeProcessRunner` always emulates pgrep, so it cannot express this.
    final class MissingPgrepRunner: HauntedProcessRunning, @unchecked Sendable {
        private var log: [HauntedProcessInvocation] = []
        private let lock = NSLock()

        var invocations: [HauntedProcessInvocation] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }

        func run(_ command: String) async throws -> Data {
            record(.init(kind: .run, executable: "/bin/zsh", arguments: ["-lc", command]))
            return Data()
        }

        @discardableResult
        func runToCompletion(executable: String, arguments: [String]) -> Int32 {
            record(.init(kind: .runToCompletion, executable: executable, arguments: arguments))
            return executable == "/usr/bin/pgrep" ? -1 : 0
        }

        @discardableResult
        func spawnDetached(executable: String, arguments: [String]) -> Bool {
            record(.init(kind: .spawnDetached, executable: executable, arguments: arguments))
            return true
        }

        private func record(_ invocation: HauntedProcessInvocation) {
            lock.lock()
            log.append(invocation)
            lock.unlock()
        }
    }
}
