# Check-System.ps1
# 系统健康报告：系统版本 / 开机时间 / 近 7 天错误日志 / Windows 更新状态 /
#               安全软件状态 / 待重启标志
# 兼容 Windows PowerShell 2.0（Win7）至 5.1（Win11）：优先 WMI 与事件日志接口，
# 读不到的项如实标注「不可用」，不猜测、不假报。
# 结果同时输出到屏幕，并保存到同目录 reports\system-<时间>.txt

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ReportDir = Join-Path $ScriptDir 'reports'
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir | Out-Null }

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
    Write-Host '需要管理员权限：请通过「启动维护.cmd」运行，或以管理员身份打开 PowerShell 后再运行本脚本。' -ForegroundColor Yellow
    return
}

$script:Lines = New-Object System.Collections.ArrayList
function Out-Line {
    param([string]$Text = '')
    [void]$script:Lines.Add($Text)
    Write-Host $Text
}
function Wmi-DateTime([string]$Dtm) {
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($Dtm).ToString('yyyy-MM-dd HH:mm:ss') }
    catch { return $Dtm }
}
function Short-Msg([string]$Msg) {
    if (-not $Msg) { return '' }
    $one = ($Msg -replace '\s+', ' ').Trim()
    if ($one.Length -gt 110) { return $one.Substring(0, 110) + '…' }
    return $one
}

Out-Line '================ 系统健康报告 ================'
Out-Line ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 系统版本与开机时间 ----------
Out-Line ''
Out-Line '---- 系统信息 ----'
try {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    Out-Line ('系统：' + $os.Caption + '（版本 ' + $os.Version + '，内部版本 ' + $os.BuildNumber + '）')
    if ($os.OSArchitecture) { Out-Line ('架构：' + $os.OSArchitecture) }
    Out-Line ('安装日期：' + (Wmi-DateTime $os.InstallDate))
    $boot = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
    Out-Line ('最近开机：' + $boot.ToString('yyyy-MM-dd HH:mm:ss'))
    $up = (Get-Date) - $boot
    Out-Line ('已连续运行：' + [int]$up.TotalDays + ' 天 ' + $up.Hours + ' 小时 ' + $up.Minutes + ' 分钟')
} catch { Out-Line '系统信息：读取失败' }

# ---------- 近 7 天错误日志 ----------
Out-Line ''
Out-Line '---- 近 7 天错误日志 ----'
$since = (Get-Date).AddDays(-7)
$logDone = $false
if (Get-Command Get-WinEvent -ErrorAction SilentlyContinue) {
    try {
        $filter = @{ LogName = 'System'; Level = 1, 2; StartTime = $since }
        $evts = Get-WinEvent -FilterHashtable $filter -MaxEvents 1000 -ErrorAction Stop
        $cnt = ($evts | Measure-Object).Count
        Out-Line ('系统日志（严重 + 错误，近 7 天，最多统计 1000 条）：' + $cnt + ' 条')
        $shown = 0
        foreach ($e in $evts) {
            $shown++
            if ($shown -gt 10) { break }
            Out-Line ('  ' + $e.TimeCreated.ToString('yyyy-MM-dd HH:mm') + ' | ' + $e.ProviderName + ' | ID ' + $e.Id + ' | ' + (Short-Msg $e.Message))
        }
        $logDone = $true
    } catch { $logDone = $false }
}
if (-not $logDone) {
    # 回退到经典事件日志接口（Get-EventLog）；经典日志中「严重」多以「错误」级别记录
    try {
        $errs = Get-EventLog -LogName System -EntryType Error -After $since -ErrorAction Stop
        $cnt = ($errs | Measure-Object).Count
        Out-Line ('系统日志错误（近 7 天，经经典日志接口读取）：' + $cnt + ' 条')
        $shown = 0
        foreach ($e in $errs) {
            $shown++
            if ($shown -gt 10) { break }
            Out-Line ('  ' + $e.TimeGenerated.ToString('yyyy-MM-dd HH:mm') + ' | ' + $e.Source + ' | ID ' + $e.EventID + ' | ' + (Short-Msg $e.Message))
        }
        $logDone = $true
    } catch { Out-Line '系统日志：读取失败（Get-WinEvent 与 Get-EventLog 均不可用）' }
}
try {
    $appErrs = Get-EventLog -LogName Application -EntryType Error -After $since -ErrorAction Stop
    Out-Line ('应用程序日志错误（近 7 天）：' + (($appErrs | Measure-Object).Count) + ' 条')
} catch { Out-Line '应用程序日志：读取失败' }

# ---------- Windows 更新状态 ----------
Out-Line ''
Out-Line '---- Windows 更新 ----'
$wuDone = $false
try {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    Out-Line ('更新历史记录总数：' + $total)
    if ($total -gt 0) {
        $showN = [Math]::Min(8, $total)
        $hist = $searcher.QueryHistory(0, $showN)
        foreach ($h in $hist) {
            $rc = '未知'
            switch ($h.ResultCode) {
                2 { $rc = '成功' }
                3 { $rc = '成功（有警告）' }
                4 { $rc = '失败' }
                5 { $rc = '已中止' }
                default { $rc = '代码 ' + $h.ResultCode }
            }
            Out-Line ('  ' + $h.Date.ToString('yyyy-MM-dd') + ' | ' + $rc + ' | ' + $h.Title)
        }
    }
    $wuDone = $true
} catch { $wuDone = $false }
if (-not $wuDone) { Out-Line '更新历史：COM 接口读取失败，无法确认最近更新状态。' }
$wuSvc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if ($wuSvc) { Out-Line ('Windows Update 服务（wuauserv）：' + $wuSvc.Status + ' / 启动类型 ' + $wuSvc.StartType) }

# ---------- 安全软件状态 ----------
Out-Line ''
Out-Line '---- 安全软件 ----'
$avFound = $false
foreach ($ns in @('root\SecurityCenter2', 'root\SecurityCenter')) {
    if ($avFound) { break }
    try {
        $avs = Get-WmiObject -Namespace $ns -Class AntiVirusProduct -ErrorAction Stop
        foreach ($av in $avs) {
            $avFound = $true
            Out-Line ('安全软件：' + $av.displayName + '（状态码 0x' + ('{0:X}' -f [int]$av.productState) + '，以厂商控制台为准）')
        }
    } catch { }
}
if (-not $avFound) { Out-Line '安全软件：未通过 Security Center 读到（可能未注册或相关服务未运行）。' }
$defSvc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
if ($defSvc) { Out-Line ('Windows Defender 服务（WinDefend）：' + $defSvc.Status) }

# ---------- 待重启标志 ----------
Out-Line ''
Out-Line '---- 待重启标志 ----'
$pending = New-Object System.Collections.ArrayList
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    [void]$pending.Add('组件服务（CBS）要求重启完成更新')
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    [void]$pending.Add('Windows 更新要求重启')
}
try {
    $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
    if ($pfro) { [void]$pending.Add('存在待重命名/删除的文件操作（PendingFileRenameOperations）') }
} catch { }
if ($pending.Count -gt 0) {
    Out-Line '检测到待重启：'
    foreach ($p in $pending) { Out-Line ('  - ' + $p) }
} else {
    Out-Line '无待重启标志。'
}

# ---------- 保存报告 ----------
$reportPath = Join-Path $ReportDir ('system-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Lines | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ''
Write-Host ('报告已保存：' + $reportPath)
