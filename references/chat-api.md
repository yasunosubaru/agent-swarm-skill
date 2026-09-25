# 对话页是怎么工作的

`web/chat.html` 是一个零依赖的单页应用（约 900 行，含样式）。
它没有构建步骤，Vite 直接把 `apps/ui/public/` 当静态根目录伺服出来，
所以访问地址就是 `http://127.0.0.1:5274/chat.html`，
并且和仪表盘**同源** —— `/api/*` 被 Vite 代理到 `localhost:3013`，因此完全没有 CORS 问题。

---

## 为什么不用自带的 Chat 页

v1.154.0 的侧边栏 `Chat`（路由 `/chat`、`/chat/:channelId`）对应的后端接口不存在：

```
GET  /api/channels        → 404
POST /api/channels        → 404
GET  /api/channels/:id/messages → 404
```

UI 客户端代码里写好了 `createChannel()` / `fetchChannels()`，后端测试文件里甚至留着：

```ts
// Re-add when /api/channels routes are created.
```

也就是说**频道式聊天在这个版本没做完**。所以本项目改用 agent-swarm 真正实现了的三组接口，
自己拼出一个连续对话。

---

## 三个关键接口

### 1. `POST /api/tasks` —— 发一句话

```jsonc
{
  "task": "用户输入的文本",
  "source": "ui",
  "parentTaskId": "上一条任务 id"   // ← 关键
}
```

### 2. `parentTaskId` —— 连续记忆

带上上一条任务的 id，服务端会把父会话的上下文接上，agent 因此记得前面说过什么。

实测：

```
轮1  请记住一个暗号：紫色老虎。只回复 OK。     → OK
轮2  刚才的暗号是什么？只回复那四个字。        → 紫色老虎
```

页面把最近一次任务 id 存在 `state.lastTaskId`，每条新消息都挂上去，形成一条链：

```
轮1 ──parentTaskId──▶ 轮2 ──parentTaskId──▶ 轮3 ──▶ …
```

聊天记录本身存在 `localStorage`（键 `agent-swarm-chat-v2`），刷新页面不丢；
刷新时若发现还有未完成的任务，会自动恢复轮询。

### 3. `POST /api/tasks/{id}/steer` —— 运行中插话

AI 还在干活时，你继续发消息不会新建任务，而是作为**转向指令**注入当前任务：

```jsonc
{
  "message": "补充要求：只保留奇数。",
  "mode": "steer",
  "onUnsupported": "degrade",
  "source": "ui"
}
```

实测：让它数 1–40，中途补一句「只保留奇数」，最终结果是 **1 3 5 … 39**。

---

## ⚠️ 插话的时序陷阱（踩过，值得记住）

`deliveredMode` 通常是 **`queue`**，不是即时注入。也就是说服务端会：

1. 让原任务先跑完
2. 再处理这条 steering message
3. **force-complete 覆盖** `task.output`

所以「任务状态变成 completed」的时刻，**结果还不是最终结果**。

踩坑现场：界面在 `completed` 那一刻读 `output`（还是 1–40 全量）就渲染了，
十几秒后服务端才把 output 覆盖成奇数序列。

**正确做法**（代码里 `waitSteering()`）：

```
任务进入终态
  ↓
若本次会话发过 steering message
  ↓
轮询 GET /api/tasks/{id}/steering-messages 直到全部 handled / undeliverable
  ↓
重新 GET /api/tasks/{id} 取被覆盖后的 output
  ↓
渲染
```

界面上这段时间显示「正在应用你的补充…」。

---

## `output` 为空时的兜底

纯文本回复时 `task.output` **经常是空字符串**。这时从会话日志里取最后一段文本：

```
GET /api/tasks/{id}/session-logs
```

- `message.part.delta` 事件：`properties.{partID, field, delta}`，`field` 为 `text` 时按 `partID` 分组拼接
- `message.part.updated` 事件：`properties.part.{id, type:"text", text}`，直接就是完整文本
- **取最后索引最大的一组** —— 最终回答总是最后写出来的，推理过程在它前面

```js
const parts = new Map();
logs.forEach((e, i) => { /* 按 partID 累加，记录 last = i */ });
let best = "", bestIdx = -1;
for (const v of parts.values())
  if (v.text.trim() && v.last >= bestIdx) { bestIdx = v.last; best = v.text; }
```

---

## 密钥是怎么进来的

`chat.html` 里**没有任何密钥**：

```html
<script src="/swarm-config.js"></script>
<script>
  const CFG = window.SWARM_CONFIG || {};
  const API_KEY = CFG.apiKey || "";
</script>
```

`swarm-config.js` 由 `setup.ps1` / `swarm-ctl.ps1` 生成到
`<源码目录>/apps/ui/public/`，内容形如：

```js
window.SWARM_CONFIG = { apiKey: "3d23…" };
```

所以 `chat.html` 本身可以公开提交，而真 key 始终留在 gitignore 覆盖范围内。
文件缺失时，页面会禁用输入框并提示「请先运行 setup.ps1 生成配置」，而不是静默失败。

---

## 其他实现细节

| 点 | 做法 |
|---|---|
| Markdown | 轻量渲染：代码块、行内代码、`**粗体**`、链接、有序/无序列表；先转义再拼，避免 XSS |
| 复制 | 每条回复下方的任务号行，点击复制全文 |
| 状态灯 | 每 15 秒拉一次 `/health` + `/api/agents`，显示员工数与忙碌数 |
| 员工名 | 启动时拉 `/api/agents` 建 id→name 映射，消息上显示 `Lead` 等 |
| 轮询间隔 | 2.5 秒；最长等 15 分钟，超时提示去 Sessions 页看 |
| 错误 | 失败/超时用红框显示在气泡位置，不吞异常 |
| 停止 | 顶部「新对话」在有任务运行时拒绝并提示 |

---

## 想改成自己的样子

`web/chat.html` 顶部就是 CSS 变量：

```css
:root{
  --bg:#0A0A0B; --card:#131316; --line:#232328;
  --text:#E8E8EA; --amber:#F59E0B; --ok:#22C55E; --bad:#EF4444;
}
```

改完复制到 `<源码目录>/apps\ui\public\chat.html` 即可，
Vite 会立刻热更新，不需要重启服务。
