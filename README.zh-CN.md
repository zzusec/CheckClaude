# CheckClaude

[English](README.md) · **简体中文**

检查这台机器适不适合运行 Claude / Claude Code，并把能自动修的直接修掉。

菜单栏 / 托盘常驻，26 项加权信号打分（0–100），指出问题、差几分、下一步做什么；
系统时区、系统区域、DNS 泄漏、PAC 分流可一键修复。macOS、Windows、Linux 三端同一套评分模型。

只依赖系统自带能力，无第三方运行时依赖，不需要账号，不上传任何数据。

```
Claude 环境 🟢 98 分 · 优秀
   环境适合运行 Claude
   ── 还能提 2 分 ──
      ＋2  出口稳定性：固定一个节点，24 小时内别切线路
   ── 出口 ──
   ✓ 出口国家：US Los Angeles          14/14
   ✓ Anthropic API 可达：HTTP 401      10/10
   …
```

> **免责声明**：分数只反映本机环境画像中的矛盾信号，不代表 Anthropic 的官方判定，
> 也不构成账号安全保证。本工具不读取、不修改任何 Claude 账号凭据。

## 下载

| 平台 | 下载 | 要求 |
|---|---|---|
| macOS | [CheckClaude.dmg](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude.dmg) | macOS 12+，Apple 芯片与 Intel 通用二进制 |
| Windows | [CheckClaude-win.zip](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude-win.zip) | Windows 10/11，解压即用，无需安装运行时 |
| Linux | [checkclaude-amd64.deb](https://github.com/zzusec/CheckClaude/releases/latest/download/checkclaude-amd64.deb) · [tar.gz](https://github.com/zzusec/CheckClaude/releases/latest/download/checkclaude-linux-amd64.tar.gz) | Debian / Ubuntu amd64，CLI 静态二进制 + GTK 托盘 |

三端均未做代码签名，首次打开会被系统拦截。

**macOS** —— 拖进 `Applications`。macOS 15 起 Apple 已移除「右键 → 打开」这条路径，改用其一：

```bash
xattr -dr com.apple.quarantine /Applications/CheckClaude.app
```

或双击一次让它被拦，再到 **系统设置 → 隐私与安全性 → 安全性 → 「仍要打开」**。

**Windows** —— 被 SmartScreen 拦时点「更多信息」→「仍要运行」。托盘右键菜单里可勾选
「开机自启」（写 `HKCU` Run 项，不需要管理员）。

**Linux** —— `sudo dpkg -i checkclaude-amd64.deb`，缺依赖时补 `sudo apt -f install`。
服务器上只装 CLI 也能跑；桌面装 `.deb` 会同时装托盘并注册开机自启。

## 命令行

**macOS**

```bash
~/CheckClaude/claude-check.sh               # 完整体检报告
~/CheckClaude/claude-check.sh --fix         # 执行安全可恢复的修复
~/CheckClaude/claude-check.sh --fix-locale  # 额外把系统区域改成出口国家
~/CheckClaude/auto-timezone.sh --check      # 只检测三路一致性，不改时区
~/CheckClaude/auto-timezone.sh --dry-run    # 显示将改成的时区，不实际写入
```

**Windows**

```
CheckClaude.exe --check     # 打印完整体检报告，不启动托盘
CheckClaude.exe --version
```

**Linux**

```bash
checkclaude --check         # 完整体检报告
checkclaude --json          # 机器可读 JSON
checkclaude --browser       # 打开默认浏览器采集真实指纹并展示网页报告
checkclaude --fix           # 执行安全可恢复的修复（时区 / GNOME PAC）
checkclaude --fix-locale    # 写入用户级区域格式覆盖，不改显示语言
checkclaude --tray-status   # 托盘用的单行 TSV
```

命令行单跑时没有浏览器上下文，浏览器组 7 项按中性分计入，不假装测过。

## 评分模型

26 项加权信号，满分 100，分 6 组：

| 组 | 信号 | 权重 | 判定依据 |
|---|---|---|---|
| 出口 | 出口国家 | 14 | 是否落在 Anthropic 不服务地区（CN / HK / RU / IR…） |
| 出口 | Anthropic API 可达 | 10 | 401 为正常；403 表示出口被地区拦截 |
| 出口 | IPv6 出口 | 3 | 代理只接管 IPv4 时，IPv6 直连会暴露真实地区 |
| 出口 | 多源情报一致 | 3 | 四家 IP 情报源对同一出口的 ISO 国家码是否一致 |
| 出口 | claude.ai 可达 | 2 | 测 `robots.txt`；主页对裸 curl 一律 403，那是 bot 挑战 |
| 出口 | anthropic.com 可达 | 2 | 官网与 API 走不同前端，分开测可区分整体被拦与单点异常 |
| 质量 | IP 类型 | 4 | 住宅 / 机房 IDC / 公开代理 |
| 质量 | 边缘机房匹配 | 3 | Cloudflare 落地机房与 IP 库归属是否一致 |
| 质量 | 出口链路单一 | 3 | CF 看到的来源 ≠ 检测到的出口，即多层嵌套代理 |
| 画像 | 三路出口一致 | 6 | 分流 / PAC 会让画像在多个地区之间跳变 |
| 画像 | 系统时区匹配出口 | 5 | 典型矛盾信号，**可一键修复** |
| 画像 | 系统区域匹配出口 | 4 | 系统区域设置与出口地区矛盾，**可一键修复** |
| 画像 | 语言变体一致 | 2 | 简繁体与出口地区的对应（繁体 → TW / HK / MO） |
| 画像 | 时区偏移自洽 | 2 | UTC 偏移与时区名冲突，即被 `TZ` 覆盖过 |
| DNS | claude.ai 解析 | 6 | 正常 / fake-ip 接管 / 被污染 |
| DNS | DNS 出口 | 4 | 用国内公共 DNS 即查询泄漏，**可一键修复** |
| 稳定 | 出口稳定性 | 4 | 24 小时内出口跳变次数（读本地日志，网页端做不到） |
| 稳定 | 代理形态 | 3 | TUN 全局 / 系统代理 / PAC 分流，**PAC 可一键修复** |
| 稳定 | 运行容器 | 3 | 物理机 / 虚拟机 |
| 浏览器 | WebRTC 出口 | 6 | UDP 不走 HTTP 代理，能暴露代理没兜住的真实出口 |
| 浏览器 | 浏览器时区 | 3 | `Intl` 时区与系统时区是否一致 |
| 浏览器 | 浏览器语言 | 2 | `navigator.languages` 与出口地区是否矛盾 |
| 浏览器 | 渲染环境 | 2 | WebGL 渲染器 / Canvas 指纹 / 中文字体探测 |
| 浏览器 | Client Hints | 2 | Chromium 上报的平台是否与真实系统一致 |
| 浏览器 | Intl 区域设置 | 1 | 浏览器国际化配置与出口地区是否对应 |
| 浏览器 | HTTP 语言首标 | 1 | `Accept-Language` 是否与出口地区冲突 |

### 档位

档位采用二元口径：**只有绿档说「可用」，其余一律明说「不建议使用」**。

| 档位 | 条件 |
|---|---|
| 🟢 优秀 | ≥ 90 分，**且** 6 项关键信号全部满分 —— 唯一判定为「环境适合运行 Claude」的档 |
| 🟠 风险 | 三路出口不一致（分流模式），不论总分多少 |
| 🟠 有风险 | ≥ 70 分 |
| 🔴 高风险 | ≥ 50 分，或出口落在 Anthropic 不服务地区 |
| 🔴 危险 | < 50 分 |

**关键项一票否决**：出口国家、Anthropic API 可达、系统时区匹配出口、WebRTC 出口、IPv6 出口、
三路出口一致 —— 任一项不满分，总分再高也不进绿档。同样是 90 分，「丢了 10 分轻微项」和
「WebRTC 泄漏 6 分 + 时区不符 5 分」风险天差地别，后者真实出口已经暴露。

三路出口不一致单独硬降级：账号画像在多地区间跳变是风控最敏感的信号之一，只按 6 分扣分会让
80 多分的环境显示成可用，与红色图标自相矛盾。

评分模型参考 [check-cc](https://github.com/yacuo/check-cc) 的多信号加权思路，三端各自本地实现。

## 检测方法

### 三路出口一致性

从三个不同目的地回显来源 IP：

| 视角 | 含义 | 接口（多路兜底） |
|---|---|---|
| 国内 | 访问国内网站时对方看到的 IP | 3322 / pconline / bilibili / ipip（均为 HTTPS） |
| 国外 | 访问未被封国外网站时的 IP | ipify / icanhazip / ipinfo |
| 谷歌 / 被封 | 访问谷歌等被封网站时的 IP | Cloudflare trace / ip.sb + Google 可达性 |

三者一致即为干净的真实出口；都成功但结果不一致则判定为分流 / PAC / DNS 泄漏，连续两次确认后告警。
任一路临时超时标记为网络波动并沿用上次有效结果，单次查询失败不计作 IP 变化。系统时区始终以
**谷歌侧出口 IP** 为准解析写入。

线路质量统一走 HTTPS over TCP，不依赖 ICMP：最近 24 小时按路记录总耗时、TCP 建连、TLS 握手、
TTFB、HTTP 状态和成功率。

### 浏览器指纹采集

完整体检会通过只监听 `127.0.0.1` 的一次性本地桥接，用系统默认浏览器采集 WebRTC、`Intl`、
Client Hints、`Accept-Language`、WebGL、Canvas 与中文字体等真实信号 —— 这才是网页端登录
claude.ai 时对方实际看到的那一套。URL 带随机 token，结果写入本机 `browser_signals`，
完成或超时后监听立即关闭，不经过任何外部服务器。

桥接同时核对 HTTP UA 与 JavaScript UA、UA-CH 平台与品牌、`Accept-Language` 与
`navigator.languages`，并并行检查 `claude.ai`、Anthropic 官网与 API 的浏览器侧传输路径和耗时，
用来发现浏览器扩展代理 / PAC 与 shell 网络路径不一致。最后这部分是诊断信息，不把 `no-cors`
当作 HTTP 状态判断。

> **改完浏览器设置后，要点「重新体检（含浏览器采集）」**，只有它会重新打开浏览器采集。
> 旁边的「立即检测（不含浏览器）」只做轻量出口探测，沿用一小时内的上次浏览器结果。
> Windows 托盘的「浏览器画像」一行会显示这份数据由**哪个浏览器、几分钟前**采集 ——
> 采集走的是**系统默认浏览器**，如果你改的不是它，改了也不会反映到分数上。

macOS 在默认浏览器回传失败时回退到内置 WKWebView；Windows 与 Linux 保留一小时内的有效结果，
超时后按中性分计入。

### IP 情报交叉验证

出口 IP 情报并行查询 `ip-api`、`ipinfo`、`ipwho.is`、`api.ip.sb`，四家针对同一个已确认的出口 IP，
国家码统一为 ISO 两位后再比较。IPv4、IPv6 与 Cloudflare 边缘节点分开处理，不同协议族或 CDN
中间节点不计作情报冲突。多家情报不一致、或出口位于不支持地区时，不自动修改系统区域。

## 一键修复

| 问题 | 修复方式 |
|---|---|
| 系统时区与出口不符 | 全自动改写 |
| PAC 自动分流 | 全自动关闭 |
| DNS 泄漏 / 被污染 | 全自动换成境外 DNS，**先验证**候选能正确解析 `claude.ai` 再写入，并备份原值 |
| 系统区域与出口不符 | 出口为已确认的支持地区时自动调整，不改显示语言 |
| 浏览器语言 | 手动，报告里直接给出对应浏览器的设置路径 |
| 换节点 / 换住宅 IP / 固定线路 | 只能手动，报告中给出具体建议 |

DNS 修复先用 `1.1.1.1 / 8.8.8.8 / 9.9.9.9` 各解析一次 `claude.ai`，确认拿到 Anthropic 或
Cloudflare 的真实地址（未被投毒）才写入系统，原值备份在 `dns_backup`，撤销一条命令。
三家全部被投毒时才退回 DoH 描述文件。

> macOS 把 DNS Settings 实现为 Network Extension，机器上运行 FlClash / Surge / Clash Verge
> 这类带 TUN 的代理时安装会失败并报 `The VPN service could not be created`，需先退出代理 App。
> 因此 DoH 描述文件不作为首选方案。

各平台的提权方式：

- **macOS** —— `sudo bash enable-auto-timezone.sh` 为 `systemsetup` / `networksetup` 开 NOPASSWD；未配置时改时区弹一次系统授权框。
- **Windows** —— 改系统时区和 DNS 时弹一次 UAC。
- **Linux** —— root 直接改，桌面用户走 `pkexec`，都拿不到时只打印手动命令。Linux 版不会自动改写 `/etc/resolv.conf`、NetworkManager、IPv6、系统显示语言和浏览器配置。

## Codex 防降智（macOS）

Codex 的每次请求都带 `x-codex-turn-state`，表示这一轮从哪个状态续上。新会话没有它，等于每次都
从冷状态开始。CheckClaude 起一个只监听 `127.0.0.1` 的反代，把仍在有效期内的 state 跨会话复用：

```
codex ──► 127.0.0.1:8788/backend-api ──► chatgpt.com/backend-api
             采集 / 校验 / 注入 state
```

- **默认开启、后台常驻**，不需要勾选；菜单栏只显示一行状态，要关跑 `codex-guard.sh --disable`。
- 只在 codex 走官方 ChatGPT 登录时接入；`model_provider` 指向第三方中转时自动跳过（注入对上游没有意义）。
- 接入方式是在 `~/.codex/config.toml` 顶部写 `chatgpt_base_url`，原文件备份为 `config.toml.checkclaude-backup`，关闭 / 卸载时逐行还原。
- state 只校验结构（`0x80` 开头、10 块、签发时间在有效期内），不合格不缓存；只留在反代进程内存里，落盘的只有指纹和计数。
- 反代由 LaunchAgent 常驻，App 退出或崩溃都不影响 codex 正常使用；起不来会自动回滚配置。
- 缓存快过期时用上一次请求的凭据补一针探针续期，失败进冷却，不重放真实请求。

这只能保持请求参数一致，**不保证模型质量、账号额度或服务端路由**。292/10 块是经验规则，
不是官方公布的指标。

## 告警与监控

后台按可选间隔（默认 1 分钟）只做轻量三路出口探测；完整体检仅在首次启动、出口状态变化或手动
触发时运行，不会每分钟去敲 Anthropic 接口。

- 出口 IP 连续两次确认发生变化 → 通知「出口 IP 变化 A → B」
- 由一致变为不一致 → 通知「⚠️ 出口 IP 异常」；恢复一致 → 通知「出口已恢复正常」
- 单次查询失败只显示「网络检测波动」并沿用上次有效结果
- 检测进程带互斥锁，慢请求不会与下一轮并发覆盖状态
- 仅在状态**真正变化**时提醒

菜单栏 / 托盘图标：🟢 一致　🟠 网络波动 / 复核中　🔴 异常　⚪️ 暂无数据。
macOS 的网络波动图展示最近 60 次四路耗时趋势，国内、国外、谷歌侧、Google 各占一行，折线为耗时、
橙点为该路获取失败、红线为已确认的出口 IP 变化；鼠标悬停显示该时间点的各路延迟，子菜单汇总最近
24 小时各路成功率、失败次数、平均耗时与 IP 变化次数。

## 从源码构建

**macOS**

```bash
git clone https://github.com/zzusec/CheckClaude.git
cd CheckClaude
bash install.sh          # 构建并装到 /Applications + 开机自启，无需 sudo
bash build_dmg.sh        # 生成可分发的 CheckClaude.dmg
bash uninstall.sh
```

`install.sh` 会编译菜单栏 App、加载 root 守护进程（自动改时区 + 告警）、设置开机自启。
App 自包含，检测脚本打包在 `CheckClaude.app/Contents/Resources/`，数据写入
`~/Library/Application Support/CheckClaude`。

> 建议在「系统设置 → 通用 → 日期与时间」中**关闭「自动设置时区」**，否则系统定位会与本工具冲突。

**Windows** —— .NET Framework 4.8（Windows 10/11 自带）+ `csc.exe` 编译为单个 exe。
在 Mac 上可远程构建与测试：

```bash
WIN_HOST=win-ding bash windows/build-remote.sh 4.18
WIN_HOST=win-ding bash windows/test-remote.sh
```

**Linux** —— 纯 Go 静态二进制（CLI，无 GTK 依赖）加一个 GTK3 + Ayatana AppIndicator 托盘。

```bash
LINUX_HOST=root@你的构建机 bash linux/build-remote.sh
```

**自测**（均不联网）：

```bash
bash test-claude-check.sh     # 评分模型
bash test-auto-timezone.sh    # 网络波动状态机
bash test-browser-report.sh   # 完整浏览器报告页
bash test-upgrade.sh          # 升级流程
bash test-codex-guard.sh      # codex 反代，本机假上游
cd linux && go test ./...     # Linux 评分引擎
bash windows/test-remote.sh   # Windows 桥接，含真实 Edge 端到端采集
```

## 项目结构

| 路径 | 作用 |
|---|---|
| `claude-check.sh` | macOS 体检引擎：26 项加权信号 + 问题清单 + 修复建议 + 自动修复 |
| `auto-timezone.sh` | macOS 三路检测 + 谷歌侧 IP 时区解析 + 自动改时区 + 变化告警 |
| `codex-guard.sh` · `menubar/CodexGuard.swift` | Codex 防降智：本机反代、`x-codex-turn-state` 缓存与注入 |
| `menubar/StatusApp.swift` · `menubar/build.sh` | macOS 菜单栏 App 与构建脚本 |
| `windows/Program.cs` | Windows 托盘、检测、修复与升级主逻辑 |
| `windows/BrowserBridge.cs` | Windows 真实浏览器指纹本地桥接 |
| `linux/cmd/` · `linux/internal/` | Linux CLI 与 GTK 托盘 |
| `install.sh` · `uninstall.sh` · `upgrade.sh` | 安装 / 卸载 / 检查 GitHub Releases 并在线升级 |
| `com.example.checkclaude-daemon.plist` | macOS 守护进程：每 5 分钟 + 网络变化触发 |

## 许可

[MIT](LICENSE)

## 关于作者

这个工具是我每天自己在用的东西，顺手开源。主力产品是**叮叮提醒** —— 吃药、还款、农历生日、
纪念日倒数、考试倒计时，说一句话就能创建，到点通过微信、邮件、短信或电话送达；微信小程序 /
macOS / Windows 三端同步，微信与邮件提醒终生免费。官网 <https://www.yinso.com>，
微信小程序搜「叮叮提醒」。

感谢 [linux.do](https://linux.do/) —— 一个充满活力的技术社区，本项目也在这里分享和交流。
