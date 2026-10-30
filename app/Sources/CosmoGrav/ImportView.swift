import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportDraft: Identifiable {
    let id = UUID()
    var text: String
    var name: String
}

/// Takes a long list of links (pasted, or from a .txt or .csv file), shows what's in it,
/// and divides it into videos, Shorts and batches before anything is added to the queue.
struct ImportView: View {
    @EnvironmentObject private var queue: QueueManager
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var listName: String
    @State private var report = ImportReport()
    @State private var splitByType = true
    @State private var batchSize = 25
    @State private var folders: FolderMode = .perType
    @State private var auto = true
    @State private var quality = UserDefaults.standard.string(forKey: "defaultQuality").flatMap(Quality.init(rawValue:)) ?? .best
    @State private var skipDownloaded = true
    @State private var showProblems = false
    @State private var message: String?

    private static let sizes = [0, 10, 25, 50, 100]

    init(draft: ImportDraft) {
        _text = State(initialValue: draft.text)
        _listName = State(initialValue: draft.name)
    }

    private var downloadedKeys: Set<String> {
        Set(queue.history.compactMap { LinkImport.key(for: $0.url) })
    }

    private var links: [ImportedLink] {
        guard skipDownloaded else { return report.links }
        let done = downloadedKeys
        return report.links.filter { !done.contains($0.key) }
    }

    private var batches: [LinkBatch] {
        LinkImport.divide(links, byKind: splitByType, size: batchSize, folders: folders, listName: listName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    source
                    if !report.links.isEmpty || !report.problems.isEmpty { summary }
                    if !links.isEmpty { divideOptions; batchList }
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 660, height: 640)
        .background(Theme.ink)
        .task(id: text) {
            // Waits for typing to pause so a very long paste is only read once.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let input = text
            let parsed = await Task.detached(priority: .userInitiated) { LinkImport.parse(input) }.value
            guard !Task.isCancelled else { return }
            withAnimation(Theme.ease) { report = parsed }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Import a link list")
                Text("Bring in a long list, then divide it.").font(.system(size: 20, weight: .medium)).tracking(-0.3)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .background(ZStack { Theme.space; Starfield() })
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { openFile() } label: { Label("Open .txt or .csv…", systemImage: "doc.text") }
                    .buttonStyle(GhostButtonStyle())
                Button { pasteClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(GhostButtonStyle())
                if !text.isEmpty {
                    Button("Clear") { text = ""; listName = "Pasted links"; message = nil }.buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Text("One link per line, or a spreadsheet saved as CSV.").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            TextEditor(text: $text)
                .font(.mono(11, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste your links here…").font(.mono(11, weight: .regular)).foregroundStyle(.white.opacity(0.35))
                            .padding(13).allowsHitTesting(false)
                    }
                }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.ember) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("What's in the list", tint: Theme.textDim)
            HStack(spacing: 6) {
                Chip(text: report.links.count == 1 ? "1 link" : "\(report.links.count) links", tint: Theme.gold)
                ForEach(LinkKind.allCases) { kind in
                    let n = report.count(kind)
                    if n > 0 { Chip(text: kind.count(n)) }
                }
                if report.duplicates > 0 { Chip(text: "\(report.duplicates) repeats removed", symbol: "minus.circle") }
            }
            let inHistory = report.links.filter { downloadedKeys.contains($0.key) }.count
            if inHistory > 0 {
                Toggle("Skip \(inHistory) you've already downloaded (from History)", isOn: $skipDownloaded)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            if report.hitLimit {
                Text("Only the first \(LinkImport.maxLinks) links were read. Import the rest as a second list.")
                    .font(.system(size: 11)).foregroundStyle(Theme.ember)
            }
            if !report.problems.isEmpty {
                Button {
                    withAnimation(Theme.ease) { showProblems.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.ember)
                        Text("\(report.problems.count) line\(report.problems.count == 1 ? "" : "s") skipped")
                        Image(systemName: showProblems ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                if showProblems {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(report.problems.prefix(100).enumerated()), id: \.offset) { _, problem in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Line \(problem.line)").font(.mono(10)).foregroundStyle(Theme.gold).frame(width: 64, alignment: .leading)
                                Text(problem.reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                                Text(problem.text).font(.mono(10, weight: .regular)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if report.problems.count > 100 {
                            Text("…and \(report.problems.count - 100) more").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var divideOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Divide it", tint: Theme.textDim)
            Toggle("Keep videos, Shorts and playlists apart", isOn: $splitByType).toggleStyle(.checkbox).font(.system(size: 12))
            HStack(spacing: 10) {
                Text("Batches of").font(.system(size: 12))
                Picker("", selection: $batchSize) {
                    ForEach(Self.sizes, id: \.self) { Text($0 == 0 ? "All" : "\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            HStack(spacing: 10) {
                Text("Save into").font(.system(size: 12))
                Picker("", selection: $folders) {
                    ForEach(FolderMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
                if folders != .none {
                    TextField("Folder name", text: $listName).textFieldStyle(.roundedBorder).frame(width: 150)
                        .help("The folder made inside your save folder")
                }
            }
            HStack(spacing: 10) {
                Text("Download as").font(.system(size: 12))
                Picker("", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
                if !quality.hasMedia {
                    Text("Only the .srt captions are saved, no video.").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }
            Toggle("Download on its own, one batch after another", isOn: $auto).toggleStyle(.checkbox).font(.system(size: 12))
                .help("Each batch starts once the one before it has finished. Turn off to add batches yourself.")
        }
    }

    private var batchList: some View {
        let all = batches
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(all.count == 1 ? "1 batch" : "\(all.count) batches", tint: Theme.textDim)
            ForEach(Array(all.enumerated()), id: \.element.id) { index, batch in
                HStack(spacing: 10) {
                    Text(String(format: "%02d", index + 1)).font(.mono(10)).foregroundStyle(Theme.gold)
                    Text(batch.title).font(.system(size: 12, weight: .medium))
                    Text(batch.links.count == 1 ? "1 link" : "\(batch.links.count) links").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    if !batch.folder.isEmpty {
                        Label(batch.folder.joined(separator: " / "), systemImage: "folder")
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Save batches as files…") { saveBatches() }
                .buttonStyle(GhostButtonStyle())
                .disabled(links.isEmpty)
                .help("Writes each batch to its own .txt file, to share or import later")
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
            Button {
                queue.importBatches(batches, auto: auto, quality: quality)
                dismiss()
            } label: {
                Text(addTitle)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(links.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.6))
    }

    private var addTitle: String {
        let count = batches.count
        if links.isEmpty { return "Add to queue  →" }
        if count <= 1 { return auto ? "Add and download  →" : "Add \(links.count) to queue  →" }
        return auto ? "Start batch 1 of \(count)  →" : "Add batch 1 of \(count)  →"
    }

    // MARK: Files

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LinkImport.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .txt or .csv file with one link per line"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(file: url)
    }

    private func load(file url: URL) {
        do {
            text = try LinkImport.read(file: url)
            listName = url.deletingPathExtension().lastPathComponent
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func pasteClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        guard !pasted.isEmpty else { message = "The clipboard is empty."; return }
        text = text.isEmpty ? pasted : text + "\n" + pasted
        queue.markClipboardSeen()
        message = nil
    }

    private func saveBatches() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save one .txt file per batch"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = FileNames.sanitize(listName).isEmpty ? "Link list" : FileNames.sanitize(listName)
        var saved = 0
        for (index, batch) in batches.enumerated() {
            let name = "\(base) \(String(format: "%02d", index + 1)) \(FileNames.sanitize(batch.title.replacingOccurrences(of: " · ", with: " ")))"
            let file = FileNames.unique(in: folder, name: name, ext: "txt")
            let body = batch.links.map(\.url).joined(separator: "\n") + "\n"
            if (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil { saved += 1 }
        }
        message = nil
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if saved < batches.count { message = "Only \(saved) of \(batches.count) files could be saved there." }
    }
}

/// Shown under the options bar while batches from an imported list are waiting.
struct PendingBatchesBanner: View {
    @EnvironmentObject private var queue: QueueManager

    var body: some View {
        if let next = queue.pendingBatches.first {
            let remaining = queue.pendingBatches.reduce(0) { $0 + $1.links.count }
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up next: \(next.title), \(next.links.count) link\(next.links.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                    Text("\(queue.pendingBatches.count) batch\(queue.pendingBatches.count == 1 ? "" : "es") waiting · \(remaining) links"
                         + (queue.autoContinue ? " · starts on its own" : ""))
                        .font(.mono(9.5)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Drop the rest") { queue.clearPendingBatches() }.buttonStyle(GhostButtonStyle())
                Toggle("Auto", isOn: Binding(get: { queue.autoContinue }, set: { queue.setAutoContinue($0) })).toggleStyle(.switch).controlSize(.mini)
                    .help("Start the next batch on its own when this one finishes")
                Button("Add now") { queue.addNextBatch() }.buttonStyle(PrimaryButtonStyle())
            }
            .modifier(BannerShape(tint: Theme.gold))
        }
    }
}
