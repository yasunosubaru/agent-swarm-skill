# 排障手册

按「症状 → 原因 → 修法」组织。全是实际踩过的坑。

---

## A. PowerShell 相关（最容易浪费时间的一类）

### A1. `.ps1` 里有中文 → 语法报错 / 乱码

**症状**：报 `switch 语句缺少它的主体`、引号不闭合之类的莫名其妙错误；或者输出是 `������`。

**原因**：Windows PowerShell 5.1 对**没有 BOM** 的 `.ps1` 按系统 ANSI 代码页（中文是 GBK）解码，
UTF-8 中文被拆成乱码，顺带破坏了引号和语法结构。

**修法**：`.ps1` 一律存成 **UTF-8 with BOM**。

```powershell
$f = ".\script.ps1"
[System.IO.File]::WriteAllText($f,
    [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8),
    (New-Object System.Text.UTF8Encoding($true)))   # ← true 就是 BOM
```

> 本仓库所有 `.ps1` 都已带 BOM。用编辑器改完记得复查。
> `.json` / `.jsonc` / `.env` / `chat.html` 则**不要** BOM（见 A2）。

### A2. 用 `Invoke-RestMethod` 发中文 → agent 收到一堆 `?`

**症状**：任务内容变成 `"????????????"`，agent 甚至会主动报告
「任务文本不可读，11 个非 ASCII 字符被替换成 ?」。

**原因**：PowerShell 5.1 的 `Invoke-RestMethod` 默认把字符串按 ISO-8859-1 发送。

**修法**：显式传 UTF-8 字节。

```powershell
$json  = @{ task = "中文内容"; source = "api" } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Invoke-RestMethod -Method POST -Uri "http://localhost:3013/api/tasks" `
  -Headers @{ Authorization = "Bearer $key" } `
  -ContentType "application/json; charset=utf-8" -Body $bytes
```

> 浏览器里的 `fetch` 天然就是 UTF-8，所以**网页端不受影响**。这纯粹是 PowerShell 客户端的坑。

### A3. 变量名和参数撞名 → 赋值报类型错误

**症状**：

```
无法将值"System.String"转换为类型"System.Management.Automation.SwitchParameter"
```

**原因**：PowerShell 变量名**不区分大小写**。给脚本加了 `-Chat` 开关后，
再写 `$script:chat = "http://..."`，赋的就是那个 SwitchParameter。

**修法**：换个名字，比如 `$script:chatUrl`。

### A4. 排查进程时把自己杀了

**症状**：`shell` 命令返回 `exit 255`，输出莫名其妙地断掉。

**原因**：`Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*foo.ps1*" }`
—— 你自己的命令行里就含 `foo.ps1`，于是 shell 进程自己被匹配并 `Stop-Process` 掉了。

**修法**：永远排除自己。

```powershell
$me = $PID
... | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like "*-File*foo.ps1*" }
```

### A5. WPF 窗口不显示 / 单实例重复

- WPF 需要 STA：快捷方式里带 `-STA`（Windows PowerShell 5.1 控制台主机默认已是 STA，但显式写更保险）。
- 单实例用命名 Mutex；第二次启动用 `FindWindow` + `ShowWindow(SW_RESTORE)` + `SetForegroundWindow` 把老窗口顶到前台。
- Mutex 名用 `Local\` 而不是 `Global\`，避免跨会话权限问题。

---

## B. 服务起不来

### B1. 容器全都 `Exited (0)`

`Exited (0)` 是**正常停止**，不是崩溃。几乎总是有人点了「停止全部」。

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action start
```

### B2. 宿主代理 18080 掉线

宿主 shell 后端重启会带走这个进程。`proxy_supervisor.ps1` 每 10 秒自愈一次，
但 supervisor 自己也得活着。检查：

```powershell
Get-NetTCPConnection -LocalPort 18080 -State Listen
```

> 想开机自启，`schtasks /create` 在非管理员会话会 `拒绝访问`；
> 改用注册表 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` 或任务计划程序（选"仅用户登录时"）。

### B3. Docker 拉不动基础镜像

症状是 build 卡在 `FROM` 或 `manifest unknown`。

- 确认 Docker Desktop 代理是**手动** `http://host.docker.internal:18080`
- 用 setup 时的镜像源补丁版 Dockerfile
- `docker pull ghcr.dockerproxy.net/desplega-ai/agent-fs:0.13.7` 先单独验证

### B4. worker 镜像构建失败

| 报错 | 原因 | 修法 |
|---|---|---|
| `better-sqlite3` 装不上 | 预编译产物来自 GitHub Releases，拉不到就回退源码编译 | Dockerfile 里必须有 `build-essential` |
| 找不到 `bun` | 最终镜像没带 CLI | 从 builder `COPY --from=builder /usr/local/bin/bun` |
| `ghcr.io/j178/prek` 拉不到 | 那个 stage 在受限网络下不可达 | 删掉该 stage |
| skills 安装失败 | 走 GitHub 免费源 | 换成 github-free 源 |

### B5. 仪表盘 5274 起不来

```powershell
Get-Content .\logs\ui-dev.log -Tail 30
```

首次启动要 `npm install`，可能几分钟。端口被占就换 `config.json` 里的 `uiPort`。
注意 Vite 用了 `--strictPort`，端口被占会直接退出而不是换端口。

### B6. `docker compose up` 卡住

镜像已经构建好之后**务必加 `--no-build`**，否则每次都会重新构建（能卡 5 分钟以上）。

---

## C. AI 员工相关

### C1. 员工注册了但 `credStatus.liveTest.ok = false`

**这是误报，不用管。** 内置探针只检查 `OPENROUTER_API_KEY` / `ANTHROPIC_API_KEY` /
`OPENAI_API_KEY` 这三个环境变量。用 `HARNESS_PROVIDER=opencode` + 凭据文件时它必然 false。

**真正的判据**是：

```
credStatus.ready == true  且  credStatus.satisfiedBy == "file"
```

### C2. agent 说「Cannot write /workspace/shared/...」

正常。`/workspace/shared` 根目录 `root:root 755`，agent 以 uid 1001 无 sudo 运行。
让 agent 写 `/workspace/personal` 或 `/workspace/shared/misc/<agentId>/`。

### C3. 任务完成了但 `output` 是空的

纯文本回复就是这样。用 [CHAT.md 的 session-logs 兜底](CHAT.md#output-为空时的兜底)取文本。
自检脚本 `verify.ps1` 里也内置了同样的逻辑。

---

## D. 对话页

### D1. 提示「缺少 API Key」

`apps/ui/public/swarm-config.js` 不存在或读不到。重跑：

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action start
```

它会在启动仪表盘前自动重新生成该文件。

### D2. 插话没生效

先看它到底有没有被投递：

```powershell
$r = Invoke-RestMethod "http://localhost:3013/api/tasks/<taskId>/steering-messages" `
     -Headers @{ Authorization = "Bearer $key" }
$r.messages | Format-List status, deliveredMode, handledNote
```

- `status: handled` + `deliveredMode: queue` → 已生效，只是**结果被延后覆盖**，页面会等它处理完再刷新
- `status: undeliverable` → 任务当时已经结束得太早，这条没插进去
- `handledNote` 会写明最终怎么处理的

### D3. 刷新页面后对话没了

记录存在 `localStorage`（键 `agent-swarm-chat-v2`）。无痕窗口、换浏览器、
或清了站点数据就会丢。用右上角「新对话」是主动清空。

---

## E. 一键排查清单

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action status    # 五个 up/down
powershell -File .\gui\swarm-ctl.ps1 -Action verify    # 含 HTTP 探测
powershell -File .\verify.ps1                          # 再加真实任务往返
docker compose -f .\deploy\docker-compose.swarm.yml --env-file .\deploy\.env ps
docker compose -f .\deploy\docker-compose.swarm.yml --env-file .\deploy\.env logs --tail 100 api
```
