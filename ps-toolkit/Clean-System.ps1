# Clean-System.ps1
# 一键清理（安全白名单）：用户/系统临时文件、Windows Update 下载缓存、
# 回收站、缩略图/图标缓存、传递优化文件（有则清）。
# 流程钉死：先 dry-run 统计可清理大小 -> 屏幕展示 -> 用户输入 Y 确认后才真删。
# 绝不碰：pagefile.sys / hiberfil.sys、用户文档、浏览器书签/密码等数据，
# 白名单之外的任何路径一律不动。
# 兼容 Windows PowerShell 2.0（Win7）至 5.1（Win11）。
# 记录保存到同目录 reports\clean-<时间>.txt

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
function Format-Bytes([double]$b) {
    if ($b -ge 1073741824) { return ('{0:N2} GB' -f ($b / 1073741824)) }
    if ($b -ge 1048576) { return ('{0:N2} MB' -f ($b / 1048576)) }
    if ($b -ge 1024) { return ('{0:N1} KB' -f ($b / 1024)) }
    return ('{0:N0} B' -f $b)
}

# ---------- 目标定义（白名单写死，不接受外部传参改路径） ----------
function New-Target {
    param([string]$Name, [string]$Kind, [string]$Path, [string[]]$Patterns, [string[]]$Services)
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Name $Name
    $o | Add-Member NoteProperty Kind $Kind
    $o | Add-Member NoteProperty Path $Path
    $o | Add-Member NoteProperty Patterns $Patterns
    $o | Add-Member NoteProperty Services $Services
    $o | Add-Member NoteProperty Before 0.0
    return $o
}

$windirPath = $env:windir
$targets = New-Object System.Collections.ArrayList
[void]$targets.Add((New-Target -Name '当前用户临时文件' -Kind 'DIR' -Path $env:TEMP))
[void]$targets.Add((New-Target -Name '系统临时文件' -Kind 'DIR' -Path (Join-Path $windirPath 'Temp')))
[void]$targets.Add((New-Target -Name 'Windows Update 下载缓存' -Kind 'DIR' -Path (Join-Path $windirPath 'SoftwareDistribution\Download') -Services @('wuauserv', 'bits')))
$explorerCache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
[void]$targets.Add((New-Target -Name '缩略图/图标缓存' -Kind 'FILES' -Path $explorerCache -Patterns @('thumbcache_*.db', 'iconcache_*.db')))
[void]$targets.Add((New-Target -Name '图标缓存（旧位置）' -Kind 'FILE' -Path (Join-Path $env:LOCALAPPDATA 'IconCache.db')))
[void]$targets.Add((New-Target -Name '传递优化文件' -Kind 'DIR' -Path (Join-Path $windirPath 'SoftwareDistribution\DeliveryOptimization') -Services @('DoSvc')))
[void]$targets.Add((New-Target -Name '回收站（全部固定磁盘）' -Kind 'RECYCLE' -Path ''))

# ---------- 测量 ----------
function Get-DirSize([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $m = Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Measure-Object -Property Length -Sum
    if ($null -eq $m.Sum) { return 0.0 }
    return [double]$m.Sum
}
function Get-RecyclePaths {
    $list = New-Object System.Collections.ArrayList
    try {
        $drives = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3"
        foreach ($d in $drives) {
            $rp = $d.DeviceID + '\$Recycle.Bin'
            if (Test-Path $rp) { [void]$list.Add($rp) }
        }
    } catch { }
    # 用一元逗号返回，保证调用方拿到的始终是带 .Count 的集合（0/1/多个都成立）
    return ,$list
}
function Measure-Target($t) {
    switch ($t.Kind) {
        'DIR' { return Get-DirSize $t.Path }
        'FILE' {
            if (Test-Path $t.Path) { return [double](Get-Item $t.Path -Force).Length }
            return $null
        }
        'FILES' {
            if (-not (Test-Path $t.Path)) { return $null }
            $sum = 0.0
            foreach ($pat in $t.Patterns) {
                $fs = Get-ChildItem -Path $t.Path -Filter $pat -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer }
                foreach ($f in $fs) { $sum += [double]$f.Length }
            }
            return $sum
        }
        'RECYCLE' {
            $paths = Get-RecyclePaths
            if ($paths.Count -eq 0) { return $null }
            $sum = 0.0
            foreach ($rp in $paths) {
                $s = Get-DirSize $rp
                if ($null -ne $s) { $sum += $s }
            }
            return $sum
        }
    }
    return $null
}

# ---------- 清理 ----------
function Clear-DirContents([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Stop-TargetServices($t) {
    $wasRunning = New-Object System.Collections.ArrayList
    if ($t.Services) {
        foreach ($name in $t.Services) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                try {
                    Stop-Service -Name $name -Force -ErrorAction Stop
                    [void]$wasRunning.Add($name)
                } catch { }
            }
        }
    }
    return $wasRunning
}
function Start-ServicesList($list) {
    foreach ($name in $list) {
        try { Start-Service -Name $name -ErrorAction SilentlyContinue } catch { }
    }
}
function Clear-Target($t) {
    $restart = Stop-TargetServices $t
    try {
        switch ($t.Kind) {
            'DIR' { Clear-DirContents $t.Path }
            'FILE' { Remove-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue }
            'FILES' {
                foreach ($pat in $t.Patterns) {
                    Get-ChildItem -Path $t.Path -Filter $pat -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.PSIsContainer } |
                        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                }
            }
            'RECYCLE' {
                foreach ($rp in (Get-RecyclePaths)) { Clear-DirContents $rp }
            }
        }
    } finally {
        Start-ServicesList $restart
    }
}

# ---------- 主流程：先统计 ----------
Out-Line '================ 一键清理（安全白名单）================'
Out-Line ('统计时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Out-Line '清理范围仅限下列白名单项，不涉及文档、浏览器数据、pagefile/hiberfil。'
Out-Line ''
$totalBefore = 0.0
foreach ($t in $targets) {
    $size = Measure-Target $t
    if ($null -eq $size) {
        Out-Line ('[跳过] ' + $t.Name + '：不存在')
        $t.Before = -1
    } else {
        $t.Before = [double]$size
        $totalBefore += [double]$size
        Out-Line ('[可清] ' + $t.Name + '：' + (Format-Bytes ([double]$size)) + '（' + $t.Path + '）')
    }
}
Out-Line ''
Out-Line ('预计可清理总量约：' + (Format-Bytes $totalBefore))

if ($totalBefore -le 0) {
    Out-Line '没有可清理的内容，本次结束。'
} else {
    $confirm = Read-Host '确认删除以上内容吗？输入 Y 并回车执行，其他任意输入取消'
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Out-Line '用户取消，未删除任何文件。'
    } else {
        Out-Line ''
        Out-Line '---- 开始清理 ----'
        $totalFreed = 0.0
        foreach ($t in $targets) {
            if ($t.Before -lt 0) { continue }
            try { Clear-Target $t } catch { Out-Line ('清理出错：' + $t.Name + '（' + $_.Exception.Message + '），继续下一项') }
            $after = Measure-Target $t
            if ($null -eq $after) { $after = 0.0 }
            $freed = [double]$t.Before - [double]$after
            if ($freed -lt 0) { $freed = 0 }
            $totalFreed += $freed
            Out-Line ($t.Name + '：实际释放 ' + (Format-Bytes $freed) + '（剩余 ' + (Format-Bytes ([double]$after)) + '，被占用/锁定的文件已自动跳过）')
        }
        Out-Line ''
        Out-Line ('清理完成，实际释放总量约：' + (Format-Bytes $totalFreed))
    }
}

$reportPath = Join-Path $ReportDir ('clean-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Lines | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ''
Write-Host ('记录已保存：' + $reportPath)
