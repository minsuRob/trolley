import AppKit

/// The widget's face: the user's folder icon, drawn in code.
///
/// The three paths (back panel with tab, slanted front, gloss) are a direct
/// port of the 128x128 SVG. Drawn rather than bundled because this binary is
/// deployed by copying the bare executable to a stable path (TCC is granted
/// per path) -- `Bundle.module` would crash away from the build directory.
class FolderIconView: NSView {
    /// The 내 일감 count, top-right -- red circle, white digits, capped at "+99".
    /// Added before `badgeLayer` so a just-finished ✅/❌ draws over it rather
    /// than the other way round; that overlap is rare (2.5s per tool call) and
    /// the completion badge is the more urgent of the two.
    let countBadgeLayer = CATextLayer()
    /// The ✅/❌ overlay, hidden unless a call just finished.
    let badgeLayer = CATextLayer()
    /// A rotating dashed ring shown while a tool call runs.
    let spinnerLayer = CAShapeLayer()

    // The SVG's coordinate system is y-down; a flipped view lets the port use
    // its coordinates verbatim.
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        countBadgeLayer.backgroundColor = NSColor.systemRed.cgColor
        countBadgeLayer.foregroundColor = NSColor.white.cgColor
        countBadgeLayer.font = NSFont.boldSystemFont(ofSize: 11)
        countBadgeLayer.fontSize = 11
        countBadgeLayer.alignmentMode = .center
        countBadgeLayer.opacity = 0
        layer?.addSublayer(countBadgeLayer)

        badgeLayer.string = "✅"
        badgeLayer.fontSize = 26
        badgeLayer.alignmentMode = .center
        badgeLayer.opacity = 0
        layer?.addSublayer(badgeLayer)

        spinnerLayer.fillColor = nil
        spinnerLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        spinnerLayer.lineWidth = 3
        spinnerLayer.lineCap = .round
        spinnerLayer.lineDashPattern = [6, 5]
        spinnerLayer.opacity = 0
        layer?.addSublayer(spinnerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        badgeLayer.contentsScale = scale
        countBadgeLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        let countBadgeSize: CGFloat = 20
        countBadgeLayer.frame = CGRect(
            x: bounds.maxX - countBadgeSize - 2,
            y: bounds.maxY - countBadgeSize - 2,
            width: countBadgeSize,
            height: countBadgeSize
        )
        countBadgeLayer.cornerRadius = countBadgeSize / 2
        let badgeSize: CGFloat = 30
        badgeLayer.frame = CGRect(
            x: bounds.maxX - badgeSize - 2,
            y: bounds.maxY - badgeSize - 2,
            width: badgeSize,
            height: badgeSize
        )
        let ringDiameter = bounds.width * 0.42
        let ringFrame = CGRect(
            x: (bounds.width - ringDiameter) / 2,
            y: bounds.height * 0.30,
            width: ringDiameter,
            height: ringDiameter
        )
        spinnerLayer.frame = ringFrame
        spinnerLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: ringFrame.size),
            transform: nil
        )
    }

    /// Shows or hides the 내 일감 count badge; see `CountBadgeCopy` for the rule.
    func setCount(_ count: Int?) {
        guard let text = CountBadgeCopy.text(for: count) else {
            countBadgeLayer.opacity = 0
            return
        }
        countBadgeLayer.string = text
        countBadgeLayer.opacity = 1
    }

    // MARK: - Folder drawing (SVG port)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The view is flipped, so the art's y-down coordinates land as drawn.
        FolderIconArt.draw(in: context, size: bounds.size, isFlipped: true)
    }

}

/// The folder drawing itself, separated from the view so the app icon can be
/// rendered from the same paths -- the icon and the widget's face are then the
/// same picture by construction, not by two people redrawing it.
public enum FolderIconArt {
    /// - Parameter isFlipped: true when the destination already has y running
    ///   downward, as a flipped `NSView` does. A bitmap context does not, so the
    ///   art is flipped for it here.
    public static func draw(in context: CGContext, size: CGSize, isFlipped: Bool) {
        context.saveGState()
        if !isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.saveGState()
        // Scale the 128x128 viewBox to our bounds.
        context.scaleBy(x: size.width / 128, y: size.height / 128)

        let stroke = NSColor(srgbRed: 0xBE / 255, green: 0x86 / 255, blue: 0x13 / 255, alpha: 1)

        // Back panel with the tab; the tab's right corner runs diagonally to (61, 42).
        let back = CGMutablePath()
        back.move(to: CGPoint(x: 6, y: 36))
        back.addArc(tangent1End: CGPoint(x: 6, y: 30), tangent2End: CGPoint(x: 12, y: 30), radius: 6)
        back.addLine(to: CGPoint(x: 48, y: 30))
        back.addArc(tangent1End: CGPoint(x: 54, y: 30), tangent2End: CGPoint(x: 61, y: 42), radius: 6)
        back.addLine(to: CGPoint(x: 61, y: 42))
        back.addLine(to: CGPoint(x: 106, y: 42))
        back.addArc(tangent1End: CGPoint(x: 112, y: 42), tangent2End: CGPoint(x: 112, y: 48), radius: 6)
        back.addLine(to: CGPoint(x: 112, y: 106))
        back.addLine(to: CGPoint(x: 6, y: 106))
        back.closeSubpath()
        fillPath(back, in: context, gradient: [
            (NSColor(srgbRed: 0xF7 / 255, green: 0xDC / 255, blue: 0x80 / 255, alpha: 1), 0),
            (NSColor(srgbRed: 0xE5 / 255, green: 0xB3 / 255, blue: 0x34 / 255, alpha: 1), 1)
        ], from: CGPoint(x: 59, y: 30), to: CGPoint(x: 59, y: 106))
        strokePath(back, in: context, color: stroke)

        // Slanted front: a parallelogram leaning 12 units right toward the top.
        let front = CGMutablePath()
        front.move(to: CGPoint(x: 6, y: 106))
        front.addArc(tangent1End: CGPoint(x: 18, y: 54), tangent2End: CGPoint(x: 23.9, y: 49.3), radius: 6)
        front.addLine(to: CGPoint(x: 117.9, y: 49.3))
        front.addArc(tangent1End: CGPoint(x: 123.8, y: 49.3), tangent2End: CGPoint(x: 123.8, y: 56.6), radius: 6)
        front.addLine(to: CGPoint(x: 112, y: 106))
        front.addArc(tangent1End: CGPoint(x: 110.6, y: 110.7), tangent2End: CGPoint(x: 106, y: 110.7), radius: 6)
        front.addLine(to: CGPoint(x: 12, y: 110.7))
        front.addArc(tangent1End: CGPoint(x: 6, y: 110.7), tangent2End: CGPoint(x: 6, y: 106), radius: 6)
        front.closeSubpath()
        fillPath(front, in: context, gradient: [
            (NSColor(srgbRed: 0xFF / 255, green: 0xE7 / 255, blue: 0x9A / 255, alpha: 1), 0),
            (NSColor(srgbRed: 0xF7 / 255, green: 0xCB / 255, blue: 0x52 / 255, alpha: 1), 0.45),
            (NSColor(srgbRed: 0xE3 / 255, green: 0xA6 / 255, blue: 0x16 / 255, alpha: 1), 1)
        ], from: CGPoint(x: 24, y: 49), to: CGPoint(x: 106, y: 111))
        strokePath(front, in: context, color: stroke)

        // Gloss across the top of the front panel.
        let gloss = CGMutablePath()
        gloss.move(to: CGPoint(x: 19.6, y: 55.5))
        gloss.addLine(to: CGPoint(x: 120.4, y: 55.5))
        gloss.addLine(to: CGPoint(x: 117, y: 70.5))
        gloss.addLine(to: CGPoint(x: 16.2, y: 70.5))
        gloss.closeSubpath()
        fillPath(gloss, in: context, gradient: [
            (NSColor.white.withAlphaComponent(0.5), 0),
            (NSColor.white.withAlphaComponent(0), 1)
        ], from: CGPoint(x: 68, y: 55.5), to: CGPoint(x: 68, y: 70.5))

        context.restoreGState()
        context.restoreGState()
    }

    private static func fillPath(
        _ path: CGPath,
        in context: CGContext,
        gradient stops: [(color: NSColor, location: CGFloat)],
        from start: CGPoint,
        to end: CGPoint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.color.cgColor) as CFArray,
            locations: stops.map(\.location)
        ) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private static func strokePath(_ path: CGPath, in context: CGContext, color: NSColor) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.5)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}
