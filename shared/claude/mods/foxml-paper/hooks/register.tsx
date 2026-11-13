import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderNode } from 'claude-code'

import type { AgentSession, ApiCredits, CiLook, GitLook, NotebookView, PaperAction, PaperCard, PaperEnvelope, PaperLook, PaperOverlap, PaperPeer, PaperRedZone, PaperTone, PaperTree, TurnLook, TurnReceipt, WorkJob } from '../types'
import { addBefore, addEdit, addName, neighbours, namesText, noteText, overlapFor, parseLedger, parseNames, parseNote, trailerUrl, withPlan, editedSince } from './ledger'
import type { Other } from './ledger'
import { paper } from './theme'
import { ago, beginArgs, branchLabel, canTrack, ciLabel, exitOf, greenAgain, jobPace, outputOf, parseBranchLine, filterFiles, pendingLine, planProgress, receiptLine, reviewStates, reviewSummary, ruleLine, ruler, spread, workName, wrapWords, stepLabel, testLabel, turnLabel, unreviewed, work, workLook } from './work'
import { attributeFiles, fileColumns, fileCounts, gitFiles, drawerPage, mailId, shortPath } from './notebook'
import { BUILD_ID } from './build'

// Linux_Theme paper: a notebook pane beside the chat (hearts, the session's name, its plan, the gate, pages
// touched, the other Claudes with [go] and [note]), a red-zone band before a risky system edit, a band when
// another live session edited the same file lately, notes as envelopes (from nvim's inbox, or another Claude), a
// few gentle toasts, and paper spinner words. It writes only this session's own files in the private runtime folder
// ($XDG_RUNTIME_DIR/foxml-claude: edits/<session>.json, edits/<session>/before/, and its inbox notes, removed once
// delivered) and the commit names in $XDG_STATE_HOME/foxml/claude-sessions.jsonl.

const PANE = 'paper-notebook'
const look = atom({ plugin: 'foxml-paper', key: 'look' } as const, null as PaperLook | null, { shape: 'look-3' })
const title = atom({ plugin: 'foxml-paper', key: 'title' } as const, null as string | null)
const redZone = atom({ plugin: 'foxml-paper', key: 'redZone' } as const, null as PaperRedZone | null, { shape: 'red-1' })
const overlap = atom({ plugin: 'foxml-paper', key: 'overlap' } as const, null as PaperOverlap | null, { shape: 'overlap-1' })
const peers = atom({ plugin: 'foxml-paper', key: 'peers' } as const, [] as PaperPeer[], { shape: 'peers-1' })
const writingTo = atom({ plugin: 'foxml-paper', key: 'writingTo' } as const, null as string | null)
const turn = atom({ plugin: 'foxml-paper', key: 'turn' } as const, null as TurnLook | null, { shape: 'turn-1' })
const nudge = atom({ plugin: 'foxml-paper', key: 'nudge' } as const, null as number | null)
const receipt = atom({ plugin: 'foxml-paper', key: 'receipt' } as const, null as TurnReceipt | null, { shape: 'receipt-2' })
const envelopes = atom({ plugin: 'foxml-paper', key: 'envelopes' } as const, [] as PaperEnvelope[], { shape: 'env-1' })
const notebookView = atom({ plugin: 'foxml-paper', key: 'notebookView' } as const,
  { page: 'overview', scope: 'session', selected: '', offset: 0, form: 'none' } as NotebookView, { shape: 'notebook-1' })
const SID = /^[A-Za-z0-9_-]{1,80}$/
const autoCompact = (columns: number) => columns < 144
const paneSize = (view: NotebookView) => view.compact && view.page === 'overview' && view.form === 'none'
  ? { rows: 4, columns: 30 } : { rows: view.page === 'overview' && view.form === 'none' ? 10 : 22, columns: 42 }

const WORDS = ['Reading', 'Checking', 'Tracing', 'Writing', 'Reviewing', 'Working']

// Where a slip can leave a machine unbootable or locked out: login, boot, mounts, the kernel, the firewall.
// The list is ~/.config/foxml/redzone.json (shared/redzone.json), the same file the review's risk marks read; this
// copy only stands in when that file is missing (tests/test_redzone.py keeps the two the same).
const RED_DEFAULT = {
  paths: ['/etc/pam.d', '/etc/fstab', '/etc/crypttab', '/etc/greetd', '/etc/sudoers', '/etc/mkinitcpio', '/etc/default/grub',
    '/etc/kernel/cmdline', '/etc/sysctl', '/etc/usbguard', '/etc/ufw', '/etc/security', '/boot/'],
  tools: ['bootctl', 'efibootmgr', 'mkinitcpio', 'grub-mkconfig', 'ufw', 'usbguard', 'sysctl -w', 'cryptsetup', 'faillock'],
}
const escaped = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ /g, '\\s+')
function redRules(list: { paths: string[]; tools: string[] }) {
  return {
    paths: new RegExp(`(^|[\\s'"=])(${list.paths.map(escaped).join('|')})`),
    tools: new RegExp(`(^|[\\s;&|(])(${list.tools.map(escaped).join('|')})\\b`),
  }
}
let red = redRules(RED_DEFAULT)
async function loadRedZone($: EngineInterface) {
  try {
    const home = (await run($, ['sh', '-c', 'printf %s "${XDG_CONFIG_HOME:-$HOME/.config}"'])) ?? ''
    const listed = JSON.parse(await $.fs.read(home + '/foxml/redzone.json')) as { paths?: unknown; tools?: unknown }
    const strings = (v: unknown) => Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string' && s !== '' && s.length < 200) : []
    const paths = strings(listed.paths), tools = strings(listed.tools)
    red = redRules({ paths: paths.length ? paths : RED_DEFAULT.paths, tools: tools.length ? tools : RED_DEFAULT.tools })
  } catch { red = redRules(RED_DEFAULT) }
}
const PRIVILEGED = /(^|[\s;&|(])(sudo|doas|pkexec|run0)\b/
const PUSH = /(^|[\s;&|(])git\s+(-C\s+\S+\s+)?push\b(?![^;&|]*--dry-run)/
const COMMIT = /(^|[\s;&|(])git\s+(-C\s+\S+\s+)?commit\b(?![^;&|]*--dry-run)/

function redZoneOf(command: string): string | null {
  const path = command.match(red.paths)?.[2]
  if (path !== undefined && PRIVILEGED.test(command)) return path
  return command.match(red.tools)?.[2]?.split(/\s+/)[0] ?? null
}

// A short greeting by the hour.
function greeting(hour: number): string {
  if (hour >= 5 && hour < 12) return 'good morning'
  if (hour >= 12 && hour < 18) return 'good afternoon'
  if (hour >= 18 && hour < 23) return 'good evening'
  return 'working late'
}

// One colour for a test result wherever it shows: berry for any failure, note when stale, green when it holds.
function testColour(test: { state: string; stale?: boolean; tests: { failed: number | null } }): string {
  return (test.tests.failed ?? 0) > 0 || test.state === 'failed' || test.state === 'interrupted' ? paper.berry : test.stale ? paper.note : paper.added
}

function hearts(percent: number | null): number {
  return percent === null ? 0 : Math.min(5, Math.floor((percent * 5 + 50) / 100))
}

// Paths keep their end (the file name); words keep their start.
function fit(label: string, width: number): string {
  if (width < 2) return ''
  if (label.length <= width) return label
  return /^\S*\/\S*$/.test(label.trim()) ? shortPath(label, width) : label.slice(0, width - 1).trimEnd() + '…'
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
  refreshTask: null as Promise<void> | null,
  planFile: null as string | null,
  pinnedFile: null as string | null,
  lastHearts: -1,
  lastGate: null as PaperLook['gate'] | null,
  runtime: undefined as string | null | undefined,
  pane: undefined as string | null | undefined,
  // The one name for this session's work (workName), and the one last written to the pane's @work label.
  work: null as string | null,
  workLabel: null as string | null,
  // file → when Claude was last told about it, so each overlap is said once.
  noted: new Map<string, number>(),
  state: undefined as string | null | undefined,
  inboxBusy: false,
  delivered: new Set<string>(),
  receipts: new Map<string, number>(),
  receiptsReady: null as Promise<void> | null,
  toldLastNight: false,
  // CI is asked of GitHub only when the pushed commit changes, every 30 s while it runs, else every 5 minutes.
  turnRisk: [] as string[],
  turnStart: 0,
  // When the notebook last read everything, and whether the newest attempt failed: so a stale page says so.
  lookAt: 0,
  lookFailed: false,
  refreshAgain: false,
  watchStarted: false,
  watchFailed: false,
  watchRetryAt: 0,
  watchDelay: 1000,
  viewportColumns: 0,
  resizePending: false,
  notebookOpen: false,
  // Every path this turn edited, however often it was edited before: the receipt's first source.
  turnFiles: [] as string[],
  ci: null as CiLook | null,
  ciTold: '',
  github: new Map<string, boolean>(),
}

// No delivery id is exposed for peers. Coalesce identical full bodies briefly;
// a later identical note is allowed to be a new message.
const MAIL_RETRY_MS = 15 * 60 * 1000
function loadReceipts($: EngineInterface): Promise<void> {
  if (memory.receiptsReady === null) memory.receiptsReady = (async () => {
    try {
      const saved = await $.store.get('notebook-read-mail:' + await $.session.id())
      const now = await $.clock.now()
      if (Array.isArray(saved)) for (const item of saved)
        if (item && typeof item.id === 'string' && typeof item.at === 'number' && now - item.at < MAIL_RETRY_MS)
          memory.receipts.set(item.id, item.at)
    } catch { /* dismissal still works in this session without the store */ }
  })()
  return memory.receiptsReady
}

async function receiveEnvelope($: EngineInterface, note: PaperEnvelope, identity = note.text) {
  await loadReceipts($)
  const id = note.id ?? await mailId(note.from, identity)
  const dismissed = memory.receipts.get(id)
  if (dismissed !== undefined && note.at - dismissed < MAIL_RETRY_MS) return
  await update($, envelopes, list => [{ ...note, id }, ...list.filter(n => n.id !== id)].slice(0, 20))
}

async function acknowledgeMail($: EngineInterface, notes: PaperEnvelope[]) {
  await loadReceipts($)
  const ids = new Set(await Promise.all(notes.map(n => n.id ? Promise.resolve(n.id) : mailId(n.from, n.text))))
  const now = await $.clock.now()
  for (const id of ids) memory.receipts.set(id, now)
  // Await the state write: a callback that returns first can lose its work when
  // the engine ends that press. Identity, not a rendered array index, selects it.
  await update($, envelopes, list => list.filter(n => !ids.has(n.id ?? '') && !notes.some(old => !n.id && old.from === n.from && old.text === n.text && old.at === n.at)))
  const receipts = [...memory.receipts].filter(([, at]) => now - at < MAIL_RETRY_MS).slice(-128).map(([id, at]) => ({ id, at }))
  try { await $.store.set('notebook-read-mail:' + await $.session.id(), receipts) }
  catch { $.ui.toast('Notes cleared. Could not save the read markers for a reload.') }
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

// The session's one name: the work in hand once a refresh has seen the plan, else Claude's own title.
async function nameNow($: EngineInterface): Promise<string | null> { return memory.work ?? await read($, title) }
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

// /goodnight leaves $XDG_STATE_HOME/foxml/goodnight/<repo folder>.md; it waits for the next session for a day and a half.
const LAST_NIGHT_MS = 36 * 3600 * 1000
async function lastNight($: EngineInterface, root: string): Promise<PaperLook['lastNight']> {
  const state = await stateDir($)
  const name = root.split('/').filter(Boolean).pop()
  if (state === null || !name) return null
  const file = `${state}/goodnight/${name}.md`
  try {
    const stat = await $.fs.stat(file)
    if (stat.kind !== 'file' || (await $.clock.now()) - stat.mtimeMs > LAST_NIGHT_MS) return null
    const first = (await $.fs.read(file)).split('\n').map(l => l.replace(/^[\s#>*-]+/, '').trim()).find(l => l !== '') ?? ''
    return { file, line: first.slice(0, 200) }
  } catch {
    return null
  }
}

async function withActivity<T>($: EngineInterface, text: string, call: () => Promise<T>): Promise<T> {
  const args = ['activity', '--root', await repoRoot($), '--session', await $.session.id(), '--text', text]
  await work($, [...args, '--state', 'working'])
  try { return await call() }
  finally { await work($, [...args, '--state', 'done']) }
}

// Before an edit: has another live session edited this file lately? Band for you, a note for Claude, once.
async function checkOverlap($: EngineInterface, file: string) {
  const dir = await sessionsDir($)
  const path = await realPath($, file)
  let found = null as PaperOverlap | null
  const shared = await work($, ['overlaps', '--root', await repoRoot($), '--file', path, '--agent', 'claude', '--session', await $.session.id()])
  if (shared !== null) {
    try {
      const first = JSON.parse(shared)?.[0]
      if (first && typeof first.name === 'string') found = { path, title: `${first.agent} · ${first.name}`,
        ago: ago((await $.clock.now()) / 1000 - first.at), ...(first.pane ? { pane: first.pane } : {}) }
    } catch { /* an older backend can use the old adapter */ }
  } else if (dir !== null) found = overlapFor(path, await $.clock.now(), await $.session.id(), await readOthers($, dir))
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
        text: `(foxml-paper) Another active agent session, "${found.title}"`
          + (found.pane ? ` (running in tmux pane ${found.pane})` : '') + `, edited ${path} ${found.ago}. `
          + 'Coordinate with that session before changing it further: use messaging only when that agent supports it, or read its changes first, '
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
  if (memory.pinnedFile !== null) file = memory.pinnedFile
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
  // The plan this session works from goes on record with the commit, so the review tree can group by plan.
  const plan = (await read($, look))?.plan
  const sha = (await run($, ['git', '--no-optional-locks', '-C', where, 'rev-parse', '--verify', 'HEAD']))?.trim() ?? ''
  const top = (await run($, ['git', '--no-optional-locks', '-C', where, 'rev-parse', '--show-toplevel']))?.trim() ?? ''
  if (plan && /^[0-9a-f]{40}$/.test(sha) && top && trailerUrl(body ?? '') !== null)
    await work($, ['commit-plan', '--root', top, '--sha', sha, '--file', plan.file, '--title', plan.title.slice(0, 300), '--step', (plan.step ?? '').slice(0, 300)])
  const url = trailerUrl(body ?? '')
  const state = await stateDir($)
  if (url === null || state === null) return
  const name = (await nameNow($)) ?? (await repoRoot($)).split('/').filter(Boolean).pop() ?? 'Claude'
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
      await receiveEnvelope($, { id: 'nvim-' + name, from: 'you, in nvim', text, at })
      void $.prompt.submit({ text: noteText(note), asUser: true }).catch(() => undefined)
    }
  } finally {
    memory.inboxBusy = false
  }
}

// After an edit: note it in this session's ledger, for the other sessions to see.
async function recordEdit($: EngineInterface, file: string, observed = true) {
  await publishAgent($, 'working', observed ? file : undefined)
  const dir = await sessionsDir($)
  if (dir === null) return
  const sid = await $.session.id()
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(sid)) return
  const own = `${dir}/edits/${sid}.json`
  let ledger = null
  try { ledger = parseLedger(await $.fs.read(own)) } catch { ledger = null }
  const real = await realPath($, file)
  if (!memory.turnFiles.includes(real)) memory.turnFiles.push(real)
  const next = addEdit(ledger, real, await $.clock.now(), await nameNow($), await repoRoot($),
                       (await ownPane($)) ?? undefined)
  await $.fs.write(own, JSON.stringify(next) + '\n')
}

async function recordShellEdits($: EngineInterface, root: string, began: number) {
  if (root === '') return
  const listed = await run($, ['git', '--no-optional-locks', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
  if (listed === null) return
  const changed = gitFiles('', listed)
  if (changed.length === 0 || changed.length > 400) return   // a checkout or a mass rename is not "this command's edits"
  let recorded = 0
  for (const file of changed) {
    if (recorded >= 40) break
    try {
      const stat = await $.fs.stat(root + '/' + file.path)
      // A second of slack for coarse clocks; the command's own start bounds it below.
      if (stat.kind === 'file' && stat.mtimeMs >= began - 1000) { await recordEdit($, root + '/' + file.path, false); recorded++ }
    } catch { /* deleted or unreadable: nothing to attribute */ }
  }
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

// desk-work owns cross-agent identity and liveness; the old drawer endpoint is a compatibility adapter.
async function readPeers($: EngineInterface): Promise<PaperPeer[] | null> {
  const current = await work($, ['agents'])
  if (current !== null) {
    try {
      const list = JSON.parse(current) as AgentSession[]
      const self = await $.session.id()
      if (Array.isArray(list)) return list.filter(p => p && typeof p.id === 'string' && !(p.agent === 'claude' && p.id === self))
        .map(p => ({ ...p, id: p.agent === 'claude' ? p.id : p.key, state: p.state === 'needs' ? 'needs you' : p.state }))
    } catch { /* older backend */ }
  }
  const out = await run($, ['desk-drawer', 'claude-peers'])
  if (out === null) return null
  try {
    const self = await $.session.id()
    const list = JSON.parse(out) as PaperPeer[]
    return Array.isArray(list)
      ? list.filter(p => p && typeof p.id === 'string' && p.id !== self && typeof p.name === 'string')
      : null
  } catch {
    return null
  }
}

async function goTo($: EngineInterface, peer: PaperPeer) {
  const out = await run($, ['desk-drawer', 'run', 'claude-jump', peer.pane])
  if (out === null) $.ui.toast(`couldn't reach ${peer.name}'s window`)
}

async function sendNote($: EngineInterface, peer: PaperPeer, text: string) {
  if (peer.canMessage === false) { $.ui.toast('This agent supports jumping to its terminal; note delivery is unavailable.'); return false }
  const note = text.trim()
  await update($, writingTo, () => null)
  if (note === '') return false
  const me = (await nameNow($)) ?? 'another session'
  try {
    const sent = await $.session.send({ to: { sessionId: peer.id }, text: `✉ from ${me}: ${note}` })
    $.ui.toast(sent.isDelivered ? `note left for ${peer.name}` : `not sent: ${sent.reason}`)
    return sent.isDelivered
  } catch {
    $.ui.toast(`not sent: ${peer.name} isn't taking notes`)
    return false
  }
}

function peerMark(peer: PaperPeer): [string, string] {
  if (peer.state === 'needs you') return ['●', paper.berry]
  if (peer.busy) return ['✎', paper.dim]
  return ['○', paper.ink]
}

function toneColour(tone: PaperTone | undefined): string {
  return tone === undefined ? paper.ink : paper[tone === 'heart' ? 'heart' : tone]
}

// The pushed commit's GitHub Actions runs (gh run list), asked sparingly; a failure is told once as a toast.
async function ciFor($: EngineInterface, root: string, upstream: string): Promise<CiLook | null> {
  const sha = (await run($, ['git', '--no-optional-locks', '-C', root, 'rev-parse', '--verify', upstream + '^{commit}']))?.trim() ?? ''
  if (!/^[0-9a-f]{40}$/.test(sha)) return null
  const remote = upstream.split('/')[0] ?? ''
  if (!memory.github.has(root + ' ' + remote)) {
    const url = (await run($, ['git', '-C', root, 'remote', 'get-url', remote])) ?? ''
    memory.github.set(root + ' ' + remote, /github\.com[:/]/.test(url))
  }
  if (!memory.github.get(root + ' ' + remote)) return null
  const now = await $.clock.now()
  const held = memory.ci?.sha === sha ? memory.ci : null
  const running = held !== null && (held.runs.length === 0 || held.runs.some(r => r.status !== 'completed'))
  if (held && now - held.at < (running ? 30000 : 300000)) return held
  try {
    const out = await $.process.run(['gh', 'run', 'list', '--commit', sha, '--limit', '40', '--json', 'name,workflowName,status,conclusion,url'], { cwd: root, timeoutMs: 8000 })
    const runs = out.exitCode === 0 ? JSON.parse(out.stdout) : null
    if (!Array.isArray(runs)) return held
    memory.ci = { sha, runs, at: now }
  } catch { return held }
  const said = ciLabel(memory.ci.runs)
  if (said?.state === 'failed' && memory.ciTold !== sha) { memory.ciTold = sha; $.ui.toast(said.label) }
  if (said?.state === 'passed' && memory.ciTold === sha + ':running') { memory.ciTold = sha; $.ui.toast('✓ CI passed') }
  if (said?.state === 'running' && memory.ciTold !== sha) memory.ciTold = sha + ':running'
  return memory.ci
}

function refresh($: EngineInterface): Promise<void> {
  if (memory.refreshTask !== null) memory.refreshAgain = true
  else memory.refreshTask = (async () => {
    do { memory.refreshAgain = false; await refreshNow($) } while (memory.refreshAgain)
  })().finally(() => { memory.refreshTask = null })
  return memory.refreshTask
}

async function startWorkWatch($: EngineInterface, root: string) {
  if (memory.watchStarted) return
  const clock = await $.clock.now()
  if (clock < memory.watchRetryAt) return
  memory.watchStarted = true
  void (async () => {
    let pending = ''
    try {
      for await (const chunk of $.process.spawn({ argv: ['desk-work', 'watch', '--root', root] })) {
        if (chunk.stream !== 'stdout') continue
        pending += chunk.text
        if (pending.length > 65536) { pending = ''; continue }
        let split: number
        while ((split = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, split); pending = pending.slice(split + 1)
          try { if (JSON.parse(line)?.version === 1) { memory.watchFailed = false; memory.watchDelay = 1000; void refresh($) } } catch { /* partial or older protocol */ }
        }
      }
    } catch { /* the recovery poll still works without the bridge */ }
    finally {
      memory.watchStarted = false; memory.watchFailed = true
      memory.watchRetryAt = await $.clock.now() + memory.watchDelay
      memory.watchDelay = Math.min(30000, memory.watchDelay * 2)
    }
  })()
}

async function publishAgent($: EngineInterface, state: string, file?: string) {
  await work($, ['agent-update', '--root', await repoRoot($), '--agent', 'claude', '--session', await $.session.id(),
    '--pid', 'parent', '--state', state, '--build', BUILD_ID, '--title', memory.work ?? await nameNow($) ?? 'Claude', '--pane', await ownPane($) ?? '',
    ...(file === undefined ? [] : ['--file', file])])
}

async function saveNotebookView($: EngineInterface) {
  const { form, focused, ...view } = await read($, notebookView)
  await work($, ['workspace', '--root', await repoRoot($), '--client', 'notebook:' + await $.session.id(), '--input', '-'], JSON.stringify(view))
}

async function refreshNow($: EngineInterface) {
  try {
    const cwd = await $.session.cwd()
    const root = await repoRoot($)
    const session = await $.session.id()
    // --no-optional-locks: never take the index lock another session's commit may need.
    const status = await run($, ['git', '--no-optional-locks', '-C', cwd, 'status', '--porcelain=v1', '--branch', '--untracked-files=no'])
    const tracking = parseBranchLine(status?.split('\n')[0] ?? '')
    const branch = tracking.branch
    const trees = (await run($, ['git', '--no-optional-locks', '-C', root, 'worktree', 'list', '--porcelain']))?.split('\n').filter(l => l.startsWith('worktree ')).length ?? 1
    const git: GitLook | null = status === null ? null : { upstream: tracking.upstream, ahead: tracking.ahead, behind: tracking.behind, trees }
    const ci = git?.upstream ? await ciFor($, root, git.upstream) : null
    const head = await run($, ['git', '--no-optional-locks', '-C', root, 'rev-parse', '--verify', 'HEAD'])
    const numstat = await run($, ['git', '--no-optional-locks', '-C', root, 'diff', '--numstat', '-z', ...(head === null ? ['--cached'] : ['HEAD'])])
    const paths = await run($, ['git', '--no-optional-locks', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
    if ((status !== null && (numstat === null || paths === null)) || (status === null && (await read($, look))?.git))
      throw new Error('Could not refresh the working tree')
    const dir = await sessionsDir($)
    const otherLedgers = dir === null ? [] : await readOthers($, dir)
    let own = null
    if (dir !== null && SID.test(session)) {
      try { own = parseLedger(await $.fs.read(`${dir}/edits/${session}.json`)) } catch { /* no edits yet */ }
    }
    const files = attributeFiles(gitFiles(numstat ?? '', paths ?? ''), root, own, otherLedgers)

    let gate: PaperLook['gate'] = 'none'
    try {
      const approved = await $.fs.read(root + '/.claude/.plan-approved')
      const id = await $.session.id()
      gate = approved.split('\n').some(line => line.startsWith(id + ' ') || line === id) ? 'open' : 'closed'
    } catch {
      gate = 'none'
    }

    let plan: PaperLook['plan'] = null
    let pinned: { file: string; step?: string } | null = null
    try {
      const value = JSON.parse(await work($, ['plan', '--root', root, '--session', session]) ?? 'null')
      if (value && typeof value.file === 'string') pinned = value
    } catch { /* no readable pin */ }
    memory.pinnedFile = pinned?.file ?? null
    const planFile = pinned?.file ?? memory.planFile ?? own?.plan ?? null
    if (planFile !== null) {
      try {
        const text = await $.fs.read(planFile)
        const heading = text.split('\n').find(line => line.startsWith('# '))
        plan = { title: heading ? heading.slice(2).trim() : planFile.split('/').pop() ?? planFile, file: planFile,
          pinned: pinned !== null, step: pinned?.step ?? '', ...planProgress(text) }
      } catch {
        plan = null
      }
    }

    // One name everywhere: the pane carries it as its @work label, which the window title and the drawer's
    // Terminals page read. The tmux session keeps the project's name: going to a project finds it by that.
    // With neither a plan nor a title there is no name yet: each place keeps its own fallback.
    const titled = await read($, title)
    memory.work = plan?.title || titled ? workName(plan?.title, titled, root.split('/').filter(Boolean).pop() ?? '') : null
    const label = (memory.work ?? '').replace(/[^\p{L}\p{N} _.,+()&·…-]/gu, ' ').replace(/\s+/g, ' ').trim()
    const inPane = await ownPane($)
    if (inPane !== null && label !== memory.workLabel) {
      memory.workLabel = label
      await run($, ['tmux', 'set-option', '-p', '-t', inPane, '@work', label])
    }
    const context = (await $.session.usage()).context.percent ?? null
    const near = neighbours(root, await $.clock.now(), session, otherLedgers)
    const card = await readCard($, dir)
    const projectWork = await workLook($, root, await $.session.id())
    for (const agent of projectWork?.agents ?? []) {
      if (agent.agent === 'claude' && agent.id === session) continue
      for (const file of files) if (agent.files.includes(file.path) && !file.owners?.some(owner => owner.sid === agent.key || agent.agent === 'claude' && owner.sid === agent.id)) {
        file.owners = [...(file.owners ?? []), { sid: agent.key, name: `${agent.agent} · ${agent.name}`, ...(agent.pane ? { pane: agent.pane } : {}) }]
      }
    }
    let credits: ApiCredits | null = null
    try {
      const value = JSON.parse(await run($, ['desk-credits', 'status']) ?? 'null')
      if (value && typeof value.short === 'string' && typeof value.headline === 'string' && typeof value.meter === 'string') credits = value
    } catch { /* The account meter is optional; session context still works. */ }
    let project: PaperLook['project']
    if ((await read($, notebookView)).page === 'project') {
      let trees: PaperTree[] = []
      try { const value = JSON.parse(await work($, ['worktrees', '--root', root]) ?? '[]'); if (Array.isArray(value)) trees = value } catch { /* unavailable */ }
      const documents = []
      for (const [path, label] of [['DOCS/ROADMAP.md', 'roadmap'], ['plans/README.md', 'plans'], ['README.md', 'project notes'],
        ['package.json', 'dependencies'], ['Cargo.toml', 'dependencies'], ['pyproject.toml', 'dependencies'], ['CMakeLists.txt', 'build dependencies'], ['Makefile', 'build targets']]) {
        if (path && label && await $.fs.exists(root + '/' + path)) documents.push({ path, label })
      }
      project = { trees, documents }
    }
    const note = await lastNight($, root)
    await update($, look, () => ({ root, session, branch, files, gate, plan, context, neighbours: near, card, work: projectWork, project, credits, lastNight: note, git, ci }))
    memory.lookAt = await $.clock.now(); memory.lookFailed = false
    const found = await readPeers($)
    await update($, peers, () => found ?? near.map(n => ({ id: n.sid, name: n.title, project: root.split('/').pop() ?? root,
      state: `edited ${n.files} ${n.files === 1 ? 'file' : 'files'} here`, busy: false,
      pane: otherLedgers.find(o => o.sid === n.sid)?.ledger.pane ?? '' })))

    const left = 5 - hearts(context)
    if (memory.lastHearts > 2 && left === 2) $.ui.toast(`context is ${context ?? 50}% used · a good moment for a handoff`)
    memory.lastHearts = left
    if (memory.lastGate === 'closed' && gate === 'open') $.ui.toast('gate open ✓ the plan is approved')
    memory.lastGate = gate
  } catch {
    // A missed refresh only leaves the notebook a little behind; the next one catches up. The page says so meanwhile.
    memory.lookFailed = true
  }
}

async function beforeEdit($: EngineInterface, file: string) {
  // An edit needs no sudo to count: the path alone says where it lands.
  const what = (' ' + file).match(red.paths)?.[2] ?? null
  if (what !== null) await update($, redZone, () => ({ what }))
  if (/\/plans\/.+\.md$/.test(file)) await notePlan($, file).catch(() => undefined)
}

export const register: Register = on => {

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await loadReceipts($)
    await loadRedZone($)
    try {
      const preference = await $.store.get('notebook-layout')
      if (preference === 'compact' || preference === 'expanded' || preference === 'auto') await update($, notebookView, view => ({ ...view, compact: preference === 'compact', adaptive: preference === 'auto' }))
    } catch { /* the default layout still works */ }
    const unread = await read($, envelopes)
    const migrated = await Promise.all(unread.map(async note => ({ ...note, id: note.id ?? await mailId(note.from, note.text) })))
    const seen = new Set<string>()
    await update($, envelopes, () => migrated.filter(note => {
      if (memory.receipts.has(note.id) || seen.has(note.id)) return false
      seen.add(note.id)
      return true
    }))
    try {
      const saved = JSON.parse(await work($, ['workspace', '--root', await repoRoot($), '--client', 'notebook:' + await $.session.id()]) ?? 'null')
      if (saved?.version === 1 && ['overview', 'files', 'project', 'sessions', 'timeline', 'digest'].includes(saved.page))
        await update($, notebookView, current => ({ ...current, ...saved, form: 'none', focused: '' }))
    } catch { /* a first visit starts at the overview */ }
    // Only where someone is looking: a headless run (claude -p) has nowhere to put a pane.
    if (e.isInteractive) {
      const opened = await $.ui.open({ id: PANE, title: 'notebook', ...paneSize(await read($, notebookView)) })
      memory.notebookOpen = true
      $.ui.toast(greeting(new Date().getHours()))
      if (!opened.isPlaced) $.ui.toast('The notebook is available: /notebook opens it at this width.')
    }
    await refresh($)
    await publishAgent($, 'waiting')
    void startWorkWatch($, await repoRoot($))
    if (e.isInteractive && !memory.toldLastNight && (await read($, look))?.lastNight) {
      memory.toldLastNight = true
      $.ui.toast("last night's note is waiting · /notebook project")
    }
    $.clock.every(20000, () => { void refresh($); void repoRoot($).then(root => startWorkWatch($, root)) })
    $.clock.every(60000, async () => { await work($, ['agent-heartbeat', '--root', await repoRoot($), '--agent', 'claude', '--session', await $.session.id(), '--pid', 'parent']) })
    $.clock.every(5000, () => void checkInbox($))
    $.clock.every(1000, async () => {
      if (!memory.notebookOpen || !memory.resizePending || !memory.viewportColumns) return
      memory.resizePending = false
      const view = await read($, notebookView)
      if (!view.adaptive || view.page !== 'overview' || view.form !== 'none') return
      const compact = autoCompact(memory.viewportColumns)
      if (compact === view.compact) return
      await update($, notebookView, current => ({ ...current, compact }))
      await $.ui.open({ id: PANE, title: 'notebook', ...paneSize({ ...view, compact }) })
    })
    await $.command.register({ name: 'notebook', description: 'Open the paper notebook', argumentHint: '[auto|compact|expand|files|all|project|sessions|timeline|digest]', immediate: true })
    return started
  })

  on('command.run', { command: 'notebook' }, async ($, e) => {
    const page = e.args.trim()
    memory.notebookOpen = true
    memory.resizePending = true
    if (page === 'compact' || page === 'expand' || page === 'auto') {
      const compact = page === 'compact'
      await update($, notebookView, view => ({ ...view, compact: page === 'auto' ? autoCompact(e.presentation.columns) : compact, adaptive: page === 'auto', page: 'overview' as const, form: 'none' as const, selected: '' }))
      await $.store.set('notebook-layout', page === 'auto' ? 'auto' : compact ? 'compact' : 'expanded')
    }
    await update($, notebookView, view => ({ ...view, form: 'none' as const,
      ...(view.form !== 'none' ? { selected: '', focused: '' } : {}) }))
    await update($, writingTo, () => null)
    if (['files', 'project', 'sessions', 'overview', 'all', 'timeline', 'digest'].includes(page))
      await update($, notebookView, v => ({ ...v, page: page === 'all' ? 'files' : page as NotebookView['page'],
        scope: page === 'all' ? 'all' as const : v.scope, offset: 0, selected: '', form: 'none' as const }))
    const view = await read($, notebookView)
    const opened = await $.ui.open({ id: PANE, title: 'notebook', ...paneSize(view), focus: true })
    await refresh($)
    await saveNotebookView($)
    return { text: opened.isPlaced ? 'The notebook is open.' : 'The notebook will open when there is room.' }
  })

  on('ui.focus', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const focused = await next(e)
    if (!focused.deny)
      await update($, notebookView, view => ({ ...view, focused: e.element ?? '',
        selected: e.element && !e.element.startsWith('nav-') ? e.element : view.selected }))
    return focused
  })

  // Escape closes an active editor. Reopening the notebook must never restore
  // an abandoned form or put the keyboard straight back into its input.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    await update($, notebookView, view => ({ ...view, form: 'none' as const, selected: '', focused: '' }))
    await update($, writingTo, () => null)
    const closed = await next(e)
    memory.notebookOpen = false
    return closed
  })

  // Claude Code names each session; the notebook heads with that name.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    if (e.session_title) await update($, title, () => e.session_title ?? null)
    return next(e)
  })
  on('classic.Stop', async ($, e, next) => {
    await publishAgent($, 'waiting')
    await update($, turn, () => null)
    // A turn that leaves files of this session unreviewed says so once, above the prompt, until looked at.
    // A refresh already under way began before the turn's last edit was recorded: let it finish, then read afresh.
    await refresh($)
    await refresh($)
    const seen = await read($, look)
    const mine = (seen?.files ?? []).filter(f => f.own).map(f => f.path)
    const left = unreviewed(mine, reviewStates(seen?.work?.review))
    await update($, nudge, () => left > 0 ? left : null)
    // The receipt: what this turn changed, ran and committed.
    const began = (await read($, receipt))?.at ?? 0
    const start = memory.turnStart || began
    if (start > 0 && seen) {
      const dir = await sessionsDir($)
      const sid = await $.session.id()
      let touched: string[] = []
      try {
        const ledger = dir === null ? null : parseLedger(await $.fs.read(`${dir}/edits/${sid}.json`))
        const base = seen.root.replace(/\/$/, '') + '/'
        touched = [...new Set([...memory.turnFiles, ...editedSince(ledger, start)])].filter(p => p.startsWith(base)).map(p => p.slice(base.length))
      } catch { touched = memory.turnFiles.map(p => p.replace(seen.root.replace(/\/$/, '') + '/', '')) }
      const ran = seen.work?.tests
      const tests = ran && typeof ran.ended === 'number' && ran.ended * 1000 >= start ? testLabel(ran).replace(/ · .*$/, '') : null
      const log = await run($, ['git', '--no-optional-locks', '-C', seen.root, 'log', '-8', `--since=@${Math.floor(start / 1000)}`, '--format=%H %s'])
      const commits = (log ?? '').split('\n').map(s => s.trim()).filter(s => /^[0-9a-f]{40} /.test(s)).map(s => ({ sha: s.slice(0, 40), subject: s.slice(41) }))
      const made: TurnReceipt = { at: await $.clock.now(), files: touched.slice(0, 40), tests, commits, risky: memory.turnRisk.slice(0, 4) }
      await update($, receipt, () => (made.files.length || made.tests || made.commits.length || made.risky.length) ? made : null)
    }
    memory.turnStart = 0
    return next(e)
  })
  on('classic.SessionStart', async ($, e, next) => {
    if (e.session_title) await update($, title, () => e.session_title ?? null)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    await publishAgent($, 'working')
    const started = await $.clock.now()
    await update($, turn, () => ({ started, step: '', seen: started }))
    memory.turnStart = started
    memory.turnRisk = []
    memory.turnFiles = []
    await update($, nudge, () => null)
    await update($, redZone, () => null)
    await update($, overlap, () => null)
    void refresh($)
    return next(e)
  })

  on('session.end', async ($, e, next) => { await saveNotebookView($); await publishAgent($, 'done'); return next(e) })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const what = redZoneOf(e.command)
    if (what !== null) { await update($, redZone, () => ({ what })); if (!memory.turnRisk.includes(what)) memory.turnRisk.push(what) }
    const root = await repoRoot($)
    const sid = await $.session.id()
    const safe = !/password|token|secret|authorization|sk-|ghp_/i.test(e.command)
    // Claude's own plain-words description of the command reads better than the command, wherever one is shown.
    const described = typeof e.description === 'string' ? e.description.split('\n')[0]!.trim().slice(0, 160) : ''
    const title = described && !/password|token|secret|authorization|sk-|ghp_/i.test(described) ? described : ''
    // Before a push: say what is going out unreviewed. It only says so; the push is the person's to stop.
    if (PUSH.test(e.command)) {
      try {
        const check = JSON.parse(await work($, ['push-check', '--root', root]) ?? 'null') as { line?: string } | null
        if (check?.line) $.ui.toast('pushing · ' + check.line)
      } catch { /* the check is a courtesy */ }
    }
    const began = await $.clock.now()
    const activity = title || (safe ? e.command.split('\n')[0]?.slice(0, 160) ?? 'running a command' : 'running a command')
    await work($, ['activity', '--root', root, '--session', sid, '--text', activity, '--state', 'working'])
    await update($, turn, t => t ? { ...t, step: title || t.step, seen: began } : t)
    const job = canTrack(e.command) && e.run_in_background !== true
      ? (await work($, beginArgs(e.command, root, sid, title, await $.session.cwd())))?.trim() || null : null
    let ran: Awaited<ReturnType<typeof next>> | undefined
    let finished: string | null = null
    try { ran = await next(e) }
    finally {
      await work($, ['activity', '--root', root, '--session', sid, '--text', activity, '--state', 'done'])
      if (job && /^[0-9a-f-]{8,64}$/.test(job))
        finished = await work($, ['finish', '--id', job, '--exit', String(ran ? exitOf(ran) : 130), '--output', '-'], ran ? outputOf(ran) : '')
    }
    // A file a shell command wrote (a script, sed, a formatter) is this session's edit too: whatever git sees as
    // changed and was modified while the command ran. Without it a session that edits through the shell reads
    // "0 this session".
    await recordShellEdits($, root, began).catch(() => undefined)
    // Tests that failed two or more times in a row pass again: desk-work counted the run of failures.
    if (greenAgain(finished)) $.ui.toast('green again ✿')
    if (COMMIT.test(e.command) && ran!.deny === undefined && ran!.isError !== true) {
      $.ui.toast('a seed planted ❦')
      await nameCommit($, e.command).catch(() => undefined)
    }
    // After a push that went through: the review stamps follow, where the repository asks for that
    // (git config desk.pushReviewNotes true). Off by default; desk-work decides and never forces.
    if (PUSH.test(e.command) && ran!.deny === undefined && ran!.isError !== true) {
      try {
        const sent = JSON.parse(await work($, ['push-notes', '--root', root]) ?? 'null') as { pushed?: boolean; reason?: string } | null
        if (sent?.pushed) $.ui.toast('review stamps pushed too')
        else if (sent?.reason && sent.reason !== 'off' && sent.reason !== 'no stamps yet') $.ui.toast('review stamps not pushed: ' + sent.reason)
      } catch { /* a courtesy, like the check before it */ }
    }
    void refresh($)
    return ran!
  })

  // Another Claude's message: an envelope in the notebook; delivering it stays the engine's.
  on('session.receive', async ($, e, next) => {
    if (e.origin.kind === 'peer' || e.origin.kind === 'peer-send-message') {
      const first = e.text.split('\n').find(line => line.trim() !== '')?.trim() ?? ''
      const from = first.match(/^✉ from (.{1,60}?): /)?.[1] ?? ('teammate' in e.origin ? e.origin.teammate : 'another Claude')
      const body = e.text.trim().replace(/^✉ from .{1,60}?: /, '')
      const text = body.slice(0, 2000)
      const at = await $.clock.now()
      if (text !== '') await receiveEnvelope($, { from, text, at }, body)
    }
    return next(e)
  })

  on('tool.call', { tool: 'Edit' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    await checkOverlap($, e.file_path).catch(() => undefined)
    await keepBefore($, e.file_path).catch(() => undefined)
    const ran = await withActivity($, `editing ${e.file_path.split('/').pop() ?? 'a file'}`, () => next(e))
    if (ran.deny === undefined && ran.isError !== true) await recordEdit($, e.file_path).catch(() => undefined)
    void refresh($)
    return ran
  })
  on('tool.call', { tool: 'Write' }, async ($, e, next) => {
    await beforeEdit($, e.file_path)
    await checkOverlap($, e.file_path).catch(() => undefined)
    await keepBefore($, e.file_path).catch(() => undefined)
    const ran = await withActivity($, `writing ${e.file_path.split('/').pop() ?? 'a file'}`, () => next(e))
    if (ran.deny === undefined && ran.isError !== true) await recordEdit($, e.file_path).catch(() => undefined)
    void refresh($)
    return ran
  })

  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    if (/\/plans\/.+\.md$/.test(e.file_path)) await notePlan($, e.file_path).catch(() => undefined)
    return withActivity($, `reading ${e.file_path.split('/').pop() ?? 'a file'}`, () => next(e))
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.message !== null) return next(e)
    const turn = await $.session.turns()
    let seed = turn
    for (const ch of e.requestId ?? '') seed = (seed * 31 + ch.charCodeAt(0)) >>> 0
    return next({ ...e, props: { ...e.props, word: WORDS[seed % WORDS.length] ?? 'Working' } })
  })

  // One band at a time: the red zone first, then a card's alert, then another session's recent edit.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const zone = await read($, redZone)
    if (zone !== null) return (
      <Box>
        <Text color={paper.ribbon} weight="bold">○ red zone </Text>
        <Text color={paper.ink}>{clip(zone.what, Math.max(8, e.props.bodyColumns - 40))}</Text>
        <Text color={paper.dim}> · brick-safety first </Text>
        <Button key="dismiss" label="ok" plain onPress={() => update($, redZone, () => null)} />
      </Box>
    )
    const alert = (await read($, look))?.card?.alert
    if (alert) return (
      <Box>
        <Text color={toneColour(alert.tone ?? 'berry')} weight="bold">○ {clip(alert.text, Math.max(8, e.props.bodyColumns - 4))}</Text>
      </Box>
    )
    const waiting = await read($, nudge)
    if (waiting !== null && !e.props.isWorking) return (
      <Box>
        <Text color={paper.ribbon} weight="bold">✎ turn done </Text>
        <Text color={paper.ink}>{clip(receiptLine(await read($, receipt)) || `${waiting} ${waiting === 1 ? 'file' : 'files'} changed`, Math.max(12, e.props.bodyColumns - 44))}</Text>
        <Text color={paper.dim}> · review pending </Text>
        <Button key="review" label="review" plain onPress={async () => {
          await update($, nudge, () => null)
          await work($, ['open', '--root', await repoRoot($), '--action', 'reviews'])
        }} />
        <Text> </Text>
        <Button key="later" label="later" plain onPress={() => update($, nudge, () => null)} />
      </Box>
    )
    const other = await read($, overlap)
    if (other !== null) {
      const name = other.path.split('/').pop() ?? other.path
      return (
        <Box>
          <Text color={paper.ribbon} weight="bold">○ coordinate with the active session that last edited </Text>
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
    let view = await read($, notebookView)
    if (e.viewport?.columns) {
      if (e.viewport.columns !== memory.viewportColumns) memory.resizePending = true
      memory.viewportColumns = e.viewport.columns
      if (view.adaptive && view.page === 'overview' && view.form === 'none') view = { ...view, compact: autoCompact(e.viewport.columns) }
    }
    const warning = await read($, overlap)
    const writingId = await read($, writingTo)
    const writing = others.find(p => p.id === writingId) ?? null
    const name = await nameNow($)
    const underway = await read($, turn)
    const clock = await $.clock.now()
    const width = Math.max(12, e.props.bodyColumns)
    const filled = hearts(now?.context ?? null)
    const root = now?.root ?? await repoRoot($)
    const session = now?.session ?? await $.session.id()
    const navigation: { key: string; press: () => unknown }[] = []
    // The first "needs you" row's action, for the next key.
    let firstNeed: (() => unknown) | null = null
    const content = []
    const setView = async (change: Partial<NotebookView>) => {
      memory.resizePending = true
      if (change.compact !== undefined && change.adaptive === undefined) change.adaptive = false
      await update($, notebookView, v => ({ ...v, ...change }))
      if (change.compact !== undefined) await $.store.set('notebook-layout', change.compact ? 'compact' : 'expanded')
      if (change.page || change.form !== undefined || change.compact !== undefined) {
        await $.ui.open({ id: PANE, title: 'notebook', ...paneSize({ ...view, ...change }), focus: true,
          ...(change.form && change.form !== 'none' ? { closeOnEscape: true as const } : {}) })
      }
      if (change.page) {
        await refresh($)
      }
      const input = change.form === 'task' ? 'work-next-step' : change.form === 'plan' ? 'plan-file' : change.form === 'step' ? 'plan-current-step' : null
      if (input) await $.ui.focus({ requestId: PANE, key: input }).catch(() => undefined)
      else if (change.form === 'none') await $.ui.focus({ requestId: PANE, key: 'nav-back' }).catch(() => undefined)
      await saveNotebookView($)
    }
    const checkedWork = async (args: string[]) => {
      const result = await work($, args)
      if (result === null) { $.ui.toast('Could not open that work item.'); return false }
      try {
        const value = JSON.parse(result)
        if (value?.ok === false) { $.ui.toast(value.message ?? 'That change could not be saved.'); return false }
      } catch { /* open commands have no JSON output */ }
      return true
    }
    const openFile = async (path: string, editor = false) => {
      await checkedWork(['open', '--root', root, '--action', editor ? 'file' : 'file-diff', '--file', path,
        '--session', view.scope === 'session' ? session : ''])
    }
    const openDocument = async (path: string) => {
      const slash = path.lastIndexOf('/')
      await checkedWork(['open', '--root', path.startsWith('/') ? path.slice(0, slash) || '/' : root,
        '--action', 'file', '--file', path.startsWith('/') ? path.slice(slash + 1) : path])
    }
    const openJob = (id: string, action = 'log', index?: number) => checkedWork(['open', '--root', root, '--action', action, '--id', id,
      ...(index === undefined ? [] : ['--index', String(index)])])
    const page = (value: NotebookView['page']) => setView({ page: value, selected: '', form: 'none' })
    const row = (key: string, label: string, press: () => unknown, detail?: ReturnType<typeof Text>) => {
      navigation.push({ key, press })
      const selected = view.selected === key
      const inverted = e.surface === 'terminal' && e.props.isFocused && view.focused === key
      const scope = 'paper-row-' + navigation.length
      const hover = { scope, inverse: false, color: paper.ink, backgroundColor: paper.selection }
      // The terminal always inverts a focused Button. Give it the reversed pair
      // so the visible result is ink on blush; hover cancels inversion itself.
      const paint = (node: RenderNode): RenderNode => {
        if (typeof node === 'string') return node
        if (node.type !== 'Text') return node
        return Text({ ...node.props, hover,
          ...(inverted ? { color: paper.selection, backgroundColor: paper.ink }
            : selected ? { color: paper.ink, backgroundColor: paper.selection } : {}),
          children: node.children?.map(paint) })
      }
      const body = <Text color={paper.ink}>
        <Text color={paper.ribbon}>{selected ? '› ' : '  '}</Text>
        {detail ?? <Text color={paper.ink}>
          {/^[◇⌑✉✓◷+!] /.test(label)
            ? <Text><Text color={label.startsWith('!') ? paper.berry : label.startsWith('✓') || label.startsWith('◷') ? paper.added : paper.ribbon}>{label.slice(0, 1)}</Text>{fit(label.slice(1), width - 3)}</Text>
            : fit(label, width - 2)}
        </Text>}
      </Text>
      return <Button key={key} label={label} plain hover={hover} {...(selected && e.props.isFocused && view.form === 'none' && writingId === null ? { autoFocus: true as const } : {})} onPress={async () => {
        await update($, notebookView, v => ({ ...v, selected: key, focused: key }))
        return press()
      }}>
        {paint(body)}
      </Button>
    }
    const text = (label: string, colour: string = paper.dim) => <Text color={colour}>{label.length > width ? label.slice(0, width - 1) + '…' : label}</Text>
    if (view.compact && view.page === 'overview' && view.form === 'none') {
      const attention = now?.work?.attention
      const local = (mail.length ? 1 : 0) + (warning ? 1 : 0) + (ciLabel(now?.ci?.runs)?.state === 'failed' ? 1 : 0)
      const count = attention ? attention.length + local : (now?.work?.pending ?? 0) + local
      const stale = memory.lookFailed || memory.lookAt > 0 && clock - memory.lookAt > 180000
      return <Box flexDirection="column">
        {text(name ?? 'notebook', paper.ink)}
        <Button key="compact-attention" label={stale ? 'status needs a refresh' : now?.work ? count === 0 ? 'all quiet' : `${count} ${count === 1 ? 'needs' : 'need'} you` : 'work status unavailable'} plain
          onPress={() => setView({ compact: false, page: 'overview', selected: '' })} />
        {now?.work?.tests && text(testLabel(now.work.tests), testColour(now.work.tests))}
        <Button key="compact-expand" label={memory.watchFailed && now?.work ? 'expand · live updates delayed' : 'expand notebook'} hotkey="z" plain onPress={() => setView({ compact: false, page: 'overview', selected: '' })} />
      </Box>
    }
    // A ruler under its row, indented to the row's text, with words after it.
    const measured = (fraction: number, words: string, pencil = false) => {
      const length = Math.max(3, Math.min(16, width - words.length - 4))
      const [drawn, mark, rest] = ruler(fraction, length, pencil)
      return <Text color={paper.dim}>{'  '}<Text color={paper.heart}>{drawn}</Text><Text color={paper.ribbon}>{mark}</Text><Text color={paper.note}>{rest}</Text>{' ' + fit(words, Math.max(2, width - length - 3))}</Text>
    }
    const planRuler = () => {
      const total = now?.plan?.total ?? 0, done = now?.plan?.done ?? 0
      if (total > 0) content.push(measured(done / total, stepLabel({ done, total })))
    }
    // Against the last pass of the same command here: a pencil on the ruler, or a plain note once it runs long.
    const jobRow = (job: WorkJob, label: string) => {
      content.push(row(`job-${job.id}`, label, () => openJob(job.id)))
      const pace = jobPace(job)
      if (pace && 'late' in pace) content.push(text('  taking longer than last time'))
      else if (pace) content.push(measured(pace.fraction, pace.left, true))
    }
    const pin = async (file: string, step = '') => {
      if (!await checkedWork(['plan-pin', '--root', root, '--session', session, '--file', file.trim(), '--step', step.trim()])) return
      memory.pinnedFile = file.trim() || null
      memory.planFile = null
      await setView({ form: 'none' })
      await refresh($)
      const plan = (await read($, look))?.plan
      if (plan) await notePlan($, plan.file)
    }

    if (view.form === 'none' && view.page === 'overview') {
      // The front page, to the UI style (docs/ui-style.md): groups under rule lines, a mark and a name per row with
      // its count on the right, a line saying what the selected row is, and nothing that is not about now.
      const inner = Math.max(10, width - 2)
      const about: Record<string, string> = {}
      const rule = (label: string, right = '') => content.push(text(ruleLine(label, right, width), paper.ribbon))
      const pair = (key: string, left: string, right: string, press: () => unknown, says: string, colour: string = paper.ink) => {
        // A row too long for the pane is cut with an ellipsis; its whole text then leads the description.
        const room = right ? Math.max(4, inner - right.length - 1) : inner
        about[key] = left.length > room ? `${left.replace(/^[^\p{L}\p{N}]+/u, '')} — ${says}` : says
        if (key.startsWith('attention-') && firstNeed === null) firstNeed = press
        const line = spread(left, right, inner)
        const cut = right ? line.length - right.length : line.length
        // The button's own label reads whole ("3 claudes · you + 2 others") for screen readers and other surfaces.
        content.push(row(key, right ? `${left} · ${right}` : left, press, <Text>
          <Text color={colour}>{line.slice(0, cut)}</Text><Text color={paper.dim}>{line.slice(cut)}</Text>
        </Text>))
      }
      const working = turnLabel(underway, clock)
      if (working) content.push(text(working, paper.ribbon))

      const states = reviewStates(now?.work?.review)
      const mine = (now?.files ?? []).filter(f => f.own).map(f => f.path)
      const done = await read($, receipt)
      // Needs you comes first: what failed, what is ready for another look, what someone left for you. Each row's
      // description says the next action.
      const requests = now?.work?.requests ?? []
      const ready = requests.filter(r => r.state === 'ready')
      const changedSince = (now?.files ?? []).map(f => f.path).filter(p => states.get(p) === 'changed' && !ready.some(r => r.file === p))
      const failedIds = new Set((now?.work?.failures ?? []).map(j => j.id))
      const ci = ciLabel(now?.ci?.runs)
      const base = (path: string) => path.split('/').pop() ?? path
      const reReview = (path: string) => checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', path, '--session', session])
      const attention: (() => void)[] = []
      const sharedAttention = now?.work?.attention
      if (sharedAttention) for (const item of sharedAttention.slice(0, 8)) {
        const mark = item.kind === 'request' || item.kind === 'changed' ? '↻' : item.kind === 'commit' ? '○' : '!'
        attention.push(() => pair('attention-' + item.id, `${mark} ${item.label}`, item.kind === 'request' ? 're-review' : item.kind,
          () => checkedWork(['open', '--root', item.root, '--action', 'attention', '--id', item.id]),
          item.why + '. Enter opens it.', item.kind === 'job' || item.kind === 'agent' ? paper.berry : paper.ink))
      }
      if (!sharedAttention) for (const job of (now?.work?.failures ?? []).slice(0, 2))
        attention.push(() => pair(`attention-job-${job.id}`, '! ' + (job.title ?? job.command), job.state, () => openJob(job.id), 'A job that failed and has not passed since. Enter opens its output.', paper.berry))
      const lastTests = now?.work?.tests
      if (!sharedAttention && lastTests && lastTests.state === 'failed' && !failedIds.has(lastTests.id))
        attention.push(() => pair('attention-tests', '! tests failed', ago(clock / 1000 - (lastTests.ended ?? clock / 1000)), () => openJob(lastTests.id, 'tests'), 'The last test run failed. Enter opens the failures, each a jump to its line.', paper.berry))
      if (ci && ci.state === 'failed')
        attention.push(() => pair('attention-ci', '! CI failed on the push', 'open run', async () => { if (/^https:\/\/github\.com\//.test(ci.url)) await run($, ['xdg-open', ci.url]) },
          'GitHub Actions failed on the pushed commit. Enter opens the run in the browser.', paper.berry))
      if (!sharedAttention) for (const r of ready.slice(0, 3))
        attention.push(() => pair(`attention-request-${r.file}`, '↻ ' + base(r.file), 're-review', () => reReview(r.file),
          `You asked ${r.name || 'a session'}: "${r.text}". The file has changed since. Enter opens it for another look.`))
      if (!sharedAttention && changedSince.length) {
        const first = changedSince[0] ?? ''
        attention.push(() => pair('attention-changed', `↻ ${changedSince.length} changed since you reviewed`, base(first), () => reReview(first),
          'Edited after you checked them. Enter opens the first; the review shows only what is new.'))
      }
      if (warning) attention.push(() => pair('attention-overlap', 'shared edit · ' + (warning.path.split('/').pop() ?? ''), warning.ago ?? '', async () => {
        if (warning.pane) await run($, ['desk-drawer', 'run', 'claude-jump', warning.pane])
        else await page('files')
      }, 'Another live session edited this file lately. Enter goes to it.', paper.berry))
      if (mail.length) attention.push(() => pair('attention-mail', '✉ notes for this session', `${mail.length} unread`, () => page('sessions'), 'Notes left for this session from Neovim or another Claude. Enter reads them.'))
      if (attention.length) { rule('needs you', String(attention.length + Math.max(0, (sharedAttention?.length ?? 0) - 8))); attention.forEach(add => add()) }
      if (sharedAttention && sharedAttention.length > 8) pair('attention-more', `${sharedAttention.length - 8} more need you`, 'open list',
        () => run($, ['desktop-menu', '--open', 'attention']), 'The full shared list in the desktop drawer.')
      if (now?.work?.digest?.total) pair('page-digest', 'since you last looked', `${now.work.digest.total} events`, () => page('digest'),
        'Observed edits, requests and test results since you last marked this project caught up. Opening does not clear it.')

      if (done && !working) {
        rule('last turn', ago((clock - done.at) / 1000))
        // Each row opens exactly what it names: the turn's own files (the first one not yet reviewed), or the commit.
        const still = (now?.files ?? []).map(f => f.path)
        const next_ = done.files.find(p => still.includes(p) && states.get(p) !== 'checked') ?? done.files.find(p => still.includes(p))
        const open = () => next_ !== undefined
          ? checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', next_, '--session', session])
          : done.commits[0] ? checkedWork(['open', '--root', root, '--action', 'reviews', '--id', done.commits[0].sha])
          : checkedWork(['open', '--root', root, '--action', 'reviews'])
        if (done.files.length) {
          const read_ = done.files.filter(p => states.get(p) === 'checked').length
          pair('receipt-files', `✎ ${done.files.length} ${done.files.length === 1 ? 'file' : 'files'} changed`, `${read_} of ${done.files.length} reviewed`, open,
            next_ !== undefined ? `What the last turn changed. Enter opens ${next_.split('/').pop()}, the next one not reviewed.` : 'What the last turn changed; all of it is committed. Enter opens the commit.')
        }
        if (done.tests) pair('receipt-tests', done.tests, '', () => now?.work?.tests ? openJob(now.work.tests.id, 'tests') : undefined,
          'The tests the last turn ran.', done.tests.startsWith('✓') ? paper.added : paper.berry)
        for (const commit of done.commits.slice(0, 3))
          pair('receipt-commit-' + commit.sha.slice(0, 7), '❦ ' + commit.subject, commit.sha.slice(0, 7),
            () => checkedWork(['open', '--root', root, '--action', 'reviews', '--id', commit.sha]), 'A commit the last turn made. Enter opens this commit in the review.')
        if (done.commits.length > 3) content.push(text(`  and ${done.commits.length - 3} more commits`))
        for (const what of done.risky) pair('receipt-risk-' + what, '⚠ touched ' + what, 'red zone', open, 'The last turn ran something in the red zone: login, boot, mounts, the kernel or the firewall.', paper.berry)
      }

      const total = now?.plan?.total ?? 0, ticked = now?.plan?.done ?? 0
      rule('plan', now?.gate === 'open' ? 'gate open ✓' : now?.gate === 'closed' ? 'plan first ✎' : '')
      if (now?.plan) {
        pair('plan-open', (now.plan.pinned ? '⌑ ' : '') + workName(now.plan.title, null, now.plan.title), total > 0 ? stepLabel({ done: ticked, total }) : '', () => openDocument(now.plan!.file),
          'The plan this session works from. Enter opens it.')
        if (total > 0) content.push(measured(ticked / total, `${ticked} of ${total} done`))
        if (now.plan.step) pair('plan-step', '◇ ' + now.plan.step, '', () => setView({ form: 'step' }), 'The step in hand. Enter changes it.')
        // No step pinned by hand: the plan's first unticked box is the step, and it moves on as boxes are ticked.
        else if (now.plan.next) pair('plan-step', '◇ ' + now.plan.next, 'next', () => setView({ form: 'step' }),
          'The first step of the plan not ticked yet; it moves on as the plan\'s boxes are ticked. Enter pins a step by hand.')
      } else pair('plan-pin', 'pin an active plan', '', () => setView({ form: 'plan' }), 'No plan read yet in this session. Enter pins one.', paper.dim)

      const pending = now?.work?.pending ?? 0
      const summary = reviewSummary((now?.files ?? []).map(f => f.path), states)
      const waitingOn = requests.filter(r => r.state === 'waiting')
      rule('review', waitingOn.length > 0 ? `${waitingOn.length} with sessions` : '')
      // Changed files already have an action under "needs you".
      const waitingLine = pendingLine(pending, mine.filter(p => states.get(p) !== 'changed'), states)
      const [waitingFirst = '', ...waitingRest] = waitingLine.split(' · ')
      if (waitingLine) pair('review-open', '✎ ' + waitingFirst, waitingRest.join(' · ').replace(' since you looked', ' since').replace(' of yours unread', ' unread'), () => checkedWork(['open', '--root', root, '--action', 'reviews']),
        'What is waiting to be looked over. Enter opens the review in Neovim on the next one.')
      // Requests still with a session: who was asked and what for, until the file changes (then it needs you, above).
      for (const r of waitingOn.slice(0, 3))
        pair(`request-${r.file}`, '✉ ' + base(r.file), 'sent · ' + (r.name || 'a session'), () => setView({ page: 'request', request: r.file, selected: '' }),
          `Sent to ${r.name || 'a session'} ${ago(clock / 1000 - r.at)}: "${r.text}". The file has not changed yet. Enter opens the thread: send it again or withdraw it.`)
      if (waitingOn.length > 3) content.push(text(`  and ${waitingOn.length - 3} more requests waiting`))
      const reviewed = (now?.files ?? []).filter(f => states.get(f.path) === 'checked').length
      pair('page-files', `${now?.files.length ?? 0} changed files`, summary ? `${reviewed} reviewed` : mine.length ? `${mine.length} this session` : '', () => page('files'),
        'Files that differ from the last commit, and how many of them were reviewed as they are now.')

      const age = memory.lookAt > 0 ? (clock - memory.lookAt) / 1000 : null
      rule('work', age === null ? '' : 'updated ' + ago(age))
      if (now?.work?.integration?.status === 'reload-pending') content.push(text(now.work.integration.message, paper.ribbon))
      if (memory.lookFailed || (age !== null && age > 180))
        pair('refresh-now', '↻ this page may be out of date', 'retry', async () => { await refresh($) },
          'The last refresh did not finish, so what is shown may be old. Enter reads everything again now.', paper.berry)
      else if (now && !now.work)
        pair('refresh-now', 'work tool unavailable', 'retry', async () => { await refresh($) },
          'desk-work did not answer, so tests, reviews and requests are not shown. Enter tries again.', paper.dim)
      if (memory.watchFailed && now?.work) pair('watch-retry', 'live updates delayed', 'retry', async () => {
        memory.watchRetryAt = 0; void startWorkWatch($, root); await refresh($)
      }, 'The change stream stopped. The recovery poll still refreshes this page; Enter reconnects it.', paper.dim)
      if (now?.work?.tests) pair('work-tests', testLabel(now.work.tests, clock / 1000), '', () => openJob(now.work!.tests!.id, 'tests'),
        'The last test run here, and whether the code changed since.', testColour(now.work.tests))
      if (ci) pair('work-ci', ci.label, '', async () => { if (/^https:\/\/github\.com\//.test(ci.url)) await run($, ['xdg-open', ci.url]) },
        'GitHub Actions on the pushed commit. Enter opens the run.', ci.state === 'failed' ? paper.berry : ci.state === 'passed' ? paper.added : paper.dim)
      for (const job of (now?.work?.jobs ?? []).slice(0, 1)) jobRow(job, `◷ ${job.title ?? job.command} · ${Math.floor(job.elapsed / 60)}m`)
      const branchLine = now?.card?.title ?? branchLabel(now?.git, now?.branch ?? '')
      const dot = branchLine.indexOf(' · ')
      pair('page-project', dot > 0 ? branchLine.slice(0, dot) : branchLine, dot > 0 ? branchLine.slice(dot + 3) : '', () => page('project'),
        'The branch against what is pushed. Enter shows the project: plan, tests and worktrees.')
      const tasks = (now?.work?.tasks ?? []).filter(t => !t.done)
      if (tasks.length) pair('page-tasks', '◇ ' + (tasks[0]?.text ?? ''), `${tasks.length} next`, () => page('project'), 'Pinned next steps for this project.')
      if (now?.work) pair('task-add', '+ next step', '', () => setView({ form: 'task' }), 'Pin something to do next.', paper.dim)

      if (others.length) {
        rule('sessions', String(others.length + 1))
        // Counted with this one, so four running reads as four: "4 claudes · you + 3 others".
        pair('page-sessions', `${others.length + 1} ${others.some(p => p.agent && p.agent !== 'claude') ? 'agents' : 'claudes'}`, `you + ${others.length} ${others.length === 1 ? 'other' : 'others'}`, () => page('sessions'),
          'The other Claude sessions on this machine. Enter lists them, to go to one or leave it a note.')
      }
      pair('page-help', '? marks and keys', '', () => page('help'), 'What each mark means and which keys work here.', paper.dim)
      pair('page-timeline', 'project timeline', '', () => page('timeline'), 'The shared history of requests, edits, tests and reviews.')
      // What the selected row is, the way a menu's description strip says it.
      const says = about[view.selected]
      if (says) { content.push(text('')); for (const line of wrapWords(says, width)) content.push(text(line)) }
    }

    if (view.form === 'none' && view.page === 'request') {
      // One request's thread: what was asked of whom, where it stands, and the three things to do about it.
      const thread = (now?.work?.requests ?? []).find(r => r.file === view.request)
      if (!thread) content.push(text('That request is settled.'))
      else {
        content.push(text(ruleLine('request', ago(clock / 1000 - thread.at), width), paper.ribbon))
        content.push(text((thread.state === 'ready' ? '↻ ' : '✉ ') + thread.file, paper.ink))
        content.push(text('to ' + (thread.name || 'a session')))
        content.push(text(thread.state === 'ready' ? 'the file has changed since' : 'the file has not changed yet', thread.state === 'ready' ? paper.added : paper.dim))
        for (const line of wrapWords(`"${thread.text}"`, Math.max(8, width - 2))) content.push(text('  ' + line, paper.ink))
        content.push(row('request-open', thread.state === 'ready' ? '↻ re-review the file' : 'open the file',
          () => checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', thread.file, '--session', session])))
        const peer = others.find(p => p.id === thread.sid)
        content.push(row('request-again', peer ? '✉ send it again' : '✉ send again · session ended', async () => {
          if (!peer) { $.ui.toast('That session is no longer running. Withdraw this, then ask a live one from the review.'); return }
          // Delivery retries keep the original baseline: an answered request must stay ready for re-review.
          if (await sendNote($, peer, `Change request (again) for ${thread.file}: ${thread.text}`)) await refresh($)
        }))
        content.push(row('request-withdraw', '✕ withdraw it', async () => {
          if (await checkedWork(['review-request', '--root', root, '--file', thread.file, '--clear', 'yes'])) { await refresh($); await page('overview') }
        }))
      }
      content.push(row('request-back', 'back', () => page('overview')))
    }

    if (view.form === 'none' && view.page === 'help') {
      const line = (mark: string, words: string) => wrapWords(words, Math.max(8, width - 7)).forEach((part, i) =>
        content.push(<Text><Text color={paper.ribbon}>{('  ' + (i === 0 ? mark : '')).padEnd(7)}</Text><Text color={paper.ink}>{part}</Text></Text>))
      content.push(text(ruleLine('marks', '', width), paper.ribbon))
      line('✓', 'reviewed as it is now')
      line('↻', 'edited since you reviewed it')
      line('○', 'not reviewed yet')
      line('✉', 'sent to a session; waiting for a change')
      line('✎', 'something to look over')
      line('⚠', 'red zone: login, boot, mounts, firewall')
      line('!', 'failed, and not passed since')
      line('◷', 'running now')
      line('❦', 'a commit')
      line('⌑', 'the pinned plan')
      line('◇', 'the step or task in hand')
      line('▰▱', 'context used; five full is the limit')
      content.push(text(ruleLine('keys', '', width), paper.ribbon))
      line('j k', 'move down and up')
      line('l ⏎', 'open the selected row')
      line('h', 'back to the front page')
      line('n', 'the next thing that needs you')
      line('e', 'on files: open the selected file to edit')
      line('d', 'the same page in the drawer')
      content.push(text(ruleLine('words', '', width), paper.ribbon))
      for (const words of ['gate open: the plan is approved, edits may go on', 'plan first: edits wait for an approved plan',
        'needs you: what failed, or is ready for another look'])
        wrapWords(words, Math.max(8, width - 2)).forEach((part, i) => content.push(text((i === 0 ? '  ' : '    ') + part, paper.ink)))
      content.push(row('help-back', 'back', () => page('overview')))
    }

    if (view.form === 'none' && view.page === 'files') {
      content.push(row('scope-session', (view.scope === 'session' ? '● ' : '○ ') + 'this session', () => setView({ scope: 'session', offset: 0, selected: '' })))
      content.push(row('scope-all', (view.scope === 'all' ? '● ' : '○ ') + 'all changes', () => setView({ scope: 'all', offset: 0, selected: '' })))
      const scoped = (now?.files ?? []).filter(f => view.scope === 'all' || f.own)
      const reviewed = reviewStates(now?.work?.review)
      // Filters: only what needs a review, only what changed since its review, and a part of a name. They persist.
      const show = view.show ?? 'all'
      const needing = scoped.filter(f => reviewed.get(f.path) !== 'checked').length
      const changedCount = scoped.filter(f => reviewed.get(f.path) === 'changed').length
      const nextShow = show === 'all' ? 'unreviewed' : show === 'unreviewed' ? 'changed' : 'all'
      content.push(row('files-show', show === 'all' ? `○ showing everything · ${needing} need review`
        : show === 'unreviewed' ? `● only what needs review · ${needing}` : `● only changed since review · ${changedCount}`,
        () => setView({ show: nextShow, offset: 0, selected: 'files-show' })))
      content.push(row('files-search', view.query ? `/ ${view.query} · clear` : '/ find a file',
        () => view.query ? setView({ query: '', offset: 0, selected: 'files-search' }) : setView({ form: 'search' })))
      const files = filterFiles(scoped, reviewed, show, view.query)
      const columns = fileColumns(files)
      const offset = Math.min(view.offset, Math.max(0, Math.floor((files.length - 1) / 40) * 40))
      const summary = reviewSummary(files.map(f => f.path), reviewed)
      content.push(text(`${files.length} ${files.length === 1 ? 'file' : 'files'} · working-tree totals`))
      if (summary) content.push(text(summary, paper.ribbon))
      if (!files.length) content.push(text(scoped.length ? 'Nothing matches these filters.' : view.scope === 'session' ? 'No recorded edits still differ.' : 'The working tree is clean.'))
      let directory = ''
      for (const file of files.slice(offset, offset + 40)) {
        const parent = file.path.includes('/') ? file.path.slice(0, file.path.lastIndexOf('/')) : '.'
        if (parent !== directory) { content.push(text(parent + '/')); directory = parent }
        const [added, removed] = fileCounts(file, columns)
        const owner = [file.own ? 'you' : '', ...(file.owners ?? []).map(o => o.name)].filter(Boolean).join(', ') || 'unattributed'
        const suffix = (file.owners?.length || !file.own) ? ` · ${owner}` : ''
        // ✓ reviewed, ↻ edited since it was reviewed, ○ not yet: only once a review of these files exists.
        const state = reviewed.get(file.path)
        const mark = summary ? (state === 'checked' ? '✓' : state === 'changed' ? '↻' : '○') + ' ' : ''
        const labelWidth = Math.max(6, width - added.length - removed.length - 4 - mark.length)
        const fileLabel = shortPath(file.path, Math.max(6, labelWidth - Math.min(suffix.length, Math.floor(labelWidth / 2))))
          + shortPath(suffix, Math.min(suffix.length, Math.floor(labelWidth / 2)))
        content.push(row(`file:${file.path}`, file.path, () => openFile(file.path), <Text>
          <Text color={state === 'checked' ? paper.added : state === 'changed' ? paper.berry : paper.note}>{mark}</Text>
          <Text color={paper.added}>{added}</Text><Text> </Text><Text color={paper.removed}>{removed}</Text><Text> </Text>
          <Text color={paper.ink}>{shortPath(fileLabel, labelWidth)}</Text>
        </Text>))
      }
      if (offset > 0) content.push(row('files-previous', '↑ previous files', () => setView({ offset: offset - 40, selected: '' })))
      if (files.length > offset + 40) content.push(row('files-next', `↓ ${files.length - offset - 40} more files`, () => setView({ offset: offset + 40, selected: '' })))
      const selected = files.find(f => `file:${f.path}` === view.selected)
      if (selected) {
        content.push(text('Selected: ' + selected.path))
        if (selected.owners?.length) content.push(text('Shared file: the diff can include other edits.', paper.ribbon))
        for (const owner of selected.owners ?? []) {
          const peer = others.find(p => p.id === owner.sid)
          if (peer) content.push(row('file-owner-' + peer.id, 'go to ' + peer.name, () => goTo($, peer)))
        }
      }
    }

    if (view.form === 'none' && view.page === 'project') {
      if (now?.plan) {
        content.push(row('plan-open', (now.plan.pinned ? '⌑ ' : '') + now.plan.title, () => openDocument(now.plan!.file)))
        planRuler()
        content.push(row('plan-pin', now.plan.pinned ? 'change active plan' : 'pin this plan', () => now.plan?.pinned ? setView({ form: 'plan' }) : pin(now.plan!.file)))
        content.push(row('plan-step', now.plan.step ? '◇ ' + now.plan.step : '+ current step', () => setView({ form: 'step' })))
        if (now.plan.pinned) content.push(row('plan-unpin', 'unpin plan', () => pin('')))
      } else content.push(row('plan-pin', '+ active plan', () => setView({ form: 'plan' })))
      if (now?.lastNight) content.push(row('last-night', 'last night · ' + (now.lastNight.line || 'where we left off'), () => openDocument(now.lastNight!.file)))
      if (now?.work?.tests) {
        const test = now.work.tests
        content.push(<Text color={testColour(test)}>{testLabel(test)}</Text>)
        content.push(row('work-tests', 'test output & failures', () => openJob(test.id, 'tests')))
        content.push(row('work-compare', 'compare with last passing run', () => openJob(test.id, 'compare')))
        for (const [i, failure] of test.tests.failures.slice(0, 10).entries())
          content.push(row(`work-failure-${i}`, `${failure.filename.split('/').pop()}:${failure.lnum}`, () => openJob(test.id, 'tests', i + 1)))
        for (const file of (test.changedFiles ?? []).slice(0, 10))
          content.push(row('test-changed:' + file, 'changed since: ' + file, () => openFile(file, true)))
      }
      for (const job of now?.work?.jobs ?? []) jobRow(job, `◷ ${job.title ?? job.command}`)
      if (now?.work) {
        for (const task of now.work.tasks.filter(t => !t.done)) {
          content.push(row(`task-draft-${task.id}`, '◇ ' + task.text, () => checkedWork(['open', '--root', root, '--action', 'tasks', '--id', task.id])))
          content.push(row(`task-done-${task.id}`, '  mark done', async () => {
            await checkedWork(['task-toggle', '--root', root, '--id', task.id]); await refresh($)
          }))
        }
        content.push(row('task-add', '+ next step', () => setView({ form: 'task' })))
      }
      if (now?.card) {
        content.push(text(now.card.title, paper.ribbon))
        for (const [i, item] of now.card.rows.slice(0, 24).entries()) {
          const label = `${item.mark ? item.mark + ' ' : ''}${item.text}`
          const action: PaperAction | undefined = item.action
          if (action && ['file', 'file-diff', 'log', 'tests', 'compare'].includes(action.kind)
            && ((action.kind === 'file' || action.kind === 'file-diff') ? typeof action.file === 'string' : typeof action.id === 'string'))
            content.push(row('card-' + i, label, () => action.kind === 'file' || action.kind === 'file-diff'
              ? openFile(action.file!, action.kind === 'file') : openJob(action.id!, action.kind)))
          else content.push(text(label, toneColour(item.tone)))
        }
      }
      for (const doc of now?.project?.documents ?? [])
        content.push(row('document:' + doc.path, `${doc.label} · ${doc.path}`, () => openDocument(doc.path)))
      for (const tree of now?.project?.trees ?? []) {
        if (tree.bare) continue
        const dirty = tree.status.split('\n').filter(line => line && !line.startsWith('##')).length
        content.push(row('tree:' + tree.path, `${tree.branch} · ${dirty} changed · ${tree.sessions.length} ${tree.sessions.length === 1 ? 'session' : 'sessions'}`, () => checkedWork([
          'open', '--root', root, '--action', 'worktree', '--file', tree.path,
        ])))
      }
    }

    if (view.form === 'none' && view.page === 'sessions') {
      if (mail.length) content.push(row('mail-clear', 'mark all notes read', () => acknowledgeMail($, mail)))
      for (const note of mail) {
        content.push(text(`✉ from ${note.from}`, paper.ribbon))
        content.push(<Text color={paper.ink}>{note.text}</Text>)
        content.push(row(`envelope-${note.id ?? note.at}`, 'mark read', () => acknowledgeMail($, [note])))
      }
      if (others.length) content.push(text(`${others.length + 1} ${others.some(p => p.agent && p.agent !== 'claude') ? 'agents' : 'claudes'} · you and ${others.length} ${others.length === 1 ? 'other' : 'others'}`))
      for (const peer of others.slice(0, 8)) {
        const [mark, colour] = peerMark(peer)
        const where = peer.name === peer.project ? '' : ` · ${peer.project}`
        content.push(text(`${mark} ${peer.agent && peer.agent !== 'claude' ? peer.agent + ' · ' : ''}${peer.name}${where}`, colour))
        content.push(text(peer.state))
        if (peer.pane) content.push(row('go-' + peer.id, 'go to ' + peer.name, () => goTo($, peer)))
        if (peer.canMessage === false) content.push(text('note delivery unavailable'))
        else if (writing?.id !== peer.id) content.push(row('note-' + peer.id, 'leave a note', async () => {
          await update($, writingTo, () => peer.id)
          await $.ui.focus({ requestId: PANE, key: 'peer-note' }).catch(() => undefined)
        }))
        else {
          content.push(<Input key="peer-note" placeholder={`a note for ${clip(peer.name, 20)}`} submitLabel="send" autoFocus
            onSubmit={value => sendNote($, peer, value)} />)
          content.push(row('peer-cancel', 'never mind', () => update($, writingTo, () => null)))
        }
      }
      if (others.length > 8) content.push(text(`+ ${others.length - 8} more · the drawer's Agents page lists them all`))
      if (!mail.length && !others.length) content.push(text('No unread notes or other live sessions.'))
    }

    if (view.form === 'none' && (view.page === 'timeline' || view.page === 'digest')) {
      const digest = now?.work?.digest
      const events = view.page === 'digest' ? digest?.events ?? [] : now?.work?.timeline ?? []
      if (view.page === 'digest' && digest?.summary) for (const line of wrapWords(digest.summary, width)) content.push(text(line, paper.ink))
      if (!events.length) content.push(text('No recorded events here yet.'))
      for (const event of events.slice(view.offset, view.offset + 20))
        content.push(row('event-' + event.id, event.label, () => checkedWork(['open', '--root', root, '--action', 'event', '--id', event.id]),
          <Text>{fit(event.label, Math.max(8, width - 10))}<Text color={paper.dim}> {ago(clock / 1000 - event.at)}</Text></Text>))
      if (view.page === 'digest' && digest?.total) content.push(row('digest-caught-up', 'mark these events caught up', async () => {
        if (await checkedWork(['digest', '--root', root, '--consumer', 'notebook', '--through', String(digest.through)])) await refresh($)
      }))
      if (digest?.truncated && view.page === 'digest') content.push(text('Older events have expired; this digest is partial.'))
      if (events.length > 20) content.push(row('events-next', view.offset + 20 < events.length ? 'older events' : 'newest events',
        () => setView({ offset: view.offset + 20 < events.length ? view.offset + 20 : 0 })))
    }
    if (view.form === 'snooze') {
      const selected = now?.work?.attention?.find(item => 'attention-' + item.id === view.selected)
      if (selected) {
        content.push(text(selected.label, paper.ink))
        for (const [key, label, option] of [['hour', 'later · one hour', '--seconds'], ['change', 'until this item changes', '--until-change']] as const)
          content.push(row('snooze-' + key, label, async () => {
            if (await checkedWork(['snooze', '--root', root, '--id', selected.id, option, key === 'hour' ? '3600' : 'yes'])) {
              await setView({ form: 'none', selected: '' }); await refresh($)
            }
          }))
      } else content.push(text('That attention item is already settled.'))
    }
    if (view.form === 'task') {
      content.push(<Input key="work-next-step" placeholder="pin a next step" submitLabel="pin" autoFocus onSubmit={async value => {
        if (!value.trim()) { await setView({ form: 'none' }); return }
        if (await checkedWork(['task-add', '--root', root, '--text', value.trim()])) { await setView({ form: 'none' }); await refresh($) }
      }} />)
    }
    if (view.form === 'search') content.push(<Input key="files-query" placeholder="part of a file name" value={view.query ?? ''} submitLabel="find" autoFocus
      onSubmit={value => setView({ form: 'none', query: value.trim().slice(0, 80), offset: 0, selected: '' })} />)
    if (view.form === 'plan') content.push(<Input key="plan-file" placeholder="path/to/plan.md" submitLabel="pin" autoFocus onSubmit={value => pin(value)} />)
    if (view.form === 'step') content.push(<Input key="plan-current-step" placeholder="current step" value={now?.plan?.step ?? ''} submitLabel="pin" autoFocus
      onSubmit={value => now?.plan ? pin(now.plan.file, value) : undefined} />)
    if (view.form !== 'none') {
      content.push(row('form-cancel', 'cancel', () => setView({ form: 'none' })))
    }

    const move = async (direction: number) => {
      if (!navigation.length) return
      const index = navigation.findIndex(n => n.key === view.selected)
      const selected = navigation[(index < 0 ? (direction > 0 ? 0 : navigation.length - 1) : (index + direction + navigation.length) % navigation.length)]!
      await setView({ selected: selected.key })
      await $.ui.focus({ requestId: PANE, key: selected.key }).catch(() => undefined)
      await setView({ focused: selected.key })
      await $.ui.scroll({ to: { key: selected.key }, in: PANE }).catch(() => undefined)
    }
    const activate = () => (navigation.find(n => n.key === view.selected) ?? navigation[0])?.press()
    const back = () => view.form !== 'none' ? setView({ form: 'none' }) : page('overview')
    const nextNeed = firstNeed as (() => unknown) | null
    return <Box flexDirection="column">
      <Text>
        {/* No reading yet (a session just resumed): no meter, rather than five empty boxes that read as 0%. */}
        {now?.context != null && <Text color={now.context >= 80 ? paper.berry : paper.heart}>{'▰'.repeat(filled)}</Text>}
        {now?.context != null && <Text color={paper.note}>{'▱'.repeat(5 - filled)}</Text>}
        <Text color={paper.dim}>{now?.context == null ? 'context not measured yet' : ` ${now.context}%`}</Text>
        {mail.length > 0 && <Text color={paper.ribbon}>{` · ✉ ${mail.length}`}</Text>}
        <Text color={paper.ink}>{name ? ' · ' + fit(name, Math.max(4, width - 14)) : ''}</Text>
      </Text>
      {/* The keys only matter while the notebook holds the keyboard; at rest the row is noise. */}
      {(e.props.isFocused || view.page !== 'overview') && <Box>
        <Button key="nav-back" label="back" hotkey="h" plain onPress={back} /><Text> </Text>
        <Button key="nav-up" label="↑" hotkey="k" plain onPress={() => move(-1)} /><Text> </Text>
        <Button key="nav-down" label="↓" hotkey="j" plain onPress={() => move(1)} /><Text> </Text>
        <Button key="nav-open" label="open" hotkey="l" plain onPress={activate} /><Text> </Text>
        {nextNeed !== null && <Button key="nav-next" label="next" hotkey="n" plain onPress={() => nextNeed()} />}{nextNeed !== null && <Text> </Text>}
        <Button key="nav-drawer" label="drawer" hotkey="d" plain onPress={() => run($, ['desktop-menu', '--open', drawerPage(view.page)])} />
        {now?.work?.attention?.some(item => 'attention-' + item.id === view.selected) && <Button key="nav-snooze" label="later" hotkey="s" plain onPress={() => setView({ form: 'snooze' })} />}
        <Text> </Text><Button key="nav-compact" label="compact" hotkey="z" plain onPress={() => setView({ compact: true, page: 'overview', form: 'none', selected: '' })} />
      </Box>}
      {now?.credits && (now.credits.status === 'error' || (now.credits.remaining_percent != null && now.credits.remaining_percent <= 20)) && <Button key="api-credit-meter" label="monthly API credit details" plain
        onPress={() => run($, ['desktop-menu', '--open', 'api-credits'])}>
        <Text color={now.credits.status === 'error' || (now.credits.remaining_percent !== null && now.credits.remaining_percent <= 20) ? paper.berry : paper.added}>
          {shortPath(now.credits.short, width)}
          {now.credits.meter ? '\n' + now.credits.meter + ' tracked' : ''}
        </Text>
      </Button>}
      {view.page !== 'overview' && <Box>
        {(['files', 'project', 'sessions'] as const).flatMap(value => [<Button key={'nav-page-' + value} label={value} plain onPress={() => page(value)} />, <Text key={'nav-gap-' + value}> </Text>])}
      </Box>}
      {view.page === 'files' && <Button key="nav-editor" label="edit selected" hotkey="e" plain onPress={() => {
        const selected = (now?.files ?? []).find(f => `file:${f.path}` === view.selected)
        if (selected) return openFile(selected.path, true)
      }} />}
      {view.page === 'files' && <Button key="nav-file-tests" label="tests for selected" plain onPress={() => {
        const selected = (now?.files ?? []).find(file => 'file:' + file.path === view.selected)
        if (selected) return checkedWork(['open', '--root', root, '--action', 'suggested-tests', '--file', selected.path])
      }} />}
      {content}
    </Box>
  })
}
