import CryptoKit
import Foundation

/// Headless check of file links and the piece downloader: `CosmoGrav --selftest-files [PIECES_URL SHA256 [PLAIN_URL]]`.
/// The link checks need no network; the downloads use files served on the build machine itself.
enum FileSelfTest {
    static func run(_ args: [String]) -> Never {
        Task {
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print((ok ? "PASS " : "FAIL ") + what)
                if !ok { failures += 1 }
            }
            func direct(_ link: String) -> String? {
                if case .file(let url, _) = FileLinks.resolve(link) { return url.absoluteString }
                return nil
            }

            check(direct("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view?usp=sharing")
                  == "https://drive.usercontent.google.com/download?id=1AbCdEfGhIjKlMnOpQrStUvWxYz012345&export=download&confirm=t",
                  "Google Drive share link")
            check(direct("https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUvWxYz012345")?.contains("id=1AbCdEfGhIjKlMnOpQrStUvWxYz012345") == true,
                  "Google Drive open?id= link")
            if case .unsupported = FileLinks.resolve("https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOp") {} else { check(false, "Drive folder explained") }
            check(direct("https://www.dropbox.com/scl/fi/abc123/brief.pdf?rlkey=xyz&dl=0")
                  == "https://www.dropbox.com/scl/fi/abc123/brief.pdf?rlkey=xyz&dl=1", "Dropbox dl=0 becomes dl=1")
            check(direct("https://1drv.ms/u/s!AbCdEf")?.hasPrefix("https://api.onedrive.com/v1.0/shares/u!") == true, "OneDrive share link")
            if case .unsupported = FileLinks.resolve("https://mega.nz/file/abc#key") {} else { check(false, "MEGA explained") }
            check(direct("https://example.com/files/Footage%20Pack.zip?token=1") != nil, "zip link kept as a file")
            check(direct("https://example.com/brief.PDF") != nil, "pdf link kept as a file")
            check(FileLinks.resolve("https://example.com/clip.mp4") == nil, "mp4 link still goes to the converter")
            check(FileLinks.resolve("https://www.youtube.com/watch?v=T6LYbRcdjPU") == nil, "YouTube still goes to yt-dlp")
            check(FileLinks.resolve("https://example.com/page.html") == nil, "web page is not a file")
            check(FileLinks.resolve("file:///etc/passwd") == nil, "file:// refused")

            let named = FileDownloader.fileName(disposition: "attachment; filename*=UTF-8''Client%20Brief%20v2.pdf", url: URL(string: "https://x.com/d")!, type: "")
            check(named.0 == "Client Brief v2" && named.1 == "pdf", "name from Content-Disposition (\(named))")
            let sneaky = FileDownloader.fileName(disposition: "attachment; filename=\"../../.ssh/authorized_keys\"", url: URL(string: "https://x.com/d")!, type: "")
            check(!sneaky.0.contains("/") && sneaky.0 != "..", "server can't pick another folder (\(sneaky))")
            let typed = FileDownloader.fileName(disposition: nil, url: URL(string: "https://x.com/download")!, type: "image/png")
            check(typed.0 == "download" && typed.1 == "png", "extension from the content type (\(typed))")

            if args.count >= 2, let url = URL(string: args[0]) {
                let expected = args[1].lowercased()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmograv-pieces-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    let probe = try await FileDownloader.probe(url, service: nil)
                    print("PROBE size=\(probe.size ?? -1) ranges=\(probe.ranges) name=\(probe.name).\(probe.ext)")
                    check(probe.ranges && (probe.size ?? 0) > 0, "server sends pieces")

                    // Stop part way, then download again: it must carry on from the pieces already saved.
                    let first = RunningProcess()
                    let stopper = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            if FileDownloader.totalSize(folder.contentsIfAny.filter { $0.lastPathComponent.hasPrefix("piece-") }) > (probe.size ?? 0) / 4 {
                                first.cancel()
                                return
                            }
                        }
                    }
                    var stopped = false
                    do { _ = try await FileDownloader.download(probe, folder: folder, handle: first) { _, _ in } } catch { stopped = error is CancellationError }
                    stopper.cancel()
                    let kept = FileDownloader.totalSize(folder.contentsIfAny.filter { $0.lastPathComponent.hasPrefix("piece-") })
                    let pieceCount = folder.contentsIfAny.filter { $0.lastPathComponent.hasPrefix("piece-") }.count
                    print("STOPPED after \(kept) bytes in \(pieceCount) pieces")
                    check(stopped && kept > 0, "pause keeps what arrived")
                    check(pieceCount > 1, "downloads over several connections")

                    final class Box: @unchecked Sendable { var details: [String] = [] }
                    let box = Box()
                    let started = Date()
                    let file = try await FileDownloader.download(probe, folder: folder, handle: RunningProcess()) { _, detail in box.details.append(detail) }
                    let data = try Data(contentsOf: file)
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    print("RESUMED in \(String(format: "%.1f", Date().timeIntervalSince(started)))s | \(box.details.last ?? "")")
                    check(hash == expected, "resumed file is byte for byte right")
                    check(box.details.contains { $0.hasPrefix("Resumed") }, "says it resumed")
                } catch {
                    check(false, "piece download: \(error.localizedDescription)")
                }
            }

            if args.count >= 3, let url = URL(string: args[2]) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmograv-plain-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    let probe = try await FileDownloader.probe(url, service: nil)
                    let file = try await FileDownloader.download(probe, folder: folder, handle: RunningProcess()) { _, _ in }
                    let data = try Data(contentsOf: file)
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    check(!probe.ranges && hash == args[1].lowercased(), "server without pieces: one connection, right file")
                } catch {
                    check(false, "plain download: \(error.localizedDescription)")
                }
            }

            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
