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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            optionsBar
            banners
            if queue.items.isEmpty { emptyState.transition(.opacity) } else { list.transition(.opacity) }
            footer
        }
        .animation(Theme.ease, value: queue.items.isEmpty)
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.ink)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [6, 6]))
                    .shadow(color: Theme.gold.opacity(0.5), radius: 12)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Theme.ease, value: dropTargeted)
        .sheet(isPresented: $showHistory) { HistoryView().preferredColorScheme(.dark) }
        .sheet(item: $queue.importDraft) { draft in
            ImportView(draft: draft).environmentObject(queue).preferredColorScheme(.dark)
        }
        .background {
            // Its own view, so it never competes with the Import window's sheet.
            Color.clear.sheet(item: $queue.crawljobDraft) { draft in
                CrawljobView(draft: draft).environmentObject(queue).environmentObject(settings).preferredColorScheme(.dark)
            }
        }
        .background {
            Color.clear.sheet(item: $queue.browserItem) { item in
                if let session = queue.browserSession(for: item) {
                    BrowserSheet(session: session).preferredColorScheme(.dark)
                }
            }
        }
        .onAppear {
            updater.startChecking()
            // Used by CI to photograph the About window.
            if CommandLine.arguments.contains("--about") { openWindow(id: "about") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queue.checkClipboard()
            updater.checkIfStale()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                CosmosMark()
                    .fill(.white)
                    .frame(width: 28, height: 28)
                    .shadow(color: Theme.gold.opacity(0.35), radius: 8)
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow("CosmoGrav · Media Downloader")
                    Wordmark(size: 18)
                }
                Spacer()
                Button { showHistory = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(GhostButtonStyle())
                AboutButton()
                OpenSettingsButton(label: "Settings", ghost: true)
            }

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Theme.gold.opacity(0.8))
                    ZStack(alignment: .leading) {
                        if linkText.isEmpty {
                            Text("Paste links from YouTube, TikTok, Instagram, Facebook… several at once is fine")
                                .foregroundStyle(.white.opacity(0.38))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $linkText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .onSubmit(addTyped)
                    }
                    .font(.system(size: 13))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.8))

                Button { queue.openImport() } label: {
                    Label("Import list", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Bring in a long list from a .txt or .csv file, or a big paste, and divide it into batches (⌘O)")

                Button(action: pasteFromClipboard) {
                    Text("Paste links  →")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Add every link on the clipboard (⇧⌘V)")
            }
            if let addMessage {
                Text(addMessage).font(.mono(10)).foregroundStyle(.white.opacity(0.55)).transition(.opacity)
            }
        }
        .animation(Theme.ease, value: addMessage)
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 22)
        .background(
            ZStack {
                Theme.space
                Starfield()
                HorizonGlow()
                // Fade into the window so there is no hard edge between header and list.
                LinearGradient(colors: [.clear, Theme.ink], startPoint: .center, endPoint: .bottom)
            }
        )
    }

    private var optionsBar: some View {
        HStack(spacing: 22) {
            HStack(spacing: 8) {
                Eyebrow("Quality", tint: Theme.textDim)
                Picker("", selection: $settings.defaultQuality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                .help("Used for links you add from now on. Each video can also be changed on its own.")
            }

            HStack(spacing: 8) {
                Eyebrow("Save to", tint: Theme.textDim)
                Button { settings.chooseFolder() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").foregroundStyle(Theme.gold)
                        Text(settings.saveFolder.lastPathComponent).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .help(settings.saveFolder.path)
            }

            HStack(spacing: 8) {
                Eyebrow("At once", tint: Theme.textDim)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if queue.toolsMissing {
                Banner(symbol: "exclamationmark.triangle", tint: Theme.ember,
                       text: "Setup isn't finished on this Mac. Run the install line in Terminal once, then reopen the app.",
                       buttonTitle: "Copy install line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Tools.installCommand, forType: .string)
                }
            }
            if !queue.clipboardLinks.isEmpty {
                let count = queue.clipboardLinks.count
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.gold)
                    Text(count == 1 ? "You copied a link: \(queue.clipboardLinks[0])" : "You copied \(count) links.")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Not now") { queue.clipboardLinks = [] }.buttonStyle(GhostButtonStyle())
                    if count > Self.importThreshold {
                        Button("Divide into batches…") {
                            queue.openImport(text: queue.clipboardLinks.joined(separator: "\n"))
                            queue.clipboardLinks = []
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    Button(count == 1 ? "Add it" : "Add all") { queue.acceptClipboardLinks() }.buttonStyle(PrimaryButtonStyle())
                }
                .modifier(BannerShape(tint: Theme.gold))
            }
            if let notice = queue.watchNotice {
                Banner(symbol: "tray.and.arrow.down", tint: Theme.gold, text: notice, buttonTitle: "OK") {
                    queue.watchNotice = nil
                }
            }
            PendingBatchesBanner()
            if let version = updater.availableVersion {
                Banner(symbol: "sparkles", tint: Theme.gold,
                       text: "Version \(version) is available.",
                       buttonTitle: updater.updating ? "Updating…" : "Update now") {
                    updater.installUpdate()
                }
            }
        }
        .padding(.horizontal, 24)
        .animation(Theme.ease, value: queue.clipboardLinks)
        .animation(Theme.ease, value: queue.pendingBatches.count)
        .animation(Theme.ease, value: queue.watchNotice)
    }

    // MARK: Queue

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(queue.items) { item in
                    ItemRow(item: item)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
            }
            .animation(Theme.ease, value: queue.items.map(\.id))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            OrbRing(progress: nil, size: 92, lineWidth: 1.3)
                .padding(.bottom, 10)
            Eyebrow("Ready when you are")
            Text("Bring the source to the edit suite.")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(.white)
            Text("Copy one or more links, then click Paste links. You can also drag links here.\nGot a long list? Click Import list, or drop a .txt, .csv or JDownloader .crawljob file here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Link(destination: Tools.website) {
                HStack(spacing: 7) {
                    CosmosMark().fill(.white.opacity(0.6)).frame(width: 12, height: 12)
                    Text("CREATION OF COSMOS").font(.system(size: 9.5, weight: .regular)).tracking(2.6)
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            .help("creationofcosmos.com")

            Text(statusText.uppercased()).font(.mono(9.5)).tracking(1.4).foregroundStyle(Theme.gold.opacity(0.8))
            Spacer()

            if queue.finishedCount > 0 {
                Button("Clear finished") { queue.clearFinished() }
                    .buttonStyle(GhostButtonStyle())
            }
            if queue.activeCount + queue.waitingCount > 0 {
                Button("Stop all") { queue.cancelAll() }
                    .buttonStyle(GhostButtonStyle())
            }
            Button {
                queue.startAll()
            } label: {
                Text(queue.readyCount > 1 ? "Download all (\(queue.readyCount))  →" : "Download  →")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(queue.items.allSatisfy { $0.state != .ready })
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            ZStack(alignment: .top) {
                Color.black.opacity(0.6)
                LinearGradient(colors: [.clear, Theme.hairline, .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1)
            }
        )
    }

    private var statusText: String {
        var parts: [String] = []
        if queue.activeCount > 0 { parts.append("\(queue.activeCount) downloading") }
        if queue.waitingCount > 0 { parts.append("\(queue.waitingCount) waiting") }
        if queue.finishedCount > 0 { parts.append("\(queue.finishedCount) done") }
        return parts.joined(separator: " · ")
    }

    // MARK: Adding links

    private func addTyped() {
        let count = queue.add(text: linkText)
        addMessage = count == 0 ? "No links found in what you typed." : nil
        if count > 0 { linkText = "" }
    }

    /// Pastes with more links than this open the Import window, so a long list can be divided first.
    static let importThreshold = 20

    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if LinkParser.links(in: text).count > Self.importThreshold {
            queue.markClipboardSeen()
            queue.openImport(text: text)
            addMessage = nil
            return
        }
        let count = queue.add(text: text)
        queue.markClipboardSeen()
        addMessage = count == 0 ? "The clipboard doesn't contain any links. Copy a link first." : "Added \(count) link\(count == 1 ? "" : "s")."
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL {
                            openDroppedList(url)
                        } else {
                            queue.add(text: url.absoluteString)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        if LinkParser.links(in: text).count > Self.importThreshold {
                            queue.openImport(text: text)
                        } else {
                            queue.add(text: text)
                        }
                    }
                }
            }
        }
        return true
    }

    /// A .txt or .csv dropped on the window opens in the Import window.
    private func openDroppedList(_ url: URL) {
        if url.pathExtension.lowercased() == Crawljob.fileExtension {
            queue.openCrawljobs([url])
            return
        }
        guard LinkImport.fileExtensions.contains(url.pathExtension.lowercased()) else {
            addMessage = "Drop a .txt, .csv or .crawljob file with links, or the links themselves."
            return
        }
        do {
            queue.openImport(text: try LinkImport.read(file: url), name: url.deletingPathExtension().lastPathComponent)
        } catch {
            addMessage = error.localizedDescription
        }
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
            Button(buttonTitle, action: action).buttonStyle(PrimaryButtonStyle())
        }
        .modifier(BannerShape(tint: tint))
    }
}

struct BannerShape: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.8))
            .transition(.opacity.combined(with: .offset(y: -6)))
    }
}
