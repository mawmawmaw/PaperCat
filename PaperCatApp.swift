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
        // When launched via the privilege-escalation launcher, monitor the launcher
        // process so that Force Quit also terminates this root process.
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
