import Cocoa

extension NSAttributedString.Key {
    /// Background colour of a query-term tag. Drawn as a rounded rectangle
    /// (a "tag") by `TagLayoutManager` instead of the default square highlight.
    static let mffTagBackground = NSAttributedString.Key("mff.tagBackground")
}

/// Layout manager that renders `.mffTagBackground` runs as rounded rectangles.
final class TagLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.mffTagBackground, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
                let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                color.setFill()
                path.fill()
            }
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Field editor (NSTextView) whose layout manager draws rounded tag backgrounds.
func makeTagFieldEditor() -> NSTextView {
    let storage = NSTextStorage()
    let layout = TagLayoutManager()
    storage.addLayoutManager(layout)

    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    layout.addTextContainer(container)

    let view = NSTextView(frame: .zero, textContainer: container)
    view.isFieldEditor = true
    view.isRichText = false
    view.importsGraphics = false
    view.allowsUndo = true
    return view
}
