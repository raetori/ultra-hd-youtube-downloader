import Foundation

/// Headless check of the browser extension link, used by the build machine: `CosmoGrav --selftest-bridge`.
/// The helper Chrome starts (NativeHost) is tested separately by .github/scripts/native-host-test.py.
enum BridgeSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }

        check(BrowserBridge.isWebLink("https://www.youtube.com/watch?v=3OMLs3yI-KE"), "https link accepted")
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "cosmograv://add?url=x", "https://", "https://a.com/\nrm -rf",
                    "ftp://x.org/a.zip", "https://" + String(repeating: "a", count: 5000) + ".com"] {
            check(!BrowserBridge.isWebLink(bad), "refused \(bad.prefix(40))")
        }

        let messy = BrowserBridge.Request(items: [
            .init(url: "https://www.youtube.com/watch?v=3OMLs3yI-KE", title: "  Dutch GP  "),
            .init(url: "https://www.youtube.com/watch?v=3OMLs3yI-KE", title: nil),
            .init(url: "file:///Users/me/secret.txt", title: nil),
        ], quality: "hd1080", start: true, from: 12.5, to: 40, mode: "queue", name: nil)
        let clean = BrowserBridge.sanitize(messy)
        check(clean?.items.count == 1 && clean?.items.first?.title == "Dutch GP", "duplicates and file links dropped, title tidied")
        check(clean?.quality == "hd1080" && clean?.from == 12.5 && clean?.to == 40, "quality and clip kept")
        check(BrowserBridge.sanitize(.init(items: [.init(url: "https://a.com/v", title: nil)], quality: "rm -rf", start: nil, from: -3, to: .infinity, mode: "x", name: nil))
              .map { $0.quality == nil && $0.from == nil && $0.to == nil && $0.mode == "queue" } == true, "bad quality, clip and mode ignored")
        check(BrowserBridge.sanitize(.init(items: [.init(url: "https://a.com/v", title: nil)], quality: nil, start: nil, from: 50, to: 20, mode: nil, name: nil))?.to == nil,
              "clip end before start ignored")
        let many = BrowserBridge.Request(items: (0..<1500).map { .init(url: "https://a.com/\($0)", title: nil) }, quality: nil, start: nil, from: 5, to: 9, mode: "import", name: nil)
        let capped = BrowserBridge.sanitize(many)
        check(capped?.items.count == BrowserBridge.maxLinks && capped?.from == nil && capped?.mode == "import", "1500 links capped at \(BrowserBridge.maxLinks), no clip on lists")
        check(BrowserBridge.sanitize(.init(items: [.init(url: "javascript:x", title: nil)], quality: nil, start: nil, from: nil, to: nil, mode: nil, name: nil)) == nil,
              "nothing usable gives nothing")

        let link = URL(string: "cosmograv://add?url=https%3A%2F%2Fvimeo.com%2F123456&quality=mp3&from=3&to=9")!
        let fromLink = BrowserBridge.request(fromAddLink: link)
        check(fromLink?.items.first?.url == "https://vimeo.com/123456" && fromLink?.quality == "mp3" && fromLink?.to == 9, "cosmograv://add read")
        check(fromLink?.start == false, "web links are never started on their own")
        check(BrowserBridge.request(fromAddLink: URL(string: "cosmograv://add?url=file%3A%2F%2F%2Fetc%2Fhosts")!) == nil, "cosmograv://add refuses file links")

        let manifest = try? JSONSerialization.jsonObject(with: BrowserBridge.manifestJSON(executable: "/Applications/CosmoGrav.app/Contents/MacOS/CosmoGrav")) as? [String: Any]
        check(manifest?["name"] as? String == BrowserBridge.hostName && (manifest?["allowed_origins"] as? [String]) == [BrowserBridge.extensionOrigin],
              "browser manifest allows only the CosmoGrav extension")

        // Inbox round trip, in the real (private) folder.
        _ = BrowserBridge.drainInbox()
        let written = try? BrowserBridge.writeToInbox(clean!)
        let perms = written.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int }
        check(perms == 0o600, "inbox file readable only by you")
        try? Data("not json".utf8).write(to: BrowserBridge.inbox.appendingPathComponent("0-bad.json"))
        let drained = BrowserBridge.drainInbox()
        check(drained == [clean!], "inbox read once, broken files skipped")
        check(BrowserBridge.drainInbox().isEmpty, "inbox empty afterwards")

        if let bundled = BrowserBridge.bundledVersion {
            check(bundled == NativeHost.appVersion, "bundled extension \(bundled) matches the app \(NativeHost.appVersion)")
            check(BrowserBridge.syncExtensionFolder() && BrowserBridge.manifestVersion(at: BrowserBridge.extensionFolder) == bundled,
                  "extension copied to \(BrowserBridge.extensionFolder.path)")
        } else {
            check(false, "extension bundled inside the app")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
