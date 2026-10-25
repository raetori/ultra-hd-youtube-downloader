using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace CosmoGrav
{
    public sealed class PipelineException : Exception
    {
        public bool NeedsLogin { get; }
        public PipelineException(string message, bool needsLogin = false) : base(message) { NeedsLogin = needsLogin; }

        /// Turns yt-dlp/ffmpeg output into one readable sentence and spots "you need to be logged in" failures.
        public static PipelineException From(string output, string fallback)
        {
            var lines = (output ?? "").Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);
            var line = lines.LastOrDefault(l => l.StartsWith("ERROR:")) ?? lines.LastOrDefault() ?? fallback;
            line = line.Replace("ERROR: ", "");
            line = Regex.Replace(line, @"^\[[^\]]+\] [^:]+: ", "");
            var caused = line.IndexOf(" (caused by", StringComparison.Ordinal);
            if (caused >= 0) line = line.Substring(0, caused);
            var lower = (output ?? "").ToLowerInvariant();
            var hints = new[] { "login", "log in", "sign in", "cookies", "private", "rate-limit", "rate limit", "authentication", "not available to you" };
            if (line.Length > 300) line = line.Substring(0, 300);
            return new PipelineException(line, hints.Any(lower.Contains));
        }
    }

    public sealed class MediaInfo
    {
        public string Title;
        public string Thumbnail;
        public double? Duration;
        public string Site;
        public int? Height;
        public int Parts = 1;
        public List<KeyValuePair<string, string>> Entries; // url, title
    }

    public static class Pipeline
    {
        /// Set by the self-test to see why the trimmed-part shortcut fell back to a full download.
        public static Action<string> DebugLog;

        static string F(double v) => v.ToString("0.000", CultureInfo.InvariantCulture);

        public static List<string> CommonArgs(bool useLogin, string browser)
        {
            var args = new List<string> { "--ffmpeg-location", Tools.Bin, "--no-playlist", "--encoding", "utf-8" };
            if (File.Exists(Tools.Deno)) args.AddRange(new[] { "--js-runtimes", "deno:" + Tools.Deno });
            if (useLogin && browser != "none") args.AddRange(new[] { "--cookies-from-browser", browser });
            return args;
        }

        // MARK: Info

        public static async Task<MediaInfo> FetchInfo(string url, Quality quality, bool useLogin, string browser)
        {
            // Playlists are listed flat so a long playlist is queued in seconds instead of minutes.
            var args = CommonArgs(useLogin, browser);
            args.AddRange(new[] { "-J", "--flat-playlist", "-f", quality.FormatSelector(), "--", url });
            var result = await Runner.Run(Tools.YtDlp, args);
            var json = result.Status == 0 ? Json.TryParseObject(result.Stdout) : null;
            if (json == null) throw PipelineException.From(result.Stderr, "Couldn't read this link.");

            var site = json.Str("extractor_key") ?? json.Str("extractor") ?? "";
            var title = json.Str("title") ?? url;

            if (json.Str("_type") == "playlist")
            {
                var entries = new List<KeyValuePair<string, string>>();
                foreach (var entry in json.Objs("entries"))
                {
                    var link = entry.Str("url") ?? entry.Str("webpage_url");
                    if (link == null || !link.StartsWith("http")) continue;
                    entries.Add(new KeyValuePair<string, string>(link, entry.Str("title")));
                }
                return new MediaInfo { Title = title, Site = site, Entries = entries };
            }

            // Windows can't always show WebP pictures, so prefer the best JPEG or PNG thumbnail the site offers.
            var thumbs = json.Objs("thumbnails").Select(t => t.Str("url")).Where(u => u != null).ToList();
            var thumb = thumbs.LastOrDefault(IsJpegOrPng) ?? json.Str("thumbnail") ?? thumbs.LastOrDefault();
            var requested = json.Objs("requested_formats");
            var height = json.Int("height") ?? requested.Select(r => r.Int("height")).Where(h => h.HasValue).Select(h => h.Value).DefaultIfEmpty().Max();
            return new MediaInfo
            {
                Title = title,
                Thumbnail = thumb,
                Duration = json.Num("duration"),
                Site = site,
                Height = height > 0 ? height : null,
                Parts = Math.Max(1, requested.Count),
            };
        }

        static bool IsJpegOrPng(string url)
        {
            var path = url.Split('?')[0].ToLowerInvariant();
            return path.EndsWith(".jpg") || path.EndsWith(".jpeg") || path.EndsWith(".png");
        }

        public static string ResolutionLabel(int? height)
        {
            if (!height.HasValue || height <= 0) return null;
            var h = height.Value;
            if (h >= 4000) return "8K";
            if (h >= 2000) return "4K";
            if (h >= 1400) return "1440p";
            return h + "p";
        }

        public static string FormatBytes(double bytes)
        {
            string[] units = { "bytes", "KB", "MB", "GB", "TB" };
            int u = 0;
            while (bytes >= 1000 && u < units.Length - 1) { bytes /= 1000; u++; }
            return u == 0 ? $"{bytes:0} {units[u]}" : $"{bytes.ToString(bytes < 10 ? "0.0" : "0", CultureInfo.InvariantCulture)} {units[u]}";
        }

        // MARK: Download

        sealed class PartTracker
        {
            readonly object gate = new object();
            int part;
            DateTime? slowSince;
            public void Next() { lock (gate) { part++; slowSince = null; } }
            public int Current { get { lock (gate) return Math.Max(part, 1); } }

            /// True once the speed has stayed under ~150 KB/s for 15 seconds, the signature of YouTube's throttling.
            public bool IsThrottled(double? speed)
            {
                lock (gate)
                {
                    if (!speed.HasValue || speed <= 0 || speed >= 150_000) { slowSince = null; return false; }
                    if (slowSince == null) slowSince = DateTime.Now;
                    return DateTime.Now - slowSince.Value > TimeSpan.FromSeconds(15);
                }
            }
        }

        static double? ParseNumber(string s) =>
            double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : (double?)null;

        /// Downloads into `workDir` and returns the downloaded file. Progress is 0...1 across all parts.
        public static async Task<string> Download(string url, Quality quality, int expectedParts, bool useLogin, string browser,
                                                  string workDir, RunningProcess handle, Action<double, string> onProgress)
        {
            var pathFile = Path.Combine(workDir, "path.txt");
            var args = CommonArgs(useLogin, browser);
            args.AddRange(new[]
            {
                "-f", quality.FormatSelector(),
                "-P", workDir, "-o", "media.%(ext)s",
                "--newline", "--no-mtime", "--force-overwrites", "--no-part",
                // YouTube limits the speed of each connection, so its files are fetched as pieces over
                // 8 connections at once ("dashy"); other sites that serve pieces benefit from the same setting.
                "--extractor-args", "youtube:formats=dashy",
                "--concurrent-fragments", "8",
                "--progress-template", "download:COSMOS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
                "--print-to-file", "after_move:filepath", pathFile,
            });
            if (!quality.IsAudio()) args.AddRange(new[] { "--merge-output-format", "mkv" });
            args.AddRange(new[] { "--", url });

            var tracker = new PartTracker();
            int parts = Math.Max(1, expectedParts);
            var result = await Runner.Run(Tools.YtDlp, args, handle, line =>
            {
                if (line.StartsWith("[download] Destination"))
                {
                    tracker.Next();
                }
                else if (line.StartsWith("COSMOS "))
                {
                    var f = line.Split(' ');
                    if (f.Length < 6) return;
                    double done = ParseNumber(f[1]) ?? 0;
                    double total = ParseNumber(f[2]) ?? ParseNumber(f[3]) ?? 0;
                    double fraction = total > 0 ? Math.Min(done / total, 1) : 0;
                    int part = Math.Min(tracker.Current, parts);
                    // With separate video and audio streams, the video is the bulk of the download.
                    double overall = parts > 1 ? (part == 1 ? fraction * 0.85 : 0.85 + fraction * 0.15) : fraction;
                    var detail = parts > 1 ? (part == 1 ? "Downloading video" : "Downloading audio") : "Downloading";
                    var speed = ParseNumber(f[4]);
                    if (speed > 0) detail += " · " + FormatBytes(speed.Value) + "/s";
                    if (tracker.IsThrottled(speed)) detail = "Very slow: the site is limiting this download. Settings → Update now may help · " + detail;
                    var eta = ParseNumber(f[5]);
                    if (eta > 0) detail += " · " + TimeFormat.ToText(eta.Value) + " left";
                    onProgress(overall, detail);
                }
                else if (line.StartsWith("[Merger]"))
                {
                    onProgress(1, "Combining video and audio…");
                }
            });
            if (handle.Cancelled) throw new OperationCanceledException();
            if (result.Status != 0) throw PipelineException.From(result.Stderr, "The download failed.");
            string saved = null;
            try { saved = File.ReadAllLines(pathFile).LastOrDefault(l => l.Trim().Length > 0)?.Trim(); } catch { }
            if (saved == null || !File.Exists(saved)) throw new PipelineException("The download finished but the file is missing.");
            return saved;
        }

        // MARK: Trimmed download

        /// For a trimmed video, reads only the chosen part straight from the site's servers and converts it in one pass,
        /// instead of downloading the whole file first. Returns false when the site serves the video in a way this
        /// can't handle (for example DASH fragments); the caller then falls back to a full download.
        public static async Task<bool> DownloadSection(string url, Quality quality, double? trimStart, double? trimEnd, double? duration,
                                                       bool useLogin, string browser, string output, RunningProcess handle,
                                                       Action<double, string> onProgress)
        {
            onProgress(0, "Finding the part you trimmed…");
            var infoArgs = CommonArgs(useLogin, browser);
            infoArgs.AddRange(new[] { "-j", "-f", quality.FormatSelector(), "--", url });
            var result = await Runner.Run(Tools.YtDlp, infoArgs, handle);
            if (handle.Cancelled) throw new OperationCanceledException();
            var json = result.Status == 0 ? Json.TryParseObject(result.Stdout.Trim()) : null;
            if (json == null) throw PipelineException.From(result.Stderr, "Couldn't read this link.");

            var formats = json.Objs("requested_formats");
            if (formats.Count == 0) formats.Add(json);
            var direct = new[] { "http", "https", "m3u8", "m3u8_native" };
            if (!formats.All(f => direct.Contains(f.Str("protocol") ?? "") && f.Str("url") != null))
            {
                DebugLog?.Invoke("section: unsupported protocols " + string.Join(",", formats.Select(f => f.Str("protocol") ?? "nil")));
                return false;
            }

            double start = Math.Max(trimStart ?? 0, 0);
            double? end = trimEnd ?? duration;
            double? length = end.HasValue ? Math.Max(end.Value - start, 0.1) : (double?)null;
            var inputs = new List<string>();
            int? videoIndex = null, audioIndex = null, height = null;
            double? fps = null;
            for (int i = 0; i < formats.Count; i++)
            {
                var format = formats[i];
                var headers = format.Obj("http_headers");
                if (headers != null && headers.Count > 0)
                    inputs.AddRange(new[] { "-headers", string.Concat(headers.Select(h => $"{h.Key}: {h.Value}\r\n")) });
                if (start > 0) inputs.AddRange(new[] { "-ss", F(start) });
                if (length.HasValue) inputs.AddRange(new[] { "-t", F(length.Value) });
                inputs.AddRange(new[] { "-i", format.Str("url") });
                // Plain video files on generic sites don't report codecs; assume they may hold both.
                var vcodec = format.Str("vcodec") ?? "unknown";
                var acodec = format.Str("acodec") ?? "unknown";
                if (vcodec != "none" && videoIndex == null)
                {
                    videoIndex = i;
                    height = format.Int("height");
                    fps = format.Num("fps");
                }
                if (acodec != "none" && audioIndex == null) audioIndex = i;
            }

            var maps = new List<string>();
            List<string> codecArgs;
            var container = new List<string>();
            if (quality.IsAudio())
            {
                var a = audioIndex ?? videoIndex;
                if (a == null) { DebugLog?.Invoke("section: no audio stream"); return false; }
                maps.AddRange(new[] { "-map", a + ":a:0?" });
                codecArgs = AudioArgs(quality).ToList();
            }
            else
            {
                if (videoIndex == null) { DebugLog?.Invoke("section: no video stream"); return false; }
                maps.AddRange(new[] { "-map", videoIndex + ":v:0?" });
                // Some sites don't say a file has sound, so take the video file's own audio when there is no separate track.
                maps.AddRange(new[] { "-map", (audioIndex ?? videoIndex) + ":a:0?" });
                codecArgs = (await VideoArgs(quality, height, fps)).Concat(AudioArgs(quality)).ToList();
                container = ContainerArgs(quality).ToList();
            }

            double total = length ?? 0;
            Task<ProcessResult> Attempt(List<string> codecs)
            {
                var all = new List<string> { "-hide_banner", "-nostdin", "-y" };
                all.AddRange(inputs); all.AddRange(maps); all.AddRange(codecs); all.AddRange(container);
                all.AddRange(new[] { "-progress", "pipe:1", "-nostats", "-loglevel", "error", output });
                return Runner.Run(Tools.Ffmpeg, all, handle, line =>
                {
                    if (!line.StartsWith("out_time_us=") || total <= 0) return;
                    var us = ParseNumber(line.Substring("out_time_us=".Length));
                    if (us == null) return;
                    var fraction = Math.Min(Math.Max(us.Value / 1_000_000 / total, 0), 1);
                    onProgress(fraction, $"Downloading and converting the trimmed part… {(int)(fraction * 100)}%");
                });
            }
            onProgress(0, "Downloading and converting the trimmed part…");
            var run = await Attempt(codecArgs);
            if (handle.Cancelled) throw new OperationCanceledException();
            var software = SoftwareFallback(codecArgs);
            if (run.Status != 0 && software != null)
            {
                codecArgs = software.Concat(AudioArgs(quality)).ToList();
                run = await Attempt(codecArgs);
                if (handle.Cancelled) throw new OperationCanceledException();
            }
            // If reading straight from the site fails (expired link, odd server), the full download still works.
            if (run.Status != 0) { DebugLog?.Invoke("section: ffmpeg failed: " + Tail(run.Stderr, 400)); return false; }
            if (!File.Exists(output)) return false;
            // Files without a seek index can come back short or silent; the full download is always right.
            var check = await ProbeFile(output);
            if (length.HasValue && (check.Duration ?? 0) < length.Value * 0.95 - 0.2)
            {
                DebugLog?.Invoke($"section: got {check.Duration:0.00}s of {length:0.00}s, falling back");
                return false;
            }
            if (!quality.IsAudio() && check.AudioCodec == null && await HasAudio(formats.Select(f => f.Str("url")).ToList(), formats))
            {
                DebugLog?.Invoke("section: sound missing, falling back");
                return false;
            }
            return true;
        }

        /// Whether any of the site's streams carries sound (asked of ffprobe when the site doesn't say).
        static async Task<bool> HasAudio(List<string> urls, List<Dictionary<string, object>> formats)
        {
            if (formats.Any(f => (f.Str("acodec") ?? "unknown") != "none" && f.Str("acodec") != null)) return true;
            foreach (var url in urls)
            {
                var r = await Runner.Run(Tools.Ffprobe, new[] { "-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_type", "-of", "csv=p=0", url });
                if (r.Stdout.Contains("audio")) return true;
            }
            return false;
        }

        static string Tail(string s, int n) => s.Length <= n ? s : s.Substring(s.Length - n);

        // MARK: Convert

        sealed class Probe
        {
            public string VideoCodec, PixelFormat, AudioCodec;
            public int? Height;
            public double? Fps, Duration;
        }

        static async Task<Probe> ProbeFile(string file)
        {
            var probe = new Probe();
            try
            {
                var result = await Runner.Run(Tools.Ffprobe, new[] { "-v", "error", "-show_entries",
                    "stream=codec_type,codec_name,pix_fmt,height,avg_frame_rate:format=duration", "-of", "json", file });
                var json = Json.TryParseObject(result.Stdout);
                if (json == null) return probe;
                var streams = json.Objs("streams");
                var v = streams.FirstOrDefault(s => s.Str("codec_type") == "video");
                if (v != null)
                {
                    probe.VideoCodec = v.Str("codec_name");
                    probe.PixelFormat = v.Str("pix_fmt");
                    probe.Height = v.Int("height");
                    var rate = (v.Str("avg_frame_rate") ?? "").Split('/');
                    if (rate.Length == 2 && ParseNumber(rate[0]) is double n && ParseNumber(rate[1]) is double d && d > 0) probe.Fps = n / d;
                }
                probe.AudioCodec = streams.FirstOrDefault(s => s.Str("codec_type") == "audio").Str("codec_name");
                probe.Duration = ParseNumber(json.Obj("format").Str("duration") ?? "");
            }
            catch { }
            return probe;
        }

        /// Produces the final file: an H.264 + AAC MP4 that Premiere imports, a ProRes MOV, or MP3/WAV audio.
        /// Streams already in the right codec are copied untouched unless the clip is trimmed.
        public static async Task Finalize(string input, Quality quality, double? trimStart, double? trimEnd,
                                          string output, RunningProcess handle, Action<double, string> onProgress)
        {
            var info = await ProbeFile(input);
            double start = Math.Max(trimStart ?? 0, 0);
            bool trimmed = trimStart.HasValue || trimEnd.HasValue;
            double length = info.Duration ?? 0;
            if (trimEnd.HasValue) length = Math.Max(trimEnd.Value - start, 0.1);
            else if (start > 0) length = Math.Max(length - start, 0.1);

            var inputArgs = new List<string> { "-hide_banner", "-nostdin", "-y" };
            if (start > 0) inputArgs.AddRange(new[] { "-ss", F(start) });
            inputArgs.AddRange(new[] { "-i", input });
            if (trimEnd.HasValue) inputArgs.AddRange(new[] { "-t", F(length) });

            string[] audio, video, container;
            string label;
            bool copyVideo = false;
            switch (quality)
            {
                case Quality.Mp3:
                case Quality.Wav:
                    video = new[] { "-vn" };
                    audio = AudioArgs(quality);
                    container = new string[0];
                    label = quality == Quality.Mp3 ? "Making MP3" : "Making WAV";
                    break;
                case Quality.ProRes:
                    video = info.VideoCodec == null ? new[] { "-vn" } : await VideoArgs(Quality.ProRes, info.Height, info.Fps);
                    audio = info.AudioCodec == null ? new[] { "-an" } : AudioArgs(Quality.ProRes);
                    container = ContainerArgs(Quality.ProRes);
                    label = "Converting to ProRes";
                    break;
                default:
                    copyVideo = info.VideoCodec == "h264" && info.PixelFormat == "yuv420p" && !trimmed;
                    if (info.VideoCodec == null) video = new[] { "-vn" };
                    else if (copyVideo) video = new[] { "-c:v", "copy" };
                    else video = await HardwareVideoArgs(info.Height, info.Fps);
                    if (info.AudioCodec == null) audio = new[] { "-an" };
                    else if (info.AudioCodec == "aac" && !trimmed) audio = new[] { "-c:a", "copy" };
                    else audio = AudioArgs(quality);
                    container = ContainerArgs(quality);
                    label = copyVideo ? "Finishing up" : "Converting to H.264 for Premiere";
                    break;
            }

            var mapping = new[] { "-map", "0:v:0?", "-map", "0:a:0?", "-map_metadata", "0", "-dn", "-sn" };
            var tail = new[] { "-progress", "pipe:1", "-nostats", "-loglevel", "error", output };
            double totalLength = length;

            Task<ProcessResult> Attempt(string[] videoArgs)
            {
                var all = inputArgs.Concat(mapping).Concat(videoArgs).Concat(audio).Concat(container).Concat(tail);
                return Runner.Run(Tools.Ffmpeg, all, handle, line =>
                {
                    if (!line.StartsWith("out_time_us=") || totalLength <= 0) return;
                    var us = ParseNumber(line.Substring("out_time_us=".Length));
                    if (us == null) return;
                    var fraction = Math.Min(Math.Max(us.Value / 1_000_000 / totalLength, 0), 1);
                    onProgress(fraction, $"{label}… {(int)(fraction * 100)}%");
                });
            }

            onProgress(0, label + "…");
            var result = await Attempt(video);
            if (handle.Cancelled) throw new OperationCanceledException();
            var software = SoftwareFallback(video);
            if (result.Status != 0 && software != null)
            {
                // The graphics encoder refused this video (unusual size or format): use the CPU encoder instead.
                video = software;
                onProgress(0, label + "…");
                result = await Attempt(video);
                if (handle.Cancelled) throw new OperationCanceledException();
            }
            if (result.Status != 0) throw PipelineException.From(result.Stderr, "Couldn't convert the file.");
            if (!quality.IsAudio() && info.VideoCodec != null)
            {
                var check = await ProbeFile(output);
                var expected = quality == Quality.ProRes ? "prores" : "h264";
                if (check.VideoCodec != expected)
                    throw new PipelineException($"Conversion produced {check.VideoCodec ?? "nothing"} instead of {expected}.");
            }
        }

        /// Encoder settings per output type. The PC's graphics encoder first; `SoftwareFallback` covers PCs without one.
        static async Task<string[]> VideoArgs(Quality quality, int? height, double? fps)
        {
            if (quality == Quality.ProRes)
                return new[] { "-c:v", "prores_ks", "-profile:v", "3", "-vendor", "apl0", "-pix_fmt", "yuv422p10le" };
            return await HardwareVideoArgs(height, fps);
        }

        static string[] SoftwareFallback(IList<string> args)
        {
            if (args.Any(a => a == "h264_nvenc" || a == "h264_qsv" || a == "h264_amf")) return Encoders.Software.Args(0);
            return null;
        }

        static string[] AudioArgs(Quality quality)
        {
            switch (quality)
            {
                case Quality.ProRes: return new[] { "-c:a", "pcm_s16le", "-ar", "48000" };
                case Quality.Mp3: return new[] { "-c:a", "libmp3lame", "-q:a", "0" };
                case Quality.Wav: return new[] { "-c:a", "pcm_s24le", "-ar", "48000" };
                default: return new[] { "-c:a", "aac", "-b:a", "320k", "-ar", "48000" };
            }
        }

        static string[] ContainerArgs(Quality quality) =>
            quality == Quality.Best || quality == Quality.Hd1080 ? new[] { "-tag:v", "avc1", "-movflags", "+faststart" } : new string[0];

        /// The fastest H.264 encoder on this PC, with a bitrate scaled to resolution and frame rate.
        static async Task<string[]> HardwareVideoArgs(int? height, double? fps)
        {
            int h = height ?? 1080;
            int mbps = h <= 720 ? 8 : h <= 1080 ? 16 : h <= 1440 ? 30 : h <= 2160 ? 60 : 120;
            if ((fps ?? 30) > 31) mbps = mbps * 3 / 2;
            var encoder = await Encoders.Best();
            return encoder.Args(mbps);
        }

        // MARK: Captions

        /// Saves the video's captions (or YouTube's automatic ones) as .srt next to the video, cut to match a trim.
        /// Captions are a bonus, so failures just mean none were saved.
        public static async Task<List<string>> SaveCaptions(string url, bool useLogin, string browser, string workDir,
                                                            double? trimStart, double? trimEnd, string baseName)
        {
            var saved = new List<string>();
            var dir = Path.Combine(workDir, "captions");
            try
            {
                Directory.CreateDirectory(dir);
                var args = CommonArgs(useLogin, browser);
                args.AddRange(new[] { "--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en",
                                      "--convert-subs", "srt", "-P", dir, "-o", "captions.%(ext)s", "--", url });
                var result = await Runner.Run(Tools.YtDlp, args);
                if (result.Status != 0) return saved;
                foreach (var file in Directory.GetFiles(dir, "*.srt"))
                {
                    // captions.en.srt -> "<video name>.en.srt"
                    var language = Path.GetExtension(Path.GetFileNameWithoutExtension(file)).TrimStart('.');
                    var target = baseName + (language.Length == 0 ? "" : "." + language) + ".srt";
                    try { File.Delete(target); } catch { }
                    if (trimStart.HasValue || trimEnd.HasValue)
                    {
                        double start = Math.Max(trimStart ?? 0, 0);
                        var cut = new List<string> { "-hide_banner", "-nostdin", "-y", "-loglevel", "error" };
                        if (start > 0) cut.AddRange(new[] { "-ss", F(start) });
                        cut.AddRange(new[] { "-i", file });
                        if (trimEnd.HasValue) cut.AddRange(new[] { "-t", F(Math.Max(trimEnd.Value - start, 0.1)) });
                        cut.Add(target);
                        var r = await Runner.Run(Tools.Ffmpeg, cut);
                        if (r.Status != 0) continue;
                    }
                    else
                    {
                        try { File.Move(file, target); } catch { continue; }
                    }
                    saved.Add(target);
                }
            }
            catch { }
            return saved;
        }
    }
}
