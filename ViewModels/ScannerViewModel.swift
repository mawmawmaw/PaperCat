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
    private var cancellables = Set<AnyCancellable>()

    init() {
        scannerManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
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
            document.objectWillChange.send()
        }
    }

    func resetAdjustments(for pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        document.pages[pageIndex].brightness = 0
        document.pages[pageIndex].contrast = 1.0
        document.pages[pageIndex].sharpness = 0
        document.pages[pageIndex].adjustedImage = document.pages[pageIndex].originalImage
        document.objectWillChange.send()
    }

    func applyAdjustmentsToAll() {
        guard let index = selectedPageIndex, document.pages.indices.contains(index) else { return }
        let source = document.pages[index]

        for i in document.pages.indices {
            document.pages[i].brightness = source.brightness
            document.pages[i].contrast = source.contrast
            document.pages[i].sharpness = source.sharpness

            if let adjusted = ImageProcessor.applyAdjustments(
                to: document.pages[i].originalImage,
                brightness: source.brightness,
                contrast: source.contrast,
                sharpness: source.sharpness
            ) {
                document.pages[i].adjustedImage = adjusted
            }
        }
        document.objectWillChange.send()
    }

    // MARK: - Crop

    func cropPage(at index: Int, to rect: CGRect) {
        guard document.pages.indices.contains(index) else { return }
        if let cropped = ImageProcessor.crop(image: document.pages[index].adjustedImage, to: rect) {
            document.pages[index].adjustedImage = cropped
            document.pages[index].originalImage = cropped
            document.objectWillChange.send()
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
        let image = page.annotations.isEmpty
            ? page.adjustedImage
            : PDFBuilder.renderAnnotations(onto: page.adjustedImage, annotations: page.annotations)
        do {
            try PDFBuilder.saveImage(image, format: format, to: url)
        } catch {
            scannerManager.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Printing (placeholder — USB printing not yet implemented)

    func printDocument() {
        scannerManager.errorMessage = "Printing not yet available"
    }
}
