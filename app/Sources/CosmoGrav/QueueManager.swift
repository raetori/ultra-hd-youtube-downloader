import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var defaultQuality: Quality { didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") } }
    @Published var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent") } }
    /// Browser whose login yt-dlp may borrow when a site insists on one ("none" = never).
    @Published var loginBrowser: String { didSet { defaults.set(loginBrowser, forKey: "loginBrowser") } }
    /// Also save captions (.srt) next to each video when the site has them.
    @Published var saveCaptions: Bool { didSet { defaults.set(saveCaptions, forKey: "saveCaptions") } }
    @Published var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }
    @Published var watchClipboard: Bool { didSet { defaults.set(watchClipboard, forKey: "watchClipboard") } }
    /// Folder Watch: .crawljob files dropped into `watchFolder` are added on their own, like JDownloader.
    @Published var watchFolderOn: Bool { didSet { defaults.set(watchFolderOn, forKey: "watchFolderOn") } }
    @Published var watchFolder: URL { didSet { defaults.set(watchFolder.path, forKey: "watchFolder") } }
    /// For files that don't say autoStart=TRUE or FALSE themselves.
    @Published var watchAutoStart: Bool { didSet { defaults.set(watchAutoStart, forKey: "watchAutoStart") } }

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
        saveCaptions = defaults.bool(forKey: "saveCaptions")
        notifyWhenDone = defaults.object(forKey: "notifyWhenDone") as? Bool ?? true
        watchClipboard = defaults.object(forKey: "watchClipboard") as? Bool ?? true
        watchFolderOn = defaults.bool(forKey: "watchFolderOn")
        watchFolder = defaults.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? downloads.appendingPathComponent("CosmoGrav Folder Watch", isDirectory: true)
        watchAutoStart = defaults.object(forKey: "watchAutoStart") as? Bool ?? true
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

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = watchFolder
        panel.prompt = "Watch This Folder"
        panel.message = "Choose the folder where .crawljob files are dropped"
        if panel.runModal() == .OK, let url = panel.url { watchFolder = url }
    }
}

@MainActor
final class QueueManager: ObservableObject {
    static weak var shared: QueueManager?

    @Published var items: [DownloadItem] = [] { didSet { observeItems() } }
    @Published var history: [HistoryEntry] = []
    @Published var toolsMissing = !Tools.installed
    /// Links found on the clipboard when the app comes to the front, offered with one click.
    @Published var clipboardLinks: [String] = []
    /// An imported list waiting in the Import window (pasted, opened or dropped).
    @Published var importDraft: ImportDraft?
    /// Batches from an imported list that haven't been added to the queue yet.
    @Published var pendingBatches: [LinkBatch] = []
    /// Add the next batch on its own once the current one has finished.
    @Published var autoContinue = false
    /// A .crawljob file waiting in its review window (opened, double-clicked or dropped).
    @Published var crawljobDraft: CrawljobDraft?
    /// What Folder Watch just did, shown as a banner.
    @Published var watchNotice: String?
    /// Files opened from Finder before the queue existed.
    static var pendingFiles: [URL] = []
    private var watcher: CrawljobWatcher?
    /// The download page shown in CosmoGrav's browser.
    @Published var browserItem: DownloadItem?
    private var browserSessions: [UUID: BrowserSession] = [:]
    private var settingsObservers: Set<AnyCancellable> = []
    private var lastPasteboardChange = NSPasteboard.general.changeCount

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
        Task.detached(priority: .background) { FileDownloader.cleanStale() }
        let watcher = CrawljobWatcher(queue: self)
        self.watcher = watcher
        settings.$watchFolderOn.combineLatest(settings.$watchFolder)
            .sink { on, folder in watcher.configure(enabled: on, folder: folder) }
            .store(in: &settingsObservers)
        if !Self.pendingFiles.isEmpty {
            openCrawljobs(Self.pendingFiles)
            Self.pendingFiles = []
        }
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

    func add(urls: [(url: String, title: String?)], folder: [String] = [], baseFolder: URL? = nil, autoStart: Bool = false,
             quality: Quality? = nil) {
        toolsMissing = !Tools.installed
        for entry in urls {
            if items.contains(where: { $0.url == entry.url && $0.state != .done }) { continue }
            let item = DownloadItem(url: entry.url, quality: quality ?? settings.defaultQuality, title: entry.title)
            item.folder = folder
            item.baseFolder = baseFolder
            item.autoStart = autoStart
            items.append(item)
            fetchInfo(item)
        }
    }

    // MARK: Download pages (file hosts)

    func openDownloadPage(_ item: DownloadItem) {
        if browserSessions[item.id] == nil { browserSessions[item.id] = BrowserSession(item: item, queue: self) }
        browserItem = item
    }

    func browserSession(for item: DownloadItem) -> BrowserSession? { browserSessions[item.id] }

    func pageDownloadStarted(_ session: BrowserSession, name: String, ext: String, size: Int64?, handle: RunningProcess) {
        let item = session.item
        item.runner = handle
        item.title = name + "." + ext
        if item.fileName.isEmpty || !item.infoLoaded { item.fileName = name }
        item.site = Self.siteName("", url: item.url)
        item.state = .downloading
        item.progress = 0
        item.errorMessage = nil
        item.needsBrowser = false
        item.detail = "Downloading from the site…" + (size.map { " " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        browserItem = nil
        updateDockBadge()
    }

    func pageDownloadProgress(_ session: BrowserSession, fraction: Double, detail: String) {
        let item = session.item
        guard item.state == .downloading else { return }
        item.progress = min(max(fraction, 0), 1)
        item.detail = detail
    }

    func pageDownloadFinished(_ session: BrowserSession, file: URL) {
        let item = session.item
        browserSessions.removeValue(forKey: item.id)?.close()
        let folder = item.folder.reduce(item.baseFolder ?? settings.saveFolder) { $0.appendingPathComponent($1, isDirectory: true) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = file.pathExtension.isEmpty ? "bin" : file.pathExtension
            let name = item.fileName.isEmpty ? file.deletingPathExtension().lastPathComponent : item.fileName
            let destination = FileNames.unique(in: folder, name: name, ext: ext)
            try FileManager.default.moveItem(at: file, to: destination)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            item.outputURL = destination
            item.state = .done
            item.progress = 1
            item.detail = "Saved to \(folder.lastPathComponent)"
            addHistory(item, file: destination)
        } catch {
            item.state = .failed
            item.errorMessage = "The download finished but couldn't be saved: \(error.localizedDescription)"
            item.detail = "Failed"
        }
        item.runner = nil
        finishedOne()
    }

    func pageDownloadFailed(_ session: BrowserSession, error: Error) {
        let item = session.item
        browserSessions.removeValue(forKey: item.id)?.close()
        let stopped = item.runner?.cancelled ?? false
        item.state = stopped ? .cancelled : .failed
        item.needsBrowser = true
        item.errorMessage = stopped ? nil : "The site stopped the download (\(error.localizedDescription)). Open the download page again to retry."
        item.detail = stopped ? "Stopped. Open the download page again to restart." : "Failed"
        item.runner = nil
        finishedOne()
    }

    // MARK: .crawljob files

    /// Reads one or more .crawljob files into the review window (added to it if it is already open).
    func openCrawljobs(_ files: [URL]) {
        guard !files.isEmpty else { return }
        var report = CrawljobReport()
        for file in files {
            do {
                report.merge(Crawljob.parse(try LinkImport.read(file: file)))
            } catch {
                report.merge(CrawljobReport(error: "\(file.lastPathComponent): \(error.localizedDescription)"))
            }
        }
        if let open = crawljobDraft {
            // A new draft (new id) so the open window shows the added files.
            var merged = open.report
            merged.merge(report)
            crawljobDraft = CrawljobDraft(name: "\(open.name) + more", report: merged)
        } else {
            let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "\(files.count) crawljob files"
            crawljobDraft = CrawljobDraft(name: name, report: report)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseCrawljobs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Crawljob.fileExtension) ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more JDownloader .crawljob files"
        guard panel.runModal() == .OK else { return }
        openCrawljobs(panel.urls)
    }

    /// Adds each job's links, saving where the job says. Returns how many links were added.
    @discardableResult
    func addCrawljobs(_ jobs: [CrawlJob], quality: Quality, startByDefault: Bool) -> Int {
        toolsMissing = !Tools.installed
        var added = 0
        for job in jobs {
            let place = Crawljob.destination(for: job, saveFolder: settings.saveFolder)
            let name = job.links.count == 1 ? Crawljob.fileName(job.filename) : nil
            for link in job.links {
                if items.contains(where: { $0.url == link && $0.state != .done }) { continue }
                let item = DownloadItem(url: link, quality: quality)
                item.baseFolder = place.base
                item.folder = place.folder
                item.autoStart = job.autoStart ?? startByDefault
                if let name {
                    item.fileName = name
                    item.keepFileName = true
                }
                items.append(item)
                fetchInfo(item)
                added += 1
            }
        }
        return added
    }

    // MARK: Imported lists

    func openImport(text: String = "", name: String = "Pasted links") {
        importDraft = ImportDraft(text: text, name: name)
    }

    /// Adds the first batch now. The rest wait under "Up next", and follow on their own when `auto` is on.
    func importBatches(_ list: [LinkBatch], auto: Bool, quality: Quality) {
        let batches = list.map { batch -> LinkBatch in
            var batch = batch
            batch.quality = quality
            return batch
        }
        guard let first = batches.first else { return }
        autoContinue = auto
        pendingBatches = Array(batches.dropFirst())
        add(batch: first)
    }

    func addNextBatch() {
        guard !pendingBatches.isEmpty else { return }
        add(batch: pendingBatches.removeFirst())
    }

    func setAutoContinue(_ on: Bool) {
        autoContinue = on
        continueBatchesIfIdle()
    }

    func clearPendingBatches() {
        pendingBatches = []
        autoContinue = false
    }

    private func add(batch: LinkBatch) {
        add(urls: batch.links.map { (url: $0.url, title: String?.none) }, folder: batch.folder, autoStart: autoContinue,
            quality: batch.quality)
        if autoContinue { startAll() }
    }

    /// In auto mode, moves on to the next batch once nothing from the current one is loading or downloading.
    private func continueBatchesIfIdle() {
        guard autoContinue, !pendingBatches.isEmpty else { return }
        let busy = items.contains { $0.state == .fetching || $0.state == .queued || $0.state.isActive || ($0.autoStart && $0.state == .ready) }
        if !busy { addNextBatch() }
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
                if let resolution = FileLinks.resolve(url) {
                    switch resolution {
                    case .unsupported(let reason):
                        throw PipelineError(message: reason)
                    case .file(let direct, let service):
                        do {
                            applyFile(item, try await FileDownloader.probe(direct, service: service), service: service)
                        } catch is WebPageError {
                            throw Self.downloadPageError
                        }
                        return
                    }
                }
                let info: MediaInfo
                do {
                    info = try await Pipeline.fetchInfo(url: url, quality: quality, useLogin: useLogin, browser: browser)
                } catch let error as PipelineError where error.message.lowercased().contains("unsupported url") {
                    // Not a video site: it may still be a plain file link without a file name in it.
                    guard let direct = URL(string: url) else { throw error }
                    do {
                        applyFile(item, try await FileDownloader.probe(direct, service: nil), service: nil)
                    } catch is WebPageError {
                        throw Self.downloadPageError
                    } catch {
                        throw PipelineError(message: "CosmoGrav doesn't know this site, and the link isn't a file it can download: \(error.localizedDescription)")
                    }
                    return
                }
                item.fileProbe = nil
                if let entries = info.entries {
                    // A playlist link becomes one row per video.
                    items.removeAll { $0.id == item.id }
                    add(urls: entries, folder: item.folder, baseFolder: item.baseFolder, autoStart: item.autoStart, quality: item.quality)
                    return
                }
                item.title = info.title
                if !item.keepFileName, item.fileName.isEmpty || !item.infoLoaded { item.fileName = FileNames.sanitize(info.title) }
                item.site = Self.siteName(info.site, url: url)
                item.thumbnail = info.thumbnail
                item.duration = info.duration
                item.resolution = item.quality.isAudio || !item.quality.hasMedia ? nil : Pipeline.resolutionLabel(height: info.height)
                item.expectedParts = info.parts
                item.infoLoaded = true
                item.needsLogin = false
                if item.state == .fetching { item.state = .ready; item.detail = "Ready" }
                if item.autoStart { start(item) }
            } catch {
                let err = error as? PipelineError
                item.state = .failed
                item.errorMessage = err?.message ?? error.localizedDescription
                item.needsBrowser = err?.needsBrowser ?? false
                item.needsLogin = item.needsBrowser ? false : (err?.needsLogin ?? false)
                item.detail = item.needsBrowser ? "Download page" : "Couldn't load this link"
                if item.site.isEmpty { item.site = Self.siteName("", url: url) }
                continueBatchesIfIdle()
            }
        }
    }

    static let downloadPageError = PipelineError(
        message: "This is a download page, not the file itself. Click Open download page, use the site's free download button there (wait out its timer), and CosmoGrav takes over the download.",
        needsBrowser: true)

    private func applyFile(_ item: DownloadItem, _ probe: FileProbe, service: String?) {
        item.fileProbe = probe
        item.title = probe.name + "." + probe.ext
        if !item.keepFileName, item.fileName.isEmpty || !item.infoLoaded { item.fileName = probe.name }
        item.site = service ?? Self.siteName("", url: item.url)
        item.thumbnail = nil
        item.duration = nil
        item.resolution = nil
        item.trimStart = nil
        item.trimEnd = nil
        item.infoLoaded = true
        item.needsLogin = false
        item.needsBrowser = false
        if item.state == .fetching {
            item.state = .ready
            let size = probe.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            let resumable = FileDownloader.totalSize(FileDownloader.piecesFolder(for: item.url).contentsIfAny.filter { $0.lastPathComponent.hasPrefix("piece-") || $0.lastPathComponent == "complete" }) > 0
            item.detail = (resumable ? "Ready to resume" : "Ready") + size + " · kept as .\(probe.ext)"
        }
        if item.autoStart { start(item) }
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
            item.autoStart = false
        case .downloading, .converting:
            item.runner?.cancel()
            item.detail = "Stopping…"
        default:
            break
        }
    }

    func cancelAll() {
        autoContinue = false
        for item in items where item.state == .queued || item.state.isActive { cancel(item) }
    }

    func remove(_ item: DownloadItem) {
        if item.state.isActive { item.runner?.cancel() }
        browserSessions.removeValue(forKey: item.id)?.close()
        items.removeAll { $0.id == item.id }
        continueBatchesIfIdle()
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
        let folder = item.folder.reduce(item.baseFolder ?? settings.saveFolder) { $0.appendingPathComponent($1, isDirectory: true) }
        let captions = settings.saveCaptions
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

                if let probe = item.fileProbe {
                    // A file kept exactly as it is: downloaded in pieces that survive a stop, then moved into place.
                    let pieces = FileDownloader.piecesFolder(for: url)
                    let downloaded = try await FileDownloader.download(probe, folder: pieces, handle: handle, onProgress: report)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = item.fileName.isEmpty ? probe.name : item.fileName
                    let destination = FileNames.unique(in: folder, name: name, ext: probe.ext)
                    try FileManager.default.moveItem(at: downloaded, to: destination)
                    try? FileManager.default.removeItem(at: pieces)
                    item.outputURL = destination
                    item.state = .done
                    item.progress = 1
                    item.detail = "Saved to \(folder.lastPathComponent)"
                    addHistory(item, file: destination)
                } else if !quality.hasMedia {
                    // Captions only: no video is downloaded.
                    item.detail = "Saving captions…"
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = item.fileName.isEmpty ? item.title : item.fileName
                    // "Name.en.srt", or "Name (2).en.srt" when that already exists.
                    let base = FileNames.unique(in: folder, name: name, ext: "en.srt").deletingPathExtension().deletingPathExtension()
                    var files = await Pipeline.saveCaptions(url: url, useLogin: useLogin, browser: browser, workDir: work,
                                                            trimStart: trimStart, trimEnd: trimEnd, baseName: base)
                    if files.isEmpty {
                        // No English: take the captions in the video's own language instead.
                        files = await Pipeline.saveCaptions(url: url, useLogin: useLogin, browser: browser, workDir: work,
                                                            trimStart: trimStart, trimEnd: trimEnd, baseName: base,
                                                            languages: ".*-orig,all,-live_chat")
                    }
                    guard let first = files.first else { throw PipelineError(message: "This video has no captions to save.") }
                    item.outputURL = first
                    item.state = .done
                    item.progress = 1
                    item.detail = "Saved \(files.count == 1 ? "captions" : "\(files.count) caption files") to \(folder.lastPathComponent)"
                    addHistory(item, file: first)
                } else {
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

                    var savedNote = "Saved to \(folder.lastPathComponent)"
                    if captions {
                        item.detail = "Saving captions…"
                        let srt = await Pipeline.saveCaptions(url: url, useLogin: useLogin, browser: browser, workDir: work,
                                                              trimStart: trimStart, trimEnd: trimEnd,
                                                              baseName: destination.deletingPathExtension())
                        savedNote += srt.isEmpty ? " · no captions available" : " · with captions"
                    }

                    item.outputURL = destination
                    item.state = .done
                    item.progress = 1
                    item.detail = savedNote
                    addHistory(item, file: destination)
                }
            } catch {
                if handle.cancelled || error is CancellationError {
                    item.state = .cancelled
                    item.detail = item.isFile ? "Paused. Click Download to resume where it stopped." : "Cancelled"
                } else {
                    let err = error as? PipelineError
                    item.state = .failed
                    item.errorMessage = err?.message ?? error.localizedDescription
                    item.needsLogin = err?.needsLogin ?? false
                    item.detail = "Failed"
                }
            }
            item.runner = nil
            finishedOne()
        }
    }

    /// After any download ends: start the next one, move batches along, and tell the user when all is done.
    private func finishedOne() {
        pump()
        continueBatchesIfIdle()
        updateDockBadge()
        if activeCount == 0 && waitingCount == 0 && finishedCount > 0 && !(autoContinue && !pendingBatches.isEmpty) {
            _ = NSApp.requestUserAttention(.informationalRequest)
            notifyFinished()
        }
    }

    private var activity: NSObjectProtocol?

    private func notifyFinished() {
        guard settings.notifyWhenDone, !NSApp.isActive else { return }
        let done = finishedCount
        let failed = items.filter { $0.state == .failed }.count
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Downloads finished"
            content.body = "\(done) ready" + (failed > 0 ? ", \(failed) failed" : "") + ". Click to open CosmoGrav."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Called when the app comes to the front: offers links copied elsewhere since the last look.
    func checkClipboard() {
        guard settings.watchClipboard else { return }
        let board = NSPasteboard.general
        guard board.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = board.changeCount
        let known = Set(items.map(\.url))
        let links = LinkParser.links(in: board.string(forType: .string) ?? "").filter { !known.contains($0) }
        clipboardLinks = Array(links.prefix(50))
    }

    func acceptClipboardLinks() {
        add(urls: clipboardLinks.map { (url: $0, title: String?.none) })
        clipboardLinks = []
    }

    /// Links added with the Paste button shouldn't be offered again by the clipboard banner.
    func markClipboardSeen() {
        lastPasteboardChange = NSPasteboard.general.changeCount
        clipboardLinks = []
    }

    private func updateDockBadge() {
        let pending = activeCount + waitingCount
        NSApp.dockTile.badgeLabel = pending > 0 ? "\(pending)" : nil
        // Keep macOS from napping or slowing the app while downloads run with its window hidden.
        if pending > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                            reason: "Downloading videos")
        } else if pending == 0, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
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
