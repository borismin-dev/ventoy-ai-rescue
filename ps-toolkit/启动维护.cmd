@echo off
chcp 65001 >nul
title Windows 系统维护工具包
setlocal
cd /d "%~dp0"

rem 检查是否管理员权限（fltmc 在非管理员会话会返回错误）
fltmc >nul 2>&1
if errorlevel 1 (
    echo 正在请求管理员权限，请在弹出的提示中选择「是」...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maintenance.ps1"

echo.
echo 维护工具已退出，按任意键关闭本窗口。
pause >nul
endlocal
