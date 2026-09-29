# 接入 OpenCode（用户 MCP）

把本地 AI 团队接进 OpenCode，之后你就可以**在 OpenCode 对话里直接派活**，
不用再切到浏览器打开仪表盘。

实测：**OpenCode → MCP → 任务池 → Coder 容器 → opencode → 结果回传**，全程可用。

---

## 一键接入

```powershell
powershell -ExecutionPolicy Bypass -File .\mcp\connect-opencode.ps1
```

脚本会：

1. 检查 API 是否在线（没起会提示你先点桌面图标）
2. 找到或创建本地 Swarm 用户
3. 铸造一个 `aswt_` 开头的 MCP token
4. 备份并改写 `~/.config/opencode/opencode.jsonc`，写入 `agent-swarm` 条目
5. 实跑 `initialize` + `tools/list` 握手验证，并列出工具名
6. 校验失败会自动回滚到备份

可重复执行：重跑会换新 token 并**替换**旧条目（不会重复插入）。

```powershell
.\mcp\connect-opencode.ps1 -ShowToken          # 把 token 全文打出来
.\mcp\connect-opencode.ps1 -ApiUrl http://localhost:3013
```

**回滚**

```powershell
Copy-Item "$env:USERPROFILE\.config\opencode\opencode.jsonc.bak-before-swarm" `
          "$env:USERPROFILE\.config\opencode\opencode.jsonc" -Force
```

改完配置需要**重启 OpenCode**（或开新会话）才会加载新的 MCP。

---

## 两个 MCP 端点，别搞混

| 端点 | 认证 | 用途 |
|---|---|---|
| `http://localhost:3013/mcp` | `Authorization: Bearer <API_KEY>` + **`X-Agent-ID`** | swarm **自己的 worker** 用（agent 视角） |
| `http://localhost:3013/mcp-user` | `Authorization: Bearer aswt_…` | **终端用户 / 你**用（user 视角）← 接 OpenCode 用这个 |

`/mcp` 缺 `X-Agent-ID` 会直接 `401 {"error":"Missing X-Agent-ID header"}`。
user 端点则需要 `aswt_` token，且 token 必须映射到一个 **active** 的用户
（`POST /api/users/{id}/mcp-tokens` 铸造，一次性明文，之后只能看到摘要）。

服务端信息：`@desplega.ai/agent-swarm-user` v1.154.0。

---

## 拿到的 6 个工具

| 工具 | 作用 |
|---|---|
| `send-task` | 派一个任务（默认进池子，由 worker 认领） |
| `get-tasks` | 列出你发起的任务，可按状态/标签/关键字筛 |
| `get-task-details` | 单个任务详情（含 output、failureReason、成本） |
| `steer-task` | **任务跑着的时候追加要求** |
| `cancel-task` | 取消进行中的任务 |
| `task-action` | 在 backlog 之间移动任务 |

`send-task` 还支持 `taskType`、`tags`、`priority`、`model` / `modelTier`、
以及 `outputSchema`（用 JSON Schema 约束最终输出格式，不满足会被拒收）。

### 在 OpenCode 里怎么说

```
用 agent-swarm 派个活：把 xxx 做完
```

任务跑起来后你可以接着说：

```
补充：输出请用表格，另外加上日期列
```

这会走 `steer-task`。

---

## ⚠️ 首次派活前先预热（否则必然失败一次）

新装 / 重建卷之后，**第一次**派活几乎必定失败：

```
Spawn failed: opencode session create timed out after 30000ms
```

原因在 agent-swarm 源码 `opencode-adapter.ts` 的注释里写得很清楚：

> The first session in a fresh data home installs plugins and fetches the models
> list, and on a cold container that call has hung… Bound it with the same budget
> as the server start so a hang fails fast as a spawn failure.

也就是**冷容器**首次建会话要装插件 + 拉模型列表，30 秒预算不够。
缓存热了以后就正常了（实测第二次起全部秒回）。

**预热方法**（注意 `-u 1001:1001`，原因见下一节）：

```powershell
foreach ($c in @("agentswarm-worker-1-1","agentswarm-worker-2-1","agentswarm-lead-1")) {
  docker exec -u 1001:1001 $c sh -c 'opencode run --model <provider>/<model> "reply OK"'
}
```

或者更省事：**失败两次就自然热了**。首次失败不影响服务，只影响那一个任务。

---

## ⚠️ 属主陷阱：`docker exec` 千万别省 `-u`

容器 `Config.User=root`（entrypoint 内部再降到 `worker`/uid 1001），
所以 `docker exec` **默认就是 root**。

如果你在容器里以 root 跑过 opencode（或任何写 HOME 的东西），
`/home/worker/.local/share/opencode/` 下的 `opencode.db`、`log/`、`repos/`
就变成 root 所有，worker（uid 1001）随后会报：

```
Spawn failed: Server exited with code 1
PermissionDenied: FileSystem.open (/home/worker/.local/share/opencode/log/opencode.log)
```

**修复**

```powershell
foreach ($c in @("agentswarm-worker-1-1","agentswarm-worker-2-1","agentswarm-lead-1")) {
  docker exec -u 0 $c sh -c 'chown -R 1001:1001 /home/worker/.local/share/opencode /home/worker/.config/opencode /home/worker/.cache'
}
```

本仓库的 `deploy/docker-compose.swarm.yml` 已经在 entrypoint 里加了
`permission-repair` 段，每次容器启动都会自动纠正这三个目录的属主，
所以正常启动不会踩到；只有**手工以 root 进容器操作**才会，需要手动修一次。

> 顺带一提：`/home/worker/.local/share/opencode` 在原镜像里**并不存在**，
> 是 bind-mount `opencode-config/auth.json` 时被 Docker 以 root 创建的。
> 这就是为什么这个目录的属主天然脆弱。

---

## 手工接入（不用脚本时）

在 `~/.config/opencode/opencode.jsonc` 的 `mcp` 段里加：

```jsonc
  "mcp": {
    // agent-swarm: End-user MCP surface for the local swarm.
    // Start the stack first (desktop icon "Agent Swarm 对话"), otherwise the port will not answer.
    "agent-swarm": {
      "type": "remote",
      "url": "http://localhost:3013/mcp-user",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer aswt_你的token"
      }
    },
    "playwright": { /* ...原有条目照抄... */ }
  },
```

拿 token：

```powershell
$key = ((Get-Content .\deploy\.env | ? { $_ -match '^API_KEY=' }) -replace '^API_KEY=','').Trim()
$H = @{ Authorization = "Bearer $key" }
$u = (Invoke-RestMethod "http://localhost:3013/api/users" -Headers $H).users | Select-Object -First 1
(Invoke-RestMethod -Method POST "http://localhost:3013/api/users/$($u.id)/mcp-tokens" `
  -Headers ($H + @{ "Content-Type" = "application/json" }) `
  -Body '{"label":"opencode-mcp"}').plaintext
```

`type: remote` 的可用字段就是 `type` / `url` / `enabled` / `headers`（可加 `oauth`），
见 <https://opencode.ai/config.json> 的 `McpRemoteConfig`。

---

## 排查

| 症状 | 检查 |
|---|---|
| OpenCode 里看不到 `agent-swarm__*` 工具 | 配置写错 / 没重启 OpenCode / `enabled` 不是 true |
| 工具调用报 401 | token 失效或被吊销 → 重跑 `connect-opencode.ps1` 换新的 |
| 工具调用报连不上 | 栈没起：`swarm-ctl.ps1 -Action status` 先看 API/UI |
| 任务 `failed`，reason 是 `session create timed out` | 冷启动，预热后再试（见上） |
| 任务 `failed`，reason 是 `PermissionDenied ... opencode.log` | 属主被 root 污染，执行上面的 chown |
| 任务一直 `unassigned` 没人接 | worker 离线：`docker ps` 看三个 agent 容器是否 Up |

---

## 参考

- 源码：`src/src/http/mcp-user.ts`（端点实现）、`src/src/http/integrations.ts`（`/api/integrations/mcp-user/config` 返回 `mcpUserUrl`）
- 仪表盘里也有对应入口：Settings → Integrations
