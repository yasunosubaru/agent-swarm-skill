# 完整部署手册

面向 Windows 10/11 + Docker Desktop，agent-swarm **v1.154.0**。
如果你只想快点用起来，看 [README](../README.md#快速开始) 就够了；本文是出问题时回来查的。

---

## 1. 架构

```
┌──────────────────────────────────────────────────────────────┐
│  Windows 主机                                                  │
│                                                              │
│  ┌────────────────┐   ┌──────────────────────────────────┐  │
│  │ AgentSwarm.ps1 │   │ Vite dev server  127.0.0.1:5274   │  │
│  │  WPF 控制台     │──▶│  ├─ 仪表盘  /                    │  │
│  │  (桌面应用)     │   │  └─ 对话页  /chat.html           │  │
│  └────────┬───────┘   └───────────────┬──────────────────┘  │
│           │ 启动/停止                 │ /api 代理              │
│  ┌────────▼───────────────────────────▼──────────────────┐   │
│  │ swarm-ctl.ps1                                        │   │
│  └────────┬─────────────────────────────────────────────┘   │
│           │                                                 │
│  ┌────────▼──────────┐   ┌────────────────────────────────┐  │
│  │ host_proxy.py     │   │ Docker Desktop (Linux VM)       │  │
│  │ CONNECT :18080    │◀──│ proxy → host.docker.internal    │  │
│  └───────────────────┘   └───────────────┬────────────────┘  │
└──────────────────────────────────────────┼───────────────────┘
                                           │
        ┌──────────────┬───────────────┬───┴────────┬──────────┐
        ▼              ▼               ▼            ▼          ▼
     minio        agent-fs          api        lead     worker×2
   + minio-init   :7433           :3013       :3020    :3021/22
```

**7 个容器**：`minio` · `minio-init` · `agent-fs` · `api` · `lead` · `worker-1` · `worker-2`。

没有 Caddy / TLS / 公网暴露 —— 全部只监听 `127.0.0.1`。

---

## 2. 配置文件

安装向导生成两个关键文件：

### `config.json`（仓库根，gitignore）

```json
{
  "swarmRoot": "...\\deploy",
  "swarmSrc": "...\\agent-swarm-1.154.0",
  "python": "...\\python.exe",
  "edge": "...\\msedge.exe",
  "proxyPort": 18080,
  "apiPort": 3013,
  "uiPort": 5274
}
```

所有 GUI / CLI 脚本都从这里读路径，**不硬编码任何绝对路径** —— 所以仓库可以克隆到任何地方。

### `deploy/.env`（gitignore）

| 变量 | 说明 |
|---|---|
| `API_KEY` | 本地 Swarm API 鉴权 Key，setup 随机生成的 64 位十六进制 |
| `HARNESS_PROVIDER` | `opencode` / `openrouter` / `anthropic` / `openai` |
| `MODEL_OVERRIDE` | 留空 = harness 自选；填如 `<provider>/<model>` |
| `MCP_BASE_URL` / `APP_URL` | 容器内互调 / 浏览器访问地址 |
| `SWARM_SRC` | `docker build` 的 context |
| `OPENROUTER_API_KEY` 等 | 仅当 harness 不是 opencode 时需要 |

---

## 3. 为什么需要 `host_proxy.py`

Docker Desktop 的 Linux VM 在部分网络环境下**无法直连** `ghcr.io` / `quay.io`
（系统 VPN 或代理会打断 VM 出口），而 Windows 主机可以。

于是：

1. `host_proxy.py` 在主机上开一个极简 HTTP CONNECT 代理（默认 `:18080`）
2. `proxy_supervisor.ps1` 每 10 秒检查一次，掉了就拉起来
3. Docker Desktop 设置 → 代理 → 手动 → `http://host.docker.internal:18080`
4. compose 给每个容器显式注入 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`

> 如果你的网络不需要这层，删掉 compose 里那三行代理变量也能跑。

---

## 4. Dockerfile 补丁说明

`deploy/dockerfiles/` 里是**为受限网络准备的本地副本**，补丁点：

| 文件 | 补丁 |
|---|---|
| `Dockerfile` | `FROM` 加镜像源前缀（`dockerproxy.net/oven/bun`、`dockerproxy.net/library/debian`） |
| `Dockerfile.worker` | 同上 + 复制 builder 里的 bun CLI + `npm i -g opencode-ai` + 去掉不可达的 `ghcr.io/j178/prek` stage + skills 走 GitHub 免费源 + 装 `build-essential` |

**为什么要 `build-essential`**：`better-sqlite3` 的预编译产物从 GitHub Releases 下载，
在受限网络下会失败并回退到源码编译，没有编译器就装不上。

setup 时选 `n` 就用源码树自带的原始 Dockerfile（网络通畅时用原始的更稳）。

> 覆盖时会自动把原件备份成 `Dockerfile.agent-swarm-orig`。

---

## 5. 日常操作

### 图形界面

控制台窗口（桌面 `Agent Swarm`）：

| 按钮 | 作用 |
|---|---|
| 开始对话 | 打开对话窗口（主按钮） |
| 打开工作台 | 打开仪表盘（任务/会话/员工管理） |
| 启动 / 修复服务 | 手动重跑启动流程 |
| 停止全部 | 停止（二次确认，**数据保留**） |
| 刷新状态 | 立即刷新状态灯 |
| 打开安装文件夹 | 打开仓库根目录 |

- 关闭控制台窗口**不会**停服务
- 重复点图标**不会**开第二个窗口（单实例 Mutex + `SetForegroundWindow`）

### 命令行

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action start
powershell -File .\gui\swarm-ctl.ps1 -Action stop
powershell -File .\gui\swarm-ctl.ps1 -Action status
powershell -File .\gui\swarm-ctl.ps1 -Action open
powershell -File .\gui\swarm-ctl.ps1 -Action open-chat
powershell -File .\gui\swarm-ctl.ps1 -Action verify
```

`start` 的输出以 `READY` / `FAILED` 结尾，方便脚本判断。

---

## 6. 端口一览

| 端口 | 用途 | 谁在用 |
|---|---|---|
| 18080 | 宿主 CONNECT 代理 | Docker Desktop → `host.docker.internal` |
| 3013 | Swarm API | 浏览器 / Vite 代理 / 验证脚本 |
| 5274 | Vite 开发服务器（仪表盘 + 对话页） | 浏览器 |
| 3020 / 3021 / 3022 | lead / worker-1 / worker-2 | 容器内部 |
| 7433 | agent-fs | 容器内部 |
| 9000 / 9001 | MinIO API / Console | 可选访问 |

---

## 7. 数据与持久化

Docker 命名卷：

| 卷 | 内容 |
|---|---|
| `agent_fs_minio` | MinIO 对象存储 |
| `agent_fs_data` | agent-fs 数据 |
| `swarm_api_data` | SQLite 主库 |
| `swarm_logs` | 会话日志 |
| `swarm_shared` | `/workspace/shared` |
| `swarm_lead` / `swarm_worker_1` / `swarm_worker_2` | 各自 `/workspace/personal` |

`stop` 只停容器，不删卷 → 下次 `start` 原样恢复。
要彻底重来：`docker compose ... down -v`。

> **写入边界**：`/workspace/shared` 根目录是 `root:root 755`，agent 以非特权 uid 1001 运行、
> 没有 sudo，**写不进去**。agent 实际写入 `/workspace/personal` 与
> `/workspace/shared/misc/<agentId>/`。这是设计如此，不是故障。

---

## 8. 卸载

```powershell
powershell -File .\gui\swarm-ctl.ps1 -Action stop
cd deploy
docker compose -f docker-compose.swarm.yml --env-file .env down -v
```

然后删掉仓库目录、桌面快捷方式，以及装进源码树的：
`apps/ui/public/chat.html`、`apps/ui/public/swarm-config.js`、`Dockerfile.agent-swarm-orig`。
