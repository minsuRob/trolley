import AppKit
import ArgumentParser
import Foundation
import TrolleyWidget

/// Renders the app icon from the same paths the widget draws.
///
/// Build tooling, not a user command -- hidden from help. It exists so the icon
/// and the widget's face cannot drift apart: there is one drawing, and the
/// iconset is produced from it at build time rather than checked in as art
/// somebody has to remember to update.
struct ExportIconCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-icon",
        abstract: "Render the app iconset PNGs (build tooling).",
        shouldDisplay: false
    )

    @Option(help: "Directory to write the .iconset PNGs into.")
    var output: String

    /// The names iconutil expects inside a .iconset directory.
    private static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024)
    ]

    func run() throws {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for variant in Self.variants {
            let data = try render(pixels: variant.pixels)
            try data.write(to: directory.appendingPathComponent("\(variant.name).png"))
        }
        print("wrote \(Self.variants.count) images to \(directory.path)")
    }

    private func render(pixels: Int) throws -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ValidationError("\(pixels)px 비트맵을 만들지 못했습니다")
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: representation) else {
            throw ValidationError("\(pixels)px 컨텍스트를 만들지 못했습니다")
        }
        NSGraphicsContext.current = graphics

        let side = CGFloat(pixels)
        // The art already carries margins inside its 128 box, so it is drawn
        // full-bleed; a bitmap context is y-up, hence isFlipped: false.
        FolderIconArt.draw(in: graphics.cgContext, size: CGSize(width: side, height: side), isFlipped: false)
        graphics.flushGraphics()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ValidationError("\(pixels)px PNG 인코딩에 실패했습니다")
        }
        return data
    }
}
