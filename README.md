# agent-swarm-skill

> 给 AI 编码助手（OpenCode / Claude Code 等）用的 **Skill 包**：
> 让它能把 [agent-swarm](https://github.com/desplega-ai/agent-swarm) 部署成本地 AI 小团队，
> 并交付一个桌面 GUI 控制台 + 可连续对话、运行中可插话的聊天窗口。

配套的桌面程序本体在 **[yasunosubaru/agent-swarm-desktop](https://github.com/yasunosubaru/agent-swarm-desktop)**（本 Skill 的 `scripts/bootstrap.ps1` 会去克隆它）。

---

## 这个 Skill 解决什么

1. **自带的 Chat 页不能用** —— v1.154.0 的 `/api/channels` 后端路由不存在（404），
   官方源码注释写着 `// Re-add when /api/channels routes are created.`
2. **部署步骤太碎** —— 七个容器、镜像源、宿主代理、凭据挂载、补丁版 Dockerfile。
3. **Windows 特有的坑** —— PowerShell 5.1 的 BOM/编码问题能把中文脚本和请求一起搞坏。

Skill 把这三件事的**正确做法和踩过的坑**写成可执行指引。

---

## 内容

```
agent-swarm-skill/
├── SKILL.md                          主指引：流程、接口、坑速查、安全红线
├── references/
│   ├── deployment.md                 架构、配置、端口、卷、Dockerfile 补丁点
│   ├── chat-api.md                   对话页三接口、插话时序陷阱、session-logs 兜底
│   ├── windows-powershell.md         BOM / 编码 / WPF / 单实例 / 进程排查 / 快捷方式
│   └── troubleshooting.md            按症状索引的排障手册
└── scripts/
    ├── bootstrap.ps1                 克隆桌面仓库并跑安装向导
    └── verify.ps1                    端到端自检（含真实任务往返）
```

---

## 用法

### 作为 Skill 使用

把本仓库放进你的 skill 目录，或直接引用：

```markdown
参考 https://github.com/yasunosubaru/agent-swarm-skill/blob/main/SKILL.md
```

`SKILL.md` 带标准 frontmatter（`name` / `description`），支持该格式的助手能自动识别：

```yaml
---
name: agent-swarm-desktop
description: 在 Windows 上把 agent-swarm 部署成本地 AI 小团队，并交付桌面 GUI 控制台 + 对话窗口。
             当用户要求部署/安装/启动 agent-swarm、把 agent-swarm 做成 GUI 或桌面应用、
             用对话方式使用 agent-swarm、或排查本机启动失败与凭据问题时使用。
---
```

### 直接用脚本

```powershell
# 克隆桌面程序并安装
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1

# 部署完成后自检（含真的发一次任务）
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

`verify.ps1` 需要同目录或桌面仓库里的 `config.json`；它会查五项服务 +
发一个任务、轮询到完成、校验回复，退出码 0 才算通过。

---

## 核心结论速览

| 主题 | 结论 |
|---|---|
| 对话怎么实现 | `POST /api/tasks` + 请求体 `parentTaskId` 串成会话链 |
| 插话怎么实现 | `POST /api/tasks/{id}/steer`，`{message, mode:"steer"}` |
| 插话的结果 | `deliveredMode` 通常是 `queue`，**结果被延后覆盖** → 必须等 `steering-messages` 全部 `handled` 再读 `output` |
| 回复为空 | 从 `GET /api/tasks/{id}/session-logs` 取**最后一段**文本 |
| 凭据判定 | `credStatus.ready=true` + `satisfiedBy=file`；`liveTest.ok=false` 是误报 |
| 启动 | 镜像建好后一律 `compose up -d --no-build` |
| `.ps1` 编码 | **UTF-8 with BOM**（PS 5.1 否则乱码到语法崩） |
| 发中文请求 | body 传 `[Text.Encoding]::UTF8.GetBytes($json)` |

---

## License

MIT，见 [LICENSE](LICENSE)。

不含 agent-swarm 本身；相关项目版权归原作者所有。
