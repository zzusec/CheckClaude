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

### v4.8（2026-09-18）

- 主菜单新增明确的 Claude 使用风险档位：安全、低风险、中风险、高风险、极高风险，并直接显示“可以安全使用 / 建议优化 / 不建议使用”等结论。
- 新增出口稳定性结论：显示最近 24 小时确认换 IP 次数，并明确提示是否应继续固定当前出口或关闭自动切换。
- “一键修复”不再因为剩余项需要手动处理而变灰：有自动项时直接修复；只有手动项时仍可点击并弹出具体修复方案。
- 修复手动指引误把“代理形态 / DNS 出口”当成已经自动修复而隐藏的问题。
- 菜单“HTTPS/TCP 线路质量”简化为“线路质量”；波动图支持鼠标悬停，立即显示对应时间点的国内、国外、谷歌侧和 Google 延迟值。
- 完整报告同步展示风险档位和出口 IP 稳定性矩阵；关键项冲突即使分数较高也保持高风险判定。

### v4.7（2026-09-17）

- 完整检测报告加载完成后显示 4 秒倒计时并自动关闭浏览器标签页，减少体检完成后遗留页面。
- 倒计时期间可点“保持打开”取消自动关闭，便于继续查看完整证据；若浏览器阻止脚本关闭，会明确提示手动关闭。
- 自动关闭发生在报告数据已经完整渲染、localhost listener 已回收之后，不影响检测结果写入。

### v4.6（2026-09-17）

- 浏览器检测页升级为完整本机报告：等待系统体检完成后展示出口 IP、三路出口、IP 情报、时区、WebRTC、DNS、Claude 连通性、HTTPS/TCP 质量以及全部 26 项评分证据。
- 新增 40+ 原始浏览器诊断维度，包括语言变体、字体分类、Emoji 风格、WebView/自动化环境、屏幕与硬件、隐私存储、Network Information、WebGL 和 Canvas；新增字段先用于诊断，不暗改原有 100 分模型。
- 新增信号一致性矩阵，直接比较出口/系统/浏览器时区、WebRTC/IPv6/Cloudflare 出口、HTTP/JS UA 与语言、shell/浏览器连通路径。
- 报告页不再 10 秒自动关闭；完整报告加载后立即回收 localhost listener，页面由用户手动关闭。
- 报告数据仅通过绑定 `127.0.0.1`、带随机令牌和 CSP 的本机接口传输；动态值用 DOM `textContent` 渲染。
- 修复菜单“系统时区已匹配”固定绿色文字在蓝色选中背景下对比度不足的问题，改用 AppKit 原生选中态文字颜色。
- 支付/账号地区明确标注为人工核对项，不伪装成工具已经读取或检测付款资料。

### v4.5（2026-09-16）

- 系统时区改为独立跟随 Claude/Google 实际路径的“谷歌侧出口 IP”；国内或国外辅助探针波动时也不会阻塞时区修正。
- 谷歌侧出口变化连续确认两次后，将出口 IP 与 IANA 时区成对提交；以后每轮检测都会纠正被定位服务或人工改回的系统时区。
- 线路波动和质量检测统一使用 HTTPS over TCP，不再依赖 ICMP/ping，也不再用明文 HTTP 探针。
- 最近 24 小时记录四路 HTTPS 总耗时、TCP 建连、TLS、TTFB、HTTP 状态和成功率；菜单新增平均耗时与抖动统计。
- 菜单明确显示“时区权威出口 → 目标时区”和当前系统时区是否已经匹配。

### v4.4（2026-09-15）

- 完整体检遇到单次公网探测超时时保留上次有效分数，连续两次失败才发布低分，避免 98 分瞬间跌到 60 多分。
- 浏览器画像采集完成后只发布一次最终评分，不再把中间分数显示到菜单栏或触发假告警。
- 同一个出口 IP 的时区突然变化时连续确认两次才采用，避免情报接口误报导致洛杉矶/纽约来回切换。
- 「检查更新」增加菜单内进行中状态和 App 内成功/失败提示；本次联网失败不会再拿旧缓存冒充检查成功。
- 开机自启仍保留，但移除 LaunchAgent `KeepAlive`；用户点击「退出」后不会再被系统立即拉起。
- 安装和升级会清理旧 `com.hx10.checkclaude` 启动项及重复进程，避免多个实例同时检测。

两端使用同一套评分模型（26 项加权信号，合计 100）。完整体检会通过本机回环地址打开系统默认浏览器，
采集 WebRTC、Intl、Client Hints、HTTP 语言首标、WebGL、Canvas 和字体等真实浏览器信号；数据只回传给本机 CheckClaude。
浏览器桥接还会并行检查 `claude.ai`、Anthropic 官网和 API 的浏览器侧传输路径与耗时，用来发现浏览器扩展代理/PAC 与 shell 网络路径不一致；该结果是诊断信息，不把 `no-cors` 当作 HTTP 状态判断。
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
| `test-claude-check.sh` / `test-auto-timezone.sh` / `test-browser-report.sh` / `test-upgrade.sh` | macOS 评分、网络波动、完整报告页和更新流程自测（不联网） |
| `upgrade.sh` | 检查 GitHub Releases 新版本 + 一键升级；发现新版主动显示右下角提示，点击后在线安装并自动重启 |
| `windows/Program.cs` | Windows 版托盘、检测、修复和升级主逻辑 |
| `windows/BrowserBridge.cs` | Windows 真实浏览器指纹本地桥接 |
| `windows/BrowserBridgeTests.cs` | Windows 浏览器桥接自动测试 |
| `windows/build-remote.sh` / `windows/test-remote.sh` | 在 Mac 上远程构建并测试 Windows 产物 |
| `com.example.checkclaude-daemon.plist` | 系统守护进程：每 5 分钟 + 网络变化触发（root，改时区免密码） |
| `menubar/CheckClaude.app` | 菜单栏图标 App（开机自启，监控 + 告警 + 手动检测） |
| `menubar/*.plist` | 菜单栏 App 的开机自启 LaunchAgent |
| `install.sh` / `uninstall.sh` | 一键安装 / 卸载 |
| `status` / `last_state` / `network_history` / `*.log` | 运行快照 / 变化基线 / 24 小时分路趋势 / 日志 |

## 三路一致性检测（ip111 逻辑）

从三个不同目的地回显你的来源 IP：

| 视角 | 含义 | 接口（多路兜底） |
|---|---|---|
| 国内 | 访问国内网站时对方看到的 IP | 3322 / pconline / bilibili / ipip（均为 HTTPS） |
| 国外 | 访问未被封国外网站时的 IP | ipify / icanhazip / ipinfo |
| 谷歌/被封 | 访问谷歌等被封网站时的 IP | Cloudflare trace / ip.sb + Google 可达性 |

- 三者一致 → 干净的真实出口（🟢）。
- 三者都成功但结果不一致 → 出口 IP 有问题（🔴，疑似分流 / PAC / DNS 泄漏），连续两次确认后告警。
- 任一路临时超时 → 标记为网络检测波动，保留上次有效 IP；不会再产生 `IP → null → 原 IP` 的虚假变化。
- 网络恢复或出现新 IP 时，连续两次得到相同结果才正式提交，避免公共查询接口偶发失败造成状态乱跳。
- 四路质量检测全部走 HTTPS/TCP，记录 TCP 建连、TLS、TTFB、总耗时和 HTTP 状态，自动保留最近 24 小时并计算抖动。
- **时区始终以“谷歌/被封侧出口 IP”为权威**：出口变化独立连续确认两次，不受国内/国外辅助接口波动影响。
- 每轮会重新核对系统 IANA 时区；若被 macOS 定位服务或人工改动，会自动纠正回权威出口对应时区。

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
| 出口 | 多源情报一致 | 3 | 四家 IP 情报源针对同一出口的 ISO 国家码是否一致 |
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
| 浏览器 | WebRTC 出口 | 6 | **UDP 不走 HTTP 代理**；区分检测完成无候选、发现公网候选、超时、异常/禁用，避免把 STUN 失败误报成安全 |
| 浏览器 | 浏览器时区 | 3 | Intl 时区与系统时区是否一致 |
| 浏览器 | 浏览器语言 | 2 | `navigator.languages` 与出口地区是否矛盾 |
| 浏览器 | 渲染环境 | 2 | WebGL 渲染器 / Canvas 指纹 / 中文字体探测 |
| 浏览器 | **Intl 区域设置** | 1 | 浏览器国际化配置与出口地区是否对应 |
| 浏览器 | **Client Hints** | 2 | Chromium 上报的平台是否与真实系统一致 |
| 浏览器 | **HTTP 语言首标** | 1 | `Accept-Language` 是否与出口地区明显冲突 |

得分 ≥85 优秀 🟢，70–84 良好 🟡，50–69 风险 🟠，<50 高风险 🔴。

菜单栏/托盘里的「重新体检」会打开系统默认浏览器，通过只监听 `127.0.0.1` 的一次性本地桥接采集浏览器组信号。桥接同时核对 HTTP UA 与 JavaScript UA、UA-CH 平台/品牌、`Accept-Language` 与 `navigator.languages`，并显示 `Sec-Fetch` 请求上下文。

出口 IP 情报会并行查询 `ip-api`、`ipinfo`、`ipwho.is` 和 `api.ip.sb`。四家都针对同一个已确认出口 IP，国家统一为 ISO 两位代码后再比较；IPv4、IPv6 与 Cloudflare 边缘节点分开处理，避免把不同协议族或 CDN 中间节点误报成情报冲突。
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

自测均不联网：`bash test-claude-check.sh`、`bash test-auto-timezone.sh`、`bash test-browser-report.sh`、`bash test-upgrade.sh`

## 告警

- 出口 IP 连续两次确认发生变化 → 通知「出口 IP 变化 A → B」。
- 由一致变为不一致 → 通知「⚠️ 出口 IP 异常」；恢复一致 → 通知「出口已恢复正常」。
- 单次查询失败只显示「网络检测波动」并沿用上次有效结果，不把获取失败当成 IP 变化。
- 完整体检的单次网络失败只显示「复核中」并保留上次有效分数；连续两次失败才正式降分。
- 谷歌侧权威出口变化、同一出口 IP 的时区变化都需要连续两次确认，单次误报不会修改系统时区。
- 已确认出口不变时，每轮都核对系统时区；发现漂移会立即自动纠正。
- 检测进程带互斥锁，慢请求不会与下一轮并发覆盖状态。
- 仅在状态**真正变化**时提醒，不会每 5 分钟刷屏。

## 菜单栏图标

点击图标显示：三路 IP、Google 可达性、**时区权威出口 → IANA 时区**、当前系统时区及匹配状态、更新时间；
并提供「线路质量 / 立即检测 / 打开日志 / 退出」。质量子菜单包含最近 60 次四路趋势：

- 国内、国外、谷歌侧、Google 各占一行，可直接定位是哪一路失败。
- 折线表示总耗时，橙点表示该路失败，红线表示已确认的出口 IP 变化；鼠标悬停可查看每个时间点的四路延迟。
- 子菜单汇总最近 24 小时各路成功率、失败次数、平均 HTTPS 耗时、抖动、TCP、TLS、TTFB 和 HTTP 状态。

图标含义：🟢 一致　🟠 网络波动/复核中　🔴 异常　⚪️ 暂无数据。

手动点「重新体检」会激活系统默认浏览器并打开一份完整的本机报告；出口变化触发的后台体检仍不抢焦点。浏览器信号回传后，页面继续等待系统、出口、DNS 和 Claude 连通性检测，最终展示 26 项评分、40+ 原始证据及一致性矩阵。报告完成后倒计时 4 秒自动关闭，可点“保持打开”取消；报告只在当前 Mac 的 `127.0.0.1` 随机端口和一次性令牌之间传递，完整结果加载后 listener 会立即回收。

「检查更新」执行期间菜单会显示进行中状态；完成后由 CheckClaude 自己显示“已是最新版”、发现新版或联网失败，
不依赖系统通知权限。登录时仍会自动启动；主动点「退出」后保持退出，直到用户再次打开或下次登录。

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

1. 四路探测全部使用 HTTPS/TCP，三路回显来源 IP 判断一致性，Google 204 验证实际连通性。
2. “谷歌/被封侧”出口作为 Claude/Google 路径的时区权威；出口变化连续两次确认，和三路一致性状态独立。
3. 通过多个 HTTPS 情报源解析 IANA 时区（如 `America/Los_Angeles`），并将出口 IP 与时区成对提交。
4. 每轮读取 `/etc/localtime`；与权威时区不一致时，经 `/usr/share/zoneinfo` 校验后调用 `systemsetup -settimezone` 自动纠正。
5. 最近 24 小时记录成功率、TCP、TLS、TTFB、HTTPS 总耗时和抖动；IP 或一致性确认变化时才通知。

---

## 关于作者

这个工具是我自己每天在用的东西，顺手开源。我的主力产品是：

### 叮叮提醒 — 重要的事，我来帮你记着

吃药、还款、农历生日、纪念日倒数、考试倒计时——**说一句话就能创建**，到点通过微信、邮件、短信或电话送达。
微信小程序 / macOS / Windows 三端同步，**微信与邮件提醒终生免费**。

- 官网：<https://www.yinso.com>
- 微信小程序搜「**叮叮提醒**」，无需下载安装

---

## 致谢

感谢 [linux.do](https://linux.do/) —— 一个充满活力的技术社区，本项目也在这里分享和交流。
