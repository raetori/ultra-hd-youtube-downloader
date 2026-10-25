using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace CosmoGrav
{
    /// The look of creationofcosmos.com: deep-space black, warm gold light (the black hole's disk),
    /// small ember mono labels, thin wide-tracked titles and soft, eased motion. Colors live in Theme.xaml.
    public static class Theme
    {
        static Color C(string key) => (Color)Application.Current.Resources[key];
        public static Color Gold => C("GoldColor");
        public static Color GoldDeep => C("GoldDeepColor");
        public static Color Ember => C("EmberColor");
        public static Color Cream => C("CreamColor");
        public static Color Danger => C("DangerColor");
        public static Color Ink => C("InkColor");

        public static Brush Brush(Color c, double opacity = 1)
        {
            var b = new SolidColorBrush(Color.FromArgb((byte)(c.A * opacity), c.R, c.G, c.B));
            b.Freeze();
            return b;
        }

        public static Brush White(double opacity) => Brush(Colors.White, opacity);

        public static readonly FontFamily Mono = new FontFamily("Cascadia Mono, Consolas");
        public static readonly FontFamily Ui = new FontFamily("Segoe UI Variable Text, Segoe UI");
        public static readonly FontFamily IconFont = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");

        /// The Creation of Cosmos mark: an open ring with a dot, from the brand SVG (100×100 viewBox).
        public static readonly Geometry Mark = MakeMark();

        static Geometry MakeMark()
        {
            var g = Geometry.Parse("M82.70,79.44 A44,44 0 1 1 82.70,20.56 L71.55,30.60 A29,29 0 1 0 71.55,69.40 Z " +
                                   "M89.5,50 A9.5,9.5 0 1 1 70.5,50 A9.5,9.5 0 1 1 89.5,50 Z");
            g.Freeze();
            return g;
        }

        public static Color SiteColor(string site)
        {
            switch (site)
            {
                case "YouTube": return Color.FromRgb(242, 97, 92);
                case "TikTok": return Color.FromRgb(89, 217, 217);
                case "Instagram": return Color.FromRgb(235, 115, 173);
                case "Facebook": return Color.FromRgb(115, 158, 250);
                case "Vimeo": return Color.FromRgb(102, 199, 242);
                default: return Color.FromArgb(178, 255, 255, 255);
            }
        }

        /// The eased curve every motion in the app uses: smooth, soft, never snappy (cubic-bezier 0.45, 0, 0.2, 1).
        public static double Ease(double t)
        {
            t = Math.Max(0, Math.Min(1, t));
            // Solve the bezier's x for t with a few Newton steps, then evaluate y.
            double x1 = 0.45, y1 = 0, x2 = 0.2, y2 = 1, u = t;
            for (int i = 0; i < 6; i++)
            {
                double x = Bez(u, x1, x2) - t;
                double d = BezD(u, x1, x2);
                if (Math.Abs(d) < 1e-6) break;
                u -= x / d;
                u = Math.Max(0, Math.Min(1, u));
            }
            return Bez(u, y1, y2);
        }

        static double Bez(double u, double p1, double p2) => 3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u;
        static double BezD(double u, double p1, double p2) => 3 * (1 - u) * (1 - u) * p1 + 6 * (1 - u) * u * (p2 - p1) + 3 * u * u * (1 - p2);
    }

    /// Runs a callback on every frame while the element is on screen.
    abstract class AnimatedElement : FrameworkElement
    {
        bool hooked;

        protected AnimatedElement()
        {
            Loaded += (s, e) => UpdateHook();
            Unloaded += (s, e) => Unhook();
            IsVisibleChanged += (s, e) => UpdateHook();
        }

        protected abstract bool NeedsFrames { get; }

        protected void UpdateHook()
        {
            if (IsLoaded && IsVisible && NeedsFrames) Hook(); else Unhook();
        }

        void Hook()
        {
            if (hooked) return;
            hooked = true;
            CompositionTarget.Rendering += OnFrame;
        }

        void Unhook()
        {
            if (!hooked) return;
            hooked = false;
            CompositionTarget.Rendering -= OnFrame;
        }

        void OnFrame(object sender, EventArgs e) => Frame();

        protected abstract void Frame();
    }

    /// The site's loader motif: a glowing orb travelling a faint ring, leaving a trail of light.
    /// With a progress value the trail shows how far along it is; with NaN the orb circles gently.
    sealed class OrbRing : AnimatedElement
    {
        public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
            nameof(Progress), typeof(double), typeof(OrbRing), new PropertyMetadata(double.NaN, (d, e) => ((OrbRing)d).ProgressChanged()));
        public static readonly DependencyProperty LineWidthProperty = DependencyProperty.Register(
            nameof(LineWidth), typeof(double), typeof(OrbRing), new FrameworkPropertyMetadata(1.2, FrameworkPropertyMetadataOptions.AffectsRender));

        public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }
        public double LineWidth { get => (double)GetValue(LineWidthProperty); set => SetValue(LineWidthProperty, value); }

        double shown, from, target;
        DateTime animStart;
        static readonly DateTime Epoch = DateTime.UtcNow;

        bool Indeterminate => double.IsNaN(Progress);
        protected override bool NeedsFrames => Indeterminate || Math.Abs(shown - target) > 0.0005;

        void ProgressChanged()
        {
            if (!Indeterminate)
            {
                from = shown;
                target = Math.Max(0, Math.Min(1, Progress));
                animStart = DateTime.UtcNow;
            }
            UpdateHook();
            InvalidateVisual();
        }

        protected override void Frame()
        {
            if (!Indeterminate)
            {
                var t = (DateTime.UtcNow - animStart).TotalSeconds / 0.55;
                shown = t >= 1 ? target : from + (target - from) * Theme.Ease(t);
                if (t >= 1) UpdateHook();
            }
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            double size = Math.Min(ActualWidth, ActualHeight);
            if (size <= 0) return;
            double trailStart, trailEnd;
            if (Indeterminate)
            {
                // One lap every 2.6 s, easing in and out like the site's loader.
                double t = (DateTime.UtcNow - Epoch).TotalSeconds;
                double phase = (t % 2.6) / 2.6;
                double head = 0.5 - Math.Cos(phase * Math.PI) / 2;
                trailStart = head - 0.28;
                trailEnd = head;
            }
            else
            {
                trailStart = 0;
                trailEnd = Math.Max(0.002, Math.Min(shown, 1));
            }
            Draw(dc, new Point(ActualWidth / 2, ActualHeight / 2), size, LineWidth, trailStart, trailEnd);
        }

        public static void Draw(DrawingContext dc, Point c, double size, double lineWidth, double trailStart, double trailEnd)
        {
            var gold = Theme.Gold;
            double r = size / 2 - lineWidth / 2;
            dc.DrawEllipse(null, new Pen(Theme.White(0.08), lineWidth), c, r, r);
            // The trail brightens toward the orb, drawn as short arcs.
            double length = trailEnd - trailStart;
            for (int i = 0; i < 16; i++)
            {
                double a = trailStart + length * i / 16, b = trailStart + length * (i + 1) / 16;
                var pen = new Pen(Theme.Brush(gold, 0.9 * (i + 1) / 16), lineWidth) { StartLineCap = PenLineCap.Flat, EndLineCap = PenLineCap.Flat };
                dc.DrawGeometry(null, pen, Arc(c, r, a, b));
            }
            double orb = Math.Min(Math.Max(3, size * 0.16), 7);
            var p = PointAt(c, r, trailEnd);
            Glow(dc, p, orb);
        }

        /// A white orb with a soft gold halo.
        public static void Glow(DrawingContext dc, Point p, double orb)
        {
            var gold = Theme.Gold;
            var halo = new RadialGradientBrush(new GradientStopCollection
            {
                new GradientStop(Color.FromArgb(150, gold.R, gold.G, gold.B), 0),
                new GradientStop(Color.FromArgb(60, gold.R, gold.G, gold.B), 0.35),
                new GradientStop(Color.FromArgb(0, gold.R, gold.G, gold.B), 1),
            });
            halo.Freeze();
            dc.DrawEllipse(halo, null, p, orb * 2.6, orb * 2.6);
            dc.DrawEllipse(Brushes.White, null, p, orb / 2, orb / 2);
        }

        static Point PointAt(Point c, double r, double fraction)
        {
            double a = (-90 + 360 * fraction) * Math.PI / 180;
            return new Point(c.X + r * Math.Cos(a), c.Y + r * Math.Sin(a));
        }

        static Geometry Arc(Point c, double r, double a, double b)
        {
            var g = new StreamGeometry();
            using (var ctx = g.Open())
            {
                ctx.BeginFigure(PointAt(c, r, a), false, false);
                ctx.ArcTo(PointAt(c, r, b), new Size(r, r), 0, (b - a) > 0.5, SweepDirection.Clockwise, true, false);
            }
            g.Freeze();
            return g;
        }
    }

    /// A hairline progress bar with a glowing orb at its head: the linear version of the orb motif.
    sealed class OrbBar : AnimatedElement
    {
        public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
            nameof(Progress), typeof(double), typeof(OrbBar), new PropertyMetadata(0.0, (d, e) => ((OrbBar)d).Changed()));

        public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }

        double shown, from, target;
        DateTime animStart;

        public OrbBar() { Height = 10; }

        protected override bool NeedsFrames => Math.Abs(shown - target) > 0.0005;

        void Changed()
        {
            from = shown;
            target = Math.Max(0, Math.Min(1, Progress));
            // A new download starts from zero without sliding backwards.
            if (target < from) { shown = from = target; }
            animStart = DateTime.UtcNow;
            UpdateHook();
            InvalidateVisual();
        }

        protected override void Frame()
        {
            var t = (DateTime.UtcNow - animStart).TotalSeconds / 0.55;
            shown = t >= 1 ? target : from + (target - from) * Theme.Ease(t);
            if (t >= 1) UpdateHook();
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, y = ActualHeight / 2;
            if (w <= 0) return;
            dc.DrawRoundedRectangle(Theme.White(0.08), null, new Rect(0, y - 1, w, 2), 1, 1);
            double width = w * shown;
            if (width > 0.5)
            {
                var fill = new LinearGradientBrush(Color.FromArgb(51, Theme.GoldDeep.R, Theme.GoldDeep.G, Theme.GoldDeep.B), Theme.Gold, 0);
                fill.Freeze();
                dc.DrawRoundedRectangle(fill, null, new Rect(0, y - 1, width, 2), 1, 1);
            }
            if (shown > 0.002) OrbRing.Glow(dc, new Point(width, y), 5);
        }
    }

    /// A field of stars that breathe very slowly. Positions come from a fixed seed so they never jump.
    sealed class Starfield : FrameworkElement
    {
        public int Count { get; set; } = 160;
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1000.0 / 15) };
        static readonly DateTime Epoch = DateTime.UtcNow;

        public Starfield()
        {
            IsHitTestVisible = false;
            timer.Tick += (s, e) => InvalidateVisual();
            Loaded += (s, e) => timer.Start();
            Unloaded += (s, e) => timer.Stop();
        }

        protected override void OnRender(DrawingContext dc)
        {
            double t = (DateTime.UtcNow - Epoch).TotalSeconds + 1000;
            ulong seed = 0x9E3779B97F4A7C15;
            double Next()
            {
                seed = unchecked(seed * 6364136223846793005UL + 1442695040888963407UL);
                return (seed >> 33) / (double)(1UL << 31);
            }
            var gold = Theme.Gold;
            for (int i = 0; i < Count; i++)
            {
                double x = Next() * ActualWidth, y = Next() * ActualHeight;
                double r = 0.4 + Next() * 1.1;
                double baseAlpha = 0.12 + Next() * 0.5;
                double speed = 0.15 + Next() * 0.35;
                double offset = Next() * 6.28;
                double alpha = baseAlpha * (0.65 + 0.35 * Math.Sin(t * speed + offset));
                bool warm = Next() > 0.8;
                var color = warm ? gold : Colors.White;
                var brush = new SolidColorBrush(Color.FromArgb((byte)(255 * Math.Max(0, Math.Min(1, alpha))), color.R, color.G, color.B));
                dc.DrawEllipse(brush, null, new Point(x + r / 2, y + r / 2), r / 2, r / 2);
            }
        }
    }

    /// Text with letter spacing, for the site's wide-tracked titles and small all-caps mono labels
    /// (WPF's TextBlock has no tracking setting).
    sealed class TrackedText : FrameworkElement
    {
        public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(TrackedText),
            new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty TrackingProperty = DependencyProperty.Register(nameof(Tracking), typeof(double), typeof(TrackedText),
            new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty ForegroundProperty = DependencyProperty.Register(nameof(Foreground), typeof(Brush), typeof(TrackedText),
            new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty FontSizeProperty = DependencyProperty.Register(nameof(FontSize), typeof(double), typeof(TrackedText),
            new FrameworkPropertyMetadata(12.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty FontWeightProperty = DependencyProperty.Register(nameof(FontWeight), typeof(FontWeight), typeof(TrackedText),
            new FrameworkPropertyMetadata(FontWeights.Normal, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty MonoProperty = DependencyProperty.Register(nameof(Mono), typeof(bool), typeof(TrackedText),
            new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty UpperProperty = DependencyProperty.Register(nameof(Upper), typeof(bool), typeof(TrackedText),
            new FrameworkPropertyMetadata(true, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

        public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
        /// Extra space between letters, in pixels.
        public double Tracking { get => (double)GetValue(TrackingProperty); set => SetValue(TrackingProperty, value); }
        public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }
        public double FontSize { get => (double)GetValue(FontSizeProperty); set => SetValue(FontSizeProperty, value); }
        public FontWeight FontWeight { get => (FontWeight)GetValue(FontWeightProperty); set => SetValue(FontWeightProperty, value); }
        public bool Mono { get => (bool)GetValue(MonoProperty); set => SetValue(MonoProperty, value); }
        public bool Upper { get => (bool)GetValue(UpperProperty); set => SetValue(UpperProperty, value); }

        public TrackedText() { SnapsToDevicePixels = true; IsHitTestVisible = false; }

        string Shown => Upper ? (Text ?? "").ToUpperInvariant() : (Text ?? "");

        FormattedText Glyph(string s, Brush brush) => new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(Mono ? Theme.Mono : Theme.Ui, FontStyles.Normal, FontWeight, FontStretches.Normal), FontSize, brush,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);

        protected override Size MeasureOverride(Size available)
        {
            var text = Shown;
            if (text.Length == 0) return new Size(0, 0);
            double width = 0, height = 0;
            foreach (char ch in text)
            {
                var g = Glyph(ch.ToString(), Brushes.White);
                width += g.WidthIncludingTrailingWhitespace + Tracking;
                height = Math.Max(height, g.Height);
            }
            return new Size(Math.Max(0, width - Tracking), height);
        }

        protected override void OnRender(DrawingContext dc)
        {
            double x = 0;
            foreach (char ch in Shown)
            {
                var g = Glyph(ch.ToString(), Foreground);
                dc.DrawText(g, new Point(x, 0));
                x += g.WidthIncludingTrailingWhitespace + Tracking;
            }
        }
    }
}
