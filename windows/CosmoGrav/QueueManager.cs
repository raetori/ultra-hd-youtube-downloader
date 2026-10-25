using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;

namespace CosmoGrav
{
    public sealed class AppSettings : Observable
    {
        string saveFolder, loginBrowser;
        Quality defaultQuality;
        int maxConcurrent;
        bool saveCaptions, notifyWhenDone, watchClipboard;

        public string SaveFolder { get => saveFolder; set { if (Set(ref saveFolder, value)) Save(); } }
        public Quality DefaultQuality { get => defaultQuality; set { if (Set(ref defaultQuality, value)) Save(); } }
        public int MaxConcurrent { get => maxConcurrent; set { if (Set(ref maxConcurrent, value)) Save(); } }
        /// Browser whose login yt-dlp may borrow when a site insists on one ("none" = never).
        public string LoginBrowser { get => loginBrowser; set { if (Set(ref loginBrowser, value)) Save(); } }
        /// Also save captions (.srt) next to each video when the site has them.
        public bool SaveCaptions { get => saveCaptions; set { if (Set(ref saveCaptions, value)) Save(); } }
        public bool NotifyWhenDone { get => notifyWhenDone; set { if (Set(ref notifyWhenDone, value)) Save(); } }
        public bool WatchClipboard { get => watchClipboard; set { if (Set(ref watchClipboard, value)) Save(); } }

        // Firefox is listed first: Chrome-based browsers on Windows lock their logins away from other apps.
        public static readonly KeyValuePair<string, string>[] Browsers =
        {
            new KeyValuePair<string, string>("none", "Don't use a login"),
            new KeyValuePair<string, string>("firefox", "Firefox (works best)"),
            new KeyValuePair<string, string>("chrome", "Google Chrome"),
            new KeyValuePair<string, string>("edge", "Microsoft Edge"),
            new KeyValuePair<string, string>("brave", "Brave"),
            new KeyValuePair<string, string>("opera", "Opera"),
            new KeyValuePair<string, string>("vivaldi", "Vivaldi"),
        };

        bool loading;

        public AppSettings()
        {
            loading = true;
            var json = File.Exists(Tools.SettingsFile) ? Json.TryParseObject(SafeRead(Tools.SettingsFile)) : null;
            var downloads = KnownFolders.Downloads;
            var folder = json.Str("saveFolder");
            SaveFolder = !string.IsNullOrEmpty(folder) ? folder : downloads;
            DefaultQuality = QualityInfo.FromKey(json.Str("defaultQuality")) ?? Quality.Best;
            var stored = json.Int("maxConcurrent") ?? 2;
            MaxConcurrent = stored >= 1 && stored <= 3 ? stored : 2;
            LoginBrowser = json.Str("loginBrowser") ?? "none";
            SaveCaptions = json.Bool("saveCaptions") ?? false;
            NotifyWhenDone = json.Bool("notifyWhenDone") ?? true;
            WatchClipboard = json.Bool("watchClipboard") ?? true;
            loading = false;
        }

        static string SafeRead(string path) { try { return File.ReadAllText(path); } catch { return null; } }

        void Save()
        {
            if (loading) return;
            try
            {
                Directory.CreateDirectory(Tools.Base);
                var json = new Dictionary<string, object>
                {
                    ["saveFolder"] = SaveFolder, ["defaultQuality"] = DefaultQuality.Key(), ["maxConcurrent"] = MaxConcurrent,
                    ["loginBrowser"] = LoginBrowser, ["saveCaptions"] = SaveCaptions, ["notifyWhenDone"] = NotifyWhenDone,
                    ["watchClipboard"] = WatchClipboard,
                };
                File.WriteAllText(Tools.SettingsFile, Json.Stringify(json, indent: true));
            }
            catch { }
        }

        public string LoginBrowserName => Browsers.FirstOrDefault(b => b.Key == LoginBrowser).Value?.Replace(" (works best)", "") ?? LoginBrowser;

        public void ChooseFolder(Window owner)
        {
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog
            {
                Description = "Choose where downloads are saved",
                SelectedPath = SaveFolder,
                ShowNewFolderButton = true,
            })
            {
                var parent = owner != null ? new Win32Owner(owner) : null;
                if (dialog.ShowDialog(parent) == System.Windows.Forms.DialogResult.OK && !string.IsNullOrEmpty(dialog.SelectedPath))
                    SaveFolder = dialog.SelectedPath;
            }
        }

        sealed class Win32Owner : System.Windows.Forms.IWin32Window
        {
            public Win32Owner(Window w) { Handle = new System.Windows.Interop.WindowInteropHelper(w).Handle; }
            public IntPtr Handle { get; }
        }
    }

    static class KnownFolders
    {
        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out string path);

        /// The user's real Downloads folder, even when they moved it to another drive.
        public static string Downloads
        {
            get
            {
                try
                {
                    var id = new Guid("374DE290-123F-4565-9164-39C4925E467B");
                    if (SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out var path) == 0 && !string.IsNullOrEmpty(path)) return path;
                }
                catch { }
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            }
        }
    }

    public sealed class QueueManager : Observable
    {
        public static QueueManager Shared { get; private set; }

        public ObservableCollection<DownloadItem> Items { get; } = new ObservableCollection<DownloadItem>();
        public List<HistoryEntry> History { get; private set; } = new List<HistoryEntry>();
        public AppSettings Settings { get; }

        bool toolsMissing = !Tools.Installed;
        public bool ToolsMissing { get => toolsMissing; set => Set(ref toolsMissing, value); }

        /// Links found on the clipboard when the app comes to the front, offered with one click.
        List<string> clipboardLinks = new List<string>();
        public List<string> ClipboardLinks { get => clipboardLinks; set { clipboardLinks = value; Raise(nameof(ClipboardLinks)); } }
        uint lastClipboardChange = SafeClipboardSequence();

        /// Raised when any item's state changes, so the footer and taskbar can refresh.
        public event Action QueueChanged;
        public event Action HistoryChanged;
        /// Raised when everything queued has finished (done, failed counts).
        public event Action<int, int> AllFinished;

        readonly AsyncLimiter infoLimiter = new AsyncLimiter(4);

        public QueueManager(AppSettings settings)
        {
            Settings = settings;
            LoadHistory();
            Shared = this;
            Items.CollectionChanged += (s, e) =>
            {
                if (e.NewItems != null) foreach (DownloadItem item in e.NewItems) item.PropertyChanged += ItemChanged;
                if (e.OldItems != null) foreach (DownloadItem item in e.OldItems) item.PropertyChanged -= ItemChanged;
                QueueChanged?.Invoke();
            };
            Task.Run(() => Tools.UpdateDownloaderIfStale());
        }

        void ItemChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(DownloadItem.State) || e.PropertyName == nameof(DownloadItem.Progress)) QueueChanged?.Invoke();
        }

        public int ActiveCount => Items.Count(i => i.State.IsActive());
        public int ReadyCount => Items.Count(i => i.State.CanStart());
        public int FinishedCount => Items.Count(i => i.State == ItemState.Done);
        public int WaitingCount => Items.Count(i => i.State == ItemState.Queued);

        // MARK: Adding

        public int Add(string text)
        {
            var links = LinkParser.Links(text);
            Add(links.Select(l => new KeyValuePair<string, string>(l, null)));
            return links.Count;
        }

        public void Add(IEnumerable<KeyValuePair<string, string>> urls)
        {
            ToolsMissing = !Tools.Installed;
            foreach (var entry in urls)
            {
                if (Items.Any(i => i.Url == entry.Key && i.State != ItemState.Done)) continue;
                var item = new DownloadItem(entry.Key, Settings.DefaultQuality, entry.Value);
                Items.Add(item);
                FetchInfo(item);
            }
        }

        public async void FetchInfo(DownloadItem item)
        {
            item.State = ItemState.Fetching;
            item.Detail = "Getting info…";
            item.ErrorMessage = null;
            string url = item.Url, browser = Settings.LoginBrowser;
            var quality = item.Quality;
            bool useLogin = item.UseLogin;
            await infoLimiter.Acquire();
            try
            {
                var info = await Pipeline.FetchInfo(url, quality, useLogin, browser);
                if (info.Entries != null)
                {
                    // A playlist link becomes one row per video.
                    Items.Remove(item);
                    Add(info.Entries);
                    return;
                }
                item.Title = info.Title;
                if (string.IsNullOrEmpty(item.FileName) || !item.InfoLoaded) item.FileName = FileNames.Sanitize(info.Title);
                item.Site = SiteName(info.Site, url);
                item.Thumbnail = info.Thumbnail;
                item.Duration = info.Duration;
                item.Resolution = item.Quality.IsAudio() ? null : Pipeline.ResolutionLabel(info.Height);
                item.ExpectedParts = info.Parts;
                item.InfoLoaded = true;
                item.NeedsLogin = false;
                if (item.State == ItemState.Fetching) { item.State = ItemState.Ready; item.Detail = "Ready"; }
            }
            catch (Exception error)
            {
                item.State = ItemState.Failed;
                item.ErrorMessage = Friendly(error);
                item.NeedsLogin = (error as PipelineException)?.NeedsLogin ?? false;
                item.Detail = "Couldn't load this link";
                if (string.IsNullOrEmpty(item.Site)) item.Site = SiteName("", url);
            }
            finally
            {
                infoLimiter.Release();
            }
        }

        static string Friendly(Exception error)
        {
            if (error is System.ComponentModel.Win32Exception)
                return "The download tools are missing. Run the install line in PowerShell again.";
            return error.Message;
        }

        public static string SiteName(string extractor, string url)
        {
            string host = "";
            try { host = new Uri(url).Host.ToLowerInvariant(); } catch { }
            var known = new[]
            {
                ("youtu", "YouTube"), ("tiktok", "TikTok"), ("instagram", "Instagram"), ("facebook", "Facebook"), ("fb.watch", "Facebook"),
                ("vimeo", "Vimeo"), ("twitter", "X"), ("x.com", "X"), ("twitch", "Twitch"), ("reddit", "Reddit"),
                ("soundcloud", "SoundCloud"), ("dailymotion", "Dailymotion"),
            };
            foreach (var (key, name) in known) if (host.Contains(key)) return name;
            if (!string.IsNullOrEmpty(extractor) && extractor.ToLowerInvariant() != "generic") return extractor;
            return host.Replace("www.", "");
        }

        // MARK: Running

        public void Start(DownloadItem item)
        {
            if (!item.State.CanStart()) return;
            if (!item.InfoLoaded) { FetchInfo(item); return; }
            item.State = ItemState.Queued;
            item.Detail = "Waiting…";
            item.ErrorMessage = null;
            item.Progress = 0;
            Pump();
        }

        public void StartAll()
        {
            foreach (var item in Items.Where(i => i.State == ItemState.Ready))
            {
                item.State = ItemState.Queued;
                item.Detail = "Waiting…";
                item.Progress = 0;
            }
            Pump();
        }

        public void Retry(DownloadItem item, bool withLogin = false)
        {
            if (withLogin) item.UseLogin = true;
            if (item.InfoLoaded) Start(item); else FetchInfo(item);
        }

        public void Cancel(DownloadItem item)
        {
            switch (item.State)
            {
                case ItemState.Queued:
                    item.State = ItemState.Ready;
                    item.Detail = "Ready";
                    break;
                case ItemState.Downloading:
                case ItemState.Converting:
                    item.Runner?.Cancel();
                    item.Detail = "Stopping…";
                    break;
            }
        }

        public void CancelAll()
        {
            foreach (var item in Items.Where(i => i.State == ItemState.Queued || i.State.IsActive()).ToList()) Cancel(item);
        }

        public void Remove(DownloadItem item)
        {
            if (item.State.IsActive()) item.Runner?.Cancel();
            Items.Remove(item);
        }

        public void ClearFinished()
        {
            foreach (var item in Items.Where(i => i.State == ItemState.Done || i.State == ItemState.Cancelled).ToList()) Items.Remove(item);
        }

        void Pump()
        {
            int slots = Settings.MaxConcurrent - ActiveCount;
            foreach (var item in Items.Where(i => i.State == ItemState.Queued).ToList())
            {
                if (slots <= 0) break;
                slots--;
                Run(item);
            }
            UpdateKeepAwake();
            QueueChanged?.Invoke();
        }

        async void Run(DownloadItem item)
        {
            var handle = new RunningProcess();
            item.Runner = handle;
            item.State = ItemState.Downloading;
            item.Progress = 0;
            item.Detail = "Starting…";
            item.ErrorMessage = null;

            string url = item.Url, browser = Settings.LoginBrowser, folder = Settings.SaveFolder;
            var quality = item.Quality;
            int parts = item.ExpectedParts;
            bool useLogin = item.UseLogin, captions = Settings.SaveCaptions;
            double? trimStart = item.TrimStart, trimEnd = item.TrimEnd, duration = item.Duration;
            var work = Path.Combine(Tools.WorkRoot, item.Id.ToString("N"));
            var dispatcher = Application.Current?.Dispatcher;

            Action<double, string> report = (value, text) =>
            {
                Action apply = () =>
                {
                    if (!item.State.IsActive()) return;
                    item.Progress = value;
                    item.Detail = text;
                };
                if (dispatcher != null) dispatcher.BeginInvoke(apply); else apply();
            };

            try
            {
                try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch { }
                Directory.CreateDirectory(work);
                try
                {
                    var temp = Path.Combine(work, "final." + quality.FileExtension());
                    bool done = false;
                    if (trimStart.HasValue || trimEnd.HasValue)
                        done = await Pipeline.DownloadSection(url, quality, trimStart, trimEnd, duration, useLogin, browser, temp, handle, report);
                    if (!done)
                    {
                        var downloaded = await Pipeline.Download(url, quality, parts, useLogin, browser, work, handle, report);
                        item.State = ItemState.Converting;
                        item.Progress = 0;
                        await Pipeline.Finalize(downloaded, quality, trimStart, trimEnd, temp, handle, report);
                    }

                    Directory.CreateDirectory(folder);
                    var name = string.IsNullOrEmpty(item.FileName) ? item.Title : item.FileName;
                    var destination = FileNames.Unique(folder, name, quality.FileExtension());
                    File.Move(temp, destination);

                    var savedNote = "Saved to " + FolderName(folder);
                    if (captions)
                    {
                        item.Detail = "Saving captions…";
                        var srt = await Pipeline.SaveCaptions(url, useLogin, browser, work, trimStart, trimEnd,
                                                              Path.Combine(Path.GetDirectoryName(destination), Path.GetFileNameWithoutExtension(destination)));
                        savedNote += srt.Count == 0 ? " · no captions available" : " · with captions";
                    }

                    item.OutputPath = destination;
                    item.State = ItemState.Done;
                    item.Progress = 1;
                    item.Detail = savedNote;
                    AddHistory(item, destination);
                }
                finally
                {
                    try { Directory.Delete(work, true); } catch { }
                }
            }
            catch (Exception error)
            {
                if (handle.Cancelled || error is OperationCanceledException)
                {
                    item.State = ItemState.Cancelled;
                    item.Detail = "Cancelled";
                }
                else
                {
                    item.State = ItemState.Failed;
                    item.ErrorMessage = Friendly(error);
                    item.NeedsLogin = (error as PipelineException)?.NeedsLogin ?? false;
                    item.Detail = "Failed";
                }
            }
            item.Runner = null;
            Pump();
            if (ActiveCount == 0 && WaitingCount == 0 && FinishedCount > 0)
                AllFinished?.Invoke(FinishedCount, Items.Count(i => i.State == ItemState.Failed));
        }

        public static string FolderName(string folder)
        {
            var name = Path.GetFileName(folder.TrimEnd('\\', '/'));
            return string.IsNullOrEmpty(name) ? folder : name;
        }

        bool awake;
        void UpdateKeepAwake()
        {
            bool pending = ActiveCount + WaitingCount > 0;
            if (pending == awake) return;
            awake = pending;
            Native.KeepAwake(pending);
        }

        // MARK: Clipboard

        static uint SafeClipboardSequence() { try { return Native.GetClipboardSequenceNumber(); } catch { return 0; } }

        static string ClipboardText()
        {
            // The clipboard can be busy for a moment while another app writes to it.
            for (int attempt = 0; attempt < 3; attempt++)
            {
                try { return Clipboard.ContainsText() ? Clipboard.GetText() : ""; }
                catch { System.Threading.Thread.Sleep(40); }
            }
            return "";
        }

        public int PasteFromClipboard()
        {
            var count = Add(ClipboardText());
            MarkClipboardSeen();
            return count;
        }

        /// Called when the app comes to the front: offers links copied elsewhere since the last look.
        public void CheckClipboard()
        {
            if (!Settings.WatchClipboard) return;
            var change = SafeClipboardSequence();
            if (change == lastClipboardChange) return;
            lastClipboardChange = change;
            var known = new HashSet<string>(Items.Select(i => i.Url));
            ClipboardLinks = LinkParser.Links(ClipboardText()).Where(l => !known.Contains(l)).Take(50).ToList();
        }

        public void AcceptClipboardLinks()
        {
            Add(ClipboardLinks.Select(l => new KeyValuePair<string, string>(l, null)).ToList());
            ClipboardLinks = new List<string>();
        }

        /// Links added with the Paste button shouldn't be offered again by the clipboard banner.
        public void MarkClipboardSeen()
        {
            lastClipboardChange = SafeClipboardSequence();
            ClipboardLinks = new List<string>();
        }

        // MARK: History (kept only on this PC)

        void LoadHistory()
        {
            try
            {
                if (!File.Exists(Tools.HistoryFile)) return;
                if (Json.Parse(File.ReadAllText(Tools.HistoryFile)) is List<object> list)
                    History = list.Select(o => HistoryEntry.FromJson(o as Dictionary<string, object>)).Where(e => e != null).ToList();
            }
            catch { }
        }

        void SaveHistory()
        {
            try
            {
                Directory.CreateDirectory(Tools.Base);
                var temp = Tools.HistoryFile + ".tmp";
                File.WriteAllText(temp, Json.Stringify(History.Select(h => h.ToJson()).ToList()));
                if (File.Exists(Tools.HistoryFile)) File.Replace(temp, Tools.HistoryFile, null); else File.Move(temp, Tools.HistoryFile);
            }
            catch { }
            HistoryChanged?.Invoke();
        }

        void AddHistory(DownloadItem item, string file)
        {
            History.Insert(0, new HistoryEntry { Title = item.Title, Url = item.Url, Site = item.Site, FilePath = file, Quality = item.Quality, Date = DateTime.Now });
            if (History.Count > 500) History.RemoveRange(500, History.Count - 500);
            SaveHistory();
        }

        public void ClearHistory()
        {
            History = new List<HistoryEntry>();
            SaveHistory();
        }

        /// Swaps in sample history for the guide's screenshots without saving it.
        public void ShowHistoryForScreenshots(List<HistoryEntry> entries) => History = entries;

        public void Redownload(HistoryEntry entry)
        {
            var item = new DownloadItem(entry.Url, entry.Quality, entry.Title);
            Items.Add(item);
            FetchInfo(item);
        }

        public void StopEverything()
        {
            foreach (var item in Items.Where(i => i.State.IsActive())) item.Runner?.Cancel();
        }
    }
}
