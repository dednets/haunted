import Foundation

/// Ensures this Mac's own DedMesh workstation stack — `dedmeshd` (mesh
/// transport, workstation role) plus `haunted-daemon` (the session backend it
/// fronts) — is running, so a machine configured to host sessions shows up
/// online in the sidebar without the user starting anything by hand. Only
/// acts where a local `~/.config/dedmesh/*.toml` exists (this Mac is itself
/// enrolled as a workstation, not just a client); a pure client install does
/// nothing here.
enum HauntedWorkstationSupervisor {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dedmesh", isDirectory: true)

    /// Best-effort: a handful of quick process checks/spawns, never throws.
    /// Returns true if it had to start something new, so the caller can give
    /// the console a moment to see it online before rendering the sidebar.
    static func ensureRunning() async -> Bool {
        guard let configs = try? FileManager.default.contentsOfDirectory(
            at: configDir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "toml" }), !configs.isEmpty else {
            return false
        }

        // dedmeshd only probes its workstation socket at startup and every
        // 30s after — haunted-daemon must already be listening before a
        // freshly spawned dedmeshd starts, or the console won't see it online
        // for up to 30s.
        let startedHauntedDaemon = ensureHauntedDaemon()

        var startedDedmeshd = false
        for config in configs where !isDedmeshdRunning(config: config) {
            spawnDedmeshd(config: config)
            startedDedmeshd = true
        }

        return startedHauntedDaemon || startedDedmeshd
    }

    /// haunted-daemon guards itself against a second instance with its own
    /// pidfile (see apps/daemon/src/main.c), so calling this unconditionally
    /// on every launch is safe — it exits 1 without side effects if one is
    /// already up.
    private static func ensureHauntedDaemon() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc", "\(HauntedCLI.quote(HauntedCLI.resolve("haunted-daemon"))) --daemonize",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// dedmeshd has no built-in duplicate guard — two instances sharing an
    /// identity fight the console for the connection — so check ourselves
    /// before spawning one.
    private static func isDedmeshdRunning(config: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "dedmeshd -config \(config.path)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs through the login shell so PATH resolves the user-installed
    /// binary, same as HauntedCLI. Fire-and-forget: dedmeshd runs
    /// indefinitely and outlives this launch, detached from our Process
    /// object (Foundation does not kill children on Process deinit).
    private static func spawnDedmeshd(config: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "exec \(HauntedCLI.quote(HauntedCLI.resolve("dedmeshd"))) -config \(HauntedCLI.quote(config.path))",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }
}
