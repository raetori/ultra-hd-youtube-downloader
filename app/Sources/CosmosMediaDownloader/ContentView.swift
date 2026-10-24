import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: Updater
    @State private var linkText = ""
    @State private var showHistory = false
    @State private var dropTargeted = false
    @State private var addMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            optionsBar
            Divider()
            banners
            if queue.items.isEmpty { emptyState } else { list }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .onAppear { updater.check() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CosmosMark()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cosmos Media Downloader")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("HD video that drops straight into Premiere Pro")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { showHistory = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.white.opacity(0.5))
                    ZStack(alignment: .leading) {
                        if linkText.isEmpty {
                            Text("Paste links from YouTube, TikTok, Instagram, Facebook… (several at once is fine)")
                                .foregroundStyle(.white.opacity(0.45))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $linkText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .onSubmit(addTyped)
                    }
                    .font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12)))

                Button(action: pasteFromClipboard) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Add every link on the clipboard (⇧⌘V)")
            }
            if let addMessage {
                Text(addMessage).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .background(Theme.space)
    }

    private var optionsBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("Quality").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $settings.defaultQuality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .help("Used for links you add from now on. Each video can also be changed on its own.")
            }

            HStack(spacing: 6) {
                Text("Save to").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { settings.chooseFolder() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        Text(settings.saveFolder.lastPathComponent).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .help(settings.saveFolder.path)
            }

            HStack(spacing: 6) {
                Text("At once").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $settings.maxConcurrent) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
                .help("How many videos download at the same time")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var banners: some View {
        if queue.toolsMissing {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: "Setup isn't finished on this Mac. Run the install line in Terminal once, then reopen the app.",
                   buttonTitle: "Copy install line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Tools.installCommand, forType: .string)
            }
        }
        if let version = updater.availableVersion {
            Banner(symbol: "sparkles", tint: Theme.accent,
                   text: "Version \(version) is available.",
                   buttonTitle: updater.updating ? "Updating…" : "Update now") {
                updater.installUpdate()
            }
        }
    }

    // MARK: Queue

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(queue.items) { item in
                    ItemRow(item: item)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "arrow.down.circle").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
            }
            Text("Add links to get started").font(.system(size: 17, weight: .semibold))
            Text("Copy one or more links, then click Paste. You can also drag links here.\nRename, trim and pick the quality for each video before downloading.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Link(destination: Tools.website) {
                HStack(spacing: 6) {
                    CosmosMark().fill(.secondary).frame(width: 13, height: 13)
                    Text("Made by Creation of Cosmos").font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)
            .help("creationofcosmos.com")

            Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()

            if queue.finishedCount > 0 {
                Button("Clear finished") { queue.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            if queue.activeCount + queue.waitingCount > 0 {
                Button("Stop all") { queue.cancelAll() }
            }
            Button {
                queue.startAll()
            } label: {
                Label(queue.readyCount > 1 ? "Download all (\(queue.readyCount))" : "Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(queue.items.allSatisfy { $0.state != .ready })
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var statusText: String {
        var parts: [String] = []
        if queue.activeCount > 0 { parts.append("\(queue.activeCount) downloading") }
        if queue.waitingCount > 0 { parts.append("\(queue.waitingCount) waiting") }
        if queue.finishedCount > 0 { parts.append("\(queue.finishedCount) done") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: ", ")
    }

    // MARK: Adding links

    private func addTyped() {
        let count = queue.add(text: linkText)
        addMessage = count == 0 ? "No links found in what you typed." : nil
        if count > 0 { linkText = "" }
    }

    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let count = queue.add(text: text)
        addMessage = count == 0 ? "The clipboard doesn't contain any links. Copy a link first." : "Added \(count) link\(count == 1 ? "" : "s")."
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in queue.add(text: url.absoluteString) } }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text { Task { @MainActor in queue.add(text: text) } }
                }
            }
        }
        return true
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12))
            Spacer()
            Button(buttonTitle, action: action)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1))
    }
}
