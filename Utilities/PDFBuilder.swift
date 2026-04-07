import AppKit
import PDFKit

struct PDFBuilder {

    /// Create a PDF document from multiple scanned pages
    static func buildPDF(from pages: [ScannedPage]) -> PDFDocument {
        let document = PDFDocument()

        for (index, page) in pages.enumerated() {
            if let pdfPage = createPDFPage(from: page.adjustedImage) {
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
}

enum ExportError: LocalizedError {
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .conversionFailed: return "Failed to convert image for export."
        }
    }
}
