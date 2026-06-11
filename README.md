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
