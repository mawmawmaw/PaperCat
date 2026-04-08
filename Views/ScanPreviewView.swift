import SwiftUI

struct ScanPreviewView: View {
    @EnvironmentObject var viewModel: ScannerViewModel
    @State private var zoomScale: CGFloat = 1.0
    @State private var showOCRPanel = false

    // Crop state
    @State private var isCropping = false
    @State private var cropStart: CGPoint = .zero
    @State private var cropEnd: CGPoint = .zero
    @State private var isDraggingCrop = false

    // Annotation state
    @State private var annotationMode: AnnotationMode = .none

    var body: some View {
        HSplitView {
            GeometryReader { geometry in
                if viewModel.scannerManager.isScanning {
                    scanningOverlay
                } else if let page = viewModel.selectedPage {
                    let imageSize = page.adjustedImage.size
                    let fitScale = min(
                        geometry.size.width / imageSize.width,
                        geometry.size.height / imageSize.height
                    )
                    let displayWidth = imageSize.width * fitScale * zoomScale
                    let displayHeight = imageSize.height * fitScale * zoomScale
                    let displaySize = CGSize(width: displayWidth, height: displayHeight)

                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: page.adjustedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: displayWidth, height: displayHeight)

                            // Annotation overlay
                            if let index = viewModel.selectedPageIndex {
                                let binding = Binding(
                                    get: { viewModel.document.pages[index].annotations },
                                    set: {
                                        viewModel.document.pages[index].annotations = $0
                                        viewModel.document.objectWillChange.send()
                                    }
                                )
                                AnnotationOverlay(
                                    annotations: binding,
                                    imageSize: imageSize,
                                    displaySize: displaySize,
                                    mode: annotationMode
                                )
                            }

                            // Crop overlay
                            if isCropping && isDraggingCrop {
                                cropOverlay
                            }
                        }
                        .frame(width: displayWidth, height: displayHeight)
                        .gesture(isCropping ? cropGesture(fitScale: fitScale) : nil)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        zoomControls
                            .padding(12)
                    }
                    .overlay(alignment: .bottom) {
                        if isCropping {
                            cropToolbar(fitScale: fitScale, imageSize: imageSize)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))

            if showOCRPanel, let page = viewModel.selectedPage {
                OCRResultView(text: page.ocrText ?? "No OCR text. Right-click a page and select 'Run OCR'.")
                    .frame(minWidth: 250, maxWidth: 350)
            }
        }
        .overlay(alignment: .top) {
            if viewModel.isProcessingOCR {
                ProgressView("Running OCR...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 20)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if viewModel.selectedPage != nil {
                    Button(action: {
                        if let index = viewModel.selectedPageIndex {
                            viewModel.runOCR(on: index)
                            showOCRPanel = true
                        }
                    }) {
                        Label("OCR", systemImage: "text.viewfinder")
                    }
                    .disabled(viewModel.isProcessingOCR)

                    Toggle(isOn: $showOCRPanel) {
                        Label("Text Panel", systemImage: "sidebar.trailing")
                    }

                    Toggle(isOn: $isCropping) {
                        Label("Crop", systemImage: "crop")
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { annotationMode == .text },
                        set: { annotationMode = $0 ? .text : .none }
                    )) {
                        Label("Add Note", systemImage: "note.text")
                    }

                    Toggle(isOn: Binding(
                        get: { annotationMode == .draw },
                        set: { annotationMode = $0 ? .draw : .none }
                    )) {
                        Label("Draw", systemImage: "pencil.tip")
                    }
                }
            }
        }
        .onChange(of: viewModel.selectedPageIndex) {
            isCropping = false
            isDraggingCrop = false
            annotationMode = .none
        }
        .onChange(of: isCropping) {
            if isCropping { annotationMode = .none }
        }
        .onChange(of: annotationMode) {
            if annotationMode != .none { isCropping = false; isDraggingCrop = false }
        }
    }

    // MARK: - Crop

    private func cropGesture(fitScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDraggingCrop {
                    cropStart = value.startLocation
                    isDraggingCrop = true
                }
                cropEnd = value.location
            }
            .onEnded { _ in }
    }

    private var cropOverlay: some View {
        let rect = normalizedCropRect
        return Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.1))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.origin.x, y: rect.origin.y)
    }

    private var normalizedCropRect: CGRect {
        let x = min(cropStart.x, cropEnd.x)
        let y = min(cropStart.y, cropEnd.y)
        let w = abs(cropEnd.x - cropStart.x)
        let h = abs(cropEnd.y - cropStart.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func cropToolbar(fitScale: CGFloat, imageSize: CGSize) -> some View {
        HStack(spacing: 12) {
            if isDraggingCrop {
                Button("Apply Crop") {
                    applyCrop(fitScale: fitScale, imageSize: imageSize)
                }
                .buttonStyle(.borderedProminent)

                Button("Clear") {
                    isDraggingCrop = false
                }
                .buttonStyle(.bordered)
            } else {
                Text("Drag to select crop area")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                isCropping = false
                isDraggingCrop = false
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func applyCrop(fitScale: CGFloat, imageSize: CGSize) {
        guard let index = viewModel.selectedPageIndex,
              let page = viewModel.selectedPage,
              let cgImage = page.adjustedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let displayRect = normalizedCropRect
        let displayScale = fitScale * zoomScale

        let pointX = displayRect.origin.x / displayScale
        let pointY = displayRect.origin.y / displayScale
        let pointW = displayRect.width / displayScale
        let pointH = displayRect.height / displayScale

        let pixelScaleX = CGFloat(cgImage.width) / imageSize.width
        let pixelScaleY = CGFloat(cgImage.height) / imageSize.height

        let pixelRect = CGRect(
            x: pointX * pixelScaleX,
            y: pointY * pixelScaleY,
            width: pointW * pixelScaleX,
            height: pointH * pixelScaleY
        )

        viewModel.cropPage(at: index, to: pixelRect)
        isCropping = false
        isDraggingCrop = false
    }

    // MARK: - Subviews

    private var scanningOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning...")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(viewModel.scannerManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button(action: { zoomScale = max(0.25, zoomScale - 0.25) }) {
                Image(systemName: "minus.magnifyingglass")
            }

            Text("\(Int(zoomScale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)

            Button(action: { zoomScale = min(4.0, zoomScale + 0.25) }) {
                Image(systemName: "plus.magnifyingglass")
            }

            Button(action: { zoomScale = 1.0 }) {
                Image(systemName: "1.magnifyingglass")
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
