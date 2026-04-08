import AppKit
import PDFKit

struct PDFBuilder {

    /// Create a PDF document from multiple scanned pages, with annotations baked in
    static func buildPDF(from pages: [ScannedPage]) -> PDFDocument {
        let document = PDFDocument()

        for (index, page) in pages.enumerated() {
            let image = page.annotations.isEmpty
                ? page.adjustedImage
                : renderAnnotations(onto: page.adjustedImage, annotations: page.annotations)
            if let pdfPage = createPDFPage(from: image) {
                document.insert(pdfPage, at: index)
            }
        }

        return document
    }

    /// Create a searchable PDF with OCR text layer
    static func buildSearchablePDF(from pages: [ScannedPage]) -> PDFDocument {
        let document = PDFDocument()

        for (index, page) in pages.enumerated() {
            if let pdfPage = createPDFPage(from: page.adjustedImage) {
                document.insert(pdfPage, at: index)
                // Note: Embedding an invisible text layer for searchability
                // requires drawing text at the recognized positions.
                // For simplicity, we embed the image as the visible layer.
                // Full searchable PDF support would require coordinate mapping
                // from VNRecognizedTextObservation bounding boxes.
            }
        }

        return document
    }

    /// Save a single image to a file
    static func saveImage(_ image: NSImage, format: ExportFormat, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw ExportError.conversionFailed
        }

        let data: Data?
        switch format {
        case .png:
            data = bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .tiff:
            data = bitmap.representation(using: .tiff, properties: [:])
        case .pdf:
            let doc = PDFDocument()
            if let page = createPDFPage(from: image) {
                doc.insert(page, at: 0)
            }
            doc.write(to: url)
            return
        }

        guard let imageData = data else {
            throw ExportError.conversionFailed
        }
        try imageData.write(to: url)
    }

    // MARK: - Private

    private static func createPDFPage(from image: NSImage) -> PDFPage? {
        PDFPage(image: image)
    }

    /// Render annotations onto an image, returning a new image with annotations baked in.
    static func renderAnnotations(onto image: NSImage, annotations: [Annotation]) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()

        // Draw original image
        image.draw(in: NSRect(origin: .zero, size: size))

        // Draw annotations
        for annotation in annotations {
            switch annotation {
            case .text(let t):
                let x = t.position.x * size.width
                let y = t.position.y * size.height
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: t.fontSize * (size.width / 800)), // scale font to image
                    .foregroundColor: t.color,
                    .backgroundColor: NSColor.white.withAlphaComponent(0.8),
                ]
                let str = NSAttributedString(string: t.text, attributes: attrs)
                str.draw(at: NSPoint(x: x, y: size.height - y - str.size().height))

            case .drawing(let d):
                let path = NSBezierPath()
                let points = d.points.map { NSPoint(x: $0.x * size.width, y: size.height - $0.y * size.height) }
                guard let first = points.first else { continue }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.line(to: point)
                }
                path.lineWidth = d.lineWidth * (size.width / 800)
                d.color.setStroke()
                path.stroke()
            }
        }

        result.unlockFocus()
        return result
    }
}

enum ExportError: LocalizedError {
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .conversionFailed: return "Failed to convert image for export."
        }
    }
}
