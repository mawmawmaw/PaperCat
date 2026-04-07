import SwiftUI

struct PageSidebarView: View {
    @EnvironmentObject var viewModel: ScannerViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedPageIndex) {
                ForEach(Array(viewModel.document.pages.enumerated()), id: \.element.id) { index, page in
                    PageThumbnailRow(page: page, index: index)
                        .tag(index)
                        .contextMenu {
                            Button("Run OCR") { viewModel.runOCR(on: index) }
                            Button("Auto-Crop") { viewModel.autoCrop(pageIndex: index) }
                            Divider()
                            Button("Delete", role: .destructive) { viewModel.deletePage(at: index) }
                        }
                }
                .onMove { source, destination in
                    viewModel.movePages(from: source, to: destination)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Text("\(viewModel.document.pages.count) page(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { viewModel.scan() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.scannerManager.scannerIsReady)
            }
            .padding(8)
        }
    }
}

struct PageThumbnailRow: View {
    let page: ScannedPage
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: page.adjustedImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 70)
                .border(Color.secondary.opacity(0.3), width: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Page \(index + 1)")
                    .font(.callout.weight(.medium))
                Text(page.scannedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if page.ocrText != nil {
                    Label("OCR", systemImage: "text.viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
