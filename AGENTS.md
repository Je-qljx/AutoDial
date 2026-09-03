# AGENTS.md — AutoDial 项目指南

宽带自动拨号守护脚本（Windows PowerShell）。检测到网线插在宽带光猫链路上但 PPPoE 会话掉线时自动重拨；通过「链路指纹」防止把其他网络的网线误判为宽带线路。

## 项目结构

- `AutoDial.ps1` — 主脚本（单文件守护循环），顶部「配置区」含全部可调参数
- `Start-AutoDial.vbs` — wscript 隐藏启动器（登录自启入口，保持 ASCII 编码）
- `Install-AutoDial.ps1` / `Uninstall-AutoDial.ps1` — 用户级启动项安装/卸载（无需管理员权限）
- `gateway.mac` — 链路指纹（运行时生成，JSON，不入库）
- `Logs/AutoDial-YYYYMMDD.log` — 运行日志（不入库，保留 30 天自动清理）

## 运行环境与硬性约束

- Windows 11 + Windows PowerShell 5.1。不要使用 pwsh 7+ 独有语法。
- **所有 .ps1 必须保存为 UTF-8 带 BOM**，否则 5.1 读取中文连接名/网卡名会乱码。
- 宽带条目名 `宽带连接`、网卡名 `以太网` 来自用户系统，改动配置区即可适配其他机器。
- `rasdial` 的成败以**退出码**为准（0=成功），输出文本仅入日志；628 可能是 691（认证失败）的伪装，需查 `Microsoft-Windows-EapMethods-RasChap/Operational` 事件 101 确认。
- 该机器为桥接光猫：`Get-NetAdapter` 的 `MediaConnectState`/`Status` 在此系统返回**数字**（1=Connected/Up）而非字符串枚举，比较时必须兼容两种类型（见 `Test-WirePlugged`/`Test-BroadbandUp`）。
- 网卡 IP 由运营商 IP 池分配，**每次插拔网线可能换 /24 网段**，指纹兜底只能用 /16 级前缀（如 `36.5.`）。

## 核心设计（改动前必读）

1. **只操作「宽带连接」这一个 RAS 条目**：绝不修改路由表、网卡 metric、其他适配器（WLAN/蓝牙等）。这是用户的核心诉求。
2. **拨号守门**：`Invoke-DialWithBackoff` 入口处必须先过 `Test-LinkAllowed`（链路指纹校验），指纹不匹配（插了其他网络的网线）一律拒绝拨号。
3. **退避策略**：普通失败指数退避（15s×2ⁿ，上限 10min）；认证类失败（691/628 确认）固定 15 分钟——账号被占用时密集重拨毫无意义且有锁号风险。
4. **单实例**：命名 Mutex `AutoDial_BroadbandGuard` 防止多实例同时拨号。
5. **指纹自动学习**：拨号成功且探测通过时调用 `Merge-FingerprintFromCurrent` 并入当前 MAC/网段前缀，适应运营商侧变化。

## 测试与验证

- 语法校验：`powershell -NoProfile -Command "$null = [ScriptBlock]::Create((Get-Content -Raw 'D:\AutoDial\AutoDial.ps1'))"`
- 单轮检测（不拨号也会跑完整判定链）：`AutoDial.ps1 -Once`
- 前台观察：`AutoDial.ps1 -Console`；绑定指纹：`AutoDial.ps1 -BindGateway`
- 模拟断网：`rasdial 宽带连接 /disconnect`，然后看日志自动重拨。**注意**：若账号被占用（628/691），重拨会失败并进入 15 分钟退避，这不是脚本 bug。
- 改完配置后需重启守护：先 `Uninstall-AutoDial.ps1` 再 `Install-AutoDial.ps1`。

## Git 约定

- 提交信息用中文，首行一句话概括，正文说明动机与关键决策（参照现有提交）。
- `Logs/`、`gateway.mac`、`.zcode/` 已在 .gitignore，不要提交。
