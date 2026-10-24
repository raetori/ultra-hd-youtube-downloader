import AppKit
import Foundation

/// Checks GitHub for a newer release and installs it with the same script teammates used to install.
@MainActor
final class Updater: ObservableObject {
    @Published var availableVersion: String?
    @Published var updating = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() {
        Task {
            guard let url = URL(string: "https://api.github.com/repos/raetori/ultra-hd-youtube-downloader/releases/latest"),
                  let response = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(latest, than: Self.currentVersion) { availableVersion = latest }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Runs the installer in the background, quits, and the installer reopens the new version.
    func installUpdate() {
        updating = true
        QueueManager.shared?.stopEverything()
        let script = "sleep 1; curl -fsSL \(Tools.repoRaw)/install.sh | /bin/bash -s -- --update > \"$HOME/Library/Logs/CosmosMediaDownloader-update.log\" 2>&1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            updating = false
        }
    }
}
