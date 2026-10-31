import Foundation

/// Headless check of .crawljob reading and Folder Watch, used by the build machine: `CosmoGrav --selftest-crawljob`.
/// No network: it only reads text and moves files in a temporary folder.
enum CrawljobSelfTest {
    /// Shaped like the files JDownloader users write by hand: two jobs, comments, escapes, a turned-off job.
    static let sampleText = """
    # Client reel references
    text=https://www.youtube.com/watch?v=T6LYbRcdjPU\\nhttps://youtu.be/TFKTyhR9F5o?si=shared
    packageName=Client reel
    autoStart=TRUE
    priority=HIGHEST
    chunks=4

    text: https://vimeo.com/123456
    packageName=Mood board
    filename=Opening shot.mp4
    downloadFolder=~/Movies/CosmoGrav/<jd:packagename>
    autoStart=UNSET
    downloadPassword=secret

    text=https://www.youtube.com/watch?v=Vid00000001
    enabled=FALSE

    text=https://www.instagram.com/reel/ABC123/?igsh=xyz \\
         https://www.tiktok.com/@a/video/123
    packageName=Socials
    autoStart=FALSE
    """

    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }
        func describe(_ r: CrawljobReport) -> String {
            r.jobs.map { "[\($0.packageName ?? "-")] \($0.links.joined(separator: " ")) auto=\(String(describing: $0.autoStart))" }
                .joined(separator: " | ")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let save = home.appendingPathComponent("Downloads", isDirectory: true)

        // Plain key=value form.
        let r = Crawljob.parse(sampleText)
        print("text form: " + describe(r))
        check(r.error == nil, "text form read")
        check(r.jobs.count == 3, "3 jobs (got \(r.jobs.count))")
        check(r.disabled == 1, "enabled=FALSE job skipped")
        check(r.jobs.first?.links == ["https://www.youtube.com/watch?v=T6LYbRcdjPU", "https://www.youtube.com/watch?v=TFKTyhR9F5o"],
              "\\n inside text splits links, share tag dropped")
        check(r.jobs.first?.autoStart == true, "autoStart=TRUE")
        check(r.jobs.count > 1 && r.jobs[1].links == ["https://vimeo.com/123456"], "text: with a colon read")
        check(r.jobs.count > 1 && r.jobs[1].autoStart == nil, "autoStart=UNSET means ask")
        check(r.jobs.count > 2 && r.jobs[2].links.count == 2 && r.jobs[2].autoStart == false, "line continuation and autoStart=FALSE")
        check(r.ignoredFields == ["priority", "chunks", "downloadpassword"], "unused fields listed by name (got \(r.ignoredFields.sorted()))")
        check(r.linkCount == 5, "5 links in all")

        if r.jobs.count > 1 {
            let place = Crawljob.destination(for: r.jobs[1], saveFolder: save)
            check(place.base.path == home.path + "/Movies/CosmoGrav/Mood board" && place.folder.isEmpty,
                  "downloadFolder with ~ and <jd:packagename> (got \(place.base.path))")
            check(Crawljob.fileName(r.jobs[1].filename) == "Opening shot", "filename kept without its extension")
            let plain = Crawljob.destination(for: r.jobs[0], saveFolder: save)
            check(plain.base == save && plain.folder == ["Client reel"], "no downloadFolder: save folder / package name")
        }

        // JSON form, an array and a single object, with real booleans.
        let json = """
        [{"text": "https://www.youtube.com/shorts/TFKTyhR9F5o", "packageName": "Shorts", "autoStart": true, "enabled": "TRUE",
          "downloadFolder": "/etc"},
         {"text": "file:///etc/passwd\\njavascript:alert(1)\\nhttps://user:pw@example.com/v", "packageName": "Bad"},
         {"text": "https://example.com/a.mp4", "packageName": "../../Library", "enabled": false},
         {"text": "https://example.com/b.mp4", "packageName": "Up/../../there", "downloadFolder": "~/../../private/etc"}]
        """
        let j = Crawljob.parse(json)
        print("json form: " + describe(j))
        check(j.error == nil && j.jobs.count == 2, "JSON array read (got \(j.jobs.count) jobs)")
        check(j.empty == 1 && j.disabled == 1, "file, script and login links refused; enabled:false skipped")
        check(j.jobs.first?.autoStart == true, "JSON true read as TRUE")
        if j.jobs.count == 2 {
            let outside = Crawljob.destination(for: j.jobs[0], saveFolder: save)
            check(outside.base == save && outside.folder == ["Shorts"], "downloadFolder outside your home folder refused")
            let sneaky = Crawljob.destination(for: j.jobs[1], saveFolder: save)
            check(sneaky.base == save && sneaky.folder.allSatisfy { !$0.contains("/") && $0 != ".." },
                  "../ tricks stay inside the save folder (got \(sneaky.base.path) \(sneaky.folder))")
        }
        check(!Crawljob.isAllowed(home.appendingPathComponent("Library/LaunchAgents")), "~/Library refused")
        check(Crawljob.isAllowed(URL(fileURLWithPath: "/Volumes/8TB Drive/Footage")), "external drive allowed")
        let single = Crawljob.parse(#"{"links": ["https://vimeo.com/1", "https://vimeo.com/2"], "packageName": "One"}"#)
        check(single.jobs.first?.links.count == 2, "single JSON object with a links list")
        check(Crawljob.parse("{ not json").error != nil, "broken JSON reported")
        check(Crawljob.parse("hello").error != nil, "file without jobs reported")

        // Folder Watch: a file is picked up once its size has settled, then moved into "added".
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmograv-watch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("New job.crawljob")
        try? sampleText.write(to: file, atomically: true, encoding: .utf8)
        try? "not a job".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        var sizes: [String: Int] = [:]
        let first = FolderWatch.readyFiles(in: folder, lastSizes: &sizes)
        let second = FolderWatch.readyFiles(in: folder, lastSizes: &sizes)
        check(first.isEmpty && second.map(\.lastPathComponent) == ["New job.crawljob"], "waits one round, then picks up only .crawljob")
        let moved = FolderWatch.archive(file, in: folder, failed: false)
        check(moved?.deletingLastPathComponent().lastPathComponent == "added" && !FileManager.default.fileExists(atPath: file.path),
              "read file moved into added")
        check(FolderWatch.readyFiles(in: folder, lastSizes: &sizes).isEmpty && FolderWatch.readyFiles(in: folder, lastSizes: &sizes).isEmpty,
              "nothing read twice")

        let huge = String(repeating: "text=https://www.youtube.com/watch?v=Vid00000001\n", count: 20_000)
        let start = Date()
        let big = Crawljob.parse(huge)
        check(big.jobs.count == Crawljob.maxJobs && Date().timeIntervalSince(start) < 5,
              "1 MB file read quickly, capped at \(Crawljob.maxJobs) jobs (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
