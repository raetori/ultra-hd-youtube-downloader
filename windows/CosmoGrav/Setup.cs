using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CosmoGrav
{
    /// CosmoGrav-Setup.exe is the app itself. Opened from anywhere other than its installed folder, it shows this
    /// window and installs itself with the same steps as the one-line PowerShell installer (install.ps1, built in).
    public static class Setup
    {
        static readonly string InstalledExe = Path.Combine(Tools.Base, "app", "CosmoGrav.exe");

        /// True when this copy was opened from a download rather than from the installed app folder.
        public static bool IsNeeded =>
            !string.Equals(Path.GetFullPath(ExePath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

        static string ExePath => Process.GetCurrentProcess().MainModule.FileName;

        /// Runs the built-in installer and reports each line it prints. Returns null when it worked, or the reason it didn't.
        public static async Task<string> Install(Action<string> onLine)
        {
            var dir = Path.Combine(Path.GetTempPath(), "cosmograv-setup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var script = Path.Combine(dir, "install.ps1");
            try
            {
                using (var stream = typeof(Setup).Assembly.GetManifestResourceStream("install.ps1"))
                using (var file = File.Create(script))
                    stream.CopyTo(file);

                var powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                var info = new ProcessStartInfo(powershell, $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{script}\"")
                {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                };
                info.EnvironmentVariables["COSMOGRAV_GUI"] = "1";
                info.EnvironmentVariables["COSMOGRAV_EXE"] = ExePath;
                info.EnvironmentVariables["COSMOGRAV_SETUP_PID"] = Process.GetCurrentProcess().Id.ToString();

                string failure = null;
                bool done = false;
                void Line(string line)
                {
                    if (string.IsNullOrWhiteSpace(line)) return;
                    line = line.Trim();
                    if (line.StartsWith("Setup failed:")) failure = line.Substring(13).Trim();
                    if (line == "All set!") done = true;
                    onLine?.Invoke(line);
                }
                await Task.Run(() =>
                {
                    using (var p = Process.Start(info))
                    {
                        p.OutputDataReceived += (s, e) => Line(e.Data);
                        p.ErrorDataReceived += (s, e) => { };
                        p.BeginOutputReadLine();
                        p.BeginErrorReadLine();
                        p.WaitForExit();
                    }
                });
                if (done && failure == null) return null;
                return failure ?? "the installer stopped before it finished.";
            }
            catch (Exception error)
            {
                return error.Message;
            }
            finally
            {
                try { Directory.Delete(dir, true); } catch { }
            }
        }

        /// Headless install used by the build machine: CosmoGrav-Setup.exe --install [--log FILE]. Exit code 0 when it worked.
        public static async void RunHeadless(string log)
        {
            var lines = new List<string>();
            var failure = await Install(lines.Add);
            lines.Add(failure == null ? "SETUP OK" : "SETUP FAILED " + failure);
            if (log != null) File.WriteAllLines(log, lines);
            Application.Current.Shutdown(failure == null ? 0 : 1);
        }
    }

    public sealed class SetupWindow : CosmosWindow
    {
        readonly OrbRing ring = new OrbRing { Width = 64, Height = 64, LineWidth = 1.4, Progress = 0, Margin = new Thickness(0, 4, 0, 18), HorizontalAlignment = HorizontalAlignment.Center };
        readonly TextBlock status;
        readonly Button install;

        public SetupWindow()
        {
            Title = "CosmoGrav Setup";
            Width = 480;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.CanMinimize;
            ShowInTaskbar = true;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;

            var grid = new Grid();
            grid.Children.Add(new Border { Background = B("Space") });
            grid.Children.Add(new Starfield { Count = 90 });

            var stack = new StackPanel { Margin = new Thickness(44, 32, 44, 28) };
            TextBlock Centered(string text, double size, Brush color, double bottom = 0)
            {
                var t = Text(text, size, color);
                t.TextAlignment = TextAlignment.Center;
                t.HorizontalAlignment = HorizontalAlignment.Center;
                t.LineHeight = size * 1.5;
                t.Margin = new Thickness(0, 0, 0, bottom);
                return t;
            }

            stack.Children.Add(new System.Windows.Shapes.Path
            {
                Data = Theme.Mark, Fill = Brushes.White, Stretch = Stretch.Uniform, Width = 44, Height = 44, Margin = new Thickness(0, 0, 0, 16),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Theme.Gold, BlurRadius = 24, ShadowDepth = 0, Opacity = 0.45 },
            });
            stack.Children.Add(new TrackedText { Text = "CosmoGrav", FontSize = 22, FontWeight = FontWeights.Light, Tracking = 5, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) });
            stack.Children.Add(new TrackedText { Text = "Version " + Updater.CurrentVersion, Mono = true, FontSize = 9.5, Tracking = 1.8, Foreground = Theme.Brush(Theme.Gold, 0.8), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 14) });
            stack.Children.Add(Centered("Download videos as Premiere-ready MP4 files.", 13, Theme.White(0.8), 22));
            stack.Children.Add(ring);
            status = Centered("Installs for you only, with no admin password.\nAbout 200 MB, takes 1 to 3 minutes.", 12, B("TextDim"), 20);
            stack.Children.Add(status);
            install = new Button { Content = "Install CosmoGrav  →", Style = S("PrimaryButton"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 22) };
            install.Click += async (s, e) => await Run();
            stack.Children.Add(install);
            stack.Children.Add(Centered("By Creation of Cosmos · creationofcosmos.com\nPlease only download content you have the rights to use.", 10.5, B("TextDim")));
            grid.Children.Add(stack);
            Content = grid;
        }

        async Task Run()
        {
            install.IsEnabled = false;
            install.Content = "Installing…";
            status.Foreground = Theme.White(0.8);
            status.Text = "Getting ready…";
            ring.Progress = 0.04;
            var failure = await Setup.Install(line => Dispatcher.Invoke(() => Show(line)));
            if (failure == null)
            {
                ring.Progress = 1;
                status.Text = "All set! CosmoGrav is opening now.\nIt's in your Start menu and on your desktop.";
                install.Content = "Done";
                await Task.Delay(3500);
                Close();
                return;
            }
            ring.Progress = 0;
            status.Foreground = B("Ember");
            status.Text = "Setup didn't finish: " + failure;
            install.Content = "Try again  →";
            install.IsEnabled = true;
        }

        void Show(string line)
        {
            // The installer's steps, in plain words.
            if (line.StartsWith("1/4")) { ring.Progress = 0.1; status.Text = "Step 1 of 4 · Getting the download engine…"; }
            else if (line.StartsWith("2/4")) { ring.Progress = 0.3; status.Text = "Step 2 of 4 · Getting the video converter (about 150 MB)…"; }
            else if (line.StartsWith("3/4")) { ring.Progress = 0.7; status.Text = "Step 3 of 4 · Getting YouTube support…"; }
            else if (line.StartsWith("4/4")) { ring.Progress = 0.88; status.Text = "Step 4 of 4 · Installing the app…"; }
            else if (line.StartsWith("Download tools are already set up")) { ring.Progress = 0.7; status.Text = "Download tools are already set up."; }
        }
    }
}
