param(
    [switch]$Gui,        # 由图形界面（WeBot-GUI.ps1）启动：输出改为结构化协议，不使用控制台交互
    [switch]$Calibrate,  # 仅打开截图区域校准窗口，保存到 config.json 后退出
    [int]$ParentPid = 0  # 图形界面进程 PID；界面退出后引擎随之退出
)
# 图形界面模式：每行输出一条 "@@类型<TAB>字段..." 消息，由界面进程解析；字段内的 \ TAB CR LF 被转义。
$script:GuiMode = [bool]$Gui -or [bool]$Calibrate
$script:GuiStopEvent = $null
$script:GuiContinueEvent = $null
if ($script:GuiMode) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
    try {
        # 界面通过命名事件请求停止 / 在阻塞提示后继续，事件名带本进程 PID。
        $script:GuiStopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "WeBot_Stop_$PID")
        $script:GuiContinueEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "WeBot_Continue_$PID")
    }
    catch {}

    function Send-GuiMessage {
        param([string]$Kind, [object[]]$Fields = @())
        $parts = @(foreach ($f in $Fields) {
                ([string]$f).Replace('\', '\\').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
            })
        $line = "@@$Kind"
        if ($parts.Count -gt 0) { $line += "`t" + ($parts -join "`t") }
        try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch {}
    }

    # 覆盖 Write-Host：保留颜色与 -NoNewline 语义，转成 @@W 消息。
    function Write-Host {
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [object]$Object,
            [switch]$NoNewline,
            [object]$Separator = ' ',
            [System.ConsoleColor]$ForegroundColor,
            [System.ConsoleColor]$BackgroundColor
        )
        $text = if ($null -eq $Object) { '' } else { (@($Object) | ForEach-Object { [string]$_ }) -join [string]$Separator }
        # 去掉控制台专用的回车重绘与 ANSI 颜色序列。
        $text = $text.Replace("`r", '') -replace "\x1b\[[0-9;]*m", ''
        $color = if ($PSBoundParameters.ContainsKey('ForegroundColor')) { [string]$ForegroundColor } else { 'Default' }
        Send-GuiMessage 'W' @($color, $(if ($NoNewline) { '0' } else { '1' }), $text)
    }
    function Clear-Host {}

    $script:GuiLastStatus = ''
    $script:GuiLastStatusAt = [DateTime]::MinValue
    function Send-GuiStatus {
        Test-GuiStopRequested
        $now = [DateTime]::Now
        $waitLabel = ''; $waitSec = ''; $remainSec = ''
        if ($script:ApiWaitStart) {
            $waitLabel = [string]$script:ApiWaitLabel
            $waitSec = [int]($now - $script:ApiWaitStart).TotalSeconds
        }
        elseif ($script:ReplyDelayUntil) {
            $remainSec = [Math]::Max(0, [int][Math]::Ceiling(($script:ReplyDelayUntil - $now).TotalSeconds))
        }
        $uIn = ''; $uOut = ''; $uTotal = ''; $uReq = ''; $limit = ''
        try {
            if ($script:UsageToday -and (Test-UsageTrackingEnabled)) {
                $uIn = $script:UsageToday.Input; $uOut = $script:UsageToday.Output
                $uTotal = $script:UsageToday.Total; $uReq = $script:UsageToday.Requests
                $limit = Get-DailyTokenLimit
            }
        }
        catch {}
        $fields = @([string]$script:CurrentMode, $waitLabel, $waitSec, $remainSec, $uIn, $uOut, $uTotal, $uReq, $limit)
        $key = $fields -join '|'
        # 内容变化时最多每 200ms 发一次，不变时每 2 秒发一次心跳。
        $age = ($now - $script:GuiLastStatusAt).TotalMilliseconds
        if (($key -ne $script:GuiLastStatus -and $age -ge 200) -or $age -ge 2000) {
            $script:GuiLastStatus = $key
            $script:GuiLastStatusAt = $now
            Send-GuiMessage 'STATUS' $fields
        }
    }

    # 界面被强制结束时不会发停止信号，定期检查界面进程，避免引擎变成无人管理的后台进程。
    $script:GuiParent = $null
    $script:GuiParentCheckAt = [DateTime]::MinValue
    if ($ParentPid -gt 0) {
        try { $script:GuiParent = [System.Diagnostics.Process]::GetProcessById($ParentPid) }
        catch { exit 0 }
    }

    function Test-GuiParentGone {
        if (-not $script:GuiParent) { return $false }
        if (([DateTime]::Now - $script:GuiParentCheckAt).TotalSeconds -lt 2) { return $false }
        $script:GuiParentCheckAt = [DateTime]::Now
        try { return $script:GuiParent.HasExited } catch { return $false }
    }

    function Test-GuiStopRequested {
        $stop = Test-GuiParentGone
        if (-not $stop -and $script:GuiStopEvent) {
            try { $stop = $script:GuiStopEvent.WaitOne(0) } catch {}
        }
        if (-not $stop) { return }
        # 正在往微信输入框写入时不中断，写完回到其他状态后再退出。
        if ($script:CurrentMode -eq 'Replying') { return }
        Write-AppLog "收到图形界面的停止请求，退出监听" "INFO"
        Send-GuiMessage 'STOPPED'
        exit 0
    }
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# 使用 HttpClient 异步请求，等待期间刷新状态行。
Add-Type -AssemblyName System.Net.Http
$ProgressPreference = 'SilentlyContinue'
$csharp_code = @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class WinUtil {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, int nFlags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    // 窗口消息注入。
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    // 查询窗口线程的焦点信息。
    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr ProcessId);
    public const uint WM_IME_CHAR    = 0x0286;  // IME 字符消息
    public const uint WM_CHAR        = 0x0102;  // UTF-16 字符消息
    public const uint WM_KEYDOWN     = 0x0100;
    public const uint WM_KEYUP       = 0x0101;
    public const uint WM_MOUSEMOVE   = 0x0200;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_LBUTTONUP   = 0x0202;
    public const int  MK_LBUTTON     = 0x0001;
    public const uint VK_RETURN      = 0x0D;
    public const int  SW_SHOWNOACTIVATE = 4;
    public const int  SW_RESTORE = 9;
    public struct RECT  { public int Left; public int Top; public int Right; public int Bottom; }
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int  cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT   rcCaret;
    }
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public static readonly IntPtr HWND_TOP    = new IntPtr(0);
    public const uint SWP_NOSIZE     = 0x0001;
    public const uint SWP_NOMOVE     = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
}
"@
try { 
    if (-not ([System.Management.Automation.PSTypeName]'WinUtil').Type) { Add-Type -TypeDefinition $csharp_code -ErrorAction Stop } 
}
catch {
    Write-Host "❌ 关键组件 (WinUtil) 加载失败！" -ForegroundColor Red
    Write-Host "错误原因: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "提示: 请确保您的系统支持 .NET 编译，或尝试以管理员权限运行。" -ForegroundColor Gray
    exit 
}
[void][WinUtil]::SetProcessDPIAware()
# 启用系统视觉样式（圆角按钮、现代数值框/复选框），并使用 GDI 文本渲染，中文更清晰。
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

# 剪贴板（Hybrid 含 emoji 时 / Clipboard 模式）和 WinForms 需要 STA 线程；
# Windows PowerShell 5.1 默认是 STA，PowerShell 7 视启动方式可能是 MTA，此时剪贴板发送会每次失败。
$script:IsSTA = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
if (-not $script:IsSTA) {
    Write-Host "⚠️ 当前 PowerShell 不是 STA 线程模式：剪贴板发送（含 emoji 的回复）和校准窗口可能无法工作。" -ForegroundColor DarkYellow
    Write-Host "   建议用 Windows PowerShell 5.1 运行，或使用：pwsh -STA -File `"$PSCommandPath`"" -ForegroundColor DarkYellow
}

# 光标闪烁检测：多帧 BGRA 差分返回连通区域 [X, Y, W, H, 像素数, 最大变化次数]。
$blink_code = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BlinkUtil {
    [DllImport("user32.dll")] public static extern uint GetCaretBlinkTime();

    public static List<int[]> FindChangedRegions(List<byte[]> frames, int width, int height, int stride, int threshold) {
        List<int[]> result = new List<int[]>();
        if (frames == null || frames.Count < 2 || width <= 0 || height <= 0) return result;

        int total = width * height;
        int[] toggles = new int[total];
        for (int f = 1; f < frames.Count; f++) {
            byte[] a = frames[f - 1];
            byte[] b = frames[f];
            for (int y = 0; y < height; y++) {
                int row = y * stride;
                int baseIdx = y * width;
                for (int x = 0; x < width; x++) {
                    int i = row + x * 4;
                    int d = Math.Abs(a[i] - b[i]) + Math.Abs(a[i + 1] - b[i + 1]) + Math.Abs(a[i + 2] - b[i + 2]);
                    if (d > threshold) toggles[baseIdx + x]++;
                }
            }
        }

        bool[] seen = new bool[total];
        Stack<int> stack = new Stack<int>();
        for (int p = 0; p < total; p++) {
            if (toggles[p] == 0 || seen[p]) continue;
            int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1, count = 0, maxT = 0;
            seen[p] = true;
            stack.Push(p);
            while (stack.Count > 0) {
                int q = stack.Pop();
                int qx = q % width, qy = q / width;
                count++;
                if (toggles[q] > maxT) maxT = toggles[q];
                if (qx < minX) minX = qx;
                if (qx > maxX) maxX = qx;
                if (qy < minY) minY = qy;
                if (qy > maxY) maxY = qy;
                for (int dy = -1; dy <= 1; dy++) {
                    int ny = qy + dy;
                    if (ny < 0 || ny >= height) continue;
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = qx + dx;
                        if (nx < 0 || nx >= width) continue;
                        int nq = ny * width + nx;
                        if (toggles[nq] > 0 && !seen[nq]) { seen[nq] = true; stack.Push(nq); }
                    }
                }
            }
            result.Add(new int[] { minX, minY, maxX - minX + 1, maxY - minY + 1, count, maxT });
            if (result.Count >= 5000) break;   // 限制大面积变化时的连通区域数量。
        }
        return result;
    }
}
"@
try {
    if (-not ([System.Management.Automation.PSTypeName]'BlinkUtil').Type) { Add-Type -TypeDefinition $blink_code -ErrorAction Stop }
}
catch {
    # 闪烁检测只是辅助功能，加载失败不影响主流程
    Write-Host "⚠️ 光标闪烁检测组件加载失败，相关检测将被跳过：$($_.Exception.Message)" -ForegroundColor DarkYellow
}

# 用户活动检测：读取系统空闲时间及窗口所属进程。
$idle_code = @"
using System;
using System.Runtime.InteropServices;
public static class IdleUtil {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    public static long GetIdleMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return -1;
        // 两者都是 32 位 tick，按无符号相减可正确处理约 49.7 天一次的回绕
        return (long)unchecked((uint)Environment.TickCount - lii.dwTime);
    }

    public static uint GetForegroundPid() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static uint GetWindowPid(IntPtr hWnd) {
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        return pid;
    }
}
"@
try {
    if (-not ([System.Management.Automation.PSTypeName]'IdleUtil').Type) { Add-Type -TypeDefinition $idle_code -ErrorAction Stop }
}
catch {
    # 组件不可用时跳过前台等待。
    Write-Host "⚠️ 前台等待组件加载失败，回复前将不再等待你离开微信：$($_.Exception.Message)" -ForegroundColor DarkYellow
}

$CONFIG_FILE = Join-Path $PSScriptRoot "config.json"
$HISTORY_FILE = Join-Path $PSScriptRoot "chat_history.json"
$SUMMARY_FILE = Join-Path $PSScriptRoot "summary.txt"

# 通用交互及持久化函数
# 同目录写入临时文件后原子替换；替换失败保留旧文件。
function Write-AtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempPath = Join-Path ([System.IO.Path]::GetDirectoryName($fullPath)) ([System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, [System.Text.UTF8Encoding]::new($true))
        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace($tempPath, $fullPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object]$Value,
        [int]$Depth = 10
    )
    $text = ConvertTo-Json -InputObject $Value -Depth $Depth -ErrorAction Stop
    Write-AtomicText -Path $Path -Text $text
}

# 限制模型上下文中的历史条数，不修改历史文件。
function Get-RecentHistoryJson {
    param([AllowEmptyString()][string]$Json, [int]$MaxEntries = 50)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '[]' }
    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    $entries = @($parsed)
    $limit = [Math]::Max(1, $MaxEntries)
    if ($entries.Count -gt $limit) {
        $entries = @($entries[($entries.Count - $limit)..($entries.Count - 1)])
    }
    return (ConvertTo-Json -InputObject @($entries) -Depth 5 -Compress -ErrorAction Stop)
}

# 拼接可见文本块，跳过思考等其他内容块。
function Get-AIResponseText {
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$ProviderType)
    $content = $null
    switch ($ProviderType) {
        'Anthropic' { $content = $Json.content }
        'Ali' {
            if ($Json.output.choices) { $content = $Json.output.choices[0].message.content }
            if ($null -eq $content) { $content = $Json.output.text }
        }
        default {
            if (-not $Json.choices) { throw 'API 返回缺少 choices，无法提取回复正文' }
            $content = $Json.choices[0].message.content
        }
    }
    if ($content -is [string]) { return $content }
    $parts = foreach ($block in @($content)) {
        if ($null -eq $block) { continue }
        if ($block -is [string]) { $block; continue }
        if ($block.PSObject.Properties['text'] -and
            (-not $block.PSObject.Properties['type'] -or $block.type -in @('text', 'output_text'))) {
            [string]$block.text
        }
    }
    return ($parts -join '')
}

function Test-ReplyScreenCurrent {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$BeforeHash,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )
    $hash = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
    if ([string]::IsNullOrWhiteSpace($hash)) { return $false }
    if ($hash -eq $BeforeHash) { return $true }
    if (Test-BlinkGuardEnabled) {
        return (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $BeforeHash -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)
    }
    return $false
}

function Ask-Input {
    param(
        [string]$Prompt,
        $DefaultValue = "",
        [bool]$IsNumber = $false,
        [bool]$AllowEmpty = $false,
        [switch]$Secret
    )
    while ($true) {
        $backHint = if ($ShowBack) { " (b=返回)" } else { "" }
        $p = "  > $Prompt$backHint"
        
        if ($DefaultValue) {
            $p += $(if ($Secret) { ' [已保存，回车保留]' } else { " [默认：$DefaultValue]" })
        }

        if ($Secret) {
            $secureValue = Read-Host $p -AsSecureString
            $ptr = [IntPtr]::Zero
            try {
                $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
                $val = ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)).Trim()
            }
            finally {
                if ($ptr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
                $secureValue.Dispose()
            }
        }
        else { $val = (Read-Host $p).Trim() }

        if ($ShowBack -and ($val -eq "b" -or $val -eq "back")) { return "[BACK]" }

        if ($val -eq "") {
            if ($DefaultValue -ne $null -and $DefaultValue -ne '') { return $DefaultValue }
            if ($AllowEmpty) { return "" }
            Write-Host "    ⚠️ 不能为空，请重新输入或按 'b' 返回。" -ForegroundColor Red
            continue
        }

        if ($IsNumber) {
            $num = 0
            if ([int]::TryParse($val, [ref]$num)) {
                if ($num -ge 0) { return $num }
                Write-Host "    ⚠️ 数值不能为负数，请重新输入。" -ForegroundColor Red
            }
            else {
                Write-Host "    ⚠️ 请输入有效数字，或按 'b' 返回。" -ForegroundColor Red
            }
            continue
        }

        return $val
    }
}
# AI 错误分类：
#   Fatal      —— Key/权限/模型/地址错误，继续请求没有意义，需要用户改配置；
#   BadRequest —— 只针对这一次请求（如截图触发内容审核、上下文过长），按"同一画面异常"处理，重试几次后跳过该画面；
#   Retry      —— 网络、超时、429、5xx 等临时问题，冷却后重试。
# 优先使用 HTTP 状态码判断，避免错误正文里偶然出现 "400" 之类的数字造成误判。
function Get-AIErrorKind {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ErrorText,
        [int]$StatusCode = 0
    )

    $fatalPattern = 'invalid_api_key|Incorrect API key|API key not valid|authentication_error|permission_denied|model_not_found|model does not exist|InvalidApiKey|AccessDenied'

    if ($StatusCode -in @(401, 403, 404)) { return 'Fatal' }
    if ($StatusCode -eq 400 -or $StatusCode -eq 413 -or $StatusCode -eq 422) {
        # 部分服务商用 400 返回 Key 或模型错误。
        if ($ErrorText -match $fatalPattern) { return 'Fatal' }
        return 'BadRequest'
    }
    if ($StatusCode -ge 400) { return 'Retry' }   # 408 / 429 / 5xx 等

    # 没有状态码（网络异常、超时等），仅凭明确的关键字判断。
    if ($ErrorText -match $fatalPattern) { return 'Fatal' }
    return 'Retry'
}
function Start-SpinnerSleep {
    param(
        [int]$Milliseconds,
        [int]$FrameMs = 100   # spinner 帧间隔，100ms ≈ 每秒 10 帧
    )
    $elapsed = 0
    while ($elapsed -lt $Milliseconds) {
        $step = [Math]::Min($FrameMs, $Milliseconds - $elapsed)
        Start-Sleep -Milliseconds $step
        Update-Spinner
        $elapsed += $step
    }
}
function Clear-AIAbnormalState {
    $script:BadAiHash = ""
    $script:BadAiCount = 0
    $script:BadAiStreakCount = 0
    $script:BadAiCooldownUntil = [DateTime]::MinValue
}
function Register-AIAbnormalHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [string]$Raw = ""
    )

    if ($script:BadAiHash -ne $Hash) {
        $script:BadAiHash = $Hash
        $script:BadAiCount = 0
    }

    $script:BadAiCount++

    # 连续异常按所有 hash 累计，避免动态画面绕过单画面重试上限。
    if ($null -eq $script:BadAiStreakCount) { $script:BadAiStreakCount = 0 }
    $script:BadAiStreakCount++

    $rawSnippet = ""
    if (-not [string]::IsNullOrWhiteSpace($Raw)) {
        $rawSnippet = Format-LogContent $Raw
    }

    if ($null -eq $script:BadAiStreakMax -or $script:BadAiStreakMax -lt 1) {
        $script:BadAiStreakMax = [Math]::Max((([int]$script:BadAiMaxRetry + 1) * 3), 6)
    }

    if ($script:BadAiStreakCount -ge $script:BadAiStreakMax) {
        $cooldownMs = if ($script:BadAiCooldownMs -and $script:BadAiCooldownMs -gt 0) { [int]$script:BadAiCooldownMs } else { 5000 }
        $script:BadAiCooldownUntil = (Get-Date).AddMilliseconds($cooldownMs)

        Write-Log "⚠️ $Reason；AI 已连续异常 $($script:BadAiStreakCount) 次，进入短暂冷却，暂不继续请求 AI。" Yellow
        Write-AppLog "$Reason；连续 AI 异常次数=$($script:BadAiStreakCount)/$script:BadAiStreakMax；Hash=$Hash；冷却 $cooldownMs ms。原始返回：$rawSnippet" "ERROR"
        Show-AlertNotification -Key "AiStreak" -Level Error -CooldownMinutes 10 `
            -Title "AI 接口连续出错" `
            -Message "已连续异常 $($script:BadAiStreakCount) 次，自动回复暂时停止。请检查网络、API Key 或额度。原因：$Reason"

        $script:Last_Hash = $Hash
        $script:BadAiHash = ""
        $script:BadAiCount = 0
        $script:BadAiStreakCount = 0

        $script:CurrentMode = "Listening"
        Update-Spinner

        return $true
    }

    # 重试期间保留 Last_Hash，让下一轮继续处理当前画面。
    if ($script:BadAiCount -le $script:BadAiMaxRetry) {
        Write-Log "⚠️ $Reason；同一画面第 $($script:BadAiCount) 次异常，将重试，不标记为已处理。" Yellow
        Write-AppLog "$Reason；Hash=$Hash；异常次数=$($script:BadAiCount)/$($script:BadAiMaxRetry + 1)，暂不更新 Last_Hash。原始返回：$rawSnippet" "WARN"

        $script:CurrentMode = "Listening"
        Update-Spinner

        $delay = if ($CONFIG -and $CONFIG.PollingIntervalMs) { [int]$CONFIG.PollingIntervalMs } else { 1000 }
        Start-SpinnerSleep -Milliseconds $delay

        return $false
    }

    # 超过重试上限后跳过当前画面，避免持续请求。
    Write-Log "⚠️ $Reason；同一画面已连续异常 $($script:BadAiCount) 次，现标记为已处理以避免死循环。" Yellow
    Write-AppLog "$Reason；Hash=$Hash；连续异常 $($script:BadAiCount) 次，已更新 Last_Hash 防止死循环。原始返回：$rawSnippet" "ERROR"

    $script:Last_Hash = $Hash

    $script:BadAiHash = ""
    $script:BadAiCount = 0

    $script:CurrentMode = "Listening"
    Update-Spinner

    return $true
}
function Add-ChatHistoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$AI
    )

    try {
        $rawText = if (Test-Path -LiteralPath $HISTORY_FILE) {
            Get-Content -LiteralPath $HISTORY_FILE -Raw -Encoding UTF8 -ErrorAction Stop
        }
        else {
            "[]"
        }

        if ([string]::IsNullOrWhiteSpace($rawText)) {
            $rawHist = @()
        }
        else {
            try {
                $rawHist = $rawText | ConvertFrom-Json -ErrorAction Stop
                $rawHist = @($rawHist)
            }
            catch {
                Write-AppLog "历史记录 JSON 损坏，写入前已重置：$($_.Exception.Message)" "WARN"

                $backupFile = "$HISTORY_FILE.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                try {
                    if (Test-Path -LiteralPath $HISTORY_FILE) {
                        Copy-Item -LiteralPath $HISTORY_FILE $backupFile -ErrorAction SilentlyContinue
                        Write-AppLog "损坏的历史记录已备份到：$backupFile" "WARN"
                    }
                }
                catch {}

                $rawHist = @()
            }
        }

        $historyList = New-Object System.Collections.Generic.List[PSObject]

        if ($rawHist) {
            foreach ($item in @($rawHist)) {
                $historyList.Add($item)
            }
        }

        $historyList.Add([PSCustomObject]@{
                time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                user = $User
                ai   = $AI
            })

        Write-JsonFile -Path $HISTORY_FILE -Value @($historyList.ToArray()) -Depth 5
    }
    catch {
        Write-AppLog "写入历史记录失败：$($_.Exception.Message)" "WARN"
    }
}
function Register-SendFailureHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [string]$Content = "",

        [string]$Reply = "",
        [bool]$Uncertain = $false
    )

    # 注入完成但视觉校验未通过时不自动重发，避免重复消息。
    if ($Uncertain) {
        $script:Last_Hash = $Hash
        Clear-SendFailureState
        Write-Log "⚠️ $Reason；发送状态未知，已停止自动重发，请核对微信。" Yellow
        Write-AppLog "发送状态未知，停止同一画面重发 → Hash=$Hash" 'WARN'
        Show-AlertNotification -Key 'SendUncertain' -Level Warning -CooldownMinutes 5 -Title '请核对微信发送状态' -Message '消息已尝试发送，但界面校验未通过。已停止自动重发，请检查是否已发送或仍在草稿中。'
        return $true
    }

    if ($script:BadSendHash -ne $Hash) {
        $script:BadSendHash = $Hash
        $script:BadSendCount = 0
    }

    $script:BadSendCount++

    $replySnippet = ""
    if (-not [string]::IsNullOrWhiteSpace($Reply)) {
        $replySnippet = Format-LogContent $Reply
    }

    # 失败重试复用已生成的回复，不再请求模型。
    if ($script:BadSendCount -le $script:BadSendMaxRetry) {
        $script:PendingSendHash = $Hash
        $script:PendingSendContent = $Content
        $script:PendingSendReply = $Reply

        Write-Log "⚠️ $Reason；同一画面第 $($script:BadSendCount) 次发送未确认，将重试，不标记为已处理。" Yellow
        Write-AppLog "$Reason；Hash=$Hash；发送未确认次数=$($script:BadSendCount)/$($script:BadSendMaxRetry + 1)，暂不更新 Last_Hash。回复内容：$replySnippet" "WARN"

        $script:CurrentMode = "Listening"
        Update-Spinner

        $delay = if ($CONFIG -and $CONFIG.PollingIntervalMs) { [int]$CONFIG.PollingIntervalMs } else { 1000 }
        Start-SpinnerSleep -Milliseconds $delay

        return $false
    }

    # 超过失败重试上限后跳过当前画面。
    Write-Log "⚠️ $Reason；同一画面已连续发送未确认 $($script:BadSendCount) 次，现标记为已处理以避免无限重发。" Yellow
    Write-AppLog "$Reason；Hash=$Hash；连续发送未确认 $($script:BadSendCount) 次，已更新 Last_Hash 防止无限重发。回复内容：$replySnippet" "ERROR"
    Show-AlertNotification -Key "SendFailed" -Level Error -CooldownMinutes 5 `
        -Title "微信消息发送失败" `
        -Message "同一条回复连续 $($script:BadSendCount) 次没发出去，已放弃这条。请确认微信焦点还在聊天输入框上。"

    $script:Last_Hash = $Hash

    Clear-SendFailureState

    $script:CurrentMode = "Listening"
    Update-Spinner

    return $true
}
function Clear-PendingSendState {
    $script:PendingSendHash = ""
    $script:PendingSendContent = ""
    $script:PendingSendReply = ""
}

function Clear-SendFailureState {
    $script:BadSendHash = ""
    $script:BadSendCount = 0
    Clear-PendingSendState
}
function Update-Spinner {
    if ($script:GuiMode) { Send-GuiStatus; return }
    if (-not $script:SpinChars -or $script:SpinChars.Count -eq 0) { return }
    try { [Console]::CursorVisible = $false } catch {}
    $script:SpinChar = $script:SpinChars[$script:SpinIdx % $script:SpinChars.Count]
    $script:SpinIdx++
    $timeStr = Get-Date -Format "HH:mm:ss"

    # 各状态用不同颜色，扫一眼就能分辨当前在做什么。
    switch ($script:CurrentMode) {
        "Listening" { $modeText = "监听中"; $modeColor = [ConsoleColor]::DarkCyan }
        "Thinking" { $modeText = "思考中"; $modeColor = [ConsoleColor]::Yellow }
        "Replying" { $modeText = "输出中"; $modeColor = [ConsoleColor]::Green }
        "WaitingUser" { $modeText = "等你离开微信"; $modeColor = [ConsoleColor]::Magenta }
        "Delaying" { $modeText = "延迟回复中"; $modeColor = [ConsoleColor]::DarkYellow }
        default { $modeText = "未知状态"; $modeColor = [ConsoleColor]::DarkGray }
    }

    $statusLine = "[{0}] {1}... {2}" -f $timeStr, $modeText, $script:SpinChar

    # ApiWaitStart 也用于前台等待和延迟状态的计时。
    if ($script:ApiWaitStart) {
        $waitSec = [int]([DateTime]::Now - $script:ApiWaitStart).TotalSeconds
        $statusLine += "  {0} {1}s" -f $script:ApiWaitLabel, $waitSec
    }
    elseif ($script:ReplyDelayUntil) {
        # 随机延迟的剩余时间。
        $remainSec = [Math]::Max(0, [int][Math]::Ceiling(($script:ReplyDelayUntil - [DateTime]::Now).TotalSeconds))
        $statusLine += "  还剩 {0}s" -f $remainSec
    }

    # 用量统计开启时，状态行显示今日 token 用量及上限。
    if ($script:UsageToday -and (Test-UsageTrackingEnabled)) {
        $usageText = "  今日 ↑{0} ↓{1}" -f (Format-TokenCount $script:UsageToday.Input), (Format-TokenCount $script:UsageToday.Output)
        $limit = Get-DailyTokenLimit
        if ($limit -gt 0) {
            $usageText += "  [{0}/{1}]" -f (Format-TokenCount $script:UsageToday.Total), (Format-TokenCount $limit)
            if ($script:UsageToday.Total -ge $limit) { $usageText += " 已达上限" }
        }
        $statusLine += $usageText
    }
    $statusLine += "    "

    Write-Host "`r$statusLine" -NoNewline -ForegroundColor $modeColor

    $script:SpinnerVisible = $true
}
function Hide-Spinner {
    if ($script:GuiMode) { return }
    if ($script:SpinnerVisible) {
        try {
            $width = [Math]::Max(1, [Console]::BufferWidth - 1)
            Write-Host ("`r" + (' ' * $width) + "`r") -NoNewline
        }
        catch {
            Write-Host ""
        }
        $script:SpinnerVisible = $false
    }
}
function Write-Log {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Hide-Spinner
    Write-Host "$Text" -ForegroundColor $Color
    Update-Spinner
}
$script:LogLevelMap = @{ "DEBUG" = 0; "INFO" = 1; "WARN" = 2; "ERROR" = 3 }
function Write-AppLog {
    param(
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    # 未启用日志或缺少配置时直接返回。
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableLogging'] -or -not $CONFIG.EnableLogging) { return }
    
    $configLevel = if ($CONFIG.PSObject.Properties['LogLevel']) { $CONFIG.LogLevel } else { "INFO" }
    if (-not $script:LogLevelMap.ContainsKey($configLevel)) { $configLevel = "INFO" }
    if ($script:LogLevelMap[$Level] -lt $script:LogLevelMap[$configLevel]) { return }
    
    try {
        $logDir = Join-Path $PSScriptRoot "logs"
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        
        $logFile = Join-Path $logDir ("log_" + (Get-Date -Format "yyyy-MM-dd") + ".txt")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$Level] $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
    catch {
        # 日志写入失败不向外抛出。
    }
}

# 出问题时的系统通知（右下角通知气泡）
# NotifyOnProblem 控制非阻塞托盘通知；同一 Key 按冷却时间去重。
$script:AlertIcon = $null
$script:AlertLastShown = @{}
function Show-AlertNotification {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Warning",
        [double]$CooldownMinutes = 10
    )
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['NotifyOnProblem'] -or -not $CONFIG.NotifyOnProblem) { return }

    $now = Get-Date
    if ($CooldownMinutes -gt 0 -and $script:AlertLastShown.ContainsKey($Key)) {
        if (($now - $script:AlertLastShown[$Key]).TotalMinutes -lt $CooldownMinutes) { return }
    }

    if ($script:GuiMode) {
        Send-GuiMessage 'ALERT' @($Level, $Title, $Message)
        $script:AlertLastShown[$Key] = $now
        Write-AppLog "已请求界面弹出通知 → [$Key] $Title：$Message" "INFO"
        return
    }

    try {
        if (-not $script:AlertIcon) {
            $script:AlertIcon = New-Object System.Windows.Forms.NotifyIcon
            $script:AlertIcon.Icon = [System.Drawing.SystemIcons]::Information
            $script:AlertIcon.Text = "微信 AI 助手"
            $script:AlertIcon.Visible = $true
        }
        $tipIcon = [System.Windows.Forms.ToolTipIcon]::$Level
        # 限制托盘通知标题和正文的长度。
        if ($Title.Length -gt 60) { $Title = $Title.Substring(0, 60) + "…" }
        if ($Message.Length -gt 250) { $Message = $Message.Substring(0, 250) + "…" }
        $script:AlertIcon.ShowBalloonTip(10000, $Title, $Message, $tipIcon)
        [System.Windows.Forms.Application]::DoEvents()
        $script:AlertLastShown[$Key] = $now
        Write-AppLog "已弹出系统通知 → [$Key] $Title：$Message" "INFO"
    }
    catch {
        # 通知失败不向外抛出。
        Write-AppLog "弹出系统通知失败：$($_.Exception.Message)" "WARN"
    }
}

function Remove-AlertNotificationIcon {
    # 释放托盘图标资源。
    if ($script:AlertIcon) {
        try {
            $script:AlertIcon.Visible = $false
            $script:AlertIcon.Dispose()
        }
        catch {}
        $script:AlertIcon = $null
    }
}
function Wait-CropHashStable {
    <#
        连续相同或命中任一已采样 hash 时，按画面稳定处理。
        超时返回最近一次有效 hash；全程截图失败时返回 InitialHash。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight,
        [string]$InitialHash = "",
        [int]$IntervalMs = 400,
        [int]$TimeoutMs = 3000
    )

    $prev = $InitialHash
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not [string]::IsNullOrWhiteSpace($prev)) { [void]$seen.Add($prev) }

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Start-SpinnerSleep -Milliseconds $IntervalMs
        $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
        if ([string]::IsNullOrWhiteSpace($h)) { continue }

        if ($h -eq $prev) {
            Write-AppLog "发送后画面已稳定 → Hash=$h" "DEBUG"
            return $h
        }
        if ($seen.Contains($h)) {
            Write-AppLog "发送后画面在两种状态间来回切换，视为稳定 → Hash=$h" "DEBUG"
            return $h
        }
        [void]$seen.Add($h)
        $prev = $h
    }

    if ([string]::IsNullOrWhiteSpace($prev)) { $prev = $InitialHash }
    Write-AppLog "发送后画面在 $TimeoutMs ms 内未稳定，使用最后一帧 → Hash=$prev" "DEBUG"
    return $prev
}

# 前台等待：微信进程在前台且近期有键鼠操作时，暂停注入。
# 等待期间检测画面变化，过期回复交回主循环重新判断。
function Test-ForegroundWaitEnabled {
    if (-not ([System.Management.Automation.PSTypeName]'IdleUtil').Type) { return $false }
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableForegroundWait']) { return $true }
    return [bool]$CONFIG.EnableForegroundWait
}

function Test-UserBusyInWeChat {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$IdleMs
    )
    try {
        $wechatPid = [IdleUtil]::GetWindowPid($WindowHandle)
        $fgPid = [IdleUtil]::GetForegroundPid()
        if ($wechatPid -eq 0 -or $fgPid -ne $wechatPid) { return $false }
        $idle = [IdleUtil]::GetIdleMs()
        if ($idle -lt 0) { return $false }                                  # 无法读取空闲时间时不阻止发送。
        return ($idle -lt $IdleMs)
    }
    catch {
        Write-AppLog "前台等待检测异常（已忽略，直接发送）：$($_.Exception.Message)" "DEBUG"
        return $false
    }
}

function Wait-UserLeaveWeChat {
    <#
        Proceed 表示是否允许继续发送；Reason 为中止原因；WaitedMs 为等待时长。
        未启用等待或用户当前不忙时立即返回，由发送入口统一复核画面。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$BeforeHash,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )

    $res = [PSCustomObject]@{ Proceed = $true; Reason = ""; WaitedMs = 0 }
    if (-not (Test-ForegroundWaitEnabled)) { return $res }

    $idleSec = if ($CONFIG.PSObject.Properties['ForegroundIdleSeconds']) { [int]$CONFIG.ForegroundIdleSeconds } else { 3 }
    if ($idleSec -lt 1) { $idleSec = 1 }
    $idleMs = $idleSec * 1000

    if (-not (Test-UserBusyInWeChat -WindowHandle $WindowHandle -IdleMs $idleMs)) { return $res }

    $prevMode = $script:CurrentMode
    $start = Get-Date
    $nextHashCheck = $start.AddMilliseconds(1500)
    $script:CurrentMode = "WaitingUser"
    $script:ApiWaitStart = $start
    $script:ApiWaitLabel = "已等待"
    Write-Log "           ⏸️ 你正在使用微信，等你切走或停手 $idleSec 秒后再发送..." DarkYellow
    Write-AppLog "前台等待开始：微信在前台且最近 $idleSec 秒内有键鼠操作" "INFO"

    try {
        while (Test-UserBusyInWeChat -WindowHandle $WindowHandle -IdleMs $idleMs) {
            Start-SpinnerSleep -Milliseconds 300

            if ([WinUtil]::IsIconic($WindowHandle) -or [IdleUtil]::GetWindowPid($WindowHandle) -eq 0) {
                $res.Proceed = $false
                $res.Reason = "等待期间微信窗口被最小化或关闭"
                break
            }

            if ((Get-Date) -ge $nextHashCheck) {
                $nextHashCheck = (Get-Date).AddMilliseconds(1500)
                $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
                if ($h -and $h -ne $BeforeHash) {
                    # 短时采样回到原 hash 时，按闪烁处理。
                    $blinkBack = (Test-BlinkGuardEnabled) -and (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $BeforeHash `
                            -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)
                    if (-not $blinkBack) {
                        $res.Proceed = $false
                        $res.Reason = "等待期间聊天画面发生变化"
                        break
                    }
                }
            }
        }

        # 等待结束后再检查一次，覆盖停手前刚发送消息的情况。
        if ($res.Proceed) {
            $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
            if ($h -and $h -ne $BeforeHash) {
                $blinkBack = (Test-BlinkGuardEnabled) -and (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $BeforeHash `
                        -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)
                if (-not $blinkBack) {
                    $res.Proceed = $false
                    $res.Reason = "等待期间聊天画面发生变化"
                }
            }
        }
    }
    finally {
        $res.WaitedMs = [int]((Get-Date) - $start).TotalMilliseconds
        $script:ApiWaitStart = $null
        $script:ApiWaitLabel = ""
        $script:CurrentMode = $prevMode
        Update-Spinner
    }

    $waitedSec = [Math]::Round($res.WaitedMs / 1000.0, 1)
    if ($res.Proceed) {
        Write-Log "           ▶️ 已等待 ${waitedSec}s，继续发送" DarkGray
        Write-AppLog "前台等待结束，继续发送 → 等待 ${waitedSec}s" "INFO"
    }
    else {
        Write-Log "           ⏹️ $($res.Reason)，这条回复作废，重新判断（已等待 ${waitedSec}s）" DarkYellow
        Write-AppLog "前台等待中止：$($res.Reason)，回复作废 → 等待 ${waitedSec}s" "INFO"
    }
    return $res
}

# 随机回复延迟：反应时间 + 字符数 × 单字耗时 × 抖动，受总时长上限约束。
# 扣除检测消息后已花费的时间；等待期间画面变化则丢弃旧回复。
$script:ReplyDelayRandom = New-Object System.Random
$script:ReplyDelayUntil = $null

function Test-ReplyDelayEnabled {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableReplyDelay']) { return $false }
    return [bool]$CONFIG.EnableReplyDelay
}

function Get-ReplyDelayTargetMs {
    param([string]$Message)

    $minSec = if ($CONFIG.PSObject.Properties['ReplyDelayMinSeconds']) { [double]$CONFIG.ReplyDelayMinSeconds } else { 3 }
    $maxSec = if ($CONFIG.PSObject.Properties['ReplyDelayMaxSeconds']) { [double]$CONFIG.ReplyDelayMaxSeconds } else { 12 }
    $perCharMs = if ($CONFIG.PSObject.Properties['ReplyDelayPerCharMs']) { [double]$CONFIG.ReplyDelayPerCharMs } else { 150 }
    $capSec = if ($CONFIG.PSObject.Properties['ReplyDelayMaxTotalSeconds']) { [double]$CONFIG.ReplyDelayMaxTotalSeconds } else { 40 }
    if ($maxSec -lt $minSec) { $t = $minSec; $minSec = $maxSec; $maxSec = $t }

    $rnd = $script:ReplyDelayRandom
    $reactionMs = ($minSec + $rnd.NextDouble() * ($maxSec - $minSec)) * 1000
    $charCount = if ($Message) { $Message.Length } else { 0 }
    $typingMs = $charCount * $perCharMs * (0.7 + $rnd.NextDouble() * 0.6)

    $targetMs = [Math]::Min($reactionMs + $typingMs, $capSec * 1000)
    return [PSCustomObject]@{
        TargetMs   = [int]$targetMs
        ReactionMs = [int]$reactionMs
        TypingMs   = [int]$typingMs
        Capped     = (($reactionMs + $typingMs) -gt ($capSec * 1000))
    }
}

function Wait-HumanLikeDelay {
    <#
        Proceed 表示是否允许继续发送；Reason 为中止原因；WaitedMs 为额外等待时长。
        未启用延迟或已耗时足够时立即返回，由发送入口统一复核画面。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$BeforeHash,
        [Parameter(Mandatory)][string]$Message,
        $DetectedAt = $null,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )

    $res = [PSCustomObject]@{ Proceed = $true; Reason = ""; WaitedMs = 0 }
    if (-not (Test-ReplyDelayEnabled)) { return $res }

    $plan = Get-ReplyDelayTargetMs -Message $Message
    $spentMs = if ($DetectedAt) { [int]((Get-Date) - [DateTime]$DetectedAt).TotalMilliseconds } else { 0 }
    $remainMs = $plan.TargetMs - $spentMs

    $targetSec = [Math]::Round($plan.TargetMs / 1000.0, 1)
    $spentSec = [Math]::Round($spentMs / 1000.0, 1)
    Write-AppLog ("随机延迟 → 目标 {0}ms（反应 {1}ms + 打字 {2}ms{3}），已耗时 {4}ms，还需等待 {5}ms" -f `
            $plan.TargetMs, $plan.ReactionMs, $plan.TypingMs, $(if ($plan.Capped) { '，已封顶' } else { '' }), $spentMs, [Math]::Max(0, $remainMs)) "DEBUG"

    if ($remainMs -le 300) {
        return $res
    }

    $remainSec = [Math]::Round($remainMs / 1000.0, 1)
    Write-Log "           ⏳ 模拟真人回复节奏：再等 ${remainSec}s 发送（目标 ${targetSec}s，已过 ${spentSec}s）" DarkGray

    $prevMode = $script:CurrentMode
    $start = Get-Date
    $deadline = $start.AddMilliseconds($remainMs)
    $nextHashCheck = $start.AddMilliseconds(1500)
    $script:CurrentMode = "Delaying"
    $script:ReplyDelayUntil = $deadline

    try {
        while ((Get-Date) -lt $deadline) {
            $left = [int]($deadline - (Get-Date)).TotalMilliseconds
            Start-SpinnerSleep -Milliseconds ([Math]::Max(1, [Math]::Min(300, $left)))

            if ([WinUtil]::IsIconic($WindowHandle) -or [IdleUtil]::GetWindowPid($WindowHandle) -eq 0) {
                $res.Proceed = $false
                $res.Reason = "延迟期间微信窗口被最小化或关闭"
                break
            }

            if ((Get-Date) -ge $nextHashCheck) {
                $nextHashCheck = (Get-Date).AddMilliseconds(1500)
                $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
                if ($h -and $h -ne $BeforeHash) {
                    $blinkBack = (Test-BlinkGuardEnabled) -and (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $BeforeHash `
                            -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)
                    if (-not $blinkBack) {
                        $res.Proceed = $false
                        $res.Reason = "延迟期间聊天画面发生变化（对方可能又发了消息）"
                        break
                    }
                }
            }
        }

        if ($res.Proceed) {
            $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
            if ($h -and $h -ne $BeforeHash) {
                $blinkBack = (Test-BlinkGuardEnabled) -and (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $BeforeHash `
                        -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)
                if (-not $blinkBack) {
                    $res.Proceed = $false
                    $res.Reason = "延迟期间聊天画面发生变化（对方可能又发了消息）"
                }
            }
        }
    }
    finally {
        $res.WaitedMs = [int]((Get-Date) - $start).TotalMilliseconds
        $script:ReplyDelayUntil = $null
        $script:CurrentMode = $prevMode
        Update-Spinner
    }

    if (-not $res.Proceed) {
        $waitedSec = [Math]::Round($res.WaitedMs / 1000.0, 1)
        Write-Log "           ⏹️ $($res.Reason)，这条回复作废，重新判断（已等待 ${waitedSec}s）" DarkYellow
        Write-AppLog "随机延迟中止：$($res.Reason)，回复作废 → 已等待 $($res.WaitedMs)ms" "INFO"
    }
    return $res
}

# 发送后以截图变化做视觉校验，不代表服务器送达回执。
# Deferred：尚未发送，需重新判断；Uncertain：已尝试发送但校验未通过，应停止重发。
function Invoke-ReplySendAndVerify {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$BeforeHash,

        [Parameter(Mandatory = $true)]
        [int]$CropWidth,

        [Parameter(Mandatory = $true)]
        [int]$CropHeight,

        [Parameter(Mandatory = $true)]
        [int]$MarginLeft,

        [Parameter(Mandatory = $true)]
        [int]$MarginTop,

        # 重试缓存回复时不再添加随机延迟。
        [switch]$HumanDelay,

        # 延迟计算从检测到消息的时刻开始。
        $DetectedAt = $null
    )

    if ($HumanDelay) {
        $delayRes = Wait-HumanLikeDelay `
            -WindowHandle $WindowHandle `
            -BeforeHash $BeforeHash `
            -Message $Message `
            -DetectedAt $DetectedAt `
            -MarginLeft $MarginLeft `
            -MarginTop $MarginTop `
            -CropWidth $CropWidth `
            -CropHeight $CropHeight
        if (-not $delayRes.Proceed) {
            return [PSCustomObject]@{
                Confirmed = $false
                Deferred  = $true
                Reason    = $delayRes.Reason
                AfterHash = ""
            }
        }
    }

    $fgWait = Wait-UserLeaveWeChat `
        -WindowHandle $WindowHandle `
        -BeforeHash $BeforeHash `
        -MarginLeft $MarginLeft `
        -MarginTop $MarginTop `
        -CropWidth $CropWidth `
        -CropHeight $CropHeight
    if (-not $fgWait.Proceed) {
        return [PSCustomObject]@{
            Confirmed = $false
            Deferred  = $true
            Reason    = $fgWait.Reason
            AfterHash = ""
        }
    }

    # 所有发送路径在注入前统一复核画面。
    if (-not (Test-ReplyScreenCurrent -WindowHandle $WindowHandle -BeforeHash $BeforeHash -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight)) {
        Write-AppLog '发送前画面已变化或截图失败，放弃旧回复，重新判断' 'WARN'
        return [PSCustomObject]@{ Confirmed = $false; Deferred = $true; Reason = '发送前无法确认画面仍有效'; AfterHash = ''; Uncertain = $false }
    }

    $sendOk = Send-WeChatMessage `
        -WindowHandle $WindowHandle `
        -Message $Message `
        -Method $Method `
        -CharDelayMs 3 `
        -EnterDelayMs 80 `
        -PressEnter $true

    if (-not $sendOk) {
        Write-Log "           ⚠️ 消息发送失败，请检查日志" Yellow
        Write-AppLog "Send-WeChatMessage 返回失败" "ERROR"
    }

    Start-SpinnerSleep -Milliseconds 1000

    $verifyOk = $false
    $verifyReason = '发送后界面 hash 未变化，消息未确认送达'
    $verifyHash = ""

    try {
        $verifyHash = (Get-WindowCrop -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight).Hash

        if ($verifyHash -eq $BeforeHash) {
            Write-Log "           ⚠️ 界面未变化，消息可能未送达（焦点是否仍在输入框？）" Yellow
            Write-AppLog "静默失败检测：发送后 hash 未变化，消息可能未送达" "WARN"
        }
        else {
            $verifyOk = $true
            Write-AppLog "发送后 hash 已变化，通过界面变化校验（不代表服务器送达回执）" "DEBUG"
        }
    }
    catch {
        $verifyReason = "发送后校验失败：$($_.Exception.Message)"
        Write-AppLog $verifyReason "WARN"
    }
    $confirmed = ($sendOk -and $verifyOk)

    # 视觉校验通过后等待画面稳定，以返回的 hash 作为后续监听基准。
    $afterHash = ""
    if ($confirmed) {
        $afterHash = Wait-CropHashStable `
            -WindowHandle $WindowHandle `
            -MarginLeft $MarginLeft `
            -MarginTop $MarginTop `
            -CropWidth $CropWidth `
            -CropHeight $CropHeight `
            -InitialHash $verifyHash
    }

    $reason = if (-not $sendOk) {
        "Send-WeChatMessage 返回失败"
    }
    elseif (-not $verifyOk) {
        $verifyReason
    }
    else {
        ""
    }

    return [PSCustomObject]@{
        Confirmed = $confirmed
        Deferred  = $false
        Reason    = $reason
        AfterHash = $afterHash
        Uncertain = ($sendOk -and -not $verifyOk)
    }
}
# 启动时按 LogRetentionDays 清理旧日志；0 表示保留。
function Invoke-LogRotation {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableLogging'] -or -not $CONFIG.EnableLogging) { return }
    
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path -LiteralPath $logDir)) { return }
    
    $retentionDays = if ($CONFIG.PSObject.Properties['LogRetentionDays']) { [int]$CONFIG.LogRetentionDays } else { 14 }
    if ($retentionDays -le 0) { return }
    
    $cutoff = (Get-Date).AddDays(-$retentionDays)
    try {
        $oldLogs = Get-ChildItem -Path $logDir -Filter "log_*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }
        $cleaned = 0
        foreach ($f in $oldLogs) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            $cleaned++
        }
        if ($cleaned -gt 0) {
            Write-AppLog "清理了 $cleaned 个超过 $retentionDays 天的旧日志文件" "INFO"
        }
    }
    catch {
        # 清理失败不影响启动。
    }
}

# 按 LogRedactContent 隐藏正文，关闭脱敏时最多记录 500 字符。
function Format-LogContent {
    param([string]$Content)
    if ($null -eq $Content) { return "[null]" }
    $redact = $true
    if ($CONFIG -and $CONFIG.PSObject.Properties['LogRedactContent']) {
        $redact = [bool]$CONFIG.LogRedactContent
    }
    if ($redact) {
        return "[redacted: $($Content.Length) chars]"
    }
    else {
        if ($Content.Length -gt 500) {
            return $Content.Substring(0, 500) + "...[truncated, total $($Content.Length) chars]"
        }
        return $Content
    }
}

# Token 用量统计：累计模型返回的 usage，并按 EnableUsageTracking 追加 JSONL。
# DailyTokenLimit 达到阈值后暂停后续模型请求；统计日期切换时清零。
$USAGE_DIR = Join-Path $PSScriptRoot "usage"

function Test-UsageTrackingEnabled {
    if (-not $CONFIG) { return $false }
    if (-not $CONFIG.PSObject.Properties['EnableUsageTracking']) { return $true }
    return [bool]$CONFIG.EnableUsageTracking
}

function Get-DailyTokenLimit {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['DailyTokenLimit']) { return 0 }
    try { return [long]$CONFIG.DailyTokenLimit } catch { return 0 }
}

function New-UsageCounter {
    return [PSCustomObject]@{ Requests = 0; Input = [long]0; Output = [long]0; Reasoning = [long]0; CacheHit = [long]0; Total = [long]0 }
}

function Get-UsageFilePath {
    param([string]$Day = (Get-Date -Format "yyyy-MM-dd"))
    return (Join-Path $USAGE_DIR "usage_$Day.jsonl")
}

# 沿属性路径取整数；缺失、空值或转换失败时返回 0。
function Get-UsageNumber {
    param($Object, [string[]]$Path)
    $cur = $Object
    foreach ($p in $Path) {
        if ($null -eq $cur) { return [long]0 }
        if (-not $cur.PSObject.Properties[$p]) { return [long]0 }
        $cur = $cur.$p
    }
    if ($null -eq $cur) { return [long]0 }
    try { return [long]$cur } catch { return [long]0 }
}

function Get-TokenUsageFromResponse {
    param(
        [Parameter(Mandatory)] $Json,
        [Parameter(Mandatory)] [string]$ProviderType
    )

    $u = $null
    if ($Json.PSObject.Properties['usage']) { $u = $Json.usage }
    if (-not $u -and $ProviderType -eq "Ali" -and $Json.PSObject.Properties['output'] -and $Json.output.PSObject.Properties['usage']) {
        $u = $Json.output.usage
    }

    $inputTokens = [long]0; $outputTokens = [long]0; $reasoning = [long]0; $cacheHit = [long]0
    $finish = ""

    if ($u) {
        switch ($ProviderType) {
            "Anthropic" {
                # Anthropic 的 input_tokens 不含缓存部分，需要加上缓存写入/读取才是实际输入量
                $cacheRead = Get-UsageNumber $u @('cache_read_input_tokens')
                $cacheWrite = Get-UsageNumber $u @('cache_creation_input_tokens')
                $inputTokens = (Get-UsageNumber $u @('input_tokens')) + $cacheRead + $cacheWrite
                $outputTokens = Get-UsageNumber $u @('output_tokens')
                $cacheHit = $cacheRead
            }
            "Ali" {
                $inputTokens = Get-UsageNumber $u @('input_tokens')
                $outputTokens = Get-UsageNumber $u @('output_tokens')
                $reasoning = Get-UsageNumber $u @('output_tokens_details', 'reasoning_tokens')
                $cacheHit = Get-UsageNumber $u @('prompt_tokens_details', 'cached_tokens')
                # 兼容 DashScope 的 OpenAI 风格字段
                if ($inputTokens -eq 0) { $inputTokens = Get-UsageNumber $u @('prompt_tokens') }
                if ($outputTokens -eq 0) { $outputTokens = Get-UsageNumber $u @('completion_tokens') }
            }
            default {
                # OpenAI 兼容：prompt_tokens 已包含缓存命中部分，completion_tokens 已包含思考部分
                $inputTokens = Get-UsageNumber $u @('prompt_tokens')
                $outputTokens = Get-UsageNumber $u @('completion_tokens')
                $reasoning = Get-UsageNumber $u @('completion_tokens_details', 'reasoning_tokens')
                $cacheHit = Get-UsageNumber $u @('prompt_cache_hit_tokens')          # DeepSeek
                if ($cacheHit -eq 0) { $cacheHit = Get-UsageNumber $u @('prompt_tokens_details', 'cached_tokens') }  # OpenAI
            }
        }
    }

    try {
        switch ($ProviderType) {
            "Anthropic" { if ($Json.PSObject.Properties['stop_reason']) { $finish = [string]$Json.stop_reason } }
            "Ali" {
                if ($Json.output.choices) { $finish = [string]$Json.output.choices[0].finish_reason }
                elseif ($Json.output.PSObject.Properties['finish_reason']) { $finish = [string]$Json.output.finish_reason }
            }
            default { if ($Json.choices) { $finish = [string]$Json.choices[0].finish_reason } }
        }
    }
    catch {}

    $total = [long]0
    if ($u -and $u.PSObject.Properties['total_tokens']) { $total = Get-UsageNumber $u @('total_tokens') }
    if ($total -le 0) { $total = $inputTokens + $outputTokens }

    return [PSCustomObject]@{
        HasUsage     = [bool]$u
        Input        = $inputTokens
        Output       = $outputTokens
        Reasoning    = $reasoning
        CacheHit     = $cacheHit
        Total        = $total
        FinishReason = $finish
        Truncated    = ($finish -in @('length', 'max_tokens'))
    }
}

function Sync-UsageDay {
    $today = Get-Date -Format "yyyy-MM-dd"
    if ($script:UsageDay -ne $today) {
        $script:UsageDay = $today
        $script:UsageToday = New-UsageCounter
        $script:TokenLimitNotified = $false
    }
}

# 从今日用量日志恢复计数；关闭落盘时无法恢复未保存的用量。
function Initialize-TokenUsage {
    $script:UsageDay = Get-Date -Format "yyyy-MM-dd"
    $script:UsageToday = New-UsageCounter
    $script:UsageSession = New-UsageCounter
    $script:UsageSinceReply = New-UsageCounter   # 距离上一条消息处理以来的 Chat 用量（含空转、重试）
    $script:TokenLimitNotified = $false
    $script:LastUsage = $null

    $file = Get-UsageFilePath -Day $script:UsageDay
    if (-not (Test-Path -LiteralPath $file)) { return }

    try {
        foreach ($line in [System.IO.File]::ReadLines($file, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $r = $line | ConvertFrom-Json -ErrorAction Stop
                $script:UsageToday.Requests++
                $script:UsageToday.Input += Get-UsageNumber $r @('input')
                $script:UsageToday.Output += Get-UsageNumber $r @('output')
                $script:UsageToday.Reasoning += Get-UsageNumber $r @('reasoning')
                $script:UsageToday.CacheHit += Get-UsageNumber $r @('cacheHit')
                $script:UsageToday.Total += Get-UsageNumber $r @('total')
            }
            catch {}
        }
    }
    catch {
        Write-AppLog "读取今日用量文件失败（已忽略）：$($_.Exception.Message)" "WARN"
    }
}

function Add-TokenUsageRecord {
    param(
        $Usage,
        [Parameter(Mandatory)][ValidateSet("Chat", "Summary", "Proactive")][string]$Purpose,
        [string]$Model = "",
        [bool]$IsRetry = $false
    )

    if ($null -eq $Usage) { return }
    Sync-UsageDay

    if ($Usage.Truncated) {
        Write-AppLog "AI 回复因达到 MaxTokens 被截断 → Purpose=$Purpose, Model=$Model, Output=$($Usage.Output), Reasoning=$($Usage.Reasoning)。可调大 config.json 中的 MaxTokens 或关闭 DeepThinking" "WARN"
    }

    if (-not $Usage.HasUsage) {
        Write-AppLog "API 响应中没有 usage 字段，本次 token 用量未统计 → Purpose=$Purpose, Model=$Model" "DEBUG"
        return
    }

    $counters = @($script:UsageToday, $script:UsageSession)
    # 只有 Chat 请求计入每条回复的用量；其他用途只计入今日和会话总量。
    if ($Purpose -eq "Chat" -and $script:UsageSinceReply) { $counters += $script:UsageSinceReply }
    foreach ($c in $counters) {
        $c.Requests++
        $c.Input += $Usage.Input
        $c.Output += $Usage.Output
        $c.Reasoning += $Usage.Reasoning
        $c.CacheHit += $Usage.CacheHit
        $c.Total += $Usage.Total
    }

    Write-AppLog ("Token 用量 → {0} 输入={1} 输出={2} (思考={3}) 缓存命中={4} 合计={5}{6} | 今日累计={7}" -f `
            $Purpose, $Usage.Input, $Usage.Output, $Usage.Reasoning, $Usage.CacheHit, $Usage.Total, `
        $(if ($IsRetry) { " [重试]" } else { "" }), $script:UsageToday.Total) "INFO"

    if (-not (Test-UsageTrackingEnabled)) { return }

    try {
        if (-not (Test-Path -LiteralPath $USAGE_DIR)) { New-Item -Path $USAGE_DIR -ItemType Directory -Force | Out-Null }
        $record = [ordered]@{
            time      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            purpose   = $Purpose
            model     = $Model
            input     = $Usage.Input
            output    = $Usage.Output
            reasoning = $Usage.Reasoning
            cacheHit  = $Usage.CacheHit
            total     = $Usage.Total
            finish    = $Usage.FinishReason
            retry     = $IsRetry
        }
        $line = ([PSCustomObject]$record | ConvertTo-Json -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText((Get-UsageFilePath -Day $script:UsageDay), $line, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # 用量写入失败不向外抛出。
        Write-AppLog "写入用量记录失败（已忽略）：$($_.Exception.Message)" "DEBUG"
    }
}

# 今日用量是否已达上限（DailyTokenLimit <= 0 表示不限制）
function Test-DailyTokenLimitReached {
    Sync-UsageDay
    $limit = Get-DailyTokenLimit
    if ($limit -le 0) { return $false }
    return ($script:UsageToday.Total -ge $limit)
}

# 格式化本条回复及期间重试的用量，并清零累计计数。
function Pop-MessageUsageSuffix {
    $suffix = ""
    $since = $script:UsageSinceReply
    $last = $script:LastUsage

    if ((Test-UsageTrackingEnabled) -and $last -and $last.HasUsage) {
        $suffix = "↑{0} ↓{1}" -f (Format-TokenCount $last.Input), (Format-TokenCount $last.Output)
        if ($last.Reasoning -gt 0) { $suffix += "，思考 $(Format-TokenCount $last.Reasoning)" }

        if ($since -and $since.Requests -gt 1) {
            $suffix = "本条 $suffix，期间共 $($since.Requests) 次请求 ↑$(Format-TokenCount $since.Input) ↓$(Format-TokenCount $since.Output)"
        }
        $suffix = "  ($suffix)"
    }

    $script:UsageSinceReply = New-UsageCounter
    return $suffix
}

function Format-TokenCount {
    param([long]$Value)
    if ($Value -ge 1000000) { return ("{0:0.##}M" -f ($Value / 1000000.0)) }
    if ($Value -ge 1000) { return ("{0:0.#}k" -f ($Value / 1000.0)) }
    return "$Value"
}

# 检测 UTF-16 高代理项；Hybrid 据此为 BMP 以外的字符选择剪贴板路径。
function Test-HasSurrogateChar {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($ch in $Text.ToCharArray()) {
        if ([char]::IsHighSurrogate($ch)) { return $true }
    }
    return $false
}

# 通过窗口鼠标消息尝试聚焦输入框，不移动系统鼠标指针。
function ConvertTo-LParam {
    param([int]$X, [int]$Y)
    # 高 16 位放 Y，低 16 位放 X
    $packed = (($Y -band 0xFFFF) -shl 16) -bor ($X -band 0xFFFF)
    return [IntPtr]$packed
}

function Get-FocusedHwnd {
    param([IntPtr]$WindowHandle)
    # 查询指定窗口所属线程当前的焦点子控件，失败返回 [IntPtr]::Zero
    try {
        $tid = [WinUtil]::GetWindowThreadProcessId($WindowHandle, [IntPtr]::Zero)
        if ($tid -eq 0) { return [IntPtr]::Zero }
        $gti = New-Object WinUtil+GUITHREADINFO
        $gti.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][WinUtil+GUITHREADINFO])
        if ([WinUtil]::GetGUIThreadInfo($tid, [ref]$gti)) { return $gti.hwndFocus }
    }
    catch {
        Write-AppLog "Get-FocusedHwnd 异常（已忽略）：$($_.Exception.Message)" "DEBUG"
    }
    return [IntPtr]::Zero
}

function Send-PhantomClick {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][int]$ClientX,
        [Parameter(Mandatory)][int]$ClientY
    )
    $lp = ConvertTo-LParam -X $ClientX -Y $ClientY
    [void][WinUtil]::PostMessage($WindowHandle, [WinUtil]::WM_MOUSEMOVE, [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 20
    [void][WinUtil]::PostMessage($WindowHandle, [WinUtil]::WM_LBUTTONDOWN, [IntPtr][WinUtil]::MK_LBUTTON, $lp)
    Start-Sleep -Milliseconds 30
    [void][WinUtil]::PostMessage($WindowHandle, [WinUtil]::WM_LBUTTONUP, [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 80
}

function Invoke-FocusInputBox {
    <#
        点击位置使用整窗截图坐标；发送鼠标消息前换算为客户区坐标。
        WindowX/WindowY 未指定时，使用 InputBoxClickRatioX 和 InputBoxOffsetFromBottom。
        返回焦点句柄是否变化，仅作诊断；不验证焦点是否确为输入框。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$WindowX = -1,
        [int]$WindowY = -1
    )

    # 最小化时先尝试不激活还原，再计算点击坐标。
    if ([WinUtil]::IsIconic($WindowHandle)) {
        [void][WinUtil]::ShowWindow($WindowHandle, [WinUtil]::SW_SHOWNOACTIVATE)
        Start-Sleep -Milliseconds 200
        Write-AppLog "对焦点击前发现窗口最小化，已静默还原" "DEBUG"
    }

    $wr = New-Object WinUtil+RECT
    $cr = New-Object WinUtil+RECT
    if (-not [WinUtil]::GetWindowRect($WindowHandle, [ref]$wr) -or -not [WinUtil]::GetClientRect($WindowHandle, [ref]$cr)) {
        Write-AppLog "获取窗口/客户区尺寸失败，跳过对焦点击" "WARN"
        return $false
    }
    $ww = $wr.Right - $wr.Left
    $wh = $wr.Bottom - $wr.Top
    $cw = $cr.Right - $cr.Left
    $ch = $cr.Bottom - $cr.Top
    if ($ww -le 0 -or $wh -le 0 -or $cw -le 0 -or $ch -le 0) {
        Write-AppLog "窗口尺寸异常（窗口 ${ww}x${wh}，客户区 ${cw}x${ch}），跳过对焦点击" "WARN"
        return $false
    }

    if ($WindowX -lt 0 -or $WindowY -lt 0) {
        $ratioX = 0.65
        $offBot = 50
        if ($CONFIG -and $CONFIG.PSObject.Properties['InputBoxClickRatioX']) { $ratioX = [double]$CONFIG.InputBoxClickRatioX }
        if ($CONFIG -and $CONFIG.PSObject.Properties['InputBoxOffsetFromBottom']) { $offBot = [int]$CONFIG.InputBoxOffsetFromBottom }
        if ($ratioX -le 0 -or $ratioX -ge 1) { $ratioX = 0.65 }
        if ($offBot -lt 1) { $offBot = 1 }
        if ($offBot -ge $wh) { $offBot = [int][math]::Max(1, $wh / 4) }
        $WindowX = [int]($ww * $ratioX)
        $WindowY = $wh - $offBot
    }

    $origin = New-Object WinUtil+POINT
    $origin.X = 0; $origin.Y = 0
    $offX = 0; $offY = 0
    if ([WinUtil]::ClientToScreen($WindowHandle, [ref]$origin)) {
        $offX = $origin.X - $wr.Left
        $offY = $origin.Y - $wr.Top
    }
    $px = [int][math]::Max(0, [math]::Min($cw - 1, $WindowX - $offX))
    $py = [int][math]::Max(0, [math]::Min($ch - 1, $WindowY - $offY))

    $beforeFocus = Get-FocusedHwnd -WindowHandle $WindowHandle
    Send-PhantomClick -WindowHandle $WindowHandle -ClientX $px -ClientY $py
    $afterFocus = Get-FocusedHwnd -WindowHandle $WindowHandle

    $changed = ($beforeFocus -ne $afterFocus) -or ($afterFocus -ne [IntPtr]::Zero -and $beforeFocus -eq [IntPtr]::Zero)
    Write-AppLog ("对焦点击 → 窗口({0}x{1}) 点({2},{3}) → 客户区({4}x{5}) 点({6},{7}) [原点偏移 {8},{9}] | focus before=0x{10:X} after=0x{11:X} | changed={12}" -f `
            $ww, $wh, $WindowX, $WindowY, $cw, $ch, $px, $py, $offX, $offY, $beforeFocus.ToInt64(), $afterFocus.ToInt64(), $changed) "DEBUG"
    return $changed
}

# 发送方式：WMChar 注入字符；Hybrid 遇到代理项改走剪贴板；Clipboard 始终粘贴。
# 剪贴板路径需临时切到前台，结束后尝试恢复原前台窗口和剪贴板内容。
# EnableFocusClick 控制可选的发送前点击；剪贴板前台路径还会尝试聚焦。
function Invoke-WithWeChatForeground {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $oldForeground = [IntPtr]::Zero

    try {
        $oldForeground = [WinUtil]::GetForegroundWindow()

        if ([WinUtil]::IsIconic($WindowHandle)) {
            [void][WinUtil]::ShowWindow($WindowHandle, [WinUtil]::SW_RESTORE)
            Start-Sleep -Milliseconds 250
        }

        [void][WinUtil]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 200

        $nowForeground = [WinUtil]::GetForegroundWindow()
        if ($nowForeground -ne $WindowHandle) {
            Write-AppLog "微信未能切到前台，SendKeys 可能会发到当前窗口，已取消本次剪贴板发送" "ERROR"
            return $false
        }

        try {
            [void](Invoke-FocusInputBox -WindowHandle $WindowHandle)
            Start-Sleep -Milliseconds 100
        }
        catch {
            Write-AppLog "前台发送前聚焦输入框失败：$($_.Exception.Message)" "WARN"
        }

        & $Action
        return $true
    }
    finally {
        if ($oldForeground -ne [IntPtr]::Zero -and $oldForeground -ne $WindowHandle) {
            Start-Sleep -Milliseconds 150
            [void][WinUtil]::SetForegroundWindow($oldForeground)
        }
    }
}
function Send-WeChatMessage {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$WindowHandle,
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("WMChar", "Hybrid", "Clipboard")]
        [string]$Method = "Hybrid",
        [int]$CharDelayMs = 3,
        [int]$EnterDelayMs = 80,
        [bool]$PressEnter = $true
    )

    if ([string]::IsNullOrEmpty($Message)) { return $false }

    # 按 EnableFocusClick 尝试点击输入位置；此开关可在校准向导设置。
    $doFocusClick = $false
    if ($CONFIG.PSObject.Properties['EnableFocusClick']) {
        $doFocusClick = [bool]$CONFIG.EnableFocusClick
    }
    if ($doFocusClick) {
        try {
            $focusOk = Invoke-FocusInputBox -WindowHandle $WindowHandle
            if (-not $focusOk) {
                Write-AppLog "对焦点击未检测到焦点变化（仍继续尝试发送，可能本来就在输入框）" "DEBUG"
            }
        }
        catch {
            # 聚焦失败时记录日志，仍继续尝试发送。
            Write-AppLog "对焦点击异常（已忽略）：$($_.Exception.Message)" "WARN"
        }
    }

    $actualMethod = $Method
    if ($Method -eq "Hybrid" -and (Test-HasSurrogateChar -Text $Message)) {
        $actualMethod = "Clipboard"
        Write-AppLog "Hybrid 模式：检测到 emoji，本次切换为剪贴板路径" "DEBUG"
    }
    elseif ($Method -eq "Hybrid") {
        $actualMethod = "WMChar"
    }

    try {
        if ($actualMethod -eq "Clipboard") {
            # 剪贴板发送在 finally 中尝试恢复原内容。
            $oldClipData = $null
            $hadOldClipData = $false
            $clipboardChanged = $false

            try {
                # 备份 IDataObject，以便恢复文本以外的剪贴板格式。
                for ($i = 1; $i -le 5; $i++) {
                    try {
                        $oldClipData = [System.Windows.Forms.Clipboard]::GetDataObject()
                        $hadOldClipData = ($null -ne $oldClipData)
                        break
                    }
                    catch {
                        if ($i -eq 5) {
                            Write-AppLog "剪贴板备份失败，为避免覆盖用户剪贴板，本次发送取消：$($_.Exception.Message)" "ERROR"
                            return $false
                        }
                        Start-Sleep -Milliseconds 80
                    }
                }

                # 剪贴板可能被占用，写入失败时有限重试。
                $setOk = $false
                for ($i = 1; $i -le 5; $i++) {
                    try {
                        [System.Windows.Forms.Clipboard]::SetText($Message)
                        $clipboardChanged = $true
                        $setOk = $true
                        break
                    }
                    catch {
                        if ($i -eq 5) {
                            Write-AppLog "剪贴板写入失败：$($_.Exception.Message)" "ERROR"
                            return $false
                        }
                        Start-Sleep -Milliseconds 80
                    }
                }

                if (-not $setOk) {
                    Write-AppLog "剪贴板写入失败：未知原因" "ERROR"
                    return $false
                }

                Start-Sleep -Milliseconds 50

                # SendKeys 依赖前台窗口；确认微信获得前台后才执行粘贴和回车。
                $sendOk = Invoke-WithWeChatForeground -WindowHandle $WindowHandle -Action {
                    [System.Windows.Forms.SendKeys]::SendWait("^v")
                    Start-Sleep -Milliseconds 80

                    if ($PressEnter) {
                        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
                    }
                }

                if (-not $sendOk) {
                    Write-AppLog "前台剪贴板发送失败，已取消本次发送" "ERROR"
                    return $false
                }

                Start-Sleep -Milliseconds 200
                return $true
            }
            finally {
                if ($clipboardChanged) {
                    $restoreOk = $false
                    $maxRestoreAttempts = 5
                    $restoreRetryDelayMs = 80

                    for ($i = 1; $i -le $maxRestoreAttempts; $i++) {
                        try {
                            if ($hadOldClipData -and $null -ne $oldClipData) {
                                [System.Windows.Forms.Clipboard]::SetDataObject($oldClipData, $true)
                            }
                            else {
                                [System.Windows.Forms.Clipboard]::Clear()
                            }

                            $restoreOk = $true
                            break
                        }
                        catch {
                            if ($i -eq $maxRestoreAttempts) {
                                Write-AppLog "剪贴板恢复失败，当前剪贴板可能仍是刚发送的消息：$($_.Exception.Message)" "WARN"
                            }
                            else {
                                Start-Sleep -Milliseconds $restoreRetryDelayMs
                            }
                        }
                    }

                    if ($restoreOk) {
                        Write-AppLog "剪贴板已恢复" "DEBUG"
                    }
                }
            }
        }
        else {
            # 后台字符消息注入。
            # WM_CHAR 0x0D 等同于按回车，多行回复中的 \r 会把消息提前发出去；统一换成 \n（输入框内换行）。
            $charText = $Message -replace "`r`n", "`n" -replace "`r", "`n"
            foreach ($ch in $charText.ToCharArray()) {
                [void][WinUtil]::PostMessage(
                    $WindowHandle,
                    [WinUtil]::WM_CHAR,
                    [IntPtr][int]$ch,
                    [IntPtr]::Zero
                )
                if ($CharDelayMs -gt 0) {
                    Start-Sleep -Milliseconds $CharDelayMs
                }
            }

            if ($PressEnter) {
                if ($EnterDelayMs -gt 0) { Start-Sleep -Milliseconds $EnterDelayMs }
                [void][WinUtil]::PostMessage(
                    $WindowHandle,
                    [WinUtil]::WM_KEYDOWN,
                    [IntPtr][int][WinUtil]::VK_RETURN,
                    [IntPtr]::Zero
                )
                [void][WinUtil]::PostMessage(
                    $WindowHandle,
                    [WinUtil]::WM_KEYUP,
                    [IntPtr][int][WinUtil]::VK_RETURN,
                    [IntPtr]::Zero
                )
            }
            return $true
        }
    }
    catch {
        Write-AppLog "Send-WeChatMessage 异常：$($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 控制台方向键菜单。
# ---------- 控制台界面通用工具 ----------
# 估算字符串在控制台中的显示列宽：中日韩文字、全角符号、emoji 记 2 列。
function Get-TextDisplayWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $n = [int]$Text[$i]
        if ($n -eq 0xFE0F -or $n -eq 0x200D) { continue }
        if ([char]::IsHighSurrogate($Text[$i])) { $w += 2; $i++; continue }
        $next = if ($i + 1 -lt $Text.Length) { [int]$Text[$i + 1] } else { 0 }
        if (($n -ge 0x1100 -and $n -le 0x115F) -or ($n -ge 0x2E80 -and $n -le 0xA4CF) -or
            ($n -ge 0xAC00 -and $n -le 0xD7A3) -or ($n -ge 0xF900 -and $n -le 0xFAFF) -or
            ($n -ge 0xFE30 -and $n -le 0xFE4F) -or ($n -ge 0xFF00 -and $n -le 0xFF60) -or
            ($n -ge 0xFFE0 -and $n -le 0xFFE6) -or $n -eq 0x2705 -or $n -eq 0x274C -or $n -eq 0x23F3 -or
            ($next -eq 0xFE0F)) { $w += 2 }
        else { $w += 1 }
    }
    return $w
}
# 按显示列宽右侧补空格。
function Format-PadDisplay {
    param([string]$Text, [int]$Width)
    $pad = $Width - (Get-TextDisplayWidth $Text)
    if ($pad -gt 0) { return $Text + (' ' * $pad) }
    return $Text
}
# 带边框的提示块，自动按最长一行对齐右边框。
function Write-Callout {
    param(
        [string[]]$Lines,
        [ConsoleColor]$Color = [ConsoleColor]::Yellow,
        [string]$Title = ""
    )
    if ($script:GuiMode) {
        if ($Title) { Write-Host (" " + $Title) -ForegroundColor $Color }
        foreach ($l in $Lines) { Write-Host ("   " + $l) -ForegroundColor $Color }
        return
    }
    $inner = 0
    foreach ($l in $Lines) { $inner = [Math]::Max($inner, (Get-TextDisplayWidth $l)) }
    if ($Title) { $inner = [Math]::Max($inner, (Get-TextDisplayWidth $Title) + 2) }
    $inner += 2
    if ($Title) {
        $tw = Get-TextDisplayWidth $Title
        Write-Host (" ┌─ " + $Title + " " + ("─" * [Math]::Max(0, $inner - $tw - 3)) + "┐") -ForegroundColor $Color
    }
    else { Write-Host (" ┌" + ("─" * $inner) + "┐") -ForegroundColor $Color }
    foreach ($l in $Lines) { Write-Host (" │ " + (Format-PadDisplay $l ($inner - 2)) + " │") -ForegroundColor $Color }
    Write-Host (" └" + ("─" * $inner) + "┘") -ForegroundColor $Color
}
# 概览行：「标签 │ 值」，标签统一两个汉字宽度以便对齐。
function Write-InfoRow {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::White,
        [string]$Note = ""
    )
    Write-Host ("  " + (Format-PadDisplay $Label 4) + " ") -NoNewline -ForegroundColor Gray
    Write-Host "│ " -NoNewline -ForegroundColor DarkGray
    if ($Note) {
        Write-Host $Value -NoNewline -ForegroundColor $Color
        Write-Host ("  " + $Note) -ForegroundColor DarkGray
    }
    else { Write-Host $Value -ForegroundColor $Color }
}
function Write-SectionTitle {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    $w = 60
    try { $w = [Math]::Min(60, [Math]::Max(20, [Console]::WindowWidth - 4)) } catch {}
    $tw = Get-TextDisplayWidth $Text
    Write-Host ""
    Write-Host ("  " + $Text + " ") -NoNewline -ForegroundColor $Color
    Write-Host ("─" * [Math]::Max(4, $w - $tw - 3)) -ForegroundColor DarkGray
}

function Show-Menu {
    param(
        [string]$Title,
        [array]$Options,
        [int]$DefaultIndex = 0
    )
    function Set-CursorPosSafe($left, $top) {
        $h = $Host.UI.RawUI.BufferSize.Height
        $w = $Host.UI.RawUI.BufferSize.Width
        $safeTop = [Math]::Max(0, [Math]::Min($top, $h - 1))
        $safeLeft = [Math]::Max(0, [Math]::Min($left, $w - 1))
        [Console]::SetCursorPosition($safeLeft, $safeTop)
    }

    # 取缓冲区与窗口宽度较小值，避免超出可见区域。
    function Get-MenuConsoleWidth {
        $bw = $Host.UI.RawUI.BufferSize.Width
        $ww = $Host.UI.RawUI.WindowSize.Width
        $w = if ($ww -gt 0) { [Math]::Min($bw, $ww) } else { $bw }
        return [Math]::Max(4, $w)
    }
    # 高度使用可见窗口尺寸，缓冲区可能远高于屏幕。
    function Get-MenuConsoleHeight {
        $wh = $Host.UI.RawUI.WindowSize.Height
        if ($wh -gt 0) { return $wh }
        return $Host.UI.RawUI.BufferSize.Height
    }

    $selected = [math]::Max(0, [math]::Min($DefaultIndex, $Options.Count - 1))
    $count = $Options.Count
    $menuLines = 1 + $count + 1

    # 使用哈希表共享嵌套菜单函数修改的状态。
    $state = @{
        Width     = (Get-MenuConsoleWidth)
        StartLine = 0
    }

    $windowHeight = Get-MenuConsoleHeight
    if ($windowHeight -lt $menuLines) {
        Write-Host "`n⚠️ 控制台窗口高度不足，无法显示菜单。" -ForegroundColor Red
        Write-Host "   当前高度: $windowHeight 行，需要至少 $menuLines 行。" -ForegroundColor Yellow
        Write-Host "   请调高窗口后按任意键继续，或按 Esc/b 返回。" -ForegroundColor Gray
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 27 -or $key.Character -eq 'b' -or $key.Character -eq 'B') {
            try { [Console]::CursorVisible = $true } catch {}
            return -1
        }
        return Show-Menu @PSBoundParameters
    }

    try { [Console]::CursorVisible = $false } catch {}

    $optionTexts = $Options | ForEach-Object { $_.Trim() }

    # 按字符类别估算显示列宽，减少窄窗口下的文本折行。
    function Get-CharDisplayWidth {
        param([char]$c)
        $n = [int]$c
        if (($n -ge 0x1100 -and $n -le 0x115F) -or
            ($n -ge 0x2E80 -and $n -le 0xA4CF) -or
            ($n -ge 0xAC00 -and $n -le 0xD7A3) -or
            ($n -ge 0xF900 -and $n -le 0xFAFF) -or
            ($n -ge 0xFE30 -and $n -le 0xFE4F) -or
            ($n -ge 0xFF00 -and $n -le 0xFF60) -or
            ($n -ge 0xFFE0 -and $n -le 0xFFE6) -or
            $n -eq 0x2705) { return 2 }
        if ($n -eq 0xFE0F) { return 0 }   # 变体选择符本身不占宽度
        return 1
    }
    function Format-MenuLine {
        param([string]$text)
        $limit = [Math]::Max(0, $state.Width - 3)
        $sb = New-Object System.Text.StringBuilder
        $used = 0
        foreach ($ch in $text.ToCharArray()) {
            $cw = Get-CharDisplayWidth $ch
            if ($used + $cw -gt $limit) { break }
            [void]$sb.Append($ch)
            $used += $cw
        }
        return $sb.ToString()
    }

    function Clear-MenuArea {
        param([int]$startLine, [int]$lineCount)
        $h = $Host.UI.RawUI.BufferSize.Height
        $blank = ' ' * [Math]::Max(0, $state.Width - 2)
        for ($i = 0; $i -lt $lineCount; $i++) {
            $row = $startLine + $i
            if ($row -ge $h) { break }
            Set-CursorPosSafe 0 $row
            [Console]::Write($blank)
        }
    }

    # 单个选项行：选中项为整行高亮条，带序号便于数字键选择。
    function Write-MenuOption {
        param([int]$index, [bool]$isSelected, [int]$row)
        $num = if ($count -le 9) { "$($index + 1). " } else { "" }
        $mark = if ($isSelected) { "> " } else { "  " }
        $text = Format-MenuLine ("  " + $mark + $num + $optionTexts[$index] + " ")
        $used = 0
        foreach ($ch in $text.ToCharArray()) { $used += (Get-CharDisplayWidth $ch) }
        # 行尾补空格，覆盖切换前可能更长的残留文字；总宽不超过 Width-3，不会折行。
        $tail = ' ' * [Math]::Max(0, ($state.Width - 3) - $used)
        Set-CursorPosSafe 0 $row
        if ($isSelected -and $text.Length -gt 2) {
            Write-Host "  " -NoNewline
            Write-Host $text.Substring(2) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
            Write-Host $tail -NoNewline
        }
        else {
            Write-Host ($text + $tail) -ForegroundColor Gray -NoNewline
        }
    }

    # InPlace 在原起始行重绘，否则在当前光标处新建菜单。
    function Draw-Menu {
        param([int]$currentSelected, [switch]$InPlace)

        $state.Width = Get-MenuConsoleWidth

        if ($InPlace) {
            $startLine = $state.StartLine
        }
        else {
            for ($i = 0; $i -lt $menuLines; $i++) {
                Write-Host ""
            }
            $startLine = [Console]::CursorTop - $menuLines
        }
        if ($startLine -lt 0) { $startLine = 0 }
        $maxStart = $Host.UI.RawUI.BufferSize.Height - $menuLines
        if ($startLine -gt $maxStart) { $startLine = [Math]::Max(0, $maxStart) }
        $state.StartLine = $startLine

        Set-CursorPosSafe 0 $startLine
        Write-Host (Format-MenuLine ("  ? " + $Title)) -ForegroundColor Yellow -NoNewline

        for ($i = 0; $i -lt $count; $i++) {
            Write-MenuOption $i ($i -eq $currentSelected) ($startLine + 1 + $i)
        }

        $numHint = if ($count -le 9) { "   [1-$count] 快速选择" } else { "" }
        $hintLine = Format-MenuLine "  [↑/↓] 移动$numHint   [Enter] 确认   [Esc/b] 返回   [R] 重绘"
        Set-CursorPosSafe 0 ($startLine + 1 + $count)
        Write-Host $hintLine -ForegroundColor DarkGray -NoNewline

        Set-CursorPosSafe 0 ($startLine + $menuLines)
    }

    function Redraw-Menu {
        param([int]$currentSelected, [int]$extraClearLines = 0)
        $oldWidth = $state.Width
        $newWidth = Get-MenuConsoleWidth
        # 缩窄窗口可能产生折行，清除额外行以减少残影。
        $factor = [Math]::Max(1, [int][Math]::Ceiling($oldWidth / [double]$newWidth))
        $state.Width = $newWidth
        Clear-MenuArea -startLine $state.StartLine -lineCount ($menuLines * $factor + $extraClearLines)
        Draw-Menu -currentSelected $currentSelected -InPlace
    }

    # 返回前按当前窗口宽度清理折行残影。
    function Clear-MenuOnExit {
        $oldWidth = $state.Width
        $newWidth = Get-MenuConsoleWidth
        $factor = [Math]::Max(1, [int][Math]::Ceiling($oldWidth / [double]$newWidth))
        $state.Width = $newWidth
        Clear-MenuArea -startLine $state.StartLine -lineCount ($menuLines * $factor)
    }

    Draw-Menu -currentSelected $selected

    while ($true) {
        $currentHeight = Get-MenuConsoleHeight
        if ($currentHeight -lt $menuLines) {
            # 窗口高度不足时清除菜单，等待重试或返回。
            $state.Width = Get-MenuConsoleWidth
            Clear-MenuArea -startLine $state.StartLine -lineCount $menuLines
            Set-CursorPosSafe 0 $state.StartLine
            Write-Host "⚠️ 窗口高度不足（当前 $currentHeight < 需要 $menuLines）" -ForegroundColor Red
            Write-Host "   请调高窗口后按 R 重试，或按 Esc/b 返回..." -ForegroundColor Yellow -NoNewline
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

            if ($key.VirtualKeyCode -eq 27 -or $key.Character -eq 'b' -or $key.Character -eq 'B') {
                $state.Width = Get-MenuConsoleWidth
                Clear-MenuArea -startLine $state.StartLine -lineCount ([Math]::Max($menuLines, 2))
                Set-CursorPosSafe 0 $state.StartLine
                try { [Console]::CursorVisible = $true } catch {}
                return -1
            }
            # 非返回按键均触发原地重绘和尺寸复查。
            Redraw-Menu -currentSelected $selected -extraClearLines 2
            continue
        }
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $oldSelected = $selected
        $vk = $key.VirtualKeyCode
        # 数字键 1-9（含小键盘）直接跳到对应选项，Enter 确认。
        if ($count -le 9 -and (($vk -ge 49 -and $vk -le 57) -or ($vk -ge 97 -and $vk -le 105))) {
            $digit = if ($vk -ge 97) { $vk - 96 } else { $vk - 48 }
            if ($digit -le $count) { $vk = 0; $selected = $digit - 1 }
        }
        switch ($vk) {
            38 { $selected = ($selected - 1 + $count) % $count }
            40 { $selected = ($selected + 1) % $count }
            36 { $selected = 0 }
            35 { $selected = $count - 1 }
            82 {
                Redraw-Menu -currentSelected $selected
            }
            13 {
                $state.Width = Get-MenuConsoleWidth
                Clear-MenuArea -startLine ($state.StartLine + 1 + $count) -lineCount 1
                Set-CursorPosSafe 0 ($state.StartLine + 1 + $count)
                $confirmHint = Format-MenuLine ("  ✅ 已选择: " + $optionTexts[$selected])
                Write-Host $confirmHint -ForegroundColor Green -NoNewline
                Set-CursorPosSafe 0 ($state.StartLine + $menuLines)
                Write-Host ""
                try { [Console]::CursorVisible = $true } catch {}
                return $selected
            }
            27 {
                Clear-MenuOnExit
                Set-CursorPosSafe 0 $state.StartLine
                try { [Console]::CursorVisible = $true } catch {}
                return -1
            }
            default {
                if ($key.Character -eq 'b' -or $key.Character -eq 'B') {
                    Clear-MenuOnExit
                    Set-CursorPosSafe 0 $state.StartLine
                    try { [Console]::CursorVisible = $true } catch {}
                    return -1
                }
            }
        }

        if ($selected -ne $oldSelected) {
            Write-MenuOption $oldSelected $false ($state.StartLine + 1 + $oldSelected)
            Write-MenuOption $selected $true ($state.StartLine + 1 + $selected)
            Set-CursorPosSafe 0 ($state.StartLine + $menuLines)
        }
    }
}
# AI 异步请求：复用 HttpClient，轮询任务时刷新状态并检测画面变化。
$script:AIHttpClient = $null
$script:ApiWaitStart = $null
$script:ApiWaitLabel = ""

# 聊天请求设置 AIScreenWatch；轮询时发现未被闪烁规则忽略的变化则取消请求。
$script:AIScreenWatch = $null
$script:AIScreenChanged = $false
# 达到连续取消上限后暂时停用画面监测；画面匹配 Last_Hash 时恢复。
$script:AIAbortStreak = 0
$script:AIAbortMaxStreak = 3

function Test-AbortOnScreenChangeEnabled {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['AbortOnScreenChange']) { return $true }
    return [bool]$CONFIG.AbortOnScreenChange
}

function Test-AIScreenWatchTriggered {
    # 返回是否检测到需要取消请求的画面变化。
    $w = $script:AIScreenWatch
    if (-not $w) { return $false }
    if ($w.Stopwatch.ElapsedMilliseconds -lt $w.NextCheckMs) { return $false }
    $w.NextCheckMs = $w.Stopwatch.ElapsedMilliseconds + $w.IntervalMs

    $h = Get-WindowCropHash -WindowHandle $w.WindowHandle -MarginLeft $w.MarginLeft -MarginTop $w.MarginTop -CropWidth $w.CropWidth -CropHeight $w.CropHeight
    if ([string]::IsNullOrWhiteSpace($h)) { return $false }
    if ($h -eq $w.BaseHash -or $w.TwinHashes.Contains($h)) { return $false }

    # 短时采样回到基准 hash 时，按闪烁规则忽略变化。
    if (Test-BlinkGuardEnabled) {
        $isBlink = Test-CropBlinkBack -WindowHandle $w.WindowHandle -TargetHash $w.BaseHash `
            -MarginLeft $w.MarginLeft -MarginTop $w.MarginTop -CropWidth $w.CropWidth -CropHeight $w.CropHeight
        if ($isBlink) {
            [void]$w.TwinHashes.Add($h)
            Write-AppLog "思考期间画面变化判定为闪烁，已忽略 → Hash=$h" "DEBUG"
            return $false
        }
    }

    $w.ChangedHash = $h
    return $true
}

function Get-AIHttpClient {
    if (-not $script:AIHttpClient) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $script:AIHttpClient = New-Object System.Net.Http.HttpClient($handler)
        # 统一由每次请求的 CancellationTokenSource 控制超时。
        $script:AIHttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    }
    return $script:AIHttpClient
}

function Wait-AITask {
    param(
        [Parameter(Mandatory)] [System.Threading.Tasks.Task]$Task,
        [Parameter(Mandatory)] [System.Threading.CancellationTokenSource]$Cts,
        [int]$TimeoutSeconds = 60
    )

    while (-not $Task.IsCompleted) {
        if ($Cts.IsCancellationRequested) { throw "请求超时（已等待 ${TimeoutSeconds}s 未返回）" }
        Start-Sleep -Milliseconds 100
        Update-Spinner
        # 画面变化导致的取消，由调用方重新截图处理。
        if ($script:AIScreenWatch -and (Test-AIScreenWatchTriggered)) {
            $script:AIScreenChanged = $true
            try { $Cts.Cancel() } catch {}
            throw "思考期间画面发生变化，已中止本次请求"
        }
    }

    if ($Task.IsCanceled -or ($Task.IsFaulted -and $Cts.IsCancellationRequested)) {
        throw "请求超时（已等待 ${TimeoutSeconds}s 未返回）"
    }
    if ($Task.IsFaulted) {
        $inner = $Task.Exception.InnerException
        $msg = $inner.Message
        $root = $inner.GetBaseException()
        if ($root -and $root -ne $inner -and $root.Message -ne $msg) { $msg += " → $($root.Message)" }
        throw $msg
    }

    # 逗号防止 byte[] 结果被 PowerShell 管道展开成 object[]
    return , $Task.Result
}

# 统一模型请求：认证、消息格式、超时、响应正文和用量记录。
function Invoke-AICompletion {
    param(
        [Parameter(Mandatory)]
        [string]$ProviderType,
        [Parameter(Mandatory)]
        [string]$ApiUrl,
        [Parameter(Mandatory)]
        [string]$ApiKey,
        [Parameter(Mandatory)]
        [string]$Model,
        [Parameter(Mandatory)]
        [array]$Messages,
        [Parameter(Mandatory)]
        [int]$MaxTokens,
        [int]$TimeoutSeconds = 60,
        [string]$SystemPrompt = "",
        [bool]$DeepThinking = $false,
        [ValidateSet("Chat", "Summary", "Proactive")]
        [string]$UsagePurpose = "Chat",
        [bool]$UsageIsRetry = $false
    )

    # 根据接口地址选择供应商对应的推理参数分支。
    $vendor = ""
    if ($ApiUrl -match 'api\.deepseek\.com') { $vendor = "DeepSeek" }
    elseif ($ApiUrl -match 'api\.openai\.com') { $vendor = "OpenAI" }
    elseif ($ApiUrl -match 'generativelanguage\.googleapis\.com') { $vendor = "Gemini" }

    $headers = @{
        "Content-Type" = "application/json"
    }

    if ($ProviderType -eq "Anthropic") {
        $headers["x-api-key"] = $ApiKey
        $headers["anthropic-version"] = "2023-06-01"
    }
    elseif ($ProviderType -eq "OpenAI" -and $ApiKey -ne "ollama") {
        $headers["Authorization"] = "Bearer $ApiKey"
    }
    elseif ($ProviderType -eq "Ali") {
        $headers["Authorization"] = "Bearer $ApiKey"
    }

    $body = $null
    switch ($ProviderType) {
        "Anthropic" {
            $content = @()
            foreach ($msg in $Messages) {
                if ($msg -is [string]) {
                    $content += @{ type = "text"; text = $msg }
                }
                elseif ($msg.Type -eq "image") {
                    $content += @{
                        type   = "image"
                        source = @{
                            type       = "base64"
                            media_type = "image/png"
                            data       = $msg.Data
                        }
                    }
                }
            }
            $body = @{
                model      = $Model
                max_tokens = $MaxTokens
                messages   = @(
                    @{ role = "user"; content = $content }
                )
            }
            if ($SystemPrompt) {
                $body["system"] = $SystemPrompt
            }
            $body = $body | ConvertTo-Json -Depth 10
        }
        "Ali" {
            $content = @()
            foreach ($msg in $Messages) {
                if ($msg -is [string]) {
                    $content += @{ text = $msg }
                }
                elseif ($msg.Type -eq "image") {
                    $content += @{ image = "data:image/png;base64,$($msg.Data)" }
                }
            }
            $messagesArray = @()
            if ($SystemPrompt) {
                $messagesArray += @{ role = "system"; content = $SystemPrompt }
            }
            $messagesArray += @{ role = "user"; content = $content }
            $body = @{
                model      = $Model
                input      = @{
                    messages = $messagesArray
                }
                parameters = @{
                    max_tokens      = $MaxTokens
                    enable_thinking = $DeepThinking
                }
            } | ConvertTo-Json -Depth 10
        }
        default {
            $content = @()
            foreach ($msg in $Messages) {
                if ($msg -is [string]) {
                    $content += @{ type = "text"; text = $msg }
                }
                elseif ($msg.Type -eq "image") {
                    $content += @{
                        type      = "image_url"
                        image_url = @{ url = "data:image/png;base64,$($msg.Data)" }
                    }
                }
            }
            $messagesArray = @()
            if ($SystemPrompt) {
                $messagesArray += @{ role = "system"; content = $SystemPrompt }
            }
            $messagesArray += @{ role = "user"; content = $content }
            $body = @{
                model    = $Model
                messages = $messagesArray
            }
            switch ($vendor) {
                "DeepSeek" {
                    $body["max_tokens"] = $MaxTokens
                    $body["thinking"] = @{ type = $(if ($DeepThinking) { "enabled" } else { "disabled" }) }
                }
                "OpenAI" {
                    # 此分支使用 max_completion_tokens，并按 DeepThinking 设置 reasoning_effort。
                    $body["max_completion_tokens"] = $(if ($DeepThinking) { [Math]::Max($MaxTokens, 4096) } else { $MaxTokens })
                    $body["reasoning_effort"] = $(if ($DeepThinking) { "high" } else { "low" })
                }
                "Gemini" {
                    $body["max_tokens"] = $(if ($DeepThinking) { [Math]::Max($MaxTokens, 4096) } else { $MaxTokens })
                    $body["reasoning_effort"] = $(if ($DeepThinking) { "high" } else { "low" })
                }
                default {
                    $body["max_tokens"] = $MaxTokens
                }
            }
            $body = $body | ConvertTo-Json -Depth 10
        }
    }
    $imgCount = ($Messages | Where-Object { $_ -isnot [string] -and $_.Type -eq "image" }).Count
    $textPartsCount = ($Messages | Where-Object { $_ -is [string] }).Count
    Write-AppLog "API 请求开始 → Provider=$ProviderType, Model=$Model, TextParts=$textPartsCount, Images=$imgCount, Timeout=${TimeoutSeconds}s" "DEBUG"
    $requestStartTime = [DateTime]::Now
    $script:AIScreenChanged = $false
    $script:LastUsage = $null   # 请求前清空用量，避免失败时沿用上次结果。
    $script:LastApiStatusCode = 0   # 供 Get-AIErrorKind 按状态码分类错误。
    $cts = $null
    $request = $null
    $response = $null
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

        # 异步等待期间刷新状态行；取消令牌覆盖请求和响应体缓冲。
        $script:ApiWaitStart = $requestStartTime
        $script:ApiWaitLabel = if ($UsagePurpose -eq "Summary") { "整理记忆" } elseif ($UsagePurpose -eq "Proactive") { "构思主动消息" } else { "等待 AI" }

        $client = Get-AIHttpClient
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))

        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $ApiUrl)
        foreach ($k in $headers.Keys) {
            if ($k -eq "Content-Type") { continue }   # Content-Type 属于内容头，在下面单独设置
            [void]$request.Headers.TryAddWithoutValidation($k, [string]$headers[$k])
        }
        $request.Content = [System.Net.Http.ByteArrayContent]::new($bodyBytes)
        $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json; charset=utf-8")

        $sendTask = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $cts.Token)
        $response = Wait-AITask -Task $sendTask -Cts $cts -TimeoutSeconds $TimeoutSeconds

        $readTask = $response.Content.ReadAsByteArrayAsync()
        $rawBytes = Wait-AITask -Task $readTask -Cts $cts -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $rawBytes) { throw "API 返回了空响应流" }

        $responseText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
        $statusCode = [int]$response.StatusCode
        $script:LastApiStatusCode = $statusCode

        if (-not $response.IsSuccessStatusCode) {
            # 保留状态码和错误片段，供上层判断是否可重试。
            $errSnippet = $responseText.Substring(0, [math]::Min(300, $responseText.Length))
            throw "远程服务器返回错误: ($statusCode) $($response.ReasonPhrase)。$errSnippet"
        }

        $elapsedMs = [int]([DateTime]::Now - $requestStartTime).TotalMilliseconds
        Write-AppLog "API 响应成功 ← Status=$statusCode, Bytes=$($rawBytes.Length), Elapsed=${elapsedMs}ms, Model=$Model" "INFO"
        $json = $null
        try { 
            # 去除首尾空白后解析完整 JSON 响应。
            $cleanText = $responseText.Trim()
            $json = $cleanText | ConvertFrom-Json -ErrorAction Stop 
        }
        catch {
            Write-AppLog "API 响应 JSON 解析失败：$($responseText.Substring(0, [math]::Min(300, $responseText.Length)))" "ERROR"
            throw "无法解析 API 返回的 JSON: $responseText" 
        }
    }
    catch {
        $elapsedMs = [int]([DateTime]::Now - $requestStartTime).TotalMilliseconds
        if ($script:AIScreenChanged) {
            # 画面变化导致的主动取消不计入普通请求失败。
            Write-AppLog "API 请求已中止（思考期间画面变化）← Model=$Model, Elapsed=${elapsedMs}ms" "INFO"
            throw
        }
        Write-AppLog "API 请求失败 ← Provider=$ProviderType, Model=$Model, Elapsed=${elapsedMs}ms, Error=$($_.Exception.Message)" "ERROR"
        throw "API 请求失败: $_"
    }
    finally {
        # 释放请求资源并清除状态行计时。
        $script:ApiWaitStart = $null
        if ($cts) {
            try { $cts.Cancel() } catch {}
            $cts.Dispose()
        }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
    }

    # 正文为空也可能产生用量，先记录统计再提取正文。
    try {
        $script:LastUsage = Get-TokenUsageFromResponse -Json $json -ProviderType $ProviderType
        Add-TokenUsageRecord -Usage $script:LastUsage -Purpose $UsagePurpose -Model $Model -IsRetry $UsageIsRetry
    }
    catch {
        Write-AppLog "解析 token 用量失败（已忽略）：$($_.Exception.Message)" "DEBUG"
        $script:LastUsage = $null
    }

    return (Get-AIResponseText -Json $json -ProviderType $ProviderType)
}

# 截图与校准：向导通过帧差估算光标位置；运行时用 hash 回跳规则过滤闪烁。
# 这些规则是视觉启发式判断，不验证消息来源。
function Get-CaretBlinkMs {
    # 返回系统光标闪烁间隔（ms）；-1 表示系统关闭了闪烁
    try {
        if (-not ([System.Management.Automation.PSTypeName]'BlinkUtil').Type) { return 530 }
        $t = [BlinkUtil]::GetCaretBlinkTime()
        if ($t -eq [uint32]::MaxValue) { return -1 }
        if ($t -eq 0) { return 530 }
        return [int]$t
    }
    catch { return 530 }
}

function Test-BlinkGuardEnabled {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableBlinkGuard']) { return $true }
    return [bool]$CONFIG.EnableBlinkGuard
}

function Get-WindowFrameBytes {
    # 整窗截图并取出 32bpp BGRA 像素，坐标系与裁切边距一致（GetWindowRect + PrintWindow）
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)

    $rect = New-Object WinUtil+RECT
    if (-not [WinUtil]::GetWindowRect($WindowHandle, [ref]$rect)) { return $null }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { return $null }

    $bmp = $null; $g = $null; $hdc = [IntPtr]::Zero; $data = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $hdc = $g.GetHdc()
            if (-not [WinUtil]::PrintWindow($WindowHandle, $hdc, 2)) { throw "窗口截图失败，已跳过本次处理" }
        }
        finally {
            if ($hdc -ne [IntPtr]::Zero) { $g.ReleaseHdc($hdc); $hdc = [IntPtr]::Zero }
        }
        $g.Dispose(); $g = $null

        $data = $bmp.LockBits(
            (New-Object System.Drawing.Rectangle(0, 0, $w, $h)),
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $len = $data.Stride * $h
        $bytes = New-Object byte[] $len
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $len)

        return [PSCustomObject]@{ Width = $w; Height = $h; Stride = $data.Stride; Bytes = $bytes }
    }
    finally {
        if ($data -and $bmp) { $bmp.UnlockBits($data) }
        if ($g) { $g.Dispose() }
        if ($bmp) { $bmp.Dispose() }
    }
}

function Find-CaretInWindow {
    <#
        临时切到前台并尝试聚焦输入框，通过多帧变化估算光标及其他动态区域。
        返回 Ok / Reason / BlinkMs / Width / Height / Caret / Dynamic，结束后恢复 RestoreHandle。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [IntPtr]$RestoreHandle = [IntPtr]::Zero,
        [int]$ClickX = -1,
        [int]$ClickY = -1
    )

    $res = [PSCustomObject]@{ Ok = $false; Reason = ""; BlinkMs = 0; Width = 0; Height = 0; Caret = $null; Dynamic = @() }

    if (-not ([System.Management.Automation.PSTypeName]'BlinkUtil').Type) {
        $res.Reason = "闪烁检测组件未加载"
        return $res
    }
    $blink = Get-CaretBlinkMs
    $res.BlinkMs = $blink
    if ($blink -le 0) {
        $res.Reason = "系统已关闭光标闪烁，无法通过闪烁定位光标"
        return $res
    }
    if ([WinUtil]::IsIconic($WindowHandle)) {
        $res.Reason = "微信已最小化"
        return $res
    }

    $frames = New-Object 'System.Collections.Generic.List[byte[]]'
    $w = 0; $h = 0; $stride = 0
    try {
        [void][WinUtil]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 250
        if ([WinUtil]::GetForegroundWindow() -ne $WindowHandle) {
            $res.Reason = "无法把微信切到前台（光标只在微信有焦点时才闪烁）"
            return $res
        }

        try { [void](Invoke-FocusInputBox -WindowHandle $WindowHandle -WindowX $ClickX -WindowY $ClickY) } catch {}
        # 先等待焦点高亮等一次性变化结束。
        Start-Sleep -Milliseconds 400

        # 按半个闪烁周期采样 7 帧，间隔至少 80ms。
        $interval = [int][Math]::Max(80, $blink / 2)
        $frameCount = 7
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $frameCount; $i++) {
            $wait = ($i * $interval) - $sw.ElapsedMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }

            $fr = Get-WindowFrameBytes -WindowHandle $WindowHandle
            if (-not $fr) {
                $res.Reason = "截图失败"
                return $res
            }
            if ($i -eq 0) {
                $w = $fr.Width; $h = $fr.Height; $stride = $fr.Stride
            }
            elseif ($fr.Width -ne $w -or $fr.Height -ne $h) {
                $res.Reason = "检测过程中微信窗口尺寸发生变化，请重试"
                return $res
            }
            $frames.Add($fr.Bytes)
        }
    }
    finally {
        if ($RestoreHandle -ne [IntPtr]::Zero) {
            [void][WinUtil]::SetForegroundWindow($RestoreHandle)
        }
    }

    $regions = [BlinkUtil]::FindChangedRegions($frames, $w, $h, $stride, 60)
    $frames.Clear()

    $res.Width = $w
    $res.Height = $h

    # 候选光标需呈细长竖条且至少变化两次；忽略单次高亮变化。
    $all = New-Object System.Collections.Generic.List[object]
    $best = $null
    foreach ($r in $regions) {
        $item = [PSCustomObject]@{ X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3]; Pixels = $r[4]; Toggles = $r[5] }
        if ($item.Toggles -lt 2) { continue }
        $all.Add($item)

        $isCaretLike = ($item.W -le 6 -and $item.H -ge 8 -and $item.H -le 80 -and $item.H -ge (3 * $item.W))
        if ($isCaretLike) {
            if (-not $best -or $item.Toggles -gt $best.Toggles -or ($item.Toggles -eq $best.Toggles -and $item.H -gt $best.H)) {
                $best = $item
            }
        }
    }

    $res.Caret = $best
    $res.Dynamic = @($all | Where-Object { $_ -ne $best } | Select-Object -First 200)
    $res.Ok = $true
    if (-not $best) { $res.Reason = "未发现闪烁的光标（微信输入框可能没有焦点）" }

    Write-AppLog ("光标检测 → Blink={0}ms 窗口={1}x{2} 光标={3} 其他动态区域={4}" -f `
            $blink, $w, $h, $(if ($best) { "($($best.X),$($best.Y),$($best.W)x$($best.H),翻转$($best.Toggles))" } else { "无" }), $res.Dynamic.Count) "DEBUG"
    return $res
}

function Get-WindowCrop {
    # 整窗截图 → 按边距裁切 → PNG 编码 → SHA256。主循环、发送校验和各类 hash 比较共用此流程，保证 hash 可比。
    # 返回 @{ Hash; Bytes(PNG) }；失败时抛出异常。
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )
    $tempBmp = $null; $tempG = $null; $bitmap = $null; $g = $null; $ms = $null; $sha = $null; $hdc = [IntPtr]::Zero
    try {
        $rect = New-Object WinUtil+RECT
        if (-not [WinUtil]::GetWindowRect($WindowHandle, [ref]$rect)) { throw "无法获取微信窗口尺寸" }
        $tempBmp = New-Object System.Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $tempG = [System.Drawing.Graphics]::FromImage($tempBmp)
        try {
            $hdc = $tempG.GetHdc()
            if (-not [WinUtil]::PrintWindow($WindowHandle, $hdc, 2)) { throw "窗口截图失败，已跳过本次处理" }
        }
        finally {
            if ($hdc -ne [IntPtr]::Zero) { $tempG.ReleaseHdc($hdc); $hdc = [IntPtr]::Zero }
        }

        $bitmap = New-Object System.Drawing.Bitmap($CropWidth, $CropHeight)
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        $g.DrawImage($tempBmp, 0, 0,
            (New-Object System.Drawing.Rectangle($MarginLeft, $MarginTop, $CropWidth, $CropHeight)),
            [System.Drawing.GraphicsUnit]::Pixel)

        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return [PSCustomObject]@{
            Hash  = [System.BitConverter]::ToString($sha.ComputeHash($bytes))
            Bytes = $bytes
        }
    }
    finally {
        if ($sha) { $sha.Dispose() }
        if ($ms) { $ms.Dispose() }
        if ($g) { $g.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($tempG) { $tempG.Dispose() }
        if ($tempBmp) { $tempBmp.Dispose() }
    }
}

function Get-WindowCropHash {
    # 只要 hash 的场景；截图失败返回空字符串。
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )
    try {
        return (Get-WindowCrop -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight).Hash
    }
    catch {
        return ""
    }
}

function Test-CropBlinkBack {
    <#
        在 400–1500ms 的采样窗口内出现 TargetHash 时，按闪烁回跳返回 true。
        只验证画面回到已知 hash，不判断变化是否来自真实消息。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$TargetHash,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )
    $blink = Get-CaretBlinkMs
    if ($blink -le 0) { return $false }   # 系统未启用光标闪烁时跳过检测。

    $windowMs = [int][Math]::Min(1500, [Math]::Max(400, $blink * 1.3))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $windowMs) {
        Start-SpinnerSleep -Milliseconds 90
        $h = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
        if ($h -and $h -eq $TargetHash) { return $true }
    }
    return $false
}

function Show-MarginSliderForm {
    <#
        拖动边线设置裁切边距，拖动十字设置点击点，并检查光标与动态区域是否重叠。
        坐标使用整窗截图坐标；实际发送时换算为客户区坐标。
        可变状态放入 $st，供事件脚本块共享；Syncing 标记防止数值框递归同步。
        Enter 提交数值或确认，Esc 返回上一步。
    #>
    param(
        [Parameter(Mandatory)]
        [IntPtr]$WindowHandle,
        [Parameter(Mandatory)]
        [hashtable]$InitialMargins,
        [hashtable]$InitialFocusClick = $null
    )

    $rect = New-Object WinUtil+RECT
    if (-not [WinUtil]::GetWindowRect($WindowHandle, [ref]$rect)) {
        Write-Host "❌ 无法获取微信窗口尺寸，请重试。" -ForegroundColor Red
        return @{ Confirmed = $false }
    }

    $defaultMargins = @{ Left = 360; Right = 30; Top = 85; Bottom = 165 }
    $defaultFocus = @{ Enabled = $false; RatioX = 0.65; OffsetFromBottom = 50 }
    $marginNames = @("Left", "Right", "Top", "Bottom")
    $minCrop = 20   # 裁切区域最小宽/高

    $fc = @{ Enabled = $defaultFocus.Enabled; RatioX = $defaultFocus.RatioX; OffsetFromBottom = $defaultFocus.OffsetFromBottom }
    if ($InitialFocusClick) {
        if ($null -ne $InitialFocusClick.Enabled) { $fc.Enabled = [bool]$InitialFocusClick.Enabled }
        try { $rx = [double]$InitialFocusClick.RatioX; if ($rx -gt 0 -and $rx -lt 1) { $fc.RatioX = $rx } } catch {}
        try { $ob = [int]$InitialFocusClick.OffsetFromBottom; if ($ob -ge 0) { $fc.OffsetFromBottom = $ob } } catch {}
    }

    $st = @{
        Image        = $null
        Width        = $rect.Right - $rect.Left
        Height       = $rect.Bottom - $rect.Top
        Margins      = @{
            Left   = [math]::Max(0, [int]$InitialMargins.Left)
            Right  = [math]::Max(0, [int]$InitialMargins.Right)
            Top    = [math]::Max(0, [int]$InitialMargins.Top)
            Bottom = [math]::Max(0, [int]$InitialMargins.Bottom)
        }
        ClickX       = 0
        ClickY       = 0
        FocusEnabled = $fc.Enabled
        Drag         = "None"      # None | EdgeLeft | EdgeRight | EdgeTop | EdgeBottom | Click
        Syncing      = $false      # 程序内部回写数值框时置位，避免 ValueChanged 互相触发
        Caret        = $null       # Find-CaretInWindow 的结果
        Running      = $false
    }
    $st.ClickX = [int]($st.Width * $fc.RatioX)
    $st.ClickY = $st.Height - $fc.OffsetFromBottom

    function Capture-FullWindow {
        $tempFull = $null; $gFull = $null; $hdc = [IntPtr]::Zero
        try {
            $tempFull = New-Object System.Drawing.Bitmap($st.Width, $st.Height)
            $gFull = [System.Drawing.Graphics]::FromImage($tempFull)
            try {
                $hdc = $gFull.GetHdc()
                if (-not [WinUtil]::PrintWindow($WindowHandle, $hdc, 2)) { throw "窗口截图失败，已跳过本次处理" }
            }
            finally {
                if ($hdc -ne [IntPtr]::Zero) { $gFull.ReleaseHdc($hdc) }
            }
            return $tempFull.Clone()
        }
        finally {
            if ($gFull) { $gFull.Dispose() }
            if ($tempFull) { $tempFull.Dispose() }
        }
    }

    function Limit-Int([double]$v, [double]$lo, [double]$hi) {
        if ($hi -lt $lo) { $hi = $lo }
        return [int][math]::Max($lo, [math]::Min($hi, $v))
    }

    # 把边距和点击点夹到当前窗口尺寸的合法范围内
    function Repair-State {
        $m = $st.Margins
        $m.Left = Limit-Int $m.Left 0 ($st.Width - $minCrop)
        $m.Right = Limit-Int $m.Right 0 ($st.Width - $m.Left - $minCrop)
        $m.Top = Limit-Int $m.Top 0 ($st.Height - $minCrop)
        $m.Bottom = Limit-Int $m.Bottom 0 ($st.Height - $m.Top - $minCrop)
        $st.ClickX = Limit-Int $st.ClickX 0 ($st.Width - 1)
        $st.ClickY = Limit-Int $st.ClickY 0 ($st.Height - 1)
    }

    function Set-NudSafe($nud, [int]$v) {
        $d = [decimal]$v
        if ($d -lt $nud.Minimum) { $d = $nud.Minimum }
        if ($d -gt $nud.Maximum) { $d = $nud.Maximum }
        if ($nud.Value -ne $d) { $nud.Value = $d }
    }

    # 状态 → 数值框（不触发反向同步）
    function Sync-Inputs {
        $st.Syncing = $true
        try {
            $marginNuds["Left"].Maximum = [math]::Max(0, $st.Width - $minCrop)
            $marginNuds["Right"].Maximum = [math]::Max(0, $st.Width - $minCrop)
            $marginNuds["Top"].Maximum = [math]::Max(0, $st.Height - $minCrop)
            $marginNuds["Bottom"].Maximum = [math]::Max(0, $st.Height - $minCrop)
            $nudClickX.Maximum = [math]::Max(0, $st.Width - 1)
            $nudClickY.Maximum = [math]::Max(0, $st.Height - 1)
            foreach ($n in $marginNames) { Set-NudSafe $marginNuds[$n] $st.Margins[$n] }
            Set-NudSafe $nudClickX $st.ClickX
            Set-NudSafe $nudClickY $st.ClickY
            $chkEnable.Checked = [bool]$st.FocusEnabled
        }
        finally { $st.Syncing = $false }
    }

    # 图片在 PictureBox 里的实际显示区域（等比缩放、居中）
    function Get-DispRect {
        if ($null -eq $st.Image) { return $null }
        $bw = $pictureBox.ClientSize.Width
        $bh = $pictureBox.ClientSize.Height
        if ($bw -le 0 -or $bh -le 0 -or $st.Width -le 0 -or $st.Height -le 0) { return $null }
        $scale = [math]::Min($bw / $st.Width, $bh / $st.Height)
        $dw = [int]($st.Width * $scale)
        $dh = [int]($st.Height * $scale)
        return @{ X = [int](($bw - $dw) / 2); Y = [int](($bh - $dh) / 2); W = $dw; H = $dh; S = $scale }
    }

    function Test-RectOverlap {
        param($R, [int]$CropL, [int]$CropT, [int]$CropR, [int]$CropB)
        return ($R.X -lt $CropR -and ($R.X + $R.W) -gt $CropL -and $R.Y -lt $CropB -and ($R.Y + $R.H) -gt $CropT)
    }

    # 光标 / 动态区域 / 点击点 与裁切框的关系
    function Get-CheckInfo {
        $info = @{ CaretStatus = "None"; CaretInside = $false; DynamicInside = 0; ClickInMask = $true }
        $cropL = $st.Margins.Left
        $cropT = $st.Margins.Top
        $cropR = $st.Width - $st.Margins.Right
        $cropB = $st.Height - $st.Margins.Bottom
        # 点击点应在聊天截图区域之外，降低误点图片或链接的风险。
        $info.ClickInMask = -not ($st.ClickX -ge $cropL -and $st.ClickX -lt $cropR -and $st.ClickY -ge $cropT -and $st.ClickY -lt $cropB)

        $r = $st.Caret
        if (-not $r) { return $info }
        if (-not $r.Ok) { $info.CaretStatus = "Failed"; return $info }
        if ($r.Width -ne $st.Width -or $r.Height -ne $st.Height) { $info.CaretStatus = "Stale"; return $info }
        if ($r.Caret) {
            $info.CaretInside = Test-RectOverlap -R $r.Caret -CropL $cropL -CropT $cropT -CropR $cropR -CropB $cropB
        }
        foreach ($d in $r.Dynamic) {
            if (Test-RectOverlap -R $d -CropL $cropL -CropT $cropT -CropR $cropR -CropB $cropB) { $info.DynamicInside++ }
        }
        $info.CaretStatus = if ($r.Caret) { "Found" } else { "NoCaret" }
        return $info
    }

    function Update-StatusLabels {
        if ($st.Running) { return }
        $info = Get-CheckInfo
        $r = $st.Caret

        switch ($info.CaretStatus) {
            "None" {
                Set-Tone $lblCaret "Neutral"
                $lblCaret.Text = "尚未检测。`n点【检测光标】会把微信短暂切到前台约 2 秒。"
            }
            "Failed" {
                Set-Tone $lblCaret "Warn"
                $lblCaret.Text = "⚠️ 光标检测失败：$($r.Reason)`n请人工确认下边距已遮住输入框。"
            }
            "Stale" {
                Set-Tone $lblCaret "Warn"
                $lblCaret.Text = "⚠️ 微信窗口尺寸已变化，检测结果作废，请重新检测。"
            }
            default {
                $lines = @()
                $tone = "Success"
                if ($info.CaretStatus -eq "NoCaret") {
                    $lines += "⚠️ $($r.Reason)"
                    $lines += "可先把红十字拖到输入框上再重新检测。"
                    $tone = "Warn"
                }
                elseif ($info.CaretInside) {
                    $lines += "❌ 光标（青色框）在截图区域内！"
                    $lines += "会导致画面不停变化、重复回答。"
                    $lines += "可点【避开光标】自动调大下边距。"
                    $tone = "Error"
                }
                else {
                    $lines += "✅ 光标（青色框）已在截图区域外。"
                }
                if ($info.DynamicInside -gt 0) {
                    $lines += "⚠️ 区域内还有 $($info.DynamicInside) 处持续变化的内容（橙色框），如动图表情，同样可能导致重复请求。"
                    if ($tone -eq "Success") { $tone = "Warn" }
                }
                Set-Tone $lblCaret $tone
                $lblCaret.Text = ($lines -join "`n")
            }
        }

        if (-not $st.FocusEnabled) {
            Set-Tone $lblClick "Neutral"
            $lblClick.Text = "ℹ️ 对焦点击已关闭（灰十字只用于检测光标），启动后需要你手动点一次输入框。"
        }
        elseif ($info.ClickInMask) {
            Set-Tone $lblClick "Success"
            $lblClick.Text = "✅ 点击点在截图区域外（遮罩内），请确认它落在输入框上。"
        }
        else {
            Set-Tone $lblClick "Warn"
            $lblClick.Text = "⚠️ 点击点落在聊天区内，可能点开图片/链接。应拖到下方输入框上。"
        }

        $cw = $st.Width - $st.Margins.Left - $st.Margins.Right
        $ch = $st.Height - $st.Margins.Top - $st.Margins.Bottom
        if ($ch -lt 100 -or $cw -lt 100) {
            Set-Tone $lblCropSize "Warn"
            $lblCropSize.Text = "发给 AI 的区域：$cw × $ch px（偏小，可能看不全聊天内容）"
        }
        else {
            Set-Tone $lblCropSize "Info"
            $lblCropSize.Text = "发给 AI 的区域：$cw × $ch px"
        }
    }

    function Refresh-View {
        Update-StatusLabels
        Update-CoordBar
        $pictureBox.Invalidate()
    }

    # 重新截图；窗口尺寸变化时修正边距和点击点。
    function Update-Capture {
        $rc = New-Object WinUtil+RECT
        if ([WinUtil]::GetWindowRect($WindowHandle, [ref]$rc)) {
            $w = $rc.Right - $rc.Left
            $h = $rc.Bottom - $rc.Top
            if ($w -gt 0 -and $h -gt 0 -and ($w -ne $st.Width -or $h -ne $st.Height)) {
                # 按横向比例及距底像素调整点击点。
                $ratio = if ($st.Width -gt 0) { $st.ClickX / $st.Width } else { $defaultFocus.RatioX }
                $offBot = $st.Height - $st.ClickY
                $st.Width = $w
                $st.Height = $h
                $st.ClickX = [int]($w * $ratio)
                $st.ClickY = $h - $offBot
            }
        }
        $old = $st.Image
        try { $st.Image = Capture-FullWindow }
        catch { Write-AppLog "预览截图失败：$($_.Exception.Message)" "WARN" }
        if ($old -and -not [object]::ReferenceEquals($old, $st.Image)) { $old.Dispose() }
        Repair-State
        Sync-Inputs
        Refresh-View
    }

    # 命中测试：红十字优先，其次四条边线
    function Get-HitTarget([int]$dx, [int]$dy) {
        $d = Get-DispRect
        if ($null -eq $d) { return "None" }
        $cx = $st.ClickX * $d.S + $d.X
        $cy = $st.ClickY * $d.S + $d.Y
        $hitR = Px 12
        if ([math]::Abs($cx - $dx) -le $hitR -and [math]::Abs($cy - $dy) -le $hitR) { return "Click" }
        $L = $st.Margins.Left * $d.S + $d.X
        $R = ($st.Width - $st.Margins.Right) * $d.S + $d.X
        $T = $st.Margins.Top * $d.S + $d.Y
        $B = ($st.Height - $st.Margins.Bottom) * $d.S + $d.Y
        $tol = Px 6
        if ([math]::Abs($dx - $L) -le $tol -and $dy -ge $T - $tol -and $dy -le $B + $tol) { return "EdgeLeft" }
        if ([math]::Abs($dx - $R) -le $tol -and $dy -ge $T - $tol -and $dy -le $B + $tol) { return "EdgeRight" }
        if ([math]::Abs($dy - $T) -le $tol -and $dx -ge $L - $tol -and $dx -le $R + $tol) { return "EdgeTop" }
        if ([math]::Abs($dy - $B) -le $tol -and $dx -ge $L - $tol -and $dx -le $R + $tol) { return "EdgeBottom" }
        return "None"
    }

    # ---------- 窗体外观 ----------
    # 进程已 SetProcessDPIAware，控件尺寸需按 DPI 手动放大，否则高分屏下文字被截断。
    $k = 1.0
    try {
        $gDpi = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $k = [math]::Max(1.0, $gDpi.DpiX / 96.0)
        $gDpi.Dispose()
    }
    catch {}
    function Px([double]$v) { return [int][math]::Round($v * $k) }

    $theme = @{
        FormBg    = [System.Drawing.Color]::FromArgb(245, 246, 248)
        CardBg    = [System.Drawing.Color]::White
        Border    = [System.Drawing.Color]::FromArgb(227, 230, 234)
        Text      = [System.Drawing.Color]::FromArgb(31, 35, 40)
        SubText   = [System.Drawing.Color]::FromArgb(101, 109, 118)
        Accent    = [System.Drawing.Color]::FromArgb(7, 193, 96)
        AccentHot = [System.Drawing.Color]::FromArgb(6, 173, 86)
        AccentDn  = [System.Drawing.Color]::FromArgb(5, 150, 75)
        BtnBorder = [System.Drawing.Color]::FromArgb(208, 215, 222)
        BtnHot    = [System.Drawing.Color]::FromArgb(243, 244, 246)
        BtnDn     = [System.Drawing.Color]::FromArgb(229, 231, 235)
        PreviewBg = [System.Drawing.Color]::FromArgb(30, 31, 34)
        StatusBg  = [System.Drawing.Color]::FromArgb(43, 45, 49)
        StatusFg  = [System.Drawing.Color]::FromArgb(201, 205, 212)
    }
    # 状态提示配色：前景 / 背景
    $tones = @{
        Success = @([System.Drawing.Color]::FromArgb(56, 158, 13), [System.Drawing.Color]::FromArgb(246, 255, 237))
        Warn    = @([System.Drawing.Color]::FromArgb(212, 107, 8), [System.Drawing.Color]::FromArgb(255, 247, 230))
        Error   = @([System.Drawing.Color]::FromArgb(207, 19, 34), [System.Drawing.Color]::FromArgb(255, 241, 240))
        Info    = @([System.Drawing.Color]::FromArgb(22, 119, 255), [System.Drawing.Color]::FromArgb(230, 244, 255))
        Neutral = @([System.Drawing.Color]::FromArgb(101, 109, 118), [System.Drawing.Color]::FromArgb(245, 246, 248))
    }
    function Set-Tone($lbl, [string]$tone) {
        $t = $tones[$tone]
        if (-not $t) { $t = $tones.Neutral }
        $lbl.ForeColor = $t[0]
        $lbl.BackColor = $t[1]
    }

    $fontName = "Microsoft YaHei UI"
    if (-not ([System.Drawing.FontFamily]::Families | Where-Object { $_.Name -eq $fontName })) { $fontName = "Microsoft YaHei" }
    $uiFont = New-Object System.Drawing.Font($fontName, 9)
    $boldFont = New-Object System.Drawing.Font($fontName, 9, [System.Drawing.FontStyle]::Bold)
    $titleFont = New-Object System.Drawing.Font($fontName, 13, [System.Drawing.FontStyle]::Bold)
    $cardTitleFont = New-Object System.Drawing.Font($fontName, 10, [System.Drawing.FontStyle]::Bold)
    $tagFont = New-Object System.Drawing.Font($fontName, 8.5, [System.Drawing.FontStyle]::Bold)
    $btnFont = New-Object System.Drawing.Font($fontName, 9.5)

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.InitialDelay = 400
    $toolTip.AutoPopDelay = 12000

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "截图区域 & 输入框点击位置校准"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MaximizeBox = $true
    $form.MinimizeBox = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size([math]::Min((Px 1240), $wa.Width), [math]::Min((Px 800), $wa.Height))
    $form.MinimumSize = New-Object System.Drawing.Size([math]::Min((Px 1000), $wa.Width), [math]::Min((Px 640), $wa.Height))
    $form.BackColor = $theme.FormBg
    $form.ForeColor = $theme.Text
    $form.Font = $uiFont

    function New-WrapLabel([string]$text, [int]$width, $font = $null) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.AutoSize = $true
        $l.MaximumSize = New-Object System.Drawing.Size($width, 0)
        if ($font) { $l.Font = $font }
        return $l
    }

    # ---------- 顶部标题栏 ----------
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = "Top"
    $header.Height = Px 66
    $header.BackColor = $theme.CardBg
    $header.Add_Paint({
            param($s, $e)
            $pen = New-Object System.Drawing.Pen($theme.Border)
            $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1)
            $accentBrush = New-Object System.Drawing.SolidBrush($theme.Accent)
            $e.Graphics.FillRectangle($accentBrush, 0, 0, (Px 4), $s.Height)
            $pen.Dispose(); $accentBrush.Dispose()
        })
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "截图区域 & 输入框校准"
    $lblTitle.Font = $titleFont
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point((Px 20), (Px 10))
    $header.Controls.Add($lblTitle)
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "拖动金色边线调整截图区域  ·  拖动十字设置输入框点击位置  ·  亮的部分就是发给 AI 的画面  ·  Enter 确认  ·  Esc 返回上一步"
    $lblHint.ForeColor = $theme.SubText
    $lblHint.AutoSize = $true
    $lblHint.Location = New-Object System.Drawing.Point((Px 22), (Px 40))
    $header.Controls.Add($lblHint)

    # ---------- 左侧设置栏（卡片式，可滚动） ----------
    $cardW = Px 292
    $innerW = $cardW - (Px 28)

    $sideHost = New-Object System.Windows.Forms.Panel
    $sideHost.Dock = "Left"
    $sideHost.Width = Px 336
    $sideHost.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 14), (Px 4), (Px 6))
    $panelCtrl = New-Object System.Windows.Forms.FlowLayoutPanel
    $panelCtrl.Dock = "Fill"
    $panelCtrl.FlowDirection = "TopDown"
    $panelCtrl.WrapContents = $false
    $panelCtrl.AutoScroll = $true
    $sideHost.Controls.Add($panelCtrl)

    function New-Card([string]$title) {
        $c = New-Object System.Windows.Forms.FlowLayoutPanel
        $c.FlowDirection = "TopDown"
        $c.WrapContents = $false
        $c.AutoSize = $true
        $c.AutoSizeMode = "GrowAndShrink"
        $c.MinimumSize = New-Object System.Drawing.Size($cardW, 0)
        $c.MaximumSize = New-Object System.Drawing.Size($cardW, 0)
        $c.Padding = New-Object System.Windows.Forms.Padding((Px 14), (Px 12), (Px 14), (Px 12))
        $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 12))
        $c.BackColor = $theme.CardBg
        $c.Add_Paint({
                param($s, $e)
                $pen = New-Object System.Drawing.Pen($theme.Border)
                $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
                $pen.Dispose()
            })
        $t = New-WrapLabel $title $innerW $cardTitleFont
        $t.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 8))
        [void]$c.Controls.Add($t)
        $panelCtrl.Controls.Add($c)
        return $c
    }

    function New-Nud {
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Width = Px 78
        $n.Minimum = 0
        $n.Maximum = 10000
        $n.TextAlign = "Right"
        $n.Margin = New-Object System.Windows.Forms.Padding(0, (Px 3), (Px 10), (Px 3))
        return $n
    }
    function New-FieldLabel([string]$text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.AutoSize = $true
        $l.ForeColor = $theme.SubText
        $l.Anchor = "Left"
        $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px 3), (Px 4), (Px 3))
        return $l
    }
    function New-Grid([int]$cols) {
        $g = New-Object System.Windows.Forms.TableLayoutPanel
        $g.ColumnCount = $cols
        $g.AutoSize = $true
        $g.AutoSizeMode = "GrowAndShrink"
        $g.Margin = New-Object System.Windows.Forms.Padding(0)
        for ($i = 0; $i -lt $cols; $i++) { [void]$g.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) }
        return $g
    }

    # 卡片 1：截图边距
    $cardMargin = New-Card "①  截图边距（像素）"
    $gridM = New-Grid 4
    $gridM.RowCount = 2
    $marginNuds = @{}
    $marginDisp = @{ Left = "左"; Right = "右"; Top = "上"; Bottom = "下" }
    $cell = 0
    foreach ($n in $marginNames) {
        $nud = New-Nud
        $nud.Tag = $n
        $marginNuds[$n] = $nud
        $gridM.Controls.Add((New-FieldLabel $marginDisp[$n]), ($cell % 2) * 2, [int][math]::Floor($cell / 2))
        $gridM.Controls.Add($nud, ($cell % 2) * 2 + 1, [int][math]::Floor($cell / 2))
        $cell++
    }
    $cardMargin.Controls.Add($gridM)
    $lblCropSize = New-WrapLabel "" $innerW
    $lblCropSize.Padding = New-Object System.Windows.Forms.Padding((Px 8), (Px 5), (Px 8), (Px 5))
    $lblCropSize.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $cardMargin.Controls.Add($lblCropSize)
    $lblWarn = New-WrapLabel "下边距务必遮住输入框和闪烁光标，否则画面会一直变化、导致重复回答。" $innerW
    $lblWarn.ForeColor = $theme.SubText
    $lblWarn.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, 0)
    $cardMargin.Controls.Add($lblWarn)

    # 卡片 2：输入框对焦点击
    $cardFocus = New-Card "②  输入框对焦点击"
    $chkEnable = New-Object System.Windows.Forms.CheckBox
    $chkEnable.Text = "发送前先点一下输入框"
    $chkEnable.AutoSize = $true
    $chkEnable.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 6))
    $cardFocus.Controls.Add($chkEnable)
    $gridC = New-Grid 4
    $gridC.RowCount = 1
    $nudClickX = New-Nud
    $nudClickY = New-Nud
    $gridC.Controls.Add((New-FieldLabel "X"), 0, 0)
    $gridC.Controls.Add($nudClickX, 1, 0)
    $gridC.Controls.Add((New-FieldLabel "Y"), 2, 0)
    $gridC.Controls.Add($nudClickY, 3, 0)
    $cardFocus.Controls.Add($gridC)
    $btnSnap = New-Object System.Windows.Forms.Button
    $btnSnap.Text = "把十字对准检测到的光标"
    $btnSnap.Size = New-Object System.Drawing.Size($innerW, (Px 32))
    $btnSnap.Margin = New-Object System.Windows.Forms.Padding(0, (Px 8), 0, (Px 8))
    $cardFocus.Controls.Add($btnSnap)
    $lblClick = New-WrapLabel "" $innerW
    $lblClick.Padding = New-Object System.Windows.Forms.Padding((Px 8), (Px 6), (Px 8), (Px 6))
    $lblClick.MinimumSize = New-Object System.Drawing.Size($innerW, 0)
    $cardFocus.Controls.Add($lblClick)

    # 卡片 3：光标检测结果
    $cardCheck = New-Card "③  光标 / 动态内容检测"
    $lblCaret = New-WrapLabel "" $innerW
    $lblCaret.Padding = New-Object System.Windows.Forms.Padding((Px 8), (Px 6), (Px 8), (Px 6))
    $lblCaret.MinimumSize = New-Object System.Drawing.Size($innerW, 0)
    $cardCheck.Controls.Add($lblCaret)

    # 卡片 4：图例
    $cardLegend = New-Card "图例"
    $legendItems = @(
        @([System.Drawing.Color]::Gold, "金色边框：发给 AI 的截图区域（拖边线调整）"),
        @([System.Drawing.Color]::Red, "红色十字：对焦点击位置（关闭时为灰色）"),
        @([System.Drawing.Color]::Cyan, "青色框：检测到的输入框光标"),
        @([System.Drawing.Color]::Orange, "橙色框：持续变化的内容（如动图）")
    )
    foreach ($it in $legendItems) {
        $row = New-Object System.Windows.Forms.FlowLayoutPanel
        $row.AutoSize = $true
        $row.WrapContents = $false
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 4))
        $sw = New-Object System.Windows.Forms.Panel
        $sw.Size = New-Object System.Drawing.Size((Px 12), (Px 12))
        $sw.BackColor = $it[0]
        $sw.Margin = New-Object System.Windows.Forms.Padding(0, (Px 4), (Px 8), 0)
        $row.Controls.Add($sw)
        $lt = New-WrapLabel $it[1] ($innerW - (Px 24))
        $lt.ForeColor = $theme.SubText
        $lt.Margin = New-Object System.Windows.Forms.Padding(0, (Px 1), 0, 0)
        $row.Controls.Add($lt)
        $cardLegend.Controls.Add($row)
    }

    # ---------- 右侧预览 ----------
    $previewHost = New-Object System.Windows.Forms.Panel
    $previewHost.Dock = "Fill"
    $previewHost.Padding = New-Object System.Windows.Forms.Padding((Px 8), (Px 14), (Px 16), (Px 6))
    $panelPreview = New-Object System.Windows.Forms.Panel
    $panelPreview.Dock = "Fill"
    $panelPreview.BackColor = $theme.PreviewBg
    $previewHost.Controls.Add($panelPreview)

    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Dock = "Fill"
    $pictureBox.BackColor = $theme.PreviewBg
    $panelPreview.Controls.Add($pictureBox)

    # 预览底部状态条：鼠标坐标 / 截图尺寸 / 缩放比例
    $lblCoord = New-Object System.Windows.Forms.Label
    $lblCoord.Dock = "Bottom"
    $lblCoord.Height = Px 26
    $lblCoord.TextAlign = "MiddleLeft"
    $lblCoord.Padding = New-Object System.Windows.Forms.Padding((Px 10), 0, 0, 0)
    $lblCoord.BackColor = $theme.StatusBg
    $lblCoord.ForeColor = $theme.StatusFg
    $panelPreview.Controls.Add($lblCoord)
    $st.MouseX = -1
    $st.MouseY = -1
    $st.Hover = "None"
    function Update-CoordBar {
        $d = Get-DispRect
        $cw = $st.Width - $st.Margins.Left - $st.Margins.Right
        $ch = $st.Height - $st.Margins.Top - $st.Margins.Bottom
        $parts = @()
        if ($st.MouseX -ge 0) { $parts += "鼠标 ($($st.MouseX), $($st.MouseY))" } else { $parts += "鼠标 —" }
        $parts += "微信窗口 $($st.Width) × $($st.Height)"
        $parts += "截图区 $cw × $ch"
        if ($d) { $parts += ("预览缩放 {0:0}%" -f ($d.S * 100)) }
        $lblCoord.Text = ($parts -join "     ·     ")
    }

    # ---------- 底部按钮栏 ----------
    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = "Bottom"
    $footer.Height = Px 60
    $footer.BackColor = $theme.CardBg
    $footer.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 12), (Px 16), (Px 12))
    $footer.Add_Paint({
            param($s, $e)
            $pen = New-Object System.Drawing.Pen($theme.Border)
            $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0)
            $pen.Dispose()
        })
    $flowLeft = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowLeft.Dock = "Fill"
    $flowLeft.WrapContents = $false
    $flowRight = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowRight.Dock = "Right"
    $flowRight.AutoSize = $true
    $flowRight.AutoSizeMode = "GrowAndShrink"
    $flowRight.WrapContents = $false
    $footer.Controls.Add($flowLeft)
    $footer.Controls.Add($flowRight)

    function Set-ButtonStyle($b, [string]$kind) {
        $b.FlatStyle = "Flat"
        $b.UseVisualStyleBackColor = $false
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.FlatAppearance.BorderSize = 1
        if ($kind -eq "primary") {
            $b.BackColor = $theme.Accent
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = $theme.Accent
            $b.FlatAppearance.MouseOverBackColor = $theme.AccentHot
            $b.FlatAppearance.MouseDownBackColor = $theme.AccentDn
            $b.Font = New-Object System.Drawing.Font($fontName, 9.5, [System.Drawing.FontStyle]::Bold)
        }
        else {
            $b.BackColor = $theme.CardBg
            $b.ForeColor = $theme.Text
            $b.FlatAppearance.BorderColor = $theme.BtnBorder
            $b.FlatAppearance.MouseOverBackColor = $theme.BtnHot
            $b.FlatAppearance.MouseDownBackColor = $theme.BtnDn
        }
    }
    function New-BarButton([string]$text, $parent, [string]$kind = "secondary", [int]$width = 112) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Font = $btnFont
        $b.Size = New-Object System.Drawing.Size((Px $width), (Px 36))
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, (Px 8), 0)
        Set-ButtonStyle $b $kind
        $parent.Controls.Add($b)
        return $b
    }
    Set-ButtonStyle $btnSnap "secondary"

    $btnRefresh = New-BarButton "重新截图" $flowLeft
    $btnDetect = New-BarButton "检测光标" $flowLeft
    $btnAvoid = New-BarButton "避开光标" $flowLeft
    $btnReset = New-BarButton "恢复默认" $flowLeft
    $btnBack = New-BarButton "返回上一步" $flowRight
    $btnConfirm = New-BarButton "确认并继续" $flowRight "primary" 128
    $btnConfirm.Margin = New-Object System.Windows.Forms.Padding(0)

    $toolTip.SetToolTip($btnRefresh, "重新截取微信窗口画面（微信窗口大小变化后用）")
    $toolTip.SetToolTip($btnDetect, "把微信短暂切到前台约 2 秒，找出闪烁光标和动图等变化区域")
    $toolTip.SetToolTip($btnAvoid, "自动调大下边距，让截图区域避开检测到的光标")
    $toolTip.SetToolTip($btnReset, "边距和点击点恢复为默认值")
    $toolTip.SetToolTip($btnBack, "放弃本次修改，返回向导上一步（Esc）")
    $toolTip.SetToolTip($btnConfirm, "保存截图区域和点击位置（Enter）")
    $toolTip.SetToolTip($btnSnap, "把点击点移到检测到的光标右侧")
    $toolTip.SetToolTip($chkEnable, "开启后，每次发送前会先点一下输入框，确保焦点在输入框上")

    # 停靠顺序：后加入的先停靠 → 标题栏、按钮栏横跨全宽，侧栏夹在中间，预览填满剩余区域
    $form.Controls.Add($previewHost)
    $form.Controls.Add($sideHost)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)

    $pictureBox.Add_Paint({
            param($s, $e)
            $d = Get-DispRect
            if ($null -eq $d) { return }
            $g = $e.Graphics
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
                $g.DrawImage($st.Image, (New-Object System.Drawing.Rectangle($d.X, $d.Y, $d.W, $d.H)))
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

                $L = [int]($st.Margins.Left * $d.S + $d.X)
                $R = [int](($st.Width - $st.Margins.Right) * $d.S + $d.X)
                $T = [int]($st.Margins.Top * $d.S + $d.Y)
                $B = [int](($st.Height - $st.Margins.Bottom) * $d.S + $d.Y)
                $right = $d.X + $d.W
                $bottom = $d.Y + $d.H

                $mask = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
                $g.FillRectangle($mask, $d.X, $d.Y, $d.W, [math]::Max(0, $T - $d.Y))
                $g.FillRectangle($mask, $d.X, $B, $d.W, [math]::Max(0, $bottom - $B))
                $g.FillRectangle($mask, $d.X, $T, [math]::Max(0, $L - $d.X), [math]::Max(0, $B - $T))
                $g.FillRectangle($mask, $R, $T, [math]::Max(0, $right - $R), [math]::Max(0, $B - $T))
                $mask.Dispose()

                # 边线 + 中点手柄；悬停或拖动中的边线高亮为白色
                $edgePen = New-Object System.Drawing.Pen([System.Drawing.Color]::Gold, (Px 2))
                $g.DrawRectangle($edgePen, $L, $T, [math]::Max(1, $R - $L), [math]::Max(1, $B - $T))
                $edgePen.Dispose()
                $active = if ($st.Drag -ne "None") { $st.Drag } else { $st.Hover }
                if ($active -like "Edge*") {
                    $hiPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, (Px 3))
                    switch ($active) {
                        "EdgeLeft" { $g.DrawLine($hiPen, $L, $T, $L, $B) }
                        "EdgeRight" { $g.DrawLine($hiPen, $R, $T, $R, $B) }
                        "EdgeTop" { $g.DrawLine($hiPen, $L, $T, $R, $T) }
                        "EdgeBottom" { $g.DrawLine($hiPen, $L, $B, $R, $B) }
                    }
                    $hiPen.Dispose()
                }
                $hb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gold)
                $hp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 60), 1)
                $mx = [int](($L + $R) / 2); $my = [int](($T + $B) / 2)
                $hs = Px 5
                foreach ($p in @(@($L, $my), @($R, $my), @($mx, $T), @($mx, $B))) {
                    $g.FillRectangle($hb, $p[0] - $hs, $p[1] - $hs, $hs * 2, $hs * 2)
                    $g.DrawRectangle($hp, $p[0] - $hs, $p[1] - $hs, $hs * 2, $hs * 2)
                }
                $hb.Dispose(); $hp.Dispose()

                # 截图区尺寸标签（放在框上沿外侧，空间不足时放进框内）
                $tagText = "AI 截图区  {0} × {1}" -f ($st.Width - $st.Margins.Left - $st.Margins.Right), ($st.Height - $st.Margins.Top - $st.Margins.Bottom)
                $tagSize = $g.MeasureString($tagText, $tagFont)
                $tw = [int]$tagSize.Width + (Px 10); $th = [int]$tagSize.Height + (Px 4)
                $tx = $L
                $ty = if ($T - $th - (Px 4) -ge $d.Y) { $T - $th - (Px 4) } else { $T + (Px 6) }
                if ($tx + $tw -gt $right) { $tx = [math]::Max($d.X, $right - $tw) }
                $tagBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gold)
                $tagFg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 34, 0))
                $g.FillRectangle($tagBg, $tx, $ty, $tw, $th)
                $g.DrawString($tagText, $tagFont, $tagFg, $tx + (Px 5), $ty + (Px 2))
                $tagBg.Dispose(); $tagFg.Dispose()

                # 光标（青）与其他动态区域（橙）
                $cr = $st.Caret
                if ($cr -and $cr.Ok -and $cr.Width -eq $st.Width -and $cr.Height -eq $st.Height) {
                    $dynPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Orange, 2)
                    foreach ($dy in $cr.Dynamic) {
                        $g.DrawRectangle($dynPen, [int]($dy.X * $d.S + $d.X) - 3, [int]($dy.Y * $d.S + $d.Y) - 3,
                            [int]($dy.W * $d.S) + 6, [int]($dy.H * $d.S) + 6)
                    }
                    $dynPen.Dispose()
                    if ($cr.Caret) {
                        $c = $cr.Caret
                        $caretPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Cyan, 3)
                        $g.DrawRectangle($caretPen, [int]($c.X * $d.S + $d.X) - 6, [int]($c.Y * $d.S + $d.Y) - 5,
                            [int]($c.W * $d.S) + 12, [int]($c.H * $d.S) + 10)
                        $caretPen.Dispose()
                    }
                }

                # 点击点启用时显示红色；光标检测仍使用该位置。
                $cx = [int]($st.ClickX * $d.S + $d.X)
                $cy = [int]($st.ClickY * $d.S + $d.Y)
                $crossColor = if ($st.FocusEnabled) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::Gray }
                $shadow = New-Object System.Drawing.Pen([System.Drawing.Color]::White, (Px 4))
                $crossPen = New-Object System.Drawing.Pen($crossColor, (Px 2))
                $a1 = Px 14; $a0 = Px 4; $rr = Px 7
                foreach ($pen in @($shadow, $crossPen)) {
                    $g.DrawLine($pen, $cx - $a1, $cy, $cx - $a0, $cy)
                    $g.DrawLine($pen, $cx + $a0, $cy, $cx + $a1, $cy)
                    $g.DrawLine($pen, $cx, $cy - $a1, $cx, $cy - $a0)
                    $g.DrawLine($pen, $cx, $cy + $a0, $cx, $cy + $a1)
                }
                $g.DrawEllipse($crossPen, $cx - $rr, $cy - $rr, $rr * 2, $rr * 2)
                $shadow.Dispose(); $crossPen.Dispose()
                # 十字旁的文字标签；悬停时提示可拖动
                $crossText = if ($st.Hover -eq "Click" -or $st.Drag -eq "Click") { "拖动设置点击点" } elseif ($st.FocusEnabled) { "点击点" } else { "检测点" }
                $cs = $g.MeasureString($crossText, $tagFont)
                $clx = $cx + $a1 + (Px 4)
                if ($clx + $cs.Width + (Px 8) -gt $right) { $clx = $cx - $a1 - (Px 4) - [int]$cs.Width - (Px 8) }
                $cly = $cy - [int]($cs.Height / 2) - (Px 2)
                $clBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 20, 20, 20))
                $clFg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
                $g.FillRectangle($clBg, $clx, $cly, [int]$cs.Width + (Px 8), [int]$cs.Height + (Px 4))
                $g.DrawString($crossText, $tagFont, $clFg, $clx + (Px 4), $cly + (Px 2))
                $clBg.Dispose(); $clFg.Dispose()
            }
            catch {
                Write-AppLog "预览绘制异常（已忽略）：$($_.Exception.Message)" "DEBUG"
            }
        })

    # 鼠标拖拽
    $pictureBox.Add_MouseDown({
            param($s, $e)
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            $st.Drag = Get-HitTarget $e.X $e.Y
        })

    $pictureBox.Add_MouseUp({
            param($s, $e)
            if ($st.Drag -ne "None") {
                $st.Drag = "None"
                Sync-Inputs
                Refresh-View
            }
        })

    $pictureBox.Add_MouseMove({
            param($s, $e)
            $d = Get-DispRect
            # 状态条显示鼠标对应的微信窗口坐标
            if ($d -and $d.S -gt 0 -and $e.X -ge $d.X -and $e.X -lt $d.X + $d.W -and $e.Y -ge $d.Y -and $e.Y -lt $d.Y + $d.H) {
                $st.MouseX = [int](($e.X - $d.X) / $d.S); $st.MouseY = [int](($e.Y - $d.Y) / $d.S)
            }
            else { $st.MouseX = -1; $st.MouseY = -1 }
            if ($st.Drag -eq "None") {
                $hit = Get-HitTarget $e.X $e.Y
                switch ($hit) {
                    "Click" { $pictureBox.Cursor = [System.Windows.Forms.Cursors]::SizeAll }
                    { $_ -in @("EdgeLeft", "EdgeRight") } { $pictureBox.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
                    { $_ -in @("EdgeTop", "EdgeBottom") } { $pictureBox.Cursor = [System.Windows.Forms.Cursors]::SizeNS }
                    default { $pictureBox.Cursor = [System.Windows.Forms.Cursors]::Default }
                }
                if ($hit -ne $st.Hover) { $st.Hover = $hit; $pictureBox.Invalidate() }
                Update-CoordBar
                return
            }
            if ($null -eq $d -or $d.S -le 0) { return }
            $ix = [int](($e.X - $d.X) / $d.S)
            $iy = [int](($e.Y - $d.Y) / $d.S)
            $m = $st.Margins
            switch ($st.Drag) {
                "EdgeLeft" { $m.Left = Limit-Int $ix 0 ($st.Width - $m.Right - $minCrop) }
                "EdgeRight" { $m.Right = Limit-Int ($st.Width - $ix) 0 ($st.Width - $m.Left - $minCrop) }
                "EdgeTop" { $m.Top = Limit-Int $iy 0 ($st.Height - $m.Bottom - $minCrop) }
                "EdgeBottom" { $m.Bottom = Limit-Int ($st.Height - $iy) 0 ($st.Height - $m.Top - $minCrop) }
                "Click" {
                    $st.ClickX = Limit-Int $ix 0 ($st.Width - 1)
                    $st.ClickY = Limit-Int $iy 0 ($st.Height - 1)
                }
            }
            Sync-Inputs
            Refresh-View
        })

    $pictureBox.Add_MouseLeave({
            $st.MouseX = -1; $st.MouseY = -1
            if ($st.Hover -ne "None") { $st.Hover = "None"; $pictureBox.Invalidate() }
            Update-CoordBar
        })
    $pictureBox.Add_Resize({ Update-CoordBar; $pictureBox.Invalidate() })

    # 数值框 → 状态
    foreach ($n in $marginNames) {
        $marginNuds[$n].Add_ValueChanged({
                if ($st.Syncing) { return }
                $st.Margins[$this.Tag] = [int]$this.Value
                Repair-State
                Sync-Inputs
                Refresh-View
            })
    }
    $nudClickX.Add_ValueChanged({ if (-not $st.Syncing) { $st.ClickX = [int]$this.Value; Refresh-View } })
    $nudClickY.Add_ValueChanged({ if (-not $st.Syncing) { $st.ClickY = [int]$this.Value; Refresh-View } })
    $chkEnable.Add_CheckedChanged({
            if ($st.Syncing) { return }
            $st.FocusEnabled = [bool]$this.Checked
            Sync-Inputs
            Refresh-View
        })


    $btnRefresh.Add_Click({ Update-Capture })

    $btnReset.Add_Click({
            foreach ($n in $marginNames) { $st.Margins[$n] = $defaultMargins[$n] }
            $st.ClickX = [int]($st.Width * $defaultFocus.RatioX)
            $st.ClickY = $st.Height - $defaultFocus.OffsetFromBottom
            Repair-State
            Sync-Inputs
            Refresh-View
        })

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })

    $btnConfirm.Add_Click({
            $info = Get-CheckInfo
            $warn = @()
            if ($info.CaretInside) { $warn += "• 输入框光标在截图区域内（会导致重复回答）" }
            if ($info.DynamicInside -gt 0) { $warn += "• 截图区域内有 $($info.DynamicInside) 处持续变化的内容" }
            if ($st.FocusEnabled -and -not $info.ClickInMask) { $warn += "• 对焦点击点落在聊天区内（可能点开图片或链接）" }
            if ($warn.Count -gt 0) {
                $msg = "检测到以下问题：`n`n" + ($warn -join "`n") + "`n`n建议先调整。仍然要使用当前设置吗？"
                $ans = [System.Windows.Forms.MessageBox]::Show($form, $msg, "设置检查",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning,
                    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                Write-AppLog "用户在存在警告的情况下仍确认了截图区域/点击点：$($warn -join '；')" "WARN"
            }
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
            $form.Close()
        })

    # 光标检测先在十字位置尝试聚焦，再采样画面。
    $runCaretDetection = {
        if ($st.Running) { return }
        $st.Running = $true
        foreach ($b in @($btnDetect, $btnAvoid, $btnSnap, $btnRefresh)) { $b.Enabled = $false }
        Set-Tone $lblCaret "Info"
        $lblCaret.Text = "⏳ 正在检测光标，微信会短暂切到前台，请勿操作…"
        $form.Refresh()
        $oldCursor = $form.Cursor
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $st.Caret = Find-CaretInWindow -WindowHandle $WindowHandle -RestoreHandle $form.Handle `
                -ClickX $st.ClickX -ClickY $st.ClickY
        }
        catch {
            $st.Caret = [PSCustomObject]@{ Ok = $false; Reason = "检测异常：$($_.Exception.Message)"; Caret = $null; Dynamic = @(); Width = 0; Height = 0 }
        }
        finally {
            $form.Cursor = $oldCursor
            $st.Running = $false
            foreach ($b in @($btnDetect, $btnAvoid, $btnSnap, $btnRefresh)) { $b.Enabled = $true }
            try { $form.Activate() } catch {}
        }
        # 聚焦和前台切换可能改变画面，检测后刷新预览。
        Update-Capture
    }
    $btnDetect.Add_Click({ & $runCaretDetection })

    $btnAvoid.Add_Click({
            $info = Get-CheckInfo
            if ($info.CaretStatus -ne "Found") {
                [void][System.Windows.Forms.MessageBox]::Show($form, "还没有可用的光标检测结果，请先点【检测光标】。", "避开光标")
                return
            }
            $c = $st.Caret.Caret
            $need = $st.Height - $c.Y + 8
            if ($need -gt $st.Height - $st.Margins.Top - $minCrop) {
                [void][System.Windows.Forms.MessageBox]::Show($form, "光标位置太靠上，无法仅靠下边距避开，请手动调整。", "避开光标")
                return
            }
            if ($need -gt $st.Margins.Bottom) { $st.Margins.Bottom = $need }
            Repair-State
            Sync-Inputs
            Refresh-View
            $remainH = $st.Height - $st.Margins.Top - $st.Margins.Bottom
            if ($remainH -lt 100) {
                [void][System.Windows.Forms.MessageBox]::Show($form, "调整后截图区域只剩 $remainH 像素高，可能看不全聊天内容，请检查上边距。", "避开光标")
            }
        })

    $btnSnap.Add_Click({
            $info = Get-CheckInfo
            if ($info.CaretStatus -ne "Found") {
                [void][System.Windows.Forms.MessageBox]::Show($form, "还没有检测到光标。先把十字大致拖到输入框上，再点【检测光标】。", "对准光标")
                return
            }
            $c = $st.Caret.Caret
            # 在光标右侧选择候选点击点，再按窗口边界夹取。
            $st.ClickX = $c.X + $c.W + 10
            $st.ClickY = $c.Y + [int]($c.H / 2)
            Repair-State
            Sync-Inputs
            Refresh-View
        })

    # 不使用 AcceptButton：先由 KeyPreview 提交数值框编辑，再处理确认；Esc 使用 CancelButton。
    $form.KeyPreview = $true
    $form.CancelButton = $btnBack
    $form.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -ne [System.Windows.Forms.Keys]::Return) { return }
            if ($e.Alt -or $e.Control -or $e.Shift) { return }
            $ac = $form.ActiveControl
            $nud = $null
            if ($ac -is [System.Windows.Forms.NumericUpDown]) { $nud = $ac }
            elseif ($ac -and ($ac.Parent -is [System.Windows.Forms.NumericUpDown])) { $nud = $ac.Parent }
            if ($nud) {
                $txtBefore = $nud.Text.Trim()
                $committed = [string][int]$nud.Value
                if ($txtBefore -ne $committed) {
                    $e.Handled = $true
                    $e.SuppressKeyPress = $true
                    return
                }
            }
            elseif ($ac -is [System.Windows.Forms.Button]) {
                $e.Handled = $true
                $e.SuppressKeyPress = $true
                $ac.PerformClick()
                return
            }
            $e.Handled = $true
            $e.SuppressKeyPress = $true
            $btnConfirm.PerformClick()
        })

    $form.Add_Shown({ & $runCaretDetection })
    Update-Capture

    $result = $form.ShowDialog()
    $form.Dispose()
    foreach ($f in @($uiFont, $boldFont, $titleFont, $cardTitleFont, $tagFont, $btnFont)) { if ($f) { $f.Dispose() } }
    if ($toolTip) { $toolTip.Dispose() }
    if ($st.Image) { $st.Image.Dispose(); $st.Image = $null }

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        # 点击点保存为横向比例和距底像素，供尺寸变化后重新计算。
        $ratioX = if ($st.Width -gt 0) { [math]::Round($st.ClickX / $st.Width, 4) } else { $defaultFocus.RatioX }
        $ratioX = [math]::Max(0.05, [math]::Min(0.95, $ratioX))
        return @{
            Confirmed  = $true
            Margins    = $st.Margins.Clone()
            FocusClick = @{
                Enabled          = [bool]$st.FocusEnabled
                RatioX           = [double]$ratioX
                OffsetFromBottom = [int][math]::Max(0, $st.Height - $st.ClickY)
            }
        }
    }
    return @{ Confirmed = $false }
}
# 配置向导：收集设置、标准化后保存并返回 PSCustomObject。
# 向导步骤标题栏：进度点 + 步骤名。
$script:WizardStepNames = @("聊天服务商", "Key 与模型", "长期记忆", "截图区域", "AI 人设", "提醒与通知", "发送方式", "运行日志")
function Write-WizardStep {
    param([int]$Step, [string]$Subtitle = "")
    $total = $script:WizardStepNames.Count
    $name = $script:WizardStepNames[$Step - 1]
    Write-Host ""
    Write-Host "  " -NoNewline
    for ($i = 1; $i -le $total; $i++) {
        if ($i -lt $Step) { Write-Host "━━" -NoNewline -ForegroundColor Green }
        elseif ($i -eq $Step) { Write-Host "━━" -NoNewline -ForegroundColor Cyan }
        else { Write-Host "━━" -NoNewline -ForegroundColor DarkGray }
        if ($i -lt $total) { Write-Host " " -NoNewline }
    }
    Write-Host ("  {0}/{1}" -f $Step, $total) -ForegroundColor DarkGray
    Write-Host ("  步骤 {0} · " -f $Step) -NoNewline -ForegroundColor Cyan
    Write-Host $name -ForegroundColor White
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor DarkGray }
}

# 向导保存后的配置摘要；API Key 只显示末 4 位。
function Show-ConfigSummary {
    param($Conf)
    function Get-KeyHint([string]$key) {
        if (-not $key) { return "未设置" }
        if ($key -eq "ollama") { return "本地，无需 Key" }
        if ($key.Length -le 6) { return "已设置" }
        return "已设置（尾号 " + $key.Substring($key.Length - 4) + "）"
    }
    Write-SectionTitle "配置摘要"
    Write-InfoRow "聊天" "$($Conf.Chat.ProviderType) / $($Conf.Chat.Model)" White (Get-KeyHint ([string]$Conf.Chat.ApiKey))
    if ($Conf.Summary.enabled) {
        $sumModel = if ($Conf.Summary.ApiUrl -eq $Conf.Chat.ApiUrl -and $Conf.Summary.Model -eq $Conf.Chat.Model) { "同聊天模型" } else { "$($Conf.Summary.ProviderType) / $($Conf.Summary.Model)" }
        Write-InfoRow "记忆" "开启" Cyan ("每 {0} 条总结一次，保留最近 {1} 条 · {2}" -f $Conf.Summary.triggerCount, $Conf.Summary.retainCount, $sumModel)
    }
    else { Write-InfoRow "记忆" "关闭" DarkGray }
    Write-InfoRow "截图" ("边距 左{0} 右{1} 上{2} 下{3}" -f $Conf.Margins.Left, $Conf.Margins.Right, $Conf.Margins.Top, $Conf.Margins.Bottom)
    if ($Conf.EnableFocusClick) { Write-InfoRow "对焦" "发送前自动点击输入框" }
    else { Write-InfoRow "对焦" "关闭" DarkGray "启动后需手动点一次输入框" }
    $prompt = [string]$Conf.SystemPrompt
    if ((Get-TextDisplayWidth $prompt) -gt 40) {
        $cut = ""
        foreach ($ch in $prompt.ToCharArray()) { if ((Get-TextDisplayWidth ($cut + $ch)) -gt 38) { break }; $cut += $ch }
        $prompt = $cut + "…"
    }
    Write-InfoRow "人设" $prompt
    $methodText = switch ($Conf.SendMethod) { "WMChar" { "纯后台注入" } "Clipboard" { "纯剪贴板" } default { "智能混合" } }
    Write-InfoRow "发送" $methodText
    $alerts = @()
    $alerts += $(if ($Conf.BeepOnReply) { "提示音开" } else { "静音" })
    $alerts += $(if ($Conf.NotifyOnProblem) { "系统通知开" } else { "系统通知关" })
    $alerts += $(if ($Conf.BlockOnMinimized) { "最小化时阻塞" } else { "最小化时自动等待" })
    Write-InfoRow "提醒" ($alerts -join " · ")
    if ($Conf.EnableLogging) { Write-InfoRow "日志" "开启 ($($Conf.LogLevel))" White "logs\" }
    else { Write-InfoRow "日志" "关闭" DarkGray }
}

function Show-WelcomeWizard {
    Clear-Host
    $ShowBack = $false
    Write-Host ""
    Write-Host "  🛠️  配置向导" -ForegroundColor Cyan -NoNewline
    Write-Host "   共 8 步，随时可返回修改" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  菜单  " -NoNewline -ForegroundColor Gray
    Write-Host "↑/↓ 或数字键选择，Enter 确认，Esc/b 返回上一步" -ForegroundColor DarkGray
    Write-Host "  输入  " -NoNewline -ForegroundColor Gray
    Write-Host "直接回车保留 [默认值]，输入 b 返回上一步" -ForegroundColor DarkGray

    # 接口和模型预设作为可编辑的初始值；isVision 是菜单筛选标记，不检测实际模型能力。
    $presets = @(
        @{ name = "DeepSeek (多模态)"; url = "https://api.deepseek.com/chat/completions"; type = "OpenAI"; model = "deepseek-flash"; isVision = $true },
        @{ name = "Qwen (通义千问)"; url = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"; type = "Ali"; model = "qwen3.8-flash"; isVision = $true },
        @{ name = "Google Gemini"; url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"; type = "OpenAI"; model = "gemini-3.8-flash"; isVision = $true },
        @{ name = "OpenAI"; url = "https://api.openai.com/v1/chat/completions"; type = "OpenAI"; model = "gpt-6.1-sol"; isVision = $true },
        @{ name = "Anthropic"; url = "https://api.anthropic.com/v1/messages"; type = "Anthropic"; model = "claude-opus-5-5"; isVision = $true },
        @{ name = "Hugging Face"; url = "https://router.huggingface.co/v1/chat/completions"; type = "OpenAI"; model = "Qwen/Qwen3-VL-8B-Instruct"; isVision = $true },
        @{ name = "DeepSeek V4 Pro (仅文本，适合总结)"; url = "https://api.deepseek.com/chat/completions"; type = "OpenAI"; model = "deepseek-v4-pro"; isVision = $false },
        @{ name = "Ollama (本地)"; url = "http://localhost:11434/v1/chat/completions"; type = "OpenAI"; model = "qwen3.8:27b"; isVision = $true },
        @{ name = "自定义 (兼容 OpenAI)"; url = ""; type = "OpenAI"; model = ""; isVision = $true }
    )

    $WizardData = @{
        Chat         = @{
            ProviderType   = $null
            ApiUrl         = $null
            ApiKey         = ""
            Model          = ""
            MaxTokens      = 1024
            TimeoutSeconds = 60
            AbnormalResponseMaxRetry  = 2
            SendFailureMaxRetry       = 2
        }
        Summary      = @{
            enabled        = $false
            triggerCount   = 15
            retainCount    = 5
            ProviderType   = $null
            ApiUrl         = $null
            ApiKey         = ""
            Model          = ""
            MaxTokens      = 1024
            TimeoutSeconds = 60
        }
        Margins      = @{ Left = 360; Right = 30; Top = 85; Bottom = 165 }
        FocusClick   = @{ Enabled = $false; RatioX = 0.65; OffsetFromBottom = 50 }
        SystemPrompt = "你是一个全能助手。"
        BeepOnReply  = $true
        BlockOnMinimized = $false
        NotifyOnProblem  = $true
        SendMethod   = "Hybrid"
        EnableLogging = $false
        LogLevel      = "INFO"
    }

    # 重新配置时以已有配置为默认值：向导里回车即可保留原值，
    # 向导不涉及的高级项（随机延迟、主动发起、Token 上限等）在保存时原样保留。
    $oldConf = $null
    if (Test-Path -LiteralPath $CONFIG_FILE) {
        try {
            $oldConf = Get-Content -LiteralPath $CONFIG_FILE -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($oldConf -isnot [PSCustomObject]) { $oldConf = $null }
        }
        catch { $oldConf = $null }
    }
    if ($oldConf) {
        try {
            foreach ($section in @('Chat', 'Summary')) {
                $node = $oldConf.$section
                if ($node -is [PSCustomObject]) {
                    foreach ($prop in $node.PSObject.Properties) { $WizardData[$section][$prop.Name] = $prop.Value }
                }
            }
            if ($oldConf.Margins) {
                foreach ($k in @("Left", "Right", "Top", "Bottom")) {
                    if ($null -ne $oldConf.Margins.$k) { $WizardData.Margins[$k] = [int]$oldConf.Margins.$k }
                }
            }
            if ($null -ne $oldConf.EnableFocusClick) { $WizardData.FocusClick.Enabled = [bool]$oldConf.EnableFocusClick }
            if ($null -ne $oldConf.InputBoxClickRatioX) { $WizardData.FocusClick.RatioX = [double]$oldConf.InputBoxClickRatioX }
            if ($null -ne $oldConf.InputBoxOffsetFromBottom) { $WizardData.FocusClick.OffsetFromBottom = [int]$oldConf.InputBoxOffsetFromBottom }
            foreach ($k in @('SystemPrompt', 'BeepOnReply', 'BlockOnMinimized', 'NotifyOnProblem', 'SendMethod', 'EnableLogging', 'LogLevel')) {
                if ($null -ne $oldConf.$k) { $WizardData[$k] = $oldConf.$k }
            }
        }
        catch {
            Write-Host "⚠️ 读取旧配置作为默认值时出错，部分选项将使用默认值：$($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    $oldChatUrl = [string]$WizardData.Chat.ApiUrl
    $oldChatKey = [string]$WizardData.Chat.ApiKey
    $oldChatModel = [string]$WizardData.Chat.Model
    $oldSumUrl = [string]$WizardData.Summary.ApiUrl
    $oldSumKey = [string]$WizardData.Summary.ApiKey
    $oldSumModel = [string]$WizardData.Summary.Model
    $oldSumSeparate = ($oldSumUrl -and ($oldSumUrl -ne $oldChatUrl -or $oldSumModel -ne $oldChatModel))

    $CurrentStep = 1

    while ($CurrentStep -le 8) {
        if ($CurrentStep -eq 1) { 
            $ShowBack = $false 
        }
        else { 
            $ShowBack = $true 
        }
        switch ($CurrentStep) {
            1 {
                Write-WizardStep 1 "选择负责聊天的 AI 服务商（需要支持图片识别）"
                $visionPresets = $presets | Where-Object { $_.isVision }

                $menuOptions = @($visionPresets | ForEach-Object { $_.name })
                $menuResult = Show-Menu -Title "请选择 AI 服务商" -Options $menuOptions

                if ($menuResult -eq -1) { Write-Host "⚠️ 已是第一步，无法回退。" -ForegroundColor Red; continue }

                $sel = @{}
                $visionPresets[$menuResult].GetEnumerator() | ForEach-Object { $sel[$_.Key] = $_.Value }
                $WizardData.Chat.ProviderType = $sel.type
                $WizardData.Chat.ApiUrl = $sel.url
                $WizardData.Chat.Model = $sel.model   
                $WizardData.Chat.IsOllama = ($sel.name -match "Ollama")

                if ($sel.name -match "自定义") {
                    $url = Ask-Input -Prompt "请输入完整 API URL" -DefaultValue $oldChatUrl
                    if ($url -eq "[BACK]") { continue }
                    $WizardData.Chat.ApiUrl = $url
                }

                # 接口地址没变时沿用原 Key 和模型名；换了服务商则清空 Key，避免把 A 家的 Key 发给 B 家。
                if ($oldChatUrl -and $WizardData.Chat.ApiUrl -eq $oldChatUrl) {
                    $WizardData.Chat.ApiKey = $oldChatKey
                    if ($oldChatModel) { $WizardData.Chat.Model = $oldChatModel }
                }
                else {
                    $WizardData.Chat.ApiKey = ""
                }
                $CurrentStep++
            }
            2 {
                Write-WizardStep 2 "接口类型：$($WizardData.Chat.ProviderType)"

                if ($WizardData.Chat.IsOllama) {
                    $WizardData.Chat.ApiKey = "ollama"
                }
                else {
                    $key = Ask-Input -Prompt "输入 API Key" -DefaultValue $WizardData.Chat.ApiKey -Secret
                    if ($key -eq "[BACK]") { $CurrentStep--; continue }
                    $WizardData.Chat.ApiKey = $key
                }

                $defModel = $WizardData.Chat.Model
                $model = Ask-Input -Prompt "输入模型名称" -DefaultValue $defModel
                if ($model -eq "[BACK]") { $CurrentStep--; continue }
                $WizardData.Chat.Model = $model
                # MaxTokens / TimeoutSeconds 不在向导里设置，沿用旧配置或默认值。

                $CurrentStep++
            }
            3 {
                Write-WizardStep 3 "聊天记录过长时，自动把旧对话总结成长期记忆"

                $enableResult = Show-Menu -Title "是否开启自动总结旧记忆?" -Options @("是 (开启长期记忆)", "否 (不开启)") -DefaultIndex $(if ($WizardData.Summary.enabled) { 0 } else { 1 })
                if ($enableResult -eq -1) { $CurrentStep--; continue }
                $WizardData.Summary.enabled = ($enableResult -eq 0)

                if ($WizardData.Summary.enabled) {
                    $trig = Ask-Input -Prompt "触发总结的消息数量" -DefaultValue $WizardData.Summary.triggerCount -IsNumber $true
                    if ($trig -eq "[BACK]") { $CurrentStep--; continue }
                    while ($trig -lt 1) {
                        Write-Host "⚠️ 触发数量必须≥1" -ForegroundColor Red
                        $trig = Ask-Input -Prompt "触发总结的消息数量" -DefaultValue 15 -IsNumber $true
                        if ($trig -eq "[BACK]") { break }
                    }
                    if ($trig -eq "[BACK]") { $CurrentStep--; continue }
                    $WizardData.Summary.triggerCount = $trig

                    $ret = Ask-Input -Prompt "总结后保留的近期对话数量" -DefaultValue $WizardData.Summary.retainCount -IsNumber $true
                    if ($ret -eq "[BACK]") { $CurrentStep--; continue }
                    if ($ret -ge $trig) { $ret = $trig - 1; Write-Host "    ⚠️ 已自动调整为 $ret" -ForegroundColor Yellow }
                    $WizardData.Summary.retainCount = $ret

                    $sModeResult = Show-Menu -Title "总结使用哪个模型?" -Options @("同聊天模型（共用配置）", "单独指定总结模型") -DefaultIndex $(if ($oldSumSeparate) { 1 } else { 0 })
                    if ($sModeResult -eq -1) { $CurrentStep--; continue }
                    $sMode = $sModeResult + 1

                    if ($sMode -eq 1) {
                        $WizardData.Summary.ProviderType = $WizardData.Chat.ProviderType
                        $WizardData.Summary.ApiUrl = $WizardData.Chat.ApiUrl
                        $WizardData.Summary.ApiKey = $WizardData.Chat.ApiKey
                        $WizardData.Summary.Model = $WizardData.Chat.Model
                        $WizardData.Summary.MaxTokens = $WizardData.Chat.MaxTokens
                        $WizardData.Summary.TimeoutSeconds = $WizardData.Chat.TimeoutSeconds
                    }
                    else {
                        Write-Host "  请选择总结服务商（支持所有模型，含仅文本的 DeepSeek V4 Pro）:" -ForegroundColor Cyan
                        $sMenuOptions = @($presets | ForEach-Object { $_.name })
                        $sIdx = Show-Menu -Title "选择总结 AI 服务商" -Options $sMenuOptions
                        if ($sIdx -eq -1) { continue }

                        $sSel = $presets[$sIdx]
                        $sSelCopy = @{}
                        $sSel.GetEnumerator() | ForEach-Object { $sSelCopy[$_.Key] = $_.Value }

                        $WizardData.Summary.ProviderType = $sSelCopy.type
                        $WizardData.Summary.ApiUrl = $sSelCopy.url

                        if ($sSelCopy.name -match "自定义") {
                            $sUrl = Ask-Input -Prompt "输入 API URL" -DefaultValue $oldSumUrl
                            if ($sUrl -eq "[BACK]") { $CurrentStep--; continue }
                            $WizardData.Summary.ApiUrl = $sUrl
                        }

                        if ($sSelCopy.name -match "Ollama") {
                            $WizardData.Summary.ApiKey = "ollama"
                        }
                        else {
                            $isSame = ($WizardData.Chat.ProviderType -eq $sSelCopy.type -and $WizardData.Chat.ApiUrl -eq $WizardData.Summary.ApiUrl)
                            if ($oldSumKey -and $oldSumKey -ne "ollama" -and $WizardData.Summary.ApiUrl -eq $oldSumUrl) {
                                $defKey = $oldSumKey
                                $keyPrompt = "输入 API Key"
                            }
                            elseif ($isSame -and $WizardData.Chat.ApiKey -ne "ollama") {
                                $defKey = $WizardData.Chat.ApiKey
                                $keyPrompt = "输入 API Key (回车共用聊天 API Key)"
                            }
                            else {
                                $defKey = ""
                                $keyPrompt = "输入 API Key"
                            }
                            $sKey = Ask-Input -Prompt $keyPrompt -DefaultValue $defKey -Secret
                            if ($sKey -eq "[BACK]") { $CurrentStep--; continue }
                            $WizardData.Summary.ApiKey = $sKey
                        }

                        $sDefModel = if ($oldSumModel -and $WizardData.Summary.ApiUrl -eq $oldSumUrl) { $oldSumModel } else { $sSelCopy.model }
                        $sModel = Ask-Input -Prompt "输入模型名称" -DefaultValue $sDefModel
                        if ($sModel -eq "[BACK]") { $CurrentStep--; continue }
                        $WizardData.Summary.Model = $sModel
                    }
                }
                $CurrentStep++
            }
            4 {
                Write-WizardStep 4 "将打开校准窗口，拖拽实时预览（请确保微信窗口可见）"

                # 区分进程未运行与窗口隐藏到托盘，分别提示启动或还原。
                $wechatProcesses = Get-Process -Name "WeChat", "Weixin" -ErrorAction SilentlyContinue
                $p = $wechatProcesses |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -ne "" } | Select-Object -First 1

                if (-not $p) {
                    if ($wechatProcesses) {
                        Write-Host "⚠️ 微信已最小化！请还原后按回车重试..." -ForegroundColor Red
                    }
                    else {
                        Write-Host "❌ 未找到微信窗口，请先打开微信后按回车重试..." -ForegroundColor Red
                    }
                    $dummy = (Read-Host).Trim()
                    if ($dummy -eq "b" -or $dummy -eq "back") { $CurrentStep--; break }
                    continue
                }
                if ([WinUtil]::IsIconic($p.MainWindowHandle)) {
                    Write-Host "⚠️ 微信已最小化！请还原后按回车重试..." -ForegroundColor Red
                    $dummy = (Read-Host).Trim()
                    if ($dummy -eq "b" -or $dummy -eq "back") { $CurrentStep--; break }
                    continue
                }

                $result = Show-MarginSliderForm -WindowHandle $p.MainWindowHandle `
                    -InitialMargins $WizardData.Margins `
                    -InitialFocusClick $WizardData.FocusClick
                if ($result.Confirmed) {
                    $WizardData.Margins = $result.Margins
                    if ($result.FocusClick) { $WizardData.FocusClick = $result.FocusClick }
                    $CurrentStep++
                }
                else {
                    $CurrentStep--
                }
            }
            5 {
                Write-WizardStep 5 "系统提示词 (System Prompt)，决定 AI 的说话风格和身份"
                $sys = Ask-Input -Prompt "输入 AI 人设" -DefaultValue $WizardData.SystemPrompt -AllowEmpty $true
                if ($sys -eq "[BACK]") { $CurrentStep--; continue }
                $WizardData.SystemPrompt = if ($sys -eq "") { "你是一个全能助手。" } else { $sys }
                $CurrentStep++
            }
            6 {
                Write-WizardStep 6 "提示音、微信最小化处理、系统通知"
                $beepResult = Show-Menu -Title "是否在回复时播放提示音?" -Options @("是 (播放提示音)", "否 (静音)") -DefaultIndex $(if ($WizardData.BeepOnReply) { 0 } else { 1 })
                if ($beepResult -eq -1) { $CurrentStep--; continue }
                $WizardData.BeepOnReply = ($beepResult -eq 0)

                $minResult = Show-Menu -Title "微信最小化时如何处理?" `
                    -Options @("自动等待 (推荐) - 暂停监听，窗口还原后自动继续",
                    "阻塞提示 - 暂停并等待在此窗口按回车后再继续") `
                    -DefaultIndex $(if ($WizardData.BlockOnMinimized) { 1 } else { 0 })
                if ($minResult -eq -1) { continue }
                $WizardData.BlockOnMinimized = ($minResult -eq 1)

                $notifyResult = Show-Menu -Title "出问题时是否弹出系统通知?" `
                    -Options @("是 (推荐) - 微信关闭/最小化、发送失败、AI 出错等情况在右下角弹通知",
                    "否 - 只在本窗口显示和写日志") `
                    -DefaultIndex $(if ($WizardData.NotifyOnProblem) { 0 } else { 1 })
                if ($notifyResult -eq -1) { continue }
                $WizardData.NotifyOnProblem = ($notifyResult -eq 0)
                $CurrentStep++
            }
            7 {
                Write-WizardStep 7 "AI 回复如何输入到微信"
                $methodResult = Show-Menu -Title "选择发送方式" `
                    -Options @("智能混合 (推荐) - 平时走后台，含 emoji 时自动借用剪贴板",
                    "纯后台注入 - 速度最快，全后台无感 (不支持 emoji)",
                    "纯剪贴板模式 - 最稳，每次都会临时借用剪贴板并切前台") `
                    -DefaultIndex $(switch ($WizardData.SendMethod) { 'WMChar' { 1 } 'Clipboard' { 2 } default { 0 } })
                if ($methodResult -eq -1) { $CurrentStep--; continue }
                switch ($methodResult) {
                    0 { $WizardData.SendMethod = "Hybrid" }
                    1 { $WizardData.SendMethod = "WMChar" }
                    2 { $WizardData.SendMethod = "Clipboard" }
                }
                $CurrentStep++
            }
            8 {
                Write-WizardStep 8 "日志写入 logs\log_日期.txt，出问题时用来排查；聊天内容默认脱敏，只记字数"
                $logDefault = if (-not $WizardData.EnableLogging) { 0 } elseif ($WizardData.LogLevel -eq "DEBUG") { 2 } else { 1 }
                $logResult = Show-Menu -Title "是否记录运行日志?" `
                    -Options @("关闭 - 不写日志文件",
                    "常规日志 (INFO) - 记录收发消息、API 请求、警告和错误",
                    "详细日志 (DEBUG) - 额外记录截图 hash、对焦、发送校验、AI 原始返回等，排查问题用") `
                    -DefaultIndex $logDefault
                if ($logResult -eq -1) { $CurrentStep--; continue }
                switch ($logResult) {
                    0 { $WizardData.EnableLogging = $false; $WizardData.LogLevel = "INFO" }
                    1 { $WizardData.EnableLogging = $true; $WizardData.LogLevel = "INFO" }
                    2 { $WizardData.EnableLogging = $true; $WizardData.LogLevel = "DEBUG" }
                }
                $CurrentStep++
            }
        }
    }
    
    $WizardData.Chat.Remove('IsOllama')
    if (-not $WizardData.Chat.ContainsKey('DeepThinking')) { $WizardData.Chat['DeepThinking'] = $false }
    if (-not $WizardData.Summary.ContainsKey('DeepThinking')) { $WizardData.Summary['DeepThinking'] = $false }
    $finalConf = @{
        Chat                     = $WizardData.Chat
        Summary                  = $WizardData.Summary
        Margins                  = $WizardData.Margins
        SystemPrompt             = $WizardData.SystemPrompt
        BlockOnMinimized         = $WizardData.BlockOnMinimized
        NotifyOnProblem          = $WizardData.NotifyOnProblem   # 出问题时弹出系统通知
        BeepOnReply              = $WizardData.BeepOnReply
        SendMethod               = $WizardData.SendMethod   # WMChar / Hybrid / Clipboard
        EnableLogging            = $WizardData.EnableLogging
        LogLevel                 = $WizardData.LogLevel   # DEBUG / INFO / WARN / ERROR
        LogRetentionDays         = 14          # 日志保留天数，0 表示不清理
        LogRedactContent         = $true       # 正文脱敏开关
        PollingIntervalMs        = 530
        EnableFocusClick         = [bool]$WizardData.FocusClick.Enabled          # 发送前尝试点击输入位置
        InputBoxClickRatioX      = [double]$WizardData.FocusClick.RatioX         # 点击点横向位置（占窗口宽度比例）
        InputBoxOffsetFromBottom = [int]$WizardData.FocusClick.OffsetFromBottom  # 点击点距窗口底部像素
        EnableBlinkGuard         = $true       # 用 hash 回跳规则过滤闪烁
        AbortOnScreenChange      = $true       # 思考期间画面变化时取消请求
        EnableForegroundWait     = $true       # 微信处于前台且近期有操作时等待
        ForegroundIdleSeconds    = 3           # 前台等待的空闲时间阈值（秒）
        EnableReplyDelay         = $false      # 启用回复延迟
        ReplyDelayMinSeconds     = 3           # 随机反应时间下限（秒）
        ReplyDelayMaxSeconds     = 12          # 随机反应时间上限（秒）
        ReplyDelayPerCharMs      = 150         # 每个 UTF-16 代码单元的耗时（毫秒，带 ±30% 抖动）
        ReplyDelayMaxTotalSeconds = 40         # 总延迟封顶（秒，含 AI 思考时间）
        EnableProactive          = $false      # 主动发起：隔一段时间自己判断要不要先发消息（默认关闭）
        ProactiveCheckMinutes    = 15          # 常规检查间隔（分钟，可带 ±30% 抖动）
        ProactiveMinSilenceMinutes = 90        # 聊天画面至少沉默多少分钟才考虑主动发
        ProactiveMaxPerDay       = 3           # 每天最多主动发几条
        ProactiveMaxUnanswered   = 1           # 主动发的消息对方没回时，最多连续发几条（回复后清零）
        ProactiveStartHour       = 9           # 允许主动发消息的时段起点（小时，含）
        ProactiveEndHour         = 22          # 允许主动发消息的时段终点（小时，不含；起点=终点表示全天，起点>终点表示跨午夜）
        ProactiveProbability     = 0.4         # 其他条件通过后，请求主动消息判断的概率
        ProactiveCooldownAfterNoMinutes = 60   # 无合适话题时的检查间隔（分钟）
        EnableUsageTracking      = $true       # 记录每次 AI 请求的 token 用量到 usage\usage_日期.jsonl
        DailyTokenLimit          = 0           # 每日 token 上限（输入+输出），0 表示不限制；达到后暂停自动回复
    }
    # 向导没有涉及的配置项（含手动添加的高级项）沿用旧值，而不是被重置为默认值。
    if ($oldConf) {
        $wizardKeys = @('Chat', 'Summary', 'Margins', 'SystemPrompt', 'BlockOnMinimized', 'NotifyOnProblem', 'BeepOnReply',
            'SendMethod', 'EnableLogging', 'LogLevel', 'EnableFocusClick', 'InputBoxClickRatioX', 'InputBoxOffsetFromBottom')
        foreach ($prop in $oldConf.PSObject.Properties) {
            if ($prop.Name -notin $wizardKeys) { $finalConf[$prop.Name] = $prop.Value }
        }
    }
    $finalConf = [PSCustomObject]$finalConf
    [void](Normalize-Config -Config $finalConf)
    Write-JsonFile -Path $CONFIG_FILE -Value $finalConf
    
    Write-Host ""
    Write-Host "  ✅ 配置已保存到 config.json" -ForegroundColor Green
    Show-ConfigSummary $finalConf
    Write-Host ""
    Write-Host "  📝 MaxTokens、Timeout、随机延迟、主动发起等高级参数，请直接编辑 config.json。" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  按任意键继续（10 秒后自动继续）..." -ForegroundColor DarkGray -NoNewline
    for ($w = 0; $w -lt 100; $w++) {
        try { if ($Host.UI.RawUI.KeyAvailable) { [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); break } } catch { Start-Sleep -Seconds 2; break }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ""
    return $finalConf
}


# 配置标准化函数：统一补默认值、类型转换、范围限制
function Test-ConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Object) { return $false }

    if ($Object -is [hashtable]) {
        return $Object.ContainsKey($Name)
    }

    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-ConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($Object -is [hashtable]) {
        return $Object[$Name]
    }

    return $Object.$Name
}

function Set-ConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Value
    )

    if ($Object -is [hashtable]) {
        $Object[$Name] = $Value
        return
    }

    if (Test-ConfigProperty -Object $Object -Name $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Ensure-ConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $DefaultValue
    )

    if (-not (Test-ConfigProperty -Object $Object -Name $Name)) {
        Set-ConfigProperty -Object $Object -Name $Name -Value $DefaultValue
        return $true
    }

    return $false
}

function Set-IntConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [int] $DefaultValue,
        [Parameter(Mandatory = $true)] [int] $MinValue,
        [Parameter(Mandatory = $true)] [int] $MaxValue
    )

    $changed = $false

    if (-not (Test-ConfigProperty -Object $Object -Name $Name)) {
        Set-ConfigProperty -Object $Object -Name $Name -Value $DefaultValue
        $changed = $true
    }

    $oldValue = Get-ConfigProperty -Object $Object -Name $Name

    $reason = ""
    try {
        $newValue = [int]$oldValue
    }
    catch {
        $newValue = $DefaultValue
        $reason = "不是有效整数，已恢复默认值"
    }

    if ($newValue -lt $MinValue) {
        $newValue = $MinValue
        $reason = "低于下限 $MinValue"
    }
    elseif ($newValue -gt $MaxValue) {
        $newValue = $MaxValue
        $reason = "超过上限 $MaxValue"
    }

    if ([string]$oldValue -ne [string]$newValue) {
        Set-ConfigProperty -Object $Object -Name $Name -Value $newValue
        $changed = $true

        # 对范围修正输出具体字段及原因。
        if ($reason) {
            Write-Host "   ⚠️ 配置项 $Name = $oldValue $reason，已修正为 $newValue" -ForegroundColor Yellow
        }
    }

    return $changed
}
function Set-DoubleConfigProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [double] $DefaultValue,
        [Parameter(Mandatory = $true)] [double] $MinValue,
        [Parameter(Mandatory = $true)] [double] $MaxValue
    )

    $changed = $false

    if (-not (Test-ConfigProperty -Object $Object -Name $Name)) {
        Set-ConfigProperty -Object $Object -Name $Name -Value $DefaultValue
        $changed = $true
    }

    $oldValue = Get-ConfigProperty -Object $Object -Name $Name

    try {
        $newValue = [double]$oldValue
    }
    catch {
        $newValue = $DefaultValue
    }

    if ($newValue -lt $MinValue) {
        $newValue = $MinValue
    }
    elseif ($newValue -gt $MaxValue) {
        $newValue = $MaxValue
    }

    if ([string]$oldValue -ne [string]$newValue) {
        Set-ConfigProperty -Object $Object -Name $Name -Value $newValue
        $changed = $true
    }

    return $changed
}
function Set-BoolConfigProperty {
    param([Parameter(Mandatory)]$Object, [string]$Name, [bool]$DefaultValue)
    $value = Get-ConfigProperty -Object $Object -Name $Name
    if ($value -is [bool]) { return $false }
    $normalized = $DefaultValue
    if ($null -ne $value) {
        switch (([string]$value).Trim().ToLowerInvariant()) {
            'true' { $normalized = $true }
            '1' { $normalized = $true }
            'false' { $normalized = $false }
            '0' { $normalized = $false }
        }
    }
    Set-ConfigProperty -Object $Object -Name $Name -Value $normalized
    return $true
}

function Normalize-Config {
    param(
        [Parameter(Mandatory = $true)] $Config
    )

    if ($Config -isnot [System.Collections.IDictionary] -and $Config -isnot [PSCustomObject]) {
        throw '配置根节点必须是 JSON 对象'
    }
    $changed = $false
    foreach ($name in @('Chat', 'Summary', 'Margins')) {
        $node = Get-ConfigProperty -Object $Config -Name $name
        if ($node -isnot [hashtable] -and $node -isnot [PSCustomObject]) {
            Set-ConfigProperty -Object $Config -Name $name -Value ([PSCustomObject]@{})
            $changed = $true
        }
    }

    # 补全缺失的配置字段。
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'Chat' -DefaultValue ([PSCustomObject]@{})) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'Summary' -DefaultValue ([PSCustomObject]@{})) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'Margins' -DefaultValue ([PSCustomObject]@{ Left = 360; Right = 30; Top = 85; Bottom = 165 })) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'SystemPrompt' -DefaultValue '你是一个全能助手。') -or $changed

    $chat = Get-ConfigProperty -Object $Config -Name 'Chat'
    $summary = Get-ConfigProperty -Object $Config -Name 'Summary'

    $margins = Get-ConfigProperty -Object $Config -Name 'Margins'

    if ($null -eq $margins) {
        $margins = [PSCustomObject]@{ Left = 360; Right = 30; Top = 85; Bottom = 165 }
        Set-ConfigProperty -Object $Config -Name 'Margins' -Value $margins
        $changed = $true
    }

    $changed = (Set-IntConfigProperty -Object $margins -Name 'Left'   -DefaultValue 360 -MinValue 0 -MaxValue 5000) -or $changed
    $changed = (Set-IntConfigProperty -Object $margins -Name 'Right'  -DefaultValue 30  -MinValue 0 -MaxValue 5000) -or $changed
    $changed = (Set-IntConfigProperty -Object $margins -Name 'Top'    -DefaultValue 85  -MinValue 0 -MaxValue 5000) -or $changed
    $changed = (Set-IntConfigProperty -Object $margins -Name 'Bottom' -DefaultValue 165 -MinValue 0 -MaxValue 5000) -or $changed

    $changed = (Set-IntConfigProperty -Object $Config -Name 'HistoryContextMaxEntries' -DefaultValue 50 -MinValue 1 -MaxValue 1000) -or $changed

    $changed = (Ensure-ConfigProperty -Object $Config -Name 'BlockOnMinimized' -DefaultValue $false) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'NotifyOnProblem' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'BeepOnReply' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'SendMethod' -DefaultValue 'Hybrid') -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableLogging' -DefaultValue $false) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'LogLevel' -DefaultValue 'INFO') -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'LogRedactContent' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'PollingIntervalMs' -DefaultValue 530) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableFocusClick' -DefaultValue $false) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'InputBoxClickRatioX' -DefaultValue 0.65) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'InputBoxOffsetFromBottom' -DefaultValue 50) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableBlinkGuard' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'AbortOnScreenChange' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableUsageTracking' -DefaultValue $true) -or $changed
    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableForegroundWait' -DefaultValue $true) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ForegroundIdleSeconds' -DefaultValue 3 -MinValue 1 -MaxValue 600) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'DailyTokenLimit' -DefaultValue 0 -MinValue 0 -MaxValue 2000000000) -or $changed

    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableReplyDelay' -DefaultValue $false) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ReplyDelayMinSeconds' -DefaultValue 3 -MinValue 0 -MaxValue 600) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ReplyDelayMaxSeconds' -DefaultValue 12 -MinValue 0 -MaxValue 600) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ReplyDelayPerCharMs' -DefaultValue 150 -MinValue 0 -MaxValue 5000) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ReplyDelayMaxTotalSeconds' -DefaultValue 40 -MinValue 1 -MaxValue 1800) -or $changed
    $delayMin = [int](Get-ConfigProperty -Object $Config -Name 'ReplyDelayMinSeconds')
    $delayMax = [int](Get-ConfigProperty -Object $Config -Name 'ReplyDelayMaxSeconds')
    if ($delayMin -gt $delayMax) {
        Set-ConfigProperty -Object $Config -Name 'ReplyDelayMinSeconds' -Value $delayMax
        Set-ConfigProperty -Object $Config -Name 'ReplyDelayMaxSeconds' -Value $delayMin
        Write-Host "   ⚠️ 配置项 ReplyDelayMinSeconds = $delayMin 大于 ReplyDelayMaxSeconds = $delayMax，已自动交换" -ForegroundColor Yellow
        $changed = $true
    }

    $changed = (Ensure-ConfigProperty -Object $Config -Name 'EnableProactive' -DefaultValue $false) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveCheckMinutes' -DefaultValue 15 -MinValue 1 -MaxValue 1440) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveMinSilenceMinutes' -DefaultValue 90 -MinValue 1 -MaxValue 10080) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveMaxPerDay' -DefaultValue 3 -MinValue 1 -MaxValue 100) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveMaxUnanswered' -DefaultValue 1 -MinValue 1 -MaxValue 10) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveStartHour' -DefaultValue 9 -MinValue 0 -MaxValue 23) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveEndHour' -DefaultValue 22 -MinValue 0 -MaxValue 24) -or $changed
    $changed = (Set-DoubleConfigProperty -Object $Config -Name 'ProactiveProbability' -DefaultValue 0.4 -MinValue 0 -MaxValue 1) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'ProactiveCooldownAfterNoMinutes' -DefaultValue 60 -MinValue 1 -MaxValue 1440) -or $changed

    if ((Get-ConfigProperty -Object $Config -Name 'SendMethod') -notin @('WMChar', 'Hybrid', 'Clipboard')) {
        Set-ConfigProperty -Object $Config -Name 'SendMethod' -Value 'Hybrid'
        $changed = $true
    }
    if ((Get-ConfigProperty -Object $Config -Name 'LogLevel') -notin @('DEBUG', 'INFO', 'WARN', 'ERROR')) {
        Set-ConfigProperty -Object $Config -Name 'LogLevel' -Value 'INFO'
        $changed = $true
    }
    $changed = (Set-IntConfigProperty -Object $Config -Name 'LogRetentionDays' -DefaultValue 14 -MinValue 0 -MaxValue 3650) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'PollingIntervalMs' -DefaultValue 530 -MinValue 100 -MaxValue 10000) -or $changed
    $changed = (Set-DoubleConfigProperty -Object $Config -Name 'InputBoxClickRatioX' -DefaultValue 0.65 -MinValue 0.05 -MaxValue 0.95) -or $changed
    $changed = (Set-IntConfigProperty -Object $Config -Name 'InputBoxOffsetFromBottom' -DefaultValue 50 -MinValue 0 -MaxValue 1000) -or $changed

    $changed = (Ensure-ConfigProperty -Object $chat -Name 'DeepThinking' -DefaultValue $false) -or $changed
    $changed = (Set-IntConfigProperty -Object $chat -Name 'MaxTokens' -DefaultValue 1024 -MinValue 1 -MaxValue 200000) -or $changed
    $changed = (Set-IntConfigProperty -Object $chat -Name 'TimeoutSeconds' -DefaultValue 60 -MinValue 1 -MaxValue 600) -or $changed

    # 额外重试次数范围为 0–5；未知发送状态走停止重发分支。
    $changed = (Set-IntConfigProperty -Object $chat -Name 'AbnormalResponseMaxRetry' -DefaultValue 2 -MinValue 0 -MaxValue 5) -or $changed
    $changed = (Set-IntConfigProperty -Object $chat -Name 'SendFailureMaxRetry' -DefaultValue 2 -MinValue 0 -MaxValue 5) -or $changed

    $changed = (Ensure-ConfigProperty -Object $summary -Name 'enabled' -DefaultValue $false) -or $changed
    $changed = (Set-IntConfigProperty -Object $summary -Name 'triggerCount' -DefaultValue 15 -MinValue 1 -MaxValue 10000) -or $changed
    $changed = (Set-IntConfigProperty -Object $summary -Name 'retainCount' -DefaultValue 5 -MinValue 0 -MaxValue 9999) -or $changed

    # retainCount 必须小于 triggerCount，确保每次总结能压缩至少一条历史。
    $trigVal = [int](Get-ConfigProperty -Object $summary -Name 'triggerCount')
    $keepVal = [int](Get-ConfigProperty -Object $summary -Name 'retainCount')
    if ($keepVal -ge $trigVal) {
        $fixedKeep = $trigVal - 1
        Set-ConfigProperty -Object $summary -Name 'retainCount' -Value $fixedKeep
        Write-Host "   ⚠️ 配置项 retainCount = $keepVal 不小于 triggerCount = $trigVal，总结将无法生效，已修正为 $fixedKeep" -ForegroundColor Yellow
        $changed = $true
    }
    $changed = (Ensure-ConfigProperty -Object $summary -Name 'DeepThinking' -DefaultValue $false) -or $changed
    $changed = (Set-IntConfigProperty -Object $summary -Name 'MaxTokens' -DefaultValue 1024 -MinValue 1 -MaxValue 200000) -or $changed
    $changed = (Set-IntConfigProperty -Object $summary -Name 'TimeoutSeconds' -DefaultValue 60 -MinValue 1 -MaxValue 600) -or $changed

    $booleanDefaults = @{
        BlockOnMinimized = $false; NotifyOnProblem = $true; BeepOnReply = $true
        EnableLogging = $false; LogRedactContent = $true; EnableFocusClick = $false
        EnableBlinkGuard = $true; AbortOnScreenChange = $true; EnableUsageTracking = $true
        EnableForegroundWait = $true; EnableReplyDelay = $false; EnableProactive = $false
    }
    foreach ($name in $booleanDefaults.Keys) {
        $changed = (Set-BoolConfigProperty -Object $Config -Name $name -DefaultValue $booleanDefaults[$name]) -or $changed
    }
    $changed = (Set-BoolConfigProperty -Object $chat -Name 'DeepThinking' -DefaultValue $false) -or $changed
    $changed = (Set-BoolConfigProperty -Object $summary -Name 'DeepThinking' -DefaultValue $false) -or $changed
    $changed = (Set-BoolConfigProperty -Object $summary -Name 'enabled' -DefaultValue $false) -or $changed
    return $changed
}

# 记忆总结：节流读取历史，生成摘要后分别原子保存摘要和近期历史。
function Update-MemorySummary {
    param($Config)
    if (-not $Config.Summary.enabled) { return }
    if (([DateTime]::Now - $script:LastSummaryAttempt).TotalSeconds -lt 60) { return }
    if ($script:LastSummaryScan -and ([DateTime]::Now - $script:LastSummaryScan).TotalSeconds -lt 5) { return }
    $script:LastSummaryScan = [DateTime]::Now

    if (-not (Test-Path -LiteralPath $HISTORY_FILE)) {
        Write-AtomicText -Path $HISTORY_FILE -Text '[]'
        return
    }

    try {
        $historyText = Get-Content -LiteralPath $HISTORY_FILE -Raw -Encoding UTF8 -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($historyText)) {
            $histRaw = @()
        }
        else {
            $histRaw = $historyText | ConvertFrom-Json -ErrorAction Stop
            $histRaw = @($histRaw)
        }
    }
    catch {
        Write-AppLog "读取历史记录失败，已重置 chat_history.json：$($_.Exception.Message)" "WARN"

        $backupFile = "$HISTORY_FILE.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        try {
            Copy-Item -LiteralPath $HISTORY_FILE $backupFile -ErrorAction SilentlyContinue
            Write-AppLog "损坏的历史记录已备份到：$backupFile" "WARN"
        }
        catch {}

        Write-AtomicText -Path $HISTORY_FILE -Text '[]'
        return
    }

    $trig = [int]$Config.Summary.triggerCount
    $keep = [int]$Config.Summary.retainCount

    if ($histRaw.Count -lt $trig) { return }

    $endIdx = $histRaw.Count - $keep - 1
    if ($endIdx -lt 0) { return }

    if (([DateTime]::Now - $script:LastSummaryAttempt).TotalSeconds -lt 60) { return }

    if (Test-DailyTokenLimitReached) { return }

    $script:LastSummaryAttempt = [DateTime]::Now

    Write-Log "🧠 [记忆整理] 正在压缩长期记忆..." DarkGray
    Write-AppLog "记忆整理触发 → 历史消息数=$($histRaw.Count), 触发阈值=$trig, 保留近期=$keep" "INFO"

    $oldSum = if (Test-Path -LiteralPath $SUMMARY_FILE) { Get-Content -LiteralPath $SUMMARY_FILE -Raw -Encoding UTF8 } else { "" }
    $toSum = ConvertTo-Json -InputObject @($histRaw[0..$endIdx]) -Depth 5 -Compress
    if ([string]::IsNullOrWhiteSpace($oldSum)) { $oldSum = "（暂无）" }
    $todayText = Get-Date -Format 'yyyy-MM-dd'

    # 摘要要求只输出记忆正文；返回内容优先从 <memory> 标签提取。
    $summarySystemPrompt = @"
你是一个对话记忆整理助手，负责维护一份关于聊天对象的长期记忆。
这份记忆会在之后每次聊天时提供给回复助手作为背景，所以只需保留对后续聊天有用的信息。
"@

    $summaryPrompt = @"
请把【新增对话】中有价值的信息合并进【旧记忆】，输出一份更新后的完整长期记忆。

整理要求：
1. 保留：对方的称呼、身份、喜好、习惯、近况，双方的约定、待办事项、未结束的话题，以及聊天中形成的称呼或说话风格。
2. 舍弃：寒暄、"嗯""好的""哈哈"之类的无信息内容，已经结束且不会再提的琐事。
3. 新信息与旧记忆冲突时，以新信息为准；涉及时间的事项尽量写明日期（今天是 $todayText）。
4. 用简洁的中文条目书写，每条一行，以"- "开头，可以按主题分组。
5. 全文控制在 600 字以内；超出时优先删除最旧、最不重要的内容。

对话数据说明：
- 每条记录中 user 是对方发的消息，ai 是你（我方）发出的回复，time 是记录时间。
- ai 为 __NO_REPLY__ 表示当时判断无需回复，没有发送任何消息。
- ai 以 [发送失败，已放弃重试] 开头表示这条回复实际没有发出去，对方没有看到。
- ai 以 [发送状态未知，已停止重试] 开头表示尝试发送过但未确认，请以截图为准，不要假定已送达。
- user 为 __PROACTIVE__ 表示这条是我方主动发起的消息（当时对方并没有发消息），ai 是我方主动发出的内容；对方后来有没有回应，要看后面的记录。

输出格式：只输出更新后的记忆，放在 <memory></memory> 标签内，标签外不要输出任何解释或说明。

【旧记忆】:
$oldSum

【新增对话】:
$toSum
"@
    if ($Config.Summary.DeepThinking) {
        $summarySystemPrompt += " 请进行深度思考，仔细整合，确保总结准确且保留关键信息。"
    }

    $summaryTruncated = $false
    try {
        $newSum = Invoke-AICompletion -ProviderType $Config.Summary.ProviderType `
            -ApiUrl $Config.Summary.ApiUrl `
            -ApiKey $Config.Summary.ApiKey `
            -Model $Config.Summary.Model `
            -Messages @($summaryPrompt) `
            -MaxTokens $Config.Summary.MaxTokens `
            -TimeoutSeconds $Config.Summary.TimeoutSeconds `
            -SystemPrompt $summarySystemPrompt `
            -DeepThinking ([bool]$Config.Summary.DeepThinking) `
            -UsagePurpose "Summary"

        # 截断响应不更新摘要或历史，避免保存残缺记忆。
        if ($newSum -and $script:LastUsage -and $script:LastUsage.Truncated) {
            Write-Log "⚠️ [记忆整理] AI 回复被截断，本次不更新记忆（可调大 config.json 中 Summary.MaxTokens）" Yellow
            Write-AppLog "记忆整理：回复因 MaxTokens 被截断，跳过更新，避免写入残缺记忆 → Output=$($script:LastUsage.Output)" "WARN"
            $newSum = $null
            $summaryTruncated = $true
        }

        # 优先提取最后一组 <memory>；缺少标签时按原文保存。
        if ($newSum) {
            $memMatches = [regex]::Matches($newSum, "(?is)<memory>(.*?)</memory>")
            if ($memMatches.Count -gt 0) {
                $newSum = $memMatches[$memMatches.Count - 1].Groups[1].Value.Trim()
            }
            else {
                Write-AppLog "记忆整理：返回内容缺少 <memory> 标签，按原文保存" "WARN"
                $newSum = $newSum.Trim()
            }
        }

        if ($newSum) {
            Write-AtomicText -Path $SUMMARY_FILE -Text $newSum
            if ($keep -le 0) {
                Write-AtomicText -Path $HISTORY_FILE -Text '[]'
            }
            else {
                $keep = [Math]::Min($keep, $histRaw.Count)

                $startIdx = $histRaw.Count - $keep
                $recentHistory = @($histRaw[$startIdx..($histRaw.Count - 1)])

                Write-JsonFile -Path $HISTORY_FILE -Value @($recentHistory) -Depth 5
            }
            Write-Log "✅ 记忆更新完成。" Green
            Write-AppLog "记忆整理完成 ← 新摘要长度=$($newSum.Length) chars, 历史已截断为最近 $keep 条" "INFO"
            $script:LastSummaryAttempt = [DateTime]::Now
        }
        elseif (-not $summaryTruncated) {
            Write-AppLog "记忆整理：AI 返回空内容，跳过更新" "WARN"
        }
    }
    catch {
        Write-Log "❌ 记忆整理失败 (10秒后重试): $_" Red
        Write-AppLog "记忆整理失败：$($_.Exception.Message)" "ERROR"
        $script:LastSummaryAttempt = [DateTime]::Now.AddSeconds(-50)
    }
}

# 控制台状态行初始状态。
$script:SpinChars = @('|', '/', '-', '\')
$script:SpinIdx = 0
$script:CurrentMode = "Listening"
$script:SpinnerVisible = $false
# 启动界面与配置入口。

# Logo 按检测到的终端能力选择 ANSI 真彩色或 ConsoleColor。
$script:WebotLogo = @(
    '  ██╗    ██╗███████╗██████╗  ██████╗ ████████╗'
    '  ██║    ██║██╔════╝██╔══██╗██╔═══██╗╚══██╔══╝'
    '  ██║ █╗ ██║█████╗  ██████╔╝██║   ██║   ██║   '
    '  ██║███╗██║██╔══╝  ██╔══██╗██║   ██║   ██║   '
    '  ╚███╔███╔╝███████╗██████╔╝╚██████╔╝   ██║   '
    '   ╚══╝╚══╝ ╚══════╝╚═════╝  ╚═════╝    ╚═╝   '
)

function Test-AnsiColorSupport {
    try {
        if ($env:NO_COLOR) { return $false }
        if ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode' -or $env:COLORTERM -match 'truecolor|24bit') { return $true }
        if ($Host.UI.PSObject.Properties['SupportsVirtualTerminal'] -and $Host.UI.SupportsVirtualTerminal) { return $true }
    }
    catch {}
    return $false
}

function Show-WebotLogo {
    $stops = @(@(134, 239, 172), @(7, 193, 96), @(20, 184, 166))
    $logo = $script:WebotLogo
    Write-Host ""

    if (Test-AnsiColorSupport) {
        $esc = [char]27
        $maxLen = ($logo | Measure-Object -Property Length -Maximum).Maximum
        foreach ($row in $logo) {
            $sb = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $row.Length; $i++) {
                $ch = $row[$i]
                if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
                $t = if ($maxLen -gt 1) { $i / ($maxLen - 1) } else { 0 }
                if ($t -le 0.5) { $a = $stops[0]; $b = $stops[1]; $k = $t * 2 }
                else            { $a = $stops[1]; $b = $stops[2]; $k = ($t - 0.5) * 2 }
                $r  = [int]($a[0] + ($b[0] - $a[0]) * $k)
                $g  = [int]($a[1] + ($b[1] - $a[1]) * $k)
                $bl = [int]($a[2] + ($b[2] - $a[2]) * $k)
                if ($ch -ne [char]0x2588) { $r = [int]($r * 0.45); $g = [int]($g * 0.45); $bl = [int]($bl * 0.45) }
                [void]$sb.Append("$esc[38;2;$r;$g;${bl}m$ch")
            }
            [void]$sb.Append("$esc[0m")
            Write-Host $sb.ToString()
        }
    }
    else {
        $colors = @('Green', 'Green', 'Green', 'DarkGreen', 'DarkCyan', 'DarkCyan')
        for ($i = 0; $i -lt $logo.Count; $i++) {
            Write-Host $logo[$i] -ForegroundColor $colors[$i % $colors.Count]
        }
    }
    Write-Host ""
}

function Show-Banner {
    param($CountDown = $null)
    Clear-Host
    Show-WebotLogo
    Write-Host "  🤖 微信 AI 助手 · WEBOT v1.0" -ForegroundColor Cyan -NoNewline
    Write-Host "   WeChat Copilot" -ForegroundColor DarkGray

    if (Test-Path -LiteralPath $CONFIG_FILE) {
        Write-SectionTitle "配置"
        Write-InfoRow "文件" "config.json" White "高级设置（超时、窗口阻塞、Token 上限等）请直接编辑此文件"
        if ($CONFIG) {
            if ($CONFIG.PSObject.Properties['EnableLogging'] -and $CONFIG.EnableLogging) {
                $lv = if ($CONFIG.PSObject.Properties['LogLevel']) { $CONFIG.LogLevel } else { "INFO" }
                Write-InfoRow "日志" "已开启 ($lv)" White "logs\"
            }
            else {
                Write-InfoRow "日志" "未开启" DarkGray "可在配置向导 [C] 或 config.json 的 EnableLogging 中开启"
            }
        }

        if ($CountDown) {
            Write-Host ""
            Write-Host "  [C] " -NoNewline -ForegroundColor Green
            Write-Host "重新配置向导     " -NoNewline -ForegroundColor White
            Write-Host "[Enter] " -NoNewline -ForegroundColor Green
            Write-Host "立即启动" -ForegroundColor White
            Write-Host ""
        }
    }
}

$enteredWizard = $false

# 校准模式：只打开截图区域校准窗口，结果合并写回 config.json。
function Invoke-GuiCalibration {
    $cfg = $null
    if (Test-Path -LiteralPath $CONFIG_FILE) {
        try { $cfg = Get-Content -LiteralPath $CONFIG_FILE -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch {
            Write-Host "❌ config.json 解析失败：$($_.Exception.Message)" -ForegroundColor Red
            return 4
        }
    }
    if ($cfg -isnot [PSCustomObject]) { $cfg = [PSCustomObject]@{} }
    $script:CONFIG = $cfg

    $wechatProcesses = @(Get-Process -Name "WeChat", "Weixin" -ErrorAction SilentlyContinue)
    $p = $wechatProcesses | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -ne "" } | Select-Object -First 1
    if (-not $p -or [WinUtil]::IsIconic($p.MainWindowHandle)) {
        if ($wechatProcesses.Count -gt 0) { Write-Host "⚠️ 微信已最小化或隐藏到托盘，请还原微信窗口后再校准。" -ForegroundColor Yellow }
        else { Write-Host "❌ 未找到微信窗口，请先打开并登录微信。" -ForegroundColor Red }
        return 3
    }

    $margins = @{ Left = 360; Right = 30; Top = 85; Bottom = 165 }
    if ($cfg.PSObject.Properties['Margins'] -and $cfg.Margins) {
        foreach ($k in @("Left", "Right", "Top", "Bottom")) {
            try { if ($null -ne $cfg.Margins.$k) { $margins[$k] = [int]$cfg.Margins.$k } } catch {}
        }
    }
    $focus = @{ Enabled = $false; RatioX = 0.65; OffsetFromBottom = 50 }
    try { if ($null -ne $cfg.EnableFocusClick) { $focus.Enabled = [bool]$cfg.EnableFocusClick } } catch {}
    try { if ($null -ne $cfg.InputBoxClickRatioX) { $focus.RatioX = [double]$cfg.InputBoxClickRatioX } } catch {}
    try { if ($null -ne $cfg.InputBoxOffsetFromBottom) { $focus.OffsetFromBottom = [int]$cfg.InputBoxOffsetFromBottom } } catch {}

    $result = Show-MarginSliderForm -WindowHandle $p.MainWindowHandle -InitialMargins $margins -InitialFocusClick $focus
    if (-not $result.Confirmed) {
        Write-Host "已取消校准，配置未修改。" -ForegroundColor DarkGray
        return 1
    }
    Set-ConfigProperty -Object $cfg -Name 'Margins' -Value ([PSCustomObject]$result.Margins)
    if ($result.FocusClick) {
        Set-ConfigProperty -Object $cfg -Name 'EnableFocusClick' -Value ([bool]$result.FocusClick.Enabled)
        Set-ConfigProperty -Object $cfg -Name 'InputBoxClickRatioX' -Value ([double]$result.FocusClick.RatioX)
        Set-ConfigProperty -Object $cfg -Name 'InputBoxOffsetFromBottom' -Value ([int]$result.FocusClick.OffsetFromBottom)
    }
    Write-JsonFile -Path $CONFIG_FILE -Value $cfg
    Write-Host "✅ 截图区域已保存到 config.json" -ForegroundColor Green
    Send-GuiMessage 'CALIBRATED'
    return 0
}

if ($Calibrate) {
    $calibCode = Invoke-GuiCalibration
    exit $calibCode
}

if ($script:GuiMode) {
    # 图形界面负责配置，引擎不进入控制台向导。
    if (-not (Test-Path -LiteralPath $CONFIG_FILE)) {
        Write-Host "❌ 未找到 config.json，请先在图形界面的「设置」中完成配置。" -ForegroundColor Red
        exit 2
    }
}
elseif (-not (Test-Path -LiteralPath $CONFIG_FILE)) {
    # 无配置文件时直接进入向导。
    Write-Host "检测到初次运行，正在进入配置向导..." -ForegroundColor Cyan
    Start-Sleep -Milliseconds 500
    $CONFIG = Show-WelcomeWizard
    $enteredWizard = $true
}
else {
    # 有配置文件时提供 3 秒配置入口等待时间。
    Show-Banner -CountDown $true
    
    $timeout  = 30
    $barWidth = 24
    $keyPressed = $false

    function Draw-StartupBar([int]$step) {
        $ratio   = [math]::Min(1.0, $step / $timeout)
        $filled  = [int][math]::Round($ratio * $barWidth)
        $percent = [int][math]::Round($ratio * 100)
        $remain  = [math]::Max(0, ($timeout - $step) / 10.0)

        Write-Host "`r  自动启动 " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,3:0.0}s " -f $remain) -NoNewline -ForegroundColor Yellow
        Write-Host ("━" * $filled) -NoNewline -ForegroundColor Green
        Write-Host ("─" * ($barWidth - $filled)) -NoNewline -ForegroundColor DarkGray
        Write-Host (" {0,3}%   " -f $percent) -NoNewline -ForegroundColor DarkGray
    }

    # 倒计时期间隐藏光标，避免每次 `r 重绘时光标在行首/行尾来回跳动。
    try { [Console]::CursorVisible = $false } catch {}

    for ($i = 0; $i -le $timeout; $i++) {
        Draw-StartupBar $i

        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.Character -eq 'c' -or $key.Character -eq 'C') {
                Write-Host ""
                # 进入配置向导需要输入，恢复光标显示。
                try { [Console]::CursorVisible = $true } catch {}
                $CONFIG = Show-WelcomeWizard
                $enteredWizard = $true
                $keyPressed = $true
                break
            }
            if ($key.VirtualKeyCode -eq 13) {
                Draw-StartupBar $timeout
                $keyPressed = $true
                break
            }
        }
        if ($i -lt $timeout) { Start-Sleep -Milliseconds 100 }
    }
    Write-Host ""
}
# 主动消息：启用后按时段、沉默时长、次数与概率筛选，再请求模型判断。
# 仅在画面匹配 Last_Hash 时考虑发送，发送前再次复核；hash 不验证聊天对象身份。
# 次数保存在 proactive_state.json；发送状态未知时停用到重启。
$PROACTIVE_STATE_FILE = Join-Path $PSScriptRoot "proactive_state.json"
$script:ProactiveRandom = New-Object System.Random
$script:ProactiveState = $null
$script:ProactiveNextCheckAt = [DateTime]::MinValue
$script:ProactiveFailStreak = 0
$script:ProactiveDisabled = $false
$script:LastChatActivityAt = Get-Date   # 最近观察到聊天画面变化的时间，启动时以当前时间初始化。

function Test-ProactiveEnabled {
    if (-not $CONFIG -or -not $CONFIG.PSObject.Properties['EnableProactive']) { return $false }
    return [bool]$CONFIG.EnableProactive
}

# 读取主动消息参数，并为缺失字段提供回退值。
function Get-ProactiveSettings {
    $s = [PSCustomObject]@{
        CheckMinutes           = 15
        MinSilenceMinutes      = 90
        MaxPerDay              = 3
        MaxUnanswered          = 1
        StartHour              = 9
        EndHour                = 22
        Probability            = 0.4
        CooldownAfterNoMinutes = 60
    }
    if (-not $CONFIG) { return $s }
    try {
        if ($CONFIG.PSObject.Properties['ProactiveCheckMinutes']) { $s.CheckMinutes = [Math]::Max(1, [int]$CONFIG.ProactiveCheckMinutes) }
        if ($CONFIG.PSObject.Properties['ProactiveMinSilenceMinutes']) { $s.MinSilenceMinutes = [Math]::Max(1, [int]$CONFIG.ProactiveMinSilenceMinutes) }
        if ($CONFIG.PSObject.Properties['ProactiveMaxPerDay']) { $s.MaxPerDay = [Math]::Max(1, [int]$CONFIG.ProactiveMaxPerDay) }
        if ($CONFIG.PSObject.Properties['ProactiveMaxUnanswered']) { $s.MaxUnanswered = [Math]::Max(1, [int]$CONFIG.ProactiveMaxUnanswered) }
        if ($CONFIG.PSObject.Properties['ProactiveStartHour']) { $s.StartHour = [Math]::Min(23, [Math]::Max(0, [int]$CONFIG.ProactiveStartHour)) }
        if ($CONFIG.PSObject.Properties['ProactiveEndHour']) { $s.EndHour = [Math]::Min(24, [Math]::Max(0, [int]$CONFIG.ProactiveEndHour)) }
        if ($CONFIG.PSObject.Properties['ProactiveProbability']) { $s.Probability = [Math]::Min(1.0, [Math]::Max(0.0, [double]$CONFIG.ProactiveProbability)) }
        if ($CONFIG.PSObject.Properties['ProactiveCooldownAfterNoMinutes']) { $s.CooldownAfterNoMinutes = [Math]::Max(1, [int]$CONFIG.ProactiveCooldownAfterNoMinutes) }
    }
    catch {
        Write-AppLog "读取主动发起配置出错，部分参数使用默认值：$($_.Exception.Message)" "WARN"
    }
    return $s
}

function Save-ProactiveState {
    if ($null -eq $script:ProactiveState) { return }
    try {
        Write-JsonFile -Path $PROACTIVE_STATE_FILE -Value $script:ProactiveState
    }
    catch {
        Write-AppLog "写入主动发起状态失败：$($_.Exception.Message)" "WARN"
    }
}

# 跨天仅重置今日已发条数，保留连续未回复计数。
function Sync-ProactiveDay {
    if ($null -eq $script:ProactiveState) { return }
    $today = Get-Date -Format 'yyyyMMdd'
    if ($script:ProactiveState.date -ne $today) {
        $script:ProactiveState.date = $today
        $script:ProactiveState.sentToday = 0
        Save-ProactiveState
    }
}

function Initialize-ProactiveState {
    $script:LastChatActivityAt = Get-Date
    $script:ProactiveNextCheckAt = [DateTime]::MinValue
    $script:ProactiveFailStreak = 0
    $script:ProactiveDisabled = $false

    $state = [PSCustomObject]@{
        date            = (Get-Date -Format 'yyyyMMdd')
        sentToday       = 0
        unanswered      = 0
        lastProactiveAt = ""
    }
    if (Test-Path -LiteralPath $PROACTIVE_STATE_FILE) {
        try {
            $raw = Get-Content -LiteralPath $PROACTIVE_STATE_FILE -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($obj.PSObject.Properties['date']) { $state.date = [string]$obj.date }
                if ($obj.PSObject.Properties['sentToday']) { $state.sentToday = [int]$obj.sentToday }
                if ($obj.PSObject.Properties['unanswered']) { $state.unanswered = [int]$obj.unanswered }
                if ($obj.PSObject.Properties['lastProactiveAt']) { $state.lastProactiveAt = [string]$obj.lastProactiveAt }
            }
        }
        catch {
            Write-AppLog "主动发起状态文件读取失败，按初始状态处理：$($_.Exception.Message)" "WARN"
        }
    }
    $script:ProactiveState = $state
    Sync-ProactiveDay
}

# 主循环识别到对方新消息时，清零主动消息未回复计数。
function Reset-ProactiveUnanswered {
    if ($null -eq $script:ProactiveState) { return }
    if ($script:ProactiveState.unanswered -gt 0) {
        $script:ProactiveState.unanswered = 0
        Save-ProactiveState
        Write-AppLog "对方有新消息，主动发起的连续未回复计数已清零" "DEBUG"
    }
}

# 当前小时是否在允许主动发消息的时段内（Start = End 表示全天；Start > End 表示跨午夜）
function Test-ProactiveActiveHour {
    param([int]$StartHour, [int]$EndHour)
    $h = (Get-Date).Hour
    if ($StartHour -eq $EndHour) { return $true }
    if ($StartHour -lt $EndHour) { return ($h -ge $StartHour -and $h -lt $EndHour) }
    return ($h -ge $StartHour -or $h -lt $EndHour)
}

# Jitter 开启时，对检查间隔添加 ±30% 抖动。
function Set-ProactiveNextCheck {
    param(
        [double]$Minutes,
        [bool]$Jitter = $true
    )
    $m = $Minutes
    if ($Jitter) { $m = $Minutes * (0.7 + $script:ProactiveRandom.NextDouble() * 0.6) }
    $script:ProactiveNextCheckAt = (Get-Date).AddMinutes($m)
}

function Invoke-ProactiveCheck {
    <#
        主循环在画面匹配 Last_Hash 时调用；检查未到期则立即返回。
        满足筛选条件后请求模型，复核画面并尝试发送，视觉校验通过后更新监听基准。
        此函数不向成功输出流返回数据。
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][string]$CurrentHash,
        [Parameter(Mandatory)][byte[]]$ImageBytes,
        [int]$MarginLeft, [int]$MarginTop, [int]$CropWidth, [int]$CropHeight
    )

    if (-not (Test-ProactiveEnabled)) { return }
    if ($script:ProactiveDisabled -or $null -eq $script:ProactiveState) { return }
    if ([DateTime]::Now -lt $script:ProactiveNextCheckAt) { return }
    if ([string]::IsNullOrWhiteSpace($CurrentHash)) { return }

    $cfg = Get-ProactiveSettings

    try {
        Sync-ProactiveDay
        $st = $script:ProactiveState
        $now = Get-Date
        $silenceMin = ($now - $script:LastChatActivityAt).TotalMinutes

        # 主动消息的时间、次数、空闲状态与概率筛选。
        $gate = ""
        $retryMin = [double]$cfg.CheckMinutes
        $jitter = $true

        if (-not (Test-ProactiveActiveHour -StartHour $cfg.StartHour -EndHour $cfg.EndHour)) {
            $gate = "当前不在允许的时段（{0}:00-{1}:00）" -f $cfg.StartHour, $cfg.EndHour
        }
        elseif ($st.unanswered -ge $cfg.MaxUnanswered) {
            $gate = "上一条主动消息对方还没回复（{0}/{1}）" -f $st.unanswered, $cfg.MaxUnanswered
        }
        elseif ($st.sentToday -ge $cfg.MaxPerDay) {
            $gate = "今日主动消息已达上限（{0}/{1}）" -f $st.sentToday, $cfg.MaxPerDay
            $retryMin = [Math]::Max([double]$cfg.CheckMinutes, 30.0)
        }
        elseif ($silenceMin -lt $cfg.MinSilenceMinutes) {
            $gate = "聊天沉默时间不够（{0:0} / {1} 分钟）" -f $silenceMin, $cfg.MinSilenceMinutes
            $retryMin = [Math]::Max(1.0, ($cfg.MinSilenceMinutes - $silenceMin))
            $jitter = $false
        }
        elseif (Test-DailyTokenLimitReached) {
            $gate = "今日 token 已达上限"
            $retryMin = [Math]::Max([double]$cfg.CheckMinutes, 30.0)
        }
        elseif ($script:BadAiCooldownUntil -gt $now) {
            $gate = "AI 连续异常冷却中"
            $retryMin = 5.0
            $jitter = $false
        }
        elseif (Test-UserBusyInWeChat -WindowHandle $WindowHandle -IdleMs 30000) {
            $gate = "你正在使用微信"
            $retryMin = 2.0
            $jitter = $false
        }
        elseif ($script:ProactiveRandom.NextDouble() -ge $cfg.Probability) {
            $gate = "本轮随机概率未命中（p={0:0.##}）" -f $cfg.Probability
        }

        if ($gate) {
            Write-AppLog ("主动发起：闸门未通过 → {0}；约 {1:0.#} 分钟后再看" -f $gate, $retryMin) "DEBUG"
            Set-ProactiveNextCheck -Minutes $retryMin -Jitter $jitter
            return
        }

        # 请求模型判断是否生成主动消息。
        $silenceInt = [int][Math]::Round($silenceMin)
        $silenceText = if ($silenceInt -ge 60) {
            "{0} 小时 {1} 分钟" -f [int][Math]::Floor($silenceInt / 60), ($silenceInt % 60)
        }
        else {
            "$silenceInt 分钟"
        }

        $historyData = "[]"
        try {
            if (Test-Path -LiteralPath $HISTORY_FILE) {
                $h = Get-Content -LiteralPath $HISTORY_FILE -Raw -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($h)) { $historyData = $h }
            }
        }
        catch {
            Write-AppLog "主动发起：读取近期对话失败，已使用空历史：$($_.Exception.Message)" "WARN"
        }
        try { $historyData = Get-RecentHistoryJson -Json $historyData -MaxEntries $CONFIG.HistoryContextMaxEntries }
        catch { Write-AppLog "近期对话格式异常，使用空上下文：$($_.Exception.Message)" 'WARN'; $historyData = '[]' }
        $longMemory = if (Test-Path -LiteralPath $SUMMARY_FILE) { Get-Content -LiteralPath $SUMMARY_FILE -Raw -Encoding UTF8 } else { "" }
        $nowTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss dddd'

        $systemPrompt = $CONFIG.SystemPrompt
        if ($CONFIG.Chat.DeepThinking) {
            $systemPrompt += " 请进行深度思考，一步一步推理，确保回答准确。"
        }

        $promptText = @"
现在对方没有发来新消息。你正在考虑要不要【主动】给对方发一条消息，就像真人偶尔会主动找朋友聊天一样。

截图中左侧白色气泡是对方发的消息，右侧绿色气泡是你发的消息。请结合截图、【近期对话】和【长期记忆】判断。

当前情况：
- 距离聊天画面上次有变化，已经过去：$silenceText
- 你今天已经主动发起过：$($st.sentToday) 次
- 当前时间：$nowTime

判断原则（宁可不发，也不要打扰对方）：
1. 只有确实有自然的话题时才发。例如：跟进【长期记忆】里没聊完的话题、对方提过的待办或近况；顺着上次聊到的内容自然延伸；符合当前时间的、不生硬的问候或分享。
2. 没有合适的话题就不发。不要为了发而发，不要发"在吗""干嘛呢"这类没有实际内容的话。
3. 如果你最后发的消息是一个还没得到回答的问题或邀请，或者对方明显在忙、已经结束了对话，不要追问，不要催促。
4. 内容要符合你的人设和平时的说话风格，简短自然，像随手发的一条消息。
5. 不要重复【近期对话】里已经说过的话。

输出格式（只输出下面的 XML 标签，不要输出解释）：
决定不发：
<proactive>0</proactive>

决定发：
<proactive>1</proactive>
<reply>你要主动发出的消息内容</reply>

【近期对话】数据说明：
- 每条记录中 user 是对方发的消息，ai 是你发出的回复，time 是记录时间（较早的记录可能只有时分秒，没有日期）。
- ai 为 __NO_REPLY__ 表示当时判断无需回复，你没有发送任何消息。
- ai 以 [发送失败，已放弃重试] 开头表示这条回复实际没有发出去，对方没有看到；截图中也不会有对应的绿色气泡。
- ai 以 [发送状态未知，已停止重试] 开头表示尝试发送过但未确认，请以截图为准，不要假定已送达。
- user 为 __PROACTIVE__ 表示这条是你主动发起的消息（当时对方并没有发消息），ai 是你主动发出的内容。

【长期记忆】: $longMemory
【近期对话】: $historyData
"@

        $messages = @()
        $messages += $promptText
        $messages += @{ Type = "image"; Data = [Convert]::ToBase64String($ImageBytes) }

        $script:CurrentMode = "Thinking"
        Update-Spinner

        $aiRaw = $null
        try {
            $aiRaw = Invoke-AICompletion -ProviderType $CONFIG.Chat.ProviderType `
                -ApiUrl $CONFIG.Chat.ApiUrl `
                -ApiKey $CONFIG.Chat.ApiKey `
                -Model $CONFIG.Chat.Model `
                -Messages $messages `
                -MaxTokens $CONFIG.Chat.MaxTokens `
                -TimeoutSeconds $CONFIG.Chat.TimeoutSeconds `
                -SystemPrompt $systemPrompt `
                -DeepThinking ([bool]$CONFIG.Chat.DeepThinking) `
                -UsagePurpose "Proactive"
        }
        catch {
            # 主动请求失败时退避，不向被动回复流程抛出。
            Write-Log "⚠️ 主动发起：AI 请求失败，稍后再判断：$($_.Exception.Message)" Yellow
            Write-AppLog "主动发起：AI 请求失败：$($_.ToString())" "WARN"
            $script:CurrentMode = "Listening"
            Update-Spinner
            Set-ProactiveNextCheck -Minutes ([double]$cfg.CooldownAfterNoMinutes) -Jitter $false
            return
        }
        $script:CurrentMode = "Listening"
        Update-Spinner

        $usageSuffix = ""
        if ((Test-UsageTrackingEnabled) -and $script:LastUsage -and $script:LastUsage.HasUsage) {
            $usageSuffix = "  (↑{0} ↓{1})" -f (Format-TokenCount $script:LastUsage.Input), (Format-TokenCount $script:LastUsage.Output)
        }
        $truncated = [bool]($script:LastUsage -and $script:LastUsage.Truncated)

        Write-AppLog "主动发起：AI 原始返回 → $(Format-LogContent $aiRaw)" "DEBUG"

        # 只接受明确的决策标签；截断或格式异常时不发送。
        $decision = 0
        $reply = ""
        if ($truncated) {
            Write-AppLog "主动发起：AI 回复被 MaxTokens 截断，本次放弃" "WARN"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($aiRaw)) {
            $pm = [regex]::Matches($aiRaw, "(?is)<proactive>\s*([01])\s*</proactive>")
            if ($pm.Count -gt 0) {
                $sel = $pm[$pm.Count - 1]
                if ($sel.Groups[1].Value -eq "1") {
                    $tail = $aiRaw.Substring($sel.Index + $sel.Length)
                    $rm = [regex]::Matches($tail, "(?is)<reply>(.*?)</reply>")
                    if ($rm.Count -gt 0) { $reply = $rm[$rm.Count - 1].Groups[1].Value.Trim() }
                    $reply = ($reply -replace '</?reply>', '').Trim()
                    if (-not [string]::IsNullOrWhiteSpace($reply) -and $reply -ne "__NO_REPLY__") { $decision = 1 }
                }
            }
            else {
                Write-AppLog "主动发起：AI 返回缺少有效 <proactive> 标签，按「不发」处理" "WARN"
            }
        }

        if ($decision -ne 1) {
            Write-Log ("[{0}] 🤫 主动发起：暂时没有合适的话题{1}" -f (Get-Date -Format 'HH:mm:ss'), $usageSuffix) DarkGray
            Write-AppLog "主动发起：AI 判断暂不发送" "INFO"
            Set-ProactiveNextCheck -Minutes ([double]$cfg.CooldownAfterNoMinutes) -Jitter $false
            return
        }

        # 复核画面与近期用户操作，丢弃过期的主动消息。
        $freshHash = Get-WindowCropHash -WindowHandle $WindowHandle -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight
        if ($freshHash -and $freshHash -ne $CurrentHash) {
            $stale = $true
            if ($script:BlinkTwinHashes -and $script:BlinkTwinHashes.Contains($freshHash)) { $stale = $false }
            elseif (Test-BlinkGuardEnabled) {
                if (Test-CropBlinkBack -WindowHandle $WindowHandle -TargetHash $CurrentHash `
                        -MarginLeft $MarginLeft -MarginTop $MarginTop -CropWidth $CropWidth -CropHeight $CropHeight) { $stale = $false }
            }
            if ($stale) {
                Write-Log "           ⏹️ 主动发起：AI 思考期间聊天画面变了，放弃这条主动消息" DarkYellow
                Write-AppLog "主动发起：发送前画面已变化，放弃 → 原 Hash=$CurrentHash, 现 Hash=$freshHash" "INFO"
                Set-ProactiveNextCheck -Minutes 2.0 -Jitter $false
                return
            }
        }
        if (Test-UserBusyInWeChat -WindowHandle $WindowHandle -IdleMs 30000) {
            Write-Log "           ⏹️ 主动发起：你刚开始使用微信，放弃这条主动消息" DarkYellow
            Write-AppLog "主动发起：发送前检测到你正在使用微信，放弃" "INFO"
            Set-ProactiveNextCheck -Minutes 2.0 -Jitter $false
            return
        }

        # 复用回复发送链路：延迟、前台等待、注入和视觉校验。
        Hide-Spinner
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 💬 主动发起: $reply" -ForegroundColor Cyan -NoNewline
        Write-Host $usageSuffix -ForegroundColor DarkGray
        Update-Spinner
        Write-AppLog "主动发起：准备发送 → $(Format-LogContent $reply)" "INFO"
        if ($CONFIG.BeepOnReply) { [System.Media.SystemSounds]::Asterisk.Play() }

        $script:CurrentMode = "Replying"
        Update-Spinner

        $sendResult = Invoke-ReplySendAndVerify `
            -WindowHandle $WindowHandle `
            -Message $reply `
            -Method $CONFIG.SendMethod `
            -BeforeHash $CurrentHash `
            -CropWidth $CropWidth `
            -CropHeight $CropHeight `
            -MarginLeft $MarginLeft `
            -MarginTop $MarginTop `
            -HumanDelay `
            -DetectedAt (Get-Date)

        $script:CurrentMode = "Listening"
        Update-Spinner

        if ($sendResult.Deferred) {
            # 发送前中止时不计入次数，重新安排检查。
            Write-AppLog "主动发起：发送被推迟并作废 → $($sendResult.Reason)" "INFO"
            Set-ProactiveNextCheck -Minutes 2.0 -Jitter $false
            return
        }

        if (-not $sendResult.Confirmed) {
            if ($sendResult.Uncertain) {
                $script:ProactiveDisabled = $true
                Write-Log '⚠️ 主动消息发送状态未知，本次运行已停止主动发起，请核对微信。' Yellow
                Write-AppLog '主动消息发送状态未知，已停用到重启，避免重复发送' 'WARN'
                return
            }
            $script:ProactiveFailStreak++
            Write-Log "⚠️ 主动发起：这条消息没有确认送达（连续失败 $($script:ProactiveFailStreak) 次）" Yellow
            Write-AppLog "主动发起：发送未确认 → $($sendResult.Reason)；连续失败 $($script:ProactiveFailStreak) 次；内容：$(Format-LogContent $reply)" "WARN"
            if ($script:ProactiveFailStreak -ge 2) {
                # 连续失败后停用主动消息，避免反复向输入框追加内容。
                $script:ProactiveDisabled = $true
                Write-Log "⛔ 主动发起连续发送失败，本次运行内已停用（被动回复不受影响）。请确认微信焦点在聊天输入框后重启脚本。" Yellow
                Write-AppLog "主动发起：连续发送失败，本次运行内停用" "ERROR"
                Show-AlertNotification -Key "ProactiveSendFailed" -Level Warning -CooldownMinutes 30 `
                    -Title "主动发消息已停用" `
                    -Message "主动发起的消息连续 $($script:ProactiveFailStreak) 次没发出去，已停用到下次重启。请确认微信焦点还在聊天输入框上。"
            }
            else {
                Set-ProactiveNextCheck -Minutes ([Math]::Max([double]$cfg.CheckMinutes, 30.0))
            }
            return
        }

        $script:ProactiveFailStreak = 0
        $script:Last_Hash = if (-not [string]::IsNullOrWhiteSpace($sendResult.AfterHash)) { $sendResult.AfterHash } else { $CurrentHash }
        $script:LastChatActivityAt = Get-Date

        $st.sentToday = [int]$st.sentToday + 1
        $st.unanswered = [int]$st.unanswered + 1
        $st.lastProactiveAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Save-ProactiveState

        Add-ChatHistoryEntry -User "__PROACTIVE__" -AI $reply
        Write-AppLog "主动发起：发送成功（今日第 $($st.sentToday) 条，连续未回复 $($st.unanswered) 条）" "INFO"
        Set-ProactiveNextCheck -Minutes ([double]$cfg.CheckMinutes)
    }
    catch {
        # 检查异常时记录日志并退避。
        Write-AppLog "主动发起检查异常（已忽略）：$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage -replace '\s*\r?\n\s*', ' | ')" "WARN"
        $script:CurrentMode = "Listening"
        Set-ProactiveNextCheck -Minutes ([double]$cfg.CheckMinutes)
    }
}

# 主入口
if (-not $enteredWizard) {
    if (Test-Path -LiteralPath $CONFIG_FILE) {
        try {
            $CONFIG = Get-Content -LiteralPath $CONFIG_FILE -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

            $configChanged = Normalize-Config -Config $CONFIG

            if ($configChanged) {
                Write-JsonFile -Path $CONFIG_FILE -Value $CONFIG
                Write-Host "✅ 已加载配置文件，并自动补全/修正了缺失或非法配置项。" -ForegroundColor Green
            }
            else {
                Write-Host "✅ 已加载配置文件。" -ForegroundColor Green
            }
        }
        catch {
            if ($script:GuiMode) {
                Write-Host "❌ config.json 解析失败：$($_.Exception.Message)，请在图形界面的「设置」中重新保存配置。" -ForegroundColor Red
                exit 2
            }
            Write-Host "⚠️ 配置文件解析失败，重新运行配置向导..." -ForegroundColor Yellow
            $CONFIG = Show-WelcomeWizard
        }
    }
    else {
        $CONFIG = Show-WelcomeWizard
    }
}
if (-not (Test-Path -LiteralPath $HISTORY_FILE)) { Write-AtomicText -Path $HISTORY_FILE -Text '[]' }

$script:Last_Hash = ""

# 同一画面的格式异常最多额外重试 AbnormalResponseMaxRetry 次。
$script:BadAiHash = ""
$script:BadAiCount = 0
$script:BadAiMaxRetry = [int]$CONFIG.Chat.AbnormalResponseMaxRetry
# 全局连续异常计数跨 hash 累计，达到阈值后进入冷却。
$script:BadAiStreakCount = 0
$script:BadAiStreakMax = [Math]::Max((($script:BadAiMaxRetry + 1) * 3), 6)
$script:BadAiCooldownUntil = [DateTime]::MinValue
$script:BadAiCooldownMs = [Math]::Max(([int]$CONFIG.PollingIntervalMs * 5), 5000)

# 发送返回失败时最多额外重试 SendFailureMaxRetry 次；发送状态未知时不重发。
$script:BadSendHash = ""
$script:BadSendCount = 0
$script:BadSendMaxRetry = [int]$CONFIG.Chat.SendFailureMaxRetry
# 缓存失败回复，避免重试时重新生成内容。
$script:PendingSendHash = ""
$script:PendingSendContent = ""
$script:PendingSendReply = ""

$script:LastSummaryAttempt = [DateTime]::MinValue
$script:LastApiStatusCode = 0
$script:FatalExit = $false
$script:MinimizedNotified = $false
$script:WeChatNotFoundNotified = $false

# 出问题时的系统通知：微信最小化 / 未运行持续多少秒后才弹通知
$script:AlertGraceSeconds = 15
$script:MinimizedSince = Get-Date
$script:MinimizedAlerted = $false
$script:WeChatNotFoundSince = Get-Date
$script:WeChatNotFoundAlerted = $false

# 窗口尺寸变化后等待稳定并重设 hash 基准，跳过该画面的模型判断。
$script:LastWindowSize = ""
$script:ResizeRebasePending = $false

# 闪烁候选 hash 仅在 BlinkTwinBase 匹配 Last_Hash 时有效。
$script:BlinkTwinHashes = New-Object 'System.Collections.Generic.HashSet[string]'
$script:BlinkTwinBase = ""
$script:BlinkWarned = $false

Invoke-LogRotation
Initialize-TokenUsage
Initialize-ProactiveState
Write-AppLog "============================================================" "INFO"
Write-AppLog "应用启动 → Provider=$($CONFIG.Chat.ProviderType), Model=$($CONFIG.Chat.Model), Memory=$($CONFIG.Summary.enabled), DeepThinking=$($CONFIG.Chat.DeepThinking), PollingMs=$($CONFIG.PollingIntervalMs)" "INFO"
Write-AppLog "日志配置 → Level=$($CONFIG.LogLevel), RetentionDays=$($CONFIG.LogRetentionDays), RedactContent=$($CONFIG.LogRedactContent)" "INFO"

if (-not $script:GuiMode) { Show-Banner }
Write-SectionTitle "运行概览" Green
Write-InfoRow "状态" "运行中" Green
Write-InfoRow "模型" "$($CONFIG.Chat.ProviderType) / $($CONFIG.Chat.Model)"
if ($CONFIG.Summary.enabled) { Write-InfoRow "记忆" "开启" Cyan } else { Write-InfoRow "记忆" "关闭" DarkGray }
switch ($CONFIG.SendMethod) {
    "WMChar" { Write-InfoRow "发送" "纯后台注入" White "不支持 emoji" }
    "Hybrid" { Write-InfoRow "发送" "智能混合" White "含 emoji 时借用剪贴板" }
    "Clipboard" { Write-InfoRow "发送" "纯剪贴板" }
    default { Write-InfoRow "发送" ([string]$CONFIG.SendMethod) }
}
if (Test-UsageTrackingEnabled) {
    $usageLimit = Get-DailyTokenLimit
    $usageLimitText = if ($usageLimit -gt 0) { "每日上限 $(Format-TokenCount $usageLimit)" } else { "不限额" }
    Write-InfoRow "用量" ("今日 {0} tokens · {1} 次请求" -f (Format-TokenCount $script:UsageToday.Total), $script:UsageToday.Requests) White $usageLimitText
}
else {
    Write-InfoRow "用量" "统计关闭" DarkGray
}
if (Test-ProactiveEnabled) {
    $pCfg = Get-ProactiveSettings
    Write-InfoRow "主动" "开启" Cyan ("{0}:00-{1}:00 · 沉默≥{2}分钟 · 每日≤{3}条 · 未回复时≤{4}条" -f $pCfg.StartHour, $pCfg.EndHour, $pCfg.MinSilenceMinutes, $pCfg.MaxPerDay, $pCfg.MaxUnanswered)
}
else {
    Write-InfoRow "主动" "关闭" DarkGray
}
if ($CONFIG.EnableFocusClick) {
    Write-InfoRow "对焦" "发送前自动点击输入框" White ("横向 {0:P0} · 距底 {1}px" -f [double]$CONFIG.InputBoxClickRatioX, [int]$CONFIG.InputBoxOffsetFromBottom)
}
else {
    Write-InfoRow "对焦" "关闭" DarkGray "需手动保持输入框焦点"
}

Write-Host ""
if (-not $CONFIG.EnableFocusClick) {
    Write-Callout -Title "⚠️ 重要" -Color Yellow -Lines @(
        "脚本要求微信窗口内的焦点必须停留在【聊天输入框】上：",
        "请在启动后【手动点一次微信的输入框】，之后不要再点击",
        "微信内的搜索框 / 设置 / 其它按钮，否则消息会发空。",
        "",
        $(if ($script:GuiMode) { "提示：在「校准截图区域」中开启【对焦点击】可免去这一步。" } else { "提示：在配置向导第 4 步开启【对焦点击】可免去这一步。" })
    )
}
Write-Host ""
if ($script:GuiMode) {
    Write-Host "  正在监听微信窗口" -ForegroundColor Gray
    Send-GuiMessage 'STARTED' @($CONFIG.Chat.ProviderType, $CONFIG.Chat.Model)
}
else {
    Write-Host "  正在监听微信窗口  " -NoNewline -ForegroundColor Gray
    Write-Host "按 Ctrl+C 停止" -ForegroundColor DarkGray
}
Write-Host ""

# 主监听循环
# 退出监听循环时释放托盘通知和 HTTP 资源，并恢复控制台状态。
try {
while ($true) {
    # 先匹配进程，再选择有主窗口的实例；无主窗口时按隐藏到托盘处理。
    $wechatProcesses = @(Get-Process -Name "WeChat", "Weixin" -ErrorAction SilentlyContinue)
    $proc = $wechatProcesses |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -ne "" } | Select-Object -First 1

    if ($wechatProcesses.Count -eq 0) {
        Write-Log "❌ 未检测到微信运行..." Red
        if (-not $script:WeChatNotFoundNotified) {
            Write-AppLog "未检测到微信进程（WeChat / Weixin），等待中" "WARN"
            $script:WeChatNotFoundNotified = $true
            $script:WeChatNotFoundSince = Get-Date
            $script:WeChatNotFoundAlerted = $false
        }
        # 进程持续缺失一段时间后才通知，避免短暂重启触发提醒。
        if (-not $script:WeChatNotFoundAlerted -and
            ((Get-Date) - $script:WeChatNotFoundSince).TotalSeconds -ge $script:AlertGraceSeconds) {
            Show-AlertNotification -Key "WeChatNotFound" -Level Warning -CooldownMinutes 0 `
                -Title "微信没有在运行" `
                -Message "自动回复已暂停。打开微信并登录后，脚本会自动继续监听。"
            $script:WeChatNotFoundAlerted = $true
        }
        Start-SpinnerSleep -Milliseconds 1000
        continue
    }
    else {
        if ($script:WeChatNotFoundNotified) {
            if ($proc) {
                Write-AppLog "微信进程已恢复 → PID=$($proc.Id), Title=$($proc.MainWindowTitle)" "INFO"
            }
            else {
                Write-AppLog "微信进程已恢复（窗口暂不可见，可能在托盘）→ PID=$($wechatProcesses[0].Id)" "INFO"
            }
            $script:WeChatNotFoundNotified = $false
        }
    }

    $isTrayHidden = (-not $proc)
    if ($isTrayHidden -or [WinUtil]::IsIconic($proc.MainWindowHandle)) {
        $minWhere = if ($isTrayHidden) { "最小化到托盘" } else { "最小化" }
        if ($CONFIG.BlockOnMinimized) {
            Write-Log "⚠️ 微信已${minWhere}！请还原后按回车重试..." Red
            Write-AppLog "微信窗口${minWhere}（阻塞模式），等待用户操作" "WARN"
            # 阻塞模式等待回车，进入等待时先发一次通知。
            if (-not $script:MinimizedAlerted) {
                Show-AlertNotification -Key "WeChatMinimized" -Level Warning -CooldownMinutes 0 `
                    -Title "微信已${minWhere}" `
                    -Message "自动回复已暂停。请还原微信窗口，然后在脚本窗口按回车继续。"
                $script:MinimizedAlerted = $true
            }
            Hide-Spinner
            if ($script:GuiMode) {
                # 由界面的「继续」按钮通过命名事件唤醒。
                Send-GuiMessage 'BLOCK' @($minWhere)
                if ($script:GuiContinueEvent) {
                    while (-not $script:GuiContinueEvent.WaitOne(200)) { Update-Spinner }
                }
                else { Start-SpinnerSleep -Milliseconds 1000 }
                Send-GuiMessage 'UNBLOCK'
            }
            else { $null = Read-Host }
        }
        else {
            if (-not $script:MinimizedNotified) {
                Write-Log "⚠️ 微信已${minWhere}，请还原窗口以继续监控..." Red
                Write-AppLog "微信窗口${minWhere}（非阻塞模式），暂停截图" "WARN"
                $script:MinimizedNotified = $true
                $script:MinimizedSince = Get-Date
            }
            # 非阻塞模式延迟通知短暂最小化。
            if (-not $script:MinimizedAlerted -and
                ((Get-Date) - $script:MinimizedSince).TotalSeconds -ge $script:AlertGraceSeconds) {
                Show-AlertNotification -Key "WeChatMinimized" -Level Warning -CooldownMinutes 0 `
                    -Title "微信已${minWhere}" `
                    -Message "自动回复已暂停。还原微信窗口后会自动继续监听。"
                $script:MinimizedAlerted = $true
            }
            Start-SpinnerSleep -Milliseconds 1000
        }
        continue
    }
    else {
        if ($script:MinimizedNotified) {
            Write-AppLog "微信窗口已还原，恢复监听" "INFO"
        }
        $script:MinimizedNotified = $false
        $script:MinimizedAlerted = $false
    }

    try {
        Update-MemorySummary $CONFIG

        $mL = $CONFIG.Margins.Left
        $mR = $CONFIG.Margins.Right
        $mT = $CONFIG.Margins.Top
        $mB = $CONFIG.Margins.Bottom

        $rect = New-Object WinUtil+RECT
        [void][WinUtil]::GetWindowRect($proc.MainWindowHandle, [ref]$rect)

        # 尺寸变化时先跳过，连续两轮尺寸相同后重设基准画面。
        $winSize = "{0}x{1}" -f ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
        if (-not [string]::IsNullOrEmpty($script:LastWindowSize) -and $winSize -ne $script:LastWindowSize) {
            if (-not $script:ResizeRebasePending) {
                Write-Log "[$(Get-Date -Format 'HH:mm:ss')] ↔️ 检测到微信窗口尺寸变化，等待稳定后重新取基准画面（期间不会自动回复）" DarkYellow
            }
            Write-AppLog "微信窗口尺寸变化 → $($script:LastWindowSize) → $winSize，暂停处理直到尺寸稳定" "INFO"
            $script:LastWindowSize = $winSize
            $script:ResizeRebasePending = $true
            Start-SpinnerSleep -Milliseconds 500
            continue
        }
        $script:LastWindowSize = $winSize

        $cW = ($rect.Right - $rect.Left) - $mL - $mR
        $cH = ($rect.Bottom - $rect.Top) - $mT - $mB
        $cW = [math]::Max(1, $cW); $cH = [math]::Max(1, $cH)

        if ($cW -le 10 -or $cH -le 10) {
            if (-not $script:TinyAreaNotified) {
                Write-AppLog "截图有效区域过小 → cW=$cW, cH=$cH（窗口尺寸或边距设置可能有问题），暂停截图" "WARN"
                $script:TinyAreaNotified = $true
            }
            # 暂停截图时继续刷新状态行。
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 100
                Update-Spinner
            }
            continue
        }
        else {
            if ($script:TinyAreaNotified) {
                Write-AppLog "截图有效区域已恢复 → cW=$cW, cH=$cH" "INFO"
                $script:TinyAreaNotified = $false
            }
        }

        # 截图失败时抛出异常，由外层 catch 记录并在下一轮重试。
        $crop = Get-WindowCrop -WindowHandle $proc.MainWindowHandle -MarginLeft $mL -MarginTop $mT -CropWidth $cW -CropHeight $cH
        $imgBytes = $crop.Bytes
        $current_hash = $crop.Hash
        $crop = $null

        # 尺寸稳定后重新取基准，不请求模型。
        if ($script:ResizeRebasePending) {
            $stableHash = Wait-CropHashStable `
                -WindowHandle $proc.MainWindowHandle `
                -MarginLeft $mL -MarginTop $mT -CropWidth $cW -CropHeight $cH `
                -InitialHash $current_hash
            if ([string]::IsNullOrWhiteSpace($stableHash)) { $stableHash = $current_hash }

            $rectAfter = New-Object WinUtil+RECT
            [void][WinUtil]::GetWindowRect($proc.MainWindowHandle, [ref]$rectAfter)
            $sizeAfter = "{0}x{1}" -f ($rectAfter.Right - $rectAfter.Left), ($rectAfter.Bottom - $rectAfter.Top)
            if ($sizeAfter -ne $winSize) {
                Write-AppLog "取基准期间窗口尺寸再次变化 → $winSize → $sizeAfter，稍后重试" "DEBUG"
                $script:LastWindowSize = $sizeAfter
                Start-SpinnerSleep -Milliseconds 500
                continue
            }

            $script:Last_Hash = $stableHash
            $script:BlinkTwinHashes.Clear()
            $script:BlinkTwinBase = $stableHash
            # 清除基于旧画面保留的发送失败与待重发状态。
            Clear-SendFailureState
            $script:ResizeRebasePending = $false
            Write-AppLog "窗口尺寸已稳定（$winSize），已重新取基准画面 → Hash=$stableHash" "INFO"
            Write-Log "[$(Get-Date -Format 'HH:mm:ss')] ✅ 窗口尺寸已稳定，继续监听" DarkGray
            Start-SpinnerSleep -Milliseconds $CONFIG.PollingIntervalMs
            continue
        }

        # 已知闪烁候选画面按未变化处理。
        if ($script:BlinkTwinBase -ne $script:Last_Hash) {
            $script:BlinkTwinHashes.Clear()
            $script:BlinkTwinBase = $script:Last_Hash
        }
        if (-not [string]::IsNullOrWhiteSpace($script:Last_Hash) -and $script:BlinkTwinHashes.Contains($current_hash)) {
            $current_hash = $script:Last_Hash
        }

        if ($current_hash -eq $script:Last_Hash) {
            $script:AIAbortStreak = 0   # 基准画面再次出现时，重置连续请求取消计数。
            if (-not [string]::IsNullOrWhiteSpace($script:PendingSendHash)) {
                Write-AppLog "当前画面已处理，清空过期待重发缓存 → PendingHash=$($script:PendingSendHash), CurrentHash=$current_hash" "DEBUG"
                Clear-SendFailureState
            }

            # 画面匹配基准时检查主动消息；未启用或未到期时立即返回。
            if (-not [string]::IsNullOrWhiteSpace($script:Last_Hash)) {
                Invoke-ProactiveCheck `
                    -WindowHandle $proc.MainWindowHandle `
                    -CurrentHash $current_hash `
                    -ImageBytes $imgBytes `
                    -MarginLeft $mL `
                    -MarginTop $mT `
                    -CropWidth $cW `
                    -CropHeight $cH
            }

            Start-SpinnerSleep -Milliseconds $CONFIG.PollingIntervalMs
            Update-Spinner
            continue
        }

        # 变化画面短时回到基准时，按闪烁处理。
        if ((Test-BlinkGuardEnabled) -and -not [string]::IsNullOrWhiteSpace($script:Last_Hash)) {
            $isBlink = Test-CropBlinkBack `
                -WindowHandle $proc.MainWindowHandle `
                -TargetHash $script:Last_Hash `
                -MarginLeft $mL `
                -MarginTop $mT `
                -CropWidth $cW `
                -CropHeight $cH

            if ($isBlink) {
                [void]$script:BlinkTwinHashes.Add($current_hash)
                Write-AppLog "闪烁防护：画面在两种状态间来回切换（多半是输入框光标在截图区域内），已忽略 → Hash=$current_hash, Last=$($script:Last_Hash)" "DEBUG"
                if (-not $script:BlinkWarned) {
                    Write-Log "[$(Get-Date -Format 'HH:mm:ss')] ⚠️ 截图区域内有闪烁元素（多半是输入框光标），已自动忽略。建议重新配置截图区域，调大下边距。" Yellow
                    Write-AppLog "闪烁防护首次触发：截图区域内存在闪烁元素，建议调大下边距" "WARN"
                    $script:BlinkWarned = $true
                }
                Start-SpinnerSleep -Milliseconds $CONFIG.PollingIntervalMs
                continue
            }
        }

        # 画面与待重发缓存不匹配时丢弃缓存，避免之后误发旧回复。
        if (
            -not [string]::IsNullOrWhiteSpace($script:PendingSendHash) -and
            $script:PendingSendHash -ne $current_hash
        ) {
            Write-AppLog "待重发缓存已过期，清空缓存 → PendingHash=$($script:PendingSendHash), CurrentHash=$current_hash" "DEBUG"
            Clear-SendFailureState
        }

        Write-AppLog "检测到界面变化，准备发送 AI 请求 → Hash=$current_hash" "DEBUG"
        # 记录观察到变化的时刻，供回复延迟扣除已有耗时。
        $detectedAt = Get-Date
        $script:LastChatActivityAt = $detectedAt
        
        if (
            $script:BadSendHash -eq $current_hash -and
            $script:BadSendCount -gt 0 -and
            $script:PendingSendHash -eq $current_hash -and
            -not [string]::IsNullOrWhiteSpace($script:PendingSendReply)
        ) {
            $content = $script:PendingSendContent
            $cleanReply = $script:PendingSendReply

            Write-AppLog "检测到待重发回复，跳过 AI 请求，直接重发缓存内容：$(Format-LogContent $cleanReply)" "WARN"
            Write-Log ""
            Write-Log "[$(Get-Date -Format 'HH:mm:ss')] 🔁 正在重发上次未确认的回复: $cleanReply" Yellow

            $script:CurrentMode = "Replying"
            Update-Spinner

            $sendResult = Invoke-ReplySendAndVerify `
                -WindowHandle $proc.MainWindowHandle `
                -Message $cleanReply `
                -Method $CONFIG.SendMethod `
                -BeforeHash $current_hash `
                -CropWidth $cW `
                -CropHeight $cH `
                -MarginLeft $mL `
                -MarginTop $mT

            if ($sendResult.Deferred) {
                # 发送前复核中止时清除旧回复缓存。
                Clear-SendFailureState
                $script:CurrentMode = "Listening"
                Update-Spinner
                continue
            }

            if (-not $sendResult.Confirmed) {
                $sendGiveUp = Register-SendFailureHash `
                    -Hash $current_hash `
                    -Reason $sendResult.Reason `
                    -Uncertain ([bool]$sendResult.Uncertain) `
                    -Content $content `
                    -Reply $cleanReply

                if ($sendGiveUp) {
                    $failurePrefix = if ($sendResult.Uncertain) { '[发送状态未知，已停止重试]' } else { '[发送失败，已放弃重试]' }
                    Add-ChatHistoryEntry -User $content -AI "$failurePrefix $cleanReply"
                }

                continue
            }

            # 视觉校验通过后，以发送后的稳定画面更新监听基准。
            $script:Last_Hash = if (-not [string]::IsNullOrWhiteSpace($sendResult.AfterHash)) { $sendResult.AfterHash } else { $current_hash }

            Clear-SendFailureState

            Add-ChatHistoryEntry -User $content -AI $cleanReply

            $script:CurrentMode = "Listening"
            Update-Spinner

            continue
        }

        # 全局异常冷却期间暂停模型请求。
        $nowForAiCooldown = Get-Date
        if ($script:BadAiCooldownUntil -gt $nowForAiCooldown) {
            $remainingAiCooldownMs = [int][Math]::Ceiling(($script:BadAiCooldownUntil - $nowForAiCooldown).TotalMilliseconds)
            if ($remainingAiCooldownMs -lt 200) { $remainingAiCooldownMs = 200 }
            $sleepAiCooldownMs = [Math]::Min($remainingAiCooldownMs, [int]$CONFIG.PollingIntervalMs)

            Write-AppLog "AI 连续异常冷却中，暂不请求 AI → RemainingMs=$remainingAiCooldownMs, Hash=$current_hash" "DEBUG"
            $script:CurrentMode = "Listening"
            Update-Spinner
            Start-SpinnerSleep -Milliseconds $sleepAiCooldownMs
            continue
        }

        # 达到今日 token 上限时保留未处理画面，日期切换后重新判断。
        if (Test-DailyTokenLimitReached) {
            if (-not $script:TokenLimitNotified) {
                $limitText = Format-TokenCount (Get-DailyTokenLimit)
                Write-Log "[$(Get-Date -Format 'HH:mm:ss')] ⛔ 今日 token 用量已达上限 $limitText，暂停自动回复（次日自动恢复，或修改 config.json 中的 DailyTokenLimit 后重启）" Yellow
                Write-AppLog "今日 token 用量已达上限 → Used=$($script:UsageToday.Total), Limit=$(Get-DailyTokenLimit)，暂停请求 AI" "WARN"
                if ($CONFIG.BeepOnReply) { [System.Media.SystemSounds]::Exclamation.Play() }
                Show-AlertNotification -Key "TokenLimit" -Level Warning -CooldownMinutes 0 `
                    -Title "今日 token 已用完" `
                    -Message "已达每日上限 $limitText，自动回复已暂停，明天自动恢复（或修改 config.json 中的 DailyTokenLimit 后重启）。"
                $script:TokenLimitNotified = $true
            }
            $script:CurrentMode = "Listening"
            Update-Spinner
            Start-SpinnerSleep -Milliseconds ([Math]::Max([int]$CONFIG.PollingIntervalMs, 5000))
            continue
        }

        $base64 = [Convert]::ToBase64String($imgBytes)
        try {
            if (Test-Path -LiteralPath $HISTORY_FILE) {
                $historyData = Get-Content -LiteralPath $HISTORY_FILE -Raw -Encoding UTF8 -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($historyData)) {
                    $historyData = "[]"
                }
            }
            else {
                $historyData = "[]"
                Write-AtomicText -Path $HISTORY_FILE -Text '[]'
            }
        }
        catch {
            Write-AppLog "读取近期对话失败，已使用空历史：$($_.Exception.Message)" "WARN"
            $historyData = "[]"
        }
        try { $historyData = Get-RecentHistoryJson -Json $historyData -MaxEntries $CONFIG.HistoryContextMaxEntries }
        catch { Write-AppLog "近期对话格式异常，使用空上下文：$($_.Exception.Message)" 'WARN'; $historyData = '[]' }
        $longMemory = if (Test-Path -LiteralPath $SUMMARY_FILE) { Get-Content -LiteralPath $SUMMARY_FILE -Raw -Encoding UTF8 } else { "" }
        $nowTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss dddd'

        $messages = @()
        $systemPrompt = $CONFIG.SystemPrompt
        if ($CONFIG.Chat.DeepThinking) {
            $systemPrompt += " 请进行深度思考，一步一步推理，确保回答准确。"
        }

        $userText = @"
截图中左侧白色气泡是对方发的消息，右侧绿色气泡是你发的消息。

请先观察截图中的最后一条消息气泡颜色，再结合【近期对话】历史，判断最后一条消息是否为你刚刚回复的。

如果最后一条消息是你（右侧绿色气泡）发送的，请绝对不要再次回复，只输出：
<info>0</info>

如果最后一条消息是对方（左侧白色气泡）发的，请按以下格式输出：
<info>1</info>
<content>对方未被回答的所有消息原话</content>
<reply>你根据这些对话的回复内容</reply>

如果最后一条消息是对方发的，但根据上下文不需要回复，例如只是“嗯”“好的”“哈哈”“收到”“谢谢”等无需继续回应的内容，请不要留空 reply，而是严格输出：
<info>1</info>
<content>对方未被回答的所有消息原话</content>
<reply>__NO_REPLY__</reply>

注意：
1. 只输出上述 XML 标签，不要输出解释。
2. <reply> 不能为空。
3. 只有确实不需要回复时，才使用 __NO_REPLY__。
4. 如果需要回复文字，即使回复内容中包含英文单词 None，也应把它作为正常回复内容输出，不要用 __NO_REPLY__。

【近期对话】数据说明：
- 每条记录中 user 是对方发的消息，ai 是你发出的回复，time 是记录时间（较早的记录可能只有时分秒，没有日期）。
- ai 为 __NO_REPLY__ 表示当时判断无需回复，你没有发送任何消息。
- ai 以 [发送失败，已放弃重试] 开头表示这条回复实际没有发出去，对方没有看到；截图中也不会有对应的绿色气泡。
- ai 以 [发送状态未知，已停止重试] 开头表示尝试发送过但未确认，请以截图为准，不要假定已送达。
- user 为 __PROACTIVE__ 表示这条是你主动发起的消息（当时对方并没有发消息），ai 是你主动发出的内容。

【长期记忆】: $longMemory
【近期对话】: $historyData
【当前时间】: $nowTime
"@

        $messages = @()
        $messages += $userText
        $messages += @{ Type = "image"; Data = $base64 }

        $script:CurrentMode = "Thinking"
        Update-Spinner

        $aiRaw = $null

        $script:AIScreenChanged = $false
        $script:AIScreenWatch = $null
        if (Test-AbortOnScreenChangeEnabled) {
            if ($script:AIAbortStreak -lt $script:AIAbortMaxStreak) {
                $script:AIScreenWatch = @{
                    WindowHandle = $proc.MainWindowHandle
                    MarginLeft   = $mL
                    MarginTop    = $mT
                    CropWidth    = $cW
                    CropHeight   = $cH
                    BaseHash     = $current_hash
                    TwinHashes   = New-Object 'System.Collections.Generic.HashSet[string]'
                    IntervalMs   = 800
                    NextCheckMs  = 800
                    Stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
                    ChangedHash  = ""
                }
            }
            else {
                Write-AppLog "思考期间画面已连续变化 $($script:AIAbortStreak) 次（截图区可能有动图等动态元素），本次请求不再中止" "DEBUG"
            }
        }

        try {
            $aiRaw = Invoke-AICompletion -ProviderType $CONFIG.Chat.ProviderType `
                -ApiUrl $CONFIG.Chat.ApiUrl `
                -ApiKey $CONFIG.Chat.ApiKey `
                -Model $CONFIG.Chat.Model `
                -Messages $messages `
                -MaxTokens $CONFIG.Chat.MaxTokens `
                -TimeoutSeconds $CONFIG.Chat.TimeoutSeconds `
                -SystemPrompt $systemPrompt `
                -DeepThinking ([bool]$CONFIG.Chat.DeepThinking) `
                -UsagePurpose "Chat" `
                -UsageIsRetry ($script:BadAiHash -eq $current_hash -and $script:BadAiCount -gt 0)
        }
        catch {
            if ($script:AIScreenChanged) {
                # 画面变化导致的取消不计入失败，也不更新处理基准。
                $script:AIScreenChanged = $false
                $script:AIAbortStreak++
                $newHash = if ($script:AIScreenWatch) { $script:AIScreenWatch.ChangedHash } else { "" }
                Write-Log "[$(Get-Date -Format 'HH:mm:ss')] 🔄 思考期间又有新消息，已中止本次请求，按最新画面重新思考" DarkGray
                Write-AppLog "思考期间画面变化，中止 AI 请求 → BaseHash=$current_hash, NewHash=$newHash, Streak=$($script:AIAbortStreak)" "INFO"
                $script:AIScreenWatch = $null
                $script:CurrentMode = "Listening"
                Update-Spinner
                continue
            }

            $errText = $_.ToString()
            $errKind = Get-AIErrorKind -ErrorText $errText -StatusCode ([int]$script:LastApiStatusCode)

            if ($errKind -eq 'Fatal') {
                Write-Log "❌ AI API 配置或权限错误：$($_.Exception.Message)" Red
                Write-Log "请检查 API Key、模型名、接口地址或权限后，重启脚本。" Yellow
                Write-AppLog "AI API 不可重试错误（HTTP $($script:LastApiStatusCode)）：$errText" "ERROR"
                Show-AlertNotification -Key "AiFatal" -Level Error -CooldownMinutes 0 `
                    -Title "AI 接口配置错误，自动回复已停止" `
                    -Message "请检查 API Key、模型名或接口地址后重启脚本。"

                $script:FatalExit = $true
                break
            }

            if ($errKind -eq 'BadRequest') {
                # 只针对这一次请求的错误（如截图被内容审核拦截），按同一画面异常处理：重试几次后跳过该画面，不退出脚本。
                Write-Log "⚠️ AI 拒绝了本次请求（HTTP $($script:LastApiStatusCode)），可能是截图内容被审核拦截或上下文过长：$($_.Exception.Message)" Yellow
                [void](Register-AIAbnormalHash -Hash $current_hash -Reason "AI 拒绝本次请求（HTTP $($script:LastApiStatusCode)）" -Raw $errText)
                continue
            }

            Write-Log "⚠️ AI API 请求失败，稍后重试：$($_.Exception.Message)" Yellow
            Write-AppLog "AI API 请求异常，进入冷却但不标记当前画面为已处理：$errText" "WARN"

            $cooldownMs = if ($script:BadAiCooldownMs -and $script:BadAiCooldownMs -gt 0) {
                [int]$script:BadAiCooldownMs
            }
            else {
                5000
            }

            $script:BadAiCooldownUntil = (Get-Date).AddMilliseconds($cooldownMs)

            $script:CurrentMode = "Listening"
            Update-Spinner

            continue
        }
        finally {
            $script:AIScreenWatch = $null
        }
        Write-AppLog "AI 原始返回 → $(Format-LogContent $aiRaw)" "DEBUG"
        if ($script:LastUsage -and $script:LastUsage.Truncated) {
            [void](Register-AIAbnormalHash -Hash $current_hash -Reason 'AI 回复被截断，本次不发送' -Raw $aiRaw)
            continue
        }
        if ([string]::IsNullOrWhiteSpace($aiRaw)) {
            [void](Register-AIAbnormalHash `
                    -Hash $current_hash `
                    -Reason "AI 返回内容为空" `
                    -Raw $aiRaw)

            continue
        }

        try {
            # 缺少有效 <info> 标签时按格式异常重试，不能视作无新消息。
            $infoMatches = [regex]::Matches($aiRaw, "(?is)<info>\s*([01])\s*</info>")

            if ($infoMatches.Count -eq 0) {
                [void](Register-AIAbnormalHash `
                        -Hash $current_hash `
                        -Reason "AI 返回缺少有效 <info>0</info> 或 <info>1</info>" `
                        -Raw $aiRaw)

                continue
            }

            # 使用最后一个有效 <info>，仅从其后解析正文，避免与示例标签错配。
            $selectedInfoMatch = $infoMatches[$infoMatches.Count - 1]
            $infoValue = $selectedInfoMatch.Groups[1].Value
            $isNewMsg = ($infoValue -eq "1")
                
            if ($isNewMsg) {
                $answerTailStart = $selectedInfoMatch.Index + $selectedInfoMatch.Length
                if ($answerTailStart -lt $aiRaw.Length) {
                    $answerTail = $aiRaw.Substring($answerTailStart)
                }
                else {
                    $answerTail = ""
                }

                $content = ""
                $contentMatches = [regex]::Matches($answerTail, "(?is)<content>(.*?)</content>")
                if ($contentMatches.Count -gt 0) {
                    $content = $contentMatches[$contentMatches.Count - 1].Groups[1].Value.Trim()
                }

                $reply = ""
                $replyMatches = [regex]::Matches($answerTail, "(?is)<reply>(.*?)</reply>")
                if ($replyMatches.Count -gt 0) {
                    $reply = $replyMatches[$replyMatches.Count - 1].Groups[1].Value.Trim()
                }

                $cleanReply = ""
                $postSendHash = ""
                if ([string]::IsNullOrWhiteSpace($content)) {
                    [void](Register-AIAbnormalHash `
                            -Hash $current_hash `
                            -Reason "AI 返回 <info>1</info> 但 <content> 为空或缺失" `
                            -Raw $aiRaw)

                    continue
                }

                $noReplyToken = "__NO_REPLY__"

                if ([string]::IsNullOrWhiteSpace($reply)) {
                    [void](Register-AIAbnormalHash `
                            -Hash $current_hash `
                            -Reason "AI 返回 <info>1</info> 但 <reply> 为空或缺失" `
                            -Raw $aiRaw)

                    continue
                }

                if ($reply -eq $noReplyToken) {
                    Write-AppLog "AI 判断无需回复：$(Format-LogContent $content)" "INFO"
                }

                Write-AppLog "识别到新消息：$(Format-LogContent $content)" "INFO"
                Write-Log ""
                Write-Log "[$(Get-Date -Format 'HH:mm:ss')] 🎯 收到消息: $content"
                Reset-ProactiveUnanswered

                # 提取并清零本条消息及此前重试累计的用量。
                $msgUsageSuffix = Pop-MessageUsageSuffix

                if (-not [string]::IsNullOrWhiteSpace($reply) -and $reply -ne $noReplyToken) {
                    $cleanReply = $reply -replace '</?reply>', ''
                    Write-AppLog "执行回复动作：$(Format-LogContent $cleanReply)" "INFO"
                    $script:CurrentMode = "Replying"
                    Update-Spinner

                    Hide-Spinner
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🤖 正在回复: $cleanReply" -ForegroundColor Cyan -NoNewline
                    Write-Host $msgUsageSuffix -ForegroundColor DarkGray
                    Update-Spinner
                    if ($CONFIG.BeepOnReply) { [System.Media.SystemSounds]::Asterisk.Play() }

                    $sendResult = Invoke-ReplySendAndVerify `
                        -WindowHandle $proc.MainWindowHandle `
                        -Message $cleanReply `
                        -Method $CONFIG.SendMethod `
                        -BeforeHash $current_hash `
                        -CropWidth $cW `
                        -CropHeight $cH `
                        -MarginLeft $mL `
                        -MarginTop $mT `
                        -HumanDelay `
                        -DetectedAt $detectedAt

                    if ($sendResult.Deferred) {
                        # 发送前中止时不写历史、不更新基准，交由下一轮重新判断。
                        Clear-SendFailureState
                        $script:CurrentMode = "Listening"
                        Update-Spinner
                        continue
                    }

                    $sendConfirmed = [bool]$sendResult.Confirmed

                    if (-not $sendConfirmed) {
                        $sendGiveUp = Register-SendFailureHash `
                            -Hash $current_hash `
                            -Reason $sendResult.Reason `
                            -Uncertain ([bool]$sendResult.Uncertain) `
                            -Content $content `
                            -Reply $cleanReply

                        if ($sendGiveUp) {
                            $failurePrefix = if ($sendResult.Uncertain) { '[发送状态未知，已停止重试]' } else { '[发送失败，已放弃重试]' }
                            Add-ChatHistoryEntry -User $content -AI "$failurePrefix $cleanReply"
                        }

                        continue
                    }

                    Clear-SendFailureState
                    $postSendHash = $sendResult.AfterHash
                }
                else {
                    Write-Log "[$(Get-Date -Format 'HH:mm:ss')] 🤐 判断无需回复$msgUsageSuffix" DarkGray
                }

                # 已回复时使用发送后 hash；无需回复时使用当前 hash，并记录处理结果。
                $script:Last_Hash = if (-not [string]::IsNullOrWhiteSpace($postSendHash)) { $postSendHash } else { $current_hash }
                Clear-AIAbnormalState
                Clear-SendFailureState
                $historyAi = if (-not [string]::IsNullOrWhiteSpace($cleanReply)) {
                    $cleanReply
                }
                elseif (-not [string]::IsNullOrWhiteSpace($reply)) {
                    $reply
                }
                else {
                    $noReplyToken
                }

                Add-ChatHistoryEntry -User $content -AI $historyAi
            }
            else {
                # 模型明确返回无新消息时，记录当前画面为已处理。
                $script:Last_Hash = $current_hash
                Clear-AIAbnormalState
                Clear-SendFailureState
            }
        }
        catch {
            Write-Log "⚠️ 解析 AI 回复格式时出错：$($_.Exception.Message)" Yellow

            [void](Register-AIAbnormalHash `
                    -Hash $current_hash `
                    -Reason "解析 AI 回复格式失败：$($_.Exception.Message)" `
                    -Raw $aiRaw)
        }

        $script:CurrentMode = "Listening"
        Update-Spinner

    }
    catch {
        $errRecord = $_
        $err = $errRecord.ToString()
        # 保存异常类型、代码位置和调用栈，便于定位。
        $errPos = ""
        $errStack = ""
        try { $errPos = ($errRecord.InvocationInfo.PositionMessage -replace '\s*\r?\n\s*', ' | ').Trim() } catch {}
        try { $errStack = ($errRecord.ScriptStackTrace -replace '\r?\n', ' <- ').Trim() } catch {}
        $errType = ""
        try { $errType = $errRecord.Exception.GetType().FullName } catch {}
        Write-Host ""
        Write-Log "[$(Get-Date -Format 'HH:mm:ss')] ❌ 报错详情: $err" Red
        if ($errPos) { Write-Log "           位置: $errPos" DarkGray }
        Write-AppLog "系统运行时异常: [$errType] $err" "ERROR"
        if ($errPos) { Write-AppLog "    出错位置: $errPos" "ERROR" }
        if ($errStack) { Write-AppLog "    调用栈: $errStack" "ERROR" }
        if ($CONFIG.BeepOnReply) { [System.Media.SystemSounds]::Hand.Play() }
        Show-AlertNotification -Key "RuntimeError" -Level Error -CooldownMinutes 10 `
            -Title "微信 AI 助手运行出错" `
            -Message "$err（脚本会继续尝试运行，详情见命令行窗口或日志）"
        $script:CurrentMode = "Listening"
        Update-Spinner
    }

    Start-SpinnerSleep -Milliseconds $CONFIG.PollingIntervalMs
    Update-Spinner

    # 非托管资源在 finally 中释放，托管内存由运行时回收。
}
}
finally {
    if ($script:FatalExit -and $script:GuiMode) {
        Send-GuiMessage 'FATAL'
    }
    elseif ($script:FatalExit) {
        # 双击/右键运行时窗口会在脚本结束后立刻关闭，先停住让用户看到错误原因。
        Hide-Spinner
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host ""
        try { [void](Read-Host "按回车键退出") } catch {}
    }
    Remove-AlertNotificationIcon
    if ($script:AIHttpClient) { try { $script:AIHttpClient.Dispose() } catch {} ; $script:AIHttpClient = $null }
    Hide-Spinner
    try { [Console]::CursorVisible = $true } catch {}
}
