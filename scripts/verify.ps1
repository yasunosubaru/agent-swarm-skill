# ============================================================
#  Agent Swarm Desktop —— 端到端自检
#
#    powershell -ExecutionPolicy Bypass -File .\verify.ps1
#    powershell -File .\verify.ps1 -SkipTask     # 只查服务，不发真实任务
#
#  退出码：0 = 全部通过；1 = 有项目失败
# ============================================================
param([switch]$SkipTask)

$ErrorActionPreference = "Continue"
$repoRoot = $PSScriptRoot
$cfgFile = Join-Path $repoRoot "config.json"
if (-not (Test-Path $cfgFile)) {
    Write-Host "找不到 config.json，请先运行 setup.ps1" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
$apiPort = if ($cfg.apiPort) { [int]$cfg.apiPort } else { 3013 }

function Get-Key {
    $envFile = Join-Path $cfg.swarmRoot ".env"
    if (-not (Test-Path $envFile)) { return "" }
    $l = Get-Content $envFile -Encoding UTF8 | Where-Object { $_ -match '^API_KEY=' } | Select-Object -First 1
    if ($l) { return ($l -replace '^API_KEY=', '').Trim() }
    return ""
}

# ---------- 1) 服务层 ----------
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "gui\swarm-ctl.ps1") -Action verify
$out | ForEach-Object { Write-Host $_ }
$serviceOk = ($out -contains "VERIFY_OK")

# ---------- 2) 真实任务往返 ----------
$taskOk = $true
if (-not $SkipTask) {
    Write-Host ""
    Write-Host "[6] 真实任务往返（会真的调用一次模型）" -ForegroundColor Cyan
    $key = Get-Key
    if (-not $key) {
        Write-Host "    !! 读不到 API Key" -ForegroundColor Yellow
        $taskOk = $false
    }
    else {
        try {
            # 注意：PowerShell 5.1 的 Invoke-RestMethod 默认按 ISO-8859-1 发送，
            # 中文会被替换成 "?"。必须显式传 UTF-8 字节。
            $prompt = "自检消息：请只回复这六个字符 VERIFY_OK"
            $json = (@{ task = $prompt; source = "api" } | ConvertTo-Json -Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $task = Invoke-RestMethod -Method POST -Uri "http://localhost:$apiPort/api/tasks" `
                -Headers @{ Authorization = "Bearer $key" } `
                -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 30

            Write-Host "    任务已创建：$($task.id)"
            $final = $null
            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep 3
                $t = Invoke-RestMethod -Uri "http://localhost:$apiPort/api/tasks/$($task.id)" `
                    -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
                Write-Host ("    ... {0} ({1}s)" -f $t.status, (($i + 1) * 3)) -ForegroundColor DarkGray
                if ($t.status -in @("completed", "failed", "cancelled", "canceled")) { $final = $t; break }
            }
            if (-not $final) { Write-Host "    !! 超时未完成" -ForegroundColor Yellow; $taskOk = $false }
            elseif ($final.status -ne "completed") { Write-Host "    !! 任务 $($final.status)" -ForegroundColor Yellow; $taskOk = $false }
            else {
                $reply = $final.output
                if (-not $reply) {
                    # 纯文本回复时 output 可能为空，从 session 日志里取最后一段文本
                    try {
                        $logs = Invoke-RestMethod -Uri "http://localhost:$apiPort/api/tasks/$($final.id)/session-logs" `
                            -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
                        $arr = if ($logs.logs) { $logs.logs } elseif ($logs -is [array]) { $logs } else { @() }
                        $parts = @{}
                        $i2 = 0
                        foreach ($e in $arr) {
                            $i2++
                            $ty = [string]$e.type; $p = $e.properties
                            if ($ty -like "*part.delta*" -and $p.field -eq "text" -and $p.delta) {
                                $k = [string]$p.partID
                                if (-not $parts.ContainsKey($k)) { $parts[$k] = @{ text = ""; idx = 0 } }
                                $parts[$k].text += [string]$p.delta
                                $parts[$k].idx = $i2
                            }
                        }
                        $best = ""; $bestIdx = -1
                        foreach ($v in $parts.Values) {
                            if ($v.text.Trim() -and $v.idx -gt $bestIdx) { $bestIdx = $v.idx; $best = $v.text.Trim() }
                        }
                        $reply = $best
                    }
                    catch { }
                }
                if ($reply -match "VERIFY_OK") {
                    Write-Host "    OK  收到回复：$($reply.Trim())" -ForegroundColor DarkGray
                }
                else {
                    Write-Host "    !! 回复不符合预期：[$($reply.Trim())]" -ForegroundColor Yellow
                    $taskOk = $false
                }
            }
        }
        catch {
            Write-Host "    !! 异常：$($_.Exception.Message)" -ForegroundColor Yellow
            $taskOk = $false
        }
    }
}

Write-Host ""
if ($serviceOk -and $taskOk) {
    Write-Host "全部通过 ✔" -ForegroundColor Green
    exit 0
}
Write-Host "存在未通过项 ✘" -ForegroundColor Yellow
exit 1
