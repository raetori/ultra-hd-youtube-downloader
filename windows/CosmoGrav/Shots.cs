using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CosmoGrav
{
    public static class DemoData
    {
        /// Sample rows in every state, so the design can be checked without touching the network.
        public static void LoadDemo(this QueueManager queue, string thumbnails = null)
        {
            DownloadItem Make(string title, string site, double duration, string resolution, Quality quality,
                              ItemState state, double progress, string detail, int thumb)
            {
                var item = new DownloadItem("https://example.com/" + Math.Abs(title.GetHashCode()), quality, title)
                {
                    Site = site, Duration = duration, Resolution = resolution, State = state, Progress = progress, Detail = detail,
                };
                item.InfoLoaded = true;
                if (thumbnails != null) item.Thumbnail = new Uri(Path.Combine(thumbnails, $"thumb{thumb}.png")).AbsoluteUri;
                return item;
            }
            var trimmed = Make("Interstellar docking scene reference", "YouTube", 241, "4K", Quality.Best, ItemState.Ready, 0, "Ready · about 820 MB", 3);
            trimmed.TrimStart = 61;
            trimmed.TrimEnd = 94;
            var done = Make("Night drive b-roll", "TikTok", 27, "1080p", Quality.ProRes, ItemState.Done, 1, "Saved to Downloads", 4);
            done.OutputPath = Path.Combine(KnownFolders.Downloads, "Night drive b-roll.mov");
            foreach (var item in new[]
            {
                trimmed,
                Make("Creation of Cosmos launch film", "YouTube", 152, "4K", Quality.Best, ItemState.Downloading, 0.62, "62% · 14.2 MB/s · 0:09 left", 1),
                Make("Behind the cut: Makati studio session", "Instagram", 48, "1080p", Quality.Hd1080, ItemState.Converting, 0.35, "Making it Premiere-ready · 35%", 2),
                done,
                Make("Client brief voice memo", "Facebook", 95, "720p", Quality.Wav, ItemState.Queued, 0, "Waiting for a free slot", 5),
            })
                queue.Items.Add(item);
        }
    }

    /// Photographs every screen of the app for the website's step-by-step guide:
    /// `CosmoGrav.exe --shots FOLDER`. Popups (menus, the trim box) are drawn onto the window picture.
    static class Shots
    {
        const double Scale = 2;

        public static async void Run(MainWindow window, string folder)
        {
            Directory.CreateDirectory(folder);
            var log = new List<string>();
            try
            {
                var thumbs = Path.Combine(folder, "_thumbs");
                Directory.CreateDirectory(thumbs);
                for (int i = 1; i <= 5; i++) SaveThumbnail(Path.Combine(thumbs, $"thumb{i}.png"), i);

                window.Width = 960;
                window.Height = 720;
                window.WindowStartupLocation = WindowStartupLocation.Manual;
                window.Left = 40;
                window.Top = 40;
                window.Show();
                window.Activate();
                var queue = window.Queue;
                queue.ToolsMissing = false;
                await Wait(1500);

                // 1. The empty window, right after opening.
                await Save(window, folder, "01-open-the-app.png");

                // 2. A link was copied in the browser: the app offers it.
                queue.ClipboardLinks = new List<string> { "https://www.youtube.com/watch?v=3OMLs3yI-KE" };
                await Wait(900);
                await Save(window, folder, "02-copied-link-offer.png");
                queue.ClipboardLinks = new List<string>();

                // 3. The queue with videos in every state.
                queue.LoadDemo(thumbs);
                await Wait(1500);
                await Save(window, folder, "03-queue.png");

                // 4. Picking a quality for one video.
                var trimmedRow = window.RowFor(queue.Items[0]);
                trimmedRow.BringIntoView();
                await Wait(400);
                trimmedRow.OpenQualityMenu();
                await Wait(900);
                await Save(window, folder, "04-pick-quality.png", trimmedRow.QualityMenu);
                trimmedRow.QualityMenu.IsOpen = false;
                await Wait(400);

                // 5. Trimming a video.
                trimmedRow.OpenTrim("1:01", "1:34");
                await Wait(900);
                await Save(window, folder, "05-trim.png", trimmedRow.TrimPopup);
                trimmedRow.TrimPopup.IsOpen = false;
                await Wait(400);

                // 6. The default quality list in the options bar.
                window.QualityPicker.IsDropDownOpen = true;
                await Wait(900);
                var popup = window.QualityPicker.Template.FindName("PART_Popup", window.QualityPicker) as Popup;
                await Save(window, folder, "06-default-quality.png", popup);
                window.QualityPicker.IsDropDownOpen = false;
                await Wait(400);

                // 7. An update is available.
                window.Updater.AvailableVersion = "1.4.0";
                await Wait(900);
                await Save(window, folder, "07-update-available.png");
                window.Updater.AvailableVersion = null;

                // 8. Settings.
                var settings = SettingsWindow.Open(window);
                settings.Left = 80;
                settings.Top = 40;
                await Wait(1200);
                await Save(settings, folder, "08-settings.png", target: (FrameworkElement)settings.Scroller.Content);
                settings.Close();

                // 9. History (sample entries, not saved).
                var saved = queue.History;
                queue.ShowHistoryForScreenshots(new List<HistoryEntry>
                {
                    new HistoryEntry { Title = "Night drive b-roll", Url = "https://example.com/1", Site = "TikTok", FilePath = "", Quality = Quality.ProRes, Date = DateTime.Now.AddMinutes(-12) },
                    new HistoryEntry { Title = "Creation of Cosmos launch film", Url = "https://example.com/2", Site = "YouTube", FilePath = "", Quality = Quality.Best, Date = DateTime.Now.AddHours(-3) },
                    new HistoryEntry { Title = "Behind the cut: Makati studio session", Url = "https://example.com/3", Site = "Instagram", FilePath = "", Quality = Quality.Hd1080, Date = DateTime.Now.AddDays(-1) },
                    new HistoryEntry { Title = "Client brief voice memo", Url = "https://example.com/4", Site = "Facebook", FilePath = "", Quality = Quality.Wav, Date = DateTime.Now.AddDays(-2) },
                });
                var history = HistoryWindow.Open(window);
                await Wait(1200);
                await Save(history, folder, "09-history.png");
                history.Close();
                queue.ShowHistoryForScreenshots(saved);

                // 10. About.
                var about = AboutWindow.Open(window);
                await Wait(1500);
                await Save(about, folder, "10-about.png");
                about.Close();

                // 11. The setup window someone sees after downloading CosmoGrav-Setup.exe.
                var setup = new SetupWindow { WindowStartupLocation = WindowStartupLocation.Manual, Left = 80, Top = 40 };
                setup.Show();
                await Wait(1500);
                await Save(setup, folder, "11-windows-setup.png");
                setup.Close();

                try { Directory.Delete(thumbs, true); } catch { }
                log.Add("SHOTS OK");
            }
            catch (Exception error)
            {
                log.Add("SHOTS FAILED " + error);
            }
            File.WriteAllLines(Path.Combine(folder, "shots.txt"), log);
            App.QuitWithoutAsking();
        }

        static Task Wait(int ms) => Task.Delay(ms);

        /// Draws the window's content (and any open popup) into a PNG at twice the size, for sharp pictures.
        static async Task Save(Window window, string folder, string name, object popupOwner = null, FrameworkElement target = null)
        {
            await window.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            // A target inside a scroll area (Settings) is drawn whole, with the window's margins around it.
            if (target != null)
            {
                var m = target.Margin;
                var pad = new Border { Background = window.Background, Padding = m, Child = new Image { Source = Render(target), Width = target.ActualWidth, Height = target.ActualHeight } };
                pad.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                pad.Arrange(new Rect(pad.DesiredSize));
                pad.UpdateLayout();
                SavePng(Render(pad), Path.Combine(folder, name));
                return;
            }
            var content = (FrameworkElement)window.Content;
            int w = (int)Math.Ceiling(content.ActualWidth * Scale), h = (int)Math.Ceiling(content.ActualHeight * Scale);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(window.Background, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
                dc.DrawImage(Render(content), new Rect(0, 0, content.ActualWidth, content.ActualHeight));
                var popupRoot = PopupRoot(popupOwner);
                if (popupRoot != null)
                {
                    var origin = content.PointToScreen(new Point(0, 0));
                    var at = popupRoot.PointToScreen(new Point(0, 0));
                    var dpi = VisualTreeHelper.GetDpi(content);
                    var offset = new Point((at.X - origin.X) / dpi.DpiScaleX, (at.Y - origin.Y) / dpi.DpiScaleY);
                    dc.DrawImage(Render(popupRoot), new Rect(offset, new Size(popupRoot.ActualWidth, popupRoot.ActualHeight)));
                }
            }
            var bitmap = new RenderTargetBitmap(w, h, 96 * Scale, 96 * Scale, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            SavePng(bitmap, Path.Combine(folder, name));
        }

        static void SavePng(BitmapSource bitmap, string path)
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(path)) encoder.Save(file);
        }

        static FrameworkElement PopupRoot(object owner)
        {
            Visual inner = null;
            if (owner is Popup popup && popup.IsOpen) inner = popup.Child;
            else if (owner is ContextMenu menu && menu.IsOpen) inner = menu;
            if (inner == null) return null;
            return PresentationSource.FromVisual(inner)?.RootVisual as FrameworkElement ?? inner as FrameworkElement;
        }

        static BitmapSource Render(FrameworkElement element)
        {
            int w = Math.Max(1, (int)Math.Ceiling(element.ActualWidth * Scale)), h = Math.Max(1, (int)Math.Ceiling(element.ActualHeight * Scale));
            var bitmap = new RenderTargetBitmap(w, h, 96 * Scale, 96 * Scale, PixelFormats.Pbgra32);
            // Render through a brush so the element's own position in its parent doesn't shift the picture.
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
                dc.DrawRectangle(new VisualBrush(element)
                {
                    // Map the element's own 0,0..width,height exactly, ignoring glows that spill past its edges.
                    ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, element.ActualWidth, element.ActualHeight), Stretch = Stretch.Fill,
                },
                                 null, new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            bitmap.Render(visual);
            return bitmap;
        }

        /// Stand-in thumbnails for the sample rows: soft cosmic gradients in the app's palette.
        static void SaveThumbnail(string path, int seed)
        {
            var palettes = new[]
            {
                (Color.FromRgb(18, 10, 6), Color.FromRgb(237, 194, 135)),
                (Color.FromRgb(6, 10, 22), Color.FromRgb(120, 160, 240)),
                (Color.FromRgb(16, 6, 14), Color.FromRgb(235, 115, 173)),
                (Color.FromRgb(4, 14, 16), Color.FromRgb(89, 217, 217)),
                (Color.FromRgb(20, 8, 4), Color.FromRgb(242, 143, 77)),
            };
            var (dark, light) = palettes[(seed - 1) % palettes.Length];
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(new SolidColorBrush(dark), null, new Rect(0, 0, 320, 180));
                var glow = new RadialGradientBrush(Color.FromArgb(220, light.R, light.G, light.B), Color.FromArgb(0, light.R, light.G, light.B))
                {
                    Center = new Point(0.3 + 0.1 * seed % 0.5, 0.75), GradientOrigin = new Point(0.3 + 0.1 * seed % 0.5, 0.75), RadiusX = 0.8, RadiusY = 0.7,
                };
                dc.DrawRectangle(glow, null, new Rect(0, 0, 320, 180));
                var rng = new Random(seed);
                for (int i = 0; i < 60; i++)
                    dc.DrawEllipse(new SolidColorBrush(Color.FromArgb((byte)rng.Next(60, 200), 255, 255, 255)), null,
                                   new Point(rng.NextDouble() * 320, rng.NextDouble() * 120), 0.6 + rng.NextDouble(), 0.6 + rng.NextDouble());
                dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(230, 0, 0, 0)), new Pen(new SolidColorBrush(light), 1.5),
                               new Point(200 + seed * 7, 92), 26, 26);
            }
            var bitmap = new RenderTargetBitmap(320, 180, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(path)) encoder.Save(file);
        }
    }
}
