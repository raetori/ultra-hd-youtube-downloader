using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CosmoGrav
{
    /// Small Windows API calls: dark title bars, taskbar flashing, keeping the PC awake, clipboard change count.
    static class Native
    {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        static extern bool FlashWindowEx(ref FLASHWINFO info);

        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint flags);

        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        [DllImport("kernel32.dll")]
        public static extern bool AttachConsole(int processId);

        [StructLayout(LayoutKind.Sequential)]
        struct FLASHWINFO
        {
            public uint cbSize;
            public IntPtr hwnd;
            public uint dwFlags;
            public uint uCount;
            public uint dwTimeout;
        }

        /// Black title bar with light text, matching the app (Windows 10 20H1 and later; Windows 11 also colors the caption).
        public static void DarkTitleBar(Window window)
        {
            void Apply()
            {
                var hwnd = new WindowInteropHelper(window).Handle;
                if (hwnd == IntPtr.Zero) return;
                int on = 1;
                if (DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
                int black = 0x00050505; // COLORREF 0x00BBGGRR
                DwmSetWindowAttribute(hwnd, 35, ref black, sizeof(int));
                int border = 0x00221A14;
                DwmSetWindowAttribute(hwnd, 34, ref border, sizeof(int));
                int text = 0x00DCE6EE;
                DwmSetWindowAttribute(hwnd, 36, ref text, sizeof(int));
            }
            if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Apply();
            else window.SourceInitialized += (s, e) => Apply();
        }

        /// Flashes the taskbar button until the window is brought to the front.
        public static void Flash(Window window)
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;
            var info = new FLASHWINFO
            {
                cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)),
                hwnd = hwnd,
                dwFlags = 2 | 12, // FLASHW_TRAY | FLASHW_TIMERNOFG
                uCount = 5,
                dwTimeout = 0,
            };
            FlashWindowEx(ref info);
        }

        /// Keeps Windows from sleeping while downloads run with the window in the background.
        public static void KeepAwake(bool on)
        {
            const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x00000001;
            SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
        }
    }
}
