import Foundation

struct PipelineError: LocalizedError {
    let message: String
    var needsLogin = false
    var errorDescription: String? { message }

    /// Turns yt-dlp/ffmpeg output into one readable sentence and spots "you need to be logged in" failures.
    static func from(_ output: String, fallback: String) -> PipelineError {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last ?? fallback
        line = line.replacingOccurrences(of: "ERROR: ", with: "")
        if let range = line.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) { line.removeSubrange(range) }
        if let range = line.range(of: " (caused by") { line = String(line[..<range.lowerBound]) }
        let lower = output.lowercased()
        let loginHints = ["login", "log in", "sign in", "cookies", "private", "rate-limit", "rate limit", "authentication", "not available to you"]
        return PipelineError(message: String(line.prefix(300)), needsLogin: loginHints.contains { lower.contains($0) })
    }
}

struct MediaInfo {
    var title: String
    var thumbnail: URL?
    var duration: Double?
    var site: String
    var height: Int?
    var parts: Int
    var entries: [(url: String, title: String?)]?
}

enum Pipeline {
    static func commonArgs(useLogin: Bool, browser: String) -> [String] {
        var args = ["--ffmpeg-location", Tools.bin.path, "--no-playlist"]
        if FileManager.default.isExecutableFile(atPath: Tools.deno.path) {
            args += ["--js-runtimes", "deno:" + Tools.deno.path]
        }
        if useLogin && browser != "none" { args += ["--cookies-from-browser", browser] }
        return args
    }

    // MARK: Info

    static func fetchInfo(url: String, quality: Quality, useLogin: Bool, browser: String) async throws -> MediaInfo {
        // Playlists are listed flat so a long playlist is queued in seconds instead of minutes.
        let args = commonArgs(useLogin: useLogin, browser: browser)
            + ["-J", "--flat-playlist", "-f", quality.formatSelector, "--", url]
        let result = try await Runner.run(Tools.ytdlp, args)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError.from(result.stderr, fallback: "Couldn't read this link.")
        }

        let site = (json["extractor_key"] as? String) ?? (json["extractor"] as? String) ?? ""
        let title = (json["title"] as? String) ?? url

        if (json["_type"] as? String) == "playlist" {
            let entries = (json["entries"] as? [[String: Any]] ?? []).compactMap { entry -> (url: String, title: String?)? in
                guard let link = (entry["url"] as? String) ?? (entry["webpage_url"] as? String), link.hasPrefix("http") else { return nil }
                return (link, entry["title"] as? String)
            }
            return MediaInfo(title: title, thumbnail: nil, duration: nil, site: site, height: nil, parts: 1, entries: entries)
        }

        var thumb = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        if thumb == nil, let thumbs = json["thumbnails"] as? [[String: Any]] {
            thumb = (thumbs.last?["url"] as? String).flatMap(URL.init(string:))
        }
        let requested = json["requested_formats"] as? [[String: Any]]
        let height = (json["height"] as? Int) ?? requested?.compactMap { $0["height"] as? Int }.max()
        return MediaInfo(title: title,
                         thumbnail: thumb,
                         duration: (json["duration"] as? NSNumber)?.doubleValue,
                         site: site,
                         height: height,
                         parts: max(1, requested?.count ?? 1),
                         entries: nil)
    }

    static func resolutionLabel(height: Int?) -> String? {
        guard let h = height, h > 0 else { return nil }
        switch h {
        case 4000...: return "8K"
        case 2000..<4000: return "4K"
        case 1400..<2000: return "1440p"
        default: return "\(h)p"
        }
    }

    // MARK: Download

    private final class PartTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var part = 0
        func next() { lock.lock(); part += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return max(part, 1) }
    }

    /// Downloads into `workDir` and returns the downloaded file. Progress is 0...1 across all parts.
    static func download(url: String, quality: Quality, expectedParts: Int, useLogin: Bool, browser: String,
                         workDir: URL, handle: RunningProcess,
                         onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let pathFile = workDir.appendingPathComponent("path.txt")
        var args = commonArgs(useLogin: useLogin, browser: browser)
        args += ["-f", quality.formatSelector,
                 "-P", workDir.path, "-o", "media.%(ext)s",
                 "--newline", "--no-mtime", "--force-overwrites",
                 // Several connections at once for sites that serve video in pieces (Instagram, TikTok, HLS/DASH).
                 "--concurrent-fragments", "4",
                 "--progress-template", "download:COSMOS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
                 "--print-to-file", "after_move:filepath", pathFile.path]
        if !quality.isAudio { args += ["--merge-output-format", "mkv"] }
        args += ["--", url]

        let tracker = PartTracker()
        let parts = max(1, expectedParts)
        let result = try await Runner.run(Tools.ytdlp, args, handle: handle) { line in
            if line.hasPrefix("[download] Destination") {
                tracker.next()
            } else if line.hasPrefix("COSMOS ") {
                let f = line.split(separator: " ").map(String.init)
                guard f.count >= 6 else { return }
                let done = Double(f[1]) ?? 0
                let total = Double(f[2]) ?? Double(f[3]) ?? 0
                let fraction = total > 0 ? min(done / total, 1) : 0
                let part = min(tracker.current, parts)
                // With separate video and audio streams, the video is the bulk of the download.
                let overall: Double
                if parts > 1 { overall = part == 1 ? fraction * 0.85 : 0.85 + fraction * 0.15 }
                else { overall = fraction }
                var detail = parts > 1 ? (part == 1 ? "Downloading video" : "Downloading audio") : "Downloading"
                if let speed = Double(f[4]), speed > 0 { detail += " · " + ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s" }
                if let eta = Double(f[5]), eta > 0 { detail += " · " + TimeFormat.string(eta) + " left" }
                onProgress(overall, detail)
            } else if line.hasPrefix("[Merger]") {
                onProgress(1, "Combining video and audio…")
            }
        }
        if handle.cancelled { throw CancellationError() }
        guard result.status == 0 else { throw PipelineError.from(result.stderr, fallback: "The download failed.") }
        let saved = (try? String(contentsOf: pathFile, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).last.map(String.init)
        guard let saved, FileManager.default.fileExists(atPath: saved) else {
            throw PipelineError(message: "The download finished but the file is missing.")
        }
        return URL(fileURLWithPath: saved)
    }

    // MARK: Convert

    private struct Probe {
        var videoCodec: String?
        var pixelFormat: String?
        var height: Int?
        var fps: Double?
        var audioCodec: String?
        var duration: Double?
    }

    private static func probe(_ file: URL) async -> Probe {
        let args = ["-v", "error", "-show_entries",
                    "stream=codec_type,codec_name,pix_fmt,height,avg_frame_rate:format=duration",
                    "-of", "json", file.path]
        guard let result = try? await Runner.run(Tools.ffprobe, args),
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return Probe() }
        var probe = Probe()
        let streams = json["streams"] as? [[String: Any]] ?? []
        if let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            probe.videoCodec = v["codec_name"] as? String
            probe.pixelFormat = v["pix_fmt"] as? String
            probe.height = v["height"] as? Int
            if let rate = v["avg_frame_rate"] as? String {
                let p = rate.split(separator: "/").compactMap { Double($0) }
                if p.count == 2, p[1] > 0 { probe.fps = p[0] / p[1] }
            }
        }
        probe.audioCodec = streams.first(where: { ($0["codec_type"] as? String) == "audio" })?["codec_name"] as? String
        probe.duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        return probe
    }

    /// Produces the final file: an H.264 + AAC MP4 that Premiere imports, or MP3/WAV audio.
    /// Streams already in the right codec are copied untouched unless the clip is trimmed.
    static func finalize(input: URL, quality: Quality, trimStart: Double?, trimEnd: Double?,
                         output: URL, handle: RunningProcess,
                         onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let info = await probe(input)
        let start = max(trimStart ?? 0, 0)
        let trimmed = trimStart != nil || trimEnd != nil
        var length = info.duration ?? 0
        if let end = trimEnd { length = max(end - start, 0.1) } else if start > 0 { length = max(length - start, 0.1) }

        var inputArgs = ["-hide_banner", "-nostdin", "-y"]
        if start > 0 { inputArgs += ["-ss", String(format: "%.3f", start)] }
        inputArgs += ["-i", input.path]
        if trimEnd != nil { inputArgs += ["-t", String(format: "%.3f", length)] }

        var audio: [String]
        var video: [String]
        var container: [String]
        let label: String

        switch quality {
        case .mp3, .wav:
            video = ["-vn"]
            audio = quality == .mp3 ? ["-c:a", "libmp3lame", "-q:a", "0"] : ["-c:a", "pcm_s24le", "-ar", "48000"]
            container = []
            label = quality == .mp3 ? "Making MP3" : "Making WAV"
        case .best, .hd1080:
            let copyVideo = info.videoCodec == "h264" && info.pixelFormat == "yuv420p" && !trimmed
            if info.videoCodec == nil {
                video = ["-vn"]
            } else if copyVideo {
                video = ["-c:v", "copy"]
            } else {
                video = hardwareVideoArgs(height: info.height, fps: info.fps)
            }
            if info.audioCodec == nil { audio = ["-an"] }
            else if info.audioCodec == "aac" && !trimmed { audio = ["-c:a", "copy"] }
            else { audio = ["-c:a", "aac", "-b:a", "320k", "-ar", "48000"] }
            container = ["-tag:v", "avc1", "-movflags", "+faststart"]
            label = copyVideo ? "Finishing up" : "Converting to H.264 for Premiere"
        }

        let mapping = ["-map", "0:v:0?", "-map", "0:a:0?", "-map_metadata", "0", "-dn", "-sn"]
        let tail = ["-progress", "pipe:1", "-nostats", "-loglevel", "error", output.path]

        let totalLength = length
        func attempt(_ videoArgs: [String]) async throws -> ProcessResult {
            try await Runner.run(Tools.ffmpeg, inputArgs + mapping + videoArgs + audio + container + tail, handle: handle) { line in
                guard line.hasPrefix("out_time_us="), totalLength > 0,
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                let fraction = min(max(us / 1_000_000 / totalLength, 0), 1)
                onProgress(fraction, "\(label)… \(Int(fraction * 100))%")
            }
        }

        onProgress(0, "\(label)…")
        var result = try await attempt(video)
        if handle.cancelled { throw CancellationError() }
        if result.status != 0, video.contains("h264_videotoolbox") {
            // No hardware encoder available (older Mac or unusual source): use the software encoder.
            video = ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-profile:v", "high", "-pix_fmt", "yuv420p"]
            onProgress(0, "\(label)…")
            result = try await attempt(video)
            if handle.cancelled { throw CancellationError() }
        }
        guard result.status == 0 else {
            throw PipelineError.from(result.stderr, fallback: "Couldn't convert the file.")
        }
        if !quality.isAudio, info.videoCodec != nil {
            let check = await probe(output)
            guard check.videoCodec == "h264" else {
                throw PipelineError(message: "Conversion produced \(check.videoCodec ?? "nothing") instead of H.264.")
            }
        }
    }

    /// Apple's hardware H.264 encoder with a bitrate scaled to resolution and frame rate.
    private static func hardwareVideoArgs(height: Int?, fps: Double?) -> [String] {
        let h = height ?? 1080
        var mbps: Int
        switch h {
        case ..<721: mbps = 8
        case 721...1080: mbps = 16
        case 1081...1440: mbps = 30
        case 1441...2160: mbps = 60
        default: mbps = 120
        }
        if (fps ?? 30) > 31 { mbps = mbps * 3 / 2 }
        return ["-c:v", "h264_videotoolbox", "-b:v", "\(mbps)M", "-maxrate", "\(mbps * 2)M", "-bufsize", "\(mbps * 2)M",
                "-profile:v", "high", "-pix_fmt", "yuv420p"]
    }
}
