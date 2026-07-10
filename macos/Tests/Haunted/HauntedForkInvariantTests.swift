import Testing
import AppKit
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.6 — INV-09, INV-11.
///
/// "Never a plain local terminal" is the invariant a rebase onto upstream
/// Ghostty will silently break: upstream adds a `TerminalController.newWindow`
/// call site, and the app quietly opens an unattached local shell. INV-11 is
/// the cheapest possible guard and the only one that survives a rebase, so it
/// is pulled forward out of Phase 5.
struct HauntedForkInvariantTests {
    // MARK: INV-09 — window restoration is disabled unconditionally

    /// The app always starts in Haunted mode via `HauntedLoginController.startup()`,
    /// so a restored local terminal would violate the "never local" rule. The
    /// fork returns `(nil, nil)` before decoding any state, whatever
    /// `window-save-state` says.
    @MainActor
    @Test("INV-09: restoreWindow always completes with no window and no error")
    func restorationDisabled() throws {
        try #require(NSApplication.shared.delegate is AppDelegate,
                     "INV-09 needs the Ghostty test host's AppDelegate")

        // Never read: the fork returns before decoding.
        let coder = try NSKeyedUnarchiver(forReadingFrom: {
            let archiver = NSKeyedArchiver(requiringSecureCoding: false)
            archiver.finishEncoding()
            return archiver.encodedData
        }())

        var called = false
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: coder
        ) { window, error in
            called = true
            #expect(window == nil)
            #expect(error == nil)
        }
        #expect(called, "completionHandler must be called synchronously")
    }

    @MainActor
    @Test("INV-09: an unknown identifier still errors out")
    func restorationRejectsUnknownIdentifier() throws {
        let coder = try NSKeyedUnarchiver(forReadingFrom: {
            let archiver = NSKeyedArchiver(requiringSecureCoding: false)
            archiver.finishEncoding()
            return archiver.encodedData
        }())

        var received: (any Error)?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init("NotOurIdentifier"), state: coder
        ) { _, error in received = error }
        #expect(received != nil)
    }

    // MARK: INV-11 — no new plain-window call sites

    /// Every `TerminalController.newWindow` call site in `macos/Sources`, pinned.
    ///
    /// A rebase that introduces a new one fails this test. Each entry is
    /// classified: `haunted` sites open attached sessions, `moves-surfaces`
    /// re-homes an existing (already-attached) surface tree into a new window,
    /// and `PLAIN-LOCAL` sites open an unattached local shell — a live hole in
    /// the invariant, recorded here so it is visible rather than assumed absent.
    ///
    /// Do not silence a failure by bumping a count. Route the new call site
    /// through `HauntedManager` / `HauntedLoginController`, or add it below with
    /// its classification.
    private static let expectedNewWindowCallSites: [String: Int] = [
        // Haunted-owned: the sanctioned ways to get a window — one attached
        // (resume), one straight into the "Nothing here" empty state.
        "Features/Haunted/HauntedManager.swift": 2,

        // Internal recursion/dispatch inside newWindow itself.
        "Features/Terminal/TerminalController.swift": 3,

        // Re-homes an existing surface tree (drag a split out of a window).
        // The surfaces are already attached; no new local shell is spawned.
        "Features/Terminal/BaseTerminalController.swift": 1,

        // PLAIN-LOCAL: these still open an unattached local shell.
        // See TEST_PLAN.md §4.6 / docs/haunted.md.
        "App/macOS/AppDelegate.swift": 1,                       // dock drop, macos-dock-drop-behavior=new_window
        "Features/AppleScript/AppDelegate+AppleScript.swift": 1,
        "Features/App Intents/NewTerminalIntent.swift": 1,
        "Features/Services/ServiceProvider.swift": 1,
    ]

    @Test("INV-11: TerminalController.newWindow call sites are pinned")
    func newWindowCallSitesArePinned() throws {
        let sources = Self.sourcesDirectory
        var found: [String: Int] = [:]

        let files = try Self.swiftFiles(under: sources)
        try #require(!files.isEmpty, "found no Swift sources under \(sources.path)")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            // Match the qualified static call and the bare recursive call
            // inside TerminalController itself.
            let count = contents
                .components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { return false }
                    return trimmed.contains("TerminalController.newWindow(")
                        || trimmed.contains("return newWindow(")
                }
                .count
            if count > 0 {
                let relative = file.path.replacingOccurrences(
                    of: sources.path + "/", with: "")
                found[relative] = count
            }
        }

        #expect(found == Self.expectedNewWindowCallSites, """
            TerminalController.newWindow call sites changed.
            expected: \(Self.expectedNewWindowCallSites.sorted { $0.key < $1.key })
            found:    \(found.sorted { $0.key < $1.key })
            A new call site must go through HauntedManager/HauntedLoginController,
            or be added to expectedNewWindowCallSites with a classification.
            """)
    }

    // MARK: EXIT-01 — the session dies with its process

    /// TEST_PLAN §4.7. When the remote shell exits — `exit`, or ctrl-D — the
    /// daemon reaps the session, and the sidebar row must vanish with it rather
    /// than linger up to ten seconds until the next poll and invite a click that
    /// reattaches to a corpse.
    ///
    /// The hook that makes that immediate is **six lines inside an upstream
    /// file** (`Ghostty/Ghostty.App.swift`, the `childExited` action). It is the
    /// most rebase-fragile part of the whole feature: upstream owns that switch,
    /// a conflict resolution that takes "theirs" drops the post silently, and
    /// nothing else in the app would notice. Hence a grep, not a runtime test.
    @Test("EXIT-01: the childExited action still refreshes the sidebar")
    func childExitedRefreshesSidebar() throws {
        let app = Self.sourcesDirectory
            .appendingPathComponent("Ghostty/Ghostty.App.swift")
        let contents = try String(contentsOf: app, encoding: .utf8)

        try #require(contents.contains("showChildExited"),
                     "upstream renamed the child-exited action; the Haunted hook needs re-siting")
        #expect(contents.contains("hauntedSessionsDidChange"), """
            Ghostty.App.swift no longer posts .hauntedSessionsDidChange when a \
            surface's process exits. A remote session that ended by `exit`/ctrl-D \
            will linger in the sidebar until the next 10s poll, and clicking it \
            reattaches to a session the daemon has already reaped.
            """)
    }

    /// The exit path's other half: `waitAfterCommand` keeps the tab open showing
    /// the exit banner. Removing it would close the surface, and an empty surface
    /// tree closes the window — which reads to the user as the app crashing.
    @Test("EXIT-02: the attached surface keeps its exit banner")
    func attachedSurfaceWaitsAfterCommand() throws {
        let manager = Self.sourcesDirectory
            .appendingPathComponent("Features/Haunted/HauntedManager.swift")
        let contents = try String(contentsOf: manager, encoding: .utf8)
        #expect(contents.contains("config.waitAfterCommand = true"))
    }

    /// KILL-01. The fork's `TerminalController.surfaceTreeDidChange` overrides
    /// upstream's "empty surface tree closes the window" with a `hauntedEmptyState`
    /// exception. That exception is *the* crash fix: closing the window on the
    /// last session freed the attached SurfaceView while libghostty was still
    /// delivering a scrollbar action into it (a use-after-free that aborted the
    /// app). Upstream owns this method; a rebase that resolves the conflict as
    /// "theirs" silently drops the guard and the crash returns — hence a grep.
    @Test("KILL-01: the empty-tree close still honours the Haunted empty state")
    func emptyTreeCloseHonoursEmptyState() throws {
        let controller = Self.sourcesDirectory
            .appendingPathComponent("Features/Terminal/TerminalController.swift")
        let contents = try String(contentsOf: controller, encoding: .utf8)
        // Normalize whitespace so the guard survives reformatting but still
        // pins the *branch*, not merely the flag's declaration — an upstream
        // "theirs" resolution of surfaceTreeDidChange drops the branch while
        // the fork-added property survives, and that must fail loudly.
        let normalized = contents
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalized.contains("if hauntedEmptyState {"), """
            TerminalController.surfaceTreeDidChange no longer guards the \
            empty-surface-tree close with `if hauntedEmptyState`. Killing the \
            last session will close the window and crash (SurfaceView freed \
            under a live libghostty action) instead of showing the "Nothing \
            here" empty state.
            """)
    }

    /// The invariant's other half: the `newWindow:`/`newTab:` menu actions and
    /// the dock-reopen handler must all funnel into `HauntedLoginController`.
    @Test("INV-11: AppDelegate window entry points route through Haunted")
    func appDelegateRoutesThroughHaunted() throws {
        let appDelegate = Self.sourcesDirectory
            .appendingPathComponent("App/macOS/AppDelegate.swift")
        let contents = try String(contentsOf: appDelegate, encoding: .utf8)
        #expect(contents.contains("HauntedLoginController.startup()"),
                "AppDelegate no longer routes through the Haunted startup gate")

        // TEST_PLAN INV-06 calls the dock-reopen hook `applicationOpenUntitledFile`;
        // the fork actually overrides `applicationShouldHandleReopen`.
        for entryPoint in ["func newWindow(", "func newTab(", "applicationShouldHandleReopen"] {
            #expect(contents.contains(entryPoint), "missing entry point \(entryPoint)")
        }
    }

    // MARK: BUG-13 — nothing may wait on a child with waitUntilExit

    /// `Process.waitUntilExit` spins the calling thread's run loop and, called
    /// from a dispatch worker, can miss the termination wakeup and block
    /// forever after the child is gone. That shipped as BUG-13: the sidebar's
    /// poll loop awaited a `run()` wedged exactly there (observed live:
    /// `waitUntilExit → CFRunLoopRun → mach_msg`, 100% of a 2s sample), so the
    /// sidebar silently never refreshed again — frozen titles, ⌘T/⌘D sessions
    /// that never appeared. The replacement is `terminationHandler` plus a
    /// deadline (RUN-09…11); this grep keeps the hazard from being
    /// reintroduced by a refactor or an upstream rebase.
    @Test("BUG-13: no Swift source waits on a child with waitUntilExit")
    func noWaitUntilExitAnywhere() throws {
        let files = try Self.swiftFiles(under: Self.sourcesDirectory)
        try #require(!files.isEmpty)

        var offenders: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), trimmed.contains("waitUntilExit") else {
                    continue
                }
                offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
            }
        }
        #expect(offenders.isEmpty, """
            waitUntilExit is banned — it hangs forever on a missed termination \
            wakeup (BUG-13, froze the sidebar in production). Wait via \
            terminationHandler with a deadline instead (HauntedProcessRunner).
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: BUG-15 — the surface resolver must not resurrect a torn-down view

    /// A `SurfaceView`'s libghostty userdata is an *unretained* self-pointer,
    /// and the C surface outlives the view (the view frees synchronously;
    /// `Ghostty.Surface.deinit` frees the surface later on a detached task). An
    /// action arriving in that gap made `Ghostty.App.surfaceView(from:)`
    /// resurrect freed memory — the BUG-15 use-after-free that aborts in
    /// `scrollbar` (the empty-state startup crash, and the kill-last-session
    /// crash BUG-12 only half-closed). The registry guard is three touch-points
    /// across two upstream-owned files; a rebase that drops any of them silently
    /// reopens the crash, so grep for all three.
    @Test("BUG-15: surfaceView(from:) is registry-guarded, and views register/unregister")
    func surfaceResolverChecksLiveRegistry() throws {
        let app = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Ghostty/Ghostty.App.swift"),
            encoding: .utf8)
        #expect(app.contains("HauntedSurfaceRegistry.shared.isLive"), """
            Ghostty.App.surfaceView(from:) no longer checks HauntedSurfaceRegistry \
            before Unmanaged.takeUnretainedValue(). An action for a surface whose \
            SurfaceView was torn down (empty-state teardown / closed split) will \
            resurrect freed memory — the BUG-15 use-after-free that aborts in scrollbar.
            """)

        let view = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Ghostty/Surface View/SurfaceView_AppKit.swift"),
            encoding: .utf8)
        #expect(view.contains("HauntedSurfaceRegistry.shared.register"),
                "SurfaceView.init no longer registers with HauntedSurfaceRegistry — the resolver will treat every live view as dead and drop all actions.")
        #expect(view.contains("HauntedSurfaceRegistry.shared.unregister"),
                "SurfaceView.deinit no longer unregisters — a freed view stays 'live' and its dangling userdata is resurrected (BUG-15 returns).")
    }

    // MARK: UPD-01 — Sparkle must never trust upstream Ghostty's update channel

    /// The fork inherits upstream's whole Sparkle integration, and upstream's
    /// version of it points at Ghostty's appcast and trusts Ghostty's EdDSA
    /// key. Left in place, a user who enables `auto-update` gets offered stock
    /// Ghostty releases — validly signed by a key the app trusts — and
    /// accepting one replaces Haunted.app wholesale. Both values live in files
    /// upstream owns (UpdateDelegate.swift, Ghostty-Info.plist), so a rebase
    /// resolved as "theirs" silently restores them — hence a grep.
    /// See docs/terminal-updates.md.
    @Test("UPD-01: no Swift source points Sparkle at ghostty.org artifacts")
    func noUpstreamUpdateFeed() throws {
        let files = try Self.swiftFiles(under: Self.sourcesDirectory)
        try #require(!files.isEmpty)

        var offenders: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in contents.components(separatedBy: .newlines).enumerated()
            where line.contains("files.ghostty.org") {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            files.ghostty.org is upstream Ghostty's artifact host. Feeding it to \
            Sparkle offers users an "update" that replaces Haunted.app with stock \
            Ghostty. Point at https://releases.dednets.com instead.
            \(offenders.joined(separator: "\n"))
            """)
    }

    @Test("UPD-01: the update feed points at releases.dednets.com, both channels")
    func updateFeedPointsAtDedNets() throws {
        let delegate = try String(
            contentsOf: Self.sourcesDirectory
                .appendingPathComponent("Features/Update/UpdateDelegate.swift"),
            encoding: .utf8)
        for url in ["https://releases.dednets.com/appcast.xml",
                    "https://releases.dednets.com/tip/appcast.xml"] {
            #expect(delegate.contains(url),
                    "UpdateDelegate.feedURLString no longer serves \(url) — an upstream rebase probably took \"theirs\"")
        }
    }

    @Test("UPD-01: the bundle trusts DedNets' Sparkle key, not Ghostty's")
    func sparklePublicKeyIsOurs() throws {
        let plist = try String(
            contentsOf: Self.sourcesDirectory
                .deletingLastPathComponent()  // macos
                .appendingPathComponent("Ghostty-Info.plist"),
            encoding: .utf8)
        #expect(!plist.contains("wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="),
                "Ghostty-Info.plist carries upstream Ghostty's SUPublicEDKey — the app will accept updates signed by Ghostty's release key")
        #expect(plist.contains("<key>SUPublicEDKey</key>"),
                "Ghostty-Info.plist lost SUPublicEDKey — Sparkle will refuse every update for lack of a trusted key")
        #expect(plist.contains("Bgqf3WsSqHaemD8aHJ3CKImpYu1PnvhjUUsfLdWJRqg="),
                "SUPublicEDKey is neither Ghostty's nor DedNets' release key — updates signed by the DedNets private key will be rejected")
    }

    // MARK: Helpers

    /// `macos/Sources`, located relative to this test file so the check needs
    /// no bundle resource and works from any DerivedData path.
    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)   // macos/Tests/Haunted/<this>.swift
            .deletingLastPathComponent()  // macos/Tests/Haunted
            .deletingLastPathComponent()  // macos/Tests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }
}
