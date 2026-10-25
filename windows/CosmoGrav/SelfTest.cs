using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;

namespace CosmoGrav
{
    /// Headless check used by the build machine: `CosmoGrav.exe --selftest QUALITY:START-END:URL ... --log FILE`
    /// (START-END may be empty). Downloads and converts each link, then prints the codecs of the result.
    static class SelfTest
    {
        public static async void Run(List<string> specs, string logPath)
        {
            Native.AttachConsole(-1);
            StreamWriter log = null;
            try { if (logPath != null) log = new StreamWriter(logPath, false) { AutoFlush = true }; } catch { }
            void Print(string text)
            {
                try { Console.WriteLine(text); } catch { }
                log?.WriteLine(text);
            }

            Pipeline.DebugLog = s => Print("DEBUG " + s);
            int failures = 0;
            var encoder = await Encoders.Best();
            Print($"ENCODER {encoder.Name} ({encoder.Label})");
            foreach (var spec in specs)
            {
                var parts = spec.Split(new[] { ':' }, 3);
                var quality = parts.Length == 3 ? QualityInfo.FromKey(parts[0]) : null;
                if (quality == null) { Print("bad spec " + spec); failures++; continue; }
                var range = parts[1].Split('-');
                double? start = null, end = null;
                if (range.Length == 2) { start = TimeFormat.Parse(range[0]); end = TimeFormat.Parse(range[1]); }
                var url = parts[2];
                var work = Path.Combine(Path.GetTempPath(), "cosmograv-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(work);
                var handle = new RunningProcess();
                var started = DateTime.Now;
                string last = "";
                try
                {
                    var info = await Pipeline.FetchInfo(url, quality.Value, false, "none");
                    Print($"INFO {info.Site} | {info.Title} | {Pipeline.ResolutionLabel(info.Height) ?? "?"} | parts={info.Parts}");
                    var output = Path.Combine(work, "final." + quality.Value.FileExtension());
                    bool section = start.HasValue && await Pipeline.DownloadSection(url, quality.Value, start, end, info.Duration, false, "none", output, handle, (p, d) => last = d);
                    if (!section)
                    {
                        var file = await Pipeline.Download(url, quality.Value, info.Parts, false, "none", work, handle, (p, d) => { });
                        await Pipeline.Finalize(file, quality.Value, start, end, output, handle, (p, d) => last = d);
                    }
                    var probe = await Runner.Run(Tools.Ffprobe, new[] { "-v", "error", "-show_entries", "stream=codec_name,width,height,pix_fmt:format=duration", "-of", "compact", output });
                    Print($"OK{(section ? " (trimmed part only)" : "")} {quality.Value.Key()} in {(int)(DateTime.Now - started).TotalSeconds}s | {last}\n{probe.Stdout.Trim()}");
                }
                catch (Exception error)
                {
                    Print($"FAIL {spec}: {error.Message}");
                    failures++;
                }
                try { Directory.Delete(work, true); } catch { }
            }
            Print(failures == 0 ? "ALL PASSED" : $"{failures} FAILED");
            log?.Dispose();
            Application.Current.Shutdown(failures == 0 ? 0 : 1);
        }
    }
}
