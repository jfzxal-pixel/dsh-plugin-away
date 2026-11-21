# 微信 ↔ DeepSeek Harness 桥接

> **2026-11 更新**：任务跑完的「主动通知」已抽成正式插件 `dsh-plugin-away`
> （见 `../packages/dsh-plugin-away`），支持输入框里的 `/away` 命令和桌面浮窗开关。
> 本目录的 `turn-watch.js` 已停用，仅作历史备份；`bridge.ps1`（收消息 → 执行 → 回消息）仍在用。

两个方向都通了：

- **你发指令 → 我执行**（被动）
- **任务跑完 → 我主动告诉你**（主动）

## 一、主动汇报（你要的核心功能）

`turn-watch.js` 每 5 秒读一次 DSH 的会话状态文件（10KB 的 JSON，不是日志），
按「某轮任务的 `response` 由空变非空」判定这一轮真的结束了，然后调 `notify.ps1`
把结果推到你微信。

- 只有**超过 90 秒**的任务才汇报，避免你问一句"现在几点"手机也响。
- 汇报内容：用时 + 你的要求 + 结果摘要 + "要接着干直接回我下一步"。
- 阈值可调：`node turn-watch.js --min-seconds 180`

## 二、发消息给我

手机微信 → 文件传输助手 → 直接发：

```
看下 D 盘还有多少空间
把桌面那个 PPT 转成 PDF
刚才那个报错怎么修
```

会先收到 `【DSH】 收到，开始处理…`，跑完收到结果。
多条会排队；`【DSH】` 开头的消息会被忽略，不会自己回自己。

## 三、两个进程

| 进程 | 作用 | 日志 |
|---|---|---|
| `bridge.ps1` | 收消息、执行、回消息 | `bridge.log` |
| `turn-watch.js` | 任务跑完主动汇报 | `watch.log` |
| `notify.ps1` | 单次主动发消息（可被任意脚本调用） | `notify.log` |

开机自启：`%APPDATA%\...\Startup\DSH-微信桥接.lnk` → `start-all.ps1`（两个一起拉起）

手动启停：

```powershell
# 启动
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "E:\deepseek-harness\default-workspace\wechat-bridge\start-all.ps1"
# 停桥接
Stop-Process -Id (Get-Content "E:\deepseek-harness\default-workspace\wechat-bridge\bridge.lock")
# 停汇报
Get-Process node | Where-Object { $_.Path -like '*node.exe' } | Stop-Process
```

## 四、边界（按你的要求限定）

- **只看「文件传输助手」**：这是你给自己发消息的会话，不读任何其他人的聊天。
- **不碰支付**：桥接只做"读这个会话的文字 / 在这个会话里发文字"，没有别的动作。
- **不对外发言**：不会给任何联系人发消息。

## 五、已知限制

1. **锁屏会断**：发消息要给微信窗口发回车，锁屏时失败。离开时间较长建议关闭自动锁屏。
2. **会抢焦点**：收发时微信窗口会跳到前面。
3. **上下文不是同一个会话**：微信里发的指令由独立的 headless 会话执行，不带桌面会话的对话历史。说清楚要做什么最稳妥；它也能靠工作区里的文件自己判断。
4. 单次任务超时 20 分钟（`bridge.ps1 -TimeoutMin`）。
5. 微信升级可能改界面结构，届时需要重新适配。
6. 任何能操作你微信的人都能通过这个桥在你电脑上执行命令。
