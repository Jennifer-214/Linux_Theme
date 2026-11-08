import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { PaperCard, PaperEnvelope, PaperFile, PaperLook, PaperOverlap, PaperPeer, PaperRedZone, PaperTone } from '../types'
import { addBefore, addEdit, addName, neighbours, namesText, noteText, overlapFor, parseLedger, parseNames, parseNote, trailerUrl, withPlan } from './ledger'
import type { Other } from './ledger'
import { paper } from './theme'

// FoxML paper: a notebook pane beside the chat (hearts, the session's name, its plan, the gate, pages
// touched, the other Claudes with [go] and [note]), a red-zone band before a risky system edit, a band when
// another live session edited the same file lately, notes as envelopes (from nvim's inbox, or another Claude), a
// few gentle toasts, and paper spinner words. It writes only this session's own files in the private runtime folder
// ($XDG_RUNTIME_DIR/foxml-claude: edits/<session>.json, edits/<session>/before/, and its inbox notes, removed once
// delivered) and the commit names in $XDG_STATE_HOME/foxml/claude-sessions.jsonl.

const PANE = 'paper-notebook'
const look = atom({ plugin: 'foxml-paper', key: 'look' } as const, null as PaperLook | null, { shape: 'look-2' })
const title = atom({ plugin: 'foxml-paper', key: 'title' } as const, null as string | null)
const redZone = atom({ plugin: 'foxml-paper', key: 'redZone' } as const, null as PaperRedZone | null, { shape: 'red-1' })
const overlap = atom({ plugin: 'foxml-paper', key: 'overlap' } as const, null as PaperOverlap | null, { shape: 'overlap-1' })
const peers = atom({ plugin: 'foxml-paper', key: 'peers' } as const, [] as PaperPeer[], { shape: 'peers-1' })
const writingTo = atom({ plugin: 'foxml-paper', key: 'writingTo' } as const, null as string | null)
const envelopes = atom({ plugin: 'foxml-paper', key: 'envelopes' } as const, [] as PaperEnvelope[], { shape: 'env-1' })
const SID = /^[A-Za-z0-9_-]{1,80}$/

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
  runtime: undefined as string | null | undefined,
  pane: undefined as string | null | undefined,
  // file → when Claude was last told about it, so each overlap is said once.
  noted: new Map<string, number>(),
  // fox-drawer answered: the peers list replaces "also in this repo".
  peersKnown: false,
  state: undefined as string | null | undefined,
  inboxBusy: false,
  delivered: new Set<string>(),
}

// $XDG_STATE_HOME/foxml: what outlives a reboot (the commit names).
async function stateDir($: EngineInterface): Promise<string | null> {
  if (memory.state !== undefined) return memory.state
  const out = await run($, ['sh', '-c', 'printf %s "${XDG_STATE_HOME:-$HOME/.local/state}"'])
  memory.state = out !== null && out.startsWith('/') ? out + '/foxml' : null
  return memory.state
}

// Repos listed in ~/.config/foxml/claude-private-repos (one root per line) get no before-copies.
async function isPrivate($: EngineInterface, root: string): Promise<boolean> {
  const out = await run($, ['sh', '-c', 'cat "${XDG_CONFIG_HOME:-$HOME/.config}/foxml/claude-private-repos" 2>/dev/null; true'])
  return (out ?? '').split('\n').map(l => l.trim().replace(/\/+$/, '')).some(l => l !== '' && !l.startsWith('#') && l === root)
}

// $XDG_RUNTIME_DIR/foxml-claude, where the hooks keep each session's state; null without one.
async function sessionsDir($: EngineInterface): Promise<string | null> {
  if (memory.runtime !== undefined) return memory.runtime
  const out = await run($, ['sh', '-c', 'printf %s "$XDG_RUNTIME_DIR"'])
  memory.runtime = out !== null && out.startsWith('/') ? out + '/foxml-claude' : null
  return memory.runtime
}

// The tmux pane this session runs in, as Claude Code's peer list shows it (%N); null outside tmux.
async function ownPane($: EngineInterface): Promise<string | null> {
  if (memory.pane !== undefined) return memory.pane
  const out = await run($, ['sh', '-c', 'printf %s "$TMUX_PANE"'])
  memory.pane = out !== null && /^%[0-9]{1,6}$/.test(out) ? out : null
  return memory.pane
}

async function realPath($: EngineInterface, file: string): Promise<string> {
  try {
    return (await $.fs.stat(file, { resolve: true })).realPath ?? file
  } catch {
    return file  // a file about to be created
  }
}

async function readOthers($: EngineInterface, dir: string): Promise<Other[]> {
  const others: Other[] = []
  try {
    for (const entry of await $.fs.list(dir + '/edits')) {
      const sid = entry.name.replace(/\.json$/, '')
      if (entry.kind !== 'file' || sid === entry.name || !/^[A-Za-z0-9_-]{1,80}$/.test(sid)) continue
      try {
        const ledger = parseLedger(await $.fs.read(`${dir}/edits/${entry.name}`))
        if (ledger !== null) others.push({ sid, ledger, live: await $.fs.exists(`${dir}/${sid}.state`) })
      } catch {
        // a ledger mid-write or gone: skip it this time
      }
    }
  } catch {
    // no edits folder yet
  }
  return others
}

async function repoRoot($: EngineInterface): Promise<string> {
  return (await $.session.repo())?.root ?? (await $.session.cwd())
}

// Before an edit: has another live session edited this file lately? Band for you, a note for Claude, once.
async function checkOverlap($: EngineInterface, file: string) {
  const dir = await sessionsDir($)
  if (dir === null) return
  const path = await realPath($, file)
  const found = overlapFor(path, await $.clock.now(), await $.session.id(), await readOthers($, dir))
  if (found === null) return
  await update($, overlap, () => found)
  const now = await $.clock.now()
  const told = memory.noted.get(path)
  if (told !== undefined && now - told < 15 * 60 * 1000) return
  memory.noted.set(path, now)
  await $.session.append({
    message: {
      type: 'user',
      content: [{
        type: 'text',
        text: `(foxml-paper) Another active Claude session, "${found.title}"`
          + (found.pane ? ` (running in tmux pane ${found.pane})` : '') + `, edited ${path} ${found.ago}. `
          + 'Coordinate with the active session that last edited it before changing it further: message it if you '
          + 'can reach it (ListAgents shows each peer\'s tmux pane; then SendMessage), or read its changes first, '
          + 'so neither of you overwrites the other.',
      }],
    },
  }).catch(() => undefined)
}

// Before this session's first edit of a file that already has uncommitted changes, keep it as it was, so a review
// can show only this session's part. A clean file needs no copy: its before is HEAD.
async function keepBefore($: EngineInterface, file: string) {
  const dir = await sessionsDir($)
  const sid = await $.session.id()
  if (dir === null || !SID.test(sid)) return
  const path = await realPath($, file)
  const own = `${dir}/edits/${sid}.json`
  let ledger = null
  try { ledger = parseLedger(await $.fs.read(own)) } catch { ledger = null }
  if (ledger?.all?.some(e => e.path === path) || ledger?.before?.[path]) return
  const root = await repoRoot($)
  if (await isPrivate($, root)) return
  let size = 0
  try { size = (await $.fs.stat(path)).size } catch { return }  // a new file: nothing came before it
  if (size > 1024 * 1024) return
  const folder = path.slice(0, path.lastIndexOf('/')) || '/'
  const status = await run($, ['git', '--no-optional-locks', '-C', folder, 'status', '--porcelain=v1', '--', path])
  if (status === null || status.trim() === '') return
  const text = await $.fs.read(path)
  if (text.includes('\u0000')) return
  const { ledger: next, copy } = addBefore(ledger, path, root)
  await $.fs.write(`${dir}/edits/${sid}/before/${copy}`, text)
  await $.fs.write(own, JSON.stringify(next) + '\n')
}

// The plan this session reads or writes, in its ledger, so nvim's :Plan can open it.
async function notePlan($: EngineInterface, file: string) {
  if (memory.planFile === file) return
  memory.planFile = file
  const dir = await sessionsDir($)
  const sid = await $.session.id()
  if (dir === null || !SID.test(sid)) return
  const own = `${dir}/edits/${sid}.json`
  let ledger = null
  try { ledger = parseLedger(await $.fs.read(own)) } catch { ledger = null }
  await $.fs.write(own, JSON.stringify(withPlan(ledger, await realPath($, file), await $.clock.now(), await repoRoot($))) + '\n')
}

// After a commit lands: which session made it, by its Claude-Session trailer, so nvim can name it.
async function nameCommit($: EngineInterface, command: string) {
  const where = command.match(/git\s+-C\s+(\S+)\s+commit/)?.[1]?.replace(/^['"]|['"]$/g, '') ?? (await $.session.cwd())
  const out = await run($, ['git', '--no-optional-locks', '-C', where, 'log', '-1', '--format=%ct%x00%B'])
  if (out === null) return
  const [stamp, body] = out.split('\u0000')
  const now = await $.clock.now()
  if (now / 1000 - Number(stamp) > 300) return  // not the commit just made
  const url = trailerUrl(body ?? '')
  const state = await stateDir($)
  if (url === null || state === null) return
  const name = (await read($, title)) ?? (await repoRoot($)).split('/').filter(Boolean).pop() ?? 'Claude'
  const file = `${state}/claude-sessions.jsonl`
  let names = parseNames('')
  try { names = parseNames(await $.fs.read(file)) } catch { names = [] }
  if (names.some(n => n.url === url && n.title === name)) return
  await $.fs.write(file, namesText(addName(names, url, name, now)))
  await run($, ['chmod', '600', file])
}

// Notes nvim leaves for this session: each shows as an envelope and goes to Claude as your words.
async function checkInbox($: EngineInterface) {
  if (memory.inboxBusy) return
  memory.inboxBusy = true
  try {
    const dir = await sessionsDir($)
    const sid = await $.session.id()
    if (dir === null || !SID.test(sid)) return
    const box = `${dir}/inbox/${sid}`
    let entries: { name: string; kind: string }[] = []
    try { entries = await $.fs.list(box) } catch { return }
    const notes = entries.filter(e => e.kind === 'file' && /^[A-Za-z0-9_-]{1,80}\.json$/.test(e.name)).map(e => e.name).sort()
    for (const name of notes) {
      const path = `${box}/${name}`
      let note = null
      try { note = parseNote(await $.fs.read(path)) } catch { note = null }
      await run($, ['rm', '-f', '--', path])
      if (memory.delivered.has(name)) continue
      memory.delivered.add(name)
      if (note === null) continue
      const at = await $.clock.now()
      const text = note.text
      await update($, envelopes, list => [{ from: 'you, in nvim', text, at }, ...list].slice(0, 5))
      void $.prompt.submit({ text: noteText(note), asUser: true }).catch(() => undefined)
    }
  } finally {
    memory.inboxBusy = false
  }
}

// After an edit: note it in this session's ledger, for the other sessions to see.
async function recordEdit($: EngineInterface, file: string) {
  const dir = await sessionsDir($)
  if (dir === null) return
  const sid = await $.session.id()
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(sid)) return
  const own = `${dir}/edits/${sid}.json`
  let ledger = null
  try { ledger = parseLedger(await $.fs.read(own)) } catch { ledger = null }
  const next = addEdit(ledger, await realPath($, file), await $.clock.now(), await read($, title), await repoRoot($),
                       (await ownPane($)) ?? undefined)
  await $.fs.write(own, JSON.stringify(next) + '\n')
}

async function readCard($: EngineInterface, dir: string | null): Promise<PaperCard | null> {
  if (dir === null) return null
  try {
    const card = JSON.parse(await $.fs.read(`${dir}/cards/${await $.session.id()}.json`)) as PaperCard
    return card && typeof card.title === 'string' && Array.isArray(card.rows) ? card : null
  } catch {
    return null
  }
}

// The other live Claudes, from fox-drawer (one liveness rule for the drawer and the notebook); null without it.
async function readPeers($: EngineInterface): Promise<PaperPeer[] | null> {
  const out = await run($, ['fox-drawer', 'claude-peers'])
  if (out === null) return null
  try {
    const self = await $.session.id()
    const list = JSON.parse(out) as PaperPeer[]
    return Array.isArray(list)
      ? list.filter(p => p && typeof p.id === 'string' && p.id !== self && typeof p.name === 'string').slice(0, 6)
      : null
  } catch {
    return null
  }
}

async function goTo($: EngineInterface, peer: PaperPeer) {
  const out = await run($, ['fox-drawer', 'run', 'claude-jump', peer.pane])
  if (out === null) $.ui.toast(`couldn't reach ${peer.name}'s window`)
}

async function sendNote($: EngineInterface, peer: PaperPeer, text: string) {
  const note = text.trim()
  await update($, writingTo, () => null)
  if (note === '') return
  const me = (await read($, title)) ?? 'another session'
  try {
    const sent = await $.session.send({ to: { sessionId: peer.id }, text: `✉ from ${me}: ${note}` })
    $.ui.toast(sent.isDelivered ? `note left for ${peer.name} ♡` : `not sent: ${sent.reason}`)
  } catch {
    $.ui.toast(`not sent: ${peer.name} isn't taking notes`)
  }
}

function peerMark(peer: PaperPeer): [string, string] {
  if (peer.state === 'needs you') return ['♥', paper.berry]
  if (peer.busy) return ['✎', paper.dim]
  return ['♡', paper.ink]
}

function toneColour(tone: PaperTone | undefined): string {
  return tone === undefined ? paper.ink : paper[tone === 'heart' ? 'heart' : tone]
}

async function refresh($: EngineInterface) {
  if (memory.refreshing) return
  memory.refreshing = true
  try {
    const cwd = await $.session.cwd()
    // --no-optional-locks: never take the index lock another session's commit may need.
    const status = await run($, ['git', '--no-optional-locks', '-C', cwd, 'status', '--porcelain=v1', '--branch', '--untracked-files=no'])
    const branch = status?.split('\n')[0]?.replace(/^## /, '').replace(/\.\.\..*$/, '').replace(/^No commits yet on /, '') ?? ''
    const files: PaperFile[] = []
    const numstat = status === null ? null : await run($, ['git', '--no-optional-locks', '-C', cwd, 'diff', '--numstat', 'HEAD'])
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
    const dir = await sessionsDir($)
    const near = dir === null ? [] : neighbours(root, await $.clock.now(), await $.session.id(), await readOthers($, dir))
    const card = await readCard($, dir)
    await update($, look, () => ({ branch, files, gate, plan, context, neighbours: near, card }))
    const found = await readPeers($)
    await update($, peers, () => found ?? [])
    memory.peersKnown = found !== null

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
  if (/\/plans\/.+\.md$/.test(file)) await notePlan($, file).catch(() => undefined)
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
    $.clock.every(5000, () => void checkInbox($))
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
    await update($, overlap, () => null)
    void refresh($)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const what = redZoneOf(e.command)
    if (what !== null) await update($, redZone, () => ({ what }))
    const ran = await next(e)
    if (COMMIT.test(e.command) && ran.deny === undefined && ran.isError !== true) {
      $.ui.toast('a seed planted ❦')
      await nameCommit($, e.command).catch(() => undefined)
    }
    void refresh($)
    return ran
  })

  // Another Claude's message: an envelope in the notebook; delivering it stays the engine's.
  on('session.receive', async ($, e, next) => {
    if (e.origin.kind === 'peer' || e.origin.kind === 'peer-send-message') {
      const first = e.text.split('\n').find(line => line.trim() !== '')?.trim() ?? ''
      const from = first.match(/^✉ from (.{1,60}?): /)?.[1] ?? 'another Claude'
      const text = first.replace(/^✉ from .{1,60}?: /, '').slice(0, 200)
      const at = await $.clock.now()
      if (text !== '') await update($, envelopes, list => [{ from, text, at }, ...list].slice(0, 5))
    }
    return next(e)
  })

  on('tool.call', { tool: 'Edit' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    await checkOverlap($, e.file_path).catch(() => undefined)
    await keepBefore($, e.file_path).catch(() => undefined)
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) await recordEdit($, e.file_path).catch(() => undefined)
    void refresh($)
    return ran
  })
  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    await checkOverlap($, e.file_path).catch(() => undefined)
    await keepBefore($, e.file_path).catch(() => undefined)
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) await recordEdit($, e.file_path).catch(() => undefined)
    void refresh($)
    return ran
  })

  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    if (/\/plans\/.+\.md$/.test(e.file_path)) await notePlan($, e.file_path).catch(() => undefined)
    return next(e)
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.message !== null) return next(e)
    const turn = await $.session.turns()
    let seed = turn
    for (const ch of e.requestId ?? '') seed = (seed * 31 + ch.charCodeAt(0)) >>> 0
    return next({ ...e, props: { ...e.props, word: WORDS[seed % WORDS.length] ?? 'Knitting' } })
  })

  // One band at a time: the red zone first, then a card's alert, then another session's recent edit.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const zone = await read($, redZone)
    if (zone !== null) return (
      <Box>
        <Text color={paper.ribbon} weight="bold">♡ red zone </Text>
        <Text color={paper.ink}>{clip(zone.what, Math.max(8, e.props.bodyColumns - 40))}</Text>
        <Text color={paper.dim}> · brick-safety first </Text>
        <Button key="dismiss" label="ok" plain onPress={() => update($, redZone, () => null)} />
      </Box>
    )
    const alert = (await read($, look))?.card?.alert
    if (alert) return (
      <Box>
        <Text color={toneColour(alert.tone ?? 'berry')} weight="bold">♡ {clip(alert.text, Math.max(8, e.props.bodyColumns - 4))}</Text>
      </Box>
    )
    const other = await read($, overlap)
    if (other !== null) {
      const name = other.path.split('/').pop() ?? other.path
      return (
        <Box>
          <Text color={paper.ribbon} weight="bold">♡ coordinate with the active session that last edited </Text>
          <Text color={paper.ink}>{clip(name, 40)}</Text>
          <Text color={paper.dim}> · {clip(other.title, Math.max(8, e.props.bodyColumns - 100))}{other.pane ? ` (pane ${other.pane})` : ''}, {other.ago} </Text>
          <Button key="seen" label="ok" plain onPress={() => update($, overlap, () => null)} />
        </Box>
      )
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Input, Text } = $.ui.resolve(e)
    const now = await read($, look)
    const others = await read($, peers)
    const mail = await read($, envelopes)
    const writingId = await read($, writingTo)
    const writing = others.find(p => p.id === writingId) ?? null
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
          {mail.length > 0 && <Text color={paper.ribbon}>{`  ✉ ${mail.length}`}</Text>}
        </Text>
        {name !== null && <Text color={paper.ink} weight="bold">{clip(name, width)}</Text>}
        {mail.map((note, i) => (
          <Box flexDirection="column">
            <Text color={paper.ribbon}>{clip(`✉ from ${note.from}`, width)}</Text>
            <Box>
              <Text color={paper.ink}>{clip(`  ${note.text}`, Math.max(4, width - 5))} </Text>
              <Button key={`envelope-${note.at}-${i}`} label="ok" plain
                onPress={() => void update($, envelopes, list => list.filter((_, j) => j !== i))} />
            </Box>
          </Box>
        ))}
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
        {others.length > 0 && <Text> </Text>}
        {others.length > 0 && <Text color={paper.dim}>other claudes</Text>}
        {others.map(peer => {
          const [mark, colour] = peerMark(peer)
          const here = now?.neighbours.find(n => n.sid === peer.id)
          const where = peer.name === peer.project ? '' : ` · ${peer.project}`
          return (
            <Box flexDirection="column">
              <Text>
                <Text color={colour}>{mark} </Text>
                <Text color={paper.ink}>{clip(`${peer.name}${where}`, width - 2)}</Text>
              </Text>
              <Text color={paper.note}>{clip(`  ${peer.state}${here ? ` · editing ${here.files} ${here.files === 1 ? 'file' : 'files'} here` : ''}`, width)}</Text>
              {writing?.id !== peer.id && (
                <Box>
                  <Text>  </Text>
                  {peer.pane !== '' && <Button key={`go-${peer.id}`} label="go" plain onPress={() => void goTo($, peer)} />}
                  {peer.pane !== '' && <Text> </Text>}
                  <Button key={`note-${peer.id}`} label="note" plain onPress={() => {
                    void update($, writingTo, () => peer.id).then(() => $.ui.focus({ requestId: PANE, key: 'peer-note' })).catch(() => undefined)
                  }} />
                </Box>
              )}
              {writing?.id === peer.id && (
                <Box flexDirection="column">
                  <Input key="peer-note" placeholder={`a note for ${clip(peer.name, 20)}`} submitLabel="send" autoFocus
                    onSubmit={value => void sendNote($, peer, value)} />
                  <Box>
                    <Text>  </Text>
                    <Button key="peer-cancel" label="never mind" plain onPress={() => void update($, writingTo, () => null)} />
                  </Box>
                </Box>
              )}
            </Box>
          )
        })}
        {!memory.peersKnown && (now?.neighbours.length ?? 0) > 0 && <Text> </Text>}
        {!memory.peersKnown && (now?.neighbours.length ?? 0) > 0 && <Text color={paper.dim}>also in this repo</Text>}
        {(memory.peersKnown ? [] : now?.neighbours ?? []).map(n => (
          <Text color={paper.ink}>{clip(`${n.title} · ${n.files} ${n.files === 1 ? 'file' : 'files'}`, width)}</Text>
        ))}
        {now?.card && <Text> </Text>}
        {now?.card && <Text color={paper.dim}>{clip(now.card.title, width)}</Text>}
        {(now?.card?.rows ?? []).slice(0, 12).map(row => (
          <Text color={toneColour(row.tone)}>{clip(`${row.mark ? row.mark + ' ' : ''}${row.text}`, width)}</Text>
        ))}
      </Box>
    )
  })
}
