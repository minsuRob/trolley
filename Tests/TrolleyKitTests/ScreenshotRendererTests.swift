import CoreGraphics
import XCTest
@testable import TrolleyKit

final class ScreenshotRendererTests: XCTestCase {
    /// A synthetic 2x-scale capture: 200x100 pixels backing a 100x50-point
    /// display whose origin sits at (10, 20) in global space.
    private func makeCapture() -> ScreenCapture {
        let context = CGContext(
            data: nil, width: 200, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return ScreenCapture(
            image: context.makeImage()!,
            displayBounds: CGRect(x: 10, y: 20, width: 100, height: 50),
            pixelsPerPoint: 2.0
        )
    }

    func testDefaultRenderNormalizesToOnePixelPerPoint() throws {
        let rendered = try ScreenshotRenderer.render(makeCapture())

        XCTAssertEqual(rendered.pixelWidth, 100)
        XCTAssertEqual(rendered.pixelHeight, 50)
        XCTAssertEqual(rendered.pointsPerPixel, 1.0)
        XCTAssertEqual(rendered.capturedRegion, CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    /// maxWidth shrinks further, so the ratio rises above 1 and must be
    /// reported -- the model's click arithmetic depends on it.
    func testMaxWidthShrinkRaisesPointsPerPixel() throws {
        let rendered = try ScreenshotRenderer.render(makeCapture(), maxWidth: 50)

        XCTAssertEqual(rendered.pixelWidth, 50)
        XCTAssertEqual(rendered.pointsPerPixel, 2.0)
    }

    func testRegionCropOffsetsTheCapturedRegion() throws {
        let region = CGRect(x: 30, y: 30, width: 40, height: 20)

        let rendered = try ScreenshotRenderer.render(makeCapture(), region: region)

        XCTAssertEqual(rendered.capturedRegion, region)
        XCTAssertEqual(rendered.pixelWidth, 40)
        XCTAssertEqual(rendered.pixelHeight, 20)
        XCTAssertEqual(rendered.pointsPerPixel, 1.0)
    }

    func testRegionIsClampedToTheDisplay() throws {
        // Extends past the display's right edge; only the overlap is capturable.
        let region = CGRect(x: 90, y: 20, width: 100, height: 50)

        let rendered = try ScreenshotRenderer.render(makeCapture(), region: region)

        XCTAssertEqual(rendered.capturedRegion, CGRect(x: 90, y: 20, width: 20, height: 50))
    }

    func testOutputIsActuallyJPEG() throws {
        let rendered = try ScreenshotRenderer.render(makeCapture())

        XCTAssertGreaterThan(rendered.jpegData.count, 2)
        XCTAssertEqual(Array(rendered.jpegData.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG magic bytes")
    }

    func testRegionOutsideTheDisplayThrows() {
        let region = CGRect(x: 500, y: 500, width: 10, height: 10)

        XCTAssertThrowsError(try ScreenshotRenderer.render(makeCapture(), region: region)) { error in
            guard case ScreenshotRenderError.emptyRegion = error else {
                return XCTFail("expected emptyRegion, got \(error)")
            }
        }
    }
}
