import Foundation

/// Locations of the command-line tools the installer sets up, and helpers for running them.
enum Tools {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TeamYTDownloader")
    static let bin = base.appendingPathComponent("bin")
    static let workRoot = base.appendingPathComponent("work")
    static let historyFile = base.appendingPathComponent("history.json")

    static var ytdlp: URL { bin.appendingPathComponent("yt-dlp") }
    static var ffmpeg: URL { bin.appendingPathComponent("ffmpeg") }
    static var ffprobe: URL { bin.appendingPathComponent("ffprobe") }
    static var deno: URL { bin.appendingPathComponent("deno") }

    static let repoRaw = "https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main"
    static let installCommand = "/bin/bash -c \"$(curl -fsSL \(repoRaw)/install.sh)\""
    static let website = URL(string: "https://www.creationofcosmos.com")!

    static var installed: Bool {
        [ytdlp, ffmpeg, ffprobe].allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Keeps yt-dlp current at most once a day; sites change often and old versions stop working.
    static func updateDownloaderIfStale() async {
        let stamp = base.appendingPathComponent("last-update")
        let attrs = try? FileManager.default.attributesOfItem(atPath: stamp.path)
        if let date = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(date) < 86_400 { return }
        guard installed else { return }
        if let result = try? await Runner.run(ytdlp, ["-U"]), result.status == 0 {
            FileManager.default.createFile(atPath: stamp.path, contents: nil)
        }
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// A handle that lets the UI stop a running process and everything it started (yt-dlp spawns ffmpeg).
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32 = 0
    private var _cancelled = false

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func attach(_ process: Process) {
        lock.lock()
        pid = process.processIdentifier
        let stop = _cancelled
        lock.unlock()
        if stop { ProcessKiller.killTree(process.processIdentifier) }
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let current = pid
        lock.unlock()
        if current > 0 { ProcessKiller.killTree(current) }
    }
}

enum ProcessKiller {
    static func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func killTree(_ pid: Int32) {
        for child in children(of: pid) { killTree(child) }
        kill(pid, SIGTERM)
    }
}

/// Collects a process's output and hands complete lines (split on \n or \r) to a callback as they arrive.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var pendingOut = Data()
    private var pendingErr = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        if isError {
            errData.append(data)
            if errData.count > 400_000 { errData = Data(errData.suffix(200_000)) }
        } else {
            outData.append(data)
            // Progress output can run long; JSON output (no line callback) must stay whole.
            if onLine != nil, outData.count > 400_000 { outData = Data(outData.suffix(200_000)) }
        }
        if onLine != nil {
            if isError { pendingErr.append(data); lines = Self.split(&pendingErr) }
            else { pendingOut.append(data); lines = Self.split(&pendingOut) }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    func flush() {
        lock.lock()
        let rest = [pendingOut, pendingErr].map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
        pendingOut = Data()
        pendingErr = Data()
        lock.unlock()
        if let onLine { rest.forEach(onLine) }
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }

    private static func split(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
            if !line.isEmpty { lines.append(line) }
            buffer = Data(buffer[buffer.index(after: index)...])
        }
        return lines
    }
}

enum Runner {
    static func run(_ executable: URL,
                    _ arguments: [String],
                    handle: RunningProcess? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Tools.bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let collector = OutputCollector(onLine: onLine)
            outPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: false) }
            errPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: true) }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
                collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)
                collector.flush()
                continuation.resume(returning: ProcessResult(status: proc.terminationStatus,
                                                             stdout: collector.stdout,
                                                             stderr: collector.stderr))
            }
            do {
                try process.run()
                handle?.attach(process)
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Limits how many tasks do something at once (used for fetching video info).
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
