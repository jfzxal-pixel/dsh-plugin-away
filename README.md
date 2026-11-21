# dsh-plugin-away

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 加一个「离开模式」开关：
**开着的时候，任务跑完会主动通知你；关着就安静。**

适合这种场景：扔一个长任务给 agent，然后去吃饭/开会，跑完了手机响一下，你回一句就能接着干。

---

## 它做了什么

- 在输入框的 `/` 菜单里注册一个 **`/away`** 命令，用来开关。
- 订阅会话的 `turn/end` 事件：如果此刻离开模式是开的，且这一轮耗时超过阈值（默认 90 秒），就调用你配置的通知通道，把「用时 + 你交代的事 + 结果摘要」发出去。
- 开关状态存在一个 JSON 文件里（`$DSH_HOME/away-mode.json`），所以**任何东西都能翻这个开关**：桌面小浮窗、手机上的脚本、定时任务。

## 安装

### 方式一：本地目录（开发/自用）

```bash
dsh plugin --profile desktop add /path/to/dsh-plugin-away
```

然后重启 DeepSeek Harness，在输入框里打 `/away` 能看到条目即可。

### 方式二：npm 安装

```bash
npm publish            # 发布后
dsh plugin --profile desktop add dsh-plugin-away
```

### 方式三：插件页

设置 → 插件 → 安装，填入包名或本地路径。

## 配置

默认什么都不用配：通知会写进 `$DSH_HOME/away-mode.log`。
要真正推到手机上，在 profile 的 `cordis.patch.yml` 里覆盖这一行：

```yaml
- id: away-mode
  config:
    minTurnSeconds: 90          # 只汇报超过这个秒数的任务，避免琐事打扰
    label: '离开模式'            # 命令在菜单里显示的名字
    notify:
      mode: command
      command: 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
      args: ['-NoProfile', '-File', 'C:\tools\notify.ps1', '-Text', '{{message}}']
```

- `notify.mode`：`log`（默认，写文件）或 `command`（启动一个外部进程）。
- `notify.command` / `notify.args`：**不经过 shell**，argv 逐个传递，所以消息里的引号、换行、中文都不用转义。
- 占位符：`{{message}}` 会被替换成完整通知文本；同时也会通过环境变量 `AWAY_MESSAGE` 传给子进程（很长的时候用环境变量更稳）。

## 通知通道示例

**企业微信 / 飞书 / Slack / Discord 群机器人（任何平台）**

```yaml
notify:
  mode: command
  command: 'curl'
  args: ['-s', '-X', 'POST', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY',
         '-H', 'Content-Type: application/json',
         '-d', '{"msgtype":"text","text":{"content":"{{message}}"}}']
```

**Bark（iOS）**

```yaml
notify:
  mode: command
  command: 'curl'
  args: ['-s', 'https://api.day.app/YOUR_KEY/{{message}}']
```

**ntfy.sh（全平台，手机装 App）**

```yaml
notify:
  mode: command
  command: 'curl'
  args: ['-s', '-d', '{{message}}', 'https://ntfy.sh/your-topic']
```

**Telegram Bot**

```yaml
notify:
  mode: command
  command: 'curl'
  args: ['-s', '-X', 'POST',
         'https://api.telegram.org/bot<TOKEN>/sendMessage',
         '-d', 'chat_id=<CHAT_ID>',
         '--data-urlencode', 'text={{message}}']
```

**微信 PC 客户端（Windows）**

`examples/notify-wechat.ps1` 是现成的：通过 UI 自动化往「文件传输助手」发消息，不需要公众号、不逆向协议。

```yaml
notify:
  mode: command
  command: 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
  args: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'examples/notify-wechat.ps1', '-Text', '{{message}}']
```

## 桌面小浮窗（可选）

`examples/away-toggle.ps1` 是一个常驻的小窗口，一个勾选框，和 `/away` 操作同一个状态文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File examples/away-toggle.ps1
```

两者实时同步：浮窗勾上，`/away status` 立刻显示开启。

## 状态文件

`$DSH_HOME/away-mode.json`：

```json
{ "enabled": true, "updatedAt": "2026-01-01T12:00:00.000Z" }
```

- `DSH_HOME` 默认 `~/.dsh`（Windows 是 `C:\Users\<你>\.dsh`）。
- 也可以用 `DSH_AWAY_STATE` 指定别的路径。
- 读不到文件 = 关闭。文件损坏 = 关闭（不会因此误发消息）。

## 兼容性

- **宿主要求**：任何带 `commands` 服务（对话界面）的 DSH 版本。命令 id 用纯字符串，没有依赖内部类型。
- **零运行时依赖**：只用 node 内置模块，不依赖 `@deepseek-ai/*` 的任何包，因此不会因为宿主升级换版本号而装不上。
- **平台**：状态、事件、通知调度都是跨平台的；只有 `examples/notify-wechat.ps1` 和 `examples/away-toggle.ps1` 是 Windows 专用（微信 PC 客户端与 WinForms），不用可以删掉。
- **Node**：>= 20。

## 已知限制

- 只在**宿主的 turn 结束**时触发；子 agent、后台 job 的结束不算独立的一轮。
- 重复保护是「同一轮不重复通知」（内存态）；插件热重载后对**正在进行**的那一轮不再补发。
- `notify.mode: command` 是即发即忘（不等待退出码），失败不会阻塞会话；排查请看 `$DSH_HOME/away-mode.log` 里 `[away-mode]` 开头的 stderr。

## 双向：微信里下发指令（可选，Windows）

`wechat-bridge/` 是一套配套脚本，让「你在手机微信里说话 → 电脑上真的干活 → 结果回到微信」：

| 文件 | 作用 |
|---|---|
| `bridge.ps1` | 读微信「文件传输助手」的新消息，交给 `dsh headless` 执行，再把结果发回去 |
| `watchdog.ps1` | 守护进程：每 30 秒巡检，桥接挂了或心跳停了就自动拉起 |
| `start-all.ps1` | 启动守护进程（放进启动文件夹即可开机自启） |
| `bridge.config.example.json` | 复制成 `bridge.config.json`，填 `dsh` 路径和工作目录 |

### 和 `/away` 的关系

桥接**只在离开模式开启时才操作微信窗口**。关闭时它完全不碰微信——不切换会话、不抢前台，你可以照常和别人聊天。

```
/away 开启  →  桥接开始读消息、切会话、回消息
/away 关闭  →  桥接彻底静默，只保留心跳
```

开启时会先重建基线，所以关闭期间的历史消息不会被误当成指令执行。

### 安装

1. 把 `wechat-bridge/` 放到一个固定位置
2. 复制 `bridge.config.example.json` → `bridge.config.json`，改里面的四个路径
3. `powershell -File start-all.ps1`，并把它的快捷方式放进启动文件夹

> 仅 Windows：依赖微信 PC 客户端的 UI 自动化。微信必须登录且不要把窗口退出到托盘。
## 安装（其他方式）

```bash
# npm（发布后）
dsh plugin --profile desktop add dsh-plugin-away

# 直接从本仓库
dsh plugin --profile desktop add github:jfzxal-pixel/dsh-plugin-away

# 本地目录
dsh plugin --profile desktop add ./dsh-plugin-away
```

装完重启 DeepSeek Harness，在输入框打 `/away` 即可。

## 插件市场

DSH 的插件市场是**索引制**：用户添加一个索引 URL，市场从那里读 JSON。

本仓库自带一份：`market/index.json`

在「设置 → 插件 → 市场 → 添加索引」填入：

```
https://raw.githubusercontent.com/jfzxal-pixel/dsh-plugin-away/main/market/index.json
```

索引里的 `versions[].source` 目前指向本仓库的某个 commit（Git 源）；发布到 npm 后可改成 `{"type":"npm"}`。

## License

MIT