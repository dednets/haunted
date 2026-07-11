import Testing
import AppKit
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.x — PASTE-01…PASTE-05: Ctrl+V image paste into a remote
/// session (HauntedImagePaste). The image crosses the wire as an upload and
/// the REMOTE path is what gets typed; every boundary here is either
/// key-routing (must not steal ordinary keystrokes) or a trust boundary (the
/// daemon's reply is typed into a terminal).
struct HauntedImagePasteTests {
    // MARK: PASTE-02 — key routing

    @Test("PASTE-02: only a plain ctrl+V is the image-paste key",
          arguments: [
            ("v", NSEvent.ModifierFlags.control, true),
            ("v", [.control, .capsLock], true),
            ("v", [.command], false),          // text paste stays Ghostty's
            ("v", [.control, .command], false),
            ("v", [.control, .shift], false),  // user bindings keep meaning
            ("v", [.control, .option], false),
            ("c", [.control], false),
            ("", [.control], false),
          ] as [(String, NSEvent.ModifierFlags, Bool)])
    func imagePasteKey(chars: String, mods: NSEvent.ModifierFlags, expected: Bool) {
        #expect(HauntedImagePaste.isImagePasteKey(
            characters: chars, modifiers: mods) == expected)
    }

    @Test("PASTE-02: nil characters never match")
    func nilCharacters() {
        #expect(!HauntedImagePaste.isImagePasteKey(
            characters: nil, modifiers: .control))
    }

    // MARK: PASTE-03 — the remote path grammar (a trust boundary)

    @Test("PASTE-03: a well-formed daemon reply is accepted, trimmed")
    func remotePathAccepted() {
        let raw = "/home/u/.cache/haunted/uploads/up-17-3-paste.png\n"
        #expect(HauntedImagePaste.sanitizedRemotePath(raw)
                == "/home/u/.cache/haunted/uploads/up-17-3-paste.png")
    }

    @Test("PASTE-03: hostile or malformed replies are dropped",
          arguments: [
            "up-17-3-paste.png",                    // relative
            "/tmp/../etc/passwd",                   // traversal
            "/tmp/a b.png",                         // whitespace splits args
            "/tmp/x;rm -rf ~",                      // shell metacharacters
            "/tmp/x\u{1b}]0;pwn\u{07}.png",         // escape injection
            "/tmp/x\npwd",                          // second line
            "",
            "/" + String(repeating: "a", count: 1100), // over the cap
          ])
    func remotePathRejected(raw: String) {
        #expect(HauntedImagePaste.sanitizedRemotePath(raw) == nil)
    }

    // MARK: PASTE-04 — pasteboard reading (a private, uniquely named board)

    @Test("PASTE-04: a PNG flavor is used as-is; text-only and empty are nil")
    func pasteboardPNG() throws {
        let board = NSPasteboard(name: .init("haunted-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        board.clearContents()
        #expect(HauntedImagePaste.pngData(from: board) == nil)

        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(HauntedImagePaste.pngData(from: board) == nil)

        let png = try #require(Self.tinyImagePNG())
        board.clearContents()
        board.setData(png, forType: .png)
        #expect(HauntedImagePaste.pngData(from: board) == png)
    }

    @Test("PASTE-04: a TIFF flavor (screenshots) transcodes to PNG")
    func pasteboardTIFF() throws {
        let board = NSPasteboard(name: .init("haunted-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        let tiff = try #require(Self.tinyImageTIFF())
        board.clearContents()
        board.setData(tiff, forType: .tiff)
        let data = try #require(HauntedImagePaste.pngData(from: board))
        // PNG magic: the transcode really produced a PNG.
        #expect([UInt8](data.prefix(4)) == [0x89, 0x50, 0x4e, 0x47])
    }

    // MARK: PASTE-05 — the upload subprocess and the typed result

    @Test("PASTE-05: HauntedCLI.upload runs the exact argv and sanitizes")
    func uploadArgv() async throws {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/tmp/hstate"), console: nil)
        let runner = FakeProcessRunner(runHandler: { _ in
            Data("/home/u/.cache/haunted/uploads/up-1-0-paste.png\n".utf8)
        })
        let fs = HauntedTempFileSystem()

        let path = try await HauntedCLI.upload(
            identity: identity, target: "u/box/term", name: "paste.png",
            filePath: "/tmp/t.png", runner: runner, fs: fs)
        #expect(path == "/home/u/.cache/haunted/uploads/up-1-0-paste.png")
        #expect(runner.invocations.map(\.command) == [
            "'haunted' upload '/tmp/t.png' --state-dir '/tmp/hstate' "
                + "--target 'u/box/term' --name 'paste.png'",
        ])
    }

    @Test("PASTE-05: a malformed daemon reply throws instead of typing")
    func uploadMalformedReply() async {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/tmp/hstate"), console: nil)
        let runner = FakeProcessRunner(runHandler: { _ in
            Data("\u{1b}]0;pwn\u{07}\n".utf8)
        })
        await #expect(throws: HauntedCLIError.self) {
            _ = try await HauntedCLI.upload(
                identity: identity, target: "u/box/term", name: "paste.png",
                filePath: "/tmp/t.png", runner: runner)
        }
    }

    /// A quote in a target is fine — `quote()` escapes it, same as the C CLI
    /// — so "unsafe" here means what isSafeCLIArgument rejects everywhere
    /// else: control characters (escape injection) and flag-shaped values.
    @Test("PASTE-05: an unsafe target never reaches an argv",
          arguments: ["u/box\u{1b}term", "-target", ""])
    func uploadUnsafeTarget(target: String) async {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/tmp/hstate"), console: nil)
        let runner = FakeProcessRunner()
        await #expect(throws: HauntedCLIError.self) {
            _ = try await HauntedCLI.upload(
                identity: identity, target: target,
                name: "paste.png", filePath: "/tmp/t.png", runner: runner)
        }
        #expect(runner.invocations.isEmpty)
    }

    @MainActor
    @Test("PASTE-05: the flow types 'path + space', exactly once")
    func uploadAndPasteTypesPath() async throws {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/tmp/hstate"), console: nil)
        let runner = FakeProcessRunner(runHandler: { _ in
            Data("/x/up-9-1-paste.png\n".utf8)
        })
        var typed: [String] = []
        await HauntedImagePaste.uploadAndPaste(
            png: Data([0x89]), identity: identity, target: "u/box/term",
            surfaceView: nil, runner: runner) { typed.append($0) }
        #expect(typed == ["/x/up-9-1-paste.png "])
    }

    @MainActor
    @Test("PASTE-05: a failed upload types nothing")
    func uploadFailureTypesNothing() async {
        struct Boom: Error {}
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/tmp/hstate"), console: nil)
        let runner = FakeProcessRunner(runHandler: { _ in throw Boom() })
        var typed: [String] = []
        await HauntedImagePaste.uploadAndPaste(
            png: Data([0x89]), identity: identity, target: "u/box/term",
            surfaceView: nil, runner: runner) { typed.append($0) }
        #expect(typed.isEmpty)
    }

    // MARK: PASTE-01 — the keyDown hook survives upstream rebases

    /// SurfaceView.keyDown is upstream-owned; a rebase can silently drop the
    /// six-line Haunted hook, and every symptom would be "Ctrl+V does
    /// nothing again" — precisely the bug this feature exists to fix.
    @Test("PASTE-01: SurfaceView.keyDown still consults HauntedImagePaste")
    func keyDownHookPresent() throws {
        let surfaceView = Self.sourcesDirectory
            .appendingPathComponent("Ghostty/Surface View/SurfaceView_AppKit.swift")
        let contents = try String(contentsOf: surfaceView, encoding: .utf8)
        try #require(contents.contains("override func keyDown"),
                     "upstream restructured keyDown; re-site the Haunted hook")
        #expect(contents.contains(
            "HauntedImagePaste.intercept(event: event, surfaceView: self)"), """
            SurfaceView.keyDown no longer routes Ctrl+V through \
            HauntedImagePaste. An image paste into a remote session will send \
            a bare 0x16, the app on the workstation will read its own (empty) \
            clipboard, and image paste silently regresses to broken.
            """)
    }

    // MARK: Helpers

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)   // macos/Tests/Haunted/<this>.swift
            .deletingLastPathComponent()  // macos/Tests/Haunted
            .deletingLastPathComponent()  // macos/Tests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private static func tinyImageRep() -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        return rep
    }

    private static func tinyImagePNG() -> Data? {
        tinyImageRep()?.representation(using: .png, properties: [:])
    }

    private static func tinyImageTIFF() -> Data? {
        tinyImageRep()?.tiffRepresentation
    }
}
