import AppKit
import Foundation

/// Set-up states for the step-by-step guide screenshots (CI only: `--shot NAME`).
/// Nothing here runs in normal use, and nothing it shows is saved.
enum Shot {
    static let name: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--shot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    static func `is`(_ shot: String) -> Bool { name == shot }

    /// Optional folder of poster images used as thumbnails (CI downloads them from the website).
    private static let thumbs = ProcessInfo.processInfo.environment["COSMOGRAV_THUMBS"].map { URL(fileURLWithPath: $0) }

    static func thumbnail(_ file: String) -> URL? {
        guard let url = thumbs?.appendingPathComponent(file), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Keeps the crop rectangle current, also while a modal panel or menu is open.
    @MainActor
    static func begin() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in Task { @MainActor in writeRect() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// SwiftUI has no public call to open Settings on macOS 14 and later, so use the app menu's own item.
    @MainActor
    static func openSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        menu.performActionForItem(at: index)
    }

    /// Opens the Quality pop-up in the options bar.
    @MainActor
    static func openQualityMenu() {
        func find(_ view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton { return button }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView, let button = find(root) else { return }
        button.performClick(nil)
    }

    /// Writes the screen rectangle around the app's visible windows (top-left origin) so CI can crop to it.
    @MainActor
    static func writeRect() {
        guard name != nil, let screen = NSScreen.main else { return }
        let frames = NSApp.windows.filter { $0.isVisible && $0.frame.width > 40 }.map(\.frame)
        guard var rect = frames.first else { return }
        for frame in frames.dropFirst() { rect = rect.union(frame) }
        rect = rect.insetBy(dx: -28, dy: -28).intersection(screen.frame)
        let top = screen.frame.maxY - rect.maxY
        let text = "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
        try? text.write(toFile: "/tmp/cosmograv-shot-rect.txt", atomically: true, encoding: .utf8)
    }
}

extension QueueManager {
    func loadShot(_ shot: String) {
        func make(_ title: String, file: String, site: String, duration: Double, resolution: String, quality: Quality = .best,
                  state: ItemState = .ready, progress: Double = 0, detail: String) -> DownloadItem {
            let item = DownloadItem(url: "https://www.youtube.com/watch?v=\(abs(title.hashValue) % 100_000)", quality: quality, title: title)
            item.site = site
            item.thumbnail = Shot.thumbnail(file)
            item.duration = duration
            item.resolution = resolution
            item.state = state
            item.progress = progress
            item.detail = detail
            item.infoLoaded = true
            return item
        }
        switch shot {
        case "added", "quality", "rename", "trim", "folder", "update":
            let cosmos = make("Creation of Cosmos", file: "creationofcosmos.jpg", site: "YouTube", duration: 152, resolution: "4K",
                              detail: "Ready · about 640 MB")
            let flip = make("Flip Ears", file: "flipears.jpg", site: "YouTube", duration: 64, resolution: "1080p",
                            detail: "Ready · about 120 MB")
            let pudpod = make("Pudpod", file: "pudpod.jpg", site: "Instagram", duration: 38, resolution: "1080p",
                              detail: "Ready · about 70 MB")
            if shot == "rename" || shot == "trim" { cosmos.fileName = "Cosmos launch - hero shot" }
            if shot == "trim" {
                cosmos.trimStart = 61
                cosmos.trimEnd = 94
            }
            items = [cosmos, flip, pudpod]
        case "queue":
            items = [
                make("Creation of Cosmos", file: "creationofcosmos.jpg", site: "YouTube", duration: 152, resolution: "4K",
                     state: .downloading, progress: 0.62, detail: "62% · 14.2 MB/s · 0:09 left"),
                make("Flip Ears", file: "flipears.jpg", site: "YouTube", duration: 64, resolution: "1080p",
                     state: .converting, progress: 0.35, detail: "Making it Premiere-ready · 35%"),
                make("Pudpod", file: "pudpod.jpg", site: "Instagram", duration: 38, resolution: "1080p",
                     state: .queued, detail: "Waiting for a free slot"),
            ]
        case "done":
            items = [
                make("Creation of Cosmos", file: "creationofcosmos.jpg", site: "YouTube", duration: 152, resolution: "4K",
                     state: .done, progress: 1, detail: "Saved to Downloads"),
                make("Flip Ears", file: "flipears.jpg", site: "YouTube", duration: 64, resolution: "1080p",
                     state: .done, progress: 1, detail: "Saved to Downloads"),
                make("Pudpod", file: "pudpod.jpg", site: "Instagram", duration: 38, resolution: "1080p", quality: .wav,
                     state: .done, progress: 1, detail: "Saved to Downloads"),
            ]
        case "history":
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let now = Date()
            history = [
                ("Creation of Cosmos", "YouTube", Quality.best, 0.0),
                ("Flip Ears", "YouTube", .hd1080, 3_600),
                ("Pudpod", "Instagram", .wav, 86_400),
                ("BingoPlus", "Facebook", .prores, 172_800),
                ("MGD", "TikTok", .mp3, 259_200),
            ].map { title, site, quality, age in
                HistoryEntry(title: title, url: "https://example.com", site: site,
                             filePath: downloads.appendingPathComponent("\(title).\(quality.fileExtension)").path,
                             quality: quality, date: now.addingTimeInterval(-age))
            }
        default:
            break
        }
    }
}
