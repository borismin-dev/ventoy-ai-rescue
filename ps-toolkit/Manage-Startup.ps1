# Manage-Startup.ps1
# 自启项管理：列出全部开机自启项（注册表 Run/RunOnce、启动文件夹、
# 计划任务登录触发三处来源），默认只列出、不动任何项。
# 禁用流程：先备份再动手——注册表项导出 .reg、启动文件移入备份目录、
# 计划任务置为禁用，全部记录在 reports\startup-backup-<时间>\manifest.txt。
# 恢复模式：选择某个备份目录，按清单还原（导入 .reg、移回文件、启用任务）。
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

$script:Items = New-Object System.Collections.ArrayList
function Add-StartupItem {
    param(
        [string]$Kind, [string]$Name, [string]$Source, [string]$Detail,
        [string]$KeyPath = '', [string]$ValueName = '',
        [string]$FilePath = '', [string]$TaskPath = '', [bool]$TaskEnabled = $false
    )
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Kind $Kind
    $o | Add-Member NoteProperty Name $Name
    $o | Add-Member NoteProperty Source $Source
    $o | Add-Member NoteProperty Detail $Detail
    $o | Add-Member NoteProperty KeyPath $KeyPath
    $o | Add-Member NoteProperty ValueName $ValueName
    $o | Add-Member NoteProperty FilePath $FilePath
    $o | Add-Member NoteProperty TaskPath $TaskPath
    $o | Add-Member NoteProperty TaskEnabled $TaskEnabled
    [void]$script:Items.Add($o)
}

# ---------- 来源 1：注册表 Run / RunOnce ----------
$runKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Label = '注册表 HKLM Run' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Label = '注册表 HKLM RunOnce' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Label = '注册表 HKCU Run' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Label = '注册表 HKCU RunOnce' },
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'; Label = '注册表 HKLM Run（32 位视图）' }
)
foreach ($k in $runKeys) {
    if (Test-Path $k.Path) {
        try {
            $regItem = Get-Item $k.Path
            foreach ($vn in $regItem.GetValueNames()) {
                if ([string]::IsNullOrEmpty($vn)) { continue }
                $val = $regItem.GetValue($vn)
                Add-StartupItem -Kind 'REG' -Name $vn -Source $k.Label -Detail ([string]$val) -KeyPath $k.Path -ValueName $vn
            }
        } catch { }
    }
}

# ---------- 来源 2：启动文件夹 ----------
$startupFolders = @(
    @{ Path = [Environment]::GetFolderPath('Startup'); Label = '启动文件夹（当前用户）' },
    @{ Path = [Environment]::GetFolderPath('CommonStartup'); Label = '启动文件夹（所有用户）' }
)
foreach ($f in $startupFolders) {
    if ($f.Path -and (Test-Path $f.Path)) {
        $files = Get-ChildItem -Path $f.Path -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.Name -ne 'desktop.ini' }
        foreach ($file in $files) {
            Add-StartupItem -Kind 'FILE' -Name $file.Name -Source $f.Label -Detail $file.FullName -FilePath $file.FullName
        }
    }
}

# ---------- 来源 3：计划任务（登录触发） ----------
function Read-TaskFolder($folder) {
    try {
        $tasks = $folder.GetTasks(0)
        foreach ($t in $tasks) {
            $isLogon = $false
            try {
                foreach ($tr in $t.Definition.Triggers) {
                    if ($tr.Type -eq 9) { $isLogon = $true }
                }
            } catch { }
            if ($isLogon) {
                $actPath = ''
                try { $actPath = [string]$t.Definition.Actions.Item(1).Path } catch { }
                Add-StartupItem -Kind 'TASK' -Name $t.Name -Source ('计划任务 ' + $t.Path) -Detail $actPath -TaskPath $t.Path -TaskEnabled ([bool]$t.Enabled)
            }
        }
    } catch { }
    try {
        $subs = $folder.GetFolders(0)
        foreach ($sf in $subs) { Read-TaskFolder $sf }
    } catch { }
}
try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    Read-TaskFolder ($svc.GetFolder('\'))
} catch {
    Write-Host ('计划任务读取失败（' + $_.Exception.Message + '），本次列表不含计划任务来源。') -ForegroundColor Yellow
}

# ---------- 列表展示 ----------
Write-Host ''
Write-Host '================ 开机自启项列表 ================'
if ($script:Items.Count -eq 0) {
    Write-Host '未发现自启项。'
    return
}
for ($i = 0; $i -lt $script:Items.Count; $i++) {
    $it = $script:Items[$i]
    Write-Host ('[{0}] {1}' -f ($i + 1), $it.Name)
    Write-Host ('     来源：' + $it.Source)
    Write-Host ('     内容：' + $it.Detail)
    if ($it.Kind -eq 'TASK' -and -not $it.TaskEnabled) {
        Write-Host '     状态：已是禁用状态'
    }
}
Write-Host ('共 ' + $script:Items.Count + ' 项。默认仅查看，不做任何更改。')
Write-Host ''
Write-Host '操作：[D] 禁用所选自启项   [R] 从备份恢复   [其他任意键] 仅查看并退出'
$mode = Read-Host '请选择'

# ---------- 禁用流程 ----------
function Invoke-Disable {
    $sel = Read-Host '输入要禁用的编号（多个用逗号分隔，如 1,3,5）'
    $nums = New-Object System.Collections.ArrayList
    foreach ($part in ($sel -split ',')) {
        $p = $part.Trim()
        if ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $script:Items.Count -and -not $nums.Contains($n)) { [void]$nums.Add($n) }
        }
    }
    if ($nums.Count -eq 0) {
        Write-Host '没有有效的编号，未做任何更改。'
        return
    }
    $backupDir = Join-Path $ReportDir ('startup-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    $manifest = New-Object System.Collections.ArrayList
    $exported = @{}
    $regIndex = 0
    foreach ($n in $nums) {
        $it = $script:Items[$n - 1]
        switch ($it.Kind) {
            'REG' {
                if (-not $exported.ContainsKey($it.KeyPath)) {
                    $regIndex++
                    $regFile = 'reg-backup-' + $regIndex + '.reg'
                    $native = $it.KeyPath -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
                    & reg.exe export $native (Join-Path $backupDir $regFile) /y | Out-Null
                    $exported[$it.KeyPath] = $regFile
                }
                [void]$manifest.Add('REG|' + $it.KeyPath + '|' + $it.ValueName + '|' + $it.Detail)
                try {
                    Remove-ItemProperty -Path $it.KeyPath -Name $it.ValueName -ErrorAction Stop
                    Write-Host ('已禁用（注册表）：' + $it.Name)
                } catch {
                    Write-Host ('禁用失败：' + $it.Name + '（' + $_.Exception.Message + '）') -ForegroundColor Yellow
                }
            }
            'FILE' {
                $dest = Join-Path $backupDir $it.Name
                if (Test-Path $dest) { $dest = Join-Path $backupDir ([string]$n + '-' + $it.Name) }
                try {
                    Move-Item -LiteralPath $it.FilePath -Destination $dest -ErrorAction Stop
                    [void]$manifest.Add('FILE|' + $it.FilePath + '|' + (Split-Path $dest -Leaf))
                    Write-Host ('已禁用（启动文件已移入备份）：' + $it.Name)
                } catch {
                    Write-Host ('禁用失败：' + $it.Name + '（' + $_.Exception.Message + '）') -ForegroundColor Yellow
                }
            }
            'TASK' {
                [void]$manifest.Add('TASK|' + $it.TaskPath + '|' + $it.TaskEnabled)
                $r = & schtasks.exe /Change /TN $it.TaskPath /DISABLE 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ('已禁用（计划任务）：' + $it.Name)
                } else {
                    Write-Host ('计划任务禁用失败：' + $it.Name + '（' + $r + '）') -ForegroundColor Yellow
                }
            }
        }
    }
    $manifest | Set-Content -Path (Join-Path $backupDir 'manifest.txt') -Encoding UTF8
    Write-Host ''
    Write-Host ('备份目录：' + $backupDir)
    Write-Host '内含注册表导出（.reg）、被移动的启动文件与清单 manifest.txt。'
    Write-Host '如需恢复：再次运行本脚本，选择 R 并选中这个备份目录。'
}

# ---------- 恢复流程 ----------
function Invoke-Restore {
    $dirs = Get-ChildItem -Path $ReportDir -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -and $_.Name -like 'startup-backup-*' } |
        Sort-Object Name
    $dirCount = ($dirs | Measure-Object).Count
    if ($dirCount -eq 0) {
        Write-Host '没有找到任何备份目录（reports\startup-backup-*）。'
        return
    }
    Write-Host '已有备份：'
    $idx = 0
    foreach ($d in $dirs) {
        $idx++
        Write-Host ('  [{0}] {1}' -f $idx, $d.Name)
    }
    $pick = Read-Host '输入要恢复的备份编号'
    if ($pick -notmatch '^\d+$') { Write-Host '输入无效，取消恢复。'; return }
    $pickN = [int]$pick
    if ($pickN -lt 1 -or $pickN -gt $dirCount) { Write-Host '编号超出范围，取消恢复。'; return }
    $dir = $dirs[$pickN - 1].FullName
    Write-Host ('正在从备份恢复：' + $dir)
    $regFiles = Get-ChildItem -Path $dir -Filter '*.reg' -ErrorAction SilentlyContinue
    foreach ($rf in $regFiles) {
        & reg.exe import $rf.FullName | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host ('已导入注册表备份：' + $rf.Name) }
        else { Write-Host ('注册表导入失败：' + $rf.Name) -ForegroundColor Yellow }
    }
    $mf = Join-Path $dir 'manifest.txt'
    if (Test-Path $mf) {
        foreach ($line in (Get-Content $mf)) {
            if ($line -match '^FILE\|') {
                $parts = $line -split '\|', 3
                $orig = $parts[1]
                $bak = Join-Path $dir $parts[2]
                if (Test-Path $bak) {
                    if (Test-Path $orig) {
                        Write-Host ('目标已存在，跳过恢复：' + $orig) -ForegroundColor Yellow
                    } else {
                        Move-Item -LiteralPath $bak -Destination $orig
                        Write-Host ('已恢复启动文件：' + $orig)
                    }
                }
            } elseif ($line -match '^TASK\|') {
                $parts = $line -split '\|', 3
                if ($parts[2] -eq 'True') {
                    & schtasks.exe /Change /TN $parts[1] /ENABLE | Out-Null
                    if ($LASTEXITCODE -eq 0) { Write-Host ('已重新启用计划任务：' + $parts[1]) }
                    else { Write-Host ('计划任务启用失败：' + $parts[1]) -ForegroundColor Yellow }
                }
            }
        }
    }
    Write-Host '恢复完成。'
}

if ($mode -eq 'D' -or $mode -eq 'd') { Invoke-Disable }
elseif ($mode -eq 'R' -or $mode -eq 'r') { Invoke-Restore }
else { Write-Host '未做任何更改。' }
