import SwiftUI

@main
struct ScanjetApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    private var model: ScannerModel { delegate.model }

    var body: some Scene {
        // A single window: the scanner is connected once per launch, not once per window.
        Window("Scanjet", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            // Nothing here prints, and Preview takes ⌘P.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .newItem) {
                Button("Preview", systemImage: "eye") { model.preview() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!model.canScan)
                Button("Scan", systemImage: "scanner") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canScan)
                Button("Cancel Scan", systemImage: "xmark.circle") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancel)
                Divider()
                Button("Save Scan…", systemImage: "square.and.arrow.down") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
            }
        }
    }
}

/// Owns the model so the scanner's lifetime follows the process: opened at launch, and released
/// on quit so the backend parks the carriage instead of being killed mid-read.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ScannerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.connect() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
