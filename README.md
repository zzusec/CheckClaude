# auto-timezone

按 **ip111.cn 的逻辑做三路出口 IP 一致性检测**，并把 macOS 系统时区**自动设为"谷歌测试 IP"对应的时区**。
菜单栏常驻图标显示状态（✓绿=三路一致 / ✗红=异常）；出口 IP 变化或三路不一致时弹桌面告警。

适合经常切换 VPN / 代理出口的人：出口到哪个地区，系统时区就自动跟到哪；同时帮你发现分流 / DNS 泄漏导致的出口不一致。仅依赖系统自带工具（bash + Swift），无第三方运行时依赖。

## 快速开始

```bash
git clone https://github.com/zzusec/auto-timezone.git
cd auto-timezone
bash install.sh          # 构建并装到 /Applications + 开机自启，无需 sudo
```

首次打开若被 Gatekeeper 拦：右键 App → 打开。改时区时会弹一次系统授权框（密码 / Touch ID），属正常。

## 组成

| 文件 | 作用 |
|---|---|
| `auto-timezone.sh` | 引擎：三路检测 + 解析谷歌侧 IP 时区 + 自动改时区 + 变化告警 |
| `claude-check.sh` | Claude 运行环境体检：打分 + 问题清单 + 修复建议 + 自动修复 |
| `test-claude-check.sh` | 体检评分逻辑自测（不联网） |
| `com.hx10.auto-timezone.plist` | 系统守护进程：每 5 分钟 + 网络变化触发（root，改时区免密码） |
| `menubar/AutoTimezone.app` | 菜单栏图标 App（开机自启，监控 + 告警 + 手动检测） |
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

## Claude 运行环境体检（v1.3）

判断当前环境是否适合运行 Claude / Claude Code：打分 + 问题清单 + 修复建议 + 自动修复。
评分模型参考 [check-cc](https://github.com/yacuo/check-cc) 的多信号加权思路，改为 macOS 本地实现，
复用上面已经拿到的三路出口数据，不额外依赖 Node。

```bash
~/auto-timezone/claude-check.sh              # 体检并打印报告
~/auto-timezone/claude-check.sh --fix        # 顺带自动修可安全修复项（时区）
~/auto-timezone/claude-check.sh --fix-locale # 额外把系统「区域」改成出口国家
```

共 **14 项加权信号**，合计 100 分：

| 组 | 信号 | 权重 | 说明 |
|---|---|---|---|
| 出口 | 出口国家 | 22 | 是否落在 Anthropic 不服务地区（CN/HK/RU/IR…） |
| 出口 | Anthropic API 可达 | 13 | 返回 401 为正常（未带密钥）；403 = 出口被地区拦截 |
| 出口 | claude.ai 可达 | 7 | 测 `robots.txt`——主页对裸 curl 一律 403，那是 bot 挑战不是地区拦截 |
| 出口 | 多源情报一致 | 3 | 两家 IP 情报库对该出口判定是否冲突 |
| 质量 | IP 类型 | 8 | 住宅 / 机房 IDC / 公开代理，风控强度不同 |
| 质量 | 边缘机房匹配 | 4 | Cloudflare 实际落地机房与 IP 库归属是否一致（比 IP 库更难伪造） |
| 质量 | 出口链路单一 | 3 | CF 看到的来源 IP ≠ 检测到的出口 = 链路上还有一层代理 |
| 画像 | 三路出口一致 | 8 | 分流 / PAC 会让账号画像在多地区间跳变 |
| 画像 | 系统时区匹配出口 | 7 | 典型矛盾信号，**可一键修复** |
| 画像 | 时区偏移自洽 | 2 | UTC 偏移与时区名冲突 = 被 `TZ` 环境变量覆盖过 |
| 画像 | 系统区域匹配出口 | 5 | 系统区域与出口地区矛盾（网页端登录时暴露） |
| 画像 | 代理形态 | 3 | TUN 全局 / 系统代理 / **PAC 分流**（分流扣分最重） |
| DNS | claude.ai 解析 | 9 | 正常（Cloudflare / Anthropic 自有段）/ fake-ip 接管 / 被污染 |
| DNS | DNS 出口 | 6 | 用国内公共 DNS = 查询泄漏到国内，与国外出口矛盾 |

得分 ≥85 优秀 🟢，70–84 良好 🟡，50–69 风险 🟠，<50 高风险 🔴。
操作系统、ASN、边缘机房、Claude CLI 版本与接口地址（官方 / 中转）作为信息项展示不计分；
已配中转时，API 直连不通不会按满额扣分。

**未覆盖的信号**：WebRTC 泄漏、Client Hints、Sec-Fetch、Emoji 渲染风格、字体探测、
Canvas/WebGL 指纹——这些只存在于浏览器 JS 环境，shell 拿不到，本工具不做假数据。
它们影响的是 claude.ai **网页端**画像；Claude Code（CLI）不跑浏览器，不受这些信号影响。

菜单栏「Claude 环境 🟢 92 分」子菜单里可查看全部明细、问题与建议，并直接点「一键修复」。
体检**只在出口 IP 变化或手动点击时触发**，不会每分钟去敲 Anthropic 接口。

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
bash ~/auto-timezone/build_dmg.sh   # 生成 AutoTimezone.dmg
```

App 自包含:检测脚本打包在 `AutoTimezone.app/Contents/Resources/`，数据写入
`~/Library/Application Support/AutoTimezone`，改时区时弹一次系统授权框 —— 不依赖
root 守护进程，拷到任何 Mac 都能用。挂载 dmg 后把 App 拖进 Applications 即可，
首次右键→打开绕过未签名提示。开机自启在「系统设置→通用→登录项」添加。

## 安装(本机，含 root 守护进程方案)

```bash
bash ~/auto-timezone/install.sh    # 不要加 sudo；脚本内部会在装守护进程时索要一次密码
```

安装内容：① 编译菜单栏 App　② 加载 root 守护进程（自动改时区 + 告警）　③ 菜单栏 App 设为开机自启。

> 建议在「系统设置 → 日期与时间」里**关闭"自动设置时区"**，否则系统定位会与本工具冲突。

## 卸载

```bash
bash ~/auto-timezone/uninstall.sh
```

## 手动用法

```bash
~/auto-timezone/auto-timezone.sh --check     # 只检测三路一致性并打印，不改时区
~/auto-timezone/auto-timezone.sh --dry-run   # 检测 + 显示将改的时区，不实际改
~/auto-timezone/auto-timezone.sh             # 检测 + 按谷歌侧 IP 自动改时区（需 sudo）
```

## 工作原理

1. 三路视角回显来源 IP，判断一致性（不一致即告警）。
2. 取"谷歌/被封侧"出口 IP，用 `ipinfo.io` 解析成 IANA 时区（如 `Asia/Shanghai`）。
3. 读 `/etc/localtime` 软链得当前时区（无需 sudo），相同则跳过。
4. `/usr/share/zoneinfo/<tz>` 校验合法后，`systemsetup -settimezone` 写入。
5. 与上次状态对比，IP 变化或一致性翻转则弹桌面通知。
