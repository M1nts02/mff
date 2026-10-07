import AppKit

// MARK: - Floating command palette panel

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
// MARK: - Result table view (accepts first responder for native navigation)

final class ResultTableView: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}
// MARK: - Row view with rounded selection highlight (Spotlight style)

final class SpotlightRowView: NSTableRowView {
    private var isHovered = false
    /// Secondary Finder-style multi-selection (the accent highlight is reserved
    /// for the active row).
    var isMultiSelected = false {
        didSet {
            if isMultiSelected != oldValue { needsDisplay = true }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            let rect = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMultiSelected && !isSelected {
            let rect = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()
        }
        if isHovered && !isSelected {
            let rect = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return isSelected ? .emphasized : .normal
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }
}
