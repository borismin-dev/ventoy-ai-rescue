# Check-Hardware.ps1
# 硬件检查：CPU / 内存 / 物理硬盘 / 磁盘卷 / 电池 / 主板与 BIOS
# 兼容 Windows PowerShell 2.0（Win7）至 5.1（Win11）：信息以 WMI 为主，
# Get-PhysicalDisk 等新 cmdlet 仅在系统存在时使用，否则自动回退 WMI 并如实标注。
# 结果同时输出到屏幕，并保存到同目录 reports\hardware-<时间>.txt

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
function To-GB([double]$Bytes) { return [Math]::Round($Bytes / 1073741824, 2) }
function Wmi-Date([string]$Dtm) {
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($Dtm).ToString('yyyy-MM-dd') }
    catch { return $Dtm }
}

Out-Line '================ 硬件检查报告 ================'
Out-Line ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 机型 ----------
try {
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    Out-Line ('计算机：' + $cs.Manufacturer + ' ' + $cs.Model + '（计算机名 ' + $cs.Name + '）')
} catch { Out-Line '计算机信息：读取失败' }

# ---------- CPU ----------
Out-Line ''
Out-Line '---- CPU ----'
try {
    $cpus = Get-WmiObject -Class Win32_Processor
    foreach ($cpu in $cpus) {
        $cpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        Out-Line ('型号：' + $cpuName)
        Out-Line ('物理核心：' + $cpu.NumberOfCores + '，逻辑处理器：' + $cpu.NumberOfLogicalProcessors + '，最高频率：' + $cpu.MaxClockSpeed + ' MHz')
    }
} catch { Out-Line 'CPU 信息：读取失败' }

# ---------- 内存 ----------
Out-Line ''
Out-Line '---- 内存 ----'
try {
    $totalMem = 0.0
    $stickCount = 0
    $sticks = Get-WmiObject -Class Win32_PhysicalMemory
    foreach ($m in $sticks) {
        $stickCount++
        $totalMem += [double]$m.Capacity
        $part = ''
        if ($m.PartNumber) { $part = $m.PartNumber.Trim() }
        Out-Line ('插槽 ' + $m.DeviceLocator + '：' + (To-GB ([double]$m.Capacity)) + ' GB，' + $m.Speed + ' MHz，' + $m.Manufacturer + ' ' + $part)
    }
    Out-Line ('内存总量：' + (To-GB $totalMem) + ' GB（共 ' + $stickCount + ' 条）')
} catch { Out-Line '内存信息：读取失败' }

# ---------- 物理硬盘 ----------
Out-Line ''
Out-Line '---- 物理硬盘 ----'
$diskDone = $false
if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    try {
        $pds = Get-PhysicalDisk -ErrorAction Stop
        foreach ($d in $pds) {
            Out-Line ('硬盘 ' + $d.DeviceId + '：' + $d.FriendlyName + ' | ' + (To-GB ([double]$d.Size)) + ' GB | 介质：' + $d.MediaType + ' | 健康：' + $d.HealthStatus + ' | 总线：' + $d.BusType)
        }
        $diskDone = $true
    } catch { $diskDone = $false }
}
if (-not $diskDone) {
    try {
        $dds = Get-WmiObject -Class Win32_DiskDrive
        foreach ($d in $dds) {
            $sn = ''
            if ($d.SerialNumber) { $sn = $d.SerialNumber.Trim() }
            Out-Line ('硬盘 ' + $d.Index + '：' + $d.Model + ' | ' + (To-GB ([double]$d.Size)) + ' GB | 类型：' + $d.MediaType + ' | 接口：' + $d.InterfaceType + ' | 状态：' + $d.Status + ' | 序列号：' + $sn)
        }
        Out-Line '（说明：本系统无 Get-PhysicalDisk，已用 WMI 回退；WMI 不能可靠区分 SSD/HDD，介质与健康结论以状态字段为准。）'
    } catch { Out-Line '硬盘信息：读取失败' }
}

# ---------- 磁盘卷 ----------
Out-Line ''
Out-Line '---- 磁盘卷 ----'
try {
    $vols = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3"
    foreach ($v in $vols) {
        $pct = 0
        if ([double]$v.Size -gt 0) { $pct = [Math]::Round([double]$v.FreeSpace / [double]$v.Size * 100, 1) }
        Out-Line ($v.DeviceID + ' ' + $v.VolumeName + '：总 ' + (To-GB ([double]$v.Size)) + ' GB，剩余 ' + (To-GB ([double]$v.FreeSpace)) + ' GB（' + $pct + '%）')
    }
} catch { Out-Line '磁盘卷信息：读取失败' }

# ---------- 电池 ----------
Out-Line ''
Out-Line '---- 电池 ----'
$designCap = 0
$fullCap = 0
$hasBattery = $false
try {
    $bats = Get-WmiObject -Class Win32_Battery
    foreach ($b in $bats) {
        $hasBattery = $true
        Out-Line ('电池：' + $b.Name + ' | 状态码 ' + $b.Status + ' | 当前电量约 ' + $b.EstimatedChargeRemaining + '%')
        if ($b.DesignCapacity) { $designCap = [double]$b.DesignCapacity }
        if ($b.FullChargeCapacity) { $fullCap = [double]$b.FullChargeCapacity }
    }
} catch { }
if ($hasBattery -and ($designCap -le 0 -or $fullCap -le 0)) {
    # Win32_Battery 没给容量时，尝试 root\wmi 的电池类补充
    try {
        $fc = Get-WmiObject -Namespace 'root\wmi' -Class BatteryFullChargedCapacity -ErrorAction Stop
        foreach ($x in $fc) { if ($x.FullChargedCapacity) { $fullCap = [double]$x.FullChargedCapacity } }
        $sd = Get-WmiObject -Namespace 'root\wmi' -Class BatteryStaticData -ErrorAction Stop
        foreach ($x in $sd) { if ($x.DesignedCapacity) { $designCap = [double]$x.DesignedCapacity } }
    } catch { }
}
if ($hasBattery) {
    if ($designCap -gt 0 -and $fullCap -gt 0) {
        $health = [Math]::Round($fullCap / $designCap * 100, 1)
        Out-Line ('设计容量：' + $designCap + ' mWh | 满充容量：' + $fullCap + ' mWh | 健康度约 ' + $health + '%')
    } else {
        Out-Line '设计/满充容量：该机型未通过 WMI 提供，无法计算电池健康度。'
    }
} else {
    Out-Line '未检测到电池（台式机，或电池信息不可用）。'
}

# ---------- 主板与 BIOS ----------
Out-Line ''
Out-Line '---- 主板与 BIOS ----'
try {
    $bb = Get-WmiObject -Class Win32_BaseBoard
    Out-Line ('主板：' + $bb.Manufacturer + ' ' + $bb.Product + ' | 版本 ' + $bb.Version + ' | 序列号 ' + $bb.SerialNumber)
} catch { Out-Line '主板信息：读取失败' }
try {
    $bios = Get-WmiObject -Class Win32_BIOS
    Out-Line ('BIOS：' + $bios.SMBIOSBIOSVersion + ' | 发布日期 ' + (Wmi-Date $bios.ReleaseDate) + ' | 序列号 ' + $bios.SerialNumber)
} catch { Out-Line 'BIOS 信息：读取失败' }

# ---------- 保存报告 ----------
$reportPath = Join-Path $ReportDir ('hardware-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Lines | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ''
Write-Host ('报告已保存：' + $reportPath)
