import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var defaultQuality: Quality { didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") } }
    @Published var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    /// Browser whose login yt-dlp may borrow when a site insists on one ("none" = never).
    @Published var loginBrowser: String { didSet { defaults.set(loginBrowser, forKey: "loginBrowser") } }

    static let browsers: [(id: String, name: String)] = [
        ("none", "Don't use a login"), ("safari", "Safari"), ("chrome", "Google Chrome"), ("brave", "Brave"),
        ("edge", "Microsoft Edge"), ("firefox", "Firefox"), ("opera", "Opera"), ("vivaldi", "Vivaldi"),
    ]

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0) } ?? downloads
        defaultQuality = defaults.string(forKey: "defaultQuality").flatMap(Quality.init(rawValue:)) ?? .best
        let stored = defaults.integer(forKey: "maxConcurrent")
        maxConcurrent = (1...3).contains(stored) ? stored : 2
        loginBrowser = defaults.string(forKey: "loginBrowser") ?? "none"
    }

    var loginBrowserName: String {
        Self.browsers.first { $0.id == loginBrowser }?.name ?? loginBrowser
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        panel.prompt = "Save Here"
        panel.message = "Choose where downloads are saved"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }
}

@MainActor
final class QueueManager: ObservableObject {
    static weak var shared: QueueManager?

    @Published var items: [DownloadItem] = [] { didSet { observeItems() } }
    @Published var history: [HistoryEntry] = []
    @Published var toolsMissing = !Tools.installed

    let settings: AppSettings
    private let infoLimiter = AsyncLimiter(4)
    private var itemObservers: [AnyCancellable] = []

    /// Rows observe their own item, but the footer (Download all, counts) reads every item's state,
    /// so a state change on any item has to refresh the queue as well.
    private func observeItems() {
        itemObservers = items.map { item in
            item.$state.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
        loadHistory()
        QueueManager.shared = self
        Task.detached(priority: .background) { await Tools.updateDownloaderIfStale() }
    }

    var activeCount: Int { items.filter { $0.state.isActive }.count }
    var readyCount: Int { items.filter { $0.state.canStart }.count }
    var finishedCount: Int { items.filter { $0.state == .done }.count }
    var waitingCount: Int { items.filter { $0.state == .queued }.count }

    // MARK: Adding

    @discardableResult
    func add(text: String) -> Int {
        let links = LinkParser.links(in: text)
        add(urls: links.map { (url: $0, title: String?.none) })
        return links.count
    }

    func add(urls: [(url: String, title: String?)]) {
        toolsMissing = !Tools.installed
        for entry in urls {
            if items.contains(where: { $0.url == entry.url && $0.state != .done }) { continue }
            let item = DownloadItem(url: entry.url, quality: settings.defaultQuality, title: entry.title)
            items.append(item)
            fetchInfo(item)
        }
    }

    func fetchInfo(_ item: DownloadItem) {
        item.state = .fetching
        item.detail = "Getting info…"
        item.errorMessage = nil
        let url = item.url, quality = item.quality, useLogin = item.useLogin, browser = settings.loginBrowser
        Task {
            await infoLimiter.acquire()
            defer { Task { await infoLimiter.release() } }
            do {
                let info = try await Pipeline.fetchInfo(url: url, quality: quality, useLogin: useLogin, browser: browser)
                if let entries = info.entries {
                    // A playlist link becomes one row per video.
                    items.removeAll { $0.id == item.id }
                    add(urls: entries)
                    return
                }
                item.title = info.title
                if item.fileName.isEmpty || !item.infoLoaded { item.fileName = FileNames.sanitize(info.title) }
                item.site = Self.siteName(info.site, url: url)
                item.thumbnail = info.thumbnail
                item.duration = info.duration
                item.resolution = item.quality.isAudio ? nil : Pipeline.resolutionLabel(height: info.height)
                item.expectedParts = info.parts
                item.infoLoaded = true
                item.needsLogin = false
                if item.state == .fetching { item.state = .ready; item.detail = "Ready" }
            } catch {
                let err = error as? PipelineError
                item.state = .failed
                item.errorMessage = err?.message ?? error.localizedDescription
                item.needsLogin = err?.needsLogin ?? false
                item.detail = "Couldn't load this link"
                if item.site.isEmpty { item.site = Self.siteName("", url: url) }
            }
        }
    }

    static func siteName(_ extractor: String, url: String) -> String {
        let host = (URL(string: url)?.host ?? "").lowercased()
        let known: [(String, String)] = [("youtu", "YouTube"), ("tiktok", "TikTok"), ("instagram", "Instagram"),
                                         ("facebook", "Facebook"), ("fb.watch", "Facebook"), ("vimeo", "Vimeo"),
                                         ("twitter", "X"), ("x.com", "X"), ("twitch", "Twitch"), ("reddit", "Reddit"),
                                         ("soundcloud", "SoundCloud"), ("dailymotion", "Dailymotion")]
        if let match = known.first(where: { host.contains($0.0) }) { return match.1 }
        if !extractor.isEmpty, extractor.lowercased() != "generic" { return extractor }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: Running

    func start(_ item: DownloadItem) {
        guard item.state.canStart else { return }
        if !item.infoLoaded { fetchInfo(item); return }
        item.state = .queued
        item.detail = "Waiting…"
        item.errorMessage = nil
        item.progress = 0
        pump()
    }

    func startAll() {
        for item in items where item.state == .ready { item.state = .queued; item.detail = "Waiting…"; item.progress = 0 }
        pump()
    }

    func retry(_ item: DownloadItem, withLogin: Bool = false) {
        if withLogin { item.useLogin = true }
        if item.infoLoaded { start(item) } else { fetchInfo(item) }
    }

    func cancel(_ item: DownloadItem) {
        switch item.state {
        case .queued:
            item.state = .ready
            item.detail = "Ready"
        case .downloading, .converting:
            item.runner?.cancel()
            item.detail = "Stopping…"
        default:
            break
        }
    }

    func cancelAll() {
        for item in items where item.state == .queued || item.state.isActive { cancel(item) }
    }

    func remove(_ item: DownloadItem) {
        if item.state.isActive { item.runner?.cancel() }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .cancelled }
    }

    private func pump() {
        var slots = settings.maxConcurrent - activeCount
        for item in items where item.state == .queued && slots > 0 {
            slots -= 1
            run(item)
        }
        updateDockBadge()
    }

    private func run(_ item: DownloadItem) {
        let handle = RunningProcess()
        item.runner = handle
        item.state = .downloading
        item.progress = 0
        item.detail = "Starting…"
        item.errorMessage = nil

        let url = item.url, quality = item.quality, parts = item.expectedParts
        let useLogin = item.useLogin, browser = settings.loginBrowser
        let trimStart = item.trimStart, trimEnd = item.trimEnd, duration = item.duration
        let folder = settings.saveFolder
        let work = Tools.workRoot.appendingPathComponent(item.id.uuidString)

        let report: @Sendable (Double, String) -> Void = { [weak item] value, text in
            Task { @MainActor in
                guard let item, item.state.isActive else { return }
                item.progress = value
                item.detail = text
            }
        }

        Task {
            do {
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }

                let temp = work.appendingPathComponent("final." + quality.fileExtension)
                var done = false
                if trimStart != nil || trimEnd != nil {
                    done = try await Pipeline.downloadSection(url: url, quality: quality, trimStart: trimStart, trimEnd: trimEnd,
                                                              duration: duration, useLogin: useLogin, browser: browser,
                                                              output: temp, handle: handle, onProgress: report)
                }
                if !done {
                    let downloaded = try await Pipeline.download(url: url, quality: quality, expectedParts: parts,
                                                                 useLogin: useLogin, browser: browser,
                                                                 workDir: work, handle: handle, onProgress: report)
                    item.state = .converting
                    item.progress = 0
                    try await Pipeline.finalize(input: downloaded, quality: quality, trimStart: trimStart, trimEnd: trimEnd,
                                                output: temp, handle: handle, onProgress: report)
                }

                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = item.fileName.isEmpty ? item.title : item.fileName
                let destination = FileNames.unique(in: folder, name: name, ext: quality.fileExtension)
                try FileManager.default.moveItem(at: temp, to: destination)

                item.outputURL = destination
                item.state = .done
                item.progress = 1
                item.detail = "Saved to \(folder.lastPathComponent)"
                addHistory(item, file: destination)
            } catch {
                if handle.cancelled || error is CancellationError {
                    item.state = .cancelled
                    item.detail = "Cancelled"
                } else {
                    let err = error as? PipelineError
                    item.state = .failed
                    item.errorMessage = err?.message ?? error.localizedDescription
                    item.needsLogin = err?.needsLogin ?? false
                    item.detail = "Failed"
                }
            }
            item.runner = nil
            pump()
            if activeCount == 0 && waitingCount == 0 && finishedCount > 0 {
                _ = NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    private func updateDockBadge() {
        let pending = activeCount + waitingCount
        NSApp.dockTile.badgeLabel = pending > 0 ? "\(pending)" : nil
    }

    // MARK: History (kept only on this Mac)

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Tools.historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        history = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Tools.base, withIntermediateDirectories: true)
        try? encoder.encode(history).write(to: Tools.historyFile, options: .atomic)
    }

    private func addHistory(_ item: DownloadItem, file: URL) {
        history.insert(HistoryEntry(title: item.title, url: item.url, site: item.site,
                                    filePath: file.path, quality: item.quality, date: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    func redownload(_ entry: HistoryEntry) {
        let item = DownloadItem(url: entry.url, quality: entry.quality, title: entry.title)
        items.append(item)
        fetchInfo(item)
    }

    func stopEverything() {
        for item in items where item.state.isActive { item.runner?.cancel() }
    }
}
