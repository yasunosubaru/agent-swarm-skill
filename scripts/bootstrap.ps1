# ============================================================
#  克隆 agent-swarm-desktop 并运行安装向导
#
#    powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1
#
#  参数：
#    -Dir <路径>       克隆到哪（默认 .\agent-swarm-desktop）
#    -Repo <git url>   换源用
#    -SkipSetup        只克隆，不跑 setup.ps1
#    其余参数原样透传给 setup.ps1（-NonInteractive / -SwarmSrc / -Harness ...）
# ============================================================
param(
    [string]$Repo = "https://github.com/yasunosubaru/agent-swarm-desktop.git",
    [string]$Dir = "",
    [switch]$SkipSetup,
    [Parameter(ValueFromRemainingArguments = $true)]
    $Rest
)

$ErrorActionPreference = "Stop"
$skillRoot = Split-Path $PSScriptRoot -Parent
if (-not $Dir) { $Dir = Join-Path (Get-Location) "agent-swarm-desktop" }

if (Test-Path $Dir) {
    Write-Host "目标目录已存在：$Dir" -ForegroundColor Yellow
    Write-Host "要重新拉取请先删掉它，或用 -Dir 指定别的路径。" -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "找不到 git。请先安装 Git for Windows：https://git-scm.com/download/win" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "克隆 $Repo" -ForegroundColor Cyan
Write-Host "    -> $Dir" -ForegroundColor DarkGray
& git clone --depth 1 $Repo $Dir
if ($LASTEXITCODE -ne 0) {
    Write-Host "克隆失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
    exit 1
}

$setup = Join-Path $Dir "setup.ps1"
if (-not (Test-Path $setup)) {
    Write-Host "仓库里没有 setup.ps1，克隆可能不完整。" -ForegroundColor Red
    exit 1
}

if ($SkipSetup) {
    Write-Host ""
    Write-Host "已跳过安装。下一步手动运行：" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$setup`"" -ForegroundColor DarkGray
    exit 0
}

Write-Host ""
Write-Host "运行安装向导……" -ForegroundColor Cyan
$args2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $setup)
if ($Rest) { $args2 += @($Rest) }
& powershell.exe @args2
exit $LASTEXITCODE
