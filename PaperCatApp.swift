import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct PaperCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ScannerViewModel()

    init() {
        if let pidStr = ProcessInfo.processInfo.environment["PAPERCAT_LAUNCHER_PID"],
           let launcherPID = Int32(pidStr) {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    Thread.sleep(forTimeInterval: 1.0)
                    if kill(launcherPID, 0) != 0 {
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                        break
                    }
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .commands {
            // Undo/Redo — don't use .disabled since UndoManager state isn't observable
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    viewModel.undoManager.undo()
                    viewModel.objectWillChange.send()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    viewModel.undoManager.redo()
                    viewModel.objectWillChange.send()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            // Disable "New Window", add scan/export shortcuts
            CommandGroup(replacing: .newItem) {
                Button("Scan Page") {
                    viewModel.scan()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Export as PDF...") {
                    viewModel.showExportPanel = true
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    viewModel.printDocument()
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Select All Pages") {
                    viewModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(viewModel.document.pages.isEmpty)

                Button("Delete Selected") {
                    viewModel.deleteSelectedPages()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(viewModel.selectedPageIndices.isEmpty)
            }
        }
    }
}
