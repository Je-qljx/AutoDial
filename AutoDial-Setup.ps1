# ============================================================================
# AutoDial-Setup.ps1 - AutoDial 管理界面（换机向导 / 控制面板）
#
# 面向非开发人员：打开即自动体检，红灯项旁给出修复按钮，全绿即换机完成。
# 不复制守护逻辑：安装/卸载/绑定均调用现有脚本（Install/Uninstall/BindGateway），
# 守护本体 AutoDial.ps1 的后台循环不受本界面影响。
#
# 启动方式：双击 打开管理界面.vbs（无黑窗）；或手动 powershell -File 本脚本
#
# 检查项：
#   1. AutoDial.json 配置文件存在且合法
#   2. 宽带连接条目存在（rasdial 清单 + Get-NetAdapter 双查）
#   3. 拨号弹窗已关（rasphone.pbk 的 PreviewUserPw=0），可一键修复
#   4. 有线网卡在位（名称与配置一致；红灯行「选择网卡」可从本机网卡列表勾选）
#   5. 链路指纹已绑定（gateway.mac 存在）
#   6. 开机自启已安装（计划任务 AutoDial 优先，回退启动文件夹 AutoDial.lnk）
#   7. 守护进程运行中（Mutex 探测，不干扰现有单实例机制）
# ============================================================================

# ----------------------------- 基础设施 -----------------------------
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainPs1 = Join-Path $Root 'AutoDial.ps1'
$InstPs1 = Join-Path $Root 'Install-AutoDial.ps1'
$UninstPs1 = Join-Path $Root 'Uninstall-AutoDial.ps1'
$ConfigFile  = Join-Path $Root 'AutoDial.json'
$BindFile    = Join-Path $Root 'gateway.mac'
$LogDirPath  = Join-Path $Root 'Logs'
$StartupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoDial.lnk'
$TaskName    = 'AutoDial'
$PbkPath     = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$MutexName   = 'AutoDial_BroadbandGuard'

# 与 AutoDial.ps1 内置默认值保持一致的模板（JSON 缺失时生成）
$DefaultConfig = [ordered]@{
    BroadbandName      = '宽带连接'
    WiredAdapters      = @('以太网')
    CheckInterval      = 15
    ProbeIPs           = @('223.5.5.5', '119.29.29.29', '114.114.114.114')
    ProbePort          = 53
    ProbeTimeoutMs     = 3000
    FailThreshold      = 3
    BaseBackoffSec     = 15
    MaxBackoffSec      = 600
    AuthFailBackoffSec = 900
    AuthFastRetryCount = 6
    FastPollIntervalSec = 5
    FastPollWindowSec   = 120
    LogKeepDays        = 30
    EnableLogFile      = $true
}

# 读配置（返回 $null 表示文件缺失或非法）
function Get-Config {
    if (-not (Test-Path $ConfigFile)) { return $null }
    try {
        $cfg = Get-Content -Raw -Path $ConfigFile -Encoding UTF8 | ConvertFrom-Json
        if (-not $cfg.BroadbandName) { return $null }
        return $cfg
    } catch { return $null }
}

# 生成默认配置模板
function New-DefaultConfig {
    $DefaultConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigFile -Encoding UTF8
}

# 更新配置文件里的单个键（其余键原样保留）。文件缺失时先落默认模板。
# 注意 PS 5.1 的 ConvertTo-Json 会把单元素数组塌成标量，数组值需保持 [string[]] 类型；
# ConvertTo-Json 对顶层 PSCustomObject 输出四空格缩进（与既有文件风格一致）。
function Update-ConfigKey {
    param([string]$Key, $Value)
    if (-not (Test-Path $ConfigFile)) { New-DefaultConfig }
    Copy-Item $ConfigFile ($ConfigFile + '.bak') -Force
    $cfg = Get-Content -Raw -Path $ConfigFile -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.PSObject.Properties[$Key]) {
        $cfg.PSObject.Properties[$Key].Value = $Value
    } else {
        [void]$cfg.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty($Key, $Value)))
    }
    $out = $cfg | ConvertTo-Json -Depth 3
    Set-Content -Path $ConfigFile -Value $out -Encoding UTF8
}

# 检测守护进程是否在运行：探测命名 Mutex（只打开不创建，不干扰现有实例）
function Test-GuardRunning {
    try {
        $m = $null
        if ([System.Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m)) {
            $m.Close(); return $true
        }
    } catch { }
    return $false
}

# 读配置里的宽带条目名/网卡名（配置非法时回退默认，保证界面总能显示）
function Get-CfgValue {
    param([string]$Name, $Fallback)
    $cfg = $script:Cfg
    if ($cfg -and $cfg.PSObject.Properties[$Name]) { return $cfg.PSObject.Properties[$Name].Value }
    return $Fallback
}

# 读 pbk（rasphone.pbk）：不同系统写出的编码不同（本机实测 UTF-8 无 BOM，
# 传统系统是 UTF-16 带 BOM），自动识别并返回解码文本 + 原编码对象，
# 写回时用同一编码对象，保证不把文件写坏。EntryName 用于在歧义时挑选正确解码。
function Read-PbkDecoded {
    param([string]$Path, [string]$EntryName)
    if (-not (Test-Path $Path)) { return $null }
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return $null }
    $cands = @()
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $cands += ,@([System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2), [System.Text.Encoding]::Unicode)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $cands += ,@([System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2), [System.Text.Encoding]::BigEndianUnicode)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $cands += ,@((New-Object System.Text.UTF8Encoding($false)).GetString($bytes, 3, $bytes.Length - 3), (New-Object System.Text.UTF8Encoding($true)))
    } else {
        # 无 BOM：先试严格 UTF-8 解码（非法字节会抛异常），再补 ANSI(GBK) 候选
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try { $cands += ,@($strict.GetString($bytes), (New-Object System.Text.UTF8Encoding($false))) } catch { }
        $cands += ,@([System.Text.Encoding]::Default.GetString($bytes), [System.Text.Encoding]::Default)
    }
    foreach ($c in $cands) {
        if ($c[0] -match ('(?m)^\[\s*' + [regex]::Escape($EntryName) + '\s*\]')) {
            return @{ Text = $c[0]; Enc = $c[1] }
        }
    }
    if ($cands.Count -gt 0) { return @{ Text = $cands[0][0]; Enc = $cands[0][1] } }
    return $null
}

# ----------------------------- 检查项实现 -----------------------------
# 每项返回 @{ Ok=bool; Detail=string; Fix=string(修复动作标识, $null=无修复) }

function Check-Config {
    $cfg = Get-Config
    if ($null -eq $cfg) {
        if (-not (Test-Path $ConfigFile)) {
            return @{ Ok=$false; Detail='配置文件不存在（将生成默认模板）'; Fix='GenConfig' }
        }
        return @{ Ok=$false; Detail='配置文件格式非法（可重新生成默认模板）'; Fix='GenConfig' }
    }
    return @{ Ok=$true; Detail=('宽带条目「{0}」/ 网卡「{1}」' -f $cfg.BroadbandName, (@($cfg.WiredAdapters) -join ',')); Fix=$null }
}

function Check-BroadbandEntry {
    $name = Get-CfgValue 'BroadbandName' '宽带连接'
    # rasdial 空清单也输出表头「没有指定...」之外还会列出所有条目名；用 Get-NetAdapter 双查
    $ad = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    if ($ad) { return @{ Ok=$true; Detail=('条目「{0}」存在（PPPoE 网卡在系统注册）' -f $name); Fix=$null } }
    $out = & "$env:SystemRoot\System32\rasdial.exe" 2>$null
    if ($out -and (($out -join "`n") -match [regex]::Escape($name))) {
        return @{ Ok=$true; Detail=('条目「{0}」存在（rasdial 清单）' -f $name); Fix=$null }
    }
    return @{ Ok=$false; Detail=('未找到宽带条目「{0}」——请先在系统设置里手动建立宽带连接并连上一次' -f $name); Fix=$null }
}

function Check-PbkSilent {
    $name = Get-CfgValue 'BroadbandName' '宽带连接'
    if (-not (Test-Path $PbkPath)) {
        return @{ Ok=$false; Detail='未找到 rasphone.pbk（宽带条目尚未创建）'; Fix=$null }
    }
    $pbk = Read-PbkDecoded -Path $PbkPath -EntryName $name
    if (-not $pbk) {
        return @{ Ok=$false; Detail='rasphone.pbk 读取失败'; Fix=$null }
    }
    $raw = $pbk.Text
    # pbk 是 INI 风格：[条目名] 段内 PreviewUserPw=x（1=弹窗，0=静默）
    $rxEntry = [regex]::Escape($name)
    $m = [regex]::Match($raw, "(?s)\[\s*$rxEntry\s*\](.*?)(?=\r?\n\[|\z)")
    if (-not $m.Success) {
        return @{ Ok=$false; Detail=('pbk 中没有条目「{0}」段' -f $name); Fix=$null }
    }
    $section = $m.Groups[1].Value
    $pm = [regex]::Match($section, 'PreviewUserPw\s*=\s*(\d+)')
    if (-not $pm.Success) {
        # 键缺失时按系统默认处理：rasphone 新建条目默认勾选「提示名称、密码、证书等」，
        # 保守起见视为未关闭弹窗，允许一键写入 PreviewUserPw=0
        return @{ Ok=$false; Detail='pbk 未设置 PreviewUserPw（新建条目默认会弹凭据框），建议一键关闭'; Fix='FixPbk' }
    }
    if ($pm.Groups[1].Value -eq '0') {
        return @{ Ok=$true; Detail='拨号弹窗已关闭（PreviewUserPw=0，静默拨号）'; Fix=$null }
    }
    return @{ Ok=$false; Detail=('拨号会弹凭据确认框，卡住无人值守流程（PreviewUserPw={0}）' -f $pm.Groups[1].Value); Fix='FixPbk' }
}

function Check-Adapter {
    $names = @(Get-CfgValue 'WiredAdapters' @('以太网'))
    $found = @()
    foreach ($n in $names) {
        $ad = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
        if ($ad) {
            $mcs = $ad.MediaConnectState
            $connected = if ($mcs -is [string]) { $mcs -eq 'Connected' } else { [int]$mcs -eq 1 }
            $found += ('{0}({1})' -f $n, $(if ($connected) { '网线在位' } else { '未插线' }))
        }
    }
    if ($found.Count -gt 0) {
        return @{ Ok=$true; Detail=('已找到：{0}' -f ($found -join '、')); Fix=$null }
    }
    return @{ Ok=$false; Detail=('找不到名为「{0}」的网卡——点右侧「选择网卡」从本机网卡列表里挑（或核对 AutoDial.json 的 WiredAdapters）' -f ($names -join ',')); Fix='PickAdapter' }
}

function Check-Fingerprint {
    if (Test-Path $BindFile) {
        return @{ Ok=$true; Detail='链路指纹已绑定（gateway.mac 存在，拨号成功后还会自动学习）'; Fix=$null }
    }
    return @{ Ok=$false; Detail='链路指纹未绑定——不绑定时任何网线在位都可能触发拨号（有误拨风险）'; Fix='BindGateway' }
}

function Check-AutoStart {
    # 与 Install-AutoDial.ps1 的双形态对应：优先计划任务，其次启动文件夹快捷方式
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return @{ Ok=$true; Detail=('开机自启已安装（计划任务 {0}，登录触发）' -f $t.TaskName); Fix=$null }
    } catch { }
    if (Test-Path $StartupLnk) {
        return @{ Ok=$true; Detail='开机自启已安装（启动文件夹 AutoDial.lnk，计划任务不可用时的回退形态）'; Fix=$null }
    }
    return @{ Ok=$false; Detail='开机自启未安装'; Fix='Install' }
}

function Check-GuardRunning {
    if (Test-GuardRunning) {
        return @{ Ok=$true; Detail='守护进程运行中（单实例互斥锁在线）'; Fix=$null }
    }
    return @{ Ok=$false; Detail='守护进程未运行'; Fix='StartGuard' }
}

$script:Checks = @(
    @{ Name='配置文件';   Func=${function:Check-Config} },
    @{ Name='宽带条目';   Func=${function:Check-BroadbandEntry} },
    @{ Name='拨号弹窗';   Func=${function:Check-PbkSilent} },
    @{ Name='有线网卡';   Func=${function:Check-Adapter} },
    @{ Name='链路指纹';   Func=${function:Check-Fingerprint} },
    @{ Name='开机自启';   Func=${function:Check-AutoStart} },
    @{ Name='守护进程';   Func=${function:Check-GuardRunning} }
)

# ----------------------------- 操作实现 -----------------------------
# 都以子进程跑现有脚本，输出回灌 GUI 日志区，不在 GUI 里重写逻辑

$script:Busy = $false

function Invoke-ScriptOutput {
    param([string]$Title, [string]$FilePath, [string[]]$ArgumentList = @())
    Append-Log ('──── {0} ────' -f $Title)
    try {
        # 用 ProcessStartInfo 隐藏窗口运行（直接 & 调用会弹出黑色控制台窗口）
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'powershell.exe'
        $psi.Arguments              = (@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $FilePath)) + $ArgumentList) -join ' '
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)   # 控制台输出 GBK，避免中文乱码
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::GetEncoding(936)
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        # 轮询等待 + DoEvents，避免同步阻塞导致界面假死
        $deadline = [datetime]::Now.AddMinutes(5)
        while (-not $proc.HasExited -and [datetime]::Now -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if (-not $proc.HasExited) { $proc.Kill(); Append-Log '  ✘ 操作超时（5 分钟）已中止。' }
        [void]$outTask.Wait(3000)
        [void]$errTask.Wait(3000)
        $code = $proc.ExitCode
        $lines = @()
        foreach ($line in ($outTask.Result -split "`r?`n")) { if ($line.Trim()) { $lines += $line } }
        foreach ($line in ($errTask.Result -split "`r?`n")) { if ($line.Trim()) { $lines += ('[stderr] ' + $line) } }
        foreach ($line in $lines) { Append-Log ('  ' + $line) }
        if ($code -eq 0) {
            Append-Log ('  ✔ {0} 完成。' -f $Title)
        } else {
            Append-Log ('  ✘ {0} 退出码 {1}。' -f $Title, $code)
        }
    } catch {
        Append-Log ('  ✘ {0} 异常：{1}' -f $Title, $_.Exception.Message)
    }
    Refresh-All
}

function Start-GuardHidden {
    Append-Log '──── 启动守护进程 ────'
    $vbs = Join-Path $Root 'Start-AutoDial.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden
    } else {
        # 无 vbs 时直接隐藏拉起（保留兜底能力）
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $MainPs1),'-Detached') -WindowStyle Hidden
    }
    Start-Sleep -Seconds 2
    if (Test-GuardRunning) { Append-Log '  ✔ 守护进程已启动。' }
    else { Append-Log '  ⚠ 守护进程尚未上报运行状态（可能仍在启动中），稍后状态区会自动刷新。' }
    Refresh-All
}

function Stop-GuardAndUninstall {
    Invoke-ScriptOutput -Title '停止并卸载' -FilePath $UninstPs1
}

function Repair-Pbk {
    $name = Get-CfgValue 'BroadbandName' '宽带连接'
    if (-not (Test-Path $PbkPath)) {
        Append-Log '──── 修复拨号弹窗 ────'
        Append-Log '  ✘ 未找到 rasphone.pbk，无法修复。请先创建宽带连接。'
        return
    }
    try {
        $pbk = Read-PbkDecoded -Path $PbkPath -EntryName $name
        if (-not $pbk) {
            Append-Log '  ✘ rasphone.pbk 读取失败。'
            return
        }
        $raw = $pbk.Text
        $rxEntry = [regex]::Escape($name)
        $m = [regex]::Match($raw, "(?s)\[\s*$rxEntry\s*\](.*?)(?=\r?\n\[|\z)")
        if (-not $m.Success) {
            Append-Log ('  ✘ pbk 中没有条目「{0}」段。' -f $name)
            return
        }
        # 只替换该条目段内的 PreviewUserPw 数字，改前备份整个文件（保持原编码写回）
        $bak = "$PbkPath.bak"
        [System.IO.File]::WriteAllBytes($bak, [System.IO.File]::ReadAllBytes($PbkPath))
        $section = $m.Groups[1].Value
        $newSection = [regex]::Replace($section, 'PreviewUserPw\s*=\s*\d+', 'PreviewUserPw=0')
        if ($newSection -eq $section) {
            # 段内没有该键：插在段首（键顺序无关）
            $newSection = [Environment]::NewLine + 'PreviewUserPw=0' + $section
        }
        $newRaw = $raw.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $newSection)
        [System.IO.File]::WriteAllText($PbkPath, $newRaw, $pbk.Enc)
        Append-Log ('  ✔ 已把条目「{0}」的 PreviewUserPw 改为 0（静默拨号）。原文件备份为 {1}' -f $name, $bak)
    } catch {
        Append-Log ('  ✘ 修复失败：{0}' -f $_.Exception.Message)
    }
    Refresh-All
}

function Bind-Gateway {
    if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) { New-DefaultConfig }
    Invoke-ScriptOutput -Title '绑定链路指纹（需宽带网线在位）' -FilePath $MainPs1 -ArgumentList @('-BindGateway')
}

# ----------------------------- 界面构建 -----------------------------
$script:Cfg = Get-Config

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'AutoDial 宽带拨号管理器'
# 用 ClientSize（客户区）而非 Size（含标题栏/边框的外框）：底部按钮行定位在
# y=604~632，若按外框 640 算，标题栏吃掉约 30px 后按钮整行落到客户区外被裁掉
$form.ClientSize    = New-Object System.Drawing.Size(660, 660)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox   = $false
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# --- 顶部状态区 ---
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text   = '当前状态'
$grpStatus.Location = New-Object System.Drawing.Point(12, 10)
$grpStatus.Size   = New-Object System.Drawing.Size(620, 92)

$lblGuard = New-Object System.Windows.Forms.Label
$lblGuard.Location = New-Object System.Drawing.Point(15, 24); $lblGuard.AutoSize = $true; $lblGuard.Text = '守护进程：…'
$lblBroad = New-Object System.Windows.Forms.Label
$lblBroad.Location = New-Object System.Drawing.Point(15, 46); $lblBroad.AutoSize = $true; $lblBroad.Text = '宽带会话：…'
$lblWire = New-Object System.Windows.Forms.Label
$lblWire.Location = New-Object System.Drawing.Point(320, 24); $lblWire.AutoSize = $true; $lblWire.Text = '网线在位：…'
$lblNet = New-Object System.Windows.Forms.Label
$lblNet.Location = New-Object System.Drawing.Point(320, 46); $lblNet.AutoSize = $true; $lblNet.Text = '联网探测：…'
$grpStatus.Controls.AddRange(@($lblGuard, $lblBroad, $lblWire, $lblNet))
$form.Controls.Add($grpStatus)

# --- 换机检查清单 ---
$grpChecks = New-Object System.Windows.Forms.GroupBox
$grpChecks.Text   = '换机检查清单（全绿即完成）'
$grpChecks.Location = New-Object System.Drawing.Point(12, 110)
$grpChecks.Size   = New-Object System.Drawing.Size(620, 268)

# 行布局用 TableLayoutPanel：150% DPI 缩放下对 Label 手写像素 Location 会被布局引擎
# 重置回原点（实测所有行文字叠在分组框左上角），交给布局引擎才能正确缩放
$table = New-Object System.Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'
$table.ColumnCount = 4
$table.RowCount = $script:Checks.Count
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 126)))

$script:CheckRows = @()
for ($i = 0; $i -lt $script:Checks.Count; $i++) {
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $dot = New-Object System.Windows.Forms.Label
    # 固定尺寸色块 + Anchor=None（TLP 会把它居中在单元格）：「●」字符按基线渲染、
    # 字形天然偏下，文本怎么居中都救不回，改用实心色块就没有字形基线问题
    $dot.Size = New-Object System.Drawing.Size(12, 12)
    $dot.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $dot.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 3)
    $dot.BackColor = [System.Drawing.Color]::Gray
    $name = New-Object System.Windows.Forms.Label
    $name.Text = $script:Checks[$i].Name; $name.Dock = 'Fill'; $name.TextAlign = 'MiddleLeft'
    $name.Margin = New-Object System.Windows.Forms.Padding(2, 3, 3, 3)
    $detail = New-Object System.Windows.Forms.Label
    $detail.AutoSize = $false; $detail.Dock = 'Fill'; $detail.TextAlign = 'MiddleLeft'
    $detail.ForeColor = [System.Drawing.Color]::DimGray
    $fix = New-Object System.Windows.Forms.Button
    $fix.Dock = 'Fill'; $fix.Margin = New-Object System.Windows.Forms.Padding(6, 5, 3, 5)
    $fix.Text = '已就绪'; $fix.Enabled = $false   # 初始灰显，首轮 Refresh-Checks 按真实状态更新
    $fix.Tag = $null   # 刷新时写入动作标识字符串，点击时用 $this.Tag 读取（不用闭包，避免作用域坑）
    $fix.Add_Click({
        $action = $this.Tag
        if (-not $action) { return }
        switch ($action) {
            'GenConfig'   { New-DefaultConfig; Append-Log '已生成默认配置模板 AutoDial.json。请点「打开配置」按需修改，保存后稍候自动刷新。'; Refresh-All }
            'FixPbk'      { Repair-Pbk }
            'PickAdapter' { Show-AdapterPicker }
            'BindGateway' { Bind-Gateway }
            'Install'     { Invoke-ScriptOutput -Title '安装并启动' -FilePath $InstPs1 }
            'StartGuard'  { Start-GuardHidden }
        }
    })
    [void]$table.Controls.Add($dot, 0, $i)
    [void]$table.Controls.Add($name, 1, $i)
    [void]$table.Controls.Add($detail, 2, $i)
    [void]$table.Controls.Add($fix, 3, $i)
    $script:CheckRows += @{ Dot=$dot; Detail=$detail; FixBtn=$fix }
}
$grpChecks.Controls.Add($table)
$form.Controls.Add($grpChecks)

# --- 操作按钮区 ---
$grpOps = New-Object System.Windows.Forms.GroupBox
$grpOps.Text   = '操作'
$grpOps.Location = New-Object System.Drawing.Point(12, 386)
$grpOps.Size   = New-Object System.Drawing.Size(620, 62)

# 操作按钮一排 5 个：15 + 110*5 + 10*4 + 15 = 640 → 收尾 120 补齐 620（与分组框同宽）
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '安装并启动'; $btnInstall.Location = New-Object System.Drawing.Point(15, 24); $btnInstall.Size = New-Object System.Drawing.Size(110, 28)
$btnInstall.Add_Click({ Invoke-ScriptOutput -Title '安装并启动' -FilePath $InstPs1 })

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = '停止并卸载'; $btnUninstall.Location = New-Object System.Drawing.Point(135, 24); $btnUninstall.Size = New-Object System.Drawing.Size(110, 28)
$btnUninstall.Add_Click({ Stop-GuardAndUninstall })

$btnBind = New-Object System.Windows.Forms.Button
$btnBind.Text = '绑定指纹'; $btnBind.Location = New-Object System.Drawing.Point(255, 24); $btnBind.Size = New-Object System.Drawing.Size(110, 28)
$btnBind.Add_Click({ Bind-Gateway })

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = '重启守护'; $btnRestart.Location = New-Object System.Drawing.Point(375, 24); $btnRestart.Size = New-Object System.Drawing.Size(110, 28)
$btnRestart.Add_Click({
    # 用完整安装收尾（而非仅拉起进程）：Uninstall 会删掉自启项，
    # Install 同时恢复自启 + 启动守护，保证重启后清单仍全绿
    Invoke-ScriptOutput -Title '停止守护' -FilePath $UninstPs1
    Invoke-ScriptOutput -Title '重新安装并启动' -FilePath $InstPs1
})

$btnCfgDetail = New-Object System.Windows.Forms.Button
$btnCfgDetail.Text = '配置详情'; $btnCfgDetail.Location = New-Object System.Drawing.Point(495, 24); $btnCfgDetail.Size = New-Object System.Drawing.Size(110, 28)
$btnCfgDetail.Add_Click({ Show-ConfigDetail })

$grpOps.Controls.AddRange(@($btnInstall, $btnUninstall, $btnBind, $btnRestart, $btnCfgDetail))
$form.Controls.Add($grpOps)

# --- 日志区 ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text   = '操作输出 / 最近日志'
$grpLog.Location = New-Object System.Drawing.Point(12, 456)
$grpLog.Size   = New-Object System.Drawing.Size(620, 140)

# 用 RichTextBox 而非 TextBox：安装输出等含完整路径的行会超宽，TextBox 的横向
# 滚动条一旦启用就常驻（内容不足也显示），RichTextBox 按需显示，配合
# WordWrap=false + ScrollBars=Both 超宽行可左右拖动查看
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.ReadOnly   = $true
$txtLog.ScrollBars = 'Both'
$txtLog.WordWrap   = $false
$txtLog.DetectUrls = $false
$txtLog.Location   = New-Object System.Drawing.Point(10, 20)
$txtLog.Size       = New-Object System.Drawing.Size(598, 108)
$txtLog.Font       = New-Object System.Drawing.Font('Consolas', 9)
$grpLog.Controls.Add($txtLog)
$form.Controls.Add($grpLog)

$btnAllLogs = New-Object System.Windows.Forms.Button
$btnAllLogs.Text = '查看全部日志'
# 单按钮居中：620 客户区放 140px 按钮 → x = (620-140)/2 = 240
$btnAllLogs.Location = New-Object System.Drawing.Point(240, 604)
$btnAllLogs.Size = New-Object System.Drawing.Size(140, 28)
$btnAllLogs.Add_Click({ Show-AllLogs })
$form.Controls.Add($btnAllLogs)

# ----------------------------- 辅助函数（界面已建后再定义调用） -----------------------------
function Append-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

# 查看全部日志：把 Logs/ 下按天滚动的日志文件按时间顺序拼进只读查看器窗口。
# 每个文件插一行「── 文件名 ──」分隔标题；只读、等宽字体，打开即滚到最末尾
# （最新日志在底部）。日志为纯文本，窗口关闭即释放，不驻留任何资源。
function Show-AllLogs {
    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text          = 'AutoDial 全部日志（按天，旧 → 新）'
    $viewer.Size          = New-Object System.Drawing.Size(860, 620)
    $viewer.StartPosition = 'CenterParent'
    $viewer.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly   = $true
    $rtb.DetectUrls = $false
    $rtb.WordWrap   = $false
    $rtb.ScrollBars = 'Both'
    $rtb.Dock       = 'Fill'
    $rtb.Font       = New-Object System.Drawing.Font('Consolas', 9)

    $files = @()
    if (Test-Path $LogDirPath) {
        $files = Get-ChildItem -Path $LogDirPath -Filter 'AutoDial-*.log' -ErrorAction SilentlyContinue |
                 Sort-Object Name
    }
    if ($files.Count -eq 0) {
        $rtb.Text = '暂无日志文件（Logs 目录不存在或为空）。'
    } else {
        foreach ($f in $files) {
            $rtb.AppendText(('──────── {0} ────────' -f $f.Name) + [Environment]::NewLine)
            try {
                $content = Get-Content -Path $f.FullName -Encoding UTF8 -ErrorAction Stop
                if ($content) { $rtb.AppendText(($content -join [Environment]::NewLine) + [Environment]::NewLine) }
            } catch {
                $rtb.AppendText(('（读取失败：{0}）' -f $_.Exception.Message) + [Environment]::NewLine)
            }
            $rtb.AppendText([Environment]::NewLine)
        }
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.ScrollToCaret()
    }

    $viewer.Controls.Add($rtb)
    [void]$viewer.ShowDialog($form)
}

# 网卡选择器：枚举本机全部有线/无线物理网卡，用户勾选哪些是宽带口，写回配置。
# 枚举用纯 .NET NetworkInterface（NetworkInterfaceType 是稳定数值枚举），不用
# Get-NetAdapter——其 MediaType/Status 在部分系统返回数字枚举（见 AGENTS.md）。
# 只列 Ethernet/Wireless80211，排除 Tunnel/Loopback 等虚拟口。
function Get-PhysicalAdapters {
    $list = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $t = $ni.NetworkInterfaceType
        if ($t -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet -and
            $t -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { continue }
        $isWifi = $t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211
        $list += @{
            Name    = $ni.Name
            Desc    = $ni.Description
            IsWifi  = $isWifi
            Up      = $ni.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up
        }
    }
    return $list
}

function Show-AdapterPicker {
    $script:Cfg = Get-Config
    $current = @(Get-CfgValue 'WiredAdapters' @('以太网'))
    $adapters = Get-PhysicalAdapters

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text          = '选择宽带网线所在网卡'
    $viewer.Size          = New-Object System.Drawing.Size(680, 480)
    $viewer.FormBorderStyle = 'FixedDialog'
    $viewer.MaximizeBox   = $false
    $viewer.StartPosition = 'CenterParent'
    $viewer.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Text     = '勾选插宽带光猫网线的网卡（可多选，脚本按「任一在位」判定）：'
    $lblTip.Location = New-Object System.Drawing.Point(12, 12)
    $lblTip.AutoSize = $true
    $viewer.Controls.Add($lblTip)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.CheckOnClick  = $true
    $clb.Location      = New-Object System.Drawing.Point(15, 38)
    $clb.Size          = New-Object System.Drawing.Size(632, 300)
    # 条目文本：连接名 + 描述 + 类型 + 在位状态；Tag 存真实连接名
    foreach ($a in $adapters) {
        $typeText = if ($a.IsWifi) { '无线' } else { '有线' }
        $upText   = if ($a.Up) { '网线在位/已启用' } else { '未连接' }
        [void]$clb.Items.Add(('{0}  （{1}，{2}，{3}）' -f $a.Name, $a.Desc, $typeText, $upText), $current -contains $a.Name)
    }
    # 配置里有、但系统里找不到的名字也列出（防保存时静默丢失），标灰提示
    foreach ($name in $current) {
        if ($adapters.Name -notcontains $name) {
            [void]$clb.Items.Add(('{0}  （系统里找不到这个名字，勾着以防丢失）' -f $name), $true)
        }
    }
    $viewer.Controls.Add($clb)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '保存'; $btnOk.Location = New-Object System.Drawing.Point(452, 352); $btnOk.Size = New-Object System.Drawing.Size(95, 30)
    $btnOk.Add_Click({
        $picked = @()
        foreach ($i in $clb.CheckedIndices) {
            # 从显示文本里取行首到全角括号前的连接名
            $picked += ($clb.Items[$i] -split '  （')[0]
        }
        if ($picked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($viewer, '至少勾选一个网卡。', 'AutoDial', 'OK', 'Warning') | Out-Null
            return
        }
        $wifiPicked = @($adapters | Where-Object { $_.IsWifi -and $picked -contains $_.Name } | ForEach-Object { $_.Name })
        if ($wifiPicked.Count -gt 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show($viewer, ("勾选了无线网卡：{0}。守护会把它当宽带监控对象，通常宽带在有线网口。确定吗？" -f ($wifiPicked -join '、')), 'AutoDial', 'YesNo', 'Question')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Update-ConfigKey -Key 'WiredAdapters' -Value ([string[]]$picked)
        Append-Log ('已把 WiredAdapters 更新为：{0}（原配置备份为 AutoDial.json.bak）。守护运行中需重启生效。' -f ($picked -join '、'))
        $viewer.Close()
        Refresh-All
    })
    $viewer.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(557, 352); $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.Add_Click({ $viewer.Close() })
    $viewer.Controls.Add($btnCancel)

    [void]$viewer.ShowDialog($form)
}

# 只读展示（改配置走「打开配置」按钮），实际值实时读当前配置对象，
# 未在 JSON 里配置的项显示内置默认值并注明。
function Show-ConfigDetail {
    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text          = 'AutoDial 配置详情（AutoDial.json + gateway.mac）'
    $viewer.Size          = New-Object System.Drawing.Size(880, 640)
    $viewer.StartPosition = 'CenterParent'
    $viewer.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly   = $true
    $rtb.DetectUrls = $false
    $rtb.WordWrap   = $true
    $rtb.ScrollBars = 'Vertical'
    $rtb.Dock       = 'Fill'
    $rtb.Font       = New-Object System.Drawing.Font('Consolas', 9)

    # RichTextBox 着色小工具：标题青黑加粗、键名深蓝、值深红、解释灰
    $appendColored = {
        param([string]$Text, [System.Drawing.Color]$Color, [bool]$Bold = $false)
        $rtb.SelectionStart  = $rtb.TextLength
        $rtb.SelectionLength = 0
        $rtb.SelectionColor  = $Color
        $rtb.SelectionFont   = New-Object System.Drawing.Font('Consolas', 9, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
        $rtb.AppendText($Text)
        $rtb.SelectionFont = New-Object System.Drawing.Font('Consolas', 9)
        $rtb.SelectionColor = [System.Drawing.Color]::Black
    }

    $script:Cfg = Get-Config
    $cfgObj  = $script:Cfg
    $nl      = [Environment]::NewLine

    # ---- 第一部分：AutoDial.json ----
    & $appendColored ('═══════ AutoDial.json（运行参数，' + $ConfigFile + '）═══════' + $nl + $nl) ([System.Drawing.Color]::Black) $true
    if (-not $cfgObj) {
        & $appendColored ('  （配置文件不存在或非法，守护脚本回退内置默认值。点「生成模板」可重新创建。）' + $nl + $nl) ([System.Drawing.Color]::Firebrick)
    }
    # 说明顺序即展示顺序；Get-CfgValue 负责回退默认值
    $items = @(
        @{ Key='BroadbandName';      Default='宽带连接';  Desc='PPPoE 拨号条目名（「网络连接」ncpa.cpl 里显示的名字）。换机时改成目标机的拨号条目名' },
        @{ Key='WiredAdapters';      Default='["以太网"]'; Desc='插网线的物理网卡名，可写多个。必须与 ncpa.cpl 里的名字完全一致，否则守护检测不到网线；红灯行点「选择网卡」可直接挑选' },
        @{ Key='CheckInterval';      Default='15';        Desc='常规检查周期（秒）。守护每这么多秒巡检一轮：网线 → 会话 → 联网探测' },
        @{ Key='FastPollIntervalSec'; Default='5';        Desc='开机快速轮询节拍（秒）。启动初期网络栈（DHCP/邻居表）未就绪，用密节拍尽早捕获网络就绪时刻' },
        @{ Key='FastPollWindowSec';  Default='120';       Desc='开机快速轮询窗口（秒）。守护启动后前这段时间用快速节拍，之后回 CheckInterval' },
        @{ Key='ProbeIPs';           Default='阿里/腾讯/114 DNS'; Desc='联网探测目标列表（任一通即判定网络正常）。海外网络换 1.1.1.1/8.8.8.8，否则正常连接会被误判为僵死' },
        @{ Key='ProbePort';          Default='53';        Desc='探测端口（TCP 握手）。企业防火墙封 53 时可换 80/443' },
        @{ Key='ProbeTimeoutMs';     Default='3000';      Desc='单轮探测总超时（毫秒）。多个目标并行探测，最坏耗时即此值' },
        @{ Key='FailThreshold';      Default='3';         Desc='会话在但连续 N 轮探测失败 → 判定会话僵死，断开重拨' },
        @{ Key='BaseBackoffSec';     Default='15';        Desc='拨号失败退避基数（秒）。按 2 的指数递增：15→30→60→…' },
        @{ Key='MaxBackoffSec';      Default='600';       Desc='普通失败退避上限（秒），默认 10 分钟' },
        @{ Key='AuthFailBackoffSec'; Default='900';       Desc='认证类失败（691/628 账号被占用/欠费）的长退避（秒），默认 15 分钟，防止反复撞击认证服务器锁号' },
        @{ Key='AuthFastRetryCount'; Default='6';         Desc='认证类失败的紧盯期次数：断线后前 N 次每 30 秒重试（抓住旧会话快速释放窗口），之后才转长退避' },
        @{ Key='LogKeepDays';        Default='30';        Desc='日志保留天数，超期自动清理' },
        @{ Key='EnableLogFile';      Default='true';      Desc='是否写日志文件。false 时只跑不记（不建议）' }
    )
    foreach ($it in $items) {
        $configured = $cfgObj -and $cfgObj.PSObject.Properties[$it.Key]
        $val = Get-CfgValue $it.Key $it.Default
        if ($val -is [System.Array]) { $valText = '[' + (($val | ForEach-Object { "$_" }) -join ', ') + ']' } else { $valText = "$val" }
        $srcMark = if ($configured) { '' } else { '   ← 未配置，用默认值' }
        & $appendColored ('  ' + $it.Key) ([System.Drawing.Color]::MidnightBlue) $true
        & $appendColored (' = ' + $valText + $srcMark + $nl) ([System.Drawing.Color]::Firebrick)
        & $appendColored ('      ' + $it.Desc + $nl) ([System.Drawing.Color]::DimGray)
    }

    # ---- 第二部分：gateway.mac（链路指纹白名单） ----
    & $appendColored ($nl + '═══════ gateway.mac（链路指纹白名单，' + $BindFile + '）═══════' + $nl) ([System.Drawing.Color]::Black) $true
    & $appendColored ('  作用：拨号前核对网线另一端的特征，对不上就拒绝拨号——防止把公司内网/别人家路由器误判为自家宽带。' + $nl) ([System.Drawing.Color]::DimGray)
    & $appendColored ('  本文件由「绑定指纹」生成、拨号成功后自动学习扩充，勿改格式；换机/换光猫后重新绑定。' + $nl + $nl) ([System.Drawing.Color]::DimGray)
    if (-not (Test-Path $BindFile)) {
        & $appendColored ('  （指纹文件不存在 = 未绑定。不绑定时任何网线在位都可能触发拨号，有误拨风险；点「绑定指纹」创建。）' + $nl) ([System.Drawing.Color]::Firebrick)
    } else {
        try {
            $fp = Get-Content -Raw -Path $BindFile -Encoding UTF8 | ConvertFrom-Json
            $macs = @($fp.Macs | Where-Object { $_ })
            & $appendColored ('  Macs（光猫/链路设备 MAC 白名单，' + $macs.Count + ' 个）' + $nl) ([System.Drawing.Color]::MidnightBlue) $true
            if ($macs.Count -eq 0) {
                & $appendColored ('      （暂无——绑定时尚未学到 MAC，拨号成功后会自动学习补充）' + $nl) ([System.Drawing.Color]::DimGray)
            } else {
                foreach ($m in $macs) {
                    & $appendColored ('      ' + $m) ([System.Drawing.Color]::Firebrick)
                    & $appendColored ('   ← 邻居表里学到的链路设备 MAC；绑定后学到其他设备 MAC 会拒绝拨号' + $nl) ([System.Drawing.Color]::DimGray)
                }
            }
            $v6 = $fp.V6
            & $appendColored ('  V6（光猫 IPv6 链路本地地址）' + $nl) ([System.Drawing.Color]::MidnightBlue) $true
            if ($v6) {
                & $appendColored ('      ' + $v6) ([System.Drawing.Color]::Firebrick)
                & $appendColored ('   ← fe80:: 开头，光猫的 IPv6 特征（最可靠，不受 IP 池变化影响）' + $nl) ([System.Drawing.Color]::DimGray)
            } else {
                & $appendColored ('      （暂无——网卡未学到光猫 IPv6 邻居，学到后自动学习补充）' + $nl) ([System.Drawing.Color]::DimGray)
            }
            $subnets = @($fp.Subnets | Where-Object { $_ })
            & $appendColored ('  Subnets（网段前缀白名单，' + $subnets.Count + ' 个）' + $nl) ([System.Drawing.Color]::MidnightBlue) $true
            if ($subnets.Count -eq 0) {
                & $appendColored ('      （暂无）' + $nl) ([System.Drawing.Color]::DimGray)
            } else {
                foreach ($s in $subnets) {
                    & $appendColored ('      ' + $s + '*') ([System.Drawing.Color]::Firebrick)
                    & $appendColored ('   ← 运营商 IP 池大段前缀（/16）。桥接模式每次插拔可能换 /24 网段，所以只记大段兜底' + $nl) ([System.Drawing.Color]::DimGray)
                }
            }
        } catch {
            & $appendColored ('  （指纹文件读取失败：' + $_.Exception.Message + '）' + $nl) ([System.Drawing.Color]::Firebrick)
        }
    }

    $viewer.Controls.Add($rtb)
    [void]$viewer.ShowDialog($form)
}

# 实时状态（守护/宽带/网线/探测）
function Refresh-Status {
    $script:Cfg = Get-Config
    $bbName = Get-CfgValue 'BroadbandName' '宽带连接'
    $adNames = @(Get-CfgValue 'WiredAdapters' @('以太网'))

    $lblGuard.Text = '守护进程：' + $(if (Test-GuardRunning) { '运行中 ✔' } else { '未运行 ✘' })

    $bbUp = $false
    $ad = Get-NetAdapter -Name $bbName -ErrorAction SilentlyContinue
    if ($ad) {
        $st = $ad.Status
        $bbUp = if ($st -is [string]) { $st -eq 'Up' } else { [int]$st -eq 1 }
    }
    if (-not $bbUp) {
        $out = & "$env:SystemRoot\System32\rasdial.exe" 2>$null
        if ($out -and (($out -join "`n") -match [regex]::Escape($bbName))) { $bbUp = $true }
    }
    $lblBroad.Text = '宽带会话：' + $(if ($bbUp) { '已连接 ✔' } else { '未连接 ✘' })

    $wire = $false
    foreach ($n in $adNames) {
        $a = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
        if ($a) {
            $mcs = $a.MediaConnectState
            if (($mcs -is [string] -and $mcs -eq 'Connected') -or (-not ($mcs -is [string]) -and [int]$mcs -eq 1)) { $wire = $true; break }
        }
    }
    $lblWire.Text = '网线在位：' + $(if ($wire) { '在位 ✔' } else { '不在位 ✘' })

    # 联网探测：宽带会话在时做一次 TCP 53 快速探测
    $lblNet.Text = '联网探测：…'
    [System.Windows.Forms.Application]::DoEvents()
    if ($bbUp) {
        $ips = @(Get-CfgValue 'ProbeIPs' @('223.5.5.5'))
        $port = [int](Get-CfgValue 'ProbePort' 53)
        $ok = $false
        foreach ($ip in $ips) {
            $c = New-Object System.Net.Sockets.TcpClient
            try {
                $t = $c.ConnectAsync($ip, $port)
                if ($t.Wait(2500) -and $c.Connected) { $ok = $true; break }
            } catch { } finally { try { $c.Close() } catch { } }
        }
        $lblNet.Text = '联网探测：' + $(if ($ok) { '正常 ✔' } else { '失败 ✘' })
    } else {
        $lblNet.Text = '联网探测：—（宽带未连接）'
    }
}

# 清单逐项刷新 + 修复按钮状态（按钮常驻不隐藏，用 Enabled 置灰表达可用性：
# 绿灯=灰显「已就绪」，红灯可修=亮起，红灯需人工=灰显「需人工处理」，行高稳定不跳动）
function Refresh-Checks {
    for ($i = 0; $i -lt $script:Checks.Count; $i++) {
        $item = $script:Checks[$i]
        $r = & $item.Func
        $row = $script:CheckRows[$i]
        if ($r.Ok) {
            $row.Dot.BackColor = [System.Drawing.Color]::ForestGreen
            $row.Detail.ForeColor = [System.Drawing.Color]::DimGray
            $row.Detail.Text = $r.Detail
            $row.FixBtn.Text = '已就绪'
            $row.FixBtn.Enabled = $false
            $row.FixBtn.Tag = $null
        } else {
            $row.Dot.BackColor = [System.Drawing.Color]::Firebrick
            $row.Detail.ForeColor = [System.Drawing.Color]::Firebrick
            $row.Detail.Text = $r.Detail
            if ($r.Fix) {
                $row.FixBtn.Text = Switch ($r.Fix) {
                    'GenConfig'   { '生成模板' }
                    'FixPbk'      { '一键关闭弹窗' }
                    'PickAdapter' { '选择网卡' }
                    'BindGateway' { '绑定指纹' }
                    'Install'     { '安装自启' }
                    'StartGuard'  { '启动守护' }
                    default       { '修复' }
                }
                $row.FixBtn.Enabled = $true
                $row.FixBtn.Tag = $r.Fix
            } else {
                $row.FixBtn.Text = '需人工处理'
                $row.FixBtn.Enabled = $false
                $row.FixBtn.Tag = $null
            }
        }
    }
}

function Refresh-All {
    Refresh-Status
    Refresh-Checks
}

# ----------------------------- 定时器与启动 -----------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick({ Refresh-All })
$timer.Start()

$form.Add_Shown({
    Refresh-All
    $bbName = Get-CfgValue 'BroadbandName' '宽带连接'
    Append-Log ('AutoDial 管理器已打开。按红绿灯逐项处理即可完成换机；「联网探测」等状态每 15 秒自动刷新。宽带条目：{0}' -f $bbName)
})

[void]$form.ShowDialog()
$timer.Stop()
