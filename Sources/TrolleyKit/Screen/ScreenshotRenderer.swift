import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RenderedScreenshot {
    public let jpegData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Screen points per image pixel. 1.0 when the image maps 1:1 to points;
    /// rises above 1.0 when maxWidth shrank the image further.
    public let pointsPerPixel: Double
    /// What the image shows, in global screen points.
    public let capturedRegion: CGRect
}

public enum ScreenshotRenderError: Error, CustomStringConvertible {
    case emptyRegion(CGRect)
    case renderFailed(String)

    public var description: String {
        switch self {
        case .emptyRegion(let region):
            return "region \(region) does not intersect the display"
        case .renderFailed(let reason):
            return "could not render the screenshot: \(reason)"
        }
    }
}

/// Turns a raw capture into something worth putting in a model's context:
/// cropped to the requested region, downscaled so pixels map to screen points
/// (a vision model clicks what it sees -- 1:1 keeps the arithmetic trivial),
/// and JPEG-compressed because a Retina PNG is megabytes of base64.
public enum ScreenshotRenderer {
    public static func render(
        _ capture: ScreenCapture,
        region: CGRect? = nil,
        maxWidth: Int = 1440,
        quality: CGFloat = 0.8
    ) throws -> RenderedScreenshot {
        // Clamp the requested point region to the display and convert to pixels.
        let pointRegion = (region ?? capture.displayBounds).intersection(capture.displayBounds)
        guard !pointRegion.isNull, pointRegion.width >= 1, pointRegion.height >= 1 else {
            throw ScreenshotRenderError.emptyRegion(region ?? capture.displayBounds)
        }

        let scale = capture.pixelsPerPoint
        let cropPixels = CGRect(
            x: (pointRegion.minX - capture.displayBounds.minX) * scale,
            y: (pointRegion.minY - capture.displayBounds.minY) * scale,
            width: pointRegion.width * scale,
            height: pointRegion.height * scale
        ).integral

        guard let cropped = capture.image.cropping(to: cropPixels) else {
            throw ScreenshotRenderError.renderFailed("cropping to \(cropPixels) failed")
        }

        // Normalize to 1px = 1pt, then apply the maxWidth cap on top.
        let pointWidth = pointRegion.width
        let targetWidth = max(1, Int(min(pointWidth, CGFloat(maxWidth))))
        let outputScale = CGFloat(targetWidth) / CGFloat(cropped.width)
        let targetHeight = max(1, Int((CGFloat(cropped.height) * outputScale).rounded()))

        let scaled = try downscale(cropped, width: targetWidth, height: targetHeight)
        let jpeg = try encodeJPEG(scaled, quality: quality)

        return RenderedScreenshot(
            jpegData: jpeg,
            pixelWidth: scaled.width,
            pixelHeight: scaled.height,
            pointsPerPixel: Double(pointRegion.width) / Double(scaled.width),
            capturedRegion: pointRegion
        )
    }

    private static func downscale(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width != image.width || height != image.height else { return image }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotRenderError.renderFailed("could not create a \(width)x\(height) context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw ScreenshotRenderError.renderFailed("downscale produced no image")
        }
        return scaled
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotRenderError.renderFailed("could not create a JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotRenderError.renderFailed("JPEG encoding failed")
        }
        return data as Data
    }
}
