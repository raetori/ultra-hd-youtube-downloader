import Combine
import SwiftUI
import WebKit

/// A small browser inside CosmoGrav for file-host download pages (mediafile.cc and the like).
/// You use the site the normal way: its free download button, its timer, any "I'm not a robot" check.
/// The moment the site hands over the file, CosmoGrav takes the download into its queue, as the browser would
/// (one connection, the site's own speed). Nothing on the page is clicked, skipped or solved for you.
/// Cookies live only in memory and are gone when the window's download is done or the app quits.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let item: DownloadItem
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var loading = false
    @Published var address = ""
    @Published var blockedPopups = 0

    private weak var queue: QueueManager?
    private var observers: Set<AnyCancellable> = []
    private var download: WKDownload?
    private var destination: URL?
    private var meter: Timer?
    private var lastBytes: Int64 = 0
    private var speed: Double = 0

    init(item: DownloadItem, queue: QueueManager) {
        self.item = item
        self.queue = queue
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Keep the page's timer running while it works out of sight.
        if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main).sink { [weak self] in self?.canGoBack = $0 }.store(in: &observers)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main).sink { [weak self] in self?.loading = $0 }.store(in: &observers)
        webView.publisher(for: \.url).receive(on: RunLoop.main).sink { [weak self] in self?.address = $0?.absoluteString ?? "" }.store(in: &observers)
        if let url = URL(string: item.url) { webView.load(URLRequest(url: url)) }
    }

    var isDownloading: Bool { download != nil }

    // MARK: Working on its own

    private var scanTimer: Timer?
    private var scanStarted = Date()
    private var clicks = 0
    private var captchaSeen = 0
    private var askedForHelp = false
    static let maxClicks = 12
    static let giveUpAfter: TimeInterval = 240

    /// Looks at the page every 1.5 seconds: clicks the free download button once it is ready, reports a running
    /// timer, and asks for help when a robot check appears. Never touches the robot check itself.
    func startAutomatic() {
        scanStarted = Date()
        clicks = 0
        captchaSeen = 0
        askedForHelp = false
        scanTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func scan() {
        guard download == nil else { scanTimer?.invalidate(); return }
        if Date().timeIntervalSince(scanStarted) > Self.giveUpAfter {
            scanTimer?.invalidate()
            queue?.pageGaveUp(self)
            return
        }
        let script = clicks < Self.maxClicks ? Self.finder : Self.finder.replacingOccurrences(of: "var allowClick = true", with: "var allowClick = false")
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let text = result as? String ?? ""
            Task { @MainActor in self?.handleScan(text) }
        }
    }

    private func handleScan(_ text: String) {
        guard download == nil else { return }
        if text == "captcha" {
            captchaSeen += 1
            scanStarted = Date()  // The user may need a while; don't give up meanwhile.
            if captchaSeen >= 3 && !askedForHelp {
                askedForHelp = true
                queue?.pageNeedsYou(self)
            }
            return
        }
        captchaSeen = 0
        if text.hasPrefix("clicked:") {
            clicks += 1
            queue?.pageStatus(self, "Clicked “\(text.dropFirst(8))” on the site, waiting for the file…")
        } else if text.hasPrefix("countdown:") {
            scanStarted = Date()
            queue?.pageStatus(self, "Waiting out the site's free download timer · \(text.dropFirst(10)) s")
        } else if !loading {
            queue?.pageStatus(self, "Looking for the site's free download button…")
        }
    }

    /// Finds the free download button. Skips premium, sign-up and other-site (ad) links, and buttons still counting down.
    static let finder = #"""
    (function () {
      var allowClick = true;
      var site = function (h) { return (h || '').toLowerCase().split('.').slice(-2).join('.'); };
      var here = site(location.hostname);
      var bad = /premium|fast|instant|register|sign ?up|log ?in|buy|vip|upgrade|torrent|install|extension|player|stream|watch|subscribe|account/i;
      var good = /(free|slow|regular|normal|standard|low.?speed)\s*download|create download link|generate (download )?link|continue to download|get (download )?link|^\s*download\b/i;
      var files = /\.(zip|rar|7z|tar|gz|bz2|xz|iso|dmg|pkg|exe|msi|apk|pdf|mp4|mov|mkv|avi|mp3|wav|flac|aac|m4a|jpg|jpeg|png|psd|ai|aep|prproj|mogrt)(\?|$)/i;
      var countdown = null;
      var els = document.querySelectorAll('a, button, input[type=submit], input[type=button], [role=button]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var text = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
        if (!text || text.length > 60) continue;
        var r = el.getBoundingClientRect();
        var s = getComputedStyle(el);
        if (r.width < 4 || r.height < 4 || s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity) < 0.2) continue;
        var m = text.match(/(\d{1,4})\s*(sec|secs|seconds|s)\b/i);
        if (m && /wait|sec/i.test(text)) { countdown = m[1]; continue; }
        if (bad.test(text) || !good.test(text)) continue;
        if (el.disabled || el.getAttribute('aria-disabled') === 'true' || s.pointerEvents === 'none' || /\bdisabled\b/i.test(el.className)) continue;
        var href = el.getAttribute('href') || '';
        if (el.tagName === 'A' && href && !/^(javascript:|#)/i.test(href)) {
          try {
            var target = new URL(href, location.href);
            if (site(target.hostname) !== here && !files.test(target.pathname)) continue;
          } catch (e) { continue; }
        }
        var sig = text + '|' + href;
        var at = parseInt(el.getAttribute('data-cosmograv-at') || '0', 10);
        if (el.getAttribute('data-cosmograv') === sig && Date.now() - at < 15000) continue;
        if (!allowClick) break;
        el.setAttribute('data-cosmograv', sig);
        el.setAttribute('data-cosmograv-at', String(Date.now()));
        el.click();
        return 'clicked:' + text;
      }
      var checks = document.querySelectorAll('iframe[src*="recaptcha/api2/bframe"], iframe[src*="recaptcha/api2/anchor"], iframe[src*="hcaptcha.com"], iframe[src*="challenges.cloudflare.com"], .h-captcha, .cf-turnstile, #challenge-form');
      for (var j = 0; j < checks.length; j++) {
        var c = checks[j];
        if (c.closest && c.closest('.grecaptcha-badge')) continue;
        var cr = c.getBoundingClientRect();
        if (cr.width > 20 && cr.height > 20) return 'captcha';
      }
      if (countdown) return 'countdown:' + countdown;
      var body = (document.body && document.body.innerText) || '';
      var bm = body.match(/(?:wait|please wait|ready in|available in)[^0-9]{0,30}(\d{1,4})\s*(?:sec|secs|seconds|s)\b/i);
      if (bm) return 'countdown:' + bm[1];
      return 'waiting';
    })();
    """#

    // MARK: Spotting the file

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        // Only web addresses; other schemes (app links, file://) never open from here.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        take(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        take(download)
    }

    /// Pop-ups: the site's own pages (and links that are plainly files) open in this window; ad pop-ups are blocked.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let pageHost = Self.siteDomain(webView.url?.host)
        if Self.siteDomain(url.host) == pageHost || FileLinks.resolve(url.absoluteString) != nil {
            webView.load(navigationAction.request)
        } else {
            blockedPopups += 1
        }
        return nil
    }

    /// "cdn2.mediafile.cc" and "mediafile.cc" count as the same site.
    private static func siteDomain(_ host: String?) -> String {
        let parts = (host ?? "").lowercased().split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    // MARK: Downloading

    private func take(_ download: WKDownload) {
        guard self.download == nil else { download.cancel(nil); return }
        scanTimer?.invalidate()
        download.delegate = self
        self.download = download
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let work = Tools.workRoot.appendingPathComponent(item.id.uuidString + "-page", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (name, ext) = FileDownloader.fileName(disposition: nil, url: URL(fileURLWithPath: "/" + suggestedFilename),
                                                  type: response.mimeType ?? "")
        let target = work.appendingPathComponent(name + "." + ext)
        destination = target
        lastBytes = 0
        speed = 0
        let handle = RunningProcess()
        handle.onCancel { [weak self] in Task { @MainActor in self?.download?.cancel(nil) } }
        queue?.pageDownloadStarted(self, name: name, ext: ext, size: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
                                   handle: handle)
        let meter = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.report() } }
        RunLoop.main.add(meter, forMode: .common)
        self.meter = meter
        return target
    }

    private func report() {
        guard let progress = download?.progress else { return }
        let done = progress.completedUnitCount
        let total = progress.totalUnitCount
        let current = Double(max(done - lastBytes, 0)) / 0.5
        speed = speed == 0 ? current : speed * 0.7 + current * 0.3
        lastBytes = done
        var detail = "Downloading from the site · " + ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        if total > 0 { detail += " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }
        if speed > 0 { detail += " · " + ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s" }
        if total > 0, speed > 0 { detail += " · " + TimeFormat.string(Double(total - done) / speed) + " left" }
        queue?.pageDownloadProgress(self, fraction: total > 0 ? Double(done) / Double(total) : 0, detail: detail)
    }

    func downloadDidFinish(_ download: WKDownload) {
        meter?.invalidate()
        self.download = nil
        guard let destination else { return }
        queue?.pageDownloadFinished(self, file: destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        meter?.invalidate()
        self.download = nil
        queue?.pageDownloadFailed(self, error: error)
    }

    /// Stops everything when the row is removed.
    func close() {
        meter?.invalidate()
        scanTimer?.invalidate()
        download?.cancel(nil)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

/// The window around the browser.
struct BrowserSheet: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(GhostButtonStyle()).disabled(!session.canGoBack).help("Back")
                Button { session.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle()).help("Reload")
                HStack(spacing: 6) {
                    Image(systemName: session.address.hasPrefix("https") ? "lock.fill" : "globe")
                        .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    Text(session.address).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(.white.opacity(0.05)))
                if session.loading { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left").foregroundStyle(Theme.gold)
                Text("CosmoGrav waits out the site's timer and clicks its free download button for you. Answer any “I'm not a robot” check here yourself, or click the button if CosmoGrav can't find it. When the file starts, it goes into the queue and this window closes.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if session.blockedPopups > 0 {
                    Chip(text: "\(session.blockedPopups) pop-up\(session.blockedPopups == 1 ? "" : "s") blocked", symbol: "nosign")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            WebViewHost(webView: session.webView)
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .background(Theme.ink)
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
