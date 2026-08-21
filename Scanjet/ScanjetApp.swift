import SwiftUI

@main
struct ScanjetApp: App {
    @State private var model = ScannerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.connect() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
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
                    .disabled(model.result == nil)
            }
        }
    }
}
