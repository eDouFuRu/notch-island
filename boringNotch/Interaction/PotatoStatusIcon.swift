import AppKit

/// Shared tuber template for the menu bar and the island's navigation tab.
enum PotatoStatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 2.1, y: 6.5))
            outline.curve(to: NSPoint(x: 5.0, y: 12.1),
                          controlPoint1: NSPoint(x: 1.7, y: 8.8),
                          controlPoint2: NSPoint(x: 3.1, y: 10.9))
            outline.curve(to: NSPoint(x: 11.9, y: 13.5),
                          controlPoint1: NSPoint(x: 7.0, y: 13.6),
                          controlPoint2: NSPoint(x: 9.8, y: 14.4))
            outline.curve(to: NSPoint(x: 15.2, y: 12.7),
                          controlPoint1: NSPoint(x: 13.2, y: 12.9),
                          controlPoint2: NSPoint(x: 14.1, y: 13.0))
            outline.curve(to: NSPoint(x: 16.6, y: 10.0),
                          controlPoint1: NSPoint(x: 16.7, y: 12.3),
                          controlPoint2: NSPoint(x: 17.3, y: 11.3))
            outline.curve(to: NSPoint(x: 12.6, y: 5.4),
                          controlPoint1: NSPoint(x: 15.8, y: 8.2),
                          controlPoint2: NSPoint(x: 14.6, y: 6.3))
            outline.curve(to: NSPoint(x: 6.9, y: 4.0),
                          controlPoint1: NSPoint(x: 10.9, y: 4.5),
                          controlPoint2: NSPoint(x: 8.6, y: 4.1))
            outline.curve(to: NSPoint(x: 3.7, y: 3.9),
                          controlPoint1: NSPoint(x: 5.4, y: 3.9),
                          controlPoint2: NSPoint(x: 4.5, y: 3.3))
            outline.curve(to: NSPoint(x: 2.1, y: 6.5),
                          controlPoint1: NSPoint(x: 2.8, y: 4.2),
                          controlPoint2: NSPoint(x: 2.3, y: 5.1))
            outline.close()
            outline.lineWidth = 1.35
            outline.lineJoinStyle = .round
            outline.lineCapStyle = .round
            outline.stroke()

            // Short peel marks distinguish the tuber from the old leaf symbol.
            let peel = NSBezierPath()
            peel.move(to: NSPoint(x: 5.6, y: 9.4))
            peel.curve(to: NSPoint(x: 6.5, y: 10.4),
                       controlPoint1: NSPoint(x: 5.8, y: 9.8),
                       controlPoint2: NSPoint(x: 6.1, y: 10.2))
            peel.move(to: NSPoint(x: 8.4, y: 6.8))
            peel.curve(to: NSPoint(x: 9.4, y: 7.9),
                       controlPoint1: NSPoint(x: 8.6, y: 7.2),
                       controlPoint2: NSPoint(x: 9.0, y: 7.6))
            peel.move(to: NSPoint(x: 11.7, y: 9.3))
            peel.curve(to: NSPoint(x: 12.5, y: 10.2),
                       controlPoint1: NSPoint(x: 11.8, y: 9.7),
                       controlPoint2: NSPoint(x: 12.2, y: 10.0))
            peel.lineWidth = 1.2
            peel.lineCapStyle = .round
            peel.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
