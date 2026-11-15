# 把 dsh-plugin-away 分享给别人

三种方式，从「30 秒」到「最正规」。别人那边只需要一条命令 + 一次重启。

---

## 方式一：发压缩包（最快）

1. 打包（已打好：`dsh-plugin-away-0.1.0.zip`，就在这个目录旁边）。
2. 发给对方，让对方解压到任意位置，比如 `C:\tools\dsh-plugin-away`。
3. 对方执行：

```bash
dsh plugin --profile desktop add C:\tools\dsh-plugin-away
```

4. 重启 DeepSeek Harness，输入框打 `/away`。

> 注意：`add` 传的是**解压出来的目录**（里面要有 `package.json`），不是 zip。

---

## 方式二：发 GitHub（适合给一群人）

```bash
cd dsh-plugin-away
git init
git add .
git commit -m "feat: away mode plugin for DeepSeek Harness"
git branch -M main
git remote add origin https://github.com/<你的用户名>/dsh-plugin-away.git
git push -u origin main
```

对方装：

```bash
dsh plugin --profile desktop add github:<你的用户名>/dsh-plugin-away
```

建议顺手在仓库里加个 `LICENSE`（已有）和一句 `## Install` 说明。
`package.json` 里可以补上 `repository` 字段，npm 页面会显示来源：

```json
"repository": { "type": "git", "url": "git+https://github.com/<你>/dsh-plugin-away.git" }
```

---

## 方式三：发布到 npm（最方便，别人一条命令）

包名 `dsh-plugin-away` 在 npm 上**还没被占用**（已确认）。

```bash
cd dsh-plugin-away
npm login          # 第一次需要
npm publish        # 无 scoped 名字，默认公开
```

对方装：

```bash
dsh plugin --profile desktop add dsh-plugin-away
```

以后更新：改 `version` 再 `npm publish`，对方 `dsh plugin --profile desktop add dsh-plugin-away@latest`。

> 如果发布时报 `403`，多半是名字被抢注了，改个名（比如 `dsh-plugin-away-mode`）并同步改 `package.json` 的 `name`。

---

## 对方装完还要做什么

插件默认**只把通知写进日志**（`$DSH_HOME/away-mode.log`），不会自动发到手机。
要真正收到推送，对方得在自己的 profile 里配一个通知通道 —— README 的「通知通道示例」里有企业微信、Telegram、Bark、ntfy 的现成配置，复制粘贴即可。

Windows 且用微信 PC 客户端的，直接指向 `examples/notify-wechat.ps1` 就行。

---

## 自检清单（发布前）

- [ ] `node --check lib/index.js` 通过
- [ ] `package.json` 的 `name` / `version` / `license` / `engines` 正确
- [ ] `dsh.bundle.patch` 指向的 `cordis.patch.yml` 存在
- [ ] `files` 字段没漏掉 `lib`、`cordis.patch.yml`、`examples`
- [ ] 在一个干净的 profile 里试装过一次（`dsh --profile test --from-default-profile web --dump-config` 能看到 `- id: away-mode`）
