import Foundation
import SwiftUI

enum Quality: String, CaseIterable, Identifiable, Codable {
    case best, hd1080, prores, mp3, wav, captions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best HD (up to 4K)"
        case .hd1080: return "HD 1080p (faster)"
        case .prores: return "ProRes 422 HQ (for heavy editing)"
        case .mp3: return "Audio only (MP3)"
        case .wav: return "Audio only (WAV)"
        case .captions: return "Captions only (SRT)"
        }
    }

    var shortLabel: String {
        switch self {
        case .best: return "Best HD"
        case .hd1080: return "1080p"
        case .prores: return "ProRes"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .captions: return "SRT"
        }
    }

    var symbol: String { self == .captions ? "captions.bubble" : isAudio ? "waveform" : (self == .prores ? "film.stack" : "film") }

    /// What the finished file contains, shown as a badge on each row.
    var outputBadge: String? {
        switch self {
        case .best, .hd1080: return "H.264 MP4"
        case .prores: return "ProRes MOV"
        case .mp3, .wav, .captions: return nil
        }
    }
    var isAudio: Bool { self == .mp3 || self == .wav }
    /// Video or audio, as opposed to captions only.
    var hasMedia: Bool { self != .captions }

    var fileExtension: String {
        switch self {
        case .best, .hd1080: return "mp4"
        case .prores: return "mov"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .captions: return "srt"
        }
    }

    /// yt-dlp format selection. SDR is preferred so HDR sources don't look washed out in Premiere;
    /// the 1080p option picks the site's own H.264 + AAC streams when they exist so no conversion is needed.
    var formatSelector: String {
        switch self {
        case .best, .prores:
            return "bv*[dynamic_range=SDR]+ba/bv*+ba/b"
        case .hd1080:
            return "bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<=1080][dynamic_range=SDR]+ba/bv*[height<=1080]+ba/b[height<=1080]/b"
        case .mp3, .wav, .captions:
            return "ba/b"
        }
    }
}

enum ItemState: Equatable {
    case fetching, ready, queued, downloading, converting, done, failed, cancelled

    var isActive: Bool { self == .downloading || self == .converting }
    var canEdit: Bool { self == .ready || self == .failed || self == .cancelled || self == .fetching }
    var canStart: Bool { self == .ready || self == .failed || self == .cancelled }
}

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: String

    @Published var title: String
    @Published var fileName: String
    @Published var site = ""
    @Published var thumbnail: URL?
    @Published var duration: Double?
    @Published var resolution: String?
    @Published var quality: Quality
    @Published var trimStart: Double?
    @Published var trimEnd: Double?

    @Published var state: ItemState = .fetching
    @Published var progress: Double = 0
    @Published var detail = "Getting info…"
    @Published var errorMessage: String?
    @Published var needsLogin = false
    /// The link is a file host's download page, opened with "Open download page".
    @Published var needsBrowser = false
    @Published var useLogin = false
    @Published var outputURL: URL?

    var infoLoaded = false
    var expectedParts = 1
    /// Subfolders inside the save folder, for imported lists divided into folders.
    var folder: [String] = []
    /// Saves here instead of the app's save folder (a .crawljob's downloadFolder).
    var baseFolder: URL?
    /// A name chosen before the info loaded (a .crawljob's filename) that the video's title shouldn't replace.
    var keepFileName = false
    /// Set for links to files kept as they are (zip, pdf, Drive…), which skip the video pipeline.
    @Published var fileProbe: FileProbe?
    var isFile: Bool { fileProbe != nil }
    /// Imported in auto mode: starts downloading as soon as its info has loaded.
    var autoStart = false
    var runner: RunningProcess?

    init(url: String, quality: Quality, title: String? = nil) {
        self.url = url
        self.quality = quality
        self.title = title ?? url
        self.fileName = title.map(FileNames.sanitize) ?? ""
    }

    var isTrimmed: Bool { trimStart != nil || trimEnd != nil }

    var trimLabel: String? {
        guard isTrimmed else { return nil }
        let start = TimeFormat.string(trimStart ?? 0)
        let end = trimEnd.map(TimeFormat.string) ?? (duration.map(TimeFormat.string) ?? "end")
        return "\(start) – \(end)"
    }
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let title: String
    let url: String
    let site: String
    let filePath: String
    let quality: Quality
    let date: Date
}

enum TimeFormat {
    static func string(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Accepts "83", "1:23", "1:02:03" and decimals like "1:23.5".
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}

enum FileNames {
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String(cleaned.prefix(180))
    }

    /// "Name.mp4", or "Name (2).mp4" when that already exists, so nothing gets overwritten.
    static func unique(in folder: URL, name: String, ext: String) -> URL {
        let base = sanitize(name).isEmpty ? "Download" : sanitize(name)
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

enum LinkParser {
    static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return detector.matches(in: text, range: range).compactMap { $0.url?.absoluteString }
            .filter { $0.lowercased().hasPrefix("http") && seen.insert($0).inserted }
    }
}
