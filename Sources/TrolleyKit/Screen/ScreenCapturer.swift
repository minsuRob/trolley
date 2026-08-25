import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A raw display capture plus the geometry needed to map its pixels back to
/// the global point space that AX frames and CGEvent clicks use.
public struct ScreenCapture {
    /// Native pixels (Retina scale).
    public let image: CGImage
    /// The captured display's bounds in global screen points, top-left origin.
    public let displayBounds: CGRect
    /// Backing scale: image pixels per screen point (2.0 on Retina).
    public let pixelsPerPoint: Double

    public init(image: CGImage, displayBounds: CGRect, pixelsPerPoint: Double) {
        self.image = image
        self.displayBounds = displayBounds
        self.pixelsPerPoint = pixelsPerPoint
    }
}

public enum ScreenCaptureError: Error, CustomStringConvertible {
    case accessDenied
    case captureFailed(String)

    public var description: String {
        switch self {
        case .accessDenied:
            return "screen recording access is not granted"
        case .captureFailed(let reason):
            return "screen capture failed: \(reason)"
        }
    }
}

/// Seam over screen capture so the screenshot tool is testable with a tiny
/// synthetic image -- the capture counterpart of `TrustChecking`.
///
/// Screen Recording is a separate TCC permission from Accessibility, granted
/// to the same binary path. Unlike Accessibility, a grant typically only
/// applies to processes launched *after* it -- a running server must restart.
public protocol ScreenCapturing {
    func hasScreenRecordingAccess() -> Bool
    /// Registers the binary with TCC and shows the system prompt when possible.
    @discardableResult func requestScreenRecordingAccess() -> Bool
    func captureMainDisplay() throws -> ScreenCapture
}

/// Real ScreenCaptureKit-backed implementation.
public struct SystemScreenCapturer: ScreenCapturing {
    /// Leave out windows owned by this process -- the floating status widget
    /// is always-on-top, so it would photobomb every capture and hide whatever
    /// UI sits underneath the corner it occupies.
    private let excludeOwnWindows: Bool

    public init(excludeOwnWindows: Bool = true) {
        self.excludeOwnWindows = excludeOwnWindows
    }

    public func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func captureMainDisplay() throws -> ScreenCapture {
        guard hasScreenRecordingAccess() else {
            throw ScreenCaptureError.accessDenied
        }

        // SCK is async-only; the MCP loop is deliberately serial and
        // synchronous (AX calls aren't thread-safe), so bridge with a
        // detached task and a semaphore. Detached, so the task cannot inherit
        // any context tied to the thread we're about to block.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let excludeOwnWindows = self.excludeOwnWindows

        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first(where: {
                    $0.displayID == CGMainDisplayID()
                }) ?? content.displays.first else {
                    throw ScreenCaptureError.captureFailed("no display available")
                }

                let ownPid = pid_t(getpid())
                let excluded = excludeOwnWindows
                    ? content.windows.filter { $0.owningApplication?.processID == ownPid }
                    : []
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let configuration = SCStreamConfiguration()
                // display.width/height are points; pointPixelScale gives the
                // backing scale so we capture at native resolution.
                let scale = max(1, Int(filter.pointPixelScale))
                configuration.width = display.width * scale
                configuration.height = display.height * scale
                configuration.showsCursor = true
                configuration.captureResolution = .best

                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                box.result = .success(ScreenCapture(
                    image: image,
                    displayBounds: display.frame,
                    pixelsPerPoint: Double(image.width) / Double(display.width)
                ))
            } catch let error as ScreenCaptureError {
                box.result = .failure(error)
            } catch {
                box.result = .failure(.captureFailed("\(error)"))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw ScreenCaptureError.captureFailed("timed out waiting for ScreenCaptureKit")
        }
        return try box.result.get()
    }

    /// Carries the capture result across the async/sync bridge.
    private final class ResultBox: @unchecked Sendable {
        var result: Result<ScreenCapture, ScreenCaptureError> =
            .failure(.captureFailed("capture task never ran"))
    }
}
