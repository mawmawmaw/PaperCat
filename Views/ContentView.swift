import SwiftUI
import SystemConfiguration

struct ContentView: View {
    @EnvironmentObject var viewModel: ScannerViewModel

    var body: some View {
        NavigationSplitView {
            PageSidebarView()
                .frame(minWidth: 180)
        } detail: {
            if viewModel.scannerManager.isScanning && viewModel.document.pages.isEmpty {
                scanningState
            } else if viewModel.selectedPage != nil {
                VStack(spacing: 0) {
                    ScanPreviewView()
                    Divider()
                    AdjustmentsView()
                        .frame(height: 140)
                }
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                scannerStatusView

                Button(action: { viewModel.scan() }) {
                    Label("Scan", systemImage: "scanner")
                }
                .disabled(!viewModel.scannerManager.scannerIsReady || viewModel.scannerManager.isScanning)

                Menu {
                    Button("Export All as PDF...") { showExportPDFPanel() }
                    Button("Export Current Page...") { showExportPagePanel() }
                        .disabled(viewModel.selectedPage == nil)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.document.pages.isEmpty)

                // settingsMenu — disabled until dynamic scan parameters are tested
            }
        }
        .sheet(isPresented: $viewModel.showExportPanel) {
            ExportSheetView()
                .environmentObject(viewModel)
        }
    }

    // MARK: - Subviews

    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning...")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(viewModel.scannerManager.statusMessage)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "scanner")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Scanned Pages")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(viewModel.scannerManager.statusMessage)
                .font(.callout)
                .foregroundStyle(.tertiary)

            if viewModel.scannerManager.scannerIsReady {
                Button("Scan Now") { viewModel.scan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scannerStatusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.scannerManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        if viewModel.scannerManager.isScanning { return .orange }
        if viewModel.scannerManager.scannerIsReady { return .green }
        if viewModel.scannerManager.errorMessage != nil { return .red }
        return .yellow
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Resolution", selection: $viewModel.settings.resolution) {
                ForEach(ScanResolution.allCases) { res in
                    Text(res.label).tag(res)
                }
            }

            Picker("Color Mode", selection: $viewModel.settings.colorMode) {
                ForEach(ScanColorMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Picker("Paper Size", selection: $viewModel.settings.paperSize) {
                ForEach(PaperSize.allCases) { size in
                    Text(size.rawValue).tag(size)
                }
            }
        } label: {
            Label("Settings", systemImage: "gear")
        }
    }

    // MARK: - Export

    /// Get the real user's Documents folder (not root's) via the console session owner
    private static var userDocuments: URL {
        if getuid() == 0 {
            var uid: uid_t = 0
            if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? {
                return URL(fileURLWithPath: "/Users/\(name)/Documents")
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    private func showExportPDFPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(viewModel.document.name).pdf"
        panel.directoryURL = Self.userDocuments
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.exportPDF(to: url)
        }
    }

    private func showExportPagePanel() {
        let panel = NSSavePanel()
        let format = viewModel.settings.exportFormat
        switch format {
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .png: panel.allowedContentTypes = [.png]
        case .jpeg: panel.allowedContentTypes = [.jpeg]
        case .tiff: panel.allowedContentTypes = [.tiff]
        }
        panel.nameFieldStringValue = "scan.\(format.fileExtension)"
        panel.directoryURL = Self.userDocuments
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.exportCurrentPage(format: format, to: url)
        }
    }
}
