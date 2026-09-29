# ============================================================
#  把 agent-swarm 接到 OpenCode（用户 MCP）
#
#    powershell -ExecutionPolicy Bypass -File .\mcp\connect-opencode.ps1
#
#  做什么：
#    1. 找到（或创建）本地 Swarm 用户
#    2. 铸造一个 aswt_ 开头的 MCP token
#    3. 把 agent-swarm 写进 OpenCode 的 opencode.jsonc（type: remote）
#    4. 验证 /mcp-user 的 initialize + tools/list 握手
#
#  可重复执行：会换掉旧 token，并替换配置里已有的 agent-swarm 段。
#  加 -ShowToken 可把 token 全文打到屏幕上（默认只显示前 9 位）。
# ============================================================
param(
    [string]$OpencodeConfig = "$env:USERPROFILE\.config\opencode\opencode.jsonc",
    [string]$UserName = "SunCh",
    [string]$ApiUrl = "http://localhost:3013",
    [string]$ServerName = "agent-swarm",
    [switch]$ShowToken
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

# 注意：颜色是【位置参数】，必须 Say "文字" "颜色"，写成 -Color 会被 $args 吞掉（静默失效）
function Say([string]$m, [string]$c = "Gray") { Write-Host $m -ForegroundColor $c }
function Die([string]$m) { Write-Host ""; Say "错误：$m" "Red"; exit 1 }

# ---------------------------------------------------------------- 0 前置
$envFile = Join-Path $root "deploy\.env"
$apiKey = ""
if (Test-Path $envFile) {
    $apiKey = ((Get-Content $envFile -Encoding UTF8 |
        Where-Object { $_ -match '^API_KEY=' } | Select-Object -First 1) -replace '^API_KEY=', '').Trim()
}
if (-not $apiKey) { Die "读不到 API_KEY（$envFile），请先完成 setup.ps1" }

try {
    $health = Invoke-RestMethod "$ApiUrl/health" -TimeoutSec 5
}
catch { Die "API 没起来（$ApiUrl）。请先双击桌面「Agent Swarm 对话」图标，等状态灯变绿再运行本脚本。" }
Say "API 在线：v$($health.version)" "DarkGray"

$hdr = @{ Authorization = "Bearer $apiKey" }
$hdrJson = $hdr + @{ "Content-Type" = "application/json" }

# ---------------------------------------------------------------- 1 用户
Say ""
Say "[1/4] 准备 Swarm 用户" "Cyan"
$users = @((Invoke-RestMethod "$ApiUrl/api/users" -Headers $hdr -TimeoutSec 20).users)
$target = $users | Where-Object { $_.name -eq $UserName -and $_.status -eq 'active' } | Select-Object -First 1
if (-not $target) {
    $body = @{ name = $UserName; role = "admin"; status = "active" } | ConvertTo-Json -Compress
    $created = Invoke-RestMethod -Method POST "$ApiUrl/api/users" -Headers $hdrJson -Body $body -TimeoutSec 20
    $target = $created.user
    Say "    已创建用户 $($target.id)" "DarkGray"
}
else {
    Say "    复用用户 $($target.id)" "DarkGray"
}
if (-not $target.id) { Die "用户创建失败" }

# ---------------------------------------------------------------- 2 token
Say "[2/4] 铸造 MCP token（aswt_）" "Cyan"
$tok = Invoke-RestMethod -Method POST "$ApiUrl/api/users/$($target.id)/mcp-tokens" -Headers $hdrJson `
    -Body (@{ label = "opencode-mcp" } | ConvertTo-Json -Compress) -TimeoutSec 20
$token = [string]$tok.plaintext
if (-not $token) {
    $token = [regex]::Match(($tok | ConvertTo-Json -Depth 5 -Compress), 'aswt_[A-Za-z0-9_\.\-]+').Value
}
if ($token -notmatch '^aswt_[A-Za-z0-9_\.\-]{16,}$') { Die "没拿到合法 token" }
if ($ShowToken) { Say "    token: $token" "Yellow" }
else { Say "    token: $($token.Substring(0, 9))…（共 $($token.Length) 字符；加 -ShowToken 显示全文）" "DarkGray" }

# ---------------------------------------------------------------- 3 写配置
Say "[3/4] 写入 OpenCode 配置" "Cyan"
if (-not (Test-Path $OpencodeConfig)) { Die "找不到 $OpencodeConfig" }
$bak = "$OpencodeConfig.bak-before-swarm"
Copy-Item $OpencodeConfig $bak -Force
Say "    已备份到 $bak" "DarkGray"

$text = [System.IO.File]::ReadAllText($OpencodeConfig, [System.Text.Encoding]::UTF8)

# 用占位符拼装，避免字符串拼接把 token 拆到多行
$newBlock = @'
    // agent-swarm: End-user MCP surface for the local swarm.
    // Start the stack first (desktop icon "Agent Swarm 对话"), otherwise the port will not answer.
    "__SERVER__": {
      "type": "remote",
      "url": "__URL__/mcp-user",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer __TOKEN__"
      }
    },
'@
$newBlock = $newBlock.Replace("`r`n", "`n")
$newBlock = $newBlock.Replace('__SERVER__', $ServerName).Replace('__URL__', $ApiUrl).Replace('__TOKEN__', $token)

# 只匹配到 "mcp": { 的左花括号，之后可能有注释，不能假设紧跟第一个键
$anchor = [regex]::Match($text, '(?s)"mcp"\s*:\s*\{')
if (-not $anchor.Success) { Die '在配置里找不到 "mcp" 段' }
$head = $text.Substring(0, $anchor.Index + $anchor.Length)
$tail = $text.Substring($anchor.Index + $anchor.Length)

# 先删掉可能已存在的旧段（带不带注释都覆盖）
$oldRx = [regex]('(?s)\n[ \t]*(?:// agent-swarm:.*?\n[ \t]*)?"' + [regex]::Escape($ServerName) + '"\s*:\s*\{.*?\n[ \t]*\},\n')
if ($oldRx.IsMatch($tail)) {
    $tail = $oldRx.Replace($tail, "`n")
    Say "    已移除旧条目" "DarkGray"
}

$text2 = $head + "`n" + $newBlock + $tail

# 保留原文件有无 BOM
$raw = [System.IO.File]::ReadAllBytes($OpencodeConfig)
$hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
[System.IO.File]::WriteAllText($OpencodeConfig, $text2, (New-Object System.Text.UTF8Encoding($hasBom)))

# 校验：条目不重复 + JSON 合法 + token 干净单行
$written = [System.IO.File]::ReadAllText($OpencodeConfig, [System.Text.Encoding]::UTF8)
$occurrences = ([regex]::Matches($written, '"' + [regex]::Escape($ServerName) + '"\s*:')).Count
$check = [regex]::Replace($written, '(?m)^[ \t]*//.*$', '')
$ok = $true
$why = ""
try { $j = $check | ConvertFrom-Json }
catch { $ok = $false; $why = "JSON 解析失败：$($_.Exception.Message)" }
if ($ok -and $occurrences -ne 1) { $ok = $false; $why = "条目出现了 $occurrences 次（应为 1）" }
if ($ok) {
    $auth = [string]$j.mcp.$ServerName.headers.Authorization
    if ($auth -match "[\r\n]") { $ok = $false; $why = "token 里混进了换行符" }
    elseif ($auth -notmatch ('^Bearer ' + [regex]::Escape($token) + '$')) { $ok = $false; $why = "token 与刚铸造的不一致" }
}
if (-not $ok) {
    Copy-Item $bak $OpencodeConfig -Force
    Die "写入后校验失败（$why），已自动回滚到 $bak"
}
Say "    已写入并校验通过（条目 1 个、JSON 合法、token 单行）" "DarkGray"

# ---------------------------------------------------------------- 4 握手
Say "[4/4] 验证 MCP 握手" "Cyan"
$mcpHdr = @{ Authorization = "Bearer $token"; Accept = "application/json, text/event-stream" }
$mcpUrl = "$ApiUrl/mcp-user"
$init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}'
$resp = Invoke-WebRequest -Uri $mcpUrl -Method POST -Headers $mcpHdr -ContentType "application/json" -Body $init -UseBasicParsing -TimeoutSec 30
$sid = $resp.Headers['mcp-session-id']
if (-not $sid) { Die "握手没拿到 session id" }

# 响应是 SSE 格式，取 data: 行
function Get-DataLine([string]$content) {
    $l = ($content -split "`n" | Where-Object { $_ -like "data:*" } | Select-Object -First 1)
    if ($l) { return $l.Substring(5).Trim() }
    return $content.Trim()
}

$initJ = (Get-DataLine $resp.Content) | ConvertFrom-Json
Say "    服务端：$($initJ.result.serverInfo.name) v$($initJ.result.serverInfo.version)" "DarkGray"

$sessHdr = $mcpHdr + @{ "mcp-session-id" = $sid }
$null = Invoke-WebRequest -Uri $mcpUrl -Method POST -Headers $sessHdr -ContentType "application/json" `
    -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -UseBasicParsing -TimeoutSec 20
$tl = Invoke-WebRequest -Uri $mcpUrl -Method POST -Headers $sessHdr -ContentType "application/json" `
    -Body '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' -UseBasicParsing -TimeoutSec 30
$toolList = @(((Get-DataLine $tl.Content) | ConvertFrom-Json).result.tools)
Say "    工具 $($toolList.Count) 个：$(($toolList | ForEach-Object { $_.name }) -join ', ')" "DarkGray"

# ---------------------------------------------------------------- 收尾
Say ""
Say "完成。" "Green"
Say ""
Say "在 OpenCode 里直接用这些工具：" "Gray"
foreach ($t in $toolList) { Say "  ${ServerName}__$($t.name)" "DarkGray" }
Say ""
Say "示例：'用 agent-swarm 派个活：把 xxx 做完'" "DarkGray"
Say "任务跑起来后可以随时追加要求（steer-task）。" "DarkGray"
Say ""
Say "回滚：Copy-Item `"$bak`" `"$OpencodeConfig`" -Force" "DarkGray"
Say "重跑本脚本可换一个新 token。" "DarkGray"

# ---------------------------------------------------------------- 冷启动提醒
$uiUp = $false
try { $null = Invoke-RestMethod "http://127.0.0.1:5274/" -TimeoutSec 3; $uiUp = $true } catch { }
if (-not $uiUp) {
    Say ""
    Say "提示：网页仪表盘没起来（127.0.0.1:5274 无响应），聊天页将不可用。" "Yellow"
}
Say ""
Say "首次派活前建议先预热一次，否则会看到 Spawn failed: opencode session create timed out。" "Yellow"
Say "预热方法见 docs/OPENCODE-MCP.md 的「冷启动」一节。" "DarkGray"
