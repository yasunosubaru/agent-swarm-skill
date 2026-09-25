# Windows / PowerShell 实战坑位

在 Windows 上自动化部署 agent-swarm 时踩过的、**纯 Windows 特有**的问题。
（跨平台通用的坑不在这里，见 `troubleshooting.md`。）

---

## 1. `.ps1` 必须是 UTF-8 **with BOM**

Windows PowerShell 5.1 读取无 BOM 的 `.ps1` 时，按**系统 ANSI 代码页**解码（中文机器是 GBK）。
UTF-8 中文被拆成乱码，会连带破坏引号和语法结构。

**症状**：报 `switch 语句缺少它的主体`、引号不闭合等莫名错误；输出是 `������`。

**修法**：

```powershell
$f = ".\script.ps1"
[System.IO.File]::WriteAllText($f,
    [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8),
    (New-Object System.Text.UTF8Encoding($true)))    # true = 带 BOM
```

**对照表**：

| 文件类型 | 编码 |
|---|---|
| `.ps1` | UTF-8 **with BOM** |
| `.json` / `.jsonc` / `.env` | UTF-8 **无 BOM**（BOM 会让 JSON 解析器报错） |
| `.html` / `.js` / `.md` / `.yml` | UTF-8 **无 BOM** |
| Docker `settings.json` | UTF-8 **无 BOM**（BOM 会让 Docker Desktop 读失败） |

> 用 `edit` 工具改完 `.ps1`，BOM 可能会丢。提交前跑一遍上面那段。

---

## 2. `Invoke-RestMethod` 发中文会被替换成 `?`

**症状**：任务内容变成 `"?????????????"`。更妙的是 agent 会自己报告：

> 任务文本以 mojibake 到达，存储值字面量是 `"???????:42???? OK?"`，
> 11 个非 ASCII 字符在保存前被替换成了 `?`。

**原因**：PS 5.1 的 `Invoke-RestMethod` 默认把字符串 body 按 ISO-8859-1 发送。

**修法**：显式传 UTF-8 字节。

```powershell
$json  = @{ task = "中文内容"; source = "api" } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Invoke-RestMethod -Method POST -Uri "http://localhost:3013/api/tasks" `
  -Headers @{ Authorization = "Bearer $key" } `
  -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 30
```

> **浏览器里的 `fetch` 天然就是 UTF-8**，所以网页端完全不受影响。
> 这纯粹是 PowerShell 客户端的坑 —— 排查时别怀疑服务端。

---

## 3. 变量名和参数撞名

**症状**：

```
无法将值"System.String"转换为类型"System.Management.Automation.SwitchParameter"
```

**原因**：PowerShell **变量名不区分大小写**。给脚本加了 `-Chat` 开关后，
再写 `$script:chat = "http://..."`，赋的就是那个 SwitchParameter。

**修法**：换个名字。`$script:chatUrl` / `$ChatPage` 之类。

---

## 4. 排查进程时把自己杀了

**症状**：命令返回 `exit 255`，输出莫名其妙中断。

**原因**：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like "*foo.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

执行这条命令的 shell 进程，**它自己的 CommandLine 里就含 `foo.ps1`**（命令字符串本身），
于是自己把自己杀了。

**修法**：永远排除自己，并且匹配得更精确。

```powershell
$me = $PID
... | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like "*-File*foo.ps1*" }
```

---

## 5. WPF 与 STA

- WPF 需要 **STA**。Windows PowerShell 5.1 的控制台主机默认就是 STA，
  但快捷方式里显式加 `-STA` 更保险。
- 用 `powershell.exe -WindowStyle Hidden -File xxx.ps1` 启动时，
  控制台窗口被隐藏，**WPF 窗口照常显示** —— 这正是"无控制台窗口的 GUI 应用"的实现方式。
- XAML 用 `[Windows.Markup.XamlReader]::Load()` 加载，
  元素通过 `$window.FindName("name")` 取回，再挂事件处理器。
- 给自己加一个 `-SelfTest` 开关：加载完 XAML 打印 `XAML_OK` 就退出。
  这样能在无人值守环境下验证 XAML 没写错。

```powershell
if ($SelfTest) { Write-Output "XAML_OK"; exit 0 }
```

---

## 6. 单实例 + 把老窗口顶到前台

**单实例**用命名 Mutex：

```powershell
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\MyApp", [ref]$created)
if (-not $created) { /* 已有实例 */ }
```

> 用 `Local\` 而不是 `Global\`，避免跨会话/跨权限的坑。

**顶到前台**用 Win32（PowerShell 没有内置方法）：

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@
$h = [W32]::FindWindow($null, "窗口标题")
if ($h -ne [IntPtr]::Zero) {
  [void][W32]::ShowWindow($h, 9)          # 9 = SW_RESTORE
  [void][W32]::SetForegroundWindow($h)
}
```

---

## 7. 不阻塞 UI 的长任务

`docker compose up` 这种几十秒的操作不能放 UI 线程。

**方案**：`Start-Job` 跑长任务 + `DispatcherTimer` 轮询并把输出刷到界面。

```powershell
$script:job = Start-Job -ScriptBlock {
    param($ctl, $act)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ctl -Action $act
} -ArgumentList $ctlPath, $action

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1200)
$timer.Add_Tick({
    if ($script:job) {
        foreach ($line in (Receive-Job $script:job)) { Add-Log $line }
        if ($script:job.State -in @('Completed','Failed','Stopped')) {
            Remove-Job $script:job -Force
            $script:job = $null
        }
    }
})
```

用哨兵行（`READY` / `FAILED` / `STOPPED`）判断成败，比解析人类可读文本可靠。

---

## 8. 快捷方式与图标

```powershell
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$desktop\Agent Swarm.lnk")
$sc.TargetPath  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments   = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\...\AgentSwarm.ps1" -Chat'
$sc.WorkingDirectory = "C:\...\agent-swarm"
$sc.IconLocation = "C:\...\agent-swarm.ico,0"
$sc.WindowStyle  = 7      # 最小化启动
$sc.Save()
```

**多尺寸 `.ico`**：`System.Drawing.Icon.FromHandle()` 只能出一个尺寸。
正确做法是手写 ICO 容器：6 字节 `ICONDIR` + 每项 16 字节 `ICONDIRENTRY`，
负载直接塞 PNG（Vista+ 支持 PNG 压缩条目），尺寸 16/24/32/48/64/128/256。
256 那项的宽高字节写 `0`。

---

## 9. 开机自启的权限坑

`schtasks /create` 在**非管理员**会话下会 `拒绝访问`。

替代方案：

- 注册表 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`（仅当前用户，无需管理员）
- 任务计划程序里建任务，触发器选「**仅当用户登录时**」，并且不要勾「需要最高权限」

启动守护进程一律用分离进程，别指望当前会话能一直活着：

```powershell
Start-Process powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$ps1" -WindowStyle Hidden
```

---

## 10. 端口

Windows 会保留一批 TCP 端口给系统服务，绑定时会失败。
挑端口前先查：

```powershell
Get-NetTCPConnection -LocalPort 18080 -State Listen -ErrorAction SilentlyContinue
```

常见可用：18080、5274、3013、3020-3022。
