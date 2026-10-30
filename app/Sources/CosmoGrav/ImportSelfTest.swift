import Foundation

/// Headless check of the list importer used by the build machine: `CosmoGrav --selftest-import`.
/// No network: it only reads and divides text.
enum ImportSelfTest {
    /// 110 videos and 39 Shorts with made-up IDs, plus a header row, repeats and a bad line,
    /// shaped like a real list someone would paste.
    static let sampleList: String = {
        var lines = ["url"]
        for i in 1...110 {
            let id = "Vid" + String(format: "%08d", i)
            lines.append(i % 3 == 0 ? "https://youtu.be/\(id)?si=shared" : "https://www.youtube.com/watch?v=\(id)")
        }
        for i in 1...39 { lines.append("https://www.youtube.com/shorts/Sht" + String(format: "%08d", i)) }
        lines += ["https://www.youtube.com/watch?v=Vid00000001", "https://youtube.com/shorts/Sht00000002", "file:///Users/someone/notes.txt"]
        return lines.joined(separator: "\n")
    }()

    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }

        let messy = """
        url,title
        https://www.youtube.com/watch?v=T6LYbRcdjPU
        youtu.be/T6LYbRcdjPU?si=abc

        # a note
        https://www.youtube.com/shorts/TFKTyhR9F5o
        https://m.youtube.com/watch?v=TFKTyhR9F5o&t=30s
        "My title, part 2",https://vimeo.com/123456?utm_source=x
        file:///etc/passwd
        javascript:alert(1)
        https://user:pw@example.com/v
        https://www.youtube.com/playlist?list=PLabcdefghij12345
        $(rm -rf ~)
        --exec=evil https://www.tiktok.com/@a/video/123
        https://www.instagram.com/reel/ABC123/?igsh=xyz
        """
        let r = LinkImport.parse(messy)
        print("links: " + r.links.map { "\($0.kind.rawValue) \($0.url)" }.joined(separator: " | "))
        print("problems: " + r.problems.map { "\($0.line): \($0.reason)" }.joined(separator: " | "))
        check(r.links.count == 6, "6 usable links (got \(r.links.count))")
        check(r.duplicates == 2, "2 repeats removed (got \(r.duplicates))")
        check(r.problems.count == 5, "5 lines skipped (got \(r.problems.count))")
        check(r.links.first?.url == "https://www.youtube.com/watch?v=T6LYbRcdjPU", "watch link kept as is")
        check(r.links.contains { $0.kind == .short && $0.url == "https://www.youtube.com/shorts/TFKTyhR9F5o" }, "Short recognised")
        check(r.links.contains { $0.url == "https://vimeo.com/123456" }, "CSV cell read and tracking tag dropped")
        check(r.links.contains { $0.kind == .playlist }, "playlist recognised")
        check(r.links.contains { $0.kind == .short && $0.url.contains("tiktok.com") }, "TikTok counted with Shorts")
        check(r.links.contains { $0.url == "https://www.instagram.com/reel/ABC123/" }, "Instagram share tag dropped")
        check(r.links.allSatisfy { $0.url.hasPrefix("https://") || $0.url.hasPrefix("http://") }, "only web links")
        check(!r.links.contains { $0.url.contains("passwd") || $0.url.contains("user:") }, "file and login links refused")

        let sample = LinkImport.parse(sampleList)
        check(sample.count(.video) == 110 && sample.count(.short) == 39, "sample: 110 videos, 39 Shorts")
        check(sample.duplicates == 2 && sample.problems.count == 2, "sample: 2 repeats, 2 skipped lines")
        let batches = LinkImport.divide(sample.links, byKind: true, size: 25, folders: .perBatch, listName: "Joseph/../links")
        print("batches: " + batches.map { "\($0.title) (\($0.links.count)) -> \($0.folder.joined(separator: "/"))" }.joined(separator: " | "))
        check(batches.count == 7, "divided into 5 video + 2 Shorts batches (got \(batches.count))")
        check(batches.map(\.links.count) == [25, 25, 25, 25, 10, 25, 14], "batch sizes")
        check(batches.allSatisfy { $0.folder.allSatisfy { !$0.contains("/") && $0 != ".." && !$0.isEmpty } }, "folder names are safe")
        check(LinkImport.divide(sample.links, byKind: false, size: 0, folders: .none, listName: "x").count == 1, "no split gives one batch")

        let huge = String(repeating: "https://www.youtube.com/watch?v=Vid00000001\n", count: 40_000)
        let start = Date()
        let big = LinkImport.parse(huge)
        check(big.links.count == 1 && Date().timeIntervalSince(start) < 5, "1 MB paste read quickly (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
