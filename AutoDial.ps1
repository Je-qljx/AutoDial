# ============================================================================
# AutoDial.ps1 - 宽带自动拨号守护脚本
#
# 功能：检测到指定有线网卡网线在位、但宽带 PPPoE 会话未连接（或会话僵死无法
#       上网）时，自动拨号恢复。只操作「宽带连接」这一个拨号条目，不改路由、
#       不改网卡设置、不碰 WLAN/蓝牙等其他网络连接。
#
#   防误拨：通过「网关 MAC 指纹」识别网线另一端是不是宽带光猫。首次运行
#   -BindGateway 绑定宽带光猫的网关 MAC 后，只有指纹匹配（网线插在光猫上）
#   才会拨号；插了其他网络的网线（指纹不匹配）绝不拨号。
#
# 用法：
#   AutoDial.ps1                无参数运行：自动以隐藏窗口转入后台守护
#   AutoDial.ps1 -Console       前台运行，实时输出日志（观察调试用）
#   AutoDial.ps1 -Once          只执行一轮检测后退出（测试用）
#   AutoDial.ps1 -BindGateway   绑定当前有线网卡上学到的网关 MAC 作为指纹（需宽带网线在位）
#   AutoDial.ps1 -ClearGateway  清除指纹绑定（恢复为不校验指纹）
#   AutoDial.ps1 -Detached      由 Start-AutoDial.vbs 隐藏启动时使用，勿手动传
# ============================================================================
param(
    [switch]$Once,
    [switch]$Console,
    [switch]$BindGateway,
    [switch]$ClearGateway,
    [switch]$Detached
)

# ============================ 配置区（按需修改） ============================
$BroadbandName  = '宽带连接'        # PPPoE 拨号条目名称（网络连接里显示的名字）
$WiredAdapters  = @('以太网')       # 插网线的物理网卡名称，可写多个，如 @('以太网','以太网 2')
$CheckInterval  = 15                # 检查周期（秒）
$ProbeIPs       = @('223.5.5.5','119.29.29.29','114.114.114.114')  # 探测目标（TCP 53，IP 直连不依赖 DNS）
$ProbePort      = 53
$ProbeTimeoutMs = 3000              # 单个探测目标的超时（毫秒）
$FailThreshold  = 3                 # 宽带会话在但连续 N 轮探测失败 → 判定会话僵死，断开重拨
$BaseBackoffSec = 15                # 拨号失败后的退避基数（秒），按 2 的指数递增
$MaxBackoffSec  = 600               # 退避上限（秒）
$AuthFailBackoffSec = 900           # 认证类失败（691/628 账号占用等）的长退避（秒）
$AuthFastRetryCount = 6             # 认证类失败的紧盯期次数：前 N 次 30 秒短间隔，之后转长退避
$GatewayBindFile= Join-Path $PSScriptRoot 'gateway.mac'   # 网关 MAC 指纹文件
$GatewayWaitSec = 20                # 学网关 MAC 的等待时间（秒）
$LogDir         = Join-Path $PSScriptRoot 'Logs'
$LogKeepDays    = 30                # 日志保留天数
$EnableLogFile  = $true             # 是否写日志文件
# ============================================================================

$RasDialExe = Join-Path $env:SystemRoot 'System32\rasdial.exe'
$script:LastBeat       = Get-Date
$script:FailStreak     = 0
$script:ConsecDialFails = 0
$script:NextDialAt     = [datetime]::MinValue

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Console -or $Once) { Write-Host $line }
    if ($EnableLogFile) {
        try {
            $path = Join-Path $LogDir ('AutoDial-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
            Add-Content -Path $path -Value $line -Encoding UTF8
        } catch { }
    }
}

# 网线是否插在指定的有线网卡上（只读判断，不动网卡）
# 注：MediaConnectState 在部分系统返回字符串枚举、部分返回数字（1=Connected, 2=Disconnected），两种都兼容
function Test-WirePlugged {
    foreach ($name in $WiredAdapters) {
        $ad = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        if (-not $ad) { continue }
        $mcs = $ad.MediaConnectState
        $connected = if ($mcs -is [string]) { $mcs -eq 'Connected' } else { [int]$mcs -eq 1 }
        if ($connected) { return $true }
    }
    return $false
}

# 宽带 PPPoE 会话是否处于已连接状态（网卡状态 + rasdial 连接清单双重确认）
function Test-BroadbandUp {
    $ad = Get-NetAdapter -Name $BroadbandName -ErrorAction SilentlyContinue
    if ($ad) {
        $st = $ad.Status
        $up = if ($st -is [string]) { $st -eq 'Up' } else { [int]$st -eq 1 }
        if ($up) { return $true }
    }
    $out = & $RasDialExe 2>$null
    if ($out -and (($out -join "`n") -match [regex]::Escape($BroadbandName))) { return $true }
    return $false
}

# 取宽带连接当前的本机 IPv4（用于把探测流量绑定到宽带出口）
function Get-BroadbandIPv4 {
    $ip = Get-NetIPAddress -InterfaceAlias $BroadbandName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notlike '169.254.*' } |
          Select-Object -First 1
    if ($ip) { return $ip.IPAddress } else { return $null }
}

# Internet 连通性探测：对多个公网 IP 做 TCP 53 握手，任一通即视为正常。
# 优先绑定宽带连接的本机 IP，让探测尽量走宽带出口而非其他网络。
function Test-Internet {
    $srcIp = Get-BroadbandIPv4
    foreach ($target in $ProbeIPs) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            if ($srcIp) {
                try {
                    $localEp = New-Object System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Parse($srcIp)), 0
                    $client.Client.Bind($localEp)
                } catch { }
            }
            $task = $client.ConnectAsync($target, $ProbePort)
            if ($task.Wait($ProbeTimeoutMs) -and $client.Connected) { return $true }
        } catch { }
        finally { try { $client.Close() } catch { } }
    }
    return $false
}

# 拨号（使用系统已保存的宽带账号密码）；错误 813 时先断开再拨一次
function Invoke-Dial {
    param([string]$Reason)
    Write-Log 'ACTION' ('开始拨号「{0}」（{1}）' -f $BroadbandName, $Reason)
    $out = & $RasDialExe $BroadbandName 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 813) {
        # 813 = 连接已在进行中：可能是用户或上一轮调用正在拨号。
        # 不强行断开，先等它连上；等不到再断开重拨，避免误伤进行中的拨号。
        Write-Log 'INFO' '错误 813：已有拨号在进行中，等待其完成…'
        $deadline = [datetime]::Now.AddSeconds(45)
        while ([datetime]::Now -lt $deadline) {
            Start-Sleep -Seconds 3
            if (Test-BroadbandUp) { Write-Log 'INFO' '进行中的拨号已完成（会话已建立）。'; return 0 }
        }
        Write-Log 'WARN' '进行中的拨号超时未完成，断开后重拨'
        & $RasDialExe $BroadbandName '/disconnect' 2>&1 | Out-Null
        Start-Sleep -Seconds 8
        $out = & $RasDialExe $BroadbandName 2>&1
        $code = $LASTEXITCODE
    }
    # 错误 628（会话被远端终止）：刚断开的 PPPoE 会话运营商侧尚未释放，稍候重试，
    # 由指数退避机制自然拉开重拨间隔，这里不额外处理。
    $text = ($out | ForEach-Object { $_.ToString() }) -join ' '
    # 认证失败检测：rasdial 有时把 691 报成 628（连接被远端终止），用系统事件日志
    # （EapMethods-RasChap 事件 101）二次确认，供退避策略区分
    $script:LastDialWasAuthFail = $false
    if ($code -eq 628) {
        try {
            $authEvt = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-EapMethods-RasChap/Operational'; StartTime=(Get-Date).AddSeconds(-30)} -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($authEvt -and $authEvt.Id -eq 101) { $script:LastDialWasAuthFail = $true }
        } catch { }
    }
    if ($code -eq 0) {
        Write-Log 'INFO' '拨号成功。'
    } else {
        Write-Log 'ERROR' ('拨号失败，错误码 {0}。输出：{1}' -f $code, $text)
    }
    return $code
}

# ------------------------- 链路指纹（防误拨） -------------------------
# 原理：宽带光猫（桥接模式）在本机网卡上留下的稳定特征组合：
#   ① 光猫设备的 MAC 地址（邻居表里学到的一切 MAC，含 IPv4/IPv6 邻居发现）
#   ② 光猫的 IPv6 链路本地地址（fe80::/10，可随时主动 ping 促发学习，最可靠）
#   ③ IPv4 网段前缀白名单（兜底）：桥接模式下网卡 IP 由运营商 IP 池分配，
#      每次插拔网线可能换网段（如 36.5.200.x → 36.5.63.x），所以存的是
#      运营商大段前缀（如 36.5.），而不是精确的 /24 网段。
#   ④ 自动学习：每次拨号成功且 Internet 探测通过（足以证明是自家线路）时，
#      把当时的 MAC/网段前缀并入指纹，运营商调整 IP 池也无需手动重绑。
# 网线插到其他网络（公司内网/另一台路由器/无 DHCP 的空线）时，以上特征全部
# 对不上，脚本据此拒绝拨号。判定分支见 Test-LinkAllowed。

# 指纹文件默认路径（JSON 格式）
$GatewayBindFile = Join-Path $PSScriptRoot 'gateway.mac'

# 读取已绑定的指纹（JSON）；兼容旧版三行文本格式并自动升级；无绑定返回 $null
function Get-BoundFingerprint {
    if (-not (Test-Path $GatewayBindFile)) { return $null }
    try {
        $raw = (Get-Content -Raw $GatewayBindFile).Trim()
        if ($raw -notmatch '^\{') {
            # 旧格式：三行文本（MAC 集合 / IPv6 / 网段）→ 升级为 JSON
            $lines = $raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            $oldMacs = @(); $oldV6 = $null; $oldSubnets = @()
            if ($lines.Count -ge 1) { $oldMacs = ($lines[0] -split ',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -match '^[0-9A-F]{2}-' } }
            if ($lines.Count -ge 2 -and $lines[1]) { $oldV6 = $lines[1] }
            if ($lines.Count -ge 3 -and $lines[2]) {
                $p = $lines[2].Split('.')
                if ($p.Count -ge 2) { $oldSubnets = @('{0}.{1}.' -f $p[0], $p[1]) }
            }
            $fp = @{ Macs = @($oldMacs); V6 = $oldV6; Subnets = @($oldSubnets) }
            Save-Fingerprint $fp
            return $fp
        }
        $j = $raw | ConvertFrom-Json
        return @{ Macs = @($j.Macs); V6 = $j.V6; Subnets = @($j.Subnets) }
    } catch { return $null }
}

# 保存指纹（JSON）
function Save-Fingerprint {
    param($Fp)
    @{
        Macs    = @($Fp.Macs | Sort-Object -Unique)
        V6      = $Fp.V6
        Subnets = @($Fp.Subnets | Sort-Object -Unique)
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $GatewayBindFile -Encoding ASCII
}

# 从有线网卡的邻居表收集一切学到的 MAC（排除组播/广播/全零）
function Get-LinkMacs {
    $macs = @()
    foreach ($name in $WiredAdapters) {
        Get-NetNeighbor -InterfaceAlias $name -ErrorAction SilentlyContinue | ForEach-Object {
            $m = $_.LinkLayerAddress
            if ($m -and $m -notmatch '^(FF-|33-33|01-00-5E|00-00-00-00)' ) { $macs += $m.ToUpper() }
        }
    }
    return ($macs | Sort-Object -Unique)
}

# 当前学到的 IPv6 链路本地地址（无则返回 $null）
function Get-ModemLinkLocalV6 {
    $v6 = Get-NetNeighbor -InterfaceAlias $WiredAdapters[0] -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -like 'fe80:*' -and $_.State -in @('Reachable','Stale','Permanent','Probe','Delay') -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(FF-|33-33|00-00-00-00)' } |
          Select-Object -First 1
    if ($v6) { return $v6.IPAddress }
    return $null
}

# 当前有线网卡的 IPv4 网段前缀（a.b.，前两段）；无 IP 返回 $null
function Get-CurrentSubnetPrefix {
    foreach ($name in $WiredAdapters) {
        $ipCfg = Get-NetIPConfiguration -InterfaceAlias $name -ErrorAction SilentlyContinue
        $ipObj = $ipCfg.IPv4Address | Select-Object -First 1
        if ($ipObj) {
            $p = $ipObj.IPAddress.Split('.')
            return ('{0}.{1}.' -f $p[0], $p[1])
        }
    }
    return $null
}

# 当前链路指纹（动态采集）
function Get-CurrentFingerprint {
    $f = @{ Macs = @(); V6 = $null; Subnets = @() }
    $f.Macs = Get-LinkMacs
    $f.V6   = Get-ModemLinkLocalV6
    $sp = Get-CurrentSubnetPrefix
    if ($sp) { $f.Subnets = @($sp) }
    return $f
}

# 把当前学到的特征并入指纹（拨号成功后自动学习调用）
function Merge-FingerprintFromCurrent {
    $bound = Get-BoundFingerprint
    if (-not $bound) { return }
    $cur = Get-CurrentFingerprint
    $before = (@($bound.Macs).Count, @($bound.Subnets).Count -join '/')
    $bound.Macs    = @($bound.Macs) + @($cur.Macs)
    if ($cur.V6 -and -not $bound.V6) { $bound.V6 = $cur.V6 }
    $bound.Subnets = @($bound.Subnets) + @($cur.Subnets)
    $bound.Macs    = @($bound.Macs    | Where-Object { $_ } | Sort-Object -Unique)
    $bound.Subnets = @($bound.Subnets | Where-Object { $_ } | Sort-Object -Unique)
    $after = (@($bound.Macs).Count, @($bound.Subnets).Count -join '/')
    if ($before -ne $after) {
        Save-Fingerprint $bound
        Write-Log 'INFO' ('指纹自动学习：MAC/网段并入指纹（当前 MAC {0} 个、网段前缀 {1} 个）' -f @($bound.Macs).Count, @($bound.Subnets).Count)
    }
}

# -BindGateway：把当前链路指纹写入绑定文件（可与网段前缀白名单一起手写扩展）
if ($BindGateway) {
    if (-not (Test-WirePlugged)) {
        Write-Host '错误：有线网卡网线未连接，无法绑定链路指纹。请插好宽带网线后重试。' -ForegroundColor Red
        exit 1
    }
    Write-Host '正在采集当前链路指纹…'
    $f = Get-CurrentFingerprint
    if (-not $f -or ($f.Macs.Count -eq 0 -and -not $f.V6 -and $f.Subnets.Count -eq 0)) {
        Write-Host '错误：未能采集到任何链路特征（MAC/IPv6/网段）。请确认网线插在光猫上。' -ForegroundColor Red
        exit 1
    }
    Save-Fingerprint $f
    Write-Host '绑定成功！当前链路指纹：' -ForegroundColor Green
    Write-Host ("  光猫 MAC       : {0}" -f ($(if ($f.Macs.Count) { $f.Macs -join ', ' } else { '（暂无，拨号成功后会自动学习补充）' })))
    Write-Host ("  IPv6 链路本地  : {0}" -f ($(if ($f.V6) { $f.V6 } else { '（暂无）' })))
    $subnetText = if ($f.Subnets.Count) { (($f.Subnets | ForEach-Object { $_ + '*' }) -join ', ') } else { '（暂无）' }
    Write-Host ("  网段前缀白名单 : {0}" -f $subnetText)
    Write-Host ("已保存到 {0}（JSON）。拨号成功后 MAC/网段会自动并入指纹。" -f $GatewayBindFile)
    exit 0
}

# -ClearGateway：清除指纹绑定
if ($ClearGateway) {
    if (Test-Path $GatewayBindFile) {
        Remove-Item $GatewayBindFile -Force
        Write-Host '已清除链路指纹绑定，恢复为不校验指纹（任何网线在位都可能拨号）。' -ForegroundColor Yellow
    } else {
        Write-Host '当前没有指纹绑定。'
    }
    exit 0
}

# 拨号守门：链路特征对不上（网线插在其他网络上）→ 禁止拨号
# 返回 $true = 允许拨号；$false = 禁止
function Test-LinkAllowed {
    $bound = Get-BoundFingerprint
    if (-not $bound) { return $true }   # 未绑定指纹则不做校验
    $boundMacs    = @($bound.Macs    | Where-Object { $_ })
    $boundV6      = $bound.V6
    $boundSubnets = @($bound.Subnets | Where-Object { $_ })

    $cur = Get-CurrentFingerprint

    # 分支1：邻居表学到了光猫 MAC（或 IPv6 链路本地匹配）→ 确定还是那条链路
    foreach ($bm in $boundMacs) {
        if ($cur.Macs -contains $bm) { return $true }
    }
    if ($boundV6 -and $cur.V6 -and ($cur.V6 -eq $boundV6)) { return $true }

    # 分支2：学到过 MAC 但都不是光猫的 → 网线插在了其他网络（最典型的误拨场景）
    if ($cur.Macs.Count -gt 0) {
        Write-Log 'WARN' ('链路指纹不匹配（绑定 MAC: {0} / 当前学到: {1}），网线可能插在其他网络上，禁止拨号。' -f ($boundMacs -join ','), ($cur.Macs -join ','))
        return $false
    }

    # 分支3：没学到任何 MAC，IPv4 在网段前缀白名单内 → 兜底放行（等待邻居学习）
    $sp = Get-CurrentSubnetPrefix
    if ($sp) {
        foreach ($bs in $boundSubnets) {
            if ($sp -like "$bs*") { return $true }
        }
        Write-Log 'WARN' ('链路指纹不匹配（当前网段前缀 {0} 不在白名单 [{1}] 内），网线可能插在其他网络上，禁止拨号。' -f $sp, ($boundSubnets -join ', '))
        return $false
    }

    # 分支4：什么特征都没有 → 视为未知链路，拒绝
    Write-Log 'WARN' '链路指纹校验：当前链路无任何可识别特征（无 MAC/IPv6/网段匹配），禁止拨号。'
    return $false
}

# 拨号 + 失败指数退避：成功则清零，失败则按 15s、30s、60s…递增（上限 10 分钟）
# 认证类错误（691/628，多为账号被占用或欠费）不随次数恢复，改用 15 分钟长退避，
# 避免反复撞击认证服务器
function Invoke-DialWithBackoff {
    param([string]$Reason)
    if (-not (Test-LinkAllowed)) { return $false }
    $code = Invoke-Dial -Reason $Reason
    if ($code -eq 0) {
        $script:ConsecDialFails = 0
        $script:NextDialAt = [datetime]::MinValue
        # 拨号成功：把当前学到的 MAC/网段并入指纹（证明这就是自家宽带线路）
        Merge-FingerprintFromCurrent
        return $true
    }
    $script:ConsecDialFails++
    # 认证类失败（691/628）分两段处理：
    #  · 断线后前 AuthFastRetryCount 次：旧会话很可能几秒~几分钟内就释放，
    #    用 30 秒短间隔紧盯，抓住释放窗口立即拨上（实测晚 12 秒就能成功）
    #  · 之后仍失败：才是真正的账号占用/欠费，转 15 分钟长退避避免撞击
    if (($code -in @(691, 628) -or $script:LastDialWasAuthFail) -and $script:ConsecDialFails -gt $AuthFastRetryCount) {
        $wait = $AuthFailBackoffSec
        Write-Log 'WARN' ('认证类失败持续（错误码 {0}，已重试 {1} 次）：账号可能被其他设备/会话占用或欠费，{2} 分钟后重试。若长时间不恢复，请重启光猫或联系运营商释放会话。' -f $code, $script:ConsecDialFails, [int]($wait / 60))
    }
    elseif ($code -in @(691, 628) -or $script:LastDialWasAuthFail) {
        $wait = 30
        Write-Log 'WARN' ('认证类失败（错误码 {0}），旧会话可能即将释放，{1} 秒后重试（前 {2} 次为紧盯期）' -f $code, $wait, $AuthFastRetryCount)
    }
    else {
        $wait = [math]::Min($BaseBackoffSec * [math]::Pow(2, $script:ConsecDialFails - 1), $MaxBackoffSec)
        Write-Log 'WARN' ('连续第 {0} 次拨号失败，{1} 秒后重试' -f $script:ConsecDialFails, [int]$wait)
    }
    $script:NextDialAt = [datetime]::Now.AddSeconds($wait)
    return $false
}

# 无参数直接运行时：把自己转入隐藏后台进程后退出
if (-not $Once -and -not $Console -and -not $Detached) {
    $childArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"{0}"' -f $PSCommandPath), '-Detached')
    Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -WindowStyle Hidden | Out-Null
    exit 0
}

# 日志目录初始化 + 清理过期日志
if ($EnableLogFile) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Get-ChildItem -Path $LogDir -Filter 'AutoDial-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# 单实例互斥锁：防止多个守护进程同时拨号
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'AutoDial_BroadbandGuard', [ref]$createdNew)
if (-not $createdNew) {
    $msg = '检测到 AutoDial 守护进程已在运行，本实例退出。'
    if ($Console -or $Once) { Write-Host $msg } else { Write-Log 'WARN' $msg }
    exit 0
}

Write-Log 'INFO' ('守护启动（PID {0}）。宽带条目：{1}；有线网卡：{2}；检查周期：{3}s' -f $PID, $BroadbandName, ($WiredAdapters -join ','), $CheckInterval)

$lastState = ''
while ($true) {
    try {
        $state = ''
        if (-not (Test-WirePlugged)) {
            # 没插网线：什么都不做，也不影响其他网络
            $state = 'NO_WIRE'
            $script:FailStreak = 0
            if ($lastState -ne $state) { Write-Log 'INFO' '网线未连接（配置的有线网卡不在位），本轮跳过，不干预任何网络。' }
        }
        elseif (-not (Test-BroadbandUp)) {
            # 网线在位但宽带会话没连上 → 立即拨号（受退避约束）
            $state = 'BB_DOWN'
            $script:FailStreak = 0
            if ([datetime]::Now -ge $script:NextDialAt) {
                $null = Invoke-DialWithBackoff -Reason '网线在位但宽带会话未连接'
            }
            elseif ($lastState -ne $state) {
                Write-Log 'INFO' '宽带会话未连接，处于拨号退避等待中。'
            }
        }
        else {
            if (Test-Internet) {
                # 一切正常
                $state = 'OK'
                $script:FailStreak = 0
                if ($lastState -ne $state) { Write-Log 'INFO' '宽带已连接，Internet 探测正常。' }
                # 宽带正常（无论谁拨上的）：学习当前链路特征并入指纹，
                # 覆盖用户手动拨号、运营商换 IP 池等场景
                Merge-FingerprintFromCurrent
            }
            else {
                # 会话在但上不了网：连续达标后断开重拨
                $state = 'BB_STALE'
                $script:FailStreak++
                if ($script:FailStreak -le $FailThreshold) {
                    Write-Log 'WARN' ('宽带会话在，但连续第 {0}/{1} 轮 Internet 探测失败' -f $script:FailStreak, $FailThreshold)
                }
                if ($script:FailStreak -ge $FailThreshold) {
                    if ([datetime]::Now -ge $script:NextDialAt) {
                        Write-Log 'ACTION' ('连续 {0} 轮探测失败，判定宽带会话僵死：先断开再重拨' -f $script:FailStreak)
                        & $RasDialExe $BroadbandName '/disconnect' 2>&1 | Out-Null
                        Start-Sleep -Seconds 8
                        $null = Invoke-DialWithBackoff -Reason '僵死会话重拨'
                        $script:FailStreak = 0
                    }
                    elseif ($lastState -ne 'BB_STALE_WAIT') {
                        Write-Log 'INFO' 'Internet 持续不可达，处于拨号退避等待中。'
                    }
                }
            }
        }
        $lastState = $state

        # 每小时心跳，方便确认守护进程活着
        if (((Get-Date) - $script:LastBeat).TotalMinutes -ge 60) {
            $bbState   = if (Test-BroadbandUp) { '已连接' } else { '未连接' }
            $wireState = if (Test-WirePlugged) { '在位' } else { '不在位' }
            Write-Log 'INFO' ('心跳：宽带 {0}，网线 {1}' -f $bbState, $wireState)
            $script:LastBeat = Get-Date
        }
    }
    catch {
        Write-Log 'ERROR' ('本轮检测异常：{0}' -f $_.Exception.Message)
    }

    if ($Once) { break }
    Start-Sleep -Seconds $CheckInterval
}

try { $mutex.ReleaseMutex() } catch { }
