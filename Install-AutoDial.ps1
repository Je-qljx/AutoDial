# ============================================================================
# Install-AutoDial.ps1 - 一键安装：注册开机自启 + 立即启动守护进程
# 优先注册计划任务（登录触发）；失败则回退启动文件夹快捷方式。
# 均为用户级操作，不需要管理员权限。可重复运行（幂等）。
# ============================================================================
$ErrorActionPreference = 'Stop'

$dir     = $PSScriptRoot
$vbs     = Join-Path $dir 'Start-AutoDial.vbs'

if (-not (Test-Path $vbs)) {
    Write-Host "未找到 $vbs，请确认安装包完整。" -ForegroundColor Red
    exit 1
}

# 0) 首次安装时自动绑定链路指纹（防误拨：只有网线插在宽带光猫上才拨号）
$bindFile = Join-Path $dir 'gateway.mac'
if (-not (Test-Path $bindFile)) {
    Write-Host '首次安装：正在自动绑定当前链路指纹…'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'AutoDial.ps1') -BindGateway
    if ($LASTEXITCODE -ne 0) {
        Write-Host '警告：指纹绑定失败。守护进程仍会安装，但在绑定前不会自动拨号。' -ForegroundColor Yellow
        Write-Host '插好宽带网线后手动运行：AutoDial.ps1 -BindGateway'
    }
}

# 1) 注册开机自启：优先计划任务（登录触发、立即执行，不受 Explorer 延迟处理
#    启动文件夹影响）；标准用户注册被拒（权限/策略）时回退启动文件夹快捷方式。
$taskName  = 'AutoDial'
$me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$installed = 'task'
try {
    $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs) -WorkingDirectory $dir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    # ExecutionTimeLimit=0 必须显式设：任务默认 72 小时强杀，守护进程会三天一死
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description '宽带自动拨号守护（开机自启）' -Force | Out-Null
    Write-Host "已注册计划任务「$taskName」（用户 $me 登录时自动启动守护）。"
    # 计划任务生效后清掉旧版启动文件夹快捷方式，避免双入口重复拉起（有 Mutex 兜底，但留着易混淆）
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'AutoDial.lnk'
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
        Write-Host "已移除旧启动项快捷方式：$lnkPath"
    }
} catch {
    Write-Host "计划任务注册失败（$($_.Exception.Message)），回退为启动文件夹快捷方式。" -ForegroundColor Yellow
    $installed = 'lnk'
    $shell = New-Object -ComObject WScript.Shell
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'AutoDial.lnk'
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force }
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $vbs
    $lnk.WorkingDirectory = $dir
    $lnk.Description       = '宽带自动拨号守护（开机自启）'
    $lnk.Save()
    Write-Host "已创建启动项：$lnkPath"
}

# 2) 立即启动守护进程（若已在运行，互斥锁会让新实例自动退出）
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden

# 3) 验证守护进程是否真的起来了
Start-Sleep -Seconds 3
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.CommandLine -like '*AutoDial.ps1*Detached*' }
if ($procs) {
    Write-Host ("守护进程已在运行（PID：{0}）。" -f (($procs | ForEach-Object { $_.ProcessId }) -join ', ')) -ForegroundColor Green
    Write-Host '日志位置：D:\AutoDial\Logs\AutoDial-日期.log'
} else {
    Write-Host '警告：未检测到守护进程，请查看 Logs 目录中的日志排查。' -ForegroundColor Yellow
}
Write-Host '如更换了宽带光猫/网线位置，请重新运行 AutoDial.ps1 -BindGateway 更新指纹。'
