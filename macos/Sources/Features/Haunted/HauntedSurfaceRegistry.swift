import Foundation

/// Tracks which `SurfaceView` userdata pointers are still live, so a libghostty
/// action that arrives for a surface whose `SurfaceView` has already been
/// deallocated resolves to `nil` and is dropped — instead of resurrecting freed
/// memory.
///
/// The hazard (BUG-12, then BUG-15): a `SurfaceView` owns its
/// `ghostty_surface_t`, whose `userdata` is an **unretained** pointer back to
/// the view. When the view is torn down — a split or tab closed, or the fork's
/// empty-state transition `surfaceTree = .init()` (startup with nothing to
/// resume, or killing the last session) — ARC frees the view *synchronously*,
/// but `Ghostty.Surface.deinit` frees the C surface *later*, on a detached
/// main-actor task. In that gap libghostty can still deliver an action (a
/// scrollbar update) whose target surface carries the now-dangling userdata;
/// `Unmanaged.takeUnretainedValue()` on it is a use-after-free that aborts in
/// `Ghostty.App.scrollbar`.
///
/// Register on view init, unregister first thing in view deinit; the surface
/// resolver in `Ghostty.App` checks `isLive` before resurrecting the pointer.
/// Action delivery (`Ghostty.App.appTick`, dispatched to the main queue) and
/// NSView deinit are both main-thread, so the check is race-free in practice;
/// the lock guards the one documented exception — `Ghostty.Surface.deinit` is
/// "not guaranteed to happen on the main actor".
final class HauntedSurfaceRegistry {
    static let shared = HauntedSurfaceRegistry()

    private let lock = NSLock()
    private var live = Set<UnsafeMutableRawPointer>()

    /// Records a live view's userdata pointer (its own address).
    func register(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        live.insert(pointer)
        lock.unlock()
    }

    /// Forgets a view's pointer as it is torn down. After this, actions
    /// targeting its (soon-to-be-freed) surface resolve to nil.
    func unregister(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        live.remove(pointer)
        lock.unlock()
    }

    /// Whether `pointer` still refers to a live `SurfaceView`. A pointer that
    /// was never registered, or already unregistered (the view is gone), is
    /// not live — so `Ghostty.App`'s resolver drops the action rather than
    /// dereferencing freed memory.
    func isLive(_ pointer: UnsafeMutableRawPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return live.contains(pointer)
    }

    /// Live-view count, for tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }
}
