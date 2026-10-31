import AppKit
import CryptoKit
import Foundation

/// Headless check of the download-page browser: `CosmoGrav --selftest-page PAGE_URL SHA256`.
/// The page (served on the build machine) waits a moment like a host's timer, then starts its own download;
/// CosmoGrav must take it into the queue and save the exact file.
enum PageSelfTest {
    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard args.count >= 2 else { print("usage: --selftest-page PAGE_URL SHA256"); exit(2) }
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print((ok ? "PASS " : "FAIL ") + what)
                if !ok { failures += 1 }
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmograv-page-\(UUID().uuidString)")
            let settings = AppSettings()
            settings.saveFolder = folder
            let queue = QueueManager(settings: settings)
            // Shaped like a file host's page: the link is a page, so it gets the download-page treatment,
            // then CosmoGrav must wait out the timer and click the free button on its own.
            queue.add(urls: [(url: args[0], title: nil)], autoStart: true)
            guard let item = queue.items.first else { print("FAIL no row"); exit(1) }

            let started = Date()
            var sawDownloading = false
            var sawPage = false
            while Date().timeIntervalSince(started) < 90 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if item.needsBrowser { sawPage = true }
                if item.state == .downloading && item.fileProbe == nil && item.title.hasSuffix(".7z") { sawDownloading = true }
                if item.state == .done || (sawDownloading && item.state != .downloading) { break }
            }
            print("STATE \(item.state) | \(item.detail) | \(item.errorMessage ?? "")")
            check(sawPage, "recognised as a download page, not \"Unsupported URL\"")
            check(sawDownloading, "waited out the timer, clicked the free button, download went into the queue")
            check(item.state == .done, "download finished")
            if let file = item.outputURL, let data = try? Data(contentsOf: file) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                print("SAVED \(file.lastPathComponent) \(data.count) bytes")
                check(hash == args[1].lowercased(), "saved file is byte for byte right")
                check(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, "saved in the save folder")
            } else {
                check(false, "saved file exists")
            }
            try? FileManager.default.removeItem(at: folder)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(1)
    }
}
