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

$zip = "$here\CheckClaude-win.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip -Force
Write-Output ("OK version=" + $Version + " size=" + [math]::Round((Get-Item $out).Length/1KB) + "KB")
