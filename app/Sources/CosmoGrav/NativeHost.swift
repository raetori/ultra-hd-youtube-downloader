import AppKit
import Foundation

/// When Chrome starts CosmoGrav for its extension (native messaging), this runs instead of the app window.
/// It answers on stdin/stdout, hands links to the app through the private inbox and exits when Chrome closes the pipe.
enum NativeHost {
    /// Chrome passes the calling extension's origin as the first argument.
    static func isHostLaunch(_ args: [String]) -> Bool {
        args.count > 1 && args[1].hasPrefix("chrome-extension://")
    }

    static func run(_ args: [String]) -> Never {
        // Chrome only starts the helper for the origins listed in its manifest; check again anyway.
        guard args.count > 1, args[1] == BrowserBridge.extensionOrigin else { exit(1) }
        let input = FileHandle.standardInput
        while true {
            let header = input.readData(ofLength: 4)
            guard header.count == 4 else { exit(0) }
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 0, length <= BrowserBridge.maxRequestBytes else { exit(1) }
            let body = input.readData(ofLength: length)
            guard body.count == length else { exit(0) }
            send(handle(body))
        }
    }

    static func send(_ reply: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        if data.count > 1_000_000 { data = Data(#"{"ok":false,"error":"Reply too large"}"#.utf8) }
        var length = UInt32(data.count).littleEndian
        let out = FileHandle.standardOutput
        out.write(Data(bytes: &length, count: 4))
        out.write(data)
    }

    static func handle(_ body: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let type = json["type"] as? String else {
            return ["ok": false, "error": "CosmoGrav didn't understand the extension."]
        }
        switch type {
        case "hello":
            BrowserBridge.syncExtensionFolder()
            var reply = statusReply()
            reply["app"] = appVersion
            reply["bundledExtension"] = BrowserBridge.bundledVersion ?? NSNull()
            reply["extensionFolder"] = BrowserBridge.extensionFolder.path
            return reply
        case "status":
            return statusReply()
        case "add":
            guard let request = try? JSONDecoder().decode(BrowserBridge.Request.self, from: body),
                  let clean = BrowserBridge.sanitize(request) else {
                return ["ok": false, "error": "There's no web link CosmoGrav can use here."]
            }
            do {
                _ = try BrowserBridge.writeToInbox(clean)
            } catch {
                return ["ok": false, "error": "CosmoGrav couldn't save the link: \(error.localizedDescription)"]
            }
            let focus = (json["focus"] as? Bool) ?? false
            openApp(url: "\(BrowserBridge.scheme)://inbox", background: !focus)
            var reply = statusReply()
            reply["added"] = clean.items.count
            return reply
        case "open":
            if json["what"] as? String == "folder" {
                let folder = UserDefaults.standard.string(forKey: "saveFolder")
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
                runOpen([folder])
            } else {
                openApp(url: nil, background: false)
            }
            return ["ok": true]
        default:
            return ["ok": false, "error": "Unknown request"]
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func statusReply() -> [String: Any] {
        let (status, running) = BrowserBridge.readStatus()
        var reply: [String: Any] = ["ok": true, "running": running]
        if let status, let data = try? JSONEncoder().encode(status), let object = try? JSONSerialization.jsonObject(with: data) {
            reply["status"] = object
        }
        return reply
    }

    /// Opens (or wakes) this copy of CosmoGrav, in the background unless asked otherwise.
    static func openApp(url: String?, background: Bool) {
        if ProcessInfo.processInfo.environment["COSMOGRAV_NO_OPEN"] == "1" { return }
        var args = background ? ["-g"] : []
        args += ["-a", Bundle.main.bundlePath]
        if let url { args.append(url) }
        runOpen(args)
    }

    static func runOpen(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
