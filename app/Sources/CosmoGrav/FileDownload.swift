import Foundation

/// Links to files that are kept exactly as they are (zip, pdf, images, audio, project files…),
/// including public share links from Google Drive, Dropbox and OneDrive.
/// Videos on video sites, and direct video links, still go through yt-dlp and come out Premiere-ready.
enum FileLinks {
    /// Direct links with these endings are videos: they are converted to Premiere-ready MP4, not kept as is.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "ts", "m3u8", "mpd", "3gp", "f4v"]
    /// Endings that mean a web page, not a file.
    static let pageExtensions: Set<String> = ["html", "htm", "xhtml", "php", "asp", "aspx", "jsp", "cgi", "shtml", "cfm"]

    enum Resolution: Equatable {
        /// Download this address and keep the file as it is. `service` names the cloud service, if any.
        case file(URL, service: String?)
        /// A link CosmoGrav can't download, with the reason in plain words.
        case unsupported(String)
    }

    /// nil means it isn't a file link, so yt-dlp gets it as before.
    static func resolve(_ link: String) -> Resolution? {
        guard var parts = URLComponents(string: link), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), parts.user == nil else { return nil }
        let path = parts.path
        let segments = path.split(separator: "/").map(String.init)
        let query = parts.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // Google Drive: drive.google.com/file/d/ID/view, /open?id=ID, /uc?id=ID
        if host == "drive.google.com" || host == "drive.usercontent.google.com" || (host == "docs.google.com" && path.hasPrefix("/uc")) {
            if segments.contains("folders") || segments.first == "drive" {
                return .unsupported("Google Drive folders can't be downloaded from a link. Open the folder in your browser and click Download to get a zip, or add each file's own link.")
            }
            var id: String?
            if let index = segments.firstIndex(of: "d"), index + 1 < segments.count { id = segments[index + 1] }
            if id == nil { id = value("id") }
            guard let id, id.range(of: "^[A-Za-z0-9_-]{10,128}$", options: .regularExpression) != nil,
                  let direct = URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t") else {
                return .unsupported("This Google Drive link has no file in it.")
            }
            return .file(direct, service: "Google Drive")
        }

        // Dropbox: the same link with dl=1 gives the file itself (a zip for a shared folder).
        if host == "dropbox.com" || host == "www.dropbox.com" {
            guard let first = segments.first, ["s", "scl", "sh"].contains(first) else { return nil }
            parts.queryItems = query.filter { $0.name != "dl" && $0.name != "raw" } + [URLQueryItem(name: "dl", value: "1")]
            guard let direct = parts.url else { return nil }
            return .file(direct, service: "Dropbox")
        }
        if host == "dl.dropboxusercontent.com", let direct = parts.url { return .file(direct, service: "Dropbox") }

        // OneDrive (personal): Microsoft's public "shares" address turns a share link into its file.
        if host == "1drv.ms" || host == "onedrive.live.com" {
            let encoded = Data(link.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            guard let direct = URL(string: "https://api.onedrive.com/v1.0/shares/u!\(encoded)/root/content") else { return nil }
            return .file(direct, service: "OneDrive")
        }
        // OneDrive for work and SharePoint: download=1 asks for the file instead of the viewer.
        if host.hasSuffix(".sharepoint.com"), path.contains("/:") {
            parts.queryItems = query.filter { $0.name != "download" } + [URLQueryItem(name: "download", value: "1")]
            guard let direct = parts.url else { return nil }
            return .file(direct, service: "OneDrive")
        }

        if host == "mega.nz" || host == "mega.co.nz" || host == "mega.io" || host.hasSuffix(".mega.nz") {
            return .unsupported("MEGA encrypts its files so only its own website or app can open them. Download this one in your browser.")
        }

        // Any other link that ends in a file name, like …/brief.pdf or …/footage.zip.
        let ext = (path as NSString).pathExtension.lowercased()
        guard (1...8).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              !videoExtensions.contains(ext), !pageExtensions.contains(ext), let direct = URL(string: link) else { return nil }
        return .file(direct, service: nil)
    }
}

/// What the server says about a file before it is downloaded.
struct FileProbe: Sendable {
    /// The address requested each time (redirects are followed again, since their targets often expire).
    let source: URL
    let size: Int64?
    /// True when the server can send parts of the file, so it can download in pieces and resume.
    let ranges: Bool
    /// File name without its extension, and the extension (kept exactly).
    let name: String
    let ext: String
}

struct RangeIgnored: Error {}

/// The address answered with a web page instead of a file.
struct WebPageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads a file over several connections at once, keeps the pieces so a stopped download resumes where it
/// stopped, and retries a dropped connection on its own. Plain HTTPS requests, like a browser's download; nothing
/// is bypassed, so links that need a login, a captcha or a wait in the browser are reported instead.
enum FileDownloader {
    static let configuration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        config.httpAdditionalHeaders = ["User-Agent": "CosmoGrav/\(version) (Macintosh; download manager)"]
        config.httpMaximumConnectionsPerHost = 16
        return config
    }()
    private static let session = URLSession(configuration: configuration)

    /// Pieces are only used for files this big, and each piece is at least this big.
    static let minimumPiece: Int64 = 8 * 1024 * 1024
    static let maxPieces = 8
    static let attempts = 6

    // MARK: Looking first

    static func probe(_ url: URL, service: String?) async throws -> FileProbe {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw PipelineError(message: "The server didn't answer like a web server.") }
        guard (200..<300).contains(http.statusCode) else { throw PipelineError(message: message(for: http.statusCode, service: service)) }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("text/html") {
            if let service {
                throw PipelineError(message: "\(service) showed a web page instead of the file. The link may not be public (set it to “Anyone with the link”), or the file needs to be opened in your browser.")
            }
            throw WebPageError(message: "This link opens a web page, not a file or a video.")
        }
        var size: Int64?
        var ranges = false
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            size = total
            ranges = total > 0
        } else if http.expectedContentLength > 0 {
            size = http.expectedContentLength
        }
        let (name, ext) = fileName(disposition: http.value(forHTTPHeaderField: "Content-Disposition"), url: http.url ?? url, type: type)
        return FileProbe(source: url, size: size, ranges: ranges, name: name, ext: ext)
    }

    static func message(for status: Int, service: String? = nil) -> String {
        let place = service ?? "The server"
        switch status {
        case 401, 403: return "\(place) refused this download (it is private or needs a login in your browser)."
        case 404, 410: return "\(place) says this file doesn't exist anymore."
        case 429: return "\(place) is limiting downloads right now. Try again later."
        case 500...599: return "\(place) had a problem (error \(status)). Try again later."
        default: return "\(place) answered with error \(status)."
        }
    }

    /// The name from Content-Disposition, or the address, with an extension from the content type when there is none.
    static func fileName(disposition: String?, url: URL, type: String) -> (String, String) {
        var raw: String?
        if let disposition {
            let parts = disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if let star = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
                var value = String(star.dropFirst("filename*=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let quote = value.range(of: "''") { value = String(value[quote.upperBound...]) }
                raw = value.removingPercentEncoding ?? value
            } else if let plain = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
                raw = String(plain.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        if raw == nil || raw!.isEmpty {
            let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            raw = last == "/" || last.isEmpty ? "Download" : last
        }
        // Only the last part of a name with slashes, so a server can't point it at another folder.
        let leaf = raw!.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "Download"
        var ext = (leaf as NSString).pathExtension.lowercased()
        var base = (leaf as NSString).deletingPathExtension
        if ext.isEmpty || ext.count > 8 || !ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            base = leaf
            ext = extensionFor(type: type)
        }
        let clean = FileNames.sanitize(base)
        return (clean.isEmpty ? "Download" : clean, ext)
    }

    private static func extensionFor(type: String) -> String {
        let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let known: [String: String] = [
            "application/pdf": "pdf", "application/zip": "zip", "application/x-zip-compressed": "zip", "image/jpeg": "jpg",
            "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "image/tiff": "tif",
            "image/svg+xml": "svg", "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/aac": "aac",
            "audio/mp4": "m4a", "audio/flac": "flac", "audio/aiff": "aif", "video/mp4": "mp4", "video/quicktime": "mov",
            "text/plain": "txt", "text/csv": "csv", "application/json": "json", "application/x-7z-compressed": "7z",
            "application/vnd.rar": "rar", "application/x-rar-compressed": "rar", "application/gzip": "gz",
            "application/x-apple-diskimage": "dmg",
        ]
        return known[mime] ?? "bin"
    }

    // MARK: Downloading

    /// Where a link's pieces are kept between tries, so Download picks up where it stopped (even after a restart).
    static func piecesFolder(for link: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in link.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Tools.partialRoot.appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }

    /// Deletes pieces of downloads nobody came back to for two weeks.
    static func cleanStale() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Tools.partialRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 14 * 86_400 { try? fm.removeItem(at: folder) }
        }
    }

    private struct Piece { let index: Int; let start: Int64; let end: Int64; var length: Int64 { end - start + 1 } }

    /// Downloads the file into `folder` and returns the finished file. Progress is 0...1.
    static func download(_ probe: FileProbe, folder: URL, handle: RunningProcess,
                         onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Pieces from an earlier try only count if the file on the server is still the same size.
        let stamp = folder.appendingPathComponent("size.txt")
        let sizeText = probe.size.map(String.init) ?? "unknown"
        if (try? String(contentsOf: stamp, encoding: .utf8)) != sizeText || !probe.ranges {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: file) }
            try sizeText.write(to: stamp, atomically: true, encoding: .utf8)
        }

        do {
            if probe.ranges, let size = probe.size {
                return try await downloadInPieces(probe, size: size, folder: folder, handle: handle, onProgress: onProgress)
            }
        } catch is RangeIgnored {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: file) }
        }
        return try await downloadWhole(probe, folder: folder, handle: handle, onProgress: onProgress)
    }

    private static func downloadInPieces(_ probe: FileProbe, size: Int64, folder: URL, handle: RunningProcess,
                                         onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let wanted: Int64 = min(Int64(maxPieces), size / minimumPiece)
        let count = Int(max(1, wanted))
        let step: Int64 = size / Int64(count)
        var pieces: [Piece] = []
        for i in 0..<count {
            let start: Int64 = Int64(i) * step
            let end: Int64 = i == count - 1 ? size - 1 : start + step - 1
            pieces.append(Piece(index: i, start: start, end: end))
        }
        let files = pieces.map { folder.appendingPathComponent("piece-\($0.index)") }
        let label = count > 1 ? "Downloading in \(count) pieces" : "Downloading"
        let meter = Task { await meterProgress(files: files, total: size, label: label, resumed: totalSize(files) > 0, onProgress: onProgress) }
        defer { meter.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for piece in pieces {
                let file = files[piece.index]
                group.addTask {
                    try await fetchPiece(probe.source, piece: piece, file: file, handle: handle)
                }
            }
            try await group.waitForAll()
        }
        if handle.cancelled { throw CancellationError() }
        guard totalSize(files) == size else { throw PipelineError(message: "The download finished but the file is the wrong size. Click Try again.") }

        onProgress(1, "Putting the pieces together…")
        let output = folder.appendingPathComponent("complete")
        try? FileManager.default.removeItem(at: output)
        if files.count == 1 {
            try FileManager.default.moveItem(at: files[0], to: output)
        } else {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            for file in files {
                let reader = try FileHandle(forReadingFrom: file)
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                    try writer.write(contentsOf: chunk)
                }
            }
        }
        return output
    }

    /// One piece, retried with growing pauses when the connection drops; each retry continues from what arrived.
    private static func fetchPiece(_ url: URL, piece: Piece, file: URL, handle: RunningProcess) async throws {
        var failure: Error?
        for attempt in 0..<attempts {
            if handle.cancelled { throw CancellationError() }
            let have = fileSize(file)
            if have >= piece.length { return }
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(30, 1 << attempt)) * 1_000_000_000)
                if handle.cancelled { throw CancellationError() }
            }
            var request = URLRequest(url: url)
            request.setValue("bytes=\(piece.start + have)-\(piece.end)", forHTTPHeaderField: "Range")
            do {
                try await RangeFetch(file: file, partial: true).run(request, handle: handle)
                if fileSize(file) >= piece.length { return }
            } catch is RangeIgnored {
                throw RangeIgnored()
            } catch let error as PipelineError {
                throw error
            } catch {
                if handle.cancelled { throw CancellationError() }
                failure = error
            }
        }
        throw PipelineError(message: "The connection kept dropping (\(failure?.localizedDescription ?? "no data")). Click Try again to continue where it stopped.")
    }

    /// For servers that can't send parts: one connection from the start.
    private static func downloadWhole(_ probe: FileProbe, folder: URL, handle: RunningProcess,
                                      onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let output = folder.appendingPathComponent("complete")
        var failure: Error?
        for attempt in 0..<3 {
            if handle.cancelled { throw CancellationError() }
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000) }
            try? FileManager.default.removeItem(at: output)
            let meter = Task { await meterProgress(files: [output], total: probe.size ?? 0, label: "Downloading", resumed: false, onProgress: onProgress) }
            defer { meter.cancel() }
            do {
                try await RangeFetch(file: output, partial: false).run(URLRequest(url: probe.source), handle: handle)
                if let size = probe.size, fileSize(output) != size { failure = nil; continue }
                return output
            } catch let error as PipelineError {
                throw error
            } catch {
                if handle.cancelled { throw CancellationError() }
                failure = error
            }
        }
        throw PipelineError(message: "The download kept failing (\(failure?.localizedDescription ?? "incomplete file")). Click Try again.")
    }

    private static func meterProgress(files: [URL], total: Int64, label: String, resumed: Bool,
                                      onProgress: @escaping @Sendable (Double, String) -> Void) async {
        var last = totalSize(files)
        var lastTime = Date()
        var speed: Double = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let now = totalSize(files)
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed > 0 {
                let current = Double(max(now - last, 0)) / elapsed
                speed = speed == 0 ? current : speed * 0.7 + current * 0.3
            }
            last = now
            lastTime = Date()
            var detail = label
            if resumed { detail = "Resumed · " + detail }
            detail += " · " + ByteCountFormatter.string(fromByteCount: now, countStyle: .file)
            if total > 0 { detail += " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }
            if speed > 0 { detail += " · " + ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s" }
            if total > 0, speed > 0 { detail += " · " + TimeFormat.string(Double(total - now) / speed) + " left" }
            onProgress(total > 0 ? min(Double(now) / Double(total), 1) : 0, detail)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func totalSize(_ files: [URL]) -> Int64 { files.reduce(0) { $0 + fileSize($1) } }
}

/// One HTTP request whose body is appended to a file as it arrives.
private final class RangeFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let partial: Bool
    private var writer: FileHandle?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(file: URL, partial: Bool) {
        self.file = file
        self.partial = partial
    }

    func run(_ request: URLRequest, handle: RunningProcess) async throws {
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        self.writer = writer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: FileDownloader.configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            handle.onCancel { task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = partial ? status == 206 : (200..<300).contains(status)
        if !ok {
            failure = partial && status == 200 ? RangeIgnored() : PipelineError(message: FileDownloader.message(for: status))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try writer?.write(contentsOf: data) } catch {
            failure = PipelineError(message: "Couldn't save the download: \(error.localizedDescription)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? writer?.close()
        writer = nil
        session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}

extension URL {
    /// The files in this folder, or none when it doesn't exist.
    var contentsIfAny: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil)) ?? []
    }
}
