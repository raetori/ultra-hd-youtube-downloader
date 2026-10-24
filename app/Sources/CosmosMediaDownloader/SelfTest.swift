import Foundation

/// Headless check used by the build machine: `CosmosMediaDownloader --selftest QUALITY:START-END:URL ...`
/// (START-END may be empty). Downloads and converts each link, then prints the codecs of the result.
enum SelfTest {
    static func run(_ specs: [String]) -> Never {
        Pipeline.debugLog = { print("DEBUG \($0)") }
        Task {
            var failures = 0
            for spec in specs {
                let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, let quality = Quality(rawValue: parts[0]) else { print("bad spec \(spec)"); failures += 1; continue }
                let range = parts[1].split(separator: "-").map { Double($0) }
                let url = parts[2]
                let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let handle = RunningProcess()
                let started = Date()
                do {
                    let info = try await Pipeline.fetchInfo(url: url, quality: quality, useLogin: false, browser: "none")
                    print("INFO \(info.site) | \(info.title) | \(Pipeline.resolutionLabel(height: info.height) ?? "?") | parts=\(info.parts)")
                    let out = work.appendingPathComponent("final." + quality.fileExtension)
                    final class Box: @unchecked Sendable { var detail = "" }
                    let last = Box()
                    if range.count == 2, try await Pipeline.downloadSection(url: url, quality: quality, trimStart: range[0], trimEnd: range[1],
                                                                            duration: info.duration, useLogin: false, browser: "none",
                                                                            output: out, handle: handle, onProgress: { _, d in last.detail = d }) {
                        let probe = try await Runner.run(Tools.ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,width,height,pix_fmt:format=duration", "-of", "compact", out.path])
                        print("OK (trimmed part only) \(quality.rawValue) in \(Int(Date().timeIntervalSince(started)))s | \(last.detail)\n\(probe.stdout)")
                        try? FileManager.default.removeItem(at: work)
                        continue
                    }
                    let file = try await Pipeline.download(url: url, quality: quality, expectedParts: info.parts, useLogin: false,
                                                           browser: "none", workDir: work, handle: handle) { _, _ in }
                    try await Pipeline.finalize(input: file, quality: quality,
                                                trimStart: range.count == 2 ? range[0] : nil, trimEnd: range.count == 2 ? range[1] : nil,
                                                output: out, handle: handle) { _, detail in last.detail = detail }
                    let probe = try await Runner.run(Tools.ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,width,height,pix_fmt:format=duration", "-of", "compact", out.path])
                    print("OK \(quality.rawValue) in \(Int(Date().timeIntervalSince(started)))s | \(last.detail)\n\(probe.stdout)")
                } catch {
                    print("FAIL \(spec): \(error.localizedDescription)")
                    failures += 1
                }
                try? FileManager.default.removeItem(at: work)
            }
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
