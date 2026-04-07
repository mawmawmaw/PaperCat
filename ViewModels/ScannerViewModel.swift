import AppKit
import Combine
import Foundation

@MainActor
class ScannerViewModel: ObservableObject {
    @Published var settings = ScanSettings()
    @Published var document = ScanDocument()
    @Published var selectedPageIndex: Int?
    @Published var isProcessingOCR = false
    @Published var showExportPanel = false

    let scannerManager = ScannerManager()
    private var cancellable: AnyCancellable?

    init() {
        // Forward ScannerManager's changes to trigger SwiftUI updates
        cancellable = scannerManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var selectedPage: ScannedPage? {
        guard let index = selectedPageIndex, document.pages.indices.contains(index) else {
            return nil
        }
        return document.pages[index]
    }

    // MARK: - Scanning

    func scan() {
        scannerManager.scan(
            resolution: settings.resolution,
            colorMode: settings.colorMode,
            paperSize: settings.paperSize
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let image):
                    self.document.addPage(image)
                    self.selectedPageIndex = self.document.pages.count - 1
                case .failure(let error):
                    self.scannerManager.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - OCR

    func runOCR(on pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        isProcessingOCR = true

        Task {
            do {
                let text = try await OCRService.recognizeText(
                    in: document.pages[pageIndex].adjustedImage
                )
                document.pages[pageIndex].ocrText = text
            } catch {
                scannerManager.errorMessage = "OCR failed: \(error.localizedDescription)"
            }
            isProcessingOCR = false
        }
    }

    func runOCROnAllPages() {
        isProcessingOCR = true

        Task {
            for index in document.pages.indices {
                do {
                    let text = try await OCRService.recognizeText(
                        in: document.pages[index].adjustedImage
                    )
                    document.pages[index].ocrText = text
                } catch {
                    // Continue with other pages
                }
            }
            isProcessingOCR = false
        }
    }

    // MARK: - Image Adjustments

    func applyAdjustments(to pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        let page = document.pages[pageIndex]

        if let adjusted = ImageProcessor.applyAdjustments(
            to: page.originalImage,
            brightness: page.brightness,
            contrast: page.contrast,
            sharpness: page.sharpness
        ) {
            document.pages[pageIndex].adjustedImage = adjusted
        }
    }

    func resetAdjustments(for pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        document.pages[pageIndex].brightness = 0
        document.pages[pageIndex].contrast = 1.0
        document.pages[pageIndex].sharpness = 0
        document.pages[pageIndex].adjustedImage = document.pages[pageIndex].originalImage
    }

    func autoCrop(pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }

        Task {
            if let cropped = await ImageProcessor.autoCrop(image: document.pages[pageIndex].adjustedImage) {
                document.pages[pageIndex].adjustedImage = cropped
            } else {
                scannerManager.errorMessage = "Could not detect document edges for auto-crop."
            }
        }
    }

    // MARK: - Page Management

    func deletePage(at index: Int) {
        document.removePage(at: index)
        if let selected = selectedPageIndex {
            if selected >= document.pages.count {
                selectedPageIndex = document.pages.isEmpty ? nil : document.pages.count - 1
            }
        }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        document.movePage(from: source, to: destination)
    }

    // MARK: - Export

    func exportPDF(to url: URL) {
        let pdf = PDFBuilder.buildPDF(from: document.pages)
        pdf.write(to: url)
    }

    func exportCurrentPage(format: ExportFormat, to url: URL) {
        guard let page = selectedPage else { return }
        do {
            try PDFBuilder.saveImage(page.adjustedImage, format: format, to: url)
        } catch {
            scannerManager.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Printing

    func printDocument() {
        guard !document.pages.isEmpty else { return }

        // Build a composite image view for all pages
        guard let firstPage = document.pages.first else { return }
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: firstPage.adjustedImage.size))
        imageView.image = firstPage.adjustedImage
        imageView.imageScaling = .scaleProportionallyDown

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true

        let printOp = NSPrintOperation(view: imageView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }

    func printCurrentPage() {
        guard let page = selectedPage else { return }

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: page.adjustedImage.size))
        imageView.image = page.adjustedImage
        imageView.imageScaling = .scaleProportionallyDown

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit

        let printOp = NSPrintOperation(view: imageView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.run()
    }
}
