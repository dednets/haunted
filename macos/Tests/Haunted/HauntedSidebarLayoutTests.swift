import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.3 — LAY-01…08.
///
/// Geometry is shared by every window and persisted, so a bug here follows the
/// user across relaunches. Each test gets its own `UserDefaults` suite; the
/// singleton reads `.standard` and would otherwise leak state between cases and
/// into the developer's real sidebar.
@MainActor
struct HauntedSidebarLayoutTests {
    /// A scratch defaults suite, removed when the test ends.
    private static func scratchDefaults(
        _ name: String = UUID().uuidString
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: LAY-01/02 — restoring a persisted width

    @Test("LAY-01: a saved width below minWidth falls back to the default")
    func savedWidthBelowMinimum() {
        let defaults = Self.scratchDefaults()
        defaults.set(50.0, forKey: "HauntedSidebarWidth")
        #expect(HauntedSidebarLayout(defaults: defaults).width == 220)
    }

    @Test("LAY-02: a saved width above maxWidth is clamped")
    func savedWidthAboveMaximum() {
        let defaults = Self.scratchDefaults()
        defaults.set(9999.0, forKey: "HauntedSidebarWidth")
        #expect(HauntedSidebarLayout(defaults: defaults).width == HauntedSidebarLayout.maxWidth)
    }

    @Test("LAY-01: no saved width at all → the default")
    func noSavedWidth() {
        #expect(HauntedSidebarLayout(defaults: Self.scratchDefaults()).width == 220)
    }

    // MARK: LAY-03…06 — propose(width:)

    @Test("LAY-03: propose within bounds while expanded sets the width")
    func proposeWithinBounds() {
        let layout = HauntedSidebarLayout(defaults: Self.scratchDefaults())
        layout.propose(width: 300)
        #expect(layout.width == 300)
        #expect(!layout.collapsed)
    }

    @Test("LAY-04: propose beyond maxWidth clamps")
    func proposeClampsToMaximum() {
        let layout = HauntedSidebarLayout(defaults: Self.scratchDefaults())
        layout.propose(width: 600)
        #expect(layout.width == HauntedSidebarLayout.maxWidth)
    }

    /// LAY-05. Dragging the collapsed strip a few points must not tear it open;
    /// the threshold is half of minWidth.
    @Test("LAY-05: a small proposal while collapsed is a no-op")
    func proposeBelowThresholdWhileCollapsed() {
        let defaults = Self.scratchDefaults()
        defaults.set(true, forKey: "HauntedSidebarCollapsed")
        let layout = HauntedSidebarLayout(defaults: defaults)
        try? #require(layout.collapsed)

        layout.propose(width: 40) // < minWidth/2 == 80
        #expect(layout.collapsed, "a short drag must not expand the sidebar")
        #expect(layout.effectiveWidth == HauntedSidebarLayout.collapsedWidth)
    }

    /// LAY-06. Past the threshold the drag expands it — and the width clamps up
    /// to minWidth, so the sidebar never opens narrower than it can render.
    @Test("LAY-06: a proposal past the threshold expands, clamped up to minWidth")
    func proposeAboveThresholdWhileCollapsed() {
        let defaults = Self.scratchDefaults()
        defaults.set(true, forKey: "HauntedSidebarCollapsed")
        let layout = HauntedSidebarLayout(defaults: defaults)

        layout.propose(width: 120) // > 80, but < minWidth
        #expect(layout.width == HauntedSidebarLayout.minWidth)
        #expect(!layout.collapsed)
    }

    // MARK: LAY-07 — reversing inside the animation window

    /// LAY-07. `collapsed` and `contentVisible` each lag the user's intent by one
    /// animation step, so neither can be used to answer "did the user change
    /// their mind?".
    ///
    /// The old code guarded on `collapsed`: `setCollapsed(true)` set
    /// `contentVisible = false` but left `collapsed == false` until its deferred
    /// closure ran, so an immediate `setCollapsed(false)` saw "already expanded",
    /// took the early return, and the pending closure then collapsed the sidebar
    /// the user had just reopened. Reversal is exactly what a double-click on the
    /// divider produces.
    @Test("LAY-07: collapse then expand inside the animation window ends expanded")
    func reversalInsideAnimationWindow() async throws {
        let layout = HauntedSidebarLayout(defaults: Self.scratchDefaults())
        try #require(!layout.collapsed)

        layout.setCollapsed(true)
        layout.setCollapsed(false) // same runloop turn: well inside animationDuration

        // Outlast both deferred closures (animationDuration, and +0.02).
        try await Task.sleep(nanoseconds: UInt64(
            (HauntedSidebarLayout.animationDuration + 0.15) * 1_000_000_000))

        #expect(!layout.collapsed, "the user asked to expand; the pending closure must not collapse")
        #expect(layout.contentVisible)
    }

    /// The mirror image: expand then collapse inside the window ends collapsed.
    @Test("LAY-07: expand then collapse inside the animation window ends collapsed")
    func reverseReversalInsideAnimationWindow() async throws {
        let defaults = Self.scratchDefaults()
        defaults.set(true, forKey: "HauntedSidebarCollapsed")
        let layout = HauntedSidebarLayout(defaults: defaults)
        try #require(layout.collapsed)

        layout.setCollapsed(false)
        layout.setCollapsed(true)

        try await Task.sleep(nanoseconds: UInt64(
            (HauntedSidebarLayout.animationDuration + 0.15) * 1_000_000_000))

        #expect(layout.collapsed)
        #expect(!layout.contentVisible)
    }

    /// An uncontested collapse still completes — the reversal fix must not have
    /// broken the ordinary path.
    @Test("LAY-07: an uncontested collapse completes")
    func uncontestedCollapse() async throws {
        let layout = HauntedSidebarLayout(defaults: Self.scratchDefaults())
        layout.setCollapsed(true)
        #expect(!layout.contentVisible, "content fades out first")

        try await Task.sleep(nanoseconds: UInt64(
            (HauntedSidebarLayout.animationDuration + 0.15) * 1_000_000_000))
        #expect(layout.collapsed, "then the width narrows")
    }

    @Test("LAY-07: setCollapsed to the current state is a no-op")
    func setCollapsedIdempotent() {
        let layout = HauntedSidebarLayout(defaults: Self.scratchDefaults())
        layout.setCollapsed(false)
        #expect(!layout.collapsed)
        #expect(layout.contentVisible)
    }

    // MARK: LAY-08 — persistence

    @Test("LAY-08: width and collapsed survive a new instance")
    func geometryPersists() async throws {
        let name = UUID().uuidString
        let defaults = Self.scratchDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let first = HauntedSidebarLayout(defaults: defaults)
        first.propose(width: 300)
        first.setCollapsed(true)
        try await Task.sleep(nanoseconds: UInt64(
            (HauntedSidebarLayout.animationDuration + 0.15) * 1_000_000_000))

        let second = HauntedSidebarLayout(defaults: defaults)
        #expect(second.width == 300)
        #expect(second.collapsed)
        #expect(!second.contentVisible, "reopening collapsed must not flash the content in")
    }
}
