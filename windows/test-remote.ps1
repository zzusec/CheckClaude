$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found" }

$out = "$here\BrowserBridgeTests.exe"
& $csc /nologo /target:exe /optimize+ /platform:anycpu /out:"$out" `
       /reference:System.dll,System.Core.dll `
       /main:CheckClaude.BrowserBridgeTests `
       "$here\Program.cs" "$here\BrowserBridge.cs" "$here\BrowserBridgeTests.cs"
if ($LASTEXITCODE -ne 0) { throw "test compile failed" }

$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
if (Test-Path $edge) { $env:CHECKCLAUDE_TEST_BROWSER = $edge }

& $out
if ($LASTEXITCODE -ne 0) { throw "tests failed" }
