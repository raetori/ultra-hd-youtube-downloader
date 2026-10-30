import Foundation

/// What a link points at, so a long list can be divided into videos, Shorts and playlists.
enum LinkKind: String, CaseIterable, Identifiable {
    case video, short, playlist

    var id: String { rawValue }

    var plural: String {
        switch self {
        case .video: return "Videos"
        case .short: return "Shorts"
        case .playlist: return "Playlists"
        }
    }

    func count(_ n: Int) -> String {
        switch self {
        case .video: return n == 1 ? "1 video" : "\(n) videos"
        case .short: return n == 1 ? "1 Short" : "\(n) Shorts"
        case .playlist: return n == 1 ? "1 playlist" : "\(n) playlists"
        }
    }
}

struct ImportedLink: Hashable {
    let url: String
    let kind: LinkKind
    /// Same video, however it was written (youtu.be, /shorts/, ?si=…), gives the same key.
    let key: String
    let line: Int
}

struct ImportProblem: Hashable {
    let line: Int
    let text: String
    let reason: String
}

struct ImportReport {
    var links: [ImportedLink] = []
    var duplicates = 0
    var problems: [ImportProblem] = []
    var hitLimit = false

    func count(_ kind: LinkKind) -> Int { links.filter { $0.kind == kind }.count }
}

struct LinkBatch: Identifiable {
    let id = UUID()
    let title: String
    let links: [ImportedLink]
    let folder: [String]
}

enum FolderMode: String, CaseIterable, Identifiable {
    case none, perType, perBatch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "All in the save folder"
        case .perType: return "A folder for each type"
        case .perBatch: return "A folder for each batch"
        }
    }
}

/// Reads long link lists (pasted text, .txt or .csv) and divides them into batches.
/// It all happens on this Mac. Links are only ever handed to yt-dlp as data, never run as commands.
enum LinkImport {
    static let maxBytes = 1_000_000
    static let maxLinks = 5_000
    static let maxLinkLength = 2_048
    static let fileExtensions = ["txt", "csv", "tsv", "text", "list"]

    enum ReadError: LocalizedError {
        case tooBig, notText, unreadable

        var errorDescription: String? {
            switch self {
            case .tooBig: return "That file is over 1 MB. Split it into smaller files and import them one at a time."
            case .notText: return "That file isn't plain text. Save it as .txt or .csv and try again."
            case .unreadable: return "That file couldn't be opened."
            }
        }
    }

    static func read(file: URL) throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ReadError.tooBig }
        guard let data = try? Data(contentsOf: file) else { throw ReadError.unreadable }
        guard data.count <= maxBytes else { throw ReadError.tooBig }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        // Excel on Windows sometimes saves CSV as Windows-1252.
        if !data.contains(0), let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw ReadError.notText
    }

    /// Finds every link on every line. A CSV is read cell by cell, so a "Title,URL" sheet works too.
    static func parse(_ input: String) -> ImportReport {
        var report = ImportReport()
        let text = input.utf8.count > maxBytes ? String(decoding: input.utf8.prefix(maxBytes), as: UTF8.self) : input
        var seen = Set<String>()
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            let candidates = tokens(in: trimmed).filter(looksLikeLink)
            if candidates.isEmpty {
                report.problems.append(ImportProblem(line: lineNumber, text: preview(trimmed), reason: "No link on this line"))
                return
            }
            for token in candidates {
                switch normalize(token) {
                case .failure(let reason):
                    report.problems.append(ImportProblem(line: lineNumber, text: preview(token), reason: reason.message))
                case .success(let link):
                    guard seen.insert(link.key).inserted else { report.duplicates += 1; continue }
                    guard report.links.count < maxLinks else { report.hitLimit = true; stop = true; return }
                    report.links.append(ImportedLink(url: link.url, kind: link.kind, key: link.key, line: lineNumber))
                }
            }
        }
        return report
    }

    /// Splits by type first (if asked), then into batches of `size` (0 = no limit).
    static func divide(_ links: [ImportedLink], byKind: Bool, size: Int, folders: FolderMode, listName: String) -> [LinkBatch] {
        let groups: [(kind: LinkKind?, links: [ImportedLink])] = byKind
            ? LinkKind.allCases.map { kind -> (kind: LinkKind?, links: [ImportedLink]) in (kind, links.filter { $0.kind == kind }) }
                .filter { !$0.links.isEmpty }
            : [(nil, links)]
        let base = FileNames.sanitize(listName).isEmpty ? "Link list" : FileNames.sanitize(listName)
        var batches: [LinkBatch] = []
        for group in groups {
            let step = size > 0 ? size : max(group.links.count, 1)
            let chunks = stride(from: 0, to: group.links.count, by: step).map { Array(group.links[$0..<min($0 + step, group.links.count)]) }
            for (i, chunk) in chunks.enumerated() {
                let groupName = group.kind?.plural ?? "Batch"
                let numbered = chunks.count > 1 || group.kind == nil
                let title = numbered ? "\(groupName) · \(i + 1) of \(chunks.count)" : groupName
                let folder: [String]
                switch folders {
                case .none: folder = []
                case .perType: folder = group.kind.map { [base, $0.plural] } ?? [base]
                case .perBatch: folder = [base, numbered ? groupName + String(format: " %02d", i + 1) : groupName]
                }
                batches.append(LinkBatch(title: title, links: chunk, folder: folder))
            }
        }
        return batches
    }

    /// The same key `parse` gives a link, for matching against History.
    static func key(for url: String) -> String? {
        if case .success(let link) = normalize(url) { return link.key }
        return nil
    }

    // MARK: Details

    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;\t\"'<>()[]{}|"))

    private static func tokens(in line: String) -> [String] {
        line.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    private static func looksLikeLink(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("youtu.be/")
            || lower.hasPrefix("youtube.com/") || lower.hasPrefix("m.youtube.com/")
    }

    private static func preview(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return clean.count > 80 ? String(clean.prefix(77)) + "…" : clean
    }

    struct Rejection: Error { let message: String }
    private struct Normalized { let url: String; let kind: LinkKind; let key: String }

    /// Tracking tags that say who shared a link. Dropped so they never reach the site.
    private static let trackingParams: Set<String> = ["si", "feature", "pp", "fbclid", "gclid", "igsh", "igshid", "is_from_webapp", "sender_device", "ab_channel"]

    private static func normalize(_ token: String) -> Result<Normalized, Rejection> {
        var raw = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\"`"))
        guard raw.count <= maxLinkLength else { return .failure(Rejection(message: "Link is too long")) }
        if !raw.contains("://") { raw = "https://" + raw }
        guard raw.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }),
              var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased() else {
            return .failure(Rejection(message: "Not a valid link"))
        }
        guard scheme == "http" || scheme == "https" else { return .failure(Rejection(message: "Only web links (http or https) are allowed")) }
        guard parts.user == nil, parts.password == nil else { return .failure(Rejection(message: "Links with a login in them aren't allowed")) }
        guard let rawHost = parts.host?.lowercased(), rawHost.contains("."), !rawHost.hasPrefix("."), !rawHost.hasSuffix(".") else {
            return .failure(Rejection(message: "Not a valid link"))
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost

        if let youtube = youTube(host: host, parts: parts) { return youtube }

        parts.scheme = scheme
        parts.host = rawHost
        parts.fragment = nil
        let kept = (parts.queryItems ?? []).filter { !trackingParams.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
        parts.queryItems = kept.isEmpty ? nil : kept
        guard let url = parts.string else { return .failure(Rejection(message: "Not a valid link")) }
        let path = parts.path.lowercased()
        let kind: LinkKind = host.contains("tiktok.com") || path.contains("/reel") ? .short : .video
        var key = host + parts.path
        while key.hasSuffix("/") { key.removeLast() }
        if let query = parts.percentEncodedQuery { key += "?" + query }
        return .success(Normalized(url: url, kind: kind, key: key))
    }

    private static func youTube(host: String, parts: URLComponents) -> Result<Normalized, Rejection>? {
        let ytHosts = ["youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com"]
        let query = parts.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func video(_ id: String?, short: Bool = false) -> Result<Normalized, Rejection> {
            guard let id, isVideoID(id) else { return .failure(Rejection(message: "This YouTube link has no video in it")) }
            let url = short ? "https://www.youtube.com/shorts/\(id)" : "https://www.youtube.com/watch?v=\(id)"
            return .success(Normalized(url: url, kind: short ? .short : .video, key: "youtube:\(id)"))
        }
        let path = parts.path.split(separator: "/").map(String.init)

        if host == "youtu.be" { return video(path.first) }
        guard ytHosts.contains(host) else { return nil }
        let first = path.first?.lowercased() ?? ""
        switch first {
        case "watch": return video(value("v"))
        case "shorts": return video(path.count > 1 ? path[1] : nil, short: true)
        case "live", "embed", "v": return video(path.count > 1 ? path[1] : nil)
        case "playlist":
            guard let list = value("list"), list.range(of: "^[A-Za-z0-9_-]{10,64}$", options: .regularExpression) != nil else {
                return .failure(Rejection(message: "This YouTube playlist link is incomplete"))
            }
            return .success(Normalized(url: "https://www.youtube.com/playlist?list=\(list)", kind: .playlist, key: "youtube-list:\(list)"))
        case _ where first.hasPrefix("@") || first == "channel" || first == "c" || first == "user":
            // A whole channel: CosmoGrav lists its videos when it's added.
            let channelPath = "/" + path.prefix(first.hasPrefix("@") ? 1 : 2).joined(separator: "/")
            return .success(Normalized(url: "https://www.youtube.com" + channelPath, kind: .playlist, key: "youtube" + channelPath.lowercased()))
        default:
            return .failure(Rejection(message: "This YouTube link has no video in it"))
        }
    }

    private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }
}
