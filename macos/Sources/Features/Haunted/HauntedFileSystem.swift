import Foundation

/// The filesystem roots this app resolves paths against: the user's home (state
/// dir, `~/.config/dedmesh/*.toml`, the `~/.local/bin` tool candidate) and
/// Application Support (the generated attach-loop helper).
///
/// A seam rather than an environment variable, because
/// `FileManager.homeDirectoryForCurrentUser` reads the passwd database and
/// ignores `HOME` — nothing a test can set moves it. Without the seam, every
/// test that touches enrollment or the attach loop would read and write the
/// developer's real `~`.
///
/// The two file probes travel with the roots for the same reason: the
/// `/opt/homebrew` and `/usr/local` tool candidates live outside any root, so
/// whether the machine running the test happens to have `haunted` installed
/// would otherwise leak into every command string the app builds.
protocol HauntedFileSystem: Sendable {
    var homeDirectory: URL { get }
    var applicationSupportDirectory: URL { get }
    func isReadableFile(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

struct HauntedRealFileSystem: HauntedFileSystem {
    var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func isReadableFile(atPath path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)
    }
}

/// `Self == HauntedRealFileSystem` (rather than a bare protocol extension) is
/// what makes `fs: HauntedFileSystem = .real` legal as a default argument.
extension HauntedFileSystem where Self == HauntedRealFileSystem {
    static var real: HauntedRealFileSystem { HauntedRealFileSystem() }
}
