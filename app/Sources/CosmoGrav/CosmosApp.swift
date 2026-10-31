import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest-import") {
            ImportSelfTest.run()
        } else if CommandLine.arguments.contains("--selftest-crawljob") {
            CrawljobSelfTest.run()
        } else if CommandLine.arguments.contains("--selftest") {
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
        // Used by CI to photograph the Import window with a long sample list.
        if CommandLine.arguments.contains("--import-demo") { queue.openImport(text: ImportSelfTest.sampleList, name: "Sample list") }
        // Used by CI to photograph the .crawljob window.
        if CommandLine.arguments.contains("--crawljob-demo") {
            queue.crawljobDraft = CrawljobDraft(name: "Client reel.crawljob", report: Crawljob.parse(CrawljobSelfTest.sampleText))
        }
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
            CommandGroup(replacing: .newItem) {
                Button("Import Link List…") { queue.openImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open .crawljob…") { queue.chooseCrawljobs() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
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
    /// .crawljob files double-clicked in Finder or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == Crawljob.fileExtension }
        guard !files.isEmpty else { return }
        if let queue = QueueManager.shared { queue.openCrawljobs(files) } else { QueueManager.pendingFiles += files }
    }

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
