using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CosmoGrav
{
    public partial class ItemRow : UserControl
    {
        public DownloadItem Item { get; }
        readonly QueueManager queue;
        string loadedThumbnail;
        bool hovering;

        public ItemRow(DownloadItem item, QueueManager queue)
        {
            InitializeComponent();
            Item = item;
            this.queue = queue;
            DataContext = item;
            NameField.SetBinding(TextBox.TextProperty, new Binding(nameof(DownloadItem.FileName)) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            item.PropertyChanged += ItemChanged;
            queue.Settings.PropertyChanged += SettingsChanged;
            Unloaded += (s, e) => { item.PropertyChanged -= ItemChanged; queue.Settings.PropertyChanged -= SettingsChanged; };
            Loaded += (s, e) =>
            {
                item.PropertyChanged -= ItemChanged;
                item.PropertyChanged += ItemChanged;
                queue.Settings.PropertyChanged -= SettingsChanged;
                queue.Settings.PropertyChanged += SettingsChanged;
                Refresh();
            };
            MouseEnter += (s, e) => { hovering = true; RefreshHover(); };
            MouseLeave += (s, e) => { hovering = false; RefreshHover(); };
            ContextMenu = BuildContextMenu();
            Refresh();
        }

        void ItemChanged(object sender, PropertyChangedEventArgs e)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(Refresh)); return; }
            if (e.PropertyName == nameof(DownloadItem.Progress)) RefreshProgress();
            else if (e.PropertyName != nameof(DownloadItem.FileName)) Refresh();
        }

        void SettingsChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(AppSettings.LoginBrowser)) Refresh();
        }

        // MARK: Drawing the row for the item's state

        void Refresh()
        {
            var state = Item.State;

            // Site + title
            SitePanel.Visibility = string.IsNullOrEmpty(Item.Site) ? Visibility.Collapsed : Visibility.Visible;
            SiteDot.Fill = Theme.Brush(Theme.SiteColor(Item.Site));
            SiteText.Text = Item.Site ?? "";
            TitleText.Text = Item.Title;
            TitleText.ToolTip = Item.Url;

            // Thumbnail
            ThumbGlyph.Text = Item.Quality.Glyph();
            bool fetching = state == ItemState.Fetching;
            ThumbOrb.Visibility = fetching && Item.Thumbnail == null ? Visibility.Visible : Visibility.Collapsed;
            ThumbGlyph.Visibility = ThumbOrb.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            LoadThumbnail();
            DurationPill.Visibility = Item.Duration.HasValue ? Visibility.Visible : Visibility.Collapsed;
            if (Item.Duration.HasValue) DurationText.Text = TimeFormat.ToText(Item.Duration.Value);

            // Name
            bool canEdit = state.CanEdit();
            NameField.IsReadOnly = !canEdit;
            NameField.Foreground = canEdit ? Brushes.White : Theme.White(0.6);
            NameBox.Background = Theme.White(canEdit ? 0.05 : 0.02);
            ExtText.Text = "." + Item.Quality.FileExtension();

            // Options
            QualityGlyph.Text = Item.Quality.Glyph();
            QualityText.Text = Item.Quality.ShortLabel();
            QualityButton.IsEnabled = canEdit;
            TrimButton.IsEnabled = canEdit;
            TrimText.Text = Item.TrimLabel ?? "Trim";
            TrimButton.Foreground = Item.IsTrimmed ? (Brush)FindResource("Gold") : (Brush)FindResource("TextDim");
            Chips.Children.Clear();
            if (Item.Resolution != null && !Item.Quality.IsAudio())
            {
                var res = Item.Quality == Quality.Hd1080 && (Item.Resolution == "4K" || Item.Resolution == "8K" || Item.Resolution == "1440p") ? "1080p" : Item.Resolution;
                Chips.Children.Add(Ui.Chip(res, null, Theme.Gold));
            }
            if (Item.Quality.OutputBadge() is string badge) Chips.Children.Add(Ui.Chip(badge, Icons.CheckSeal, Color.FromArgb(140, 255, 255, 255)));
            if (Item.UseLogin) Chips.Children.Add(Ui.Chip("Using " + queue.Settings.LoginBrowserName + " login", Icons.Person, Theme.Ember));

            // Status
            ProgressPanel.Visibility = state.IsActive() ? Visibility.Visible : Visibility.Collapsed;
            FailedPanel.Visibility = state == ItemState.Failed ? Visibility.Visible : Visibility.Collapsed;
            DonePanel.Visibility = state == ItemState.Done ? Visibility.Visible : Visibility.Collapsed;
            DetailText.Visibility = !state.IsActive() && state != ItemState.Failed && state != ItemState.Done ? Visibility.Visible : Visibility.Collapsed;
            DetailText.Text = Item.Detail;
            DoneText.Text = Item.Detail;
            ErrorText.Text = Item.ErrorMessage ?? "Something went wrong.";
            bool askLogin = Item.NeedsLogin && !Item.UseLogin;
            LoginHint.Visibility = askLogin ? Visibility.Visible : Visibility.Collapsed;
            LoginButton.Content = queue.Settings.LoginBrowser == "none" ? "Choose a browser login…" : "Use my " + queue.Settings.LoginBrowserName + " login";
            RefreshProgress();

            // Border and glow
            Card.BorderBrush = state == ItemState.Failed ? Theme.Brush(Theme.Danger, 0.35)
                : state == ItemState.Done ? Theme.Brush(Theme.Gold, 0.22)
                : state.IsActive() ? Theme.Brush(Theme.Gold, 0.4)
                : (Brush)FindResource("Hairline");
            ActiveGlow.Opacity = state.IsActive() ? 0.12 : 0;

            // Actions
            MainAction.Visibility = Visibility.Visible;
            CancelRing.Visibility = Visibility.Collapsed;
            FetchOrb.Visibility = Visibility.Collapsed;
            MainAction.Foreground = (Brush)FindResource("Gold");
            MainAction.BorderBrush = Theme.Brush(Theme.Gold, 0.4);
            switch (state)
            {
                case ItemState.Ready:
                case ItemState.Cancelled:
                    MainAction.Content = Icons.Download; MainAction.ToolTip = "Download"; break;
                case ItemState.Failed:
                    MainAction.Content = Icons.Retry; MainAction.ToolTip = "Try again"; break;
                case ItemState.Downloading:
                case ItemState.Converting:
                    MainAction.Visibility = Visibility.Collapsed; CancelRing.Visibility = Visibility.Visible; break;
                case ItemState.Queued:
                    MainAction.Content = Icons.Close; MainAction.ToolTip = "Cancel";
                    MainAction.Foreground = (Brush)FindResource("TextDim");
                    MainAction.BorderBrush = Theme.White(0.25);
                    break;
                case ItemState.Done:
                    MainAction.Content = Icons.FolderOpen; MainAction.ToolTip = "Show in File Explorer"; break;
                case ItemState.Fetching:
                    MainAction.Visibility = Visibility.Collapsed; FetchOrb.Visibility = Visibility.Visible; break;
            }
            RemoveButton.Visibility = !state.IsActive() && state != ItemState.Queued ? Visibility.Visible : Visibility.Collapsed;
            RefreshHover();
        }

        void RefreshProgress()
        {
            Bar.Progress = Item.Progress;
            CancelRing.Tag = Item.Progress;
            ProgressText.Text = Item.Detail;
        }

        void RefreshHover()
        {
            Card.Background = hovering ? (Brush)FindResource("CardHover") : (Brush)FindResource("Card");
            RemoveButton.Opacity = hovering ? 1 : 0.35;
        }

        void LoadThumbnail()
        {
            var url = Item.Thumbnail;
            if (url == loadedThumbnail) return;
            loadedThumbnail = url;
            ThumbImageFrame.Visibility = Visibility.Collapsed;
            if (string.IsNullOrEmpty(url)) return;
            try
            {
                var image = new BitmapImage();
                image.BeginInit();
                image.UriSource = new Uri(url);
                image.DecodePixelWidth = 272;
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.EndInit();
                image.DownloadCompleted += (s, e) => { if (loadedThumbnail == url) ThumbImageFrame.Visibility = Visibility.Visible; };
                image.DownloadFailed += (s, e) => { };
                image.DecodeFailed += (s, e) => { };
                ThumbImage.ImageSource = image;
                if (!image.IsDownloading) ThumbImageFrame.Visibility = Visibility.Visible;
            }
            catch { }
        }

        // MARK: Actions

        void MainAction_Click(object sender, RoutedEventArgs e)
        {
            switch (Item.State)
            {
                case ItemState.Ready:
                case ItemState.Cancelled: queue.Start(Item); break;
                case ItemState.Failed: queue.Retry(Item); break;
                case ItemState.Queued: queue.Cancel(Item); break;
                case ItemState.Done: ShowInExplorer(Item.OutputPath); break;
            }
        }

        void Cancel_Click(object sender, RoutedEventArgs e) => queue.Cancel(Item);
        void Remove_Click(object sender, RoutedEventArgs e) => queue.Remove(Item);

        void LoginButton_Click(object sender, RoutedEventArgs e)
        {
            if (queue.Settings.LoginBrowser == "none") SettingsWindow.Open(Window.GetWindow(this));
            else queue.Retry(Item, withLogin: true);
        }

        public static void ShowInExplorer(string path)
        {
            if (string.IsNullOrEmpty(path)) return;
            try { Process.Start("explorer.exe", "/select," + Runner.Quote(path)); } catch { }
        }

        ContextMenu BuildContextMenu()
        {
            var menu = new ContextMenu();
            var copy = new MenuItem { Header = "Copy link" };
            copy.Click += (s, e) => { try { Clipboard.SetText(Item.Url); } catch { } };
            var show = new MenuItem { Header = "Show in File Explorer" };
            show.Click += (s, e) => ShowInExplorer(Item.OutputPath);
            var remove = new MenuItem { Header = "Remove" };
            remove.Click += (s, e) => queue.Remove(Item);
            menu.Items.Add(copy);
            menu.Items.Add(show);
            menu.Items.Add(new Separator());
            menu.Items.Add(remove);
            menu.Opened += (s, e) => show.IsEnabled = Item.OutputPath != null;
            return menu;
        }

        // MARK: Quality menu

        public ContextMenu QualityMenu { get; private set; }

        void QualityButton_Click(object sender, RoutedEventArgs e) => OpenQualityMenu();

        public void OpenQualityMenu()
        {
            var menu = new ContextMenu { PlacementTarget = QualityButton, Placement = PlacementMode.Bottom };
            foreach (var quality in QualityInfo.All)
            {
                var entry = new MenuItem { Header = quality.Label(), IsChecked = quality == Item.Quality };
                var q = quality;
                entry.Click += (s, args) => SetQuality(q);
                menu.Items.Add(entry);
            }
            QualityMenu = menu;
            menu.IsOpen = true;
        }

        void SetQuality(Quality quality)
        {
            if (quality == Item.Quality) return;
            Item.Quality = quality;
            // Formats depend on the quality, so look the link up again for accurate size and resolution.
            if (Item.InfoLoaded) queue.FetchInfo(Item);
        }

        // MARK: Trim

        public Popup TrimPopup { get; private set; }

        void TrimButton_Click(object sender, RoutedEventArgs e) => OpenTrim();

        public void OpenTrim(string presetStart = null, string presetEnd = null)
        {
            var startBox = new TextBox { Style = (Style)FindResource("FieldTextBox"), Width = 120, FontFamily = Theme.Mono };
            var endBox = new TextBox { Style = (Style)FindResource("FieldTextBox"), Width = 120, FontFamily = Theme.Mono };
            startBox.Text = presetStart ?? (Item.TrimStart.HasValue ? TimeFormat.ToText(Item.TrimStart.Value) : "");
            endBox.Text = presetEnd ?? (Item.TrimEnd.HasValue ? TimeFormat.ToText(Item.TrimEnd.Value) : "");
            var error = new TextBlock { Foreground = (Brush)FindResource("Danger"), FontSize = 11.5, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap };

            var popup = new Popup
            {
                PlacementTarget = TrimButton, Placement = PlacementMode.Bottom, StaysOpen = false,
                AllowsTransparency = true, PopupAnimation = PopupAnimation.Fade, VerticalOffset = 6,
            };

            void Apply()
            {
                var startEmpty = startBox.Text.Trim().Length == 0;
                var endEmpty = endBox.Text.Trim().Length == 0;
                var start = startEmpty ? null : TimeFormat.Parse(startBox.Text);
                var end = endEmpty ? null : TimeFormat.Parse(endBox.Text);
                string problem = null;
                if ((!startEmpty && start == null) || (!endEmpty && end == null)) problem = "Use a time like 1:30 or 1:02:30.";
                else if (start.HasValue && end.HasValue && end <= start) problem = "End must be after Start.";
                else if (Item.Duration.HasValue && start.HasValue && start >= Item.Duration) problem = "Start is past the end of the video.";
                if (problem != null)
                {
                    error.Text = problem;
                    error.Visibility = Visibility.Visible;
                    return;
                }
                Item.TrimStart = (start ?? 0) > 0 ? start : null;
                Item.TrimEnd = end;
                if (Item.Duration.HasValue && end.HasValue && end >= Item.Duration) Item.TrimEnd = null;
                popup.IsOpen = false;
            }

            var apply = new Button { Content = "Apply", Style = (Style)FindResource("PrimaryButton"), IsDefault = true, Margin = new Thickness(8, 0, 0, 0) };
            apply.Click += (s, e) => Apply();
            var cancel = new Button { Content = "Cancel", Style = (Style)FindResource("GhostButton"), Margin = new Thickness(8, 0, 0, 0) };
            cancel.Click += (s, e) => popup.IsOpen = false;
            var clear = new Button { Content = "Remove trim", Style = (Style)FindResource("LinkButton"), IsEnabled = Item.IsTrimmed, VerticalAlignment = VerticalAlignment.Center };
            clear.Click += (s, e) => { Item.TrimStart = null; Item.TrimEnd = null; popup.IsOpen = false; };
            startBox.KeyDown += (s, e) => { if (e.Key == Key.Enter) Apply(); else if (e.Key == Key.Escape) popup.IsOpen = false; };
            endBox.KeyDown += (s, e) => { if (e.Key == Key.Enter) Apply(); else if (e.Key == Key.Escape) popup.IsOpen = false; };

            FrameworkElement Field(string title, TextBox box, string placeholder)
            {
                var panel = new StackPanel { Margin = new Thickness(0, 0, 12, 0) };
                panel.Children.Add(new TextBlock { Text = title, FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = (Brush)FindResource("TextDim"), Margin = new Thickness(0, 0, 0, 4) });
                var grid = new Grid();
                var hint = new TextBlock { Text = placeholder, FontFamily = Theme.Mono, FontSize = 13, Foreground = Theme.White(0.3), Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
                box.TextChanged += (s, e) => hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
                hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
                grid.Children.Add(box);
                grid.Children.Add(hint);
                panel.Children.Add(grid);
                return panel;
            }

            var body = new StackPanel { Width = 290 };
            body.Children.Add(new TrackedText { Text = "Trim", Mono = true, FontSize = 9.5, Tracking = 2.2, Foreground = (Brush)FindResource("Ember"), Margin = new Thickness(0, 0, 0, 10), HorizontalAlignment = HorizontalAlignment.Left });
            body.Children.Add(new TextBlock
            {
                Text = "Keep only part of the video. Use minutes:seconds, like 1:30. Leave End empty to keep everything after Start.",
                FontSize = 11.5, Foreground = (Brush)FindResource("TextDim"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12), LineHeight = 17,
            });
            var fields = new StackPanel { Orientation = Orientation.Horizontal };
            fields.Children.Add(Field("Start", startBox, "0:00"));
            fields.Children.Add(Field("End", endBox, Item.Duration.HasValue ? TimeFormat.ToText(Item.Duration.Value) : "end"));
            body.Children.Add(fields);
            if (Item.Duration.HasValue)
                body.Children.Add(new TextBlock { Text = "Full length: " + TimeFormat.ToText(Item.Duration.Value), FontSize = 11.5, Foreground = (Brush)FindResource("TextDim"), Margin = new Thickness(0, 8, 0, 0) });
            body.Children.Add(error);
            var buttons = new DockPanel { Margin = new Thickness(0, 14, 0, 0), LastChildFill = false };
            DockPanel.SetDock(clear, Dock.Left);
            buttons.Children.Add(clear);
            DockPanel.SetDock(apply, Dock.Right);
            DockPanel.SetDock(cancel, Dock.Right);
            buttons.Children.Add(apply);
            buttons.Children.Add(cancel);
            body.Children.Add(buttons);

            var frame = new Border
            {
                Background = (Brush)FindResource("Popup"),
                BorderBrush = Theme.White(0.18),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(16),
                Margin = new Thickness(0, 0, 16, 16),
                Child = body,
            };
            TextElement.SetFontFamily(frame, Theme.Ui);
            TextElement.SetForeground(frame, Brushes.White);
            frame.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Opacity = 0.6, Color = Colors.Black };
            popup.Child = frame;
            popup.Opened += (s, e) => { startBox.Focus(); Keyboard.Focus(startBox); };
            TrimPopup = popup;
            popup.IsOpen = true;
        }
    }

    /// Small shared pieces of UI built in code.
    static class Ui
    {
        public static FrameworkElement Chip(string text, string glyph, Color tint)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            if (glyph != null)
                row.Children.Add(new TextBlock { Text = glyph, FontFamily = Theme.IconFont, FontSize = 8.5, Foreground = Theme.Brush(tint), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) });
            row.Children.Add(new TrackedText { Text = text, Mono = true, FontSize = 9.5, Tracking = 1, Foreground = Theme.Brush(tint), VerticalAlignment = VerticalAlignment.Center });
            return new Border
            {
                Child = row,
                Padding = new Thickness(7, 3, 7, 3),
                Margin = new Thickness(0, 0, 6, 0),
                CornerRadius = new CornerRadius(999),
                BorderThickness = new Thickness(1),
                BorderBrush = Theme.Brush(tint, 0.3),
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        /// A small ember mono label, wide-tracked and all caps.
        public static TrackedText Eyebrow(string text, Brush tint = null) =>
            new TrackedText { Text = text, Mono = true, FontSize = 9.5, Tracking = 2.2, Foreground = tint ?? (Brush)Application.Current.FindResource("Ember") };
    }
}
