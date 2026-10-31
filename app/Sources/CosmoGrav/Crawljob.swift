import AppKit
import Foundation

/// One job from a JDownloader `.crawljob` file: a set of links, plus where and how to save them.
struct CrawlJob: Identifiable {
    let id = UUID()
    var links: [String] = []
    var packageName: String?
    var downloadFolder: String?
    var filename: String?
    /// TRUE or FALSE from the file; nil when it says UNSET or nothing.
    var autoStart: Bool?
    /// Lines in `text` that weren't usable web links.
    var skippedLinks = 0
    /// Ticked in the review window.
    var include = true

    var title: String {
        if let packageName, !packageName.isEmpty { return packageName }
        return links.count == 1 ? links[0] : "\(links.count) links"
    }
}

struct CrawljobReport {
    var jobs: [CrawlJob] = []
    /// Jobs marked enabled=FALSE, which JDownloader skips too.
    var disabled = 0
    /// Jobs without a single usable web link.
    var empty = 0
    /// Fields CosmoGrav reads but has no use for (priority, chunks, passwords…). Names only, never values.
    var ignoredFields: Set<String> = []
    var error: String?

    var linkCount: Int { jobs.reduce(0) { $0 + $1.links.count } }

    mutating func merge(_ other: CrawljobReport) {
        jobs += other.jobs
        disabled += other.disabled
        empty += other.empty
        ignoredFields.formUnion(other.ignoredFields)
        if error == nil { error = other.error }
    }
}

/// Reads JDownloader 2 `.crawljob` files, in both of their forms:
///
///     text=https://www.youtube.com/watch?v=…        [{"text": "https://…",
///     packageName=Client reel                          "packageName": "Client reel",
///     downloadFolder=~/Movies/<jd:packagename>         "autoStart": "TRUE"}]
///     autoStart=TRUE
///
/// A repeated field (a second `text=`) starts the next job. Everything happens on this Mac, links go
/// through the same checks as an imported list (web links only, no logins in links), and they are only
/// ever handed to yt-dlp as data.
enum Crawljob {
    static let fileExtension = "crawljob"
    static let maxJobs = 1_000

    private static let used: Set<String> = ["text", "links", "packagename", "downloadfolder", "filename", "enabled", "autostart"]
    /// JDownloader-only fields that don't change anything here, so they aren't worth mentioning.
    private static let quiet: Set<String> = ["type", "comment", "jobid", "autoconfirm", "forcedstart", "deepanalyseenabled",
                                             "addofflinelink", "overwritepackagizerenabled", "setbeforepackagizerenabled"]

    // MARK: Reading

    static func parse(_ input: String) -> CrawljobReport {
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: [[String: String]]
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            guard let objects = json(trimmed) else {
                return CrawljobReport(error: "This .crawljob file looks like JSON but couldn't be read. Check it for a missing comma or bracket.")
            }
            raw = objects
        } else {
            raw = properties(text)
        }

        var report = CrawljobReport()
        for fields in raw.prefix(maxJobs) {
            if let enabled = fields["enabled"], tristate(enabled) == false { report.disabled += 1; continue }
            let source = [fields["text"], fields["links"]].compactMap { $0 }.joined(separator: "\n")
            let found = LinkImport.parse(source)
            guard !found.links.isEmpty else { report.empty += 1; continue }
            var job = CrawlJob()
            job.links = found.links.map(\.url)
            job.skippedLinks = found.problems.count
            job.packageName = cleaned(fields["packagename"])
            job.downloadFolder = cleaned(fields["downloadfolder"])
            job.filename = cleaned(fields["filename"])
            job.autoStart = fields["autostart"].flatMap(tristate)
            for key in fields.keys where !used.contains(key) && !quiet.contains(key) { report.ignoredFields.insert(key) }
            report.jobs.append(job)
        }
        if raw.isEmpty { report.error = "No jobs found in this .crawljob file. Each job needs a text= line with its links." }
        return report
    }

    /// TRUE / FALSE (any case, also yes/no/1/0); nil for UNSET or anything else.
    static func tristate(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : String(clean.prefix(500))
    }

    private static func json(_ text: String) -> [[String: String]]? {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let objects: [[String: Any]]
        if let list = value as? [[String: Any]] { objects = list }
        else if let single = value as? [String: Any] { objects = [single] }
        else { return nil }
        return objects.map { object in
            var fields: [String: String] = [:]
            for (key, value) in object {
                let name = key.lowercased()
                if let string = value as? String {
                    fields[name] = string
                } else if let number = value as? NSNumber {
                    let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                    fields[name] = isBool ? (number.boolValue ? "TRUE" : "FALSE") : number.stringValue
                } else if let list = value as? [Any] {
                    fields[name] = list.compactMap { $0 as? String }.joined(separator: "\n")
                }
            }
            return fields
        }
    }

    /// The plain `key=value` form (Java properties: `#` comments, `\` escapes and line continuations).
    private static func properties(_ text: String) -> [[String: String]] {
        var jobs: [[String: String]] = []
        var current: [String: String] = [:]
        var carried = ""

        func handle(_ line: String) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!"), let field = split(line) else { return }
            if current[field.key] != nil {
                jobs.append(current)
                current = [:]
            }
            current[field.key] = unescape(field.value)
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = carried.isEmpty ? raw : carried + raw.trimmingCharacters(in: .whitespaces)
            if continues(line) {
                carried = String(line.dropLast())
                continue
            }
            carried = ""
            handle(line)
        }
        if !carried.isEmpty { handle(carried) }
        if !current.isEmpty { jobs.append(current) }
        return jobs
    }

    /// "text=…" or "text: …" -> ("text", "…"). Keys are letters, digits, "_" and "." only, so a link is never read as a key.
    private static func split(_ line: String) -> (key: String, value: String)? {
        var key = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isASCII, line[index].isLetter || line[index].isNumber || line[index] == "_" || line[index] == "." {
            key.append(line[index])
            index = line.index(after: index)
        }
        guard !key.isEmpty else { return nil }
        while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == "=" || line[index] == ":" else { return nil }
        let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        return (key: key.lowercased(), value: value)
    }

    /// A line ending in an odd number of backslashes carries on onto the next line.
    private static func continues(_ line: String) -> Bool {
        var count = 0
        for character in line.reversed() {
            guard character == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        var iterator = Array(value).makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else { out.append(c); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": break
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = iterator.next() { hex.append(h) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            default: out.append(next)
            }
        }
        return out
    }

    // MARK: Where files go

    /// The folder a job saves into: its `downloadFolder` when that is a safe place on this Mac,
    /// otherwise the app's save folder plus a folder named after the package.
    static func destination(for job: CrawlJob, saveFolder: URL) -> (base: URL, folder: [String]) {
        let package = job.packageName.map(FileNames.sanitize).flatMap { $0.isEmpty ? nil : $0 }
        if var path = job.downloadFolder {
            path = path.replacingOccurrences(of: "<jd:packagename>", with: package ?? "", options: .caseInsensitive)
            if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
            if path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if isAllowed(url) { return (url, []) }
            }
        }
        return (saveFolder, package.map { [$0] } ?? [])
    }

    /// Download folders from a file must be inside your home folder (but not ~/Library) or on an external drive.
    static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home + "/Library" || path.hasPrefix(home + "/Library/") || path.contains("/.") { return false }
        return path.hasPrefix(home + "/") || (path.hasPrefix("/Volumes/") && path.count > "/Volumes/".count)
    }

    /// A job's `filename`, without its extension (CosmoGrav picks .mp4, .mov…), safe to save under.
    static func fileName(_ name: String?) -> String? {
        guard let name else { return nil }
        let ext = (name as NSString).pathExtension
        let base = (1...5).contains(ext.count) && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            ? (name as NSString).deletingPathExtension : name
        let clean = FileNames.sanitize(base)
        return clean.isEmpty ? nil : clean
    }
}

/// A .crawljob waiting in the review window.
struct CrawljobDraft: Identifiable {
    let id = UUID()
    var name: String
    var report: CrawljobReport
}

// MARK: Folder Watch

/// The file side of Folder Watch, kept apart from the UI so the self-test can run it.
enum FolderWatch {
    /// .crawljob files whose size hasn't changed since the last look, so a file still being written waits a round.
    static func readyFiles(in folder: URL, lastSizes: inout [String: Int]) -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var ready: [URL] = []
        var sizes: [String: Int] = [:]
        for file in files where file.pathExtension.lowercased() == Crawljob.fileExtension {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? -1
            if lastSizes[file.path] == size { ready.append(file) } else { sizes[file.path] = size }
        }
        lastSizes = sizes
        return ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Moves a read file into "added" (or "failed" when it couldn't be used), like JDownloader, so it is read only once.
    @discardableResult
    static func archive(_ file: URL, in folder: URL, failed: Bool) -> URL? {
        let target = folder.appendingPathComponent(failed ? "failed" : "added", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = file.deletingPathExtension().lastPathComponent + " " + formatter.string(from: Date())
        let destination = FileNames.unique(in: target, name: name, ext: Crawljob.fileExtension)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

/// Checks the watch folder every few seconds while Folder Watch is on.
@MainActor
final class CrawljobWatcher {
    private weak var queue: QueueManager?
    private var timer: Timer?
    private var lastSizes: [String: Int] = [:]
    /// Files that couldn't be moved away (read-only folder), so they aren't added again and again.
    private var handled: Set<String> = []

    init(queue: QueueManager) { self.queue = queue }

    func configure(enabled: Bool, folder: URL) {
        timer?.invalidate()
        timer = nil
        lastSizes = [:]
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(folder) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scan(folder)
    }

    private func scan(_ folder: URL) {
        guard let queue else { return }
        let files = FolderWatch.readyFiles(in: folder, lastSizes: &lastSizes).filter { !handled.contains($0.path) }
        for file in files {
            let report: CrawljobReport
            do { report = Crawljob.parse(try LinkImport.read(file: file)) } catch { report = CrawljobReport(error: error.localizedDescription) }
            let added = report.error == nil
                ? queue.addCrawljobs(report.jobs, quality: queue.settings.defaultQuality, startByDefault: queue.settings.watchAutoStart)
                : 0
            if FolderWatch.archive(file, in: folder, failed: report.jobs.isEmpty) == nil { handled.insert(file.path) }
            let name = file.lastPathComponent
            if let error = report.error {
                queue.watchNotice = "Folder Watch couldn't use \(name): \(error)"
            } else if report.jobs.isEmpty {
                queue.watchNotice = "Folder Watch found no usable links in \(name)."
            } else {
                queue.watchNotice = "Folder Watch added \(added) link\(added == 1 ? "" : "s") from \(name)."
            }
        }
    }
}
