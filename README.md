# CheckClaude

**检查这台机器适不适合跑 Claude**，并把能自动修的直接修掉。附带按出口 IP 自动设置 macOS 系统时区。

菜单栏/托盘常驻，26 项加权信号打分（0–100），列出问题、差几分、下一步做什么；时区、DNS 泄漏、PAC 分流可以一键修复。
只依赖系统自带能力，无第三方运行时依赖，不要账号，不上传任何数据。

```
Claude 环境 🟢 98 分 · 优秀
   环境适合运行 Claude
   ── 还能提 2 分 ──
      ＋2  出口稳定性：固定一个节点，24 小时内别切线路
   ── 出口 ──
   ✓ 出口国家：US Los Angeles          18/18
   ✓ Anthropic API 可达：HTTP 401      10/10
   …
```

> 分数只反映环境画像冲突，不代表 Anthropic 官方判定，也不保证账号安全。

## 下载

| 平台 | 下载 | 要求 |
|---|---|---|
| macOS | [CheckClaude.dmg](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude.dmg) | macOS 12+，拖进 Applications，首次打开见下方说明 |
| Windows | [CheckClaude-win.zip](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude-win.zip) | Windows 10/11，解压双击即用，无需装运行时 |

两端使用同一套评分模型（26 项加权信号，合计 100）。完整体检会通过本机回环地址打开系统默认浏览器，
采集 WebRTC、Intl、Client Hints、HTTP 语言首标、WebGL、Canvas 和字体等真实浏览器信号；数据只回传给本机 CheckClaude。
命令行单跑没有浏览器上下文，浏览器组按中性分计入，不假装测过。

Windows 版是 .NET Framework 4.8（Windows 10/11 系统自带）+ `csc.exe` 编译的单个 exe，托盘常驻。
修改系统时区和 DNS 需要管理员权限，点「一键修复」时会弹一次 UAC。

```
CheckClaude.exe --check     # 打印完整体检报告，不启动托盘
CheckClaude.exe --version   # 打印版本号
```

托盘右键菜单里可勾选「开机自启」（写 HKCU Run 项，不需要管理员）。
首次运行若被 SmartScreen 拦（未做代码签名），点「更多信息」→「仍要运行」。

## 快速开始

```bash
git clone https://github.com/zzusec/CheckClaude.git
cd CheckClaude
bash install.sh          # 构建并装到 /Applications + 开机自启，无需 sudo
```

首次打开会被 Gatekeeper 拦（未做代码签名）。macOS 15 起 Apple **移除了「右键→打开」**这条绕过路径，
现在有两种办法：

```bash
# 办法一：终端一条命令解除隔离，最快
xattr -dr com.apple.quarantine /Applications/CheckClaude.app
```

办法二：双击一次让它被拦，然后 **系统设置 → 隐私与安全性** → 往下滚到「安全性」→
「已阻止使用 "CheckClaude"」→ 点「**仍要打开**」。

改时区时会弹一次系统授权框（密码 / Touch ID），属正常。

## 组成

| 文件 | 作用 |
|---|---|
| `auto-timezone.sh` | 引擎：三路检测 + 解析谷歌侧 IP 时区 + 自动改时区 + 变化告警 |
| `claude-check.sh` | Claude 运行环境体检：26 项加权信号打分 + 问题清单 + 修复建议 + 自动修复 |
| `test-claude-check.sh` | macOS 体检评分逻辑自测（不联网） |
| `upgrade.sh` | 检查 GitHub Releases 新版本 + 一键升级 |
| `windows/Program.cs` | Windows 版托盘、检测、修复和升级主逻辑 |
| `windows/BrowserBridge.cs` | Windows 真实浏览器指纹本地桥接 |
| `windows/BrowserBridgeTests.cs` | Windows 浏览器桥接自动测试 |
| `windows/build-remote.sh` / `windows/test-remote.sh` | 在 Mac 上远程构建并测试 Windows 产物 |
| `com.hx10.checkclaude-daemon.plist` | 系统守护进程：每 5 分钟 + 网络变化触发（root，改时区免密码） |
| `menubar/CheckClaude.app` | 菜单栏图标 App（开机自启，监控 + 告警 + 手动检测） |
| `menubar/*.plist` | 菜单栏 App 的开机自启 LaunchAgent |
| `install.sh` / `uninstall.sh` | 一键安装 / 卸载 |
| `status` / `last_state` / `*.log` | 运行快照 / 变化基线 / 日志 |

## 三路一致性检测（ip111 逻辑）

从三个不同目的地回显你的来源 IP：

| 视角 | 含义 | 接口（多路兜底） |
|---|---|---|
| 国内 | 访问国内网站时对方看到的 IP | pconline / 百度 / bilibili / 3322 |
| 国外 | 访问未被封国外网站时的 IP | ipify / icanhazip / ipinfo |
| 谷歌/被封 | 访问谷歌等被封网站时的 IP | Cloudflare trace / ip.sb + Google 可达性 |

- 三者一致 → 干净的真实出口（🟢）。
- 三者不一致 / 有缺失 → 出口 IP 有问题（🔴，疑似分流 / PAC / DNS 泄漏），**弹桌面告警**。
- **时区始终以"谷歌/被封侧出口 IP"为准**（经 `ipinfo.io` 解析），自动写入系统时区。

## Claude 运行环境体检

判断当前环境是否适合运行 Claude / Claude Code：打分 + 问题清单 + 修复建议 + 自动修复。
评分模型参考 [check-cc](https://github.com/yacuo/check-cc) 的多信号加权思路，改为 macOS 本地实现，
复用上面已经拿到的三路出口数据，不额外依赖 Node。

```bash
~/CheckClaude/claude-check.sh              # 体检并打印报告
~/CheckClaude/claude-check.sh --fix        # 顺带自动修可安全修复项（时区）
~/CheckClaude/claude-check.sh --fix-locale # 额外把系统「区域」改成出口国家
```

共 **26 项加权信号**，合计 100 分，分 6 组：

| 组 | 信号 | 权重 | 说明 |
|---|---|---|---|
| 出口 | 出口国家 | 14 | 是否落在 Anthropic 不服务地区（CN/HK/RU/IR…） |
| 出口 | Anthropic API 可达 | 10 | 返回 401 为正常；403 = 出口被地区拦截 |
| 出口 | **IPv6 出口** | 3 | 代理只接管 IPv4 时，IPv6 直连会暴露真实地区 |
| 出口 | 多源情报一致 | 3 | 两家 IP 情报库对该出口判定是否冲突 |
| 出口 | claude.ai 可达 | 2 | 测 `robots.txt`——主页对裸 curl 一律 403，那是 bot 挑战 |
| 出口 | **anthropic.com 可达** | 2 | 官网与 API 走不同前端，分开测才能区分整体被拦与单点异常 |
| 质量 | IP 类型 | 4 | 住宅 / 机房 IDC / 公开代理 |
| 质量 | 边缘机房匹配 | 3 | Cloudflare 落地机房与 IP 库归属是否一致 |
| 质量 | 出口链路单一 | 3 | CF 看到的来源 ≠ 检测到的出口 = 多层嵌套代理 |
| 画像 | 三路出口一致 | 6 | 分流 / PAC 会让画像在多地区间跳变 |
| 画像 | 系统时区匹配出口 | 5 | 典型矛盾信号，**可一键修复** |
| 画像 | 系统区域匹配出口 | 4 | 系统区域与出口地区矛盾 |
| 画像 | **语言变体一致** | 2 | 简体/繁体与出口地区的对应（繁体→TW/HK/MO） |
| 画像 | 时区偏移自洽 | 2 | UTC 偏移与时区名冲突 = 被 `TZ` 覆盖过 |
| DNS | claude.ai 解析 | 6 | 正常 / fake-ip 接管 / 被污染 |
| DNS | DNS 出口 | 4 | 用国内公共 DNS = 查询泄漏，**可一键修复** |
| 稳定 | 出口稳定性 | 4 | 24h 内出口跳变次数（读本地日志，网页端做不到） |
| 稳定 | 代理形态 | 3 | TUN 全局 / 系统代理 / **PAC 分流**，可一键修复 |
| 稳定 | 运行容器 | 3 | 物理机 / 虚拟机 |
| 浏览器 | WebRTC 出口 | 6 | **UDP 不走 HTTP 代理**，能暴露代理没兜住的真实出口 |
| 浏览器 | 浏览器时区 | 3 | Intl 时区与系统时区是否一致 |
| 浏览器 | 浏览器语言 | 2 | `navigator.languages` 与出口地区是否矛盾 |
| 浏览器 | 渲染环境 | 2 | WebGL 渲染器 / Canvas 指纹 / 中文字体探测 |
| 浏览器 | **Intl 区域设置** | 1 | 浏览器国际化配置与出口地区是否对应 |
| 浏览器 | **Client Hints** | 2 | Chromium 上报的平台是否与真实系统一致 |
| 浏览器 | **HTTP 语言首标** | 1 | `Accept-Language` 是否与出口地区明显冲突 |

得分 ≥85 优秀 🟢，70–84 良好 🟡，50–69 风险 🟠，<50 高风险 🔴。

菜单栏/托盘里的「重新体检」会打开系统默认浏览器，通过只监听 `127.0.0.1` 的一次性本地桥接采集浏览器组信号。
URL 带随机 token，结果写进本机 `browser_signals`，完成或超时后监听立即关闭；不经过外部服务器。
macOS 在默认浏览器回传失败时会回退到内置 WKWebView，Windows 则保留上次一小时内的有效结果或按中性分计入。
命令行单跑时不会打开浏览器，浏览器组同样按中性分计入。

### 一键修复

| 问题 | 修复方式 |
|---|---|
| 系统时区与出口不符 | 全自动改（复用免密 `systemsetup`） |
| PAC 自动分流 | 全自动关（`networksetup -setautoproxystate off`） |
| DNS 泄漏 / 被污染 | 全自动换成境外 DNS——**先验证**候选能正确解析 `claude.ai` 再改，并备份原值 |
| 系统区域与出口不符 | 需显式 `--fix-locale`（会影响日期格式显示） |
| 换节点 / 换住宅 IP / 固定线路 | 只能手动，报告里给出具体建议 |

DNS 修复先拿 `1.1.1.1 / 8.8.8.8 / 9.9.9.9` 各解析一次 `claude.ai`，确认拿到 Anthropic/Cloudflare 真实地址
（没被投毒）才写入系统，原值备份在 `dns_backup`，撤销一条命令。三家全被投毒时才退回 DoH 描述文件。

> **DoH 描述文件不作为首选**：macOS 把 DNS Settings 实现成 Network Extension，机器上跑着
> FlClash / Surge / Clash Verge 这类带 TUN 的代理时安装会失败，报
> `The VPN service could not be created`。要用它得先退出代理 App。

自动关 PAC 和改 DNS 需要一次授权：

```bash
sudo bash enable-auto-timezone.sh   # 给 systemsetup / networksetup 开 NOPASSWD
```

菜单栏主菜单里直接有「重新体检」和「⚡ 一键修复：xxx」两个入口。
「Claude 环境 🟢 98 分（还能提 2 分）」子菜单展开是 26 项明细，末尾是**提分清单**——
每个没拿满分的项差几分、下一步具体做什么，按差值从大到小排：

```
── 还能提 2 分 ──
＋2  出口稳定性：固定一个节点，24 小时内别切线路(到点自动回满)
```

命令行 `claude-check.sh` 的报告里也有同样的「还能提 X 分」区块。
后台按可选间隔（默认 1 分钟）只做轻量三路出口探测；完整 Claude 体检**只在首次启动、出口状态变化或手动点击时触发**，不会每分钟去敲 Anthropic 接口。

> 分数只反映环境画像冲突，不代表 Anthropic 官方判定，也不保证账号安全。

评分逻辑自测（不联网）：`bash test-claude-check.sh`

## 告警

- 出口 IP 相比上次发生变化 → 通知「出口 IP 变化 A → B」。
- 由一致变为不一致 → 通知「⚠️ 出口 IP 异常」；恢复一致 → 通知「出口已恢复正常」。
- 仅在状态**真正变化**时提醒，不会每 5 分钟刷屏。

## 菜单栏图标

点击图标显示：三路 IP、Google 可达性、**谷歌侧时区**、当前系统时区、更新时间；
并提供「立即检测 / 打开日志 / 退出」。图标含义：🟢 一致　🔴 异常　⚪️ 暂无数据。

## 打包成 dmg(分发)

```bash
bash ~/CheckClaude/build_dmg.sh   # 生成 CheckClaude.dmg
```

App 自包含:检测脚本打包在 `CheckClaude.app/Contents/Resources/`，数据写入
`~/Library/Application Support/CheckClaude`，改时区时弹一次系统授权框 —— 不依赖
root 守护进程，拷到任何 Mac 都能用。挂载 dmg 后把 App 拖进 Applications 即可，
首次打开被拦时按上面「快速开始」里的两种办法之一处理。开机自启在「系统设置→通用→登录项」添加。

## 安装(本机，含 root 守护进程方案)

```bash
bash ~/CheckClaude/install.sh    # 不要加 sudo；脚本内部会在装守护进程时索要一次密码
```

安装内容：① 编译菜单栏 App　② 加载 root 守护进程（自动改时区 + 告警）　③ 菜单栏 App 设为开机自启。

> 建议在「系统设置 → 日期与时间」里**关闭"自动设置时区"**，否则系统定位会与本工具冲突。

## 卸载

```bash
bash ~/CheckClaude/uninstall.sh
```

## 手动用法

```bash
~/CheckClaude/auto-timezone.sh --check     # 只检测三路一致性并打印，不改时区
~/CheckClaude/auto-timezone.sh --dry-run   # 检测 + 显示将改的时区，不实际改
~/CheckClaude/auto-timezone.sh             # 检测 + 按谷歌侧 IP 自动改时区（需 sudo）
```

## 工作原理

1. 三路视角回显来源 IP，判断一致性（不一致即告警）。
2. 取"谷歌/被封侧"出口 IP，用 `ipinfo.io` 解析成 IANA 时区（如 `Asia/Shanghai`）。
3. 读 `/etc/localtime` 软链得当前时区（无需 sudo），相同则跳过。
4. `/usr/share/zoneinfo/<tz>` 校验合法后，`systemsetup -settimezone` 写入。
5. 与上次状态对比，IP 变化或一致性翻转则弹桌面通知。

---

## 关于作者

这个工具是我自己每天在用的东西，顺手开源。我的主力产品是：

### 叮叮提醒 — 重要的事，我来帮你记着

吃药、还款、农历生日、纪念日倒数、考试倒计时——**说一句话就能创建**，到点通过微信、邮件、短信或电话送达。
微信小程序 / macOS / Windows 三端同步，**微信与邮件提醒终生免费**。

- 官网：<https://www.yinso.com>
- 微信小程序搜「**叮叮提醒**」，无需下载安装
