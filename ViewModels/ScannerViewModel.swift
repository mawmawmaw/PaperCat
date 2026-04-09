import AppKit
import Combine
import Foundation

@MainActor
class ScannerViewModel: ObservableObject {
    @Published var settings = ScanSettings()
    @Published var document = ScanDocument()
    @Published var selectedPageIndices = Set<Int>()
    @Published var isProcessingOCR = false
    @Published var showExportPanel = false

    let scannerManager = ScannerManager()
    let undoManager = UndoManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        scannerManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    /// The primary selected page index (first in selection, for detail view)
    var selectedPageIndex: Int? {
        guard let first = selectedPageIndices.sorted().first,
              document.pages.indices.contains(first) else { return nil }
        return first
    }

    var selectedPage: ScannedPage? {
        guard let index = selectedPageIndex else { return nil }
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
                    let newIndex = self.document.pages.count - 1
                    self.selectedPageIndices = [newIndex]
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
                let oldText = document.pages[pageIndex].ocrText
                document.pages[pageIndex].ocrText = text
                registerUndo(name: "OCR") { $0.document.pages[pageIndex].ocrText = oldText }
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
                } catch {}
            }
            isProcessingOCR = false
        }
    }

    // MARK: - Image Adjustments

    func applyAdjustments(to pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        let page = document.pages[pageIndex]
        let oldImage = page.adjustedImage

        if let adjusted = ImageProcessor.applyAdjustments(
            to: page.originalImage,
            brightness: page.brightness,
            contrast: page.contrast,
            sharpness: page.sharpness
        ) {
            document.pages[pageIndex].adjustedImage = adjusted
            document.objectWillChange.send()

            let oldB = page.brightness, oldC = page.contrast, oldS = page.sharpness
            registerUndo(name: "Adjust") {
                $0.document.pages[pageIndex].brightness = oldB
                $0.document.pages[pageIndex].contrast = oldC
                $0.document.pages[pageIndex].sharpness = oldS
                $0.document.pages[pageIndex].adjustedImage = oldImage
                $0.document.objectWillChange.send()
            }
        }
    }

    func resetAdjustments(for pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        let old = document.pages[pageIndex]

        document.pages[pageIndex].brightness = 0
        document.pages[pageIndex].contrast = 1.0
        document.pages[pageIndex].sharpness = 0
        document.pages[pageIndex].adjustedImage = document.pages[pageIndex].originalImage
        document.objectWillChange.send()

        registerUndo(name: "Reset Adjustments") {
            $0.document.pages[pageIndex].brightness = old.brightness
            $0.document.pages[pageIndex].contrast = old.contrast
            $0.document.pages[pageIndex].sharpness = old.sharpness
            $0.document.pages[pageIndex].adjustedImage = old.adjustedImage
            $0.document.objectWillChange.send()
        }
    }

    func applyAdjustmentsToAll() {
        guard let index = selectedPageIndex, document.pages.indices.contains(index) else { return }
        let source = document.pages[index]
        let oldPages = document.pages

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

        registerUndo(name: "Apply to All") {
            $0.document.pages = oldPages
            $0.document.objectWillChange.send()
        }
    }

    // MARK: - Annotations

    func registerAnnotationUndo(at pageIndex: Int, old: [Annotation]) {
        guard document.pages.indices.contains(pageIndex) else { return }
        registerUndo(name: "Annotation") {
            $0.document.pages[pageIndex].annotations = old
            $0.document.objectWillChange.send()
        }
    }

    // MARK: - Crop

    func cropPage(at index: Int, to rect: CGRect) {
        guard document.pages.indices.contains(index) else { return }
        let oldAdjusted = document.pages[index].adjustedImage
        let oldOriginal = document.pages[index].originalImage

        if let cropped = ImageProcessor.crop(image: document.pages[index].adjustedImage, to: rect) {
            document.pages[index].adjustedImage = cropped
            document.pages[index].originalImage = cropped
            document.objectWillChange.send()

            registerUndo(name: "Crop") {
                $0.document.pages[index].adjustedImage = oldAdjusted
                $0.document.pages[index].originalImage = oldOriginal
                $0.document.objectWillChange.send()
            }
        }
    }

    // MARK: - Page Management

    func deletePage(at index: Int) {
        guard document.pages.indices.contains(index) else { return }
        let removed = document.pages[index]
        let oldSelection = selectedPageIndices

        document.removePage(at: index)

        // Fix selection
        if selectedPageIndices.contains(index) {
            selectedPageIndices.remove(index)
        }
        // Shift indices above the removed one
        selectedPageIndices = Set(selectedPageIndices.map { $0 > index ? $0 - 1 : $0 })
        if selectedPageIndices.isEmpty && !document.pages.isEmpty {
            selectedPageIndices = [min(index, document.pages.count - 1)]
        }

        registerUndo(name: "Delete Page") {
            $0.document.pages.insert(removed, at: index)
            $0.selectedPageIndices = oldSelection
        }
    }

    func deleteSelectedPages() {
        let sorted = selectedPageIndices.sorted().reversed()
        let oldPages = document.pages
        let oldSelection = selectedPageIndices

        for index in sorted {
            if document.pages.indices.contains(index) {
                document.removePage(at: index)
            }
        }
        selectedPageIndices = document.pages.isEmpty ? [] : [0]

        registerUndo(name: "Delete Pages") {
            $0.document.pages = oldPages
            $0.selectedPageIndices = oldSelection
        }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        let oldPages = document.pages
        let oldSelection = selectedPageIndices
        document.movePage(from: source, to: destination)

        registerUndo(name: "Move Pages") {
            $0.document.pages = oldPages
            $0.selectedPageIndices = oldSelection
        }
    }

    func movePageUp(at index: Int) {
        guard index > 0, document.pages.indices.contains(index) else { return }
        let oldPages = document.pages
        document.pages.swapAt(index, index - 1)
        selectedPageIndices = [index - 1]
        registerUndo(name: "Move Page") {
            $0.document.pages = oldPages
            $0.selectedPageIndices = [index]
        }
    }

    func movePageDown(at index: Int) {
        guard index < document.pages.count - 1, document.pages.indices.contains(index) else { return }
        let oldPages = document.pages
        document.pages.swapAt(index, index + 1)
        selectedPageIndices = [index + 1]
        registerUndo(name: "Move Page") {
            $0.document.pages = oldPages
            $0.selectedPageIndices = [index]
        }
    }

    func selectAll() {
        selectedPageIndices = Set(document.pages.indices)
    }

    // MARK: - Export

    func exportPDF(to url: URL) {
        let pdf = PDFBuilder.buildPDF(from: document.pages)
        pdf.write(to: url)
    }

    func exportSelectedPDF(to url: URL) {
        let pages = selectedPageIndices.sorted().compactMap { idx in
            document.pages.indices.contains(idx) ? document.pages[idx] : nil
        }
        guard !pages.isEmpty else { return }
        let pdf = PDFBuilder.buildPDF(from: pages)
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

    // MARK: - Printing (placeholder)

    func printDocument() {
        scannerManager.errorMessage = "Printing not yet available"
    }

    // MARK: - Undo

    private func registerUndo(name: String, handler: @escaping (ScannerViewModel) -> Void) {
        undoManager.registerUndo(withTarget: self) { target in
            handler(target)
            target.objectWillChange.send()
        }
        undoManager.setActionName(name)
    }
}
