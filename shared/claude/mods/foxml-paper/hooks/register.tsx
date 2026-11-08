import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { PaperFile, PaperLook, PaperRedZone } from '../types'
import { paper } from './theme'

// FoxML paper: a notebook pane beside the chat (hearts, the session's name, its plan, the gate, pages
// touched), a red-zone band before a risky system edit, a few gentle toasts, and paper spinner words.
// Everything here reads; nothing it runs changes a file.

const PANE = 'paper-notebook'
const look = atom({ plugin: 'foxml-paper', key: 'look' } as const, null as PaperLook | null, { shape: 'look-1' })
const title = atom({ plugin: 'foxml-paper', key: 'title' } as const, null as string | null)
const redZone = atom({ plugin: 'foxml-paper', key: 'redZone' } as const, null as PaperRedZone | null, { shape: 'red-1' })

const WORDS = ['Knitting', 'Pressing flowers', 'Baking', 'Stitching', 'Doodling', 'Steeping tea',
  'Folding paper', 'Tending the garden', 'Sketching', 'Tidying up', 'Writing a little note', 'Threading a needle']

// Where a slip can leave a machine unbootable or locked out: login, boot, mounts, the kernel, the firewall.
const RED_PATHS = /(^|[\s'"=])(\/etc\/(pam\.d|fstab|crypttab|greetd|sudoers|mkinitcpio|default\/grub|kernel\/cmdline|sysctl|usbguard|ufw|security)|\/boot\/)/
const RED_TOOLS = /(^|[\s;&|(])(bootctl|efibootmgr|mkinitcpio|grub-mkconfig|ufw|usbguard|sysctl\s+-w|cryptsetup|faillock)\b/
const PRIVILEGED = /(^|[\s;&|(])(sudo|doas|pkexec|run0)\b/
const COMMIT = /(^|[\s;&|(])git\s+(-C\s+\S+\s+)?commit\b(?![^;&|]*--dry-run)/

function redZoneOf(command: string): string | null {
  const path = command.match(RED_PATHS)?.[2]
  if (path !== undefined && PRIVILEGED.test(command)) return path
  return command.match(RED_TOOLS)?.[2]?.split(/\s+/)[0] ?? null
}

// The cat says hello by the hour.
function greeting(hour: number): string {
  if (hour >= 5 && hour < 12) return 'good morning ♡ ᓚᘏᗢ'
  if (hour >= 12 && hour < 18) return 'good afternoon ♡ ᓚᘏᗢ'
  if (hour >= 18 && hour < 23) return 'good evening ♡ ᓚᘏᗢ'
  return 'up late? be gentle with yourself ♡ ᓚᘏᗢ'
}

function hearts(percent: number | null): number {
  return percent === null ? 0 : Math.min(5, Math.floor((percent * 5 + 50) / 100))
}

function clip(text: string, width: number): string {
  if (width <= 1) return ''
  return text.length <= width ? text : '…' + text.slice(text.length - width + 1)
}

async function run($: EngineInterface, argv: string[]): Promise<string | null> {
  try {
    const out = await $.process.run(argv, { timeoutMs: 3000 })
    return out.exitCode === 0 ? out.stdout : null
  } catch {
    return null
  }
}

// What the module remembers between hooks; a reload starts it over, which only costs a missed toast.
const memory = {
  refreshing: false,
  planFile: null as string | null,
  lastHearts: -1,
  lastGate: null as PaperLook['gate'] | null,
}

async function refresh($: EngineInterface) {
  if (memory.refreshing) return
  memory.refreshing = true
  try {
    const cwd = await $.session.cwd()
    const status = await run($, ['git', '-C', cwd, 'status', '--porcelain=v1', '--branch', '--untracked-files=no'])
    const branch = status?.split('\n')[0]?.replace(/^## /, '').replace(/\.\.\..*$/, '').replace(/^No commits yet on /, '') ?? ''
    const files: PaperFile[] = []
    const numstat = status === null ? null : await run($, ['git', '-C', cwd, 'diff', '--numstat', 'HEAD'])
    for (const line of (numstat ?? '').split('\n')) {
      const [added, removed, path] = line.split('\t')
      if (path) files.push({ path, added: Number(added) || 0, removed: Number(removed) || 0 })
    }

    let gate: PaperLook['gate'] = 'none'
    const root = (await $.session.repo())?.root ?? cwd
    try {
      const approved = await $.fs.read(root + '/.claude/.plan-approved')
      const id = await $.session.id()
      gate = approved.split('\n').some(line => line.startsWith(id + ' ') || line === id) ? 'open' : 'closed'
    } catch {
      gate = 'none'
    }

    let plan: PaperLook['plan'] = null
    const planFile = memory.planFile
    if (planFile !== null) {
      try {
        const heading = (await $.fs.read(planFile)).split('\n').find(line => line.startsWith('# '))
        plan = { title: heading ? heading.slice(2).trim() : planFile.split('/').pop() ?? planFile, file: planFile.split('/').pop() ?? planFile }
      } catch {
        plan = null
      }
    }

    const context = (await $.session.usage()).context.percent ?? null
    await update($, look, () => ({ branch, files, gate, plan, context }))

    const left = 5 - hearts(context)
    if (memory.lastHearts > 2 && left === 2) $.ui.toast('two hearts left ♡ wrap up, or write a handoff?')
    memory.lastHearts = left
    if (memory.lastGate === 'closed' && gate === 'open') $.ui.toast('gate open ✓ the plan is approved')
    memory.lastGate = gate
  } catch {
    // A missed refresh only leaves the notebook a little behind; the next one catches up.
  } finally {
    memory.refreshing = false
  }
}

async function beforeEdit($: EngineInterface, file: string) {
  // An edit needs no sudo to count: the path alone says where it lands.
  const what = (' ' + file).match(RED_PATHS)?.[2] ?? null
  if (what !== null) await update($, redZone, () => ({ what }))
  if (/\/plans\/.+\.md$/.test(file)) memory.planFile = file
}

export const register: Register = on => {

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({ name: 'notebook', description: 'Open the paper notebook beside the chat' })
    // Only where someone is looking: a headless run (claude -p) has nowhere to put a pane.
    if (e.isInteractive) {
      void $.ui.open({ id: PANE, title: 'notebook' })
      $.ui.toast(greeting(new Date().getHours()))
    }
    void refresh($)
    $.clock.every(20000, () => void refresh($))
    return started
  })

  on('command.run', { command: 'notebook' }, async $ => {
    const opened = await $.ui.open({ id: PANE, title: 'notebook' })
    await refresh($)
    return { text: opened.isPlaced ? 'The notebook is open.' : 'The notebook will open when there is room.' }
  })

  // Claude Code names each session; the notebook heads with that name.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    if (e.session_title) await update($, title, () => e.session_title ?? null)
    return next(e)
  })
  on('classic.SessionStart', async ($, e, next) => {
    if (e.session_title) await update($, title, () => e.session_title ?? null)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    await update($, redZone, () => null)
    void refresh($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const what = redZoneOf(e.command)
    if (what !== null) await update($, redZone, () => ({ what }))
    const ran = await next(e)
    if (COMMIT.test(e.command) && ran.deny === undefined && ran.isError !== true) $.ui.toast('a seed planted ❦')
    void refresh($)
    return ran
  })

  on('tool.call', { tool: 'Edit' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    const ran = await next(e)
    void refresh($)
    return ran
  })
  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    const ran = await next(e)
    void refresh($)
    return ran
  })

  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    if (/\/plans\/.+\.md$/.test(e.file_path)) memory.planFile = e.file_path
    return next(e)
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.message !== null) return next(e)
    const turn = await $.session.turns()
    let seed = turn
    for (const ch of e.requestId ?? '') seed = (seed * 31 + ch.charCodeAt(0)) >>> 0
    return next({ ...e, props: { ...e.props, word: WORDS[seed % WORDS.length] ?? 'Knitting' } })
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const zone = await read($, redZone)
    if (zone === null || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text color={paper.ribbon} weight="bold">♡ red zone </Text>
        <Text color={paper.ink}>{clip(zone.what, Math.max(8, e.props.bodyColumns - 40))}</Text>
        <Text color={paper.dim}> · brick-safety first </Text>
        <Button key="dismiss" label="ok" plain onPress={() => update($, redZone, () => null)} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const now = await read($, look)
    const name = await read($, title)
    const width = Math.max(12, e.props.bodyColumns)
    const filled = hearts(now?.context ?? null)
    const heartColour = (now?.context ?? 0) >= 80 ? paper.berry : paper.heart
    const room = Math.max(1, (e.props.scroll?.bodyRows ?? 20) - 9)
    const files = now?.files ?? []

    return (
      <Box flexDirection="column">
        <Text>
          <Text color={heartColour}>{'♥'.repeat(filled)}</Text>
          <Text color={paper.note}>{'♡'.repeat(5 - filled)}</Text>
          <Text color={paper.dim}>{now?.context === null || now === null ? '' : ` ${now.context}%`}</Text>
        </Text>
        {name !== null && <Text color={paper.ink} weight="bold">{clip(name, width)}</Text>}
        <Text> </Text>
        <Text color={paper.dim}>the plan</Text>
        <Text color={now?.plan ? paper.ink : paper.note}>{clip(now?.plan?.title ?? 'none read yet', width)}</Text>
        {now?.gate === 'open' && <Text color={paper.ribbon}>gate open ✓</Text>}
        {now?.gate === 'closed' && <Text color={paper.note}>plan first ✎</Text>}
        <Text> </Text>
        <Text color={paper.dim}>{files.length === 0 ? 'no pages touched' : files.length === 1 ? '1 page touched' : `${files.length} pages touched`}</Text>
        {files.slice(0, room).map(file => {
          const counts = `+${file.added} −${file.removed} `
          return (
            <Text>
              <Text color={paper.added}>+{file.added}</Text>
              <Text color={paper.removed}> −{file.removed} </Text>
              <Text color={paper.ink}>{clip(file.path, width - counts.length)}</Text>
            </Text>
          )
        })}
        {files.length > room && <Text color={paper.note}>and {files.length - room} more</Text>}
        {now !== null && now.branch !== '' && <Text color={paper.note}>{clip('⎇ ' + now.branch, width)}</Text>}
      </Box>
    )
  })
}
