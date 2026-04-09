import SwiftUI

struct PageSidebarView: View {
    @EnvironmentObject var viewModel: ScannerViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedPageIndices) {
                ForEach(Array(viewModel.document.pages.enumerated()), id: \.element.id) { index, page in
                    PageThumbnailRow(page: page, index: index)
                        .tag(index)
                        .contextMenu {
                            Button("Run OCR") { viewModel.runOCR(on: index) }
                            Divider()
                            Button("Move Up") { viewModel.movePageUp(at: index) }
                                .disabled(index == 0)
                            Button("Move Down") { viewModel.movePageDown(at: index) }
                                .disabled(index == viewModel.document.pages.count - 1)
                            Divider()
                            Button("Delete", role: .destructive) { viewModel.deletePage(at: index) }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Text("\(viewModel.document.pages.count) page(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.selectedPageIndices.count > 1 {
                    Text("(\(viewModel.selectedPageIndices.count) selected)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
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
