# ============================================================================
# Uninstall-AutoDial.ps1 - 卸载：删除开机自启（计划任务 + 启动项快捷方式）
# + 结束正在运行的守护进程。不需要管理员权限。不会改动宽带连接本身的状态。
# ============================================================================
$ErrorActionPreference = 'Continue'

# 1) 删除自启：计划任务和启动文件夹快捷方式都清（历史安装可能是任一形态）
try {
    Unregister-ScheduledTask -TaskName 'AutoDial' -Confirm:$false -ErrorAction Stop
    Write-Host '已删除计划任务：AutoDial'
} catch {
    Write-Host '计划任务不存在（未以计划任务方式安装）。'
}
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'AutoDial.lnk'
if (Test-Path $lnkPath) {
    Remove-Item $lnkPath -Force
    Write-Host "已删除启动项：$lnkPath"
} else {
    Write-Host '启动项快捷方式不存在。'
}

# 2) 结束守护进程（排除卸载脚本自身的进程）
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.CommandLine -like '*AutoDial.ps1*' -and $_.ProcessId -ne $PID }
foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host ("已结束守护进程 PID {0}。" -f $p.ProcessId)
    } catch { }
}
if (-not $procs) { Write-Host '没有正在运行的 AutoDial 守护进程。' }

Write-Host '卸载完成。宽带连接保持当前状态不变；Logs 目录的日志如不需要可手动删除。'
