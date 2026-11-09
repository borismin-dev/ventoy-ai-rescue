# Maintenance.ps1
# Windows 系统维护工具包 - 主菜单
# 兼容 Windows PowerShell 2.0（Win7）至 5.1（Win11）
# 建议通过同目录「启动维护.cmd」双击运行（自动请求管理员权限）

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try { $Host.UI.RawUI.WindowTitle = 'Windows 系统维护工具包' } catch { }

if (-not (Test-IsAdmin)) {
    Write-Host ''
    Write-Host '当前 PowerShell 不是管理员权限，维护功能无法运行。' -ForegroundColor Yellow
    Write-Host '请关闭本窗口，双击同目录的「启动维护.cmd」（会自动请求管理员权限），'
    Write-Host '或右键 PowerShell 选择「以管理员身份运行」后再执行本脚本。'
    Write-Host ''
    Read-Host '按回车退出' | Out-Null
    return
}

function Show-HelpText {
    Write-Host ''
    Write-Host '================ 使用说明 ================'
    Write-Host '本工具包用于「能进 Windows 桌面后」的硬件检查与系统维护优化，'
    Write-Host '与 U 盘里的 PE 版分工：'
    Write-Host '  - PE 版：系统进不去时的离线急救（离线清理、修复引导等）。'
    Write-Host '  - 本工具包：系统正常进桌面后的检查、清理与修复。'
    Write-Host ''
    Write-Host '菜单功能：'
    Write-Host '  1 硬件检查    ：CPU / 内存 / 硬盘 / 电池 / 主板信息，生成报告。'
    Write-Host '  2 系统健康报告：系统版本、近 7 天错误日志、更新与安全状态。'
    Write-Host '  3 一键清理    ：白名单清理临时文件等，先统计、确认后才删除。'
    Write-Host '  4 系统修复    ：sfc、DISM（Win8 以上）、chkdsk 只读扫描。'
    Write-Host '  5 自启项管理  ：查看 / 禁用开机自启项，禁用前自动备份，可恢复。'
    Write-Host ''
    Write-Host '安全边界：不联网、不下载、不做注册表清理、不关安全软件与系统更新；'
    Write-Host '所有会改动系统的操作都会先说明并等待确认，报告保存在 reports 文件夹。'
    Write-Host ('详细说明见同目录 README.md（工具目录：' + $ScriptDir + '）')
}

$running = $true
while ($running) {
    Write-Host ''
    Write-Host '================ Windows 系统维护工具包 ================'
    Write-Host '  1. 硬件检查'
    Write-Host '  2. 系统健康报告'
    Write-Host '  3. 一键清理'
    Write-Host '  4. 系统修复'
    Write-Host '  5. 自启项管理'
    Write-Host '  6. 使用说明'
    Write-Host '  0. 退出'
    Write-Host '=========================================================='
    $choice = Read-Host '请输入编号（0-6）'
    switch ($choice) {
        '1' { & (Join-Path $ScriptDir 'Check-Hardware.ps1') }
        '2' { & (Join-Path $ScriptDir 'Check-System.ps1') }
        '3' { & (Join-Path $ScriptDir 'Clean-System.ps1') }
        '4' { & (Join-Path $ScriptDir 'Repair-System.ps1') }
        '5' { & (Join-Path $ScriptDir 'Manage-Startup.ps1') }
        '6' { Show-HelpText }
        '0' { $running = $false }
        default { Write-Host '输入无效，请输入 0-6 的编号。' -ForegroundColor Yellow }
    }
    if ($running) {
        Write-Host ''
        Read-Host '按回车返回菜单' | Out-Null
    }
}
Write-Host '已退出。'
