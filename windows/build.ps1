param([string]$Version = "2.1")
# 用 Windows 自带的 csc.exe 编译，产物是单个 exe，目标机不需要装任何运行时。
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found" }

# 版本号写进程序集，Application.ProductVersion 要用它做升级比较
@"
using System.Reflection;
[assembly: AssemblyTitle("CheckClaude")]
[assembly: AssemblyProduct("CheckClaude")]
[assembly: AssemblyCompany("yinso.com")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: AssemblyInformationalVersion("$Version")]
"@ | Set-Content -Path "$here\AssemblyInfo.cs" -Encoding UTF8

$refs = @("System.dll","System.Core.dll","System.Drawing.dll","System.Windows.Forms.dll") -join ","
$out  = "$here\CheckClaude.exe"
& $csc /nologo /target:winexe /optimize+ /platform:anycpu /out:"$out" /reference:$refs `
       /warn:1 "$here\Program.cs" "$here\AssemblyInfo.cs"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

# zip 里附一份说明，和 macOS dmg 里的使用说明.txt 对应
$readme = "$here\使用说明.txt"
@"
CheckClaude for Windows

用法: 双击 CheckClaude.exe，图标出现在右下角托盘区。
      右键托盘图标查看 20 项检测明细、问题和提分建议。

首次运行如果 SmartScreen 拦截("Windows 已保护你的电脑")，
点「更多信息」→「仍要运行」。程序未做代码签名，这是预期提示。

命令行:
  CheckClaude.exe --check     打印完整体检报告(不启动托盘)
  CheckClaude.exe --version   打印版本号

开机自启: 右键托盘图标 → 勾选「开机自启」。

一键修复会改系统时区 / DNS / 代理设置，需要管理员权限，
会弹一次 UAC 授权框。DNS 修改前会先验证候选 DNS 能正确
解析 claude.ai(没被投毒)，原设置可用 netsh 还原。

数据只写在本机 %APPDATA%\CheckClaude，不上传任何内容。

────────────────────────────────
本公司其他产品: 叮叮提醒 https://www.yinso.com
微信小程序搜「叮叮提醒」—— 吃药/还款/农历生日/纪念日倒数,
说一句话就能创建,到点经微信、邮件、短信或电话送达。
"@ | Set-Content -Path $readme -Encoding UTF8

$zip = "$here\CheckClaude-win.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path @($out, $readme) -DestinationPath $zip -Force
Write-Output ("OK version=" + $Version + " size=" + [math]::Round((Get-Item $out).Length/1KB) + "KB")
