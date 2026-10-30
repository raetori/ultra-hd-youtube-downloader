using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CosmoGrav
{
    /// Locations of the command-line tools the installer sets up, and helpers for running them.
    public static class Tools
    {
        public static readonly string Base = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CosmoGrav");
        public static readonly string Bin = Path.Combine(Base, "bin");
        public static readonly string WorkRoot = Path.Combine(Base, "work");
        public static readonly string HistoryFile = Path.Combine(Base, "history.json");
        public static readonly string SettingsFile = Path.Combine(Base, "settings.json");

        public static string YtDlp => Path.Combine(Bin, "yt-dlp.exe");
        public static string Ffmpeg => Path.Combine(Bin, "ffmpeg.exe");
        public static string Ffprobe => Path.Combine(Bin, "ffprobe.exe");
        public static string Deno => Path.Combine(Bin, "deno.exe");

        public const string RepoRawBase = "https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader";
        public const string RepoRaw = RepoRawBase + "/main";
        public const string InstallCommand = "irm " + RepoRaw + "/install.ps1 | iex";
        public const string Website = "https://www.creationofcosmos.com";

        public static bool Installed => File.Exists(YtDlp) && File.Exists(Ffmpeg) && File.Exists(Ffprobe);

        /// Keeps yt-dlp current at most once a day; sites change often and old versions stop working.
        public static async Task UpdateDownloaderIfStale(bool force = false)
        {
            var stamp = Path.Combine(Base, "last-update");
            if (!force && File.Exists(stamp) && DateTime.Now - File.GetLastWriteTime(stamp) < TimeSpan.FromDays(1)) return;
            if (!Installed) return;
            try
            {
                var result = await Runner.Run(YtDlp, new[] { "-U" });
                if (result.Status == 0)
                {
                    Directory.CreateDirectory(Base);
                    File.WriteAllText(stamp, DateTime.Now.ToString("o"));
                }
            }
            catch { }
        }
    }

    public sealed class ProcessResult
    {
        public int Status;
        public string Stdout = "";
        public string Stderr = "";
    }

    /// A handle that lets the UI stop a running process and everything it started (yt-dlp starts ffmpeg).
    public sealed class RunningProcess
    {
        readonly object gate = new object();
        int pid;
        bool cancelled;

        public bool Cancelled { get { lock (gate) return cancelled; } }

        public void Attach(Process process)
        {
            bool stop;
            lock (gate) { pid = process.Id; stop = cancelled; }
            if (stop) ProcessKiller.KillTree(process.Id);
        }

        public void Cancel()
        {
            int current;
            lock (gate) { cancelled = true; current = pid; }
            if (current > 0) ProcessKiller.KillTree(current);
        }
    }

    public static class ProcessKiller
    {
        public static void KillTree(int pid)
        {
            try
            {
                var info = new ProcessStartInfo("taskkill.exe", $"/PID {pid} /T /F")
                {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                };
                using (var p = Process.Start(info)) p?.WaitForExit(5000);
            }
            catch
            {
                try { Process.GetProcessById(pid).Kill(); } catch { }
            }
        }
    }

    public static class Runner
    {
        /// Quotes one argument the way Windows programs (and ffmpeg, yt-dlp) split their command line.
        public static string Quote(string arg)
        {
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\r', '"' }) < 0) return arg;
            var sb = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\') { backslashes++; continue; }
                if (c == '"') { sb.Append('\\', backslashes * 2 + 1); sb.Append('"'); }
                else { sb.Append('\\', backslashes); sb.Append(c); }
                backslashes = 0;
            }
            sb.Append('\\', backslashes * 2);
            sb.Append('"');
            return sb.ToString();
        }

        public static Task<ProcessResult> Run(string exe, IEnumerable<string> args, RunningProcess handle = null, Action<string> onLine = null)
        {
            return Task.Run(() =>
            {
                var info = new ProcessStartInfo(exe, string.Join(" ", args.Select(Quote)))
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false),
                    WorkingDirectory = Directory.Exists(Tools.Base) ? Tools.Base : Path.GetTempPath(),
                };
                info.EnvironmentVariables["PATH"] = Tools.Bin + ";" + Environment.GetEnvironmentVariable("PATH");
                // yt-dlp is a Python program: make it print UTF-8 so titles in any language come through intact.
                info.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
                info.EnvironmentVariables["PYTHONUTF8"] = "1";

                var stdout = new StringBuilder();
                var stderr = new StringBuilder();
                using (var process = new Process { StartInfo = info })
                {
                    process.OutputDataReceived += (s, e) =>
                    {
                        if (e.Data == null) return;
                        lock (stdout)
                        {
                            stdout.Append(e.Data).Append('\n');
                            // Progress output can run long; JSON output (no line callback) must stay whole.
                            if (onLine != null && stdout.Length > 400_000) stdout.Remove(0, 200_000);
                        }
                        if (onLine != null && e.Data.Length > 0) onLine(e.Data);
                    };
                    process.ErrorDataReceived += (s, e) =>
                    {
                        if (e.Data == null) return;
                        lock (stderr)
                        {
                            stderr.Append(e.Data).Append('\n');
                            if (stderr.Length > 400_000) stderr.Remove(0, 200_000);
                        }
                        if (onLine != null && e.Data.Length > 0) onLine(e.Data);
                    };
                    process.Start();
                    try { process.StandardInput.Close(); } catch { }
                    handle?.Attach(process);
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    process.WaitForExit();
                    lock (stdout) lock (stderr)
                        return new ProcessResult { Status = process.ExitCode, Stdout = stdout.ToString(), Stderr = stderr.ToString() };
                }
            });
        }
    }

    /// Limits how many tasks do something at once (used for fetching video info).
    public sealed class AsyncLimiter
    {
        readonly SemaphoreSlim semaphore;
        public AsyncLimiter(int limit) { semaphore = new SemaphoreSlim(limit, limit); }
        public Task Acquire() => semaphore.WaitAsync();
        public void Release() => semaphore.Release();
    }

    /// Picks the fastest H.264 encoder this PC has: NVIDIA, Intel or AMD graphics, otherwise the CPU (libx264).
    public static class Encoders
    {
        public sealed class Encoder
        {
            public string Name;
            public string Label;
            public Func<int, string[]> Args; // bitrate in Mbps -> ffmpeg video arguments
        }

        static readonly Encoder[] Hardware =
        {
            new Encoder { Name = "h264_nvenc", Label = "NVIDIA", Args = mbps => new[]
                { "-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr", "-b:v", mbps + "M", "-maxrate", mbps * 2 + "M", "-bufsize", mbps * 2 + "M", "-profile:v", "high", "-pix_fmt", "yuv420p" } },
            new Encoder { Name = "h264_qsv", Label = "Intel", Args = mbps => new[]
                { "-c:v", "h264_qsv", "-preset", "medium", "-b:v", mbps + "M", "-maxrate", mbps * 2 + "M", "-bufsize", mbps * 2 + "M", "-profile:v", "high", "-pix_fmt", "nv12" } },
            new Encoder { Name = "h264_amf", Label = "AMD", Args = mbps => new[]
                { "-c:v", "h264_amf", "-quality", "quality", "-rc", "vbr_peak", "-b:v", mbps + "M", "-maxrate", mbps * 2 + "M", "-bufsize", mbps * 2 + "M", "-profile:v", "high", "-pix_fmt", "yuv420p" } },
        };

        public static readonly Encoder Software = new Encoder
        {
            Name = "libx264", Label = "CPU",
            Args = _ => new[] { "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-profile:v", "high", "-pix_fmt", "yuv420p" },
        };

        static Task<Encoder> detected;
        static readonly object gate = new object();

        /// Tries each graphics encoder once with a tiny clip and remembers the first that works.
        public static Task<Encoder> Best()
        {
            lock (gate)
            {
                if (detected == null) detected = Detect();
                return detected;
            }
        }

        static async Task<Encoder> Detect()
        {
            var forced = Environment.GetEnvironmentVariable("COSMOGRAV_ENCODER");
            if (forced == "libx264") return Software;
            foreach (var encoder in Hardware)
            {
                if (forced != null && forced != encoder.Name) continue;
                try
                {
                    var args = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-frames:v", "10" };
                    args.AddRange(encoder.Args(8));
                    args.AddRange(new[] { "-f", "null", "-" });
                    var result = await Runner.Run(Tools.Ffmpeg, args);
                    if (result.Status == 0) return encoder;
                }
                catch { }
            }
            return Software;
        }
    }

    /// Segoe MDL2 / Fluent icon glyphs used across the app (the Windows counterpart of the Mac app's SF Symbols).
    public static class Icons
    {
        public const string Link = "";
        public const string Folder = "";
        public const string FolderOpen = "";
        public const string ChevronDown = "";
        public const string History = "";
        public const string Settings = "";
        public const string Download = "";
        public const string Retry = "";
        public const string Close = "";
        public const string Delete = "";
        public const string Edit = "";
        public const string Trim = "";
        public const string Film = "";
        public const string FilmStack = "";
        public const string Audio = "";
        public const string Check = "";
        public const string CheckSeal = "";
        public const string Warning = "";
        public const string Clipboard = "";
        public const string Sparkle = "";
        public const string Person = "";
        public const string Clock = "";
        public const string Info = "";
    }
}
