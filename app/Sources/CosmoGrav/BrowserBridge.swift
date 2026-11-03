import AppKit
import Foundation

/// The link between CosmoGrav and its browser extension.
///
/// - The extension talks to CosmoGrav through Chrome's "native messaging": Chrome starts this same program
///   (see NativeHost) and only for the CosmoGrav extension's id. No network port is opened, so web pages can't reach it.
/// - Links from the extension are written into a private inbox folder and the app is told to read it
///   with `cosmograv://inbox`.
/// - `cosmograv://add?url=…` also works from a bookmark or any browser. Those links are only added, never
///   started on their own, so a web page can't make the Mac download something by itself.
/// - The app ships the matching extension and copies it to a fixed folder, so when CosmoGrav updates the
///   extension reloads itself with the new version.
enum BrowserBridge {
    static let hostName = "com.creationofcosmos.cosmograv"
    /// Fixed by the public "key" in extension/manifest.json.
    static let extensionID = "bkpidlfkklifiknphemnicbhdfnidmhj"
    static var extensionOrigin: String { "chrome-extension://\(extensionID)/" }
    static let scheme = "cosmograv"

    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CosmoGrav", isDirectory: true)
    /// The folder you load into Chrome once. Updated on every launch of a newer CosmoGrav.
    static let extensionFolder = support.appendingPathComponent("Chrome Extension", isDirectory: true)
    static let inbox = Tools.base.appendingPathComponent("browser-inbox", isDirectory: true)
    static let statusFile = Tools.base.appendingPathComponent("browser-status.json")

    static var bundledExtension: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true)
    }

    /// Chrome-based browsers that read native messaging hosts from the user's Library.
    static let browserFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data", "com.operasoftware.Opera",
    ]

    // MARK: Limits for what a request may contain

    static let maxLinks = 1000
    static let maxLinkLength = 4096
    static let maxRequestBytes = 1 << 20

    /// Only ordinary web links, no local files, scripts or other schemes.
    static func isWebLink(_ text: String) -> Bool {
        guard text.count <= maxLinkLength, !text.contains(where: { $0.isNewline }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    struct Request: Codable, Equatable {
        struct Link: Codable, Equatable { var url: String; var title: String? }
        var items: [Link]
        var quality: String?
        var start: Bool?
        var from: Double?
        var to: Double?
        var mode: String?
        var name: String?
    }

    /// Checks and tidies a request; nil when nothing usable is left.
    static func sanitize(_ request: Request) -> Request? {
        var seen = Set<String>()
        var links: [Request.Link] = []
        for item in request.items where isWebLink(item.url) && seen.insert(item.url).inserted {
            let title = item.title.map { String($0.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines) }
            links.append(.init(url: item.url, title: title?.isEmpty == false ? title : nil))
            if links.count == maxLinks { break }
        }
        guard !links.isEmpty else { return nil }
        var clean = request
        clean.items = links
        clean.quality = request.quality.flatMap { Quality(rawValue: $0) }?.rawValue
        clean.mode = request.mode == "import" ? "import" : "queue"
        clean.name = request.name.map { String($0.prefix(120)) }
        let from = request.from.flatMap { $0.isFinite && $0 > 0 && $0 < 360_000 ? $0 : nil }
        let to = request.to.flatMap { $0.isFinite && $0 > (from ?? 0) + 0.5 && $0 < 360_000 ? $0 : nil }
        clean.from = links.count == 1 ? from : nil
        clean.to = links.count == 1 ? to : nil
        return clean
    }

    /// Reads `cosmograv://add?url=…&quality=…&from=…&to=…`. Never starts the download on its own.
    static func request(fromAddLink url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "add",
              url.absoluteString.count <= maxLinkLength * 2,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in parts.first { $0.name == name }?.value }
        guard let link = value("url") else { return nil }
        let request = Request(items: [.init(url: link, title: value("title"))], quality: value("quality"), start: false,
                              from: value("from").flatMap(Double.init), to: value("to").flatMap(Double.init), mode: "queue", name: nil)
        return sanitize(request)
    }

    // MARK: Inbox (written by the extension's helper, read by the app)

    static func writeToInbox(_ request: Request) throws -> URL {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = inbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(request)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// Takes every waiting request out of the inbox, oldest first.
    static func drainInbox() -> [Request] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        var requests: [Request] = []
        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxRequestBytes, let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  let clean = sanitize(request) else { continue }
            requests.append(clean)
        }
        return requests
    }

    // MARK: Setting up the browsers

    static func manifestJSON(executable: String) -> Data {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "CosmoGrav: receives links from the CosmoGrav browser extension",
            "path": executable,
            "type": "stdio",
            "allowed_origins": [extensionOrigin],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Tells each installed Chrome-based browser where CosmoGrav's helper is. Returns the browsers set up.
    @discardableResult
    static func installHosts() -> [String] {
        guard let executable = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") else { return [] }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let data = manifestJSON(executable: executable)
        var done: [String] = []
        for folder in browserFolders {
            let browser = library.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = hosts.appendingPathComponent("\(hostName).json")
            if (try? Data(contentsOf: file)) == data { done.append(folder); continue }
            do {
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                done.append(folder)
            } catch {
                continue
            }
        }
        return done
    }

    static func manifestVersion(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static var bundledVersion: String? { bundledExtension.flatMap(manifestVersion(at:)) }

    /// Copies the extension that came with this CosmoGrav into the folder Chrome loads, when it is newer.
    /// Swapped in one step so Chrome never sees a half-copied folder.
    @discardableResult
    static func syncExtensionFolder() -> Bool {
        guard let source = bundledExtension, let version = manifestVersion(at: source) else { return false }
        if let installed = manifestVersion(at: extensionFolder), !isNewer(version, than: installed) { return true }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let staging = support.appendingPathComponent(".Chrome Extension \(UUID().uuidString)", isDirectory: true)
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: extensionFolder.path) {
                _ = try fm.replaceItemAt(extensionFolder, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: extensionFolder)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Status for the extension's menu

    struct Status: Codable {
        struct Row: Codable { var title: String; var state: String; var progress: Double; var detail: String }
        var updated: Double
        var active: Int
        var waiting: Int
        var done: Int
        var failed: Int
        var items: [Row]
    }

    static func readStatus() -> (status: Status?, running: Bool) {
        guard let data = try? Data(contentsOf: statusFile), let status = try? JSONDecoder().decode(Status.self, from: data) else {
            return (nil, false)
        }
        // The app refreshes the file every three seconds while it is open.
        let running = Date().timeIntervalSince1970 - status.updated < 10
        return (running ? status : nil, running)
    }
}

/// The app side: reads the inbox, opens `cosmograv://` links and keeps the status file fresh.
@MainActor
final class BrowserLink {
    static var pendingURLs: [URL] = []
    private weak var queue: QueueManager?
    private var timer: Timer?
    private(set) var browsers: [String] = []

    init(queue: QueueManager) {
        self.queue = queue
        DispatchQueue.global(qos: .utility).async {
            BrowserBridge.syncExtensionFolder()
            let browsers = BrowserBridge.installHosts()
            DispatchQueue.main.async { [weak self] in self?.browsers = browsers }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let urls = Self.pendingURLs
            Self.pendingURLs = []
            urls.forEach(self.open)
            self.readInbox()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeStatus() }
        }
    }

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == BrowserBridge.scheme else { return }
        switch url.host?.lowercased() {
        case "inbox": readInbox()
        case "add": if let request = BrowserBridge.request(fromAddLink: url) { apply(request, fromWebLink: true) }
        default: NSApp.activate(ignoringOtherApps: true)
        }
    }

    func readInbox() {
        for request in BrowserBridge.drainInbox() { apply(request, fromWebLink: false) }
    }

    private func apply(_ request: BrowserBridge.Request, fromWebLink: Bool) {
        guard let queue else { return }
        let quality = request.quality.flatMap(Quality.init(rawValue:))
        if request.mode == "import" {
            queue.openImport(text: request.items.map(\.url).joined(separator: "\n"), name: request.name ?? "Links from the browser")
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        queue.addFromBrowser(request.items.map { (url: $0.url, title: $0.title) }, quality: quality,
                             autoStart: !fromWebLink && (request.start ?? true), from: request.from, to: request.to)
        if fromWebLink { NSApp.activate(ignoringOtherApps: true) }
        writeStatus()
    }

    func writeStatus() {
        guard let queue else { return }
        let rows = queue.items.reversed().prefix(8).map { item in
            BrowserBridge.Status.Row(title: item.title, state: Self.name(item.state), progress: item.progress, detail: item.detail)
        }
        let status = BrowserBridge.Status(updated: Date().timeIntervalSince1970, active: queue.activeCount, waiting: queue.waitingCount,
                                          done: queue.finishedCount, failed: queue.items.filter { $0.state == .failed }.count, items: Array(rows))
        guard let data = try? JSONEncoder().encode(status) else { return }
        // Always rewrite so the extension can tell the app is open; it's a tiny file.
        try? FileManager.default.createDirectory(at: Tools.base, withIntermediateDirectories: true)
        try? data.write(to: BrowserBridge.statusFile, options: .atomic)
    }

    func stop() {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: BrowserBridge.statusFile)
    }

    static func name(_ state: ItemState) -> String {
        switch state {
        case .fetching: return "fetching"
        case .ready: return "ready"
        case .queued: return "queued"
        case .downloading: return "downloading"
        case .converting: return "converting"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: Setup from Settings

    /// Puts the extension folder in place, opens Chrome's extensions page and shows the folder in Finder.
    static func setUpChrome() {
        BrowserBridge.syncExtensionFolder()
        BrowserBridge.installHosts()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserBridge.extensionFolder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([BrowserBridge.extensionFolder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", chrome.path, "chrome://extensions"]
            try? process.run()
        }
    }
}
