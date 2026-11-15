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

## License

MIT

---

## Install

```bash
# from npm (after publish)
dsh plugin --profile desktop add dsh-plugin-away

# from this repository
dsh plugin --profile desktop add github:<your-name>/dsh-plugin-away

# from a local checkout
dsh plugin --profile desktop add ./dsh-plugin-away
```

Then restart DeepSeek Harness and type `/away` in the composer.

## Plugin market

DSH's plugin market is index-based: users add an index URL, then browse.
This repo ships one at `market/index.json`.

Add it in **设置 → 插件 → 市场 → 添加索引**，URL 填：

```
https://raw.githubusercontent.com/<your-name>/dsh-plugin-away/main/market/index.json
```

`market/index.json` 里的 `versions[].source` 用 `{"type":"npm"}`（发布到 npm 后）
或 `{"type":"git","url":"https://github.com/<your-name>/dsh-plugin-away","commit":"<sha>"}`
（不用 npm，直接从 GitHub 装）。

## License

MIT
