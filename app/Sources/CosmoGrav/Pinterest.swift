import Foundation

/// Pinterest links, made into ones yt-dlp can read.
///
/// yt-dlp only knows two kinds of Pinterest page: a pin (`/pin/<number>/`) and a board (`/<name>/<board>/`).
/// Every other page (the home feed, search results, a profile, "Today") looked like a board to it and failed
/// with "Unable to download JSON metadata: HTTP Error 404", so those get a plain explanation instead.
/// Country addresses like ph.pinterest.com and pin.it short links are turned into the www.pinterest.com pin.
enum Pinterest {
    enum Link: Equatable {
        /// One pin, as https://www.pinterest.com/pin/<id>/
        case pin(String)
        /// A board, as https://www.pinterest.com/<name>/<board>/
        case board(String)
        /// A pin.it short link: opened once to find the pin it points to.
        case short(URL)
        /// A Pinterest page that isn't a pin or a board.
        case notAPin(String)
    }

    static let notAPinMessage = "This is a Pinterest page, not a single pin. Click the pin to open it (its link has /pin/ in it) and send that link, or hover over the video and use the CosmoGrav button."

    /// First parts of Pinterest addresses that are never a person's name, so never a board.
    private static let pages: Set<String> = [
        "search", "today", "ideas", "homefeed", "news_hub", "notifications", "settings", "business", "pin-builder",
        "idea-pin-builder", "explore", "videos", "categories", "topics", "login", "signup", "password", "about",
        "resource", "_", "board", "boards", "following", "followers", "messages", "inbox", "shopping", "edit",
    ]

    static func isPinterestHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "pin.it" { return true }
        // pinterest.com, www.pinterest.com, ph.pinterest.com, pinterest.co.uk, de.pinterest.de, …
        let labels = host.split(separator: ".").map(String.init)
        guard let index = labels.lastIndex(of: "pinterest") else { return false }
        return countryEndings.contains(labels[(index + 1)...].joined(separator: "."))
    }

    /// The endings Pinterest uses (the same list yt-dlp knows, plus a few more).
    private static let countryEndings: Set<String> = [
        "com", "fr", "de", "ch", "jp", "cl", "ca", "it", "co.uk", "nz", "ru", "com.au", "at", "pt", "co.kr", "es", "com.mx",
        "dk", "ph", "th", "com.uy", "co", "nl", "info", "kr", "ie", "vn", "com.vn", "ec", "mx", "in", "pe", "co.at", "hu",
        "co.in", "co.nz", "id", "com.ec", "com.py", "tw", "be", "uk", "com.bo", "com.pe", "se", "pl", "cz", "com.br",
    ]

    /// nil means it isn't a Pinterest link.
    static func classify(_ link: String) -> Link? {
        guard let parts = URLComponents(string: link), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), isPinterestHost(host) else { return nil }
        let segments = parts.path.split(separator: "/").map(String.init)

        if host == "pin.it" {
            guard let code = segments.first, code.range(of: "^[A-Za-z0-9]{3,32}$", options: .regularExpression) != nil,
                  let url = URL(string: "https://pin.it/\(code)") else { return .notAPin("This pin.it link is incomplete.") }
            return .short(url)
        }

        // /pin/<number>/ or /pin/<words>--<number>/, with anything after it (/sent/, /feedback/, …).
        if let index = segments.firstIndex(of: "pin"), index + 1 < segments.count {
            let id = segments[index + 1].components(separatedBy: "--").last ?? ""
            if id.count >= 5, id.count <= 30, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) {
                return .pin("https://www.pinterest.com/pin/\(id)/")
            }
            return .notAPin("This Pinterest link has no pin in it.")
        }

        // A board: /<name>/<board>/. Profile tabs start with _ (/name/_saved/), and section pages go deeper.
        if segments.count == 2 || (segments.count == 3 && !segments[2].hasPrefix("_")) {
            let name = segments[0], board = segments[1]
            let safe = "^[A-Za-z0-9_.%-]{1,100}$"
            if !pages.contains(name.lowercased()), !name.hasPrefix("_"), !board.hasPrefix("_"),
               name.range(of: safe, options: .regularExpression) != nil, board.range(of: safe, options: .regularExpression) != nil {
                return .board("https://www.pinterest.com/\(segments.prefix(2).joined(separator: "/"))/")
            }
        }
        return .notAPin(notAPinMessage)
    }

    /// The link to use in place of `link`, when it can be fixed without going online.
    static func cleaned(_ link: String) -> String {
        switch classify(link) {
        case .pin(let url), .board(let url): return url
        default: return link
        }
    }

    /// Opens a pin.it short link without downloading the page, and returns the pin it leads to.
    static func resolveShort(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: PinterestRedirectStop(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        let http = response as? HTTPURLResponse
        let candidates = [http?.value(forHTTPHeaderField: "Location"), http?.url?.absoluteString, response.url?.absoluteString]
        for candidate in candidates.compactMap({ $0 }) {
            if case .pin(let pin) = classify(candidate) { return pin }
        }
        throw PipelineError(message: "This pin.it link didn't lead to a pin. Open it in your browser, then send the pin's own link.")
    }

    /// Turns yt-dlp's Pinterest failures into what to do about them.
    static func explain(_ error: PipelineError, kind: Link) -> PipelineError {
        let lower = error.message.lowercased()
        if lower.contains("404") {
            switch kind {
            case .board:
                return PipelineError(message: "Pinterest couldn't find this board. It may be secret or renamed; open a pin from it and send that link, or use your browser login.", needsLogin: true)
            default:
                return PipelineError(message: "Pinterest couldn't find this pin. It may be private, deleted or only visible when logged in. Use your browser login if you can see it in your browser.", needsLogin: true)
            }
        }
        return error
    }

    /// Image pins have no video: yt-dlp still lists the pin's pictures, and the biggest one is the original.
    static func originalImage(pin: String, useLogin: Bool, browser: String) async throws -> (url: URL, title: String?) {
        let args = Pipeline.commonArgs(useLogin: useLogin, browser: browser) + ["-J", "--ignore-no-formats-error", "--", pin]
        let result = try await Runner.run(Tools.ytdlp, args)
        guard result.status == 0, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError.from(result.stderr, fallback: "Couldn't read this pin.")
        }
        let thumbs = (json["thumbnails"] as? [[String: Any]]) ?? []
        let best = thumbs.compactMap { t -> (URL, Int)? in
            guard let s = t["url"] as? String, let u = URL(string: s), u.scheme == "https" else { return nil }
            let width = (t["width"] as? Int) ?? 0
            return (u, s.contains("/originals/") ? Int.max : width)
        }.max { $0.1 < $1.1 }
        guard let best else { throw PipelineError(message: "This pin has no video or picture CosmoGrav can save.") }
        let title = (json["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return (best.0, title)
    }
}

/// Follows pin.it's hops inside Pinterest and stops at the first address that is a pin, so the page itself is never loaded.
private final class PinterestRedirectStop: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, let host = next.host, Pinterest.isPinterestHost(host) else { return completionHandler(nil) }
        if case .pin = Pinterest.classify(next.absoluteString) { return completionHandler(nil) }
        completionHandler(request)
    }
}
