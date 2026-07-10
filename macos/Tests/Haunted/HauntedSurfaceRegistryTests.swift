import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.6 — REG-01. The live-view registry that closes the
/// deferred-surface-free use-after-free (BUG-15). The crash itself needs a
/// live `ghostty_app_t`/`SurfaceView` and cannot be unit-reproduced (see the
/// haunted-testing skill), so this pins the guard's *invariant*: a pointer
/// that was never registered, or has been unregistered (its view torn down),
/// reads as **not live** — which is exactly what makes `Ghostty.App`'s
/// resolver drop the action instead of resurrecting freed memory.
///
/// Fresh instances, never `.shared`, so tests never pollute the process-wide
/// registry the running app uses.
struct HauntedSurfaceRegistryTests {
    /// Real allocations so each pointer is unique and valid to compare (the
    /// registry only ever compares addresses; it never dereferences them).
    private func pointer() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    }

    @Test("REG-01: an unregistered pointer is not live — a dead view's action is dropped")
    func unregisteredIsNotLive() {
        let registry = HauntedSurfaceRegistry()
        let ptr = pointer()
        defer { ptr.deallocate() }
        #expect(!registry.isLive(ptr),
                "a never-registered pointer must read dead so the resolver returns nil")
    }

    @Test("REG-01: register makes a view live; unregister (torn down) makes it dead")
    func registerThenUnregister() {
        let registry = HauntedSurfaceRegistry()
        let ptr = pointer()
        defer { ptr.deallocate() }

        registry.register(ptr)
        #expect(registry.isLive(ptr))
        #expect(registry.count == 1)

        registry.unregister(ptr)
        #expect(!registry.isLive(ptr),
                "after teardown the pointer must read dead — this is the UAF guard")
        #expect(registry.count == 0)
    }

    @Test("REG-01: distinct views are tracked independently")
    func distinctPointersIndependent() {
        let registry = HauntedSurfaceRegistry()
        let a = pointer()
        let b = pointer()
        defer { a.deallocate(); b.deallocate() }

        registry.register(a)
        #expect(registry.isLive(a))
        #expect(!registry.isLive(b), "registering one view must not make another read live")

        registry.register(b)
        registry.unregister(a)
        #expect(!registry.isLive(a))
        #expect(registry.isLive(b), "tearing down one view must not drop another")
    }

    @Test("REG-01: unregister is idempotent and a double register does not double-count")
    func idempotent() {
        let registry = HauntedSurfaceRegistry()
        let ptr = pointer()
        defer { ptr.deallocate() }

        registry.register(ptr)
        registry.register(ptr)
        #expect(registry.count == 1, "a set, not a bag")

        registry.unregister(ptr)
        registry.unregister(ptr) // must not underflow or crash
        #expect(!registry.isLive(ptr))
        #expect(registry.count == 0)
    }
}
