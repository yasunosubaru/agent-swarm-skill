---
name: agent-swarm-desktop
description: 在 Windows 上把 agent-swarm (desplega-ai) 部署成本地 AI 小团队，并交付一个桌面 GUI 控制台 + 可连续对话、运行中可插话补充的聊天窗口。当用户要求部署/安装/启动 agent-swarm、把 agent-swarm 做成 GUI 或桌面应用、用对话方式使用 agent-swarm、或排查本机 agent-swarm 启动失败与凭据问题时使用。
---

# Agent Swarm 桌面化部署

把 `desplega-ai/agent-swarm` 从"一堆 Docker 命令"变成**双击就能用的桌面应用**。

本 Skill 覆盖 v1.154.0，实测环境 Windows 10/11 + Docker Desktop。

---

## 0. 先搞清一件事：自带的 Chat 页是坏的

**不要浪费时间去调 `/chat` 页面。** v1.154.0 里它对应的后端路由不存在：

```
GET /api/channels → 404
```

后端源码留有官方注释 `// Re-add when /api/channels routes are created.`，UI 里却已经写好了
`createChannel()` / `fetchChannels()`。点进去永远只有 "Select a channel"。

**替代方案（本 Skill 的核心做法）**：用 agent-swarm 真正实现的三组接口拼出对话界面 ——

| 能力 | 接口 |
|---|---|
| 说一句话 | `POST /api/tasks` |
| 连续记忆 | 请求体带 `parentTaskId` = 上一条任务 id |
| 干活时插话 | `POST /api/tasks/{id}/steer`，body `{message, mode:"steer"}` |
| 任务状态 | `GET /api/tasks/{id}` |
| 回复兜底 | `GET /api/tasks/{id}/session-logs` |
| 插话是否落地 | `GET /api/tasks/{id}/steering-messages` |

细节见 `references/chat-api.md`，**动手前必读**，尤其那个「结果被延后覆盖」的时序陷阱。

---

## 1. 交付物

`https://github.com/yasunosubaru/agent-swarm-desktop` 提供：

- `gui/AgentSwarm.ps1` —— WPF 深色控制台（状态灯 / 启动 / 停止 / 打开对话 / 日志）
- `web/chat.html` —— 零依赖对话单页，同源挂在仪表盘 `public/` 下
- `setup.ps1` —— 交互式安装向导
- `verify.ps1` —— 端到端自检（含真实任务往返）
- `deploy/dockerfiles/` —— 受限网络下的镜像源补丁版 Dockerfile

安装：

```powershell
git clone https://github.com/yasunosubaru/agent-swarm-desktop.git
cd agent-swarm-desktop
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

---

## 2. 部署流程

### 2.1 前置检查

```powershell
docker version                 # 引擎要能通
git --version
node --version                 # 需要 20+（仪表盘 Vite）
python --version               # 可选，跑宿主代理
```

`agent-swarm` 源码从 [Releases](https://github.com/desplega-ai/agent-swarm/releases) 下载解压。
必须同时存在 `Dockerfile` 和 `apps/ui/package.json` 才算有效目录。

### 2.2 七个容器

```
minio + minio-init + agent-fs + api + lead + worker-1 + worker-2
```

无 Caddy / 无 TLS / 不暴露公网。API `3013`，仪表盘 `5274`。

### 2.3 harness 选择

| 选项 | 适合 |
|---|---|
| `opencode` | 复用本机已登录的 OpenCode 凭据（免费/已有订阅，**推荐**） |
| `openrouter` / `anthropic` / `openai` | 有对应 API Key 时 |

`HARNESS_PROVIDER=opencode` 时需要把本机的
`~/.local/share/opencode/auth.json` 复制到 `deploy/opencode-config/`，
并在 `opencode.jsonc` 里声明自定义 provider（baseURL + 模型列表）。

### 2.4 构建镜像（一次，10–30 分钟）

```powershell
docker build -f "<src>\Dockerfile"        -t agent-swarm:local       "<src>"
docker build -f "<src>\Dockerfile.worker" -t agent-swarm-worker:local --target worker-slim "<src>"
```

**必须带 `--target worker-slim`**，完整镜像好几 GB。

### 2.5 启动

镜像建好之后，启动一律加 `--no-build`，否则每次都会重新构建：

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action start
```

`start` 走 5 步：宿主代理 → Docker 引擎 → `compose up -d --no-build` → 等 API 健康 → 起 Vite。
输出以 `READY` 或 `FAILED` 结尾。

---

## 3. 验证（不许跳过）

```powershell
powershell -File .\verify.ps1
```

它会查五项服务，**并且真的发一个任务**给 AI 团队、轮询到完成、校验回复里含 `VERIFY_OK`。
退出码 0 才算部署成功。

**"容器都 Running" 不等于能用。** 必须有一次真实任务往返。

---

## 4. 交付给用户的用法

桌面上两个图标：

| 图标 | 行为 |
|---|---|
| **Agent Swarm 对话** | 拉起服务 → 直接进聊天窗口（日常用这个） |
| **Agent Swarm** | 拉起服务 → 打开控制台 |

对话页：回车发送，Shift+回车换行，AI 干活时继续发消息就是**插话补充**，右上角「新对话」清空。

---

## 5. 坑速查

| 症状 | 原因 | 修法 |
|---|---|---|
| `.ps1` 里有中文就语法报错 | PS 5.1 把无 BOM 的 UTF-8 当 GBK 读 | `.ps1` 存成 **UTF-8 with BOM** |
| `Invoke-RestMethod` 发中文变 `???` | PS 5.1 默认按 ISO-8859-1 发 | `[System.Text.Encoding]::UTF8.GetBytes($json)` 当 body |
| 赋字符串报 SwitchParameter 类型错 | `$script:chat` 撞上了 `-Chat` 参数（PS 变量名不分大小写） | 改名 `$script:chatUrl` |
| 排查进程时 shell 自己被杀掉 | 过滤 `CommandLine -like "*x.ps1*"` 匹配到了自己 | 加 `$_.ProcessId -ne $PID` |
| `credStatus.liveTest.ok=false` | **误报**，探针只查三个 *_API_KEY 环境变量 | 看 `ready=true` + `satisfiedBy=file` |
| agent 说写不进 `/workspace/shared` | 根目录 root:root 755，agent 是 uid 1001 无 sudo | 写 `/workspace/personal` 或 `/workspace/shared/misc/<id>/` |
| `docker compose up` 卡住 | 在重新构建 | 加 `--no-build` |
| 插话没生效 | `deliveredMode=queue`，结果被延后覆盖 | 等 `steering-messages` 全部 `handled` 再读 output |
| 任务完成但 `output` 是空的 | 纯文本回复的常态 | 从 `session-logs` 提取最后一段文本 |
| 拉不动基础镜像 | Docker VM 直连 ghcr/quay 不通 | 宿主 CONNECT 代理 + 镜像源前缀 Dockerfile |

完整版：`references/troubleshooting.md`。
PowerShell/编码专项：`references/windows-powershell.md`。

---

## 6. 参考文件

| 文件 | 内容 |
|---|---|
| `references/chat-api.md` | 对话页三个接口的完整用法、插话时序陷阱、session-logs 兜底 |
| `references/deployment.md` | 架构图、配置项、端口、卷、Dockerfile 补丁点 |
| `references/windows-powershell.md` | BOM / 编码 / WPF / 单实例 / 进程排查 |
| `references/troubleshooting.md` | 按症状索引的排障手册 |
| `scripts/bootstrap.ps1` | 克隆桌面仓库并跑 setup |
| `scripts/verify.ps1` | 端到端自检（与桌面仓库同款） |

---

## 7. 安全红线

推到任何远端之前，**真实凭据一律不许进版本库**：

- `config.json`（本机绝对路径）
- `deploy/.env`（本地 API Key、provider Key）
- `deploy/encryption_key`
- `deploy/opencode-config/auth.json`
- `<src>/apps/ui/public/swarm-config.js`（注入给对话页的 Key）

对话页本身必须**零密钥**：`chat.html` 运行时读 `/swarm-config.js`。
这是它能公开提交的唯一前提。

如果 Key 曾经被提交过，**去服务端吊销并轮换** —— 删文件不等于作废密钥。
