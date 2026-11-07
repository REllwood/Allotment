import AppKit

/// The stopwatch in the menu bar. While a timer runs, its hand ticks round once a minute and the face fills
/// behind it, so you can see at a glance that time is being tracked. The images are templates, so macOS
/// draws them in the right colour for a light or dark menu bar.
enum MenuBarIcon {
    static let idle = make(second: nil)

    /// One frame for each second of the minute, drawn once and reused.
    private static let frames = (0..<60).map { make(second: $0) }

    static func tracking(elapsed: TimeInterval) -> NSImage {
        frames[Int(max(0, elapsed)) % 60]
    }

    private static func make(second: Int?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ink = NSColor.black
            let center = CGPoint(x: 9, y: 10.2)
            let radius: CGFloat = 6.6

            ink.setFill()
            // The crown and its stem.
            NSBezierPath(roundedRect: NSRect(x: 6.9, y: 0.9, width: 4.2, height: 1.9), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(rect: NSRect(x: 8.35, y: 2.5, width: 1.3, height: 1.4)).fill()
            // The lap button at two o'clock.
            let button = NSBezierPath(roundedRect: NSRect(x: -0.8, y: -0.7, width: 1.6, height: 1.4), xRadius: 0.4, yRadius: 0.4)
            var transform = AffineTransform(translationByX: center.x + 7.5 * cos(-.pi / 4), byY: center.y + 7.5 * sin(-.pi / 4))
            transform.rotate(byDegrees: 45)
            button.transform(using: transform)
            button.fill()

            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.6
            ink.setStroke()
            ring.stroke()

            let angle: CGFloat
            if let second {
                angle = -90 + 360 * CGFloat(second) / 60
                // The part of the minute already gone, as a soft wedge behind the hand. On the minute the face is
                // full rather than empty, so a running timer never looks like the idle icon.
                let wedge = NSBezierPath()
                let inner = radius - 1.9
                if second == 0 {
                    wedge.appendOval(in: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
                } else {
                    wedge.move(to: center)
                    wedge.appendArc(withCenter: center, radius: inner, startAngle: -90, endAngle: angle, clockwise: false)
                    wedge.close()
                }
                ink.withAlphaComponent(0.42).setFill()
                wedge.fill()
                ink.setFill()
            } else {
                angle = -90
            }

            let radians = angle * .pi / 180
            let hand = NSBezierPath()
            hand.move(to: center)
            hand.line(to: CGPoint(x: center.x + (radius - 2.0) * cos(radians), y: center.y + (radius - 2.0) * sin(radians)))
            hand.lineWidth = 1.5
            hand.lineCapStyle = .round
            hand.stroke()

            NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = second == nil ? "Allotment, not tracking" : "Allotment, tracking"
        return image
    }
}
