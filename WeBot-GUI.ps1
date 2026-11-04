<#
    WeBot 图形界面
    以 "WeBot-Engine.ps1 -Gui" 启动后台引擎，解析其输出协议显示日志与状态；
    提供配置编辑（替代控制台向导）、截图区域校准、记忆与历史查看、托盘通知。
#>
param([string]$EnginePath = "")

# WinForms 与剪贴板需要 STA；非 STA 时用 Windows PowerShell 以 -STA 重新启动自身。
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    if ($EnginePath) { $relaunch += @('-EnginePath', "`"$EnginePath`"") }
    Start-Process -FilePath $ps51 -ArgumentList $relaunch
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# 引擎子进程：异步读取 stdout/stderr 到队列，界面定时器在 UI 线程取出处理。
$engine_code = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class WeBotEngineProcess {
    private Process _proc;
    private readonly ConcurrentQueue<string> _lines = new ConcurrentQueue<string>();

    public int Id { get { try { return _proc == null ? 0 : _proc.Id; } catch { return 0; } } }
    public bool HasExited { get { try { return _proc == null || _proc.HasExited; } catch { return true; } } }
    public int ExitCode { get { try { return _proc.ExitCode; } catch { return -1; } } }

    public void Start(string exe, string args, string workDir) {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.WorkingDirectory = workDir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        psi.StandardErrorEncoding = new UTF8Encoding(false);
        _proc = new Process();
        _proc.StartInfo = psi;
        _proc.OutputDataReceived += (s, e) => { if (e.Data != null) _lines.Enqueue(e.Data); };
        _proc.ErrorDataReceived += (s, e) => { if (e.Data != null) _lines.Enqueue("@@ERR\t" + e.Data); };
        _proc.Start();
        _proc.BeginOutputReadLine();
        _proc.BeginErrorReadLine();
        // 允许引擎（校准窗口）抢到前台。
        try { AllowSetForegroundWindow(_proc.Id); } catch { }
    }

    public bool TryDequeue(out string line) { return _lines.TryDequeue(out line); }

    // 进程退出后等待异步读取结束，保证最后几行输出不丢。
    public void FinishExit() { try { _proc.WaitForExit(); } catch { } }

    public bool Signal(string prefix) {
        if (HasExited) return false;
        EventWaitHandle h;
        if (EventWaitHandle.TryOpenExisting(prefix + _proc.Id, out h)) {
            using (h) { h.Set(); }
            return true;
        }
        return false;
    }

    public void Kill() { try { if (!HasExited) _proc.Kill(); } catch { } }

    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
if (-not ([System.Management.Automation.PSTypeName]'WeBotEngineProcess').Type) { Add-Type -TypeDefinition $engine_code }

# DPI 感知必须在任何 GDI/窗口操作（包括枚举字体）之前设置。
[void][WeBotEngineProcess]::SetProcessDPIAware()
$script:K = 1.0
try { $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:K = $g0.DpiX / 96.0; $g0.Dispose() } catch {}
function Px([double]$v) { return [int][Math]::Round($v * $script:K) }

# 自绘控件：圆角按钮（悬停/按下/禁用/选中态）、圆角卡片、状态胶囊、细进度条、Logo。
$ui_code = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

public static class WeBotUi {
    private static string _iconFontName;
    private static bool _iconChecked;

    // Win11 用 Segoe Fluent Icons，Win10 用 Segoe MDL2 Assets；都没有时不画图标。
    public static string IconFontName {
        get {
            if (!_iconChecked) {
                _iconChecked = true;
                using (InstalledFontCollection fc = new InstalledFontCollection()) {
                    foreach (string n in new string[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }) {
                        foreach (FontFamily ff in fc.Families) { if (ff.Name == n) { _iconFontName = n; break; } }
                        if (_iconFontName != null) break;
                    }
                }
            }
            return _iconFontName;
        }
    }

    public static Font IconFont(float pt) {
        string n = IconFontName;
        return n == null ? null : new Font(n, pt, FontStyle.Regular, GraphicsUnit.Point);
    }

    public static GraphicsPath Round(RectangleF r, float radius) {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(radius * 2f, Math.Min(r.Width, r.Height));
        if (d < 1f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static Color BackOf(Control c) {
        Control p = c.Parent;
        while (p != null) {
            WeBotCard card = p as WeBotCard;
            if (card != null) return card.Fill;
            if (p.BackColor.A == 255) return p.BackColor;
            p = p.Parent;
        }
        return SystemColors.Control;
    }

    public static Color Mix(Color a, Color b, float t) {
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }

    public static Color Hex(string h) { return ColorTranslator.FromHtml(h); }
}

public class WeBotButton : Button {
    private string _kind = "secondary";
    private string _glyph = "";
    private bool _hover, _down, _selected, _leftAlign;
    private int _radius = 6;
    private Font _glyphFont;
    private const TextFormatFlags TF = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.Left;

    public WeBotButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
        Cursor = Cursors.Hand;
    }

    public string Kind { get { return _kind; } set { _kind = value ?? "secondary"; Invalidate(); } }
    public string Glyph { get { return _glyph; } set { _glyph = value ?? ""; Invalidate(); } }
    public bool Selected { get { return _selected; } set { _selected = value; Invalidate(); } }
    public bool LeftAlign { get { return _leftAlign; } set { _leftAlign = value; Invalidate(); } }
    public int Radius { get { return _radius; } set { _radius = value; Invalidate(); } }

    private Font GlyphFont {
        get {
            if (_glyphFont == null) _glyphFont = WeBotUi.IconFont(Font.SizeInPoints * 1.05f);
            return _glyphFont;
        }
    }
    private int Gap { get { return Math.Max(4, (int)(Font.Height * 0.45)); } }

    protected override void OnFontChanged(EventArgs e) {
        if (_glyphFont != null) { _glyphFont.Dispose(); _glyphFont = null; }
        base.OnFontChanged(e);
    }
    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    private int GlyphWidth(Graphics g) {
        if (string.IsNullOrEmpty(_glyph) || GlyphFont == null) return 0;
        return TextRenderer.MeasureText(g, _glyph, GlyphFont, Size.Empty, TF).Width;
    }

    private Size TextSize(Graphics g) {
        if (string.IsNullOrEmpty(Text)) return Size.Empty;
        return TextRenderer.MeasureText(g, Text, Font, Size.Empty, TF);
    }

    public override Size GetPreferredSize(Size proposedSize) {
        using (Graphics g = CreateGraphics()) {
            Size ts = TextSize(g);
            int gw = GlyphWidth(g);
            int w = Padding.Horizontal + ts.Width + gw + (gw > 0 && ts.Width > 0 ? Gap : 0);
            int h = Math.Max(ts.Height, Font.Height) + Padding.Vertical;
            return new Size(Math.Max(w, MinimumSize.Width), Math.Max(h, MinimumSize.Height));
        }
    }

    private void GetColors(out Color fill, out Color border, out Color fore) {
        Color none = Color.Empty;
        bool ghost = (_kind == "ghost" || _kind == "ghost-dark" || _kind == "nav");
        if (!Enabled) {
            fill = ghost ? none : WeBotUi.Hex("#EEF1F4");
            border = none;
            fore = _kind == "ghost-dark" ? WeBotUi.Hex("#5C626B") : WeBotUi.Hex("#A7B1BC");
            return;
        }
        switch (_kind) {
            case "primary":
                fill = WeBotUi.Hex(_down ? "#0E7A50" : (_hover ? "#12915F" : "#16A06A")); border = none; fore = Color.White; break;
            case "danger":
                fill = WeBotUi.Hex(_down ? "#B83A35" : (_hover ? "#CF4742" : "#E0524D")); border = none; fore = Color.White; break;
            case "ghost":
                fill = _down ? WeBotUi.Hex("#DDE3E9") : (_hover ? WeBotUi.Hex("#E9EDF1") : none); border = none; fore = WeBotUi.Hex("#3E4C59"); break;
            case "ghost-dark":
                fill = _down ? WeBotUi.Hex("#3E4147") : (_hover ? WeBotUi.Hex("#33363B") : none); border = none; fore = WeBotUi.Hex(_hover ? "#E6E8EB" : "#AEB4BD"); break;
            case "nav":
                if (_selected) { fill = WeBotUi.Hex("#E1F3EA"); fore = WeBotUi.Hex("#0E7A50"); }
                else { fill = _down ? WeBotUi.Hex("#DDE3E9") : (_hover ? WeBotUi.Hex("#E9EDF1") : none); fore = WeBotUi.Hex("#3E4C59"); }
                border = none; break;
            default:
                fill = WeBotUi.Hex(_down ? "#E3E8ED" : (_hover ? "#F2F5F8" : "#FFFFFF"));
                border = WeBotUi.Hex(_hover ? "#C5CED7" : "#D9DFE5");
                fore = WeBotUi.Hex("#1F2933"); break;
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(WeBotUi.BackOf(this));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill, border, fore;
        GetColors(out fill, out border, out fore);
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (GraphicsPath p = WeBotUi.Round(r, _radius)) {
            if (fill.A > 0) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
            if (border.A > 0) using (Pen pen = new Pen(border)) g.DrawPath(pen, p);
        }
        if (_kind == "nav" && _selected) {
            float bh = Height * 0.5f;
            using (GraphicsPath p = WeBotUi.Round(new RectangleF(1f, (Height - bh) / 2f, 3.5f, bh), 1.75f))
            using (SolidBrush b = new SolidBrush(WeBotUi.Hex("#16A06A"))) g.FillPath(b, p);
        }
        if (Focused && ShowFocusCues) {
            RectangleF fr = new RectangleF(1.5f, 1.5f, Width - 3.5f, Height - 3.5f);
            using (GraphicsPath p = WeBotUi.Round(fr, Math.Max(1, _radius - 1)))
            using (Pen pen = new Pen(Color.FromArgb(150, 22, 160, 106), 1.5f)) g.DrawPath(pen, p);
        }

        int gw = GlyphWidth(g);
        Size ts = TextSize(g);
        int gap = (gw > 0 && ts.Width > 0) ? Gap : 0;
        int total = gw + gap + ts.Width;
        int x = _leftAlign ? Padding.Left : Math.Max(0, (Width - total) / 2);
        if (gw > 0) {
            TextRenderer.DrawText(g, _glyph, GlyphFont, new Rectangle(x, 1, gw + 2, Height), fore, TF);
            x += gw + gap;
        }
        if (ts.Width > 0) {
            TextRenderer.DrawText(g, Text, Font, new Rectangle(x, 0, Math.Max(1, Width - x), Height), fore, TF | TextFormatFlags.EndEllipsis);
        }
    }

    protected override void Dispose(bool disposing) {
        if (disposing && _glyphFont != null) { _glyphFont.Dispose(); _glyphFont = null; }
        base.Dispose(disposing);
    }
}

public class WeBotCard : Panel {
    private Color _fill = Color.White;
    private Color _border = WeBotUi.Hex("#E1E6EB");
    private int _radius = 8;

    public WeBotCard() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    public Color Fill { get { return _fill; } set { _fill = value; BackColor = value; Invalidate(true); } }
    public Color BorderColor { get { return _border; } set { _border = value; Invalidate(); } }
    public int Radius { get { return _radius; } set { _radius = value; Invalidate(); } }

    protected override void OnPaintBackground(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(WeBotUi.BackOf(this));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = WeBotUi.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), _radius)) {
            using (SolidBrush b = new SolidBrush(_fill)) g.FillPath(b, p);
            if (_border.A > 0) using (Pen pen = new Pen(_border)) g.DrawPath(pen, p);
        }
    }
}

public class WeBotPill : Control {
    private Color _dot = Color.Gray;

    public WeBotPill() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    public Color DotColor { get { return _dot; } set { _dot = value; Invalidate(); } }

    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Size = GetPreferredSize(Size.Empty); Invalidate(); }
    protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Size = GetPreferredSize(Size.Empty); Invalidate(); }

    private int DotSize { get { return Math.Max(6, (int)(Font.Height * 0.42)); } }

    public override Size GetPreferredSize(Size proposedSize) {
        Size ts = TextRenderer.MeasureText(Text ?? "", Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        int h = ts.Height + (int)(Font.Height * 0.75);
        int pad = h / 2;
        return new Size(pad + DotSize + DotSize + ts.Width + pad, h);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(WeBotUi.BackOf(this));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (GraphicsPath p = WeBotUi.Round(r, r.Height / 2f)) {
            using (SolidBrush b = new SolidBrush(WeBotUi.Mix(_dot, Color.White, 0.88f))) g.FillPath(b, p);
            using (Pen pen = new Pen(WeBotUi.Mix(_dot, Color.White, 0.62f))) g.DrawPath(pen, p);
        }
        int pad = Height / 2;
        int d = DotSize;
        using (SolidBrush b = new SolidBrush(_dot)) g.FillEllipse(b, pad - d / 3f, (Height - d) / 2f, d, d);
        Rectangle tr = new Rectangle(pad + d + d - d / 3, 0, Width, Height);
        TextRenderer.DrawText(g, Text, Font, tr, WeBotUi.Mix(_dot, Color.Black, 0.3f),
            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
    }
}

public class WeBotBar : Control {
    private int _value;
    private Color _bar = WeBotUi.Hex("#16A06A");

    public WeBotBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    public int Value { get { return _value; } set { _value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
    public Color BarColor { get { return _bar; } set { _bar = value; Invalidate(); } }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(WeBotUi.BackOf(this));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float h = Height - 1f;
        using (GraphicsPath p = WeBotUi.Round(new RectangleF(0, 0, Width - 1f, h), h / 2f))
        using (SolidBrush b = new SolidBrush(WeBotUi.Hex("#E9EDF1"))) g.FillPath(b, p);
        float w = (Width - 1f) * _value / 100f;
        if (w >= 1f) {
            using (GraphicsPath p = WeBotUi.Round(new RectangleF(0, 0, Math.Max(w, h), h), h / 2f))
            using (SolidBrush b = new SolidBrush(_bar)) g.FillPath(b, p);
        }
    }
}

public class WeBotLogo : Control {
    public WeBotLogo() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(WeBotUi.BackOf(this));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        RectangleF r = new RectangleF(0, 0, Width - 1f, Height - 1f);
        using (GraphicsPath p = WeBotUi.Round(r, Width * 0.28f))
        using (LinearGradientBrush b = new LinearGradientBrush(r, WeBotUi.Hex("#22B97C"), WeBotUi.Hex("#0E7F53"), 45f))
            g.FillPath(b, p);
        using (Font f = new Font("Segoe UI", Height * 0.5f, FontStyle.Bold, GraphicsUnit.Pixel))
        using (StringFormat sf = new StringFormat()) {
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            g.DrawString("W", f, Brushes.White, new RectangleF(0, Height * 0.03f, Width, Height), sf);
        }
    }
}
'@
if (-not ([System.Management.Automation.PSTypeName]'WeBotButton').Type) {
    Add-Type -TypeDefinition $ui_code -ReferencedAssemblies System.Windows.Forms, System.Drawing
}
# 图标字体字形（Segoe Fluent Icons / MDL2 共用码位）。
function Get-Glyph([int]$code) { if ([WeBotUi]::IconFontName) { return [string][char]$code } else { return '' } }
$G = @{
    Play = Get-Glyph 0xE768; Stop = Get-Glyph 0xE71A; Settings = Get-Glyph 0xE713; Crop = Get-Glyph 0xE7A8
    History = Get-Glyph 0xE81C; Folder = Get-Glyph 0xE838; Delete = Get-Glyph 0xE74D; Refresh = Get-Glyph 0xE72C
    Save = Get-Glyph 0xE74E; Info = Get-Glyph 0xE946; Warning = Get-Glyph 0xE7BA; Error = Get-Glyph 0xEA39
    Bolt = Get-Glyph 0xE945; Chat = Get-Glyph 0xE8BD; Chart = Get-Glyph 0xE9D2; Clock = Get-Glyph 0xE916
    Robot = Get-Glyph 0xE99A; Persona = Get-Glyph 0xE77B; Memory = Get-Glyph 0xE8F1; Send = Get-Glyph 0xE724
    Timer = Get-Glyph 0xE823; Spark = Get-Glyph 0xE945; Log = Get-Glyph 0xE9F9; Play2 = Get-Glyph 0xE768
}

# 直接运行 .ps1 时隐藏自身的控制台窗口。
try { $cw = [WeBotEngineProcess]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][WeBotEngineProcess]::ShowWindow($cw, 0) } } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

# 路径
if (-not $EnginePath) {
    $EnginePath = Join-Path $PSScriptRoot 'WeBot-Engine.ps1'
    # 兼容改名前的旧文件名。
    $legacyEngine = Join-Path $PSScriptRoot '127.ps1'
    if (-not (Test-Path -LiteralPath $EnginePath) -and (Test-Path -LiteralPath $legacyEngine)) { $EnginePath = $legacyEngine }
}
if (-not (Test-Path -LiteralPath $EnginePath)) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择 WeBot 引擎脚本（WeBot-Engine.ps1）'
    $dlg.Filter = 'PowerShell 脚本 (*.ps1)|*.ps1'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $EnginePath = $dlg.FileName
}
$EnginePath = [System.IO.Path]::GetFullPath($EnginePath)
$AppDir = Split-Path -Parent $EnginePath
$CONFIG_FILE = Join-Path $AppDir 'config.json'
$HISTORY_FILE = Join-Path $AppDir 'chat_history.json'
$SUMMARY_FILE = Join-Path $AppDir 'summary.txt'
$PS_EXE = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PS_EXE)) { $PS_EXE = (Get-Process -Id $PID).Path }

# 界面状态，事件脚本块通过脚本作用域共享。
$S = @{
    Engine        = $null
    Calib         = $null
    Phase         = 'Stopped'     # Stopped | Starting | Running | Stopping
    StopRequested = $false
    StopDeadline  = [DateTime]::MaxValue
    FatalSeen     = $false
    StartedAt     = $null
    Mode          = ''
    LogLines      = 0
    ExitRequested = $false
    TrayTipShown  = $false
    LastUptimeAt  = [DateTime]::MinValue
}

# 配色与字体
function New-Color([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
$C = @{
    Accent     = New-Color '#16A06A'
    AccentDark = New-Color '#0E7A50'
    Danger     = New-Color '#D9534F'
    Bg         = New-Color '#F4F6F8'
    Card       = [System.Drawing.Color]::White
    Border     = New-Color '#DDE2E7'
    Text       = New-Color '#1F2933'
    Muted      = New-Color '#6B7785'
    LogBg      = New-Color '#1E1F22'
    LogBorder  = New-Color '#2B2D31'
    LogLine    = New-Color '#2F3237'
    LogTitle   = New-Color '#AEB4BD'
    WarnBg     = New-Color '#FFF6DD'
    WarnBd     = New-Color '#F3DFA2'
    WarnFg     = New-Color '#7A5400'
    ErrBg      = New-Color '#FDECEB'
    ErrBd      = New-Color '#F4C2BF'
    ErrFg      = New-Color '#8A1F1B'
    InfoBg     = New-Color '#E8F3FC'
    InfoBd     = New-Color '#BFDDF4'
    InfoFg     = New-Color '#14527A'
}
$UiFontName = 'Microsoft YaHei UI'
$F = @{
    Ui       = New-Object System.Drawing.Font($UiFontName, 9)
    UiBold   = New-Object System.Drawing.Font($UiFontName, 9, [System.Drawing.FontStyle]::Bold)
    Small    = New-Object System.Drawing.Font($UiFontName, 8.25)
    Title    = New-Object System.Drawing.Font($UiFontName, 14, [System.Drawing.FontStyle]::Bold)
    PageHead = New-Object System.Drawing.Font($UiFontName, 12, [System.Drawing.FontStyle]::Bold)
    CardVal  = New-Object System.Drawing.Font($UiFontName, 13, [System.Drawing.FontStyle]::Bold)
    Log      = New-Object System.Drawing.Font('Consolas', 10)
}
$LogColors = @{
    Default = New-Color '#D4D4D4'; White = New-Color '#F5F5F5'; Gray = New-Color '#C8C8C8'; DarkGray = New-Color '#8A8F98'
    Red = New-Color '#F47067'; DarkRed = New-Color '#E5534B'; Yellow = New-Color '#F2CC60'; DarkYellow = New-Color '#D7A85A'
    Green = New-Color '#57D38C'; DarkGreen = New-Color '#3FB950'; Cyan = New-Color '#56D4DD'; DarkCyan = New-Color '#39C5CF'
    Magenta = New-Color '#DA77F2'; DarkMagenta = New-Color '#BC6FE0'; Blue = New-Color '#6CB6FF'; DarkBlue = New-Color '#539BF5'
    Black = New-Color '#8A8F98'
}
$ModeInfo = @{
    Stopped     = @{ Text = '未运行'; Color = New-Color '#8A949E' }
    Starting    = @{ Text = '启动中'; Color = New-Color '#5B8DEF' }
    Stopping    = @{ Text = '正在停止'; Color = New-Color '#8A949E' }
    Blocked     = @{ Text = '已暂停'; Color = New-Color '#D98E04' }
    Listening   = @{ Text = '监听中'; Color = New-Color '#1C9AAE' }
    Thinking    = @{ Text = '思考中'; Color = New-Color '#D98E04' }
    Replying    = @{ Text = '输出中'; Color = New-Color '#16A06A' }
    WaitingUser = @{ Text = '等你离开微信'; Color = New-Color '#A55FC9' }
    Delaying    = @{ Text = '延迟回复中'; Color = New-Color '#C17A1A' }
}

# 服务商预设（与控制台向导一致；isVision 表示可用于聊天截图识别）。
$Presets = @(
    @{ name = "DeepSeek (多模态)"; url = "https://api.deepseek.com/chat/completions"; type = "OpenAI"; model = "deepseek-flash"; isVision = $true },
    @{ name = "Qwen (通义千问)"; url = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"; type = "Ali"; model = "qwen3.8-flash"; isVision = $true },
    @{ name = "Google Gemini"; url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"; type = "OpenAI"; model = "gemini-3.8-flash"; isVision = $true },
    @{ name = "OpenAI"; url = "https://api.openai.com/v1/chat/completions"; type = "OpenAI"; model = "gpt-6.1-sol"; isVision = $true },
    @{ name = "Anthropic"; url = "https://api.anthropic.com/v1/messages"; type = "Anthropic"; model = "claude-opus-5-5"; isVision = $true },
    @{ name = "Hugging Face"; url = "https://router.huggingface.co/v1/chat/completions"; type = "OpenAI"; model = "Qwen/Qwen3-VL-8B-Instruct"; isVision = $true },
    @{ name = "DeepSeek V4 Pro (仅文本，适合总结)"; url = "https://api.deepseek.com/chat/completions"; type = "OpenAI"; model = "deepseek-v4-pro"; isVision = $false },
    @{ name = "Ollama (本地)"; url = "http://localhost:11434/v1/chat/completions"; type = "OpenAI"; model = "qwen3.8:27b"; isVision = $true }
)

#region 通用工具
function Format-TokenCount($n) {
    if ($null -eq $n -or "$n" -eq '') { return '0' }
    $v = [double]$n
    if ($v -ge 1000000) { return ('{0:0.##}M' -f ($v / 1000000)) }
    if ($v -ge 1000) { return ('{0:0.#}k' -f ($v / 1000)) }
    return ('{0:0}' -f $v)
}

function ConvertFrom-GuiField([string]$s) {
    if ($s.IndexOf([char]'\') -lt 0) { return $s }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($ch -eq [char]'\' -and $i + 1 -lt $s.Length) {
            $i++
            $n = $s[$i]
            if ($n -ceq [char]'t') { [void]$sb.Append("`t") }
            elseif ($n -ceq [char]'r') { [void]$sb.Append("`r") }
            elseif ($n -ceq [char]'n') { [void]$sb.Append("`n") }
            else { [void]$sb.Append($n) }
        }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Read-ConfigObject {
    if (-not (Test-Path -LiteralPath $CONFIG_FILE)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $CONFIG_FILE -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($obj -is [PSCustomObject]) { return $obj }
    }
    catch {}
    return $null
}

function Get-ConfigValue($obj, [string]$path) {
    foreach ($part in $path.Split('.')) {
        if ($null -eq $obj) { return $null }
        $p = $obj.PSObject.Properties[$part]
        if (-not $p) { return $null }
        $obj = $p.Value
    }
    return $obj
}

function Set-ConfigValue($obj, [string]$path, $value) {
    $parts = $path.Split('.')
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $p = $obj.PSObject.Properties[$parts[$i]]
        if (-not $p -or $p.Value -isnot [PSCustomObject]) {
            $child = [PSCustomObject]@{}
            if ($p) { $p.Value = $child } else { $obj | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue $child }
            $obj = $child
        }
        else { $obj = $p.Value }
    }
    $last = $parts[-1]
    if ($obj.PSObject.Properties[$last]) { $obj.$last = $value }
    else { $obj | Add-Member -NotePropertyName $last -NotePropertyValue $value }
}

# 与引擎相同的原子写入：临时文件 + 替换，UTF-8 带 BOM。
function Write-ConfigObject($obj) {
    $text = ConvertTo-Json -InputObject $obj -Depth 10
    $tmp = Join-Path $AppDir ([System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
        if ([System.IO.File]::Exists($CONFIG_FILE)) { [System.IO.File]::Replace($tmp, $CONFIG_FILE, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $CONFIG_FILE) }
    }
    finally { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } }
}

function Show-Msg([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    $owner = [System.Windows.Forms.Form]::ActiveForm
    if (-not $owner) { $owner = $script:MainForm }
    return [System.Windows.Forms.MessageBox]::Show($owner, $text, 'WeBot',
        [System.Windows.Forms.MessageBoxButtons]::$buttons, [System.Windows.Forms.MessageBoxIcon]::$icon)
}

function Test-EngineRunning { return ($S.Engine -and -not $S.Engine.HasExited) }

function New-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $brush = New-Object System.Drawing.SolidBrush($C.Accent)
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString('W', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
    $g.Dispose(); $brush.Dispose(); $font.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# 自绘按钮自己处理悬停/禁用配色，这里只需重绘。
function Update-ButtonLook($b) { $b.Invalidate() }

function Set-ButtonStyle($b, [string]$kind) {
    $b.Kind = $kind
    $b.Font = $F.Ui
    $b.Radius = (Px 6)
    $b.Height = (Px 34)
    $b.Padding = New-Object System.Windows.Forms.Padding((Px 14), 0, (Px 14), 0)
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size((Px 84), (Px 34))
}

function New-Button([string]$text, [string]$kind = 'secondary', [string]$glyph = '') {
    $b = New-Object WeBotButton
    $b.Text = $text
    $b.Glyph = $glyph
    Set-ButtonStyle $b $kind
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, (Px 8), 0)
    return $b
}

# 对话框底部按钮栏（带顶部分隔线）。
function New-DialogBar($form) {
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'
    $bar.FlowDirection = 'RightToLeft'
    $bar.Height = (Px 60)
    $bar.Padding = New-Object System.Windows.Forms.Padding((Px 14), (Px 13), (Px 6), (Px 12))
    $bar.BackColor = $C.Bg
    $line = New-Object System.Windows.Forms.Panel
    $line.Dock = 'Bottom'
    $line.Height = 1
    $line.BackColor = $C.Border
    return @{ Bar = $bar; Line = $line }
}
#endregion

#region 日志区
function Add-LogText([string]$text, [string]$color = 'Default', [bool]$newline = $true) {
    $rtb = $script:LogBox
    $col = $LogColors[$color]
    if (-not $col) { $col = $LogColors.Default }
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor = $col
    if ($newline) { $rtb.AppendText($text + "`n"); $S.LogLines++ } else { $rtb.AppendText($text) }

    # 超过 4000 行时裁掉最早的 1000 行。
    if ($S.LogLines -gt 4000) {
        $cut = $rtb.GetFirstCharIndexFromLine(1000)
        if ($cut -gt 0) {
            $rtb.ReadOnly = $false
            $rtb.Select(0, $cut)
            $rtb.SelectedText = ''
            $rtb.ReadOnly = $true
            $S.LogLines -= 1000
        }
    }
}

function Add-GuiNote([string]$text, [string]$color = 'DarkGray') {
    Add-LogText ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $text) $color $true
}
#endregion

#region 横幅提示
function Show-Banner([string]$text, [string]$kind = 'warn', [string]$buttonText = '', [scriptblock]$action = $null) {
    $p = $script:Banner
    $card = $script:BannerCard
    switch ($kind) {
        'error' { $bg = $C.ErrBg; $bd = $C.ErrBd; $fg = $C.ErrFg; $gl = $G.Error }
        'info' { $bg = $C.InfoBg; $bd = $C.InfoBd; $fg = $C.InfoFg; $gl = $G.Info }
        default { $bg = $C.WarnBg; $bd = $C.WarnBd; $fg = $C.WarnFg; $gl = $G.Warning }
    }
    $card.Fill = $bg
    $card.BorderColor = $bd
    foreach ($l in @($script:BannerLabel, $script:BannerIcon)) { $l.BackColor = $bg; $l.ForeColor = $fg }
    $script:BannerIcon.Text = $gl
    $script:BannerLabel.Text = $text
    $script:BannerAction = $action
    $script:BannerButton.Visible = [bool]$buttonText
    $script:BannerButton.Text = $buttonText
    $script:BannerKind = $kind
    $p.Visible = $true
}
function Hide-Banner { $script:Banner.Visible = $false; $script:BannerAction = $null; $script:BannerKind = '' }
#endregion

#region 状态显示
function Update-ModelCard {
    $cfg = Read-ConfigObject
    if (-not $cfg) {
        $script:CardModel.Value.Text = '尚未配置'
        $script:CardModel.Detail.Text = '点击「设置」完成首次配置'
        return
    }
    $type = Get-ConfigValue $cfg 'Chat.ProviderType'
    $model = Get-ConfigValue $cfg 'Chat.Model'
    $script:CardModel.Value.Text = if ($model) { [string]$model } else { '未填写模型' }
    $send = switch ([string]$cfg.SendMethod) { 'WMChar' { '后台注入' } 'Clipboard' { '剪贴板' } default { '智能混合' } }
    $mem = if (Get-ConfigValue $cfg 'Summary.enabled') { '开' } else { '关' }
    $pro = if ($cfg.EnableProactive) { '开' } else { '关' }
    $script:CardModel.Detail.Text = "$type · 记忆$mem · 主动$pro · $send"
}

function Update-StatusView {
    $key = switch ($S.Phase) {
        'Running' { if ($script:BannerKind -eq 'block') { 'Blocked' } elseif ($S.Mode -and $ModeInfo.ContainsKey($S.Mode)) { $S.Mode } else { 'Listening' } }
        default { $S.Phase }
    }
    $info = $ModeInfo[$key]
    $script:StatusPill.Text = $info.Text
    $script:StatusPill.DotColor = $info.Color
    $script:CardState.Value.Text = $info.Text
    $script:CardState.Value.ForeColor = $info.Color

    $detail = ''
    if ($S.Phase -eq 'Running') {
        if ($S.WaitLabel) { $detail = "$($S.WaitLabel) $($S.WaitSec)s" }
        elseif ("$($S.RemainSec)" -ne '') { $detail = "还剩 $($S.RemainSec)s" }
        else { $detail = '正在监听微信聊天画面' }
    }
    elseif ($S.Phase -eq 'Stopped') { $detail = '点击「启动」开始自动回复' }
    elseif ($S.Phase -eq 'Starting') { $detail = '正在加载组件与配置…' }
    elseif ($S.Phase -eq 'Stopping') { $detail = '等待当前操作完成…' }
    $script:CardState.Detail.Text = $detail

    if ("$($S.UsageTotal)" -ne '') {
        $script:CardUsage.Value.Text = "↑ $(Format-TokenCount $S.UsageIn)   ↓ $(Format-TokenCount $S.UsageOut)"
        $limit = 0
        try { $limit = [double]$S.UsageLimit } catch {}
        $d = "共 $(Format-TokenCount $S.UsageTotal) · $($S.UsageReq) 次请求"
        if ($limit -gt 0) {
            $pct = [Math]::Min(100, [int](100 * [double]$S.UsageTotal / $limit))
            $d += " · 上限 $(Format-TokenCount $limit)"
            if ([double]$S.UsageTotal -ge $limit) { $d += '（已达上限）' }
            $script:UsageBar.Visible = $true
            $script:UsageBar.Value = $pct
            $script:UsageBar.BarColor = if ($pct -ge 100) { $C.Danger } elseif ($pct -ge 80) { New-Color '#D98E04' } else { $C.Accent }
        }
        else { $script:UsageBar.Visible = $false }
        $script:CardUsage.Detail.Text = $d
    }

    $running = ($S.Phase -ne 'Stopped')
    $script:BtnStart.Enabled = -not $running
    $script:BtnStop.Enabled = ($S.Phase -eq 'Running' -or $S.Phase -eq 'Starting')
    $script:BtnCalib.Enabled = -not ($S.Calib -and -not $S.Calib.HasExited)
    foreach ($b in @($script:BtnStart, $script:BtnStop, $script:BtnCalib)) { Update-ButtonLook $b }
    $script:TrayStart.Enabled = $script:BtnStart.Enabled
    $script:TrayStop.Enabled = $script:BtnStop.Enabled
    $script:Tray.Text = 'WeBot · ' + $info.Text
}

function Update-Uptime {
    if ($S.StartedAt -and $S.Phase -ne 'Stopped') {
        $span = (Get-Date) - $S.StartedAt
        $script:CardUptime.Value.Text = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
        $script:CardUptime.Detail.Text = "引擎 PID $($S.Engine.Id) · 自 $($S.StartedAt.ToString('HH:mm'))"
    }
}
#endregion

#region 引擎控制
function Start-Engine {
    if (Test-EngineRunning) { return }
    if (-not (Read-ConfigObject)) {
        [void](Show-Msg '还没有可用的配置。请先在「设置」中填写 AI 服务商、API Key 和模型。')
        if (-not (Show-SettingsDialog)) { return }
    }
    Hide-Banner
    $S.Engine = New-Object WeBotEngineProcess
    $S.Phase = 'Starting'
    $S.StopRequested = $false
    $S.FatalSeen = $false
    $S.StopDeadline = [DateTime]::MaxValue
    $S.Mode = ''
    $S.WaitLabel = ''; $S.WaitSec = ''; $S.RemainSec = ''
    $S.StartedAt = Get-Date
    Add-LogText '' 'Default' $true
    Add-GuiNote "———— 启动引擎 ————" 'Cyan'
    try {
        $S.Engine.Start($PS_EXE, ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Gui -ParentPid {1}' -f $EnginePath, $PID), $AppDir)
    }
    catch {
        $S.Phase = 'Stopped'
        Add-GuiNote "启动失败：$($_.Exception.Message)" 'Red'
        Show-Banner "引擎启动失败：$($_.Exception.Message)" 'error'
    }
    Update-ModelCard
    Update-StatusView
}

function Stop-Engine {
    if (-not (Test-EngineRunning)) { return }
    $S.StopRequested = $true
    $S.Phase = 'Stopping'
    $S.StopDeadline = (Get-Date).AddSeconds(10)
    Add-GuiNote '正在停止引擎…'
    if (-not $S.Engine.Signal('WeBot_Stop_')) {
        # 引擎还没建好停止事件（刚启动）时直接结束进程。
        $S.Engine.Kill()
    }
    if ($script:BannerKind -eq 'block') { Hide-Banner }
    Update-StatusView
}

function Stop-EngineAndWait {
    if (-not (Test-EngineRunning)) { return }
    Stop-Engine
    $deadline = (Get-Date).AddSeconds(8)
    while ((Test-EngineRunning) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.Application]::DoEvents()
    }
    if (Test-EngineRunning) { $S.Engine.Kill() }
}

function Start-Calibration {
    if ($S.Calib -and -not $S.Calib.HasExited) { return }
    Add-GuiNote '打开截图区域校准窗口（请保持微信窗口可见）…' 'Cyan'
    $S.Calib = New-Object WeBotEngineProcess
    $S.CalibSaved = $false
    try {
        $S.Calib.Start($PS_EXE, ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Calibrate -ParentPid {1}' -f $EnginePath, $PID), $AppDir)
    }
    catch {
        Add-GuiNote "校准窗口启动失败：$($_.Exception.Message)" 'Red'
        $S.Calib = $null
    }
    Update-StatusView
}

function Invoke-EngineLine([string]$line, [string]$source) {
    if (-not $line.StartsWith('@@')) { Add-LogText $line 'Default' $true; return }
    $parts = $line.Substring(2).Split("`t")
    $kind = $parts[0]
    $fx = @()
    for ($i = 1; $i -lt $parts.Count; $i++) { $fx += , (ConvertFrom-GuiField $parts[$i]) }
    switch ($kind) {
        'W' { if ($fx.Count -ge 3) { Add-LogText $fx[2] $fx[0] ($fx[1] -eq '1') } }
        'ERR' { Add-LogText ($line.Substring(6)) 'Red' $true }
        'STATUS' {
            if ($S.Phase -eq 'Starting') { $S.Phase = 'Running' }
            $S.Mode = $fx[0]; $S.WaitLabel = $fx[1]; $S.WaitSec = $fx[2]; $S.RemainSec = $fx[3]
            if ($fx.Count -ge 9 -and $fx[6] -ne '') { $S.UsageIn = $fx[4]; $S.UsageOut = $fx[5]; $S.UsageTotal = $fx[6]; $S.UsageReq = $fx[7]; $S.UsageLimit = $fx[8] }
            $script:StatusDirty = $true
        }
        'STARTED' { if ($S.Phase -eq 'Starting') { $S.Phase = 'Running' }; $script:StatusDirty = $true }
        'ALERT' {
            $icon = switch ($fx[0]) { 'Error' { 'Error' } 'Info' { 'Info' } default { 'Warning' } }
            $script:Tray.ShowBalloonTip(10000, $fx[1], $fx[2], [System.Windows.Forms.ToolTipIcon]::$icon)
        }
        'BLOCK' {
            Show-Banner "微信已$($fx[0])，自动回复已暂停。请还原微信窗口后点击「继续」。" 'warn' '继续' {
                if ($S.Engine) { [void]$S.Engine.Signal('WeBot_Continue_') }
                Hide-Banner
                Update-StatusView
            }
            $script:BannerKind = 'block'
            $script:StatusDirty = $true
        }
        'UNBLOCK' { if ($script:BannerKind -eq 'block') { Hide-Banner }; $script:StatusDirty = $true }
        'STOPPED' { }
        'FATAL' { $S.FatalSeen = $true }
        'CALIBRATED' { $S.CalibSaved = $true }
        default { }
    }
}

function Invoke-EngineExit($proc) {
    $code = $proc.ExitCode
    $S.Phase = 'Stopped'
    $S.Mode = ''
    if ($script:BannerKind -eq 'block') { Hide-Banner }
    if ($S.StopRequested) {
        Add-GuiNote '———— 引擎已停止 ————' 'Cyan'
    }
    elseif ($S.FatalSeen) {
        Add-GuiNote "———— 引擎因 AI 接口错误停止 ————" 'Red'
        Show-Banner 'AI 接口配置或权限错误，自动回复已停止。请检查 API Key、模型名和接口地址后重新启动。' 'error' '打开设置' { [void](Show-SettingsDialog) }
    }
    elseif ($code -eq 2) {
        Add-GuiNote "———— 引擎退出：配置缺失或无法解析 ————" 'Red'
        Show-Banner '配置缺失或无法解析，请在「设置」中重新保存配置。' 'error' '打开设置' { [void](Show-SettingsDialog) }
    }
    else {
        Add-GuiNote "———— 引擎意外退出（代码 $code）————" 'Red'
        Show-Banner "引擎意外退出（代码 $code），详细原因见下方日志。" 'error' '重新启动' { Start-Engine }
        $script:Tray.ShowBalloonTip(8000, 'WeBot 已停止', "引擎意外退出（代码 $code）", [System.Windows.Forms.ToolTipIcon]::Error)
    }
    $S.Engine = $null
    $script:StatusDirty = $true
}

function Invoke-Pump {
    $wroteLog = $false
    foreach ($src in @('Engine', 'Calib')) {
        $proc = $S[$src]
        if (-not $proc) { continue }
        $line = $null
        $n = 0
        while ($n -lt 500 -and $proc.TryDequeue([ref]$line)) {
            Invoke-EngineLine $line $src
            $n++
        }
        if ($n -gt 0) { $wroteLog = $true }
        if ($n -lt 500 -and $proc.HasExited -and [object]::ReferenceEquals($S[$src], $proc)) {
            $proc.FinishExit()
            while ($proc.TryDequeue([ref]$line)) { Invoke-EngineLine $line $src; $wroteLog = $true }
            if ($src -eq 'Engine') { Invoke-EngineExit $proc }
            else {
                $code = $proc.ExitCode
                $S.Calib = $null
                if ($S.CalibSaved -or $code -eq 0) {
                    Add-GuiNote '截图区域已保存。' 'Green'
                    if (Test-EngineRunning) {
                        if ((Show-Msg "截图区域已保存，重启引擎后生效。现在重启吗？" 'Question' 'YesNo') -eq 'Yes') {
                            Stop-EngineAndWait; Invoke-Pump; Start-Engine
                        }
                    }
                }
                $script:StatusDirty = $true
            }
        }
    }
    if ($wroteLog -and $script:ChkAutoScroll.Checked) { $script:LogBox.ScrollToCaret() }

    if ($S.Phase -eq 'Stopping' -and (Get-Date) -gt $S.StopDeadline -and (Test-EngineRunning)) {
        Add-GuiNote '引擎未在 10 秒内退出，已强制结束。' 'Yellow'
        $S.Engine.Kill()
        $S.StopDeadline = [DateTime]::MaxValue
    }
    if ($script:StatusDirty) { $script:StatusDirty = $false; Update-StatusView }
    if (((Get-Date) - $S.LastUptimeAt).TotalMilliseconds -ge 1000) { $S.LastUptimeAt = Get-Date; Update-Uptime }
}
#endregion

#region 设置对话框
# 字段描述：Path 为 config.json 中的属性路径；Kind = bool | int | double | text | secret | combo。
$FieldDefs = @(
    @{ Tab = 'chat'; Path = 'Chat.ProviderType'; Kind = 'combo'; Label = '接口类型'; Items = @('OpenAI', 'Ali', 'Anthropic'); Default = 'OpenAI'; Note = 'OpenAI 兼容 / 阿里 DashScope / Anthropic' }
    @{ Tab = 'chat'; Path = 'Chat.ApiUrl'; Kind = 'text'; Label = 'API 地址'; Default = ''; Note = '完整的请求地址' }
    @{ Tab = 'chat'; Path = 'Chat.ApiKey'; Kind = 'secret'; Label = 'API Key'; Default = '' }
    @{ Tab = 'chat'; Path = 'Chat.Model'; Kind = 'text'; Label = '模型名称'; Default = ''; Note = '需要支持图片识别' }
    @{ Tab = 'chat'; Path = 'Chat.MaxTokens'; Kind = 'int'; Label = '最大输出 Token'; Min = 1; Max = 200000; Default = 1024 }
    @{ Tab = 'chat'; Path = 'Chat.TimeoutSeconds'; Kind = 'int'; Label = '请求超时（秒）'; Min = 1; Max = 600; Default = 60 }
    @{ Tab = 'chat'; Path = 'Chat.DeepThinking'; Kind = 'bool'; Label = '深度思考'; Default = $false; Note = '模型支持时开启推理，回复更慢' }
    @{ Tab = 'chat'; Path = 'Chat.AbnormalResponseMaxRetry'; Kind = 'int'; Label = '异常回复重试次数'; Min = 0; Max = 5; Default = 2 }
    @{ Tab = 'chat'; Path = 'Chat.SendFailureMaxRetry'; Kind = 'int'; Label = '发送失败重试次数'; Min = 0; Max = 5; Default = 2 }

    @{ Tab = 'memory'; Path = 'Summary.enabled'; Kind = 'bool'; Label = '开启长期记忆'; Default = $false; Note = '聊天记录过长时把旧对话总结成长期记忆' }
    @{ Tab = 'memory'; Path = 'Summary.triggerCount'; Kind = 'int'; Label = '触发总结的消息数'; Min = 1; Max = 10000; Default = 15 }
    @{ Tab = 'memory'; Path = 'Summary.retainCount'; Kind = 'int'; Label = '总结后保留的近期对话'; Min = 0; Max = 9999; Default = 5; Note = '必须小于触发数' }
    @{ Tab = 'memory'; Path = 'HistoryContextMaxEntries'; Kind = 'int'; Label = '发给 AI 的近期对话条数'; Min = 1; Max = 1000; Default = 50 }
    @{ Tab = 'memory'; Path = 'Summary.ProviderType'; Kind = 'combo'; Label = '总结接口类型'; Items = @('OpenAI', 'Ali', 'Anthropic'); Default = 'OpenAI'; Group = 'sum' }
    @{ Tab = 'memory'; Path = 'Summary.ApiUrl'; Kind = 'text'; Label = '总结 API 地址'; Default = ''; Group = 'sum' }
    @{ Tab = 'memory'; Path = 'Summary.ApiKey'; Kind = 'secret'; Label = '总结 API Key'; Default = ''; Group = 'sum' }
    @{ Tab = 'memory'; Path = 'Summary.Model'; Kind = 'text'; Label = '总结模型'; Default = ''; Group = 'sum'; Note = '可用仅文本模型' }
    @{ Tab = 'memory'; Path = 'Summary.MaxTokens'; Kind = 'int'; Label = '总结最大 Token'; Min = 1; Max = 200000; Default = 1024; Group = 'sum' }
    @{ Tab = 'memory'; Path = 'Summary.TimeoutSeconds'; Kind = 'int'; Label = '总结超时（秒）'; Min = 1; Max = 600; Default = 60; Group = 'sum' }
    @{ Tab = 'memory'; Path = 'Summary.DeepThinking'; Kind = 'bool'; Label = '总结深度思考'; Default = $false; Group = 'sum' }

    @{ Tab = 'send'; Path = 'SendMethod'; Kind = 'combo'; Label = '发送方式'; Items = @(@{ V = 'Hybrid'; T = '智能混合（推荐）' }, @{ V = 'WMChar'; T = '纯后台注入（不支持 emoji）' }, @{ V = 'Clipboard'; T = '纯剪贴板（最稳）' }); Default = 'Hybrid'; Note = '混合：平时后台注入，含 emoji 时借用剪贴板' }
    @{ Tab = 'send'; Path = 'BeepOnReply'; Kind = 'bool'; Label = '回复时播放提示音'; Default = $true }
    @{ Tab = 'send'; Path = 'NotifyOnProblem'; Kind = 'bool'; Label = '出问题时弹出系统通知'; Default = $true; Note = '微信关闭/最小化、发送失败、AI 出错等' }
    @{ Tab = 'send'; Path = 'BlockOnMinimized'; Kind = 'bool'; Label = '最小化时阻塞等待'; Default = $false; Note = '关闭：还原后自动继续；开启：需点「继续」' }
    @{ Tab = 'send'; Path = 'EnableFocusClick'; Kind = 'bool'; Label = '发送前自动点击输入框'; Default = $false; Note = '点击位置在「校准截图区域」中设置' }
    @{ Tab = 'send'; Path = 'InputBoxClickRatioX'; Kind = 'double'; Label = '点击点横向比例'; Min = 0.05; Max = 0.95; Step = 0.01; Default = 0.65 }
    @{ Tab = 'send'; Path = 'InputBoxOffsetFromBottom'; Kind = 'int'; Label = '点击点距底部（px）'; Min = 0; Max = 1000; Default = 50 }
    @{ Tab = 'send'; Path = 'EnableForegroundWait'; Kind = 'bool'; Label = '你在用微信时先等待'; Default = $true; Note = '微信在前台且你有操作时暂缓回复' }
    @{ Tab = 'send'; Path = 'ForegroundIdleSeconds'; Kind = 'int'; Label = '空闲多少秒算离开'; Min = 1; Max = 600; Default = 3 }
    @{ Tab = 'send'; Path = 'AbortOnScreenChange'; Kind = 'bool'; Label = '思考中画面变化则重来'; Default = $true }
    @{ Tab = 'send'; Path = 'EnableBlinkGuard'; Kind = 'bool'; Label = '过滤光标闪烁'; Default = $true }
    @{ Tab = 'send'; Path = 'PollingIntervalMs'; Kind = 'int'; Label = '截图间隔（毫秒）'; Min = 100; Max = 10000; Default = 530 }
    @{ Tab = 'send'; Path = 'Margins.Left'; Kind = 'int'; Label = '裁切边距 · 左'; Min = 0; Max = 5000; Default = 360; Note = '建议用「校准截图区域」拖拽设置' }
    @{ Tab = 'send'; Path = 'Margins.Right'; Kind = 'int'; Label = '裁切边距 · 右'; Min = 0; Max = 5000; Default = 30 }
    @{ Tab = 'send'; Path = 'Margins.Top'; Kind = 'int'; Label = '裁切边距 · 上'; Min = 0; Max = 5000; Default = 85 }
    @{ Tab = 'send'; Path = 'Margins.Bottom'; Kind = 'int'; Label = '裁切边距 · 下'; Min = 0; Max = 5000; Default = 165 }

    @{ Tab = 'delay'; Path = 'EnableReplyDelay'; Kind = 'bool'; Label = '启用拟人回复延迟'; Default = $false; Note = '随机反应时间 + 按字数估算打字时间' }
    @{ Tab = 'delay'; Path = 'ReplyDelayMinSeconds'; Kind = 'int'; Label = '反应时间下限（秒）'; Min = 0; Max = 600; Default = 3 }
    @{ Tab = 'delay'; Path = 'ReplyDelayMaxSeconds'; Kind = 'int'; Label = '反应时间上限（秒）'; Min = 0; Max = 600; Default = 12 }
    @{ Tab = 'delay'; Path = 'ReplyDelayPerCharMs'; Kind = 'int'; Label = '每字耗时（毫秒）'; Min = 0; Max = 5000; Default = 150; Note = '带 ±30% 抖动' }
    @{ Tab = 'delay'; Path = 'ReplyDelayMaxTotalSeconds'; Kind = 'int'; Label = '总延迟封顶（秒）'; Min = 1; Max = 1800; Default = 40; Note = '含 AI 思考时间' }

    @{ Tab = 'proactive'; Path = 'EnableProactive'; Kind = 'bool'; Label = '启用主动发起'; Default = $false; Note = '隔一段时间由 AI 判断要不要先发消息' }
    @{ Tab = 'proactive'; Path = 'ProactiveCheckMinutes'; Kind = 'int'; Label = '检查间隔（分钟）'; Min = 1; Max = 1440; Default = 15 }
    @{ Tab = 'proactive'; Path = 'ProactiveMinSilenceMinutes'; Kind = 'int'; Label = '至少沉默（分钟）'; Min = 1; Max = 10080; Default = 90 }
    @{ Tab = 'proactive'; Path = 'ProactiveMaxPerDay'; Kind = 'int'; Label = '每天最多（条）'; Min = 1; Max = 100; Default = 3 }
    @{ Tab = 'proactive'; Path = 'ProactiveMaxUnanswered'; Kind = 'int'; Label = '对方未回时最多连发'; Min = 1; Max = 10; Default = 1 }
    @{ Tab = 'proactive'; Path = 'ProactiveStartHour'; Kind = 'int'; Label = '允许时段 · 起（时）'; Min = 0; Max = 23; Default = 9 }
    @{ Tab = 'proactive'; Path = 'ProactiveEndHour'; Kind = 'int'; Label = '允许时段 · 止（时）'; Min = 0; Max = 24; Default = 22; Note = '起=止为全天，起>止为跨午夜' }
    @{ Tab = 'proactive'; Path = 'ProactiveProbability'; Kind = 'double'; Label = '触发概率'; Min = 0; Max = 1; Step = 0.05; Default = 0.4 }
    @{ Tab = 'proactive'; Path = 'ProactiveCooldownAfterNoMinutes'; Kind = 'int'; Label = '无话题时再查（分钟）'; Min = 1; Max = 1440; Default = 60 }

    @{ Tab = 'log'; Path = 'EnableUsageTracking'; Kind = 'bool'; Label = '统计 Token 用量'; Default = $true; Note = '写入 usage\usage_日期.jsonl' }
    @{ Tab = 'log'; Path = 'DailyTokenLimit'; Kind = 'int'; Label = '每日 Token 上限'; Min = 0; Max = 2000000000; Default = 0; Note = '0 表示不限制；达到后暂停自动回复' }
    @{ Tab = 'log'; Path = 'EnableLogging'; Kind = 'bool'; Label = '记录运行日志'; Default = $false; Note = '写入 logs\log_日期.txt' }
    @{ Tab = 'log'; Path = 'LogLevel'; Kind = 'combo'; Label = '日志级别'; Items = @(@{ V = 'DEBUG'; T = 'DEBUG（详细）' }, @{ V = 'INFO'; T = 'INFO（常规）' }, @{ V = 'WARN'; T = 'WARN' }, @{ V = 'ERROR'; T = 'ERROR' }); Default = 'INFO' }
    @{ Tab = 'log'; Path = 'LogRedactContent'; Kind = 'bool'; Label = '日志中隐藏聊天内容'; Default = $true; Note = '只记录字数' }
    @{ Tab = 'log'; Path = 'LogRetentionDays'; Kind = 'int'; Label = '日志保留天数'; Min = 0; Max = 3650; Default = 14; Note = '0 表示不清理' }
)

function New-SettingsTable($parent) {
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'
    $scroll.AutoScroll = $true
    $scroll.Padding = New-Object System.Windows.Forms.Padding((Px 24), (Px 4), (Px 16), (Px 16))
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = 3
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Px 180))))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (Px 330))))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $t.AutoSize = $true
    $t.AutoSizeMode = 'GrowAndShrink'
    $t.Dock = 'Top'
    $scroll.Controls.Add($t)
    $parent.Controls.Add($scroll)
    return $t
}

function Add-SettingRow($table, [string]$label, $control, $note) {
    $row = $table.RowCount
    $table.RowCount = $row + 1
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $label
    $l.AutoSize = $true
    $l.Font = $F.Ui
    $l.ForeColor = $C.Text
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 9, 8, 5)
    $table.Controls.Add($l, 0, $row)
    $control.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 5)
    $table.Controls.Add($control, 1, $row)
    if ($note -is [System.Windows.Forms.Control]) {
        $note.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 5)
        $table.Controls.Add($note, 2, $row)
    }
    elseif ($note) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = $note
        $n.AutoSize = $true
        $n.MaximumSize = New-Object System.Drawing.Size((Px 320), (Px 0))
        $n.Font = $F.Small
        $n.ForeColor = $C.Muted
        $n.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 5)
        $table.Controls.Add($n, 2, $row)
    }
    return $l
}

function Add-SettingHeader($table, [string]$text) {
    $row = $table.RowCount
    $table.RowCount = $row + 1
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.Font = $F.UiBold
    $l.ForeColor = $C.AccentDark
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 4)
    $table.Controls.Add($l, 0, $row)
    $table.SetColumnSpan($l, 3)
}

function New-FieldControl($def) {
    switch ($def.Kind) {
        'bool' {
            $c = New-Object System.Windows.Forms.CheckBox
            $c.Text = '开启'
            $c.AutoSize = $true
            return $c
        }
        { $_ -in 'int', 'double' } {
            $c = New-Object System.Windows.Forms.NumericUpDown
            $c.Width = (Px 140)
            $c.Maximum = [decimal]$def.Max
            $c.Minimum = [decimal]$def.Min
            if ($def.Kind -eq 'double') { $c.DecimalPlaces = 2; $c.Increment = [decimal]$def.Step }
            else { $c.ThousandsSeparator = ([decimal]$def.Max -ge 100000) }
            return $c
        }
        'combo' {
            $c = New-Object System.Windows.Forms.ComboBox
            $c.DropDownStyle = 'DropDownList'
            $c.Width = (Px 240)
            foreach ($it in $def.Items) { if ($it -is [hashtable]) { [void]$c.Items.Add($it.T) } else { [void]$c.Items.Add($it) } }
            return $c
        }
        default {
            $c = New-Object System.Windows.Forms.TextBox
            $c.Width = (Px 320)
            if ($def.Kind -eq 'secret') { $c.UseSystemPasswordChar = $true }
            return $c
        }
    }
}

function Set-FieldValue($def, $ctl, $value) {
    if ($null -eq $value -or "$value" -eq '') { $value = $def.Default }
    switch ($def.Kind) {
        'bool' { $ctl.Checked = [bool]$value }
        { $_ -in 'int', 'double' } {
            $d = [decimal]$def.Default
            try { $d = [decimal]$value } catch {}
            $ctl.Value = [Math]::Max($ctl.Minimum, [Math]::Min($ctl.Maximum, $d))
        }
        'combo' {
            $idx = -1
            for ($i = 0; $i -lt $def.Items.Count; $i++) {
                $v = if ($def.Items[$i] -is [hashtable]) { $def.Items[$i].V } else { $def.Items[$i] }
                if ([string]$v -eq [string]$value) { $idx = $i }
            }
            if ($idx -lt 0) { $idx = 0 }
            $ctl.SelectedIndex = $idx
        }
        default { $ctl.Text = [string]$value }
    }
}

function Get-FieldValue($def, $ctl) {
    switch ($def.Kind) {
        'bool' { return [bool]$ctl.Checked }
        'int' { return [long]$ctl.Value }
        'double' { return [double]$ctl.Value }
        'combo' {
            $it = $def.Items[[Math]::Max(0, $ctl.SelectedIndex)]
            if ($it -is [hashtable]) { return $it.V } else { return $it }
        }
        default { return $ctl.Text.Trim() }
    }
}

function Add-PresetCombo($table, [string]$label, [bool]$visionOnly, [string]$prefix) {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Width = (Px 320)
    [void]$cb.Items.Add('（选择预设以快速填写）')
    $list = @($Presets | Where-Object { -not $visionOnly -or $_.isVision })
    foreach ($p in $list) { [void]$cb.Items.Add($p.name) }
    $cb.SelectedIndex = 0
    $cb.Tag = @{ List = $list; Prefix = $prefix }
    $cb.Add_SelectedIndexChanged({
            $info = $this.Tag
            if ($this.SelectedIndex -le 0) { return }
            $p = $info.List[$this.SelectedIndex - 1]
            $pf = $info.Prefix
            $fields = $script:SettingsFields
            $urlCtl = $fields["$pf.ApiUrl"].Control
            $keyCtl = $fields["$pf.ApiKey"].Control
            $oldUrl = $urlCtl.Text.Trim()
            Set-FieldValue $fields["$pf.ProviderType"].Def $fields["$pf.ProviderType"].Control $p.type
            $urlCtl.Text = $p.url
            $fields["$pf.Model"].Control.Text = $p.model
            if ($p.name -match 'Ollama') { $keyCtl.Text = 'ollama' }
            elseif ($oldUrl -ne $p.url -and $keyCtl.Text) {
                # 换了服务商就清空 Key，避免把 A 家的 Key 发给 B 家。
                $keyCtl.Text = ''
                $keyCtl.Focus()
            }
        })
    [void](Add-SettingRow $table $label $cb '会填写接口类型、地址和模型；换服务商会清空 Key')
}

function Show-SettingsDialog {
    $cfg = Read-ConfigObject
    $isNew = -not $cfg
    if ($isNew) { $cfg = [PSCustomObject]@{} }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WeBot 设置'
    $form.Font = $F.Ui
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object System.Drawing.Size((Px 900), (Px 680))
    $form.MinimumSize = New-Object System.Drawing.Size((Px 760), (Px 520))
    $form.BackColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $false
    $form.MinimizeBox = $false
    $form.Icon = $script:AppIcon

    # 左侧导航 + 右侧内容页
    $pageHost = New-Object System.Windows.Forms.Panel
    $pageHost.Dock = 'Fill'
    $pageHost.BackColor = [System.Drawing.Color]::White
    $navPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $navPanel.Dock = 'Left'
    $navPanel.Width = (Px 184)
    $navPanel.FlowDirection = 'TopDown'
    $navPanel.WrapContents = $false
    $navPanel.BackColor = $C.Bg
    $navPanel.Padding = New-Object System.Windows.Forms.Padding((Px 12), (Px 16), (Px 12), (Px 12))
    $navLine = New-Object System.Windows.Forms.Panel
    $navLine.Dock = 'Left'
    $navLine.Width = 1
    $navLine.BackColor = $C.Border

    $pages = [ordered]@{ chat = 'AI 模型'; persona = 'AI 人设'; memory = '长期记忆'; send = '发送与截图'; delay = '拟人延迟'; proactive = '主动发起'; log = '用量与日志' }
    $pageGlyph = @{ chat = $G.Robot; persona = $G.Persona; memory = $G.Memory; send = $G.Send; delay = $G.Timer; proactive = $G.Spark; log = $G.Chart }
    $pageDesc = @{
        chat      = '聊天使用的 AI 服务商、模型与请求参数'
        persona   = 'AI 的身份设定与说话风格'
        memory    = '把较早的对话总结成长期记忆，节省上下文'
        send      = '回复的发送方式、截图区域与画面检测'
        delay     = '模拟真人的反应与打字时间'
        proactive = '在合适的时候由 AI 先开口'
        log       = 'Token 用量统计与运行日志'
    }
    $tables = @{}
    $script:SettingsPages = [ordered]@{}
    $script:SettingsNav = @{}
    foreach ($k in $pages.Keys) {
        $pg = New-Object System.Windows.Forms.Panel
        $pg.Dock = 'Fill'
        $pg.BackColor = [System.Drawing.Color]::White
        $pg.Visible = $false
        $pageHost.Controls.Add($pg)
        $script:SettingsPages[$k] = $pg
        if ($k -ne 'persona') { $tables[$k] = New-SettingsTable $pg }
        else { $personaPage = $pg }

        $nb = New-Button $pages[$k] 'nav' $pageGlyph[$k]
        $nb.AutoSize = $false
        $nb.LeftAlign = $true
        $nb.Size = New-Object System.Drawing.Size((Px 160), (Px 38))
        $nb.Padding = New-Object System.Windows.Forms.Padding((Px 14), 0, (Px 8), 0)
        $nb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 4))
        $nb.Tag = $k
        $nb.Add_Click({ Select-SettingsPage ([string]$this.Tag) })
        $navPanel.Controls.Add($nb)
        $script:SettingsNav[$k] = $nb
    }

    $script:SettingsFields = @{}
    Add-PresetCombo $tables.chat '服务商预设' $true 'Chat'

    $sumSame = New-Object System.Windows.Forms.CheckBox
    $sumSame.Text = '总结使用与聊天相同的模型配置'
    $sumSame.AutoSize = $true
    $sumHeaderAdded = $false

    foreach ($def in $FieldDefs) {
        $t = $tables[$def.Tab]
        if ($def.Group -eq 'sum' -and -not $sumHeaderAdded) {
            Add-SettingHeader $t '总结模型'
            [void](Add-SettingRow $t '' $sumSame '')
            Add-PresetCombo $t '总结服务商预设' $false 'Summary'
            $sumHeaderAdded = $true
        }
        if ($def.Path -eq 'Margins.Left') { Add-SettingHeader $t '截图区域' }
        if ($def.Path -eq 'EnableFocusClick') { Add-SettingHeader $t '输入框对焦' }
        if ($def.Path -eq 'EnableForegroundWait') { Add-SettingHeader $t '画面检测' }
        if ($def.Path -eq 'EnableLogging') { Add-SettingHeader $t '运行日志' }

        $ctl = New-FieldControl $def
        $note = $def.Note
        if ($def.Kind -eq 'secret') {
            $show = New-Object System.Windows.Forms.CheckBox
            $show.Text = '显示'
            $show.AutoSize = $true
            $show.Tag = $ctl
            $show.Add_CheckedChanged({ $this.Tag.UseSystemPasswordChar = -not $this.Checked })
            $note = $show
        }
        $lbl = Add-SettingRow $t $def.Label $ctl $note
        Set-FieldValue $def $ctl (Get-ConfigValue $cfg $def.Path)
        $script:SettingsFields[$def.Path] = @{ Def = $def; Control = $ctl; Label = $lbl }
    }

    # 人设页：大文本框
    $pp = New-Object System.Windows.Forms.Panel
    $pp.Dock = 'Fill'
    $pp.Padding = New-Object System.Windows.Forms.Padding((Px 24), (Px 4), (Px 24), (Px 20))
    $pTip = New-Object System.Windows.Forms.Label
    $pTip.Text = '系统提示词（System Prompt）决定 AI 的身份和说话风格。例如：你是我本人，说话简短随意，常用语气词……'
    $pTip.Dock = 'Top'
    $pTip.Height = (Px 30)
    $pTip.ForeColor = $C.Muted
    # 用卡片包一层，得到圆角边框和内边距。
    $promptCard = New-Object WeBotCard
    $promptCard.Dock = 'Fill'
    $promptCard.Radius = (Px 6)
    $promptCard.BorderColor = $C.Border
    $promptCard.Padding = New-Object System.Windows.Forms.Padding((Px 10), (Px 8), (Px 4), (Px 8))
    $prompt = New-Object System.Windows.Forms.TextBox
    $prompt.Multiline = $true
    $prompt.ScrollBars = 'Vertical'
    $prompt.AcceptsReturn = $true
    $prompt.BorderStyle = 'None'
    $prompt.Dock = 'Fill'
    $prompt.Font = New-Object System.Drawing.Font($UiFontName, 10.5)
    $promptCard.Controls.Add($prompt)
    $sp = Get-ConfigValue $cfg 'SystemPrompt'
    $prompt.Text = if ($sp) { ([string]$sp) -replace "(?<!\r)\n", "`r`n" } else { '你是一个全能助手。' }
    $pp.Controls.Add($promptCard)
    $pp.Controls.Add($pTip)
    $personaPage.Controls.Add($pp)

    # 每页顶部的标题与说明（后加入的 Top 控件排在最上方）。
    foreach ($k in $script:SettingsPages.Keys) {
        $head = New-Object System.Windows.Forms.Panel
        $head.Dock = 'Top'
        $head.Height = (Px 70)
        $head.BackColor = [System.Drawing.Color]::White
        $ht = New-Object System.Windows.Forms.Label
        $ht.Text = $pages[$k]
        $ht.Font = $F.PageHead
        $ht.ForeColor = $C.Text
        $ht.AutoSize = $true
        $ht.Location = New-Object System.Drawing.Point((Px 22), (Px 16))
        $hd = New-Object System.Windows.Forms.Label
        $hd.Text = $pageDesc[$k]
        $hd.ForeColor = $C.Muted
        $hd.AutoSize = $true
        $hd.Location = New-Object System.Drawing.Point((Px 24), (Px 44))
        $head.Controls.AddRange(@($ht, $hd))
        $script:SettingsPages[$k].Controls.Add($head)
    }
    Select-SettingsPage 'chat'

    # 总结是否与聊天共用：首次或地址+模型一致时视为共用。
    $sumUrl = [string](Get-ConfigValue $cfg 'Summary.ApiUrl')
    $sumSame.Checked = ($isNew -or -not $sumUrl -or ($sumUrl -eq [string](Get-ConfigValue $cfg 'Chat.ApiUrl') -and [string](Get-ConfigValue $cfg 'Summary.Model') -eq [string](Get-ConfigValue $cfg 'Chat.Model')))
    $sumSame.Add_CheckedChanged({ Update-SummaryFieldState })
    $script:SumSameBox = $sumSame
    $script:SettingsFields['Summary.enabled'].Control.Add_CheckedChanged({ Update-SummaryFieldState })
    Update-SummaryFieldState

    # 底部按钮
    $db = New-DialogBar $form
    $bar = $db.Bar
    $btnSave = New-Button '保存' 'primary' $G.Save
    $btnCancel = New-Button '取消'
    $btnCalib = New-Button '校准截图区域…' 'ghost' $G.Crop
    $bar.Controls.AddRange(@($btnSave, $btnCancel, $btnCalib))
    $btnCancel.DialogResult = 'Cancel'
    $form.CancelButton = $btnCancel
    $btnCalib.Add_Click({
            if ((Save-SettingsFromDialog $script:SettingsCfg $script:SettingsPrompt)) {
                $script:SettingsWantCalib = $true
                $script:SettingsForm.DialogResult = 'OK'
                $script:SettingsForm.Close()
            }
        })
    $btnSave.Add_Click({
            if ((Save-SettingsFromDialog $script:SettingsCfg $script:SettingsPrompt)) {
                $script:SettingsForm.DialogResult = 'OK'
                $script:SettingsForm.Close()
            }
        })

    $form.Controls.Add($pageHost)
    $form.Controls.Add($navLine)
    $form.Controls.Add($navPanel)
    $form.Controls.Add($db.Line)
    $form.Controls.Add($bar)
    $script:SettingsForm = $form
    $script:SettingsCfg = $cfg
    $script:SettingsPrompt = $prompt
    $script:SettingsWantCalib = $false

    $result = $form.ShowDialog($script:MainForm)
    $form.Dispose()
    $saved = ($result -eq [System.Windows.Forms.DialogResult]::OK)
    if ($saved) {
        Update-ModelCard
        Add-GuiNote '设置已保存到 config.json' 'Green'
        if ($script:SettingsWantCalib) { Start-Calibration }
        elseif ($isNew) {
            if ((Show-Msg "配置已保存。是否现在校准截图区域？（需要微信窗口可见）" 'Question' 'YesNo') -eq 'Yes') { Start-Calibration }
        }
        elseif (Test-EngineRunning) {
            if ((Show-Msg "设置已保存，重启引擎后生效。现在重启吗？" 'Question' 'YesNo') -eq 'Yes') {
                Stop-EngineAndWait; Invoke-Pump; Start-Engine
            }
        }
    }
    return $saved
}

function Select-SettingsPage([string]$key) {
    foreach ($k in $script:SettingsPages.Keys) {
        $script:SettingsPages[$k].Visible = ($k -eq $key)
        $script:SettingsNav[$k].Selected = ($k -eq $key)
    }
}

function Update-SummaryFieldState {
    $enabled = $script:SettingsFields['Summary.enabled'].Control.Checked
    $script:SumSameBox.Enabled = $enabled
    foreach ($f in $script:SettingsFields.Values) {
        if ($f.Def.Group -eq 'sum') { $f.Control.Enabled = $enabled -and -not $script:SumSameBox.Checked }
    }
    foreach ($p in @('Summary.triggerCount', 'Summary.retainCount')) { $script:SettingsFields[$p].Control.Enabled = $enabled }
}

function Save-SettingsFromDialog($cfg, $promptBox) {
    $fields = $script:SettingsFields
    $val = @{}
    foreach ($k in $fields.Keys) { $val[$k] = Get-FieldValue $fields[$k].Def $fields[$k].Control }

    # Ollama 本地服务不需要 Key，引擎以 "ollama" 作为标记。
    foreach ($pf in @('Chat', 'Summary')) {
        if (-not $val["$pf.ApiKey"] -and $val["$pf.ApiUrl"] -match '(localhost|127\.0\.0\.1):11434') { $val["$pf.ApiKey"] = 'ollama' }
    }
    $problems = @()
    if (-not $val['Chat.ApiUrl']) { $problems += '· 聊天 API 地址不能为空' }
    if (-not $val['Chat.ApiKey']) { $problems += '· 聊天 API Key 不能为空' }
    if (-not $val['Chat.Model']) { $problems += '· 聊天模型名称不能为空' }
    $sumSame = $script:SumSameBox.Checked
    if ($val['Summary.enabled'] -and -not $sumSame) {
        if (-not $val['Summary.ApiUrl']) { $problems += '· 总结 API 地址不能为空' }
        if (-not $val['Summary.ApiKey']) { $problems += '· 总结 API Key 不能为空' }
        if (-not $val['Summary.Model']) { $problems += '· 总结模型名称不能为空' }
    }
    if ($problems.Count -gt 0) {
        # 跳到出问题的页面。
        if (-not $val['Chat.ApiUrl'] -or -not $val['Chat.ApiKey'] -or -not $val['Chat.Model']) { Select-SettingsPage 'chat' } else { Select-SettingsPage 'memory' }
        [void](Show-Msg ("请先补全以下内容：`n" + ($problems -join "`n")) 'Warning')
        return $false
    }

    $fixes = @()
    if ($val['Summary.retainCount'] -ge $val['Summary.triggerCount']) {
        $val['Summary.retainCount'] = $val['Summary.triggerCount'] - 1
        $fixes += "· 保留条数必须小于触发条数，已调整为 $($val['Summary.retainCount'])"
    }
    if ($val['ReplyDelayMinSeconds'] -gt $val['ReplyDelayMaxSeconds']) {
        $tmp = $val['ReplyDelayMinSeconds']; $val['ReplyDelayMinSeconds'] = $val['ReplyDelayMaxSeconds']; $val['ReplyDelayMaxSeconds'] = $tmp
        $fixes += '· 反应时间下限大于上限，已交换'
    }

    if ($sumSame) {
        foreach ($k in @('ProviderType', 'ApiUrl', 'ApiKey', 'Model', 'MaxTokens', 'TimeoutSeconds')) { $val["Summary.$k"] = $val["Chat.$k"] }
    }
    foreach ($k in $val.Keys) { Set-ConfigValue $cfg $k $val[$k] }
    $promptText = $promptBox.Text.Trim()
    if (-not $promptText) { $promptText = '你是一个全能助手。' }
    Set-ConfigValue $cfg 'SystemPrompt' ($promptText -replace "`r`n", "`n")

    try { Write-ConfigObject $cfg }
    catch {
        [void](Show-Msg "保存失败：$($_.Exception.Message)" 'Error')
        return $false
    }
    if ($fixes.Count -gt 0) { [void](Show-Msg ("已保存，并自动修正：`n" + ($fixes -join "`n"))) }
    return $true
}
#endregion

#region 记忆与历史
function Show-MemoryDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '记忆与历史'
    $form.Font = $F.Ui
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object System.Drawing.Size((Px 900), (Px 620))
    $form.ShowInTaskbar = $false
    $form.Icon = $script:AppIcon

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Padding = New-Object System.Drawing.Point((Px 14), (Px 6))

    # 近期对话
    $pgHist = New-Object System.Windows.Forms.TabPage
    $pgHist.Text = '近期对话'
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $false
    $lv.BorderStyle = 'None'
    $lv.Dock = 'Fill'
    [void]$lv.Columns.Add('时间', (Px 150))
    [void]$lv.Columns.Add('对方', (Px 300))
    [void]$lv.Columns.Add('AI 回复', (Px 380))
    $lv.Add_DoubleClick({
            if ($this.SelectedItems.Count -gt 0) {
                $it = $this.SelectedItems[0]
                [void](Show-Msg ("时间：{0}`n`n对方：{1}`n`nAI：{2}" -f $it.Text, $it.SubItems[1].Text, $it.SubItems[2].Text))
            }
        })
    $histTip = New-Object System.Windows.Forms.Label
    $histTip.Dock = 'Bottom'
    $histTip.Height = (Px 26)
    $histTip.ForeColor = $C.Muted
    $histTip.TextAlign = 'MiddleLeft'
    $pgHist.Controls.Add($lv)
    $pgHist.Controls.Add($histTip)
    $script:HistList = $lv
    $script:HistTip = $histTip

    # 长期记忆
    $pgSum = New-Object System.Windows.Forms.TabPage
    $pgSum.Text = '长期记忆'
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Dock = 'Fill'
    $tb.Font = New-Object System.Drawing.Font($UiFontName, 10.5)
    $sumTip = New-Object System.Windows.Forms.Label
    $sumTip.Dock = 'Bottom'
    $sumTip.Height = (Px 26)
    $sumTip.ForeColor = $C.Muted
    $sumTip.TextAlign = 'MiddleLeft'
    $pgSum.Controls.Add($tb)
    $pgSum.Controls.Add($sumTip)
    $script:SumBox = $tb
    $script:SumTip = $sumTip

    [void]$tabs.TabPages.Add($pgHist)
    [void]$tabs.TabPages.Add($pgSum)

    $db = New-DialogBar $form
    $bar = $db.Bar
    $btnClose = New-Button '关闭'
    $btnClose.DialogResult = 'Cancel'
    $btnSaveSum = New-Button '保存长期记忆' 'primary' $G.Save
    $btnRefresh = New-Button '刷新' 'ghost' $G.Refresh
    $bar.Controls.AddRange(@($btnClose, $btnSaveSum, $btnRefresh))
    $form.CancelButton = $btnClose
    $script:BtnSaveSum = $btnSaveSum

    $btnRefresh.Add_Click({ Import-MemoryData })
    $btnSaveSum.Add_Click({
            if (Test-EngineRunning) { [void](Show-Msg '引擎运行时可能会同时改写长期记忆，请先停止引擎再保存。' 'Warning'); return }
            try {
                [System.IO.File]::WriteAllText($SUMMARY_FILE, ($script:SumBox.Text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($true)))
                $script:SumTip.Text = "已保存 · $SUMMARY_FILE"
            }
            catch { [void](Show-Msg "保存失败：$($_.Exception.Message)" 'Error') }
        })

    $form.Controls.Add($tabs)
    $form.Controls.Add($db.Line)
    $form.Controls.Add($bar)
    Import-MemoryData
    [void]$form.ShowDialog($script:MainForm)
    $form.Dispose()
}

function Import-MemoryData {
    $lv = $script:HistList
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $count = 0
    try {
        if (Test-Path -LiteralPath $HISTORY_FILE) {
            $raw = Get-Content -LiteralPath $HISTORY_FILE -Raw -Encoding UTF8
            $items = @()
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $items = @($raw | ConvertFrom-Json) }
            [array]::Reverse($items)
            foreach ($h in $items) {
                $user = [string]$h.user
                $ai = [string]$h.ai
                if ($user -eq '__PROACTIVE__') { $user = '（主动发起）' }
                if ($ai -eq '__NO_REPLY__') { $ai = '（判断无需回复）' }
                $it = New-Object System.Windows.Forms.ListViewItem([string]$h.time)
                [void]$it.SubItems.Add(($user -replace '\s+', ' '))
                [void]$it.SubItems.Add(($ai -replace '\s+', ' '))
                [void]$lv.Items.Add($it)
                $count++
            }
        }
        $script:HistTip.Text = "共 $count 条（最新在上，双击查看全文）· $HISTORY_FILE"
    }
    catch { $script:HistTip.Text = "读取失败：$($_.Exception.Message)" }
    $lv.EndUpdate()

    try {
        if (Test-Path -LiteralPath $SUMMARY_FILE) {
            $script:SumBox.Text = (Get-Content -LiteralPath $SUMMARY_FILE -Raw -Encoding UTF8) -replace "(?<!\r)\n", "`r`n"
            $script:SumTip.Text = $SUMMARY_FILE
        }
        else {
            $script:SumBox.Text = ''
            $script:SumTip.Text = '还没有长期记忆（开启「长期记忆」并积累足够对话后自动生成）'
        }
    }
    catch { $script:SumTip.Text = "读取失败：$($_.Exception.Message)" }
    $running = Test-EngineRunning
    $script:SumBox.ReadOnly = $running
    $script:BtnSaveSum.Enabled = -not $running
    if ($running) { $script:SumTip.Text += '  ·  引擎运行中，只读' }
}
#endregion

#region 主窗口
$script:AppIcon = New-AppIcon

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WeBot 微信 AI 助手'
$form.Font = $F.Ui
$form.Size = New-Object System.Drawing.Size((Px 1060), (Px 720))
$form.MinimumSize = New-Object System.Drawing.Size((Px 820), (Px 560))
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.Icon = $script:AppIcon
$script:MainForm = $form

# 头部：Logo + 标题 + 状态胶囊，底部一条分隔线。
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = (Px 76)
$header.BackColor = [System.Drawing.Color]::White
$logo = New-Object WeBotLogo
$logo.Size = New-Object System.Drawing.Size((Px 42), (Px 42))
$logo.Location = New-Object System.Drawing.Point((Px 22), (Px 17))
$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text = 'WeBot 微信 AI 助手'
$hTitle.Font = $F.Title
$hTitle.ForeColor = $C.Text
$hTitle.AutoSize = $true
$hTitle.Location = New-Object System.Drawing.Point((Px 74), (Px 13))
$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = '截图识别聊天 · AI 自动回复'
$hSub.ForeColor = $C.Muted
$hSub.AutoSize = $true
$hSub.Location = New-Object System.Drawing.Point((Px 76), (Px 44))
$pill = New-Object WeBotPill
$pill.Font = $F.UiBold
$pill.Text = '未运行'
$hLine = New-Object System.Windows.Forms.Panel
$hLine.Dock = 'Bottom'
$hLine.Height = 1
$hLine.BackColor = $C.Border
$header.Controls.AddRange(@($logo, $hTitle, $hSub, $pill, $hLine))
function Set-PillPosition {
    $h = $script:StatusPill.Parent
    if (-not $h) { return }
    $script:StatusPill.Location = New-Object System.Drawing.Point(($h.ClientSize.Width - $script:StatusPill.Width - (Px 22)), [int](($h.ClientSize.Height - $script:StatusPill.Height) / 2))
}
$header.Add_Resize({ Set-PillPosition })
$pill.Add_SizeChanged({ Set-PillPosition })
$script:StatusPill = $pill

# 卡片行
function New-Card([string]$title, [string]$glyph = '') {
    $p = New-Object WeBotCard
    $p.Dock = 'Fill'
    $p.Fill = $C.Card
    $p.BorderColor = New-Color '#E1E6EB'
    $p.Radius = (Px 10)
    $p.Margin = New-Object System.Windows.Forms.Padding((Px 6))
    $p.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 12), (Px 14), (Px 10))
    $tRow = New-Object System.Windows.Forms.Panel
    $tRow.Dock = 'Top'
    $tRow.Height = (Px 20)
    $tRow.BackColor = $C.Card
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $title
    $t.ForeColor = $C.Muted
    $t.Font = $F.Small
    $t.Dock = 'Fill'
    $t.TextAlign = 'MiddleLeft'
    $t.BackColor = $C.Card
    $tRow.Controls.Add($t)
    $iconFont = [WeBotUi]::IconFont(9)
    if ($glyph -and $iconFont) {
        $ic = New-Object System.Windows.Forms.Label
        $ic.Text = $glyph
        $ic.Font = $iconFont
        $ic.ForeColor = $C.Accent
        $ic.Dock = 'Left'
        $ic.Width = (Px 20)
        $ic.TextAlign = 'MiddleLeft'
        $ic.BackColor = $C.Card
        $tRow.Controls.Add($ic)
    }
    $v = New-Object System.Windows.Forms.Label
    $v.Font = $F.CardVal
    $v.ForeColor = $C.Text
    $v.Dock = 'Top'
    $v.Height = (Px 34)
    $v.TextAlign = 'MiddleLeft'
    $v.AutoEllipsis = $true
    $v.BackColor = $C.Card
    $v.Text = '—'
    $d = New-Object System.Windows.Forms.Label
    $d.ForeColor = $C.Muted
    $d.Font = $F.Small
    $d.Dock = 'Top'
    $d.Height = (Px 20)
    $d.AutoEllipsis = $true
    $d.BackColor = $C.Card
    $p.Controls.Add($d); $p.Controls.Add($v); $p.Controls.Add($tRow)
    return @{ Panel = $p; Value = $v; Detail = $d }
}
$cards = New-Object System.Windows.Forms.TableLayoutPanel
$cards.Dock = 'Top'
$cards.Height = (Px 118)
$cards.ColumnCount = 4
$cards.RowCount = 1
$cards.Padding = New-Object System.Windows.Forms.Padding((Px 10), (Px 10), (Px 10), 0)
foreach ($w in @(24, 30, 27, 19)) { [void]$cards.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $w))) }
$script:CardState = New-Card '运行状态' $G.Bolt
$script:CardModel = New-Card '聊天模型' $G.Chat
$script:CardUsage = New-Card '今日用量' $G.Chart
$script:CardUptime = New-Card '运行时长' $G.Clock
$script:CardUsage.Value.Text = '—'
$script:CardUsage.Detail.Text = '启动后显示'
$script:CardUptime.Value.Text = '00:00:00'
$script:CardUptime.Detail.Text = '尚未启动'
$bar = New-Object WeBotBar
$bar.Dock = 'Bottom'
$bar.Height = (Px 5)
$bar.Visible = $false
$script:CardUsage.Panel.Controls.Add($bar)
$script:UsageBar = $bar
$cards.Controls.Add($script:CardState.Panel, 0, 0)
$cards.Controls.Add($script:CardModel.Panel, 1, 0)
$cards.Controls.Add($script:CardUsage.Panel, 2, 0)
$cards.Controls.Add($script:CardUptime.Panel, 3, 0)

# 工具栏：左侧为运行控制与配置，右侧为辅助操作。
$tool = New-Object System.Windows.Forms.Panel
$tool.Dock = 'Top'
$tool.Height = (Px 58)
$tool.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 12), (Px 16), (Px 8))
$toolLeft = New-Object System.Windows.Forms.FlowLayoutPanel
$toolLeft.Dock = 'Fill'
$toolLeft.WrapContents = $false
$toolRight = New-Object System.Windows.Forms.FlowLayoutPanel
$toolRight.Dock = 'Right'
$toolRight.WrapContents = $false
$toolRight.AutoSize = $true
$toolRight.AutoSizeMode = 'GrowAndShrink'
$script:BtnStart = New-Button '启动' 'primary' $G.Play
$script:BtnStop = New-Button '停止' 'danger' $G.Stop
$sep = New-Object System.Windows.Forms.Panel
$sep.Width = 1
$sep.Height = (Px 22)
$sep.BackColor = $C.Border
$sep.Margin = New-Object System.Windows.Forms.Padding((Px 4), (Px 6), (Px 12), 0)
$btnSettings = New-Button '设置' 'secondary' $G.Settings
$script:BtnCalib = New-Button '校准截图区域' 'secondary' $G.Crop
$btnMemory = New-Button '记忆与历史' 'secondary' $G.History
$btnFolder = New-Button '打开文件夹' 'ghost' $G.Folder
$btnFolder.Margin = New-Object System.Windows.Forms.Padding(0)
$toolLeft.Controls.AddRange(@($script:BtnStart, $script:BtnStop, $sep, $btnSettings, $script:BtnCalib, $btnMemory))
$toolRight.Controls.Add($btnFolder)
$tool.Controls.Add($toolLeft)
$tool.Controls.Add($toolRight)

# 日志标题栏里的操作
$btnClear = New-Button '清空' 'ghost-dark' $G.Delete
$btnClear.MinimumSize = New-Object System.Drawing.Size((Px 64), (Px 28))
$btnClear.Height = (Px 28)
$btnClear.Padding = New-Object System.Windows.Forms.Padding((Px 10), 0, (Px 10), 0)
$btnClear.Margin = New-Object System.Windows.Forms.Padding(0, (Px 4), 0, 0)
$chkScroll = New-Object System.Windows.Forms.CheckBox
$chkScroll.Text = '自动滚动'
$chkScroll.Checked = $true
$chkScroll.AutoSize = $true
$chkScroll.ForeColor = $C.LogTitle
$chkScroll.BackColor = $C.LogBg
$chkScroll.Margin = New-Object System.Windows.Forms.Padding(0, (Px 9), (Px 10), 0)
$script:ChkAutoScroll = $chkScroll

$folderMenu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($entry in @(@('程序目录', ''), @('运行日志 logs', 'logs'), @('用量统计 usage', 'usage'))) {
    $mi = $folderMenu.Items.Add($entry[0])
    $mi.Tag = $entry[1]
    $mi.Add_Click({
            $dir = if ($this.Tag) { Join-Path $AppDir $this.Tag } else { $AppDir }
            if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe -ArgumentList "`"$dir`"" }
            else { [void](Show-Msg "文件夹还不存在：$dir`n（开启对应功能并运行后才会生成）") }
        })
}
$btnFolder.Add_Click({ $folderMenu.Show($this, (New-Object System.Drawing.Point(0, $this.Height))) })

# 横幅：圆角提示条，左侧图标，右侧操作按钮。
$banner = New-Object System.Windows.Forms.Panel
$banner.Dock = 'Top'
$banner.Height = (Px 58)
$banner.Visible = $false
$banner.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 2), (Px 16), (Px 8))
$bannerCard = New-Object WeBotCard
$bannerCard.Dock = 'Fill'
$bannerCard.Radius = (Px 8)
$bannerCard.Padding = New-Object System.Windows.Forms.Padding((Px 12), (Px 7), (Px 7), (Px 7))
$bannerIcon = New-Object System.Windows.Forms.Label
$bannerIcon.Dock = 'Left'
$bannerIcon.Width = (Px 28)
$bannerIcon.TextAlign = 'MiddleLeft'
$bIconFont = [WeBotUi]::IconFont(11)
if ($bIconFont) { $bannerIcon.Font = $bIconFont } else { $bannerIcon.Width = 0 }
$bannerLabel = New-Object System.Windows.Forms.Label
$bannerLabel.Dock = 'Fill'
$bannerLabel.TextAlign = 'MiddleLeft'
$bannerLabel.Font = $F.UiBold
$bannerLabel.AutoEllipsis = $true
$bannerBtn = New-Button '继续' 'primary'
$bannerBtn.Dock = 'Right'
$bannerBtn.Add_Click({ if ($script:BannerAction) { & $script:BannerAction } })
$bannerCard.Controls.Add($bannerLabel)
$bannerCard.Controls.Add($bannerIcon)
$bannerCard.Controls.Add($bannerBtn)
$banner.Controls.Add($bannerCard)
$script:Banner = $banner
$script:BannerCard = $bannerCard
$script:BannerIcon = $bannerIcon
$script:BannerLabel = $bannerLabel
$script:BannerButton = $bannerBtn
$script:BannerKind = ''

# 日志区：深色圆角卡片，顶部标题栏放「自动滚动」和「清空」。
$logWrap = New-Object System.Windows.Forms.Panel
$logWrap.Dock = 'Fill'
$logWrap.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 2), (Px 16), (Px 14))
$logCard = New-Object WeBotCard
$logCard.Dock = 'Fill'
$logCard.Fill = $C.LogBg
$logCard.BorderColor = $C.LogBorder
$logCard.Radius = (Px 10)
$logCard.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 6), (Px 8), (Px 12))
$logHead = New-Object System.Windows.Forms.Panel
$logHead.Dock = 'Top'
$logHead.Height = (Px 40)
$logHead.BackColor = $C.LogBg
$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = '运行日志'
$logTitle.Font = $F.UiBold
$logTitle.ForeColor = $C.LogTitle
$logTitle.BackColor = $C.LogBg
$logTitle.Dock = 'Fill'
$logTitle.TextAlign = 'MiddleLeft'
$logTools = New-Object System.Windows.Forms.FlowLayoutPanel
$logTools.Dock = 'Right'
$logTools.AutoSize = $true
$logTools.AutoSizeMode = 'GrowAndShrink'
$logTools.WrapContents = $false
$logTools.BackColor = $C.LogBg
$logTools.Controls.AddRange(@($chkScroll, $btnClear))
$logLine = New-Object System.Windows.Forms.Panel
$logLine.Dock = 'Bottom'
$logLine.Height = 1
$logLine.BackColor = $C.LogLine
$logHead.Controls.Add($logTitle)
$logHead.Controls.Add($logTools)
$logHead.Controls.Add($logLine)
$logGap = New-Object System.Windows.Forms.Panel
$logGap.Dock = 'Top'
$logGap.Height = (Px 8)
$logGap.BackColor = $C.LogBg
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = 'Fill'
$rtb.ReadOnly = $true
$rtb.BackColor = $C.LogBg
$rtb.ForeColor = $LogColors.Default
$rtb.Font = $F.Log
$rtb.BorderStyle = 'None'
$rtb.DetectUrls = $false
$rtb.HideSelection = $false
$rtb.WordWrap = $true
$logCard.Controls.Add($rtb)
$logCard.Controls.Add($logGap)
$logCard.Controls.Add($logHead)
$logWrap.Controls.Add($logCard)
$script:LogBox = $rtb

$status = New-Object System.Windows.Forms.StatusStrip
$status.SizingGrip = $true
$status.BackColor = $C.Bg
$stLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$stLabel.Text = "引擎：$EnginePath"
$stLabel.ForeColor = $C.Muted
$stLabel.Spring = $true
$stLabel.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($stLabel)

# Dock 顺序：后加入的 Top 控件排在上方。
$form.Controls.Add($logWrap)
$form.Controls.Add($banner)
$form.Controls.Add($tool)
$form.Controls.Add($cards)
$form.Controls.Add($header)
$form.Controls.Add($status)

# 托盘
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:AppIcon
$tray.Text = 'WeBot'
$tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('显示主窗口')
$script:TrayStart = $trayMenu.Items.Add('启动')
$script:TrayStop = $trayMenu.Items.Add('停止')
[void]$trayMenu.Items.Add('-')
$miExit = $trayMenu.Items.Add('退出')
$tray.ContextMenuStrip = $trayMenu
$script:Tray = $tray

function Show-MainWindow {
    $script:MainForm.Show()
    if ($script:MainForm.WindowState -eq 'Minimized') { $script:MainForm.WindowState = 'Normal' }
    $script:MainForm.Activate()
}
$miShow.Add_Click({ Show-MainWindow })
$tray.Add_DoubleClick({ Show-MainWindow })
$script:TrayStart.Add_Click({ Start-Engine })
$script:TrayStop.Add_Click({ Stop-Engine })
$miExit.Add_Click({ $S.ExitRequested = $true; $script:MainForm.Close() })

# 事件
$script:BtnStart.Add_Click({ Start-Engine })
$script:BtnStop.Add_Click({ Stop-Engine })
$btnSettings.Add_Click({ [void](Show-SettingsDialog) })
$script:BtnCalib.Add_Click({ Start-Calibration })
$btnMemory.Add_Click({ Show-MemoryDialog })
$btnClear.Add_Click({ $script:LogBox.Clear(); $S.LogLines = 0 })

# 最小化时收进托盘。
$form.Add_Resize({
        if ($this.WindowState -eq 'Minimized' -and (Test-EngineRunning)) {
            $this.Hide()
            if (-not $S.TrayTipShown) {
                $script:Tray.ShowBalloonTip(4000, 'WeBot 仍在后台运行', '双击托盘图标可重新打开窗口。', [System.Windows.Forms.ToolTipIcon]::Info)
                $S.TrayTipShown = $true
            }
        }
    })

$form.Add_FormClosing({
        if ((Test-EngineRunning) -and -not $S.ExitRequested) {
            $ans = [System.Windows.Forms.MessageBox]::Show($this,
                "自动回复正在运行。`n`n是：收到托盘继续运行`n否：停止自动回复并退出`n取消：返回",
                'WeBot', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -eq 'Yes') { $_.Cancel = $true; $this.Hide(); return }
            if ($ans -eq 'Cancel') { $_.Cancel = $true; return }
        }
        Stop-EngineAndWait
        if ($S.Calib) { $S.Calib.Kill() }
        $script:Timer.Stop()
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
    })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
        try { Invoke-Pump }
        catch { try { Add-LogText "[界面] 处理引擎输出出错：$($_.Exception.Message)" 'Red' $true } catch {} }
    })
$script:Timer = $timer

$form.Add_Shown({
        $this.ActiveControl = $script:BtnStart
        Update-ModelCard
        Update-StatusView
        Add-GuiNote "WeBot 图形界面已就绪 · 配置目录 $AppDir" 'Cyan'
        if (-not (Test-Path -LiteralPath $CONFIG_FILE)) {
            Show-Banner '首次使用：请先完成设置（AI 服务商、API Key、模型），再校准截图区域。' 'info' '打开设置' { [void](Show-SettingsDialog); if (Read-ConfigObject) { Hide-Banner } }
        }
        else {
            $cfg = Read-ConfigObject
            if ($cfg -and -not $cfg.EnableFocusClick) {
                Add-GuiNote '提示：未开启「发送前自动点击输入框」，启动后请手动点一次微信聊天输入框，之后不要点微信里的其他位置。' 'Yellow'
            }
        }
        $script:Timer.Start()
    })

[System.Windows.Forms.Application]::Run($form)
#endregion
