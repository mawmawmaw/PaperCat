import SwiftUI

struct ExportSheetView: View {
    @EnvironmentObject var viewModel: ScannerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportFormat: ExportFormat = .pdf
    @State private var exportAll = true

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Scanned Document")
                .font(.title2.weight(.semibold))

            Form {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                if viewModel.document.pages.count > 1 {
                    Picker("Pages", selection: $exportAll) {
                        Text("All pages").tag(true)
                        Text("Current page only").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export...") {
                    performExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func performExport() {
        let panel = NSSavePanel()
        let ext = exportFormat.fileExtension

        if exportAll && exportFormat == .pdf {
            panel.nameFieldStringValue = "\(viewModel.document.name).\(ext)"
        } else {
            let pageNum = (viewModel.selectedPageIndex ?? 0) + 1
            panel.nameFieldStringValue = "page_\(pageNum).\(ext)"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            if exportAll && exportFormat == .pdf {
                viewModel.exportPDF(to: url)
            } else {
                viewModel.exportCurrentPage(format: exportFormat, to: url)
            }

            dismiss()
        }
    }
}
