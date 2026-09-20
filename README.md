# CheckClaude

**English** · [简体中文](README.zh-CN.md)

Find out whether this machine is a safe place to run Claude / Claude Code — and auto-fix what can be fixed.

A menu bar / tray app that scores your environment on **26 weighted signals** (0–100), tells you
what is wrong, how many points each issue costs, and what to do next. System timezone, system
region, DNS leaks and PAC split-routing are repaired with one click. Same scoring model on
macOS, Windows and Linux.

Built entirely on OS-native capabilities: no third-party runtime, no account, no data leaves your machine.

```
Claude environment  98 · Excellent
   This machine is suitable for running Claude
   -- 2 points still available --
      +2  Exit stability: stay on one node, no route switching for 24h
   -- Exit --
   OK  Exit country: US Los Angeles         14/14
   OK  Anthropic API reachable: HTTP 401    10/10
   ...
```

> **Note**: the app's interface is currently Simplified Chinese only. Sample output and menu
> names in this README are translated; menu items are identified by their position.

> **Disclaimer**: the score reflects contradictions in your local environment fingerprint only.
> It is not an official Anthropic verdict and is not a guarantee of account safety.
> CheckClaude never reads or modifies Claude account credentials.

## Download

| Platform | Download | Requirements |
|---|---|---|
| macOS | [CheckClaude.dmg](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude.dmg) | macOS 12+, universal binary (Apple Silicon + Intel) |
| Windows | [CheckClaude-win.zip](https://github.com/zzusec/CheckClaude/releases/latest/download/CheckClaude-win.zip) | Windows 10/11, unzip and run, no runtime to install |
| Linux | [checkclaude-amd64.deb](https://github.com/zzusec/CheckClaude/releases/latest/download/checkclaude-amd64.deb) · [tar.gz](https://github.com/zzusec/CheckClaude/releases/latest/download/checkclaude-linux-amd64.tar.gz) | Debian / Ubuntu amd64, static CLI + GTK tray |

None of the builds are code-signed, so the first launch is blocked on every platform.

**macOS** — drag into `Applications`. Since macOS 15 Apple removed the "right-click → Open"
bypass, so use either:

```bash
xattr -dr com.apple.quarantine /Applications/CheckClaude.app
```

or let it be blocked once, then go to **System Settings → Privacy & Security → Security → "Open Anyway"**.

**Windows** — when SmartScreen blocks it, click "More info" → "Run anyway". The tray context menu
has an autostart toggle (writes an `HKCU` Run entry, no admin needed).

**Linux** — `sudo dpkg -i checkclaude-amd64.deb`, then `sudo apt -f install` if dependencies are
missing. The CLI alone runs fine on a server; the `.deb` also installs the tray and registers autostart.

## Command line

**macOS**

```bash
~/CheckClaude/claude-check.sh               # full report
~/CheckClaude/claude-check.sh --fix         # apply the safely reversible fixes
~/CheckClaude/claude-check.sh --fix-locale  # also set system region to the exit country
~/CheckClaude/auto-timezone.sh --check      # three-path consistency only, no timezone change
~/CheckClaude/auto-timezone.sh --dry-run    # show the timezone it would set, change nothing
```

**Windows**

```
CheckClaude.exe --check     # print the full report, do not start the tray
CheckClaude.exe --version
```

**Linux**

```bash
checkclaude --check         # full report
checkclaude --json          # machine-readable JSON
checkclaude --browser       # open the default browser, collect real fingerprints, render an HTML report
checkclaude --fix           # apply the safely reversible fixes (timezone / GNOME PAC)
checkclaude --fix-locale    # write a user-level region-format override, display language untouched
checkclaude --tray-status   # single-line TSV for the tray
```

Run from a terminal there is no browser context, so the 7 browser signals are scored neutrally
rather than pretending they were measured.

## Scoring model

26 weighted signals, 100 points total, in 6 groups.

| Group | Signal | Weight | What it checks |
|---|---|---|---|
| Exit | Exit country | 14 | Whether you land in a region Anthropic does not serve (CN / HK / RU / IR…) |
| Exit | Anthropic API reachable | 10 | 401 is healthy; 403 means the exit is region-blocked |
| Exit | IPv6 exit | 3 | When the proxy only covers IPv4, a direct IPv6 route leaks your real region |
| Exit | Intel sources agree | 3 | Whether four IP intelligence providers return the same ISO country code |
| Exit | claude.ai reachable | 2 | Probes `robots.txt`; the homepage 403s any bare curl — that is the bot challenge |
| Exit | anthropic.com reachable | 2 | Site and API sit behind different frontends; testing both separates a full block from a single-point failure |
| Quality | IP type | 4 | Residential / datacenter / public proxy |
| Quality | Edge colo match | 3 | Whether the Cloudflare colo matches the IP database's placement |
| Quality | Single exit hop | 3 | CF-observed source ≠ detected exit means nested proxies |
| Profile | Three paths agree | 6 | Split routing / PAC makes your profile jump between regions |
| Profile | Timezone matches exit | 5 | The classic contradiction — **one-click fixable** |
| Profile | Region matches exit | 4 | System region setting contradicts the exit region — **one-click fixable** |
| Profile | Script variant consistent | 2 | Simplified vs Traditional against the exit region (Traditional → TW / HK / MO) |
| Profile | Timezone offset coherent | 2 | UTC offset conflicting with the zone name means `TZ` was overridden |
| DNS | claude.ai resolution | 6 | Clean / fake-ip takeover / poisoned |
| DNS | DNS exit | 4 | A Chinese public resolver means query leakage — **one-click fixable** |
| Stability | Exit stability | 4 | Exit IP changes in the last 24h (read from local logs — a web page cannot do this) |
| Stability | Proxy shape | 3 | TUN global / system proxy / PAC split — **PAC is one-click fixable** |
| Stability | Container | 3 | Bare metal or virtual machine |
| Browser | WebRTC exit | 6 | UDP bypasses the HTTP proxy and can expose the exit your proxy failed to cover |
| Browser | Browser timezone | 3 | `Intl` timezone against the system timezone |
| Browser | Browser language | 2 | `navigator.languages` against the exit region |
| Browser | Render environment | 2 | WebGL renderer / Canvas fingerprint / CJK font probe |
| Browser | Client Hints | 2 | Whether the platform Chromium reports matches the real system |
| Browser | Intl locale | 1 | Browser internationalization settings against the exit region |
| Browser | Accept-Language | 1 | Whether the request header contradicts the exit region |

### Grades

Grades are deliberately binary: **only the green tier says "usable"; every other tier says
"not recommended" in plain words.**

| Grade | Condition |
|---|---|
| Excellent | ≥ 90 points **and** all 6 critical signals at full marks — the only tier reported as "suitable for running Claude" |
| Split routing | The three exit paths disagree (split routing), regardless of total score |
| Risky | ≥ 70 points |
| High risk | ≥ 50 points, or the exit lands in a region Anthropic does not serve |
| Dangerous | < 50 points |

**Critical signals override the total.** Exit country, Anthropic API reachable, timezone matches
exit, WebRTC exit, IPv6 exit and three-paths-agree: if any one of them is below full marks, no
score gets you into the green tier. Two environments can both sit at 90 — one lost 10 points of
minor items, the other leaked its real exit through WebRTC (6) plus a timezone mismatch (5).
The risk is not comparable.

A three-path disagreement is downgraded on its own: an account profile flickering between
regions is one of the signals risk engines weigh most, and scoring it as a mere 6-point deduction
would let an 80-something environment render as usable next to a red icon.

The weighting approach follows [check-cc](https://github.com/yacuo/check-cc); each platform here
implements it locally.

## How it works

### Three-path exit consistency

Your source IP is echoed back from three different destinations:

| Path | Meaning | Endpoints (with fallbacks) |
|---|---|---|
| Domestic | What a Chinese site sees | 3322 / pconline / bilibili / ipip (all HTTPS) |
| International | What an unblocked foreign site sees | ipify / icanhazip / ipinfo |
| Google / blocked | What Google-class blocked sites see | Cloudflare trace / ip.sb + Google reachability |

All three matching means a clean, genuine exit. All three succeeding with different answers is
split routing, PAC or a DNS leak, and alerts after two consecutive confirmations. A path that
times out is marked as network jitter and the previous valid result is kept, so a single failed
query is never counted as an IP change. The system timezone always follows the
**Google-path exit IP**.

Line quality is measured over HTTPS on TCP rather than ICMP: the last 24 hours of total latency,
TCP connect, TLS handshake, TTFB, HTTP status and success rate are kept per path.

### Browser fingerprint collection

A full scan opens your default browser against a one-shot local bridge bound to `127.0.0.1` and
collects WebRTC, `Intl`, Client Hints, `Accept-Language`, WebGL, Canvas and CJK font signals —
the exact set claude.ai actually sees when you log in from the web. The URL carries a random
token, results are written to a local `browser_signals` file, and the listener closes the moment
collection finishes or times out. Nothing passes through an external server.

The bridge also cross-checks the HTTP UA against the JavaScript UA, UA-CH platform and brands,
and `Accept-Language` against `navigator.languages`, and probes the browser-side transport path
and latency to `claude.ai`, the Anthropic site and the API — useful for spotting a browser
extension proxy or PAC that disagrees with the shell's network path. That last part is diagnostic
only; a `no-cors` response is never treated as an HTTP status.

> **After changing browser settings, use the re-scan entry** — the first action item in the
> menu, right under the score. It is the only entry point that reopens the browser.
> The quick-check entry further down (below the separator) only re-probes the exit and reuses
> the browser result from the last hour, so clicking it after a browser change does nothing.
> The Windows tray shows a browser-profile line telling you **which browser collected the data
> and how many minutes ago**. Collection always goes through the **system default browser** —
> if that is not the one you changed, your change will not show up in the score.

On macOS a failed hand-off falls back to an embedded WKWebView. Windows and Linux keep a valid
result for one hour, after which the browser signals are scored neutrally.

### IP intelligence cross-check

Exit IP intelligence is queried in parallel from `ip-api`, `ipinfo`, `ipwho.is` and `api.ip.sb`.
All four are asked about the same confirmed exit IP and normalized to ISO two-letter codes before
comparison. IPv4, IPv6 and Cloudflare edge nodes are handled separately, so a different address
family or a CDN intermediate is never reported as an intelligence conflict. When the sources
disagree, or the exit sits in an unsupported region, the system region is never changed automatically.

## One-click fixes

| Problem | How it is fixed |
|---|---|
| Timezone does not match exit | Fully automatic |
| PAC split routing | Turned off automatically |
| DNS leak / poisoning | Switched to an offshore resolver — each candidate is **verified** to resolve `claude.ai` correctly before being written, and the original value is backed up |
| System region does not match exit | Automatic for confirmed supported exits; the display language is never touched |
| Browser language | Manual, with the exact settings path for your browser |
| Change node / residential IP / pin a route | Manual only; the report spells out what to do |

DNS repair first resolves `claude.ai` through `1.1.1.1 / 8.8.8.8 / 9.9.9.9` and only writes a
resolver that returns a genuine Anthropic or Cloudflare address. The original value is stored in
`dns_backup` and one command undoes it. Only when all three are poisoned does it fall back to a
DoH profile.

> macOS implements DNS Settings as a Network Extension, so installing a DoH profile fails with
> `The VPN service could not be created` while a TUN-mode proxy such as FlClash, Surge or
> Clash Verge is running — you have to quit the proxy app first. That is why the DoH profile is
> not the preferred path.

Privilege escalation per platform:

- **macOS** — `sudo bash enable-auto-timezone.sh` grants NOPASSWD for `systemsetup` / `networksetup`; without it, changing the timezone prompts for authorization once.
- **Windows** — one UAC prompt when changing the system timezone or DNS.
- **Linux** — root writes directly, desktop users go through `pkexec`, and with neither available it just prints the manual command. The Linux build never rewrites `/etc/resolv.conf`, NetworkManager, IPv6, the display language or browser configuration.

## Codex anti-degradation (macOS)

Every Codex request carries an `x-codex-turn-state` header saying which state this turn resumes
from. A fresh session has none, so it starts cold every time. CheckClaude runs a reverse proxy
bound to `127.0.0.1` that reuses a still-valid state across sessions:

```
codex ──► 127.0.0.1:8788/backend-api ──► chatgpt.com/backend-api
             collect / validate / inject state
```

- **On by default, running in the background** — no checkbox; the menu bar shows a single status line. Disable with `codex-guard.sh --disable`.
- Engages only when codex uses the official ChatGPT login; if `model_provider` points at a third-party relay it steps aside, because injecting means nothing upstream.
- Integration writes `chatgpt_base_url` at the top of `~/.codex/config.toml`; the original is backed up as `config.toml.checkclaude-backup` and restored line by line on disable or uninstall.
- State is validated structurally (leading `0x80`, 10 blocks, issue time within the validity window) before caching, lives only in the proxy's memory, and only a fingerprint plus counters are ever written to disk.
- The proxy is kept alive by a LaunchAgent, so quitting or crashing the app never breaks codex; if it fails to start, the config is rolled back automatically.
- Near expiry it renews with one probe using the previous request's credentials, backing off on failure. Real requests are never replayed.

This only keeps request parameters consistent. It does **not** guarantee model quality, account
quota or server-side routing. The 292/10-block rule is empirical, not a published spec.

## Alerts and monitoring

A background timer (1 minute by default) only runs the lightweight three-path probe. The full
scan runs on first launch, on an exit state change, or when you trigger it — it never hammers
Anthropic's endpoints every minute.

- Exit IP change confirmed twice in a row -> notification "exit IP changed: A -> B"
- Consistent turning inconsistent -> "exit IP anomaly"; recovery -> "exit back to normal"
- A single failed query is reported as probe jitter and reuses the last valid result
- The probe holds a mutex, so a slow request never races the next round into stale state
- Notifications fire **only on real state changes**

Icon: 🟢 consistent · 🟠 jitter / re-checking · 🔴 anomaly · ⚪️ no data yet.
The macOS network chart plots the last 60 rounds of latency across all four paths — domestic,
international, Google path and Google reachability on one row each, with the line showing
latency, an amber dot marking a failed fetch and a red line marking a confirmed exit IP change.
Hovering shows the exact latencies at that point in time, and the submenu summarizes 24-hour
success rate, failure count, mean latency and IP-change count per path.

## Build from source

**macOS**

```bash
git clone https://github.com/zzusec/CheckClaude.git
cd CheckClaude
bash install.sh          # build, install to /Applications, register login item — no sudo
bash build_dmg.sh        # produce a distributable CheckClaude.dmg
bash uninstall.sh
```

`install.sh` compiles the menu bar app, loads the root daemon (automatic timezone + alerts) and
registers the login item. The app is self-contained: detection scripts ship inside
`CheckClaude.app/Contents/Resources/` and data goes to `~/Library/Application Support/CheckClaude`.

> Turn **off "Set time zone automatically"** in System Settings → General → Date & Time,
> otherwise macOS location services will fight this tool.

**Windows** — .NET Framework 4.8 (shipped with Windows 10/11) compiled by `csc.exe` into a single
exe. It can be built and tested remotely from a Mac:

```bash
WIN_HOST=win-ding bash windows/build-remote.sh 4.18
WIN_HOST=win-ding bash windows/test-remote.sh
```

**Linux** — a pure-Go static binary (CLI, no GTK dependency) plus a GTK3 + Ayatana AppIndicator tray.

```bash
LINUX_HOST=root@your-build-box bash linux/build-remote.sh
```

**Tests** (all offline):

```bash
bash test-claude-check.sh     # scoring model
bash test-auto-timezone.sh    # network-jitter state machine
bash test-browser-report.sh   # full browser report page
bash test-upgrade.sh          # upgrade flow
bash test-codex-guard.sh      # codex proxy, against a fake local upstream
cd linux && go test ./...     # Linux policy engine
bash windows/test-remote.sh   # Windows bridge, incl. a real-Edge end-to-end run
```

## Project layout

| Path | Role |
|---|---|
| `claude-check.sh` | macOS scoring engine: 26 weighted signals, issue list, recommendations, auto-fix |
| `auto-timezone.sh` | macOS three-path detection, Google-path timezone resolution, timezone repair, change alerts |
| `codex-guard.sh` · `menubar/CodexGuard.swift` | Codex anti-degradation: local reverse proxy, `x-codex-turn-state` cache and injection |
| `menubar/StatusApp.swift` · `menubar/build.sh` | macOS menu bar app and its build script |
| `windows/Program.cs` | Windows tray, detection, repair and upgrade logic |
| `windows/BrowserBridge.cs` | Windows local bridge for real browser fingerprints |
| `linux/cmd/` · `linux/internal/` | Linux CLI and GTK tray |
| `install.sh` · `uninstall.sh` · `upgrade.sh` | Install / uninstall / check GitHub Releases and upgrade in place |
| `com.example.checkclaude-daemon.plist` | macOS daemon: every 5 minutes plus network-change triggers |

## License

[MIT](LICENSE)

## About

This is a tool I use every day and decided to open source. My main product is **DingDing
Reminder** — medication, repayments, lunar birthdays, anniversary countdowns, exam timers:
create one by saying a single sentence and get it delivered by WeChat, email, SMS or a phone
call. Synced across a WeChat Mini Program, macOS and Windows; WeChat and email reminders are
free for life. <https://www.yinso.com>

Thanks to [linux.do](https://linux.do/), a genuinely lively technical community where this
project is also shared and discussed.
