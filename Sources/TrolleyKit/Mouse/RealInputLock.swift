import CoreGraphics
import Foundation

/// Suppresses real HID mouse input for the brief window a synthetic click is
/// in flight -- public API only, no private frameworks. This is what
/// actually prevents the race a shared-HID-stream click is otherwise exposed
/// to: a real mouse move, or another automation agent's own HID events,
/// landing between this click's down and up reads to the OS as a drag
/// through several points instead of a discrete click, which a list/table
/// view reads as several items getting selected.
///
/// A `CGEventTap` positioned ahead of the HID stream drops every mouse event
/// while the lock is held, except our own -- posting also re-enters that
/// same tap location, so our own down/up must be tagged with `mark(_:)` and
/// let through, or the lock would swallow its own click.
///
/// Best-effort: `withRealInputSuppressed` always runs `body`, locked or not.
/// A click must never be blocked by the lock failing to engage (trust
/// revoked mid-session, tap creation refused, ...) -- that would trade a
/// rare drag-selection bug for a click that silently never happens, which is
/// a worse failure mode.
public enum RealInputLock {
    /// Tags an event as ours so the tap callback lets it through instead of
    /// dropping it as real hardware input. Call before posting.
    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    /// True for an event `mark(_:)` has tagged. Exposed (rather than kept as
    /// inline comparison in the tap callback) so the tagging round-trip is
    /// directly testable without a real CGEventTap.
    public static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Runs `body` (expected to be a single click's down/sleep/up -- tens of
    /// milliseconds, not an animation) with real mouse input suppressed for
    /// its duration.
    public static func withRealInputSuppressed(_ body: () -> Void) {
        guard let lock = ActiveLock() else {
            body()
            return
        }
        defer { lock.release() }
        body()
    }

    fileprivate static let marker: Int64 = 0x7472_6F6C_6C65_79 // ASCII "trolley", truncated to fit
    fileprivate static let mouseEventMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    /// Owns the tap's mach port, run loop source, and the dedicated thread
    /// that pumps them -- a CGEventTap only delivers callbacks while some
    /// run loop is spinning, and this must not be tied to whichever run loop
    /// (if any) the caller's thread happens to be running.
    private final class ActiveLock {
        private let tap: CFMachPort
        private let source: CFRunLoopSource
        private let runLoop: CFRunLoop

        init?() {
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: RealInputLock.mouseEventMask,
                callback: trolleyRealInputLockCallback,
                userInfo: nil
            ) else { return nil }
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return nil }
            self.tap = tap
            self.source = source

            // The thread below writes `capturedRunLoop` before signalling
            // `ready`, and this initializer only reads it after waiting on
            // `ready` -- the semaphore establishes the happens-before, so
            // force-unwrapping afterward is safe.
            var capturedRunLoop: CFRunLoop?
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread {
                let runLoop = CFRunLoopGetCurrent()
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                capturedRunLoop = runLoop
                ready.signal()
                CFRunLoopRun()
            }
            thread.name = "ink.markhub.trolley.real-input-lock"
            thread.start()
            ready.wait()
            self.runLoop = capturedRunLoop!
        }

        func release() {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopSourceInvalidate(source)
            CFRunLoopStop(runLoop)
        }
    }
}

/// C-convention callback for the tap: no captures are allowed in a
/// `CGEventTapCallBack`, so this stays a free function referencing only
/// `RealInputLock`'s static state.
private func trolleyRealInputLockCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if RealInputLock.isMarked(event) {
        return Unmanaged.passUnretained(event)
    }
    return nil
}
