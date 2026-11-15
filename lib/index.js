/**
 * away-mode — a DeepSeek Harness plugin.
 *
 * Adds `/away` to the composer's slash menu and pushes a notification when a
 * turn finishes while "away mode" is on.
 *
 * The switch lives in a small JSON file so other tools (a desktop checkbox, a
 * phone command) can flip the same bit without talking to this plugin.
 *
 * No runtime dependencies: node builtins only, and the command id is a plain
 * string (the harness's CommandDefinitionId is an identity function).
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

export const name = 'away-mode'
export const inject = ['commands']

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
const STATE_PATH = process.env.DSH_AWAY_STATE || path.join(DSH_HOME, 'away-mode.json')
const LOG_PATH = process.env.DSH_AWAY_LOG || path.join(DSH_HOME, 'away-mode.log')

const ON_WORDS = ['on', '1', 'true', 'yes', '开', '开启', '打开']
const OFF_WORDS = ['off', '0', 'false', 'no', '关', '关闭']
const STATUS_WORDS = ['status', 'state', '状态']

function readState() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8'))
    return { enabled: parsed.enabled === true, updatedAt: parsed.updatedAt }
  } catch {
    return { enabled: false }
  }
}

function writeState(enabled) {
  const state = { enabled, updatedAt: new Date().toISOString() }
  try {
    fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true })
    fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2) + '\n', 'utf8')
  } catch (error) {
    console.error('[away-mode] cannot write state:', error?.message ?? error)
  }
  return state
}

function appendLog(line) {
  try {
    fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true })
    fs.appendFileSync(LOG_PATH, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch { }
}

function previewText(content, limit) {
  if (!Array.isArray(content)) return ''
  let text = ''
  for (const block of content) {
    if (block?.type !== 'text' || typeof block.text !== 'string') continue
    text += (text === '' ? '' : ' ') + block.text
    if (text.length >= limit * 2) break
  }
  const normalized = text.replace(/\s+/g, ' ').trim()
  return normalized.length > limit ? normalized.slice(0, limit).trimEnd() + '…' : normalized
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.round(seconds))
  if (total < 60) return `${total} 秒`
  const minutes = Math.floor(total / 60)
  const rest = total % 60
  if (minutes < 60) return rest ? `${minutes} 分 ${rest} 秒` : `${minutes} 分`
  return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`
}

function sessionTag(session) {
  const id = typeof session?.id === 'string' ? session.id : ''
  const tail = id.slice(-6) || '??????'
  const cwd = typeof session?.cwd === 'string' ? path.basename(session.cwd) : ''
  return cwd ? `${tail}@${cwd}` : tail
}

/**
 * @param ctx - host context carrying the `commands` service.
 * @param config - this row's config: minTurnSeconds, label, debug, notify.*.
 */
export function apply(ctx, config = {}) {
  const settings = {
    minTurnSeconds: Number.isFinite(config.minTurnSeconds) ? config.minTurnSeconds : 90,
    label: typeof config.label === 'string' ? config.label : '离开模式',
    debug: config.debug === true,
    notify: {
      mode: config.notify?.mode === 'command' ? 'command' : 'log',
      command: config.notify?.command ?? '',
      args: Array.isArray(config.notify?.args) ? config.notify.args : [],
    },
  }

  /**
   * Per-session turn state. `session/event` is a global broadcast filtered by
   * each listener, so every live session keeps its own entry here.
   * @type {Map<string, {turn: number, startedAt: number, lastEventAt: number, prompt: string, draft: string, notifiedTurn: number}>}
   */
  const sessions = new Map()

  // Notifications are serialized: two sessions finishing at the same time must
  // not race for the same notifier (one chat window, one input box).
  let notifyChain = Promise.resolve()

  function debug(line) {
    if (settings.debug) appendLog(`[debug] ${line}`)
  }

  function sendNotification(text) {
    notifyChain = notifyChain.then(() => new Promise((resolve) => {
      try {
        if (settings.notify.mode === 'command') {
          const command = settings.notify.command
          if (!command) {
            appendLog('[warn] notify.mode=command but notify.command is empty')
            return resolve()
          }
          const args = (settings.notify.args ?? []).map((arg) =>
            String(arg).split('{{message}}').join(text).split('{{state}}').join(STATE_PATH),
          )
          const child = spawn(command, args, {
            detached: true,
            stdio: 'ignore',
            env: { ...process.env, AWAY_MESSAGE: text, AWAY_STATE: STATE_PATH },
          })
          child.on('error', (error) => appendLog(`[warn] spawn failed: ${error?.message ?? error}`))
          child.unref()
          // Give the notifier a moment before the next one starts.
          setTimeout(resolve, 1500)
          return
        }
        fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true })
        fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${text}\n\n`, 'utf8')
        resolve()
      } catch (error) {
        appendLog(`[warn] notify failed: ${error?.message ?? error}`)
        resolve()
      }
    }))
  }

  ctx.on('session/event', (session, event) => {
    if (!session || typeof session.id !== 'string') return
    const entry = sessions.get(session.id) ?? {
      turn: -1,
      startedAt: 0,
      lastEventAt: 0,
      prompt: '',
      draft: '',
      notifiedTurn: -1,
    }
    entry.lastEventAt = Date.now()

    switch (event?.type) {
      case 'turn/start': {
        entry.turn = event.data?.turn ?? entry.turn + 1
        entry.startedAt = Date.now()
        entry.prompt = ''
        entry.draft = ''
        debug(`turn/start ${sessionTag(session)} turn=${entry.turn}`)
        break
      }
      case 'user/message': {
        if (event.data?.source?.kind !== 'user') break
        const prompt = previewText(event.data?.content, 120)
        if (prompt) entry.prompt = prompt
        break
      }
      case 'assistant/message': {
        const draft = previewText(event.data?.message?.content, 400)
        if (draft) entry.draft = draft
        break
      }
      case 'turn/end': {
        const finishedAt = Date.now()
        const startedAt = entry.startedAt || entry.lastEventAt
        const elapsed = startedAt ? (finishedAt - startedAt) / 1000 : 0
        const away = readState()
        const enough = elapsed >= settings.minTurnSeconds
        const fresh = entry.turn !== entry.notifiedTurn
        const due = away.enabled && enough && fresh

        appendLog(
          `[turn] ${sessionTag(session)} turn=${entry.turn} elapsed=${Math.round(elapsed)}s away=${away.enabled} enough=${enough} fresh=${fresh} -> ${due ? 'SEND' : 'skip'}`,
        )

        if (due) {
          entry.notifiedTurn = entry.turn
          const parts = [
            `⏱ 用时约 ${formatDuration(elapsed)}`,
            entry.prompt ? `📝 你交代的：${entry.prompt}` : '',
            entry.draft ? `✅ 结果：${entry.draft}` : '✅ 已完成（没有输出文本）',
            `🔗 会话 ${sessionTag(session)} · 第 ${entry.turn} 轮`,
            '',
            '——要接着干，直接回我下一步。',
          ].filter(Boolean)
          sendNotification(parts.join('\n'))
        }
        entry.startedAt = 0
        break
      }
      default:
        break
    }
    sessions.set(session.id, entry)
  })

  ctx.commands.register({
    definitionId: 'dsh-plugin-away',
    name: 'away',
    description: `${settings.label}：开启后任务跑完会通知你（/away on | off | status）`,
    input: { hint: '[on|off|status]' },
    recordInput: false,
    handler: (invocation) => {
      const raw = String(invocation?.rawInput ?? '').trim().toLowerCase()
      const current = readState()

      if (raw === '' || raw === 'toggle') {
        const next = writeState(!current.enabled)
        return {
          kind: 'success',
          text: next.enabled
            ? `🌙 ${settings.label}已开启。之后每个超过 ${settings.minTurnSeconds} 秒的任务跑完，都会推送给你。`
            : `☀️ ${settings.label}已关闭。不再推送完成通知。`,
        }
      }
      if (STATUS_WORDS.includes(raw)) {
        return {
          kind: 'success',
          text: current.enabled
            ? `🌙 ${settings.label}：开启中（更新于 ${current.updatedAt ?? '未知'}）`
            : '☀️ 离开模式：已关闭',
        }
      }
      if (ON_WORDS.includes(raw)) {
        writeState(true)
        return {
          kind: 'success',
          text: `🌙 ${settings.label}已开启。之后每个超过 ${settings.minTurnSeconds} 秒的任务跑完，都会推送给你。`,
        }
      }
      if (OFF_WORDS.includes(raw)) {
        writeState(false)
        return { kind: 'success', text: `☀️ ${settings.label}已关闭。` }
      }
      return {
        kind: 'error',
        text: '用法：/away       切换\n      /away on    开启\n      /away off   关闭\n      /away status 查看状态',
      }
    },
  })
}
