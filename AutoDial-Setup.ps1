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
#   4. 有线网卡在位（名称与配置一致）
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
    return @{ Ok=$false; Detail=('找不到名为「{0}」的网卡——请核对 AutoDial.json 的 WiredAdapters 与本机网卡名（网络连接里看）' -f ($names -join ',')); Fix='OpenConfig' }
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
    $fix.Tag = $null   # 刷新时写入动作标识字符串，点击时用 $this.Tag 读取（不用闭包，避免作用域坑）
    $fix.Add_Click({
        $action = $this.Tag
        if (-not $action) { return }
        switch ($action) {
            'GenConfig'   { New-DefaultConfig; Append-Log '已生成默认配置模板 AutoDial.json。请点「打开配置」按需修改，保存后稍候自动刷新。'; Refresh-All }
            'FixPbk'      { Repair-Pbk }
            'OpenConfig'  { Open-ConfigEditor }
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

$btnOpenCfg = New-Object System.Windows.Forms.Button
$btnOpenCfg.Text = '打开配置'; $btnOpenCfg.Location = New-Object System.Drawing.Point(495, 24); $btnOpenCfg.Size = New-Object System.Drawing.Size(110, 28)
$btnOpenCfg.Add_Click({ Open-ConfigEditor })

$grpOps.Controls.AddRange(@($btnInstall, $btnUninstall, $btnBind, $btnRestart, $btnOpenCfg))
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

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = '打开日志文件夹'
$btnOpenLogs.Location = New-Object System.Drawing.Point(495, 604)
$btnOpenLogs.Size = New-Object System.Drawing.Size(137, 28)
$btnOpenLogs.Add_Click({
    if (Test-Path $LogDirPath) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $LogDirPath) }
    else { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Root) }
})
$form.Controls.Add($btnOpenLogs)

$btnAllLogs = New-Object System.Windows.Forms.Button
$btnAllLogs.Text = '查看全部日志'
$btnAllLogs.Location = New-Object System.Drawing.Point(345, 604)
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

function Open-ConfigEditor {
    if (-not (Test-Path $ConfigFile)) { New-DefaultConfig }
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $ConfigFile)
    Append-Log '已用记事本打开 AutoDial.json。保存后点「重新检测」生效。'
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

# 清单逐项刷新 + 修复按钮显隐
function Refresh-Checks {
    for ($i = 0; $i -lt $script:Checks.Count; $i++) {
        $item = $script:Checks[$i]
        $r = & $item.Func
        $row = $script:CheckRows[$i]
        if ($r.Ok) {
            $row.Dot.BackColor = [System.Drawing.Color]::ForestGreen
            $row.Detail.ForeColor = [System.Drawing.Color]::DimGray
            $row.Detail.Text = $r.Detail
            $row.FixBtn.Visible = $false
            $row.FixBtn.Tag = $null
        } else {
            $row.Dot.BackColor = [System.Drawing.Color]::Firebrick
            $row.Detail.ForeColor = [System.Drawing.Color]::Firebrick
            $row.Detail.Text = $r.Detail
            if ($r.Fix) {
                $row.FixBtn.Text = Switch ($r.Fix) {
                    'GenConfig'   { '生成模板' }
                    'FixPbk'      { '一键关闭弹窗' }
                    'OpenConfig'  { '打开配置' }
                    'BindGateway' { '绑定指纹' }
                    'Install'     { '安装自启' }
                    'StartGuard'  { '启动守护' }
                    default       { '修复' }
                }
                $row.FixBtn.Visible = $true
                $row.FixBtn.Tag = $r.Fix
            } else {
                $row.FixBtn.Visible = $false
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
