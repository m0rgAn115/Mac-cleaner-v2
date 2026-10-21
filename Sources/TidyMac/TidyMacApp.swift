import AppKit
import SwiftUI

@main
struct TidyMacApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("TidyMac") {
            ContentView(model: model)
                .onAppear { if CommandLine.arguments.contains("--scan"), model.phase == .prepared { model.scan() } }
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuevo escaneo") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command).disabled(model.busy)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
