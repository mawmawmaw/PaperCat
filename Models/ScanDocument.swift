import AppKit
import Foundation

struct ScannedPage: Identifiable {
    let id = UUID()
    var originalImage: NSImage
    var adjustedImage: NSImage
    var ocrText: String?
    let scannedAt: Date

    /// Brightness adjustment (-1.0 to 1.0)
    var brightness: Double = 0.0
    /// Contrast adjustment (0.25 to 4.0, default 1.0)
    var contrast: Double = 1.0
    /// Sharpness adjustment (0.0 to 2.0)
    var sharpness: Double = 0.0

    init(image: NSImage) {
        self.originalImage = image
        self.adjustedImage = image
        self.scannedAt = Date()
    }
}

class ScanDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var pages: [ScannedPage] = []
    @Published var name: String
    let createdAt: Date

    init(name: String = "Untitled Scan") {
        self.name = name
        self.createdAt = Date()
    }

    func addPage(_ image: NSImage) {
        pages.append(ScannedPage(image: image))
    }

    func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages.remove(at: index)
    }

    func movePage(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }
}
