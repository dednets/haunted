import Foundation

/// Ensures this Mac's own DedNets workstation stack: `dedmeshd` (mesh
/// transport, workstation role) plus `haunted-daemon` (the session backend it
/// fronts) — is running, so a machine configured to host sessions shows up
/// online in the sidebar without the user starting anything by hand. Only
/// acts where a local `~/.config/dedmesh/*.toml` exists (this Mac is itself
/// enrolled as a workstation, not just a client); a pure client install does
/// nothing here.
enum HauntedWorkstationSupervisor {
    /// The two dependencies travel as one value: every entry point needs both,
    /// and threading them as separate defaulted parameters through the private
    /// helpers would double the noise for no extra reach.
    struct Environment: Sendable {
        let runner: HauntedProcessRunning
        let fs: HauntedFileSystem

        init(
            runner: HauntedProcessRunning = HauntedProcessRunner.shared,
            fs: HauntedFileSystem = .real
        ) {
            self.runner = runner
            self.fs = fs
        }

        /// Computed, never stored: as a `static let` this froze the process's
        /// real home directory the first time anything touched the supervisor.
        var configDir: URL {
            fs.homeDirectory
                .appendingPathComponent(".config/dedmesh", isDirectory: true)
        }
    }

    /// Best-effort: a handful of quick process checks/spawns, never throws.
    /// Returns true if it had to start something new, so the caller can give
    /// the console a moment to see it online before rendering the sidebar.
    static func ensureRunning(env: Environment = .init()) async -> Bool {
        guard let configs = try? env.fs.contentsOfDirectory(at: env.configDir)
            .filter({ $0.pathExtension == "toml" }), !configs.isEmpty else {
            return false
        }

        // dedmeshd only probes its workstation socket at startup and every
        // 30s after — haunted-daemon must already be listening before a
        // freshly spawned dedmeshd starts, or the console won't see it online
        // for up to 30s.
        let startedHauntedDaemon = ensureHauntedDaemon(env)

        var startedDedmeshd = false
        for config in configs where !isDedmeshdRunning(config: config, env) {
            spawnDedmeshd(config: config, env)
            startedDedmeshd = true
        }

        return startedHauntedDaemon || startedDedmeshd
    }

    /// haunted-daemon guards itself against a second instance with its own
    /// pidfile (see apps/daemon/src/main.c), so calling this unconditionally
    /// on every launch is safe — it exits 1 without side effects if one is
    /// already up.
    private static func ensureHauntedDaemon(_ env: Environment) -> Bool {
        let daemon = HauntedCLI.quote(HauntedCLI.resolve("haunted-daemon", fs: env.fs))
        return env.runner.runToCompletion(
            executable: "/bin/zsh",
            arguments: ["-lc", "\(daemon) --daemonize"]) == 0
    }

    /// POSIX ERE metacharacters, escaped so a path matches literally.
    /// Backslash first, or it would re-escape the ones added after it.
    static func eresEscaped(_ value: String) -> String {
        var escaped = value
        for metacharacter in ["\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"] {
            escaped = escaped.replacingOccurrences(
                of: metacharacter, with: "\\" + metacharacter)
        }
        return escaped
    }

    /// dedmeshd has no built-in duplicate guard — two instances sharing an
    /// identity fight the console for the connection — so check ourselves
    /// before spawning one.
    ///
    /// `pgrep -f` takes a POSIX **extended regular expression**, not a literal,
    /// and the pattern reaches it as a raw argv element (no shell in between).
    /// An unescaped config path misbehaves in both directions: a path holding
    /// `+` fails to match the daemon actually running it, so a second dedmeshd
    /// spawns and the two fight the console for one identity; and its `.`/`+`
    /// wildcards can match a *different* daemon's path, so one that should start
    /// never does. Escape the path, and pass `--` so a path beginning with `-`
    /// is never read as a flag.
    private static func isDedmeshdRunning(config: URL, _ env: Environment) -> Bool {
        let pattern = "dedmeshd -config \(eresEscaped(config.path))"
        return env.runner.runToCompletion(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "--", pattern]) == 0
    }

    /// Runs through the login shell so PATH resolves the user-installed
    /// binary, same as HauntedCLI. Fire-and-forget: dedmeshd runs
    /// indefinitely and outlives this launch, detached from our Process
    /// object (Foundation does not kill children on Process deinit).
    private static func spawnDedmeshd(config: URL, _ env: Environment) {
        let dedmeshd = HauntedCLI.quote(HauntedCLI.resolve("dedmeshd", fs: env.fs))
        env.runner.spawnDetached(
            executable: "/bin/zsh",
            arguments: ["-lc", "exec \(dedmeshd) -config \(HauntedCLI.quote(config.path))"])
    }
}
