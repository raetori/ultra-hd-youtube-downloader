using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace CosmoGrav
{
    public partial class App : Application
    {
        public static bool QuittingWithoutAsking { get; private set; }
        static Mutex single;

        /// Closes the app without the "downloads are still running" question (used by Update now).
        public static void QuitWithoutAsking()
        {
            QuittingWithoutAsking = true;
            Current.Shutdown();
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            var args = e.Args;
            DispatcherUnhandledException += OnCrash;

            // Headless check used by the build machine: CosmoGrav.exe --selftest QUALITY:START-END:URL ... [--log FILE]
            if (args.Contains("--selftest"))
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                var specs = args.SkipWhile(a => a != "--selftest").Skip(1).TakeWhile(a => !a.StartsWith("--")).ToList();
                SelfTest.Run(specs, Arg(args, "--log"));
                return;
            }

            // CosmoGrav-Setup.exe opened from Downloads: install it. --install does the same without a window (build machine).
            if (args.Contains("--install"))
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                Setup.RunHeadless(Arg(args, "--log"));
                return;
            }
            if (args.Length == 0 && Setup.IsNeeded)
            {
                MainWindow = new SetupWindow();
                MainWindow.Show();
                return;
            }

            var shots = Arg(args, "--shots");
            if (shots == null && !args.Contains("--demo") && !TakeSingleInstance()) { Shutdown(); return; }

            var settings = new AppSettings();
            var queue = new QueueManager(settings);
            var updater = new Updater();
            var window = new MainWindow(queue, updater);
            MainWindow = window;
            // Used by the build machine to photograph the queue with a few sample rows.
            if (args.Contains("--demo")) queue.LoadDemo();
            if (shots != null) { Shots.Run(window, shots); return; }
            window.Show();
            if (args.Contains("--about")) AboutWindow.Open(window);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            QueueManager.Shared?.StopEverything();
            try { if (Directory.Exists(Tools.WorkRoot)) Directory.Delete(Tools.WorkRoot, true); } catch { }
            Native.KeepAwake(false);
            base.OnExit(e);
        }

        static string Arg(string[] args, string name)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }

        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);

        /// One copy at a time: opening the app again brings the running window to the front.
        static bool TakeSingleInstance()
        {
            single = new Mutex(true, "CosmoGrav-" + Environment.UserName, out bool created);
            if (created) return true;
            try
            {
                var me = Process.GetCurrentProcess();
                var other = Process.GetProcessesByName(me.ProcessName).FirstOrDefault(p => p.Id != me.Id && p.MainWindowHandle != IntPtr.Zero);
                if (other != null)
                {
                    ShowWindow(other.MainWindowHandle, 9); // SW_RESTORE
                    SetForegroundWindow(other.MainWindowHandle);
                }
            }
            catch { }
            return false;
        }

        void OnCrash(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            try
            {
                Directory.CreateDirectory(Tools.Base);
                File.AppendAllText(Path.Combine(Tools.Base, "error.log"), $"{DateTime.Now:o} {e.Exception}\n\n");
            }
            catch { }
            e.Handled = true;
        }
    }
}
