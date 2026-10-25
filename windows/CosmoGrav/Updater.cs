using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace CosmoGrav
{
    /// Checks GitHub for a newer Windows release and installs it with the same PowerShell line teammates used to install.
    /// Windows releases are tagged "win-v1.2.3" so they never collide with the Mac app's "v1.2.3" releases.
    public sealed class Updater : Observable
    {
        string availableVersion;
        bool updating;
        public string AvailableVersion { get => availableVersion; set => Set(ref availableVersion, value); }
        public bool Updating { get => updating; set => Set(ref updating, value); }

        public static string CurrentVersion
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return $"{v.Major}.{v.Minor}.{v.Build}";
            }
        }

        DateTime lastCheck = DateTime.MinValue;
        DispatcherTimer timer;

        /// Checks now, then every hour while the app stays open.
        public void StartChecking()
        {
            Check();
            if (timer != null) return;
            timer = new DispatcherTimer { Interval = TimeSpan.FromHours(1) };
            timer.Tick += (s, e) => Check();
            timer.Start();
        }

        /// Called when the app comes to the front; skips if it checked in the last ten minutes.
        public void CheckIfStale()
        {
            if (DateTime.Now - lastCheck > TimeSpan.FromMinutes(10)) Check();
        }

        public async void Check()
        {
            lastCheck = DateTime.Now;
            var latest = await LatestVersion();
            if (latest != null && IsNewer(latest, CurrentVersion)) AvailableVersion = latest;
        }

        public static async Task<string> LatestVersion()
        {
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                using (var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) })
                {
                    client.DefaultRequestHeaders.UserAgent.ParseAdd("CosmoGrav-Windows/" + CurrentVersion);
                    client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
                    var text = await client.GetStringAsync("https://api.github.com/repos/raetori/ultra-hd-youtube-downloader/releases?per_page=30");
                    if (!(Json.Parse(text) is System.Collections.Generic.List<object> releases)) return null;
                    var tag = releases.OfType<System.Collections.Generic.Dictionary<string, object>>()
                        .Where(r => r.Bool("draft") != true && r.Bool("prerelease") != true)
                        .Select(r => r.Str("tag_name") ?? "")
                        .Where(t => t.StartsWith("win-v"))
                        .Select(t => t.Substring(5))
                        .OrderByDescending(t => t, Comparer)
                        .FirstOrDefault();
                    return tag;
                }
            }
            catch
            {
                return null;
            }
        }

        static readonly System.Collections.Generic.IComparer<string> Comparer =
            System.Collections.Generic.Comparer<string>.Create((a, b) => IsNewer(a, b) ? 1 : IsNewer(b, a) ? -1 : 0);

        public static bool IsNewer(string a, string b)
        {
            int[] Parse(string s) => s.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
            var x = Parse(a);
            var y = Parse(b);
            for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                int l = i < x.Length ? x[i] : 0, r = i < y.Length ? y[i] : 0;
                if (l != r) return l > r;
            }
            return false;
        }

        /// Runs the installer in the background, closes the app, and the installer reopens the new version.
        public void InstallUpdate()
        {
            Updating = true;
            QueueManager.Shared?.StopEverything();
            var log = Path.Combine(Tools.Base, "update.log").Replace("'", "''");
            var command = "$ProgressPreference='SilentlyContinue'; Start-Sleep -Seconds 1; $env:COSMOGRAV_UPDATE='1'; $env:COSMOGRAV_EXE=$null; $env:COSMOGRAV_GUI=$null; " +
                          $"& {{ irm '{Tools.RepoRaw}/install.ps1' | iex }} *>&1 | Out-File -FilePath '{log}' -Encoding utf8";
            try
            {
                Process.Start(new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " + Runner.Quote(command))
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                });
                App.QuitWithoutAsking();
            }
            catch
            {
                Updating = false;
            }
        }
    }
}
