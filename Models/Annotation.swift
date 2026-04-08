import AppKit
import Foundation

/// A single annotation on a scanned page.
/// Coordinates are in normalized image space (0-1 range).
enum Annotation: Identifiable {
    case text(TextAnnotation)
    case drawing(DrawingAnnotation)

    var id: UUID {
        switch self {
        case .text(let t): return t.id
        case .drawing(let d): return d.id
        }
    }
}

struct TextAnnotation: Identifiable {
    let id = UUID()
    var text: String
    /// Position in normalized image coords (0-1)
    var position: CGPoint
    var fontSize: CGFloat = 14
    var color: NSColor = .red
}

struct DrawingAnnotation: Identifiable {
    let id = UUID()
    /// Points in normalized image coords (0-1)
    var points: [CGPoint]
    var lineWidth: CGFloat = 3
    var color: NSColor = .red
}
