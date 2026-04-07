import SwiftUI

@main
struct PaperCatApp: App {
    @StateObject private var viewModel = ScannerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Page") {
                    viewModel.scan()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Export as PDF...") {
                    viewModel.showExportPanel = true
                }
                .keyboardShortcut("e", modifiers: [.command])
            }

            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    viewModel.printDocument()
                }
                .keyboardShortcut("p", modifiers: .command)
            }
        }
    }
}
