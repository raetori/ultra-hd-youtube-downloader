import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(Array(CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst()))
        } else {
            CosmosMediaDownloaderApp.main()
        }
    }
}

struct CosmosMediaDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var queue: QueueManager
    @StateObject private var updater = Updater()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _queue = StateObject(wrappedValue: QueueManager(settings: settings))
    }

    var body: some Scene {
        Window("Cosmos Media Downloader", id: "main") {
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
                Button("About Cosmos Media Downloader") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("Creation of Cosmos Website", destination: Tools.website)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(queue)
                .tint(Theme.accent)
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

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Made by Creation of Cosmos\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(
            string: "creationofcosmos.com",
            attributes: [.link: Tools.website, .font: NSFont.systemFont(ofSize: 11)]))
        credits.append(NSAttributedString(
            string: "\n\nBuilt on yt-dlp, FFmpeg and Deno.\nPlease only download content you have the rights to use.",
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
