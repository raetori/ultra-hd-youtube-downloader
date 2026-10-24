import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var queue: QueueManager
    @State private var updatingTools = false
    @State private var toolsMessage: String?

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.saveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { settings.chooseFolder() }
                    }
                }
                Picker("Default quality", selection: $settings.defaultQuality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Downloads at once", selection: $settings.maxConcurrent) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
            }

            Section {
                Picker("Browser login", selection: $settings.loginBrowser) {
                    ForEach(AppSettings.browsers, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("Instagram, Facebook and other sites that need a login")
            } footer: {
                Text("Only used when a site refuses a download and you click “Use my login”. The app borrows the login from the browser you pick here, so anything you can watch while logged in can be downloaded. Chrome-based browsers ask for permission the first time. For Safari, give this app Full Disk Access in System Settings → Privacy & Security.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                LabeledContent("Download engine") {
                    HStack {
                        if !FileManager.default.isExecutableFile(atPath: Tools.deno.path) {
                            Text("Deno missing: YouTube will be slow. Run the install line again.")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                        }
                        if let toolsMessage { Text(toolsMessage).foregroundStyle(.secondary) }
                        Button(updatingTools ? "Updating…" : "Update now") { updateTools() }.disabled(updatingTools)
                    }
                }
                LabeledContent("History") {
                    Button("Clear history (\(queue.history.count))") { queue.clearHistory() }
                        .disabled(queue.history.isEmpty)
                }
                LabeledContent("Version") { Text(Updater.currentVersion).foregroundStyle(.secondary) }
            }

            Section {
                Link("creationofcosmos.com", destination: Tools.website)
            } footer: {
                Text("Please only download content you have the rights to use. Everything stays on this Mac: no accounts, no tracking.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func updateTools() {
        updatingTools = true
        toolsMessage = nil
        Task {
            let stamp = Tools.base.appendingPathComponent("last-update")
            try? FileManager.default.removeItem(at: stamp)
            await Tools.updateDownloaderIfStale()
            updatingTools = false
            toolsMessage = FileManager.default.fileExists(atPath: stamp.path) ? "Up to date" : "Couldn't update. Check your connection."
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var queue: QueueManager
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return queue.history }
        return queue.history.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.site.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.title3.weight(.semibold))
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(16)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(queue.history.isEmpty ? "Nothing downloaded yet." : "No matches.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filtered) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.quality.symbol).foregroundStyle(Theme.accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            HStack(spacing: 6) {
                                SiteBadge(site: entry.site)
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Text("· " + entry.quality.shortLabel)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let exists = FileManager.default.fileExists(atPath: entry.filePath)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)]) }
                            .disabled(!exists)
                            .help(exists ? entry.filePath : "The file was moved or deleted")
                        Button("Download again") { queue.redownload(entry); dismiss() }
                    }
                    .padding(.vertical, 3)
                }
            }
            Divider()
            HStack {
                Text("History is stored only on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history") { queue.clearHistory() }.disabled(queue.history.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
    }
}
