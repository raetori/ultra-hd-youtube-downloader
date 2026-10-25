using System;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;

namespace CosmoGrav
{
    public partial class MainWindow : Window
    {
        public QueueManager Queue { get; }
        public AppSettings Settings { get; }
        public Updater Updater { get; }

        public MainWindow(QueueManager queue, Updater updater)
        {
            Queue = queue;
            Settings = queue.Settings;
            Updater = updater;
            InitializeComponent();
            Native.DarkTitleBar(this);

            foreach (var q in QualityInfo.All) QualityPicker.Items.Add(new ComboBoxItem { Content = q.Label(), Tag = q });
            SyncSettings();
            Settings.PropertyChanged += (s, e) => SyncSettings();

            Queue.Items.CollectionChanged += ItemsChanged;
            foreach (var item in Queue.Items) AddRow(item, animate: false);
            Queue.QueueChanged += () => Dispatcher.BeginInvoke(new Action(RefreshFooter));
            Queue.PropertyChanged += (s, e) => RefreshBanners();
            Queue.AllFinished += Finished;
            Updater.PropertyChanged += (s, e) => RefreshBanners();

            RefreshFooter();
            RefreshBanners();
            RefreshEmpty(animate: false);

            Activated += (s, e) => { Queue.CheckClipboard(); Updater.CheckIfStale(); };
            Loaded += (s, e) => Updater.StartChecking();
            Closing += OnClosing;
            DragEnter += OnDragOver;
            DragOver += OnDragOver;
            DragLeave += (s, e) => ShowDrop(false);
            Drop += OnDrop;

            InputBindings.Add(new KeyBinding(new Command(Paste), Key.V, ModifierKeys.Control | ModifierKeys.Shift));
            InputBindings.Add(new KeyBinding(new Command(() => { if (DownloadButton.IsEnabled) Queue.StartAll(); }), Key.Enter, ModifierKeys.Control));
            InputBindings.Add(new KeyBinding(new Command(() => SettingsWindow.Open(this)), Key.OemComma, ModifierKeys.Control));
            InputBindings.Add(new KeyBinding(new Command(() => HistoryWindow.Open(this)), Key.H, ModifierKeys.Control));
        }

        sealed class Command : ICommand
        {
            readonly Action action;
            public Command(Action action) { this.action = action; }
            public event EventHandler CanExecuteChanged { add { } remove { } }
            public bool CanExecute(object parameter) => true;
            public void Execute(object parameter) => action();
        }

        // MARK: Settings in the options bar

        bool syncing;
        void SyncSettings()
        {
            syncing = true;
            QualityPicker.SelectedItem = QualityPicker.Items.Cast<ComboBoxItem>().First(i => (Quality)i.Tag == Settings.DefaultQuality);
            FolderText.Text = QueueManager.FolderName(Settings.SaveFolder);
            FolderButton.ToolTip = Settings.SaveFolder;
            (Settings.MaxConcurrent == 1 ? Once1 : Settings.MaxConcurrent == 3 ? Once3 : Once2).IsChecked = true;
            syncing = false;
        }

        void QualityPicker_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (syncing || !(QualityPicker.SelectedItem is ComboBoxItem item)) return;
            Settings.DefaultQuality = (Quality)item.Tag;
        }

        void AtOnce_Checked(object sender, RoutedEventArgs e)
        {
            if (syncing || Settings == null) return;
            Settings.MaxConcurrent = int.Parse((string)((FrameworkElement)sender).Tag);
        }

        void Folder_Click(object sender, RoutedEventArgs e) => Settings.ChooseFolder(this);
        void History_Click(object sender, RoutedEventArgs e) => HistoryWindow.Open(this);
        void Settings_Click(object sender, RoutedEventArgs e) => SettingsWindow.Open(this);
        void About_Click(object sender, RoutedEventArgs e) => AboutWindow.Open(this);
        void Website_Click(object sender, RoutedEventArgs e) => OpenWebsite();

        public static void OpenWebsite()
        {
            try { Process.Start(new ProcessStartInfo(Tools.Website) { UseShellExecute = true }); } catch { }
        }

        // MARK: Adding links

        void LinkField_TextChanged(object sender, TextChangedEventArgs e) =>
            LinkHint.Visibility = LinkField.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        void LinkField_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key != Key.Enter) return;
            var count = Queue.Add(LinkField.Text);
            SetMessage(count == 0 ? "No links found in what you typed." : null);
            if (count > 0) LinkField.Text = "";
        }

        void Paste_Click(object sender, RoutedEventArgs e) => Paste();

        void Paste()
        {
            var count = Queue.PasteFromClipboard();
            SetMessage(count == 0 ? "The clipboard doesn't contain any links. Copy a link first." : $"Added {count} link{(count == 1 ? "" : "s")}.");
        }

        void SetMessage(string text)
        {
            AddMessage.Text = text ?? "";
            AddMessage.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            if (text != null) FadeIn(AddMessage, 0);
        }

        void OnDragOver(object sender, DragEventArgs e)
        {
            bool ok = e.Data.GetDataPresent(DataFormats.UnicodeText) || e.Data.GetDataPresent(DataFormats.Text) || e.Data.GetDataPresent("UniformResourceLocatorW");
            e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
            ShowDrop(ok);
            e.Handled = true;
        }

        void OnDrop(object sender, DragEventArgs e)
        {
            ShowDrop(false);
            string text = null;
            foreach (var format in new[] { DataFormats.UnicodeText, "UniformResourceLocatorW", DataFormats.Text, DataFormats.Html })
            {
                if (!e.Data.GetDataPresent(format)) continue;
                var data = e.Data.GetData(format);
                if (data is System.IO.MemoryStream ms) text = System.Text.Encoding.Unicode.GetString(ms.ToArray()).TrimEnd('\0');
                else text = data as string;
                if (!string.IsNullOrEmpty(text) && LinkParser.Links(text).Count > 0) break;
            }
            var count = Queue.Add(text ?? "");
            SetMessage(count == 0 ? "No links found in what you dropped." : $"Added {count} link{(count == 1 ? "" : "s")}.");
        }

        void ShowDrop(bool on) => Animate(DropOverlay, OpacityProperty, on ? 1 : 0);

        // MARK: Queue

        void ItemsChanged(object sender, NotifyCollectionChangedEventArgs e)
        {
            if (e.Action == NotifyCollectionChangedAction.Reset)
            {
                List.Children.Clear();
                foreach (var item in Queue.Items) AddRow(item, animate: false);
            }
            else
            {
                if (e.OldItems != null)
                    foreach (DownloadItem item in e.OldItems)
                    {
                        var row = List.Children.OfType<ItemRow>().FirstOrDefault(r => r.Item == item);
                        if (row != null) List.Children.Remove(row);
                    }
                if (e.NewItems != null)
                    foreach (DownloadItem item in e.NewItems) AddRow(item, animate: true);
            }
            RefreshEmpty(animate: true);
            RefreshFooter();
        }

        void AddRow(DownloadItem item, bool animate)
        {
            var row = new ItemRow(item, Queue);
            var index = Queue.Items.IndexOf(item);
            if (index >= 0 && index <= List.Children.Count) List.Children.Insert(index, row); else List.Children.Add(row);
            if (animate) FadeIn(row, 8);
        }

        public ItemRow RowFor(DownloadItem item) => List.Children.OfType<ItemRow>().FirstOrDefault(r => r.Item == item);

        bool? wasEmpty;
        void RefreshEmpty(bool animate)
        {
            bool empty = Queue.Items.Count == 0;
            if (wasEmpty == empty) return;
            wasEmpty = empty;
            EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
            ListScroll.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
            if (animate) FadeIn(empty ? (FrameworkElement)EmptyState : ListScroll, 0);
        }

        void RefreshFooter()
        {
            int active = Queue.ActiveCount, waiting = Queue.WaitingCount, finished = Queue.FinishedCount;
            var parts = new System.Collections.Generic.List<string>();
            if (active > 0) parts.Add($"{active} downloading");
            if (waiting > 0) parts.Add($"{waiting} waiting");
            if (finished > 0) parts.Add($"{finished} done");
            StatusText.Text = string.Join(" · ", parts);
            ClearButton.Visibility = finished > 0 ? Visibility.Visible : Visibility.Collapsed;
            StopButton.Visibility = active + waiting > 0 ? Visibility.Visible : Visibility.Collapsed;
            int ready = Queue.Items.Count(i => i.State == ItemState.Ready);
            DownloadButton.Content = Queue.ReadyCount > 1 ? $"Download all ({Queue.ReadyCount})  →" : "Download  →";
            DownloadButton.IsEnabled = ready > 0;

            // Overall progress on the taskbar button.
            var pending = Queue.Items.Where(i => i.State.IsActive() || i.State == ItemState.Queued).ToList();
            if (pending.Count == 0)
            {
                Taskbar.ProgressState = TaskbarItemProgressState.None;
            }
            else
            {
                Taskbar.ProgressState = TaskbarItemProgressState.Normal;
                Taskbar.ProgressValue = Math.Max(0.02, pending.Average(i => i.State.IsActive() ? i.Progress : 0));
            }
        }

        void Download_Click(object sender, RoutedEventArgs e) => Queue.StartAll();
        void Clear_Click(object sender, RoutedEventArgs e) => Queue.ClearFinished();
        void Stop_Click(object sender, RoutedEventArgs e) => Queue.CancelAll();

        // MARK: Banners

        void RefreshBanners()
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(RefreshBanners)); return; }
            Banners.Children.Clear();
            if (Queue.ToolsMissing)
            {
                Banners.Children.Add(Banner(Icons.Warning, Theme.Ember,
                    "Setup isn't finished on this PC. Run the install line in PowerShell once, then reopen the app.",
                    ("Copy install line", true, () => { try { Clipboard.SetText(Tools.InstallCommand); } catch { } })));
            }
            var links = Queue.ClipboardLinks;
            if (links.Count > 0)
            {
                Banners.Children.Add(Banner(Icons.Clipboard, Theme.Gold,
                    links.Count == 1 ? "You copied a link: " + links[0] : $"You copied {links.Count} links.",
                    ("Not now", false, () => Queue.ClipboardLinks = new System.Collections.Generic.List<string>()),
                    (links.Count == 1 ? "Add it" : "Add all", true, Queue.AcceptClipboardLinks)));
            }
            if (Updater.AvailableVersion != null)
            {
                Banners.Children.Add(Banner(Icons.Sparkle, Theme.Gold, $"Version {Updater.AvailableVersion} is available.",
                    (Updater.Updating ? "Updating…" : "Update now", true, Updater.InstallUpdate)));
            }
            Banners.Margin = new Thickness(24, 0, 24, Banners.Children.Count > 0 ? 6 : 0);
        }

        FrameworkElement Banner(string glyph, Color tint, string text, params (string title, bool primary, Action action)[] buttons)
        {
            var row = new DockPanel();
            row.Children.Add(new TextBlock { Text = glyph, FontFamily = Theme.IconFont, FontSize = 13, Foreground = Theme.Brush(tint), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            foreach (var (title, primary, action) in buttons)
            {
                var button = new Button { Content = title, Style = (Style)FindResource(primary ? "PrimaryButton" : "GhostButton"), Margin = new Thickness(8, 0, 0, 0) };
                var run = action;
                button.Click += (s, e) => run();
                actions.Children.Add(button);
            }
            DockPanel.SetDock(actions, Dock.Right);
            row.Children.Add(actions);
            row.Children.Add(new TextBlock { Text = text, FontSize = 12.5, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var border = new Border
            {
                Child = row,
                Padding = new Thickness(16, 9, 12, 9),
                Margin = new Thickness(0, 0, 0, 6),
                CornerRadius = new CornerRadius(12),
                Background = Theme.Brush(tint, 0.07),
                BorderBrush = Theme.Brush(tint, 0.22),
                BorderThickness = new Thickness(1),
            };
            FadeIn(border, -6);
            return border;
        }

        // MARK: Finishing

        void Finished(int done, int failed)
        {
            if (IsActive) return;
            Native.Flash(this);
            if (Settings.NotifyWhenDone) Notifier.Show("Downloads finished", $"{done} ready" + (failed > 0 ? $", {failed} failed" : "") + ". Click to open CosmoGrav.", this);
        }

        void OnClosing(object sender, CancelEventArgs e)
        {
            if (App.QuittingWithoutAsking || Queue.ActiveCount == 0) { Queue.StopEverything(); return; }
            var keep = CosmosDialog.Ask(this, "Downloads are still running", "Closing will stop them. Unfinished downloads are not saved.",
                                        "Keep downloading", "Close anyway");
            if (keep) e.Cancel = true;
            else Queue.StopEverything();
        }

        // MARK: Motion

        public static readonly KeySpline EaseSpline = new KeySpline(0.45, 0, 0.2, 1);

        /// Fades an element in while it rises a few pixels, with the app's soft easing.
        public static void FadeIn(FrameworkElement element, double rise)
        {
            element.Opacity = 0;
            Animate(element, OpacityProperty, 1);
            if (rise != 0)
            {
                var move = new TranslateTransform(0, rise);
                element.RenderTransform = move;
                Animate(move, TranslateTransform.YProperty, 0);
            }
        }

        public static void Animate(IAnimatable target, DependencyProperty property, double to)
        {
            var animation = new DoubleAnimationUsingKeyFrames();
            animation.KeyFrames.Add(new SplineDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.55)), EaseSpline));
            target.BeginAnimation(property, animation);
        }
    }

    /// Windows notification ("Downloads finished") through a temporary tray icon.
    static class Notifier
    {
        public static void Show(string title, string text, Window window)
        {
            try
            {
                var exe = Process.GetCurrentProcess().MainModule.FileName;
                var icon = new System.Windows.Forms.NotifyIcon
                {
                    Icon = System.Drawing.Icon.ExtractAssociatedIcon(exe),
                    Text = "CosmoGrav",
                    Visible = true,
                };
                void Bring()
                {
                    window.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
                        window.Activate();
                    }));
                }
                icon.BalloonTipClicked += (s, e) => Bring();
                icon.Click += (s, e) => Bring();
                icon.ShowBalloonTip(8000, title, text, System.Windows.Forms.ToolTipIcon.None);
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(12) };
                timer.Tick += (s, e) => { timer.Stop(); icon.Visible = false; icon.Dispose(); };
                timer.Start();
            }
            catch { }
        }
    }
}
