using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

namespace CosmoGrav
{
    public enum Quality { Best, Hd1080, ProRes, Mp3, Wav }

    public static class QualityInfo
    {
        public static readonly Quality[] All = { Quality.Best, Quality.Hd1080, Quality.ProRes, Quality.Mp3, Quality.Wav };

        public static string Label(this Quality q)
        {
            switch (q)
            {
                case Quality.Best: return "Best HD (up to 4K)";
                case Quality.Hd1080: return "HD 1080p (faster)";
                case Quality.ProRes: return "ProRes 422 HQ (for heavy editing)";
                case Quality.Mp3: return "Audio only (MP3)";
                default: return "Audio only (WAV)";
            }
        }

        public static string ShortLabel(this Quality q)
        {
            switch (q)
            {
                case Quality.Best: return "Best HD";
                case Quality.Hd1080: return "1080p";
                case Quality.ProRes: return "ProRes";
                case Quality.Mp3: return "MP3";
                default: return "WAV";
            }
        }

        /// Stored in settings and history files, and used by the self-test ("best", "hd1080", ...). Same names as the Mac app.
        public static string Key(this Quality q)
        {
            switch (q)
            {
                case Quality.Best: return "best";
                case Quality.Hd1080: return "hd1080";
                case Quality.ProRes: return "prores";
                case Quality.Mp3: return "mp3";
                default: return "wav";
            }
        }

        public static Quality? FromKey(string key)
        {
            foreach (var q in All) if (q.Key() == key) return q;
            return null;
        }

        public static bool IsAudio(this Quality q) => q == Quality.Mp3 || q == Quality.Wav;

        /// Segoe icon glyph for the quality: film, film stack, or waveform.
        public static string Glyph(this Quality q) => q.IsAudio() ? Icons.Audio : (q == Quality.ProRes ? Icons.FilmStack : Icons.Film);

        /// What the finished file contains, shown as a badge on each row.
        public static string OutputBadge(this Quality q)
        {
            switch (q)
            {
                case Quality.Best:
                case Quality.Hd1080: return "H.264 MP4";
                case Quality.ProRes: return "ProRes MOV";
                default: return null;
            }
        }

        public static string FileExtension(this Quality q)
        {
            switch (q)
            {
                case Quality.Best:
                case Quality.Hd1080: return "mp4";
                case Quality.ProRes: return "mov";
                case Quality.Mp3: return "mp3";
                default: return "wav";
            }
        }

        /// yt-dlp format selection. SDR is preferred so HDR sources don't look washed out in Premiere;
        /// the 1080p option picks the site's own H.264 + AAC streams when they exist so no conversion is needed.
        public static string FormatSelector(this Quality q)
        {
            switch (q)
            {
                case Quality.Best:
                case Quality.ProRes:
                    return "bv*[dynamic_range=SDR]+ba/bv*+ba/b";
                case Quality.Hd1080:
                    return "bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<=1080][dynamic_range=SDR]+ba/bv*[height<=1080]+ba/b[height<=1080]/b";
                default:
                    return "ba/b";
            }
        }
    }

    public enum ItemState { Fetching, Ready, Queued, Downloading, Converting, Done, Failed, Cancelled }

    public static class ItemStateInfo
    {
        public static bool IsActive(this ItemState s) => s == ItemState.Downloading || s == ItemState.Converting;
        public static bool CanEdit(this ItemState s) => s == ItemState.Ready || s == ItemState.Failed || s == ItemState.Cancelled || s == ItemState.Fetching;
        public static bool CanStart(this ItemState s) => s == ItemState.Ready || s == ItemState.Failed || s == ItemState.Cancelled;
    }

    public abstract class Observable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        protected bool Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value)) return false;
            field = value;
            Raise(name);
            return true;
        }

        protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public sealed class DownloadItem : Observable
    {
        public Guid Id { get; } = Guid.NewGuid();
        public string Url { get; }

        string title, fileName, site = "", thumbnail, resolution, detail = "Getting info…", errorMessage;
        double? duration, trimStart, trimEnd;
        Quality quality;
        ItemState state = ItemState.Fetching;
        double progress;
        bool needsLogin, useLogin;
        string outputPath;

        public string Title { get => title; set => Set(ref title, value); }
        public string FileName { get => fileName; set => Set(ref fileName, value); }
        public string Site { get => site; set => Set(ref site, value); }
        public string Thumbnail { get => thumbnail; set => Set(ref thumbnail, value); }
        public double? Duration { get => duration; set => Set(ref duration, value); }
        public string Resolution { get => resolution; set => Set(ref resolution, value); }
        public Quality Quality { get => quality; set => Set(ref quality, value); }
        public double? TrimStart { get => trimStart; set { if (Set(ref trimStart, value)) Raise(nameof(TrimLabel)); } }
        public double? TrimEnd { get => trimEnd; set { if (Set(ref trimEnd, value)) Raise(nameof(TrimLabel)); } }
        public ItemState State { get => state; set => Set(ref state, value); }
        public double Progress { get => progress; set => Set(ref progress, value); }
        public string Detail { get => detail; set => Set(ref detail, value); }
        public string ErrorMessage { get => errorMessage; set => Set(ref errorMessage, value); }
        public bool NeedsLogin { get => needsLogin; set => Set(ref needsLogin, value); }
        public bool UseLogin { get => useLogin; set => Set(ref useLogin, value); }
        public string OutputPath { get => outputPath; set => Set(ref outputPath, value); }

        public bool InfoLoaded;
        public int ExpectedParts = 1;
        public RunningProcess Runner;

        public DownloadItem(string url, Quality quality, string title = null)
        {
            Url = url;
            this.quality = quality;
            this.title = title ?? url;
            fileName = title != null ? FileNames.Sanitize(title) : "";
        }

        public bool IsTrimmed => TrimStart.HasValue || TrimEnd.HasValue;

        public string TrimLabel
        {
            get
            {
                if (!IsTrimmed) return null;
                var start = TimeFormat.ToText(TrimStart ?? 0);
                var end = TrimEnd.HasValue ? TimeFormat.ToText(TrimEnd.Value) : (Duration.HasValue ? TimeFormat.ToText(Duration.Value) : "end");
                return start + " – " + end;
            }
        }
    }

    public sealed class HistoryEntry
    {
        public string Title, Url, Site, FilePath;
        public Quality Quality;
        public DateTime Date;

        public Dictionary<string, object> ToJson() => new Dictionary<string, object>
        {
            ["title"] = Title, ["url"] = Url, ["site"] = Site, ["filePath"] = FilePath,
            ["quality"] = Quality.Key(), ["date"] = Date.ToUniversalTime().ToString("o"),
        };

        public static HistoryEntry FromJson(Dictionary<string, object> o)
        {
            if (o == null || o.Str("url") == null) return null;
            DateTime.TryParse(o.Str("date"), null, System.Globalization.DateTimeStyles.RoundtripKind, out var date);
            return new HistoryEntry
            {
                Title = o.Str("title") ?? o.Str("url"), Url = o.Str("url"), Site = o.Str("site") ?? "",
                FilePath = o.Str("filePath") ?? "", Quality = QualityInfo.FromKey(o.Str("quality")) ?? Quality.Best,
                Date = date.ToLocalTime(),
            };
        }
    }

    public static class TimeFormat
    {
        public static string ToText(double seconds)
        {
            int total = (int)Math.Round(seconds);
            int h = total / 3600, m = (total % 3600) / 60, s = total % 60;
            return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
        }

        /// Accepts "83", "1:23", "1:02:03" and decimals like "1:23.5".
        public static double? Parse(string text)
        {
            var trimmed = (text ?? "").Trim();
            if (trimmed.Length == 0) return null;
            var parts = trimmed.Split(':');
            if (parts.Length > 3) return null;
            double total = 0;
            foreach (var p in parts)
            {
                if (!double.TryParse(p, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) || v < 0) return null;
                total = total * 60 + v;
            }
            return total;
        }
    }

    public static class FileNames
    {
        static readonly HashSet<string> Reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        };

        /// Makes a title safe as a Windows file name.
        public static string Sanitize(string name)
        {
            if (string.IsNullOrEmpty(name)) return "";
            var bad = "/:\\?%*|\"<>".ToCharArray();
            var chars = name.Select(c => c < 32 || bad.Contains(c) ? ' ' : c).ToArray();
            var cleaned = Regex.Replace(new string(chars), @"\s{2,}", " ").Trim().Trim('.', ' ');
            if (cleaned.Length > 150) cleaned = cleaned.Substring(0, 150).TrimEnd('.', ' ');
            if (Reserved.Contains(cleaned)) cleaned = "_" + cleaned;
            return cleaned;
        }

        /// "Name.mp4", or "Name (2).mp4" when that already exists, so nothing gets overwritten.
        public static string Unique(string folder, string name, string ext)
        {
            var clean = Sanitize(name);
            var baseName = clean.Length == 0 ? "Download" : clean;
            var candidate = Path.Combine(folder, baseName + "." + ext);
            int n = 2;
            while (File.Exists(candidate))
            {
                candidate = Path.Combine(folder, $"{baseName} ({n}).{ext}");
                n++;
            }
            return candidate;
        }
    }

    public static class LinkParser
    {
        static readonly Regex UrlPattern = new Regex(@"https?://[^\s<>""']+", RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static List<string> Links(string text)
        {
            var seen = new HashSet<string>();
            var result = new List<string>();
            foreach (Match m in UrlPattern.Matches(text ?? ""))
            {
                var link = m.Value.TrimEnd('.', ',', ';', ')', ']', '}', '!', '?');
                // Keep a closing bracket that belongs to the link, as in Wikipedia-style URLs.
                if (m.Value.Length > link.Length && m.Value[link.Length] == ')' && link.Contains("(")) link += ")";
                if (!Uri.TryCreate(link, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) continue;
                if (seen.Add(link)) result.Add(link);
            }
            return result;
        }
    }
}
