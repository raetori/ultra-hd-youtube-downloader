using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace CosmoGrav
{
    /// A dark window in the app's style, with a black title bar.
    public class CosmosWindow : Window
    {
        public CosmosWindow()
        {
            Background = (Brush)Application.Current.FindResource("Ink");
            Foreground = Brushes.White;
            FontFamily = Theme.Ui;
            UseLayoutRounding = true;
            ShowInTaskbar = false;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            try { Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/icon.ico")); } catch { }
            Native.DarkTitleBar(this);
            KeyDown += (s, e) => { if (e.Key == Key.Escape) Close(); };
        }

        protected static Style S(string key) => (Style)Application.Current.FindResource(key);
        protected static Brush B(string key) => (Brush)Application.Current.FindResource(key);

        protected static TextBlock Text(string text, double size = 12.5, Brush color = null, FontWeight? weight = null) => new TextBlock
        {
            Text = text, FontSize = size, Foreground = color ?? Brushes.White, FontWeight = weight ?? FontWeights.Normal,
            TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
        };

        /// A grouped card with an eyebrow title, like the Mac app's grouped Settings form.
        protected static Border Section(string title, params UIElement[] rows)
        {
            var stack = new StackPanel();
            if (title != null) stack.Children.Add(new TrackedText { Text = title, Mono = true, FontSize = 9.5, Tracking = 2.2, Foreground = B("Ember"), Margin = new Thickness(0, 0, 0, 10), HorizontalAlignment = HorizontalAlignment.Left });
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0) stack.Children.Add(new Border { Height = 1, Background = B("Hairline"), Margin = new Thickness(0, 10, 0, 10) });
                stack.Children.Add(rows[i]);
            }
            return new Border
            {
                Child = stack, Padding = new Thickness(16, 14, 16, 14), Margin = new Thickness(0, 0, 0, 12),
                CornerRadius = new CornerRadius(12), Background = B("Card"), BorderBrush = B("Hairline"), BorderThickness = new Thickness(1),
            };
        }

        protected static DockPanel Row(string label, UIElement control)
        {
            var row = new DockPanel();
            DockPanel.SetDock(control, Dock.Right);
            row.Children.Add(control);
            row.Children.Add(Text(label));
            return row;
        }

        protected static ComboBox Combo(double width) => new ComboBox { Style = S("DarkCombo"), Width = width };
    }

    public sealed class SettingsWindow : CosmosWindow
    {
        static SettingsWindow open;
        readonly QueueManager queue = QueueManager.Shared;
        readonly AppSettings settings = QueueManager.Shared.Settings;
        public ScrollViewer Scroller { get; }

        public static SettingsWindow Open(Window owner)
        {
            if (open != null) { open.Activate(); return open; }
            open = new SettingsWindow { Owner = owner };
            open.Closed += (s, e) => open = null;
            open.Show();
            return open;
        }

        SettingsWindow()
        {
            Title = "CosmoGrav Settings";
            Width = 580;
            Height = 720;
            MinWidth = 480;
            MinHeight = 400;
            var stack = new StackPanel { Margin = new Thickness(22, 20, 22, 10) };

            // Downloads
            var folderText = Text(settings.SaveFolder, 12, B("TextDim"));
            folderText.TextWrapping = TextWrapping.NoWrap;
            folderText.TextTrimming = TextTrimming.CharacterEllipsis;
            folderText.MaxWidth = 260;
            var change = new Button { Content = "Change…", Style = S("GhostButton"), Margin = new Thickness(10, 0, 0, 0) };
            change.Click += (s, e) => { settings.ChooseFolder(this); folderText.Text = settings.SaveFolder; };
            var folderRow = new StackPanel { Orientation = Orientation.Horizontal };
            folderRow.Children.Add(folderText);
            folderRow.Children.Add(change);

            var quality = Combo(240);
            foreach (var q in QualityInfo.All) quality.Items.Add(new ComboBoxItem { Content = q.Label(), Tag = q });
            quality.SelectedItem = quality.Items.Cast<ComboBoxItem>().First(i => (Quality)i.Tag == settings.DefaultQuality);
            quality.SelectionChanged += (s, e) => settings.DefaultQuality = (Quality)((ComboBoxItem)quality.SelectedItem).Tag;

            var atOnce = Combo(90);
            for (int n = 1; n <= 3; n++) atOnce.Items.Add(new ComboBoxItem { Content = n.ToString(), Tag = n });
            atOnce.SelectedIndex = settings.MaxConcurrent - 1;
            atOnce.SelectionChanged += (s, e) => settings.MaxConcurrent = (int)((ComboBoxItem)atOnce.SelectedItem).Tag;

            stack.Children.Add(Section("Downloads",
                Row("Save to", folderRow),
                Row("Default quality", quality),
                Row("Downloads at once", atOnce),
                Switch("Also save captions (.srt) when available", settings.SaveCaptions, v => settings.SaveCaptions = v),
                Switch("Notify me when downloads finish", settings.NotifyWhenDone, v => settings.NotifyWhenDone = v),
                Switch("Offer links I copy when I switch to the app", settings.WatchClipboard, v => settings.WatchClipboard = v)));

            // Logins
            var browser = Combo(220);
            foreach (var b in AppSettings.Browsers) browser.Items.Add(new ComboBoxItem { Content = b.Value, Tag = b.Key });
            browser.SelectedItem = browser.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == settings.LoginBrowser) ?? browser.Items[0];
            browser.SelectionChanged += (s, e) => settings.LoginBrowser = (string)((ComboBoxItem)browser.SelectedItem).Tag;
            stack.Children.Add(Section("Instagram, Facebook and other sites that need a login",
                Row("Browser login", browser),
                Text("Only used when a site refuses a download and you click “Use my login”. The app borrows the login from the browser you pick here, " +
                     "so anything you can watch while logged in can be downloaded. Firefox works best on Windows: Chrome, Edge and other Chrome-based " +
                     "browsers lock their logins away from other apps, so close that browser completely first if you pick one of them.", 11.5, B("TextDim"))));

            // Maintenance
            var engineStatus = Text("", 11.5, B("TextDim"));
            engineStatus.Margin = new Thickness(0, 0, 10, 0);
            if (!File.Exists(Tools.Deno)) { engineStatus.Text = "Deno missing: YouTube will be slow. Run the install line again."; engineStatus.Foreground = B("Ember"); }
            var update = new Button { Content = "Update now", Style = S("GhostButton") };
            update.Click += async (s, e) =>
            {
                update.IsEnabled = false;
                update.Content = "Updating…";
                await Tools.UpdateDownloaderIfStale(force: true);
                var stamp = Path.Combine(Tools.Base, "last-update");
                update.Content = "Update now";
                update.IsEnabled = true;
                engineStatus.Foreground = B("TextDim");
                engineStatus.Text = File.Exists(stamp) && DateTime.Now - File.GetLastWriteTime(stamp) < TimeSpan.FromMinutes(1) ? "Up to date" : "Couldn't update. Check your connection.";
            };
            var engineRow = new StackPanel { Orientation = Orientation.Horizontal };
            engineRow.Children.Add(engineStatus);
            engineRow.Children.Add(update);

            var clear = new Button { Style = S("GhostButton") };
            void UpdateClear() { clear.Content = $"Clear history ({queue.History.Count})"; clear.IsEnabled = queue.History.Count > 0; }
            UpdateClear();
            clear.Click += (s, e) => { queue.ClearHistory(); UpdateClear(); };

            stack.Children.Add(Section("Maintenance",
                Row("Download engine", engineRow),
                Row("History", clear),
                Row("Version", Text(Updater.CurrentVersion, 12.5, B("TextDim")))));

            var site = new Button { Content = "creationofcosmos.com", Style = S("LinkButton"), FontSize = 12.5, HorizontalAlignment = HorizontalAlignment.Left };
            site.Click += (s, e) => MainWindow.OpenWebsite();
            stack.Children.Add(Section(null, site,
                Text("Please only download content you have the rights to use. Everything stays on this PC: no accounts, no tracking.", 11.5, B("TextDim"))));

            Scroller = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Content = Scroller;
        }

        static CheckBox Switch(string label, bool value, Action<bool> set)
        {
            var box = new CheckBox { Content = label, IsChecked = value, Style = S("Switch") };
            box.Checked += (s, e) => set(true);
            box.Unchecked += (s, e) => set(false);
            return box;
        }
    }

    public sealed class HistoryWindow : CosmosWindow
    {
        static HistoryWindow open;
        readonly QueueManager queue = QueueManager.Shared;
        readonly StackPanel list = new StackPanel();
        readonly TextBox search;
        readonly Button clear;

        public static HistoryWindow Open(Window owner)
        {
            if (open != null) { open.Activate(); return open; }
            open = new HistoryWindow { Owner = owner };
            open.Closed += (s, e) => open = null;
            open.Show();
            return open;
        }

        HistoryWindow()
        {
            Title = "CosmoGrav History";
            Width = 680;
            Height = 500;
            MinWidth = 520;
            MinHeight = 320;

            var root = new DockPanel();
            var header = new DockPanel { Margin = new Thickness(20, 18, 20, 14) };
            search = new TextBox { Style = S("FieldTextBox"), Width = 220, FontSize = 12.5 };
            var hint = new TextBlock { Text = "Search", Foreground = Theme.White(0.35), FontSize = 12.5, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            search.TextChanged += (s, e) => { hint.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Fill(); };
            var searchGrid = new Grid { VerticalAlignment = VerticalAlignment.Center };
            searchGrid.Children.Add(search);
            searchGrid.Children.Add(hint);
            DockPanel.SetDock(searchGrid, Dock.Right);
            header.Children.Add(searchGrid);
            var titles = new StackPanel();
            titles.Children.Add(new TrackedText { Text = "Archive", Mono = true, FontSize = 9.5, Tracking = 2.2, Foreground = B("Ember"), Margin = new Thickness(0, 0, 0, 5), HorizontalAlignment = HorizontalAlignment.Left });
            titles.Children.Add(Text("History", 20, Brushes.White, FontWeights.Medium));
            header.Children.Add(titles);
            DockPanel.SetDock(header, Dock.Top);
            root.Children.Add(header);

            var footer = new DockPanel { Margin = new Thickness(20, 10, 20, 14) };
            var done = new Button { Content = "Done", Style = S("PrimaryButton"), Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
            done.Click += (s, e) => Close();
            clear = new Button { Content = "Clear history", Style = S("GhostButton") };
            clear.Click += (s, e) => { queue.ClearHistory(); Fill(); };
            DockPanel.SetDock(done, Dock.Right);
            DockPanel.SetDock(clear, Dock.Right);
            footer.Children.Add(done);
            footer.Children.Add(clear);
            footer.Children.Add(Text("History is stored only on this PC.", 11.5, B("TextDim")));
            DockPanel.SetDock(footer, Dock.Bottom);
            root.Children.Add(footer);
            root.Children.Add(new Border { Height = 1, Background = B("Hairline"), VerticalAlignment = VerticalAlignment.Bottom });

            root.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(12, 0, 12, 0) });
            Content = root;
            Fill();
        }

        void Fill()
        {
            list.Children.Clear();
            var term = search?.Text ?? "";
            var entries = queue.History.Where(h => term.Length == 0 ||
                (h.Title ?? "").IndexOf(term, StringComparison.CurrentCultureIgnoreCase) >= 0 ||
                (h.Site ?? "").IndexOf(term, StringComparison.CurrentCultureIgnoreCase) >= 0).ToList();
            clear.IsEnabled = queue.History.Count > 0;
            if (entries.Count == 0)
            {
                var empty = new StackPanel { Margin = new Thickness(0, 80, 0, 0) };
                empty.Children.Add(new TextBlock { Text = Icons.Clock, FontFamily = Theme.IconFont, FontSize = 28, Foreground = B("TextDim"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 10) });
                empty.Children.Add(new TextBlock { Text = queue.History.Count == 0 ? "Nothing downloaded yet." : "No matches.", Foreground = B("TextDim"), HorizontalAlignment = HorizontalAlignment.Center });
                list.Children.Add(empty);
                return;
            }
            foreach (var entry in entries.Take(300))
            {
                var row = new DockPanel { Margin = new Thickness(8, 6, 8, 6) };
                row.Children.Add(new TextBlock { Text = entry.Quality.Glyph(), FontFamily = Theme.IconFont, FontSize = 14, Foreground = B("Gold"), Width = 26, VerticalAlignment = VerticalAlignment.Center });
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                bool exists = File.Exists(entry.FilePath);
                var show = new Button { Content = "Show", Style = S("GhostButton"), IsEnabled = exists, ToolTip = exists ? entry.FilePath : "The file was moved or deleted", Margin = new Thickness(8, 0, 0, 0) };
                show.Click += (s, e) => ItemRow.ShowInExplorer(entry.FilePath);
                var again = new Button { Content = "Download again", Style = S("GhostButton"), Margin = new Thickness(8, 0, 0, 0) };
                again.Click += (s, e) => { queue.Redownload(entry); Close(); };
                buttons.Children.Add(show);
                buttons.Children.Add(again);
                DockPanel.SetDock(buttons, Dock.Right);
                row.Children.Add(buttons);
                var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = entry.Title, FontSize = 12.5, Foreground = Brushes.White, TextTrimming = TextTrimming.CharacterEllipsis });
                var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
                if (!string.IsNullOrEmpty(entry.Site))
                {
                    meta.Children.Add(new System.Windows.Shapes.Ellipse { Width = 5, Height = 5, Fill = Theme.Brush(Theme.SiteColor(entry.Site)), Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center });
                    meta.Children.Add(new TrackedText { Text = entry.Site, Mono = true, FontSize = 9, Tracking = 1.4, Foreground = Theme.White(0.6), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
                }
                meta.Children.Add(new TextBlock { Text = entry.Date.ToString("MMM d, yyyy h:mm tt") + " · " + entry.Quality.ShortLabel(), FontSize = 11, Foreground = B("TextDim") });
                text.Children.Add(meta);
                row.Children.Add(text);
                list.Children.Add(new Border { Child = row, BorderBrush = B("Hairline"), BorderThickness = new Thickness(0, 0, 0, 1) });
            }
        }
    }

    public sealed class AboutWindow : CosmosWindow
    {
        static AboutWindow open;

        public static AboutWindow Open(Window owner)
        {
            if (open != null) { open.Activate(); return open; }
            open = new AboutWindow { Owner = owner };
            open.Closed += (s, e) => open = null;
            open.Show();
            return open;
        }

        AboutWindow()
        {
            Title = "About CosmoGrav";
            Width = 520;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;

            var grid = new Grid();
            grid.Children.Add(new Border { Background = B("Space") });
            grid.Children.Add(new Starfield { Count = 110 });
            var glow = new System.Windows.Shapes.Ellipse
            {
                Height = 260, Margin = new Thickness(-120, 0, -120, -190), VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false,
                Fill = new RadialGradientBrush(new GradientStopCollection
                {
                    new GradientStop(Color.FromArgb(56, 237, 194, 135), 0), new GradientStop(Color.FromArgb(20, 179, 117, 61), 0.5), new GradientStop(Colors.Transparent, 1),
                }),
                Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 30 },
            };
            grid.Children.Add(glow);

            var stack = new StackPanel { Margin = new Thickness(44, 30, 44, 30) };
            TextBlock Centered(string text, double size, Brush color, FontWeight? weight = null, double bottom = 0)
            {
                var t = Text(text, size, color, weight);
                t.TextAlignment = TextAlignment.Center;
                t.HorizontalAlignment = HorizontalAlignment.Center;
                t.LineHeight = size * 1.55;
                t.Margin = new Thickness(0, 0, 0, bottom);
                return t;
            }
            TrackedText Label(string text, Brush color, double size = 9.5, double bottom = 8) =>
                new TrackedText { Text = text, Mono = true, FontSize = size, Tracking = 1.8, Foreground = color, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, bottom) };
            FrameworkElement Rule() => new Border
            {
                Width = 220, Height = 1, Margin = new Thickness(0, 22, 0, 22),
                Background = new LinearGradientBrush(new GradientStopCollection { new GradientStop(Colors.Transparent, 0), new GradientStop(Color.FromArgb(115, 237, 194, 135), 0.5), new GradientStop(Colors.Transparent, 1) }, 0),
            };
            var soft = Theme.White(0.75);

            stack.Children.Add(new System.Windows.Shapes.Path
            {
                Data = Theme.Mark, Fill = Brushes.White, Stretch = Stretch.Uniform, Width = 48, Height = 48, Margin = new Thickness(0, 0, 0, 20),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Theme.Gold, BlurRadius = 24, ShadowDepth = 0, Opacity = 0.45 },
            });
            stack.Children.Add(Label("Visual Lab", B("Ember"), 9.5, 8));
            stack.Children.Add(new TrackedText { Text = "Creation of Cosmos", FontSize = 15, FontWeight = FontWeights.Light, Tracking = 4.8, Foreground = Theme.White(0.92), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) });
            stack.Children.Add(Label("Video editing studio · Makati, Philippines", B("TextDim"), 9, 0));
            stack.Children.Add(Rule());
            stack.Children.Add(Label("The Founder", B("Ember")));
            stack.Children.Add(Centered("Raeden Toribio", 20, Brushes.White, FontWeights.Medium, 5));
            stack.Children.Add(Label("Founder · 21 years in the edit suite", Theme.Brush(Theme.Gold, 0.85), 9.5, 16));
            stack.Children.Add(Centered("We believe every creative deserves a way up. We're building a worldwide community where editors and creatives share what they know, lift each other up, and turn their craft into a living.", 12.5, soft, null, 10));
            stack.Children.Add(Centered("From a first timeline to the biggest screens on Earth, we want to help every editor reach the place they've always dreamed of, without spending years learning it alone.", 12.5, soft));
            stack.Children.Add(Rule());
            stack.Children.Add(Label("CosmoGrav · Version " + Updater.CurrentVersion, Theme.Brush(Theme.Gold, 0.8)));
            stack.Children.Add(Centered("Footage from the source to the edit suite, ready for Premiere Pro.", 12.5, soft, null, 18));
            var visit = new Button { Content = "Visit creationofcosmos.com  →", Style = S("PrimaryButton"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 20) };
            visit.Click += (s, e) => MainWindow.OpenWebsite();
            stack.Children.Add(visit);
            stack.Children.Add(Centered("Built on yt-dlp, FFmpeg and Deno.\nPlease only download content you have the rights to use.", 10.5, B("TextDim")));
            grid.Children.Add(stack);
            Content = grid;
        }
    }

    /// A two-button question in the app's style ("Keep downloading" / "Close anyway"). Returns true for the first button.
    public sealed class CosmosDialog : CosmosWindow
    {
        bool first;

        public static bool Ask(Window owner, string title, string message, string firstButton, string secondButton)
        {
            var dialog = new CosmosDialog(title, message, firstButton, secondButton) { Owner = owner };
            dialog.ShowDialog();
            return dialog.first;
        }

        CosmosDialog(string title, string message, string firstButton, string secondButton)
        {
            Title = "CosmoGrav";
            Width = 420;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            var stack = new StackPanel { Margin = new Thickness(24, 22, 24, 20) };
            stack.Children.Add(Text(title, 16, Brushes.White, FontWeights.Medium));
            var body = Text(message, 12.5, B("TextDim"));
            body.Margin = new Thickness(0, 8, 0, 20);
            stack.Children.Add(body);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            var second = new Button { Content = secondButton, Style = S("GhostButton"), Margin = new Thickness(0, 0, 8, 0) };
            second.Click += (s, e) => { first = false; Close(); };
            var primary = new Button { Content = firstButton, Style = S("PrimaryButton"), IsDefault = true };
            primary.Click += (s, e) => { first = true; Close(); };
            buttons.Children.Add(second);
            buttons.Children.Add(primary);
            stack.Children.Add(buttons);
            Content = stack;
            first = true; // Closing the dialog with X or Esc keeps downloading.
        }
    }
}
