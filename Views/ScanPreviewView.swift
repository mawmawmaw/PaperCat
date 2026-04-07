import SwiftUI

struct ScanPreviewView: View {
    @EnvironmentObject var viewModel: ScannerViewModel
    @State private var zoomScale: CGFloat = 1.0
    @State private var showOCRPanel = false

    var body: some View {
        HSplitView {
            // Main image preview
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let page = viewModel.selectedPage {
                        Image(nsImage: page.adjustedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoomScale)
                            .frame(
                                width: geometry.size.width * zoomScale,
                                height: geometry.size.height * zoomScale
                            )
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding(12)
            }
            .overlay(alignment: .top) {
                if viewModel.scannerManager.isScanning {
                    ProgressView("Scanning...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 20)
                }
                if viewModel.isProcessingOCR {
                    ProgressView("Running OCR...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 20)
                }
            }

            // OCR panel (shown on demand)
            if showOCRPanel, let page = viewModel.selectedPage {
                OCRResultView(text: page.ocrText ?? "No OCR text. Right-click a page and select 'Run OCR'.")
                    .frame(minWidth: 250, maxWidth: 350)
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

                    Button(action: {
                        if let index = viewModel.selectedPageIndex {
                            viewModel.autoCrop(pageIndex: index)
                        }
                    }) {
                        Label("Auto-Crop", systemImage: "crop")
                    }

                    Button(action: { viewModel.printCurrentPage() }) {
                        Label("Print Page", systemImage: "printer")
                    }
                }
            }
        }
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
