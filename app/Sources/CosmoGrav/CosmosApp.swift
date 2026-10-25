import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(Array(CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst()))
        } else {
            CosmoGravApp.main()
        }
    }
}

struct CosmoGravApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var queue: QueueManager
    @StateObject private var updater = Updater()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        let queue = QueueManager(settings: settings)
        // Used by CI to photograph the queue with a few sample rows.
        if CommandLine.arguments.contains("--demo") { queue.loadDemo() }
        _queue = StateObject(wrappedValue: queue)
    }

    var body: some Scene {
        Window("CosmoGrav", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(queue)
                .environmentObject(updater)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutButton(title: "About CosmoGrav", ghost: false)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("Creation of Cosmos Website", destination: Tools.website)
            }
        }

        Window("About CosmoGrav", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(queue)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = (QueueManager.shared?.activeCount ?? 0) > 0
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Downloads are still running"
        alert.informativeText = "Quitting will stop them. Unfinished downloads are not saved."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertSecondButtonReturn {
            QueueManager.shared?.stopEverything()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        QueueManager.shared?.stopEverything()
        try? FileManager.default.removeItem(at: Tools.workRoot)
    }
}
