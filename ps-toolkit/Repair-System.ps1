# Repair-System.ps1
# 系统修复：sfc /scannow -> DISM /RestoreHealth（仅 Win8 以上）-> chkdsk 只读扫描
# - Win7 的 DISM 不支持 /RestoreHealth：明确提示改用微软「系统更新准备工具」并跳过，不假报。
# - chkdsk 只读扫描；发现错误只报告，并询问是否安排下次开机修复，不擅自决定。
# 每步记录退出码与结论，记录保存到同目录 reports\repair-<时间>.txt
# 兼容 Windows PowerShell 2.0（Win7）至 5.1（Win11）。

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
function Invoke-ToolLogged {
    param([string]$Title, [string]$File, [string[]]$ArgList)
    Out-Line ''
    Out-Line ('---- ' + $Title + ' ----')
    if (-not (Test-Path $File)) {
        Out-Line '工具不存在，跳过。'
        return $null
    }
    try {
        & $File $ArgList 2>&1 | ForEach-Object { Out-Line ([string]$_) }
        return $LASTEXITCODE
    } catch {
        Out-Line ('执行失败：' + $_.Exception.Message)
        return $null
    }
}
function Schedule-ChkdskFix([string]$Drive) {
    # 通过标准输入回答 chkdsk 的「是否在下次重启时检查」提问（Y）
    $chk = Join-Path $env:windir 'System32\chkdsk.exe'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $chk
        $psi.Arguments = $Drive + ' /f'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.WriteLine('Y')
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        return $out
    } catch {
        return ('安排失败：' + $_.Exception.Message)
    }
}

Out-Line '================ 系统修复 ================'
Out-Line ('开始时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Out-Line '依次执行：sfc 系统文件检查、DISM 组件存储修复（Win8 以上）、chkdsk 只读扫描。'
Out-Line '整个过程可能需要数十分钟，请勿关机。'
$summary = New-Object System.Collections.ArrayList

# ---------- 1. sfc ----------
$sfcExe = Join-Path $env:windir 'System32\sfc.exe'
$sfcCode = Invoke-ToolLogged '1/3 sfc /scannow（系统文件检查与修复）' $sfcExe @('/scannow')
if ($null -eq $sfcCode) {
    [void]$summary.Add('sfc：未能执行')
} else {
    Out-Line ('sfc 退出码：' + $sfcCode)
    # 从 CBS 日志提取最近一条 [SR] 结论（如有）
    $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (Test-Path $cbsLog) {
        try {
            $sr = Select-String -Path $cbsLog -Pattern '\[SR\]' -ErrorAction Stop | Select-Object -Last 1
            if ($sr) { Out-Line ('CBS 日志最近 [SR] 记录：' + $sr.Line.Trim()) }
        } catch { }
    }
    [void]$summary.Add('sfc：已执行，退出码 ' + $sfcCode + '（详情见 %windir%\Logs\CBS\CBS.log）')
}

# ---------- 2. DISM ----------
$osVer = $null
try { $osVer = [Version](Get-WmiObject -Class Win32_OperatingSystem).Version } catch { }
$dismExe = Join-Path $env:windir 'System32\Dism.exe'
if ($null -ne $osVer -and $osVer -lt [Version]'6.2') {
    Out-Line ''
    Out-Line '---- 2/3 DISM 组件存储修复 ----'
    Out-Line '当前系统为 Windows 7（版本 ' + $osVer + '），其 DISM 不支持 /RestoreHealth，本步跳过（未执行）。'
    Out-Line '建议改用微软官方「系统更新准备工具（System Update Readiness Tool / CheckSUR）」：'
    Out-Line '从微软官网下载与本系统版本对应的该工具并运行一次，结果日志在 %windir%\Logs\CBS\CheckSUR.log。'
    Out-Line '本工具包不联网、不下载任何东西，请手动获取；跳过本步不影响下面的 chkdsk。'
    [void]$summary.Add('DISM：Win7 不支持 /RestoreHealth，已跳过并给出替代工具说明')
} else {
    $dismCode = Invoke-ToolLogged '2/3 DISM /Online /Cleanup-Image /RestoreHealth（组件存储修复）' $dismExe @('/Online', '/Cleanup-Image', '/RestoreHealth')
    if ($null -eq $dismCode) {
        [void]$summary.Add('DISM：未能执行')
    } elseif ($dismCode -eq 0) {
        Out-Line 'DISM 结论：完成，组件存储未报告无法修复的损坏。'
        [void]$summary.Add('DISM：已执行，退出码 0')
    } else {
        Out-Line ('DISM 结论：退出码 ' + $dismCode + '，请结合 %windir%\Logs\DISM\dism.log 查看（可能需要系统镜像作为修复源）。')
        [void]$summary.Add('DISM：已执行，退出码 ' + $dismCode + '，需看日志')
    }
}

# ---------- 3. chkdsk 只读扫描 ----------
$sysDrive = $env:SystemDrive
$chkExe = Join-Path $env:windir 'System32\chkdsk.exe'
Out-Line ''
Out-Line ('---- 3/3 chkdsk ' + $sysDrive + '（只读扫描，不修复）----')
$chkProblems = $false
if (-not (Test-Path $chkExe)) {
    Out-Line 'chkdsk 不存在，跳过。'
    [void]$summary.Add('chkdsk：工具不存在，跳过')
} else {
    $chkOut = & $chkExe $sysDrive 2>&1 | ForEach-Object { [string]$_ }
    $chkCode = $LASTEXITCODE
    foreach ($l in $chkOut) { Out-Line $l }
    $joined = $chkOut -join "`n"
    if ($chkCode -ne 0) { $chkProblems = $true }
    if ($joined -match 'found problems' -and $joined -notmatch 'found no problems') { $chkProblems = $true }
    Out-Line ('chkdsk 退出码：' + $chkCode)
    if ($chkProblems) {
        Out-Line '结论：chkdsk 报告文件系统可能存在错误（只读模式下个别提示也可能是误报）。'
        [void]$summary.Add('chkdsk：只读扫描报告有错误')
        $ans = Read-Host '是否安排在下次开机时自动修复（chkdsk /f）？输入 Y 安排，其他输入不安排'
        if ($ans -eq 'Y' -or $ans -eq 'y') {
            $schedOut = Schedule-ChkdskFix $sysDrive
            Out-Line 'chkdsk /f 输出：'
            Out-Line $schedOut
            Out-Line '已提交安排请求，请重启电脑后留意开机时的磁盘检查（过程中不要按键跳过）。'
            [void]$summary.Add('chkdsk：用户确认，已安排下次开机修复')
        } else {
            Out-Line '未安排开机修复。可日后手动以管理员身份运行 chkdsk ' + $sysDrive + ' /f 处理。'
            [void]$summary.Add('chkdsk：用户选择不安排开机修复')
        }
    } else {
        Out-Line '结论：未发现文件系统错误。'
        [void]$summary.Add('chkdsk：只读扫描未发现错误')
    }
}

# ---------- 汇总 ----------
Out-Line ''
Out-Line '================ 修复汇总 ================'
foreach ($s in $summary) { Out-Line ('- ' + $s) }
Out-Line ('结束时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$reportPath = Join-Path $ReportDir ('repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Lines | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ''
Write-Host ('记录已保存：' + $reportPath)
