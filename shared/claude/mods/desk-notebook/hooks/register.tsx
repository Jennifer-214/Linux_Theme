import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderNode } from 'claude-code'

import type { AgentSession, ApiCredits, CiLook, GitLook, NotebookView, PaperAction, PaperCard, PaperEnvelope, PaperLook, PaperOverlap, PaperPeer, PaperRedZone, PaperTone, PaperTree, TurnLook, TurnReceipt, WorkJob } from '../types'
import { addBefore, addEdit, addName, neighbours, namesText, noteText, overlapFor, parseLedger, parseNames, parseNote, trailerUrl, withPlan, editedSince } from './ledger'
import type { Other } from './ledger'
import { paper } from './theme'
import { ago, beginArgs, canTrack, ciLabel, exitOf, greenAgain, jobPace, outputOf, parseBranchLine, filterFiles, planProgress, receiptLine, reviewStates, reviewSummary, ruleParts, ruler, sides, syncLabel, workName, wrapWords, stepLabel, testLabel, turnLabel, unreviewed, work, workCall, workLook, needBreakdown, needGroup, wrapParts, MARKS, glyph, CHARS, ELLIPSIS, RETRO, cut, said, dosText } from './work'
import { attributeFiles, fileColumns, fileCounts, gitFiles, drawerPage, mailId, shortPath, NAMED_PAGES } from './notebook'
import { BUILD_ID } from './build'
import { metricLabel } from './work'

// Linux_Theme paper: a notebook pane beside the chat (hearts, the session's name, its plan, the gate, pages
// touched, the other Claudes with [go] and [note]), a red-zone band before a risky system edit, a band when
// another live session edited the same file lately, notes as envelopes (from nvim's inbox, or another Claude), a
// few gentle toasts, and paper spinner words. It writes only this session's own files in the private runtime folder
// ($XDG_RUNTIME_DIR/foxml-claude: edits/<session>.json, edits/<session>/before/, and its inbox notes, removed once
// delivered) and the commit names in $XDG_STATE_HOME/foxml/claude-sessions.jsonl.

const PANE = 'paper-notebook'
const look = atom({ plugin: 'desk-notebook', key: 'look' } as const, null as PaperLook | null, { shape: 'look-3' })
const title = atom({ plugin: 'desk-notebook', key: 'title' } as const, null as string | null)
const redZone = atom({ plugin: 'desk-notebook', key: 'redZone' } as const, null as PaperRedZone | null, { shape: 'red-1' })
const overlap = atom({ plugin: 'desk-notebook', key: 'overlap' } as const, null as PaperOverlap | null, { shape: 'overlap-1' })
const peers = atom({ plugin: 'desk-notebook', key: 'peers' } as const, [] as PaperPeer[], { shape: 'peers-1' })
const writingTo = atom({ plugin: 'desk-notebook', key: 'writingTo' } as const, null as string | null)
const turn = atom({ plugin: 'desk-notebook', key: 'turn' } as const, null as TurnLook | null, { shape: 'turn-1' })
const nudge = atom({ plugin: 'desk-notebook', key: 'nudge' } as const, null as number | null)
const receipt = atom({ plugin: 'desk-notebook', key: 'receipt' } as const, null as TurnReceipt | null, { shape: 'receipt-2' })
const envelopes = atom({ plugin: 'desk-notebook', key: 'envelopes' } as const, [] as PaperEnvelope[], { shape: 'env-1' })
const notebookView = atom({ plugin: 'desk-notebook', key: 'notebookView' } as const,
  { page: 'overview', scope: 'session', selected: '', offset: 0, form: 'none' } as NotebookView, { shape: 'notebook-1' })
const SID = /^[A-Za-z0-9_-]{1,80}$/
const autoCompact = (columns: number) => columns < 144
// The front page has a fixed set of rows (at most 17: header, five groups, the two lines of keys), so the pane is that tall and
// never grows or shrinks as things change.
const FRONT_ROWS = 17
const paneSize = (view: NotebookView) => view.compact && view.page === 'overview' && view.form === 'none'
  ? { rows: 4, columns: 30 } : { rows: view.page === 'overview' && view.form === 'none' ? FRONT_ROWS : 22, columns: 42 }

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

// A short greeting by the hour; retro says it the way a DOS program did.
function greeting(hour: number): string {
  if (RETRO) return 'NOTEBOOK READY.'
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
  return /^\S*\/\S*$/.test(label.trim()) ? shortPath(label, width) : label.slice(0, Math.max(1, width - ELLIPSIS.length)).trimEnd() + ELLIPSIS
}

function clip(text: string, width: number): string {
  if (width <= 1) return ''
  return text.length <= width ? text : ELLIPSIS + text.slice(text.length - Math.max(0, width - ELLIPSIS.length))
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
  // The newest view a refresh made. Every state read of one dispatch reads one moment ($.state.get), so a hook that
  // waits on a refresh another event started still reads what was there when it began; this holds what it made.
  look: null as PaperLook | null,
  refreshAgain: false,
  // The change stream's pace: when it last started a refresh, and whether one is waiting for the second to pass.
  streamRefreshAt: 0,
  reportedFailure: null as boolean | null,
  reportedAt: 0,
  streamRefreshQueued: false,
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

// A turn says "working" until a quarter of an hour passes with no sign of life; every tool call is one.
async function stillWorking($: EngineInterface) {
  const at = await $.clock.now()
  const current = await read($, turn)
  if (current && at - (current.seen ?? current.started) > 30000) await update($, turn, t => t ? { ...t, seen: at } : t)
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
        text: `(desk-notebook) Another active agent session, "${found.title}"`
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
  const plan = (await latestLook($))?.plan
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
async function recordEdit($: EngineInterface, file: string, observed = true, publish = true) {
  if (publish) await publishAgent($, 'working', observed ? file : undefined)
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
      if (stat.kind === 'file' && stat.mtimeMs >= began - 1000) { await recordEdit($, root + '/' + file.path, false, false); recorded++ }
    } catch { /* deleted or unreadable: nothing to attribute */ }
  }
  if (recorded > 0) await publishAgent($, 'working')
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
    const sent = await $.session.send({ to: { sessionId: peer.id }, text: `${glyph('sent')} from ${me}: ${note}` })
    $.ui.toast(sent.isDelivered ? `note left for ${peer.name}` : `not sent: ${sent.reason}`)
    return sent.isDelivered
  } catch {
    $.ui.toast(`not sent: ${peer.name} isn't taking notes`)
    return false
  }
}

function peerMark(peer: PaperPeer): [string, string] {
  if (peer.state === 'needs you') return [glyph('waiting'), paper.berry]
  if (peer.busy) return [glyph('busy'), paper.dim]
  return [glyph('idle'), paper.ink]
}
// A row's label that starts with one of these marks and a space has its mark coloured: failed, passed and running,
// and the rest in the ribbon colour.
const LEADING = new RegExp(`^[${[glyph('step'), glyph('plan'), glyph('sent'), glyph('checked'), glyph('running'), glyph('failed'), '+'].map(m => m.replace(/[\\^\]-]/g, '\\$&')).join('')}] `)
// A note from another session starts with the envelope, the sender and a colon.
// Either style's envelope: a note can come from a session drawn in the other one.
const ENVELOPE = /^(?:✉|→) from (.{1,60}?): /

// The selected row: ink on the selection colour; retro in true inverse, the page's black on amber.
const PICK = RETRO ? { ink: paper.page, ground: paper.ink } : { ink: paper.ink, ground: paper.selection }

// Whether the notebook's front page, which draws the last turn, is on screen now.
async function frontPageShown($: EngineInterface): Promise<boolean> {
  const view = await read($, notebookView)
  if (!memory.notebookOpen || view.compact || view.page !== 'overview' || view.form !== 'none') return false
  try { return (await $.ui.panes()).some(pane => pane.id === PANE && pane.isShown && pane.isPlaced) } catch { return false }
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
  if (said?.state === 'passed' && memory.ciTold === sha + ':running') { memory.ciTold = sha; $.ui.toast(`${glyph('checked')} CI passed`) }
  if (said?.state === 'running' && memory.ciTold !== sha) memory.ciTold = sha + ':running'
  return memory.ci
}

// The view as the newest refresh left it, for a hook that has just waited on one (see memory.look).
async function latestLook($: EngineInterface): Promise<PaperLook | null> {
  return memory.look ?? await read($, look)
}

function refresh($: EngineInterface): Promise<void> {
  if (memory.refreshTask !== null) memory.refreshAgain = true
  else memory.refreshTask = (async () => {
    do { memory.refreshAgain = false; await refreshNow($) } while (memory.refreshAgain)
  })().finally(() => { memory.refreshTask = null })
  return memory.refreshTask
}

// A burst of change events (an agent saving file after file) costs one refresh a second at most, and the last event
// is always read: the first refreshes at once; any arriving within the next second share one refresh at its end.
async function refreshSoon($: EngineInterface): Promise<void> {
  if (memory.streamRefreshQueued) return
  const wait = memory.streamRefreshAt + 1000 - await $.clock.now()
  if (wait > 0) {
    memory.streamRefreshQueued = true
    try { await $.clock.sleep(wait) } catch { memory.streamRefreshQueued = false; return }
    memory.streamRefreshQueued = false
  }
  memory.streamRefreshAt = await $.clock.now()
  await refresh($)
}

async function startWorkWatch($: EngineInterface, root: string) {
  if (memory.watchStarted) return
  const clock = await $.clock.now()
  if (clock < memory.watchRetryAt) return
  memory.watchStarted = true
  void (async () => {
    let pending = ''
    try {
      for await (const chunk of $.process.spawn({ argv: ['desk-work', 'watch', '--root', root, '--client', 'notebook', '--build', BUILD_ID] })) {
        if (chunk.stream !== 'stdout') continue
        pending += chunk.text
        if (pending.length > 65536) { pending = ''; continue }
        let split: number
        while ((split = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, split); pending = pending.slice(split + 1)
          try { if (JSON.parse(line)?.version === 1) { memory.watchFailed = false; memory.watchDelay = 1000; void refreshSoon($) } } catch { /* partial or older protocol */ }
        }
      }
    } catch { /* the recovery poll still works without the bridge */ }
    finally {
      memory.watchStarted = false; memory.watchFailed = true
      memory.watchRetryAt = await $.clock.now() + memory.watchDelay
      await reportWork($, root, ['--stream', 'retrying', '--retry-at', String(Math.floor(memory.watchRetryAt / 1000))])
      memory.watchDelay = Math.min(30000, memory.watchDelay * 2)
    }
  })()
}

async function reportWork($: EngineInterface, root: string, fields: string[]) {
  await work($, ['client-report', '--client', 'notebook', '--build', BUILD_ID, '--pid', 'parent', '--root', root, ...fields])
}

async function publishAgent($: EngineInterface, state: string, file?: string) {
  await work($, ['agent-update', '--root', await repoRoot($), '--agent', 'claude', '--session', await $.session.id(),
    '--pid', 'parent', '--state', state, '--build', BUILD_ID, '--title', memory.work ?? await nameNow($) ?? 'Claude', '--pane', await ownPane($) ?? '',
    ...(file === undefined ? [] : ['--file', file])])
}

async function saveNotebookView($: EngineInterface) {
  const { form, focused, snoozing, ...view } = await read($, notebookView)
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
    const projectWork = await workLook($, root, await $.session.id(), (await read($, notebookView)).page === 'health')
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
    const made: PaperLook = { root, session, branch, files, gate, plan, context, neighbours: near, card, work: projectWork, project, credits, lastNight: note, git, ci }
    await update($, look, () => made)
    memory.look = made
    memory.lookAt = await $.clock.now(); memory.lookFailed = false
    // One report per change of state, or a minute apart while all is well: each report is a locked write of the client
    // record, and a burst of edits is many refreshes.
    if (memory.reportedFailure !== (projectWork === null) || memory.lookAt - memory.reportedAt >= 60000) {
      memory.reportedFailure = projectWork === null; memory.reportedAt = memory.lookAt
      await reportWork($, root, projectWork ? ['--refresh-at', String(Math.floor(memory.lookAt / 1000)), '--error', ''] : ['--error', 'Work records could not be refreshed'])
    }
    const found = await readPeers($)
    await update($, peers, () => found ?? near.map(n => ({ id: n.sid, name: n.title, project: root.split('/').pop() ?? root,
      state: `edited ${n.files} ${n.files === 1 ? 'file' : 'files'} here`, busy: false,
      pane: otherLedgers.find(o => o.sid === n.sid)?.ledger.pane ?? '' })))

    const left = 5 - hearts(context)
    if (memory.lastHearts > 2 && left === 2) $.ui.toast(`context is ${context ?? 50}% used · a good moment for a handoff`)
    memory.lastHearts = left
    if (memory.lastGate === 'closed' && gate === 'open') $.ui.toast(`gate open ${glyph('checked')} the plan is approved`)
    memory.lastGate = gate
  } catch {
    // A missed refresh only leaves the notebook a little behind; the next one catches up. The page says so meanwhile.
    memory.lookFailed = true
    try { await reportWork($, await repoRoot($), ['--error', 'The notebook could not refresh its project view']) } catch { /* teardown has no live engine to report through */ }
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
      if (saved?.version === 1 && NAMED_PAGES.includes(saved.page))
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
    if (e.isInteractive && !memory.toldLastNight && (await latestLook($))?.lastNight) {
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
    await $.command.register({ name: 'notebook', description: RETRO ? 'Open the notebook' : 'Open the paper notebook', argumentHint: '[toggle|close|auto|compact|expand|files|all|project|sessions|timeline|digest|health|attention|help]', immediate: true })
    return started
  })

  on('command.run', { command: 'notebook' }, async ($, e) => {
    let page = e.args.trim()
    if (page && !['toggle', 'close', 'auto', 'compact', 'expand', 'all', ...NAMED_PAGES].includes(page))
      return { text: `/notebook knows ${NAMED_PAGES.join(', ')}, all, and toggle, close, compact, expand or auto.` }
    if (page === 'close' || page === 'toggle') {
      let open = memory.notebookOpen
      try { open = (await $.ui.panes()).some(pane => pane.id === PANE) } catch { /* older engines can use the in-session state */ }
      if (page === 'close' || open) {
        await $.ui.close({ id: PANE })
        memory.notebookOpen = false
        return { text: 'The notebook is hidden. /notebook toggle brings it back.' }
      }
      page = ''
    }
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
    if (page === 'all' || (NAMED_PAGES as readonly string[]).includes(page))
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
    const view = await read($, notebookView)
    const editing = view.form !== 'none' || await read($, writingTo) !== null
    await update($, notebookView, current => ({ ...current, form: 'none' as const, ...(editing ? { selected: '' } : {}), focused: '' }))
    await update($, writingTo, () => null)
    if (e.origin.kind === 'person' && editing) {
      memory.notebookOpen = true
      await $.ui.open({ id: PANE, title: 'notebook', ...paneSize({ ...view, form: 'none' }), focus: true })
      await $.ui.focus({ requestId: PANE, key: 'nav-back' }).catch(() => undefined)
      await saveNotebookView($)
      return { value: undefined }
    }
    const closed = await next(e)
    memory.notebookOpen = false
    await saveNotebookView($)
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
    // A refresh already under way began before the turn's last edit was recorded; refresh() reads once more after it.
    await refresh($)
    const seen = await latestLook($)
    // The receipt: what this turn changed, ran and committed.
    const began = (await read($, receipt))?.at ?? 0
    const start = memory.turnStart || began
    let touched: string[] = []
    if (start > 0 && seen) {
      const dir = await sessionsDir($)
      const sid = await $.session.id()
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
    // A turn that changed files and leaves files of this session unreviewed says so once, above the prompt, until
    // looked at. A turn that changed nothing (a question) says nothing.
    const mine = (seen?.files ?? []).filter(f => f.own).map(f => f.path)
    const left = unreviewed(mine, reviewStates(seen?.work?.review))
    if (touched.length > 0 || left === 0) await update($, nudge, () => left > 0 ? left : null)
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

  on('tool.call', async ($, e, next) => {
    await stillWorking($)
    try { return await next(e) } finally { await stillWorking($) }
  })

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
    if (greenAgain(finished)) $.ui.toast(RETRO ? 'TESTS OK' : 'green again ✿')
    if (COMMIT.test(e.command) && ran!.deny === undefined && ran!.isError !== true) {
      if (!RETRO) $.ui.toast(`a seed planted ${glyph('commit')}`)
      else {
        const where = e.command.match(/git\s+-C\s+(\S+)\s+commit/)?.[1]?.replace(/^['"]|['"]$/g, '') ?? await $.session.cwd()
        const sha = (await run($, ['git', '--no-optional-locks', '-C', where, 'rev-parse', '--short', 'HEAD']))?.trim() ?? ''
        $.ui.toast(/^[0-9a-f]{4,40}$/.test(sha) ? `COMMITTED ${sha}` : 'COMMITTED')
      }
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
      const from = first.match(ENVELOPE)?.[1] ?? ('teammate' in e.origin ? e.origin.teammate : 'another Claude')
      const body = e.text.trim().replace(ENVELOPE, '')
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
    // The notebook's front page draws the last turn itself; the band says it only while that page is out of sight.
    if (waiting !== null && !e.props.isWorking && !await frontPageShown($)) return (
      <Box>
        <Text color={paper.ribbon} weight="bold">{glyph('look')} turn done </Text>
        <Text color={paper.ink}>{clip(receiptLine(await read($, receipt)) || `${waiting} ${waiting === 1 ? 'file' : 'files'} changed`, Math.max(12, e.props.bodyColumns - 44))}</Text>
        <Text color={paper.dim}> · review pending </Text>
        <Button key="review" label="review" plain onPress={async () => {
          const opened = await workCall($, ['open', '--root', await repoRoot($), '--action', 'reviews'])
          if (!opened.ok) { $.ui.toast(opened.message); return }
          await update($, nudge, () => null)
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
      if (Object.keys(change).some(k => k !== 'selected' && k !== 'focused')) await saveNotebookView($)
    }
    const checkedWork = async (args: string[]) => {
      const result = await workCall($, args)
      // desk-work says why it refused (a message on stdout, or its error output); the toast shows exactly that.
      if (!result.ok) { $.ui.toast(result.message); return false }
      try {
        const value = JSON.parse(result.stdout)
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
    const launch = async (argv: string[], failure: string) => { if (await run($, argv) === null) $.ui.toast(failure) }
    const openJob = (id: string, action = 'log', index?: number) => checkedWork(['open', '--root', root, '--action', action, '--id', id,
      ...(index === undefined ? [] : ['--index', String(index)])])
    const page = async (value: NotebookView['page']) => {
      const current = await read($, notebookView)
      const opener = value === 'overview' ? '' : current.page === 'overview' ? current.selected : current.opener ?? ''
      await setView({ page: value, selected: value === 'overview' ? current.opener ?? '' : '', form: 'none', offset: 0, opener })
    }
    const row = (key: string, label: string, press: () => unknown, detail?: ReturnType<typeof Text>) => {
      navigation.push({ key, press })
      const selected = view.selected === key
      const inverted = e.surface === 'terminal' && e.props.isFocused && view.focused === key
      const scope = 'paper-row-' + navigation.length
      const hover = { scope, inverse: false, color: PICK.ink, backgroundColor: PICK.ground }
      // The terminal always inverts a focused Button. Give it the reversed pair
      // so the visible result is ink on blush (retro: the page on amber); hover cancels inversion itself.
      const paint = (node: RenderNode): RenderNode => {
        if (typeof node === 'string') return node
        if (node.type !== 'Text') return node
        return Text({ ...node.props, hover,
          ...(inverted ? { color: PICK.ground, backgroundColor: PICK.ink }
            : selected ? { color: PICK.ink, backgroundColor: PICK.ground } : {}),
          children: node.children?.map(paint) })
      }
      const body = <Text color={paper.ink}>
        <Text color={paper.ribbon}>{selected ? CHARS.cursor + ' ' : '  '}</Text>
        {detail ?? <Text color={paper.ink}>
          {LEADING.test(label)
            ? <Text><Text color={label.startsWith(glyph('failed')) ? paper.berry : label.startsWith(glyph('checked')) || label.startsWith(glyph('running')) ? paper.added : paper.ribbon}>{label.slice(0, 1)}</Text>{fit(label.slice(1), width - 3)}</Text>
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
    const text = (label: string, colour: string = paper.dim) => <Text color={colour}>{cut(label, width)}</Text>
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
      const plan = (await latestLook($))?.plan
      if (plan) await notePlan($, plan.file)
    }

    // Page rows, to the UI style (docs/ui-style.md): groups under rule lines, a mark and a name per row with its count
    // on the right, and under the list a line saying what the selected row is.
    const inner = Math.max(10, width - 2)
    const about: Record<string, string> = {}
    // A group's rule; retro prints its label in inverse capitals.
    const ruleNode = (label: string, right = '', colour: string = paper.ribbon) => {
      const [head, name, tail] = ruleParts(label, right, width)
      return RETRO ? <Text color={colour}>{head}<Text color={paper.page} backgroundColor={colour}>{name}</Text>{tail}</Text>
        : text(head + name + tail, colour)
    }
    const rule = (label: string, right = '') => content.push(ruleNode(label, right))
    const pair = (key: string, left: string, right: string, press: () => unknown, says: string, colour: string = paper.ink) => {
      // A row too long for the pane is cut with an ellipsis; its whole text then leads the description.
      const [drawn, side] = sides(left, right, inner)
      about[key] = drawn.trimEnd() !== left ? `${left.replace(/^[^\p{L}\p{N}]+/u, '')} ${CHARS.dash} ${says}` : says
      if (key.startsWith('attention-') && firstNeed === null) firstNeed = press
      // The button's own label reads whole ("✎ 2 changed · 0 reviewed") for screen readers and other surfaces.
      content.push(row(key, right ? `${left} · ${right}` : left, press, <Text>
        <Text color={colour}>{drawn}</Text><Text color={paper.dim}>{side}</Text>
      </Text>))
    }
    const describe = () => {
      const says = about[view.selected]
      if (says) { content.push(text('')); for (const line of wrapWords(says, width)) content.push(text(line)) }
    }
    const states = reviewStates(now?.work?.review)
    const requests = now?.work?.requests ?? []
    const ready = requests.filter(r => r.state === 'ready')
    const base = (path: string) => path.split('/').pop() ?? path
    const ci = ciLabel(now?.ci?.runs)
    // Everything that needs you, most urgent first: desk-work's shared list, then what only this session knows (a CI
    // run, another session's edit, notes). Each row's description says the next action.
    type Need = { key: string; left: string; right: string; press: () => unknown; says: string; colour: string; words: [string, string]; at?: number }
    const needs: Need[] = []
    {
      const reReview = (path: string) => checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', path, '--session', session])
      const changedSince = (now?.files ?? []).map(f => f.path).filter(p => states.get(p) === 'changed' && !ready.some(r => r.file === p))
      const failedIds = new Set((now?.work?.failures ?? []).map(j => j.id))
      const shared = now?.work?.attention
      if (shared) for (const item of shared) {
        const mark = glyph(item.kind === 'request' || item.kind === 'changed' ? 'changed' : item.kind === 'commit' ? 'unread' : 'failed')
        needs.push({ key: 'attention-' + item.id, left: `${mark} ${item.label}`,
          right: ({ request: 're-review', records: 'repair', job: 'failed', agent: 'waiting', commit: 'to review', changed: 'changed' } as Record<string, string>)[item.kind] ?? item.kind,
          press: () => checkedWork(['open', '--root', item.root, '--action', 'attention', '--id', item.id]),
          says: item.why + '. Enter opens it.', colour: item.kind === 'job' || item.kind === 'agent' || item.kind === 'records' ? paper.berry : paper.ink,
          words: needGroup(item.kind, item.action?.kind), ...(item.kind === 'commit' ? { at: item.at } : {}) })
      }
      if (!shared) for (const job of (now?.work?.failures ?? []).slice(0, 2))
        needs.push({ key: `attention-job-${job.id}`, left: `${glyph('failed')} ${job.title ?? job.command}`, right: job.state, press: () => openJob(job.id),
          says: 'A job that failed and has not passed since. Enter opens its output.', colour: paper.berry, words: needGroup('job') })
      const lastTests = now?.work?.tests
      if (!shared && lastTests && lastTests.state === 'failed' && !failedIds.has(lastTests.id))
        needs.push({ key: 'attention-tests', left: `${glyph('failed')} tests failed`, right: ago(clock / 1000 - (lastTests.ended ?? clock / 1000)), press: () => openJob(lastTests.id, 'tests'),
          says: 'The last test run failed. Enter opens the failures, each a jump to its line.', colour: paper.berry, words: needGroup('job', 'tests') })
      if (ci && ci.state === 'failed')
        needs.push({ key: 'attention-ci', left: `${glyph('failed')} CI failed on the push`, right: 'open run', press: async () => { if (/^https:\/\/github\.com\//.test(ci.url)) await launch(['xdg-open', ci.url], 'The browser did not open.') },
          says: 'GitHub Actions failed on the pushed commit. Enter opens the run in the browser.', colour: paper.berry, words: needGroup('ci') })
      if (!shared) for (const r of ready.slice(0, 3))
        needs.push({ key: `attention-request-${r.file}`, left: `${glyph('changed')} ${base(r.file)}`, right: 're-review', press: () => reReview(r.file),
          says: `You asked ${r.name || 'a session'}: "${r.text}". The file has changed since. Enter opens it for another look.`, colour: paper.ink, words: needGroup('request') })
      if (!shared && changedSince.length) {
        const first = changedSince[0] ?? ''
        needs.push({ key: 'attention-changed', left: `${glyph('changed')} ${changedSince.length} changed since you reviewed`, right: base(first), press: () => reReview(first),
          says: 'Edited after you checked them. Enter opens the first; the review shows only what is new.', colour: paper.ink, words: needGroup('changed') })
      }
      if (warning) needs.push({ key: 'attention-overlap', left: 'shared edit · ' + (warning.path.split('/').pop() ?? ''), right: warning.ago ?? '', press: async () => {
        if (warning.pane) await launch(['desk-drawer', 'run', 'claude-jump', warning.pane], 'That session\'s window could not be reached.')
        else await page('files')
      }, says: 'Another live session edited this file lately. Enter goes to it.', colour: paper.berry, words: needGroup('overlap') })
      if (mail.length) needs.push({ key: 'attention-mail', left: `${glyph('sent')} notes for this session`, right: `${mail.length} unread`, press: () => page('sessions'),
        says: 'Notes left for this session from Neovim or another Claude. Enter reads them.', colour: paper.ink, words: needGroup('mail') })
      const installed = now?.work?.integration
      if (installed?.status === 'reload-pending') {
        const steps = installed.sessions?.find(s => s.client === 'notebook' && s.status === 'reload-pending')?.reload
        needs.push({ key: 'reload-pending', left: `${glyph('changed')} update installed`, right: 'reload to use it', press: () => page('health'),
          says: `This session still runs the older notebook. ${steps ?? installed.message} Enter opens work health, which lists every session on older code with its own steps.`,
          colour: paper.ribbon, words: ['update to load', 'updates to load'] })
      }
      // Credit running low is an alarm like a failed test: it joins the list rather than taking a row of its own.
      const credits = now?.credits
      if (credits && (credits.status === 'error' || (credits.remaining_percent != null && credits.remaining_percent <= 20)))
        needs.push({ key: 'api-credit-meter', left: `${glyph('failed')} ${credits.short}`,
          right: credits.meter ? credits.meter.replace(/▰/g, CHARS.meter[0]!).replace(/▱/g, CHARS.meter[1]!) + ' tracked' : '',
          press: () => launch(['desktop-menu', '--open', 'api-credits'], 'The drawer did not open.'),
          says: `${credits.headline}. Enter opens the monthly API credit details in the drawer.`, colour: paper.berry, words: ['credit low', 'credit low'] })
    }
    const breakdown = () => wrapParts(needBreakdown(needs.map(n => n.words)), Math.max(8, width - 2))
    // Something about this page itself: a refresh that did not finish, no work tool, a change stream that stopped. The
    // header shows one "!" for it (Enter there retries); the project page says which, with its own retry row.
    const age = memory.lookAt > 0 ? (clock - memory.lookAt) / 1000 : null
    const sync = memory.lookFailed || (age !== null && age > 180) ? 'This page may be out of date: the last refresh did not finish.'
      : now && !now.work ? 'desk-work did not answer, so tests, reviews and requests are not shown.'
      : memory.watchFailed && now?.work ? 'Live updates are delayed: the change stream stopped. The 20-second poll still refreshes this page.' : ''
    const retry = async () => { memory.watchRetryAt = 0; void startWorkWatch($, root); await refresh($) }
    if (view.compact && view.page === 'overview' && view.form === 'none') {
      const count = needs.length
      const stale = memory.lookFailed || memory.lookAt > 0 && clock - memory.lookAt > 180000
      return <Box flexDirection="column">
        {text(name ?? 'notebook', paper.ink)}
        <Button key="compact-attention" label={stale ? 'status needs a refresh' : now?.work ? count === 0 ? 'all quiet' : `${count} ${count === 1 ? 'needs' : 'need'} you` : 'work status unavailable'} plain
          onPress={() => setView({ compact: false, page: 'overview', selected: '' })} />
        {now?.work?.tests && text(testLabel(now.work.tests), testColour(now.work.tests))}
        <Box><Button key="compact-expand" label={memory.watchFailed && now?.work ? 'expand · delayed' : 'expand notebook'} hotkey="z" plain onPress={() => setView({ compact: false, page: 'overview', selected: '' })} />
          <Text> </Text><Button key="compact-hide" label="hide" hotkey="q" plain onPress={() => $.ui.close({ id: PANE })} /></Box>
      </Box>
    }

    if (view.form === 'none' && view.page === 'overview') {
      // The front page: the same groups in the same order every time, each a rule and one line (needs you up to three,
      // review its requests), so nothing moves while you read it. The rest is on the project page (p).
      const mine = (now?.files ?? []).filter(f => f.own).map(f => f.path)
      const done = await read($, receipt)
      const working = turnLabel(underway, clock)
      rule('needs you', needs.length ? String(needs.length) : '')
      if (!needs.length) content.push(text('  ' + (now?.work ? said('all quiet') : said('not known: work tool unavailable'))))
      else {
        firstNeed = needs[0]!.press
        if (needs.length <= 3) for (const need of needs) pair(need.key, need.left, need.right, need.press, need.says, need.colour)
        else {
          pair('attention-summary', `${glyph('failed')} ${needs.length} need you`, 'open list', () => page('attention'),
            `Everything that needs you, most urgent first. Enter lists it all; n opens the most urgent: ${needs[0]!.left.replace(/^\S+ /, '')}.`, paper.berry)
          // Two lines of counts at most; a cut list ends in an ellipsis rather than a dangling " ·".
          const counts = breakdown()
          for (const [i, line] of counts.slice(0, 2).entries())
            content.push(text('  ' + (i === 1 && counts.length > 2 ? line.replace(/ ·$/, ' ' + ELLIPSIS) : line)))
        }
      }

      // The last turn stays drawn while the next one runs, dimmed, with how long this one has run on its rule.
      rule('last turn', working ? working.replace(/^\S+ /, '').split(' · ')[0]! : done ? ago((clock - done.at) / 1000) : '')
      if (done) {
        // The row opens exactly what it names: the turn's own files (the first one not yet reviewed), or the commit.
        const still = (now?.files ?? []).map(f => f.path)
        const next_ = done.files.find(p => still.includes(p) && states.get(p) !== 'checked') ?? done.files.find(p => still.includes(p))
        const open = () => next_ !== undefined
          ? checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', next_, '--session', session])
          : done.commits[0] ? checkedWork(['open', '--root', root, '--action', 'reviews', '--id', done.commits[0].sha])
          : checkedWork(['open', '--root', root, '--action', 'reviews'])
        const alarm = done.risky.length > 0 || (done.tests !== null && !done.tests.startsWith(glyph('checked')))
        pair('receipt-files', `${glyph('look')} ${receiptLine(done)}`, '', open,
          next_ !== undefined ? `What the last turn changed, ran and committed. Enter opens ${next_.split('/').pop()}, the next one not reviewed.`
            : 'What the last turn changed, ran and committed. Enter opens it in the review.',
          working ? paper.dim : alarm ? paper.berry : paper.ink)
      } else content.push(text('  ' + (!working ? said('nothing changed yet') : underway?.step ? `${glyph('running')} ${underway.step}` : said('under way'))))

      const total = now?.plan?.total ?? 0, ticked = now?.plan?.done ?? 0
      rule('plan', now?.gate === 'closed' ? 'plan first' : '')
      if (now?.plan) {
        const step = now.plan.step || now.plan.next || ''
        pair('plan-open', step ? `${glyph('step')} ${step}` : `${glyph('plan')} ${workName(now.plan.title, null, now.plan.title)}`,
          total === 0 ? '' : ticked >= total ? stepLabel({ done: ticked, total }) : `${ticked + 1}/${total}`, () => openDocument(now.plan!.file),
          `The step in hand of "${now.plan.title}", ${ticked} of ${total} ticked. Enter opens the plan; the project page pins a step.`)
      } else pair('plan-pin', 'pin an active plan', '', () => setView({ form: 'plan' }), 'No plan read yet in this session. Enter pins one.', paper.dim)

      const summary = reviewSummary((now?.files ?? []).map(f => f.path), states)
      const waitingOn = requests.filter(r => r.state === 'waiting')
      rule('review', waitingOn.length > 0 ? `${waitingOn.length} sent` : '')
      const reviewed = (now?.files ?? []).filter(f => states.get(f.path) === 'checked').length
      // A record desk-work cannot read would make "0 reviewed" a false statement; say what is true.
      const marksUnreadable = (now?.work?.records ?? []).some(r => r.file === 'review-marks.json')
      const changedCount = now?.files.length ?? 0
      pair('page-files', `${glyph('look')} ${changedCount} changed`, marksUnreadable ? 'review marks unreadable'
        : summary ? `${reviewed} reviewed` : mine.length ? `${mine.length} this session` : '', () => page('files'),
        'Files that differ from the last commit, and how many of them were reviewed as they are now. Enter lists them.', changedCount ? paper.ink : paper.dim)
      // Requests still with a session: who was asked and what for, until the file changes (then it needs you, above).
      for (const r of waitingOn.slice(0, waitingOn.length > 2 ? 1 : 2))
        pair(`request-${r.file}`, `${glyph('sent')} ${base(r.file)}`, 'sent · ' + (r.name || 'a session'), () => setView({ page: 'request', request: r.file, selected: '' }),
          `Sent to ${r.name || 'a session'} ${ago(clock / 1000 - r.at)}: "${r.text}". The file has not changed yet. Enter opens the thread: send it again or withdraw it.`)
      if (waitingOn.length > 2) content.push(text(`  and ${waitingOn.length - 1} more sent`))

      rule('work')
      const job = (now?.work?.jobs ?? [])[0]
      if (job) pair(`job-${job.id}`, `${glyph('running')} ${job.title ?? job.command} · ${Math.floor(job.elapsed / 60)}m`, ci?.label ?? '', () => openJob(job.id),
        'Running now. Enter opens its output; the project page shows how it compares with its last pass.', paper.ink)
      else if (now?.work?.tests) pair('work-tests', testLabel(now.work.tests, clock / 1000), ci?.label ?? '', () => openJob(now.work!.tests!.id, 'tests'),
        'The last test run here, whether the code changed since, and CI on the push. Enter opens the failures.', testColour(now.work.tests))
      else if (ci) pair('work-ci', ci.label, '', async () => { if (/^https:\/\/github\.com\//.test(ci.url)) await launch(['xdg-open', ci.url], 'The browser did not open.') },
        'GitHub Actions on the pushed commit. Enter opens the run.', ci.state === 'failed' ? paper.berry : ci.state === 'passed' ? paper.added : paper.dim)
      else content.push(text('  ' + (now?.work ? said('no test runs yet') : said('work tool unavailable'))))
    }

    if (view.form === 'none' && view.page === 'attention') {
      // The whole needs-you list, most urgent first, twenty to a page; each row opens what it names.
      firstNeed = needs[0]?.press ?? null
      // The commits to review come after everything else, by day, the newest day first (within a day in the order
      // desk-work gives); each day under a heading that is not a row, so j and k pass over it.
      const day = (at: number) => { const d = new Date(at * 1000); return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}` }
      const dayLabel = (at: number) => { const d = new Date(at * 1000)
        return `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]} ${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
      const dated = needs.filter(n => n.at !== undefined)
      const perDay = new Map<string, number>()
      for (const n of dated) perDay.set(day(n.at!), (perDay.get(day(n.at!)) ?? 0) + 1)
      const listed = [...needs.filter(n => n.at === undefined),
        ...dated.map((n, i) => ({ n, i })).sort((a, b) => (day(a.n.at!) === day(b.n.at!) ? a.i - b.i : b.n.at! - a.n.at!)).map(x => x.n)]
      const offset = Math.min(view.offset, Math.max(0, Math.floor((listed.length - 1) / 20) * 20))
      rule('needs you', String(listed.length))
      if (!listed.length) content.push(text('nothing needs you here', paper.dim))
      else for (const line of breakdown()) content.push(text(line))
      let heading = ''
      for (const need of listed.slice(offset, offset + 20)) {
        if (need.at !== undefined && day(need.at) !== heading) {
          heading = day(need.at)
          content.push(ruleNode(dayLabel(need.at), String(perDay.get(heading) ?? 0), paper.dim))
        }
        pair(need.key, need.left, need.right, need.press, need.says, need.colour)
      }
      if (offset > 0) content.push(row('attention-previous', '↑ more urgent', () => setView({ offset: offset - 20, selected: '' })))
      if (listed.length > offset + 20) content.push(row('attention-next', `↓ ${listed.length - offset - 20} more`, () => setView({ offset: offset + 20, selected: '' })))
      // The review backlog: set aside to catch up later (it stays unreviewed in the review), or brought back.
      const commits = needs.filter(n => n.key.startsWith('attention-commit:')).length
      if (commits > 0 || now?.work?.aside) rule('backlog')
      if (commits > 0) pair('needs-aside', `set aside ${commits} ${commits === 1 ? 'commit' : 'commits'} to review`, 'catch up later', () => setView({ form: 'aside' }),
        'They leave this list and stay unreviewed in the review, for when you want to catch up. Bring back undoes it.', paper.dim)
      const aside = now?.work?.aside
      if (aside) pair('needs-bring-back', `bring back ${aside.count} set-aside ${aside.count === 1 ? 'commit' : 'commits'}`, 'undo', async () => {
        if (await checkedWork(['set-aside', '--root', root, '--undo', 'yes'])) await refresh($)
      }, `Set aside ${ago(clock / 1000 - aside.at)}. Enter puts them back into what needs you.`, paper.dim)
      describe()
    }

    if (view.form === 'none' && view.page === 'request') {
      // One request's thread: what was asked of whom, where it stands, and the three things to do about it.
      const thread = (now?.work?.requests ?? []).find(r => r.file === view.request)
      if (!thread) content.push(text('That request is settled.'))
      else {
        rule('request', ago(clock / 1000 - thread.at))
        content.push(text(glyph(thread.state === 'ready' ? 'changed' : 'sent') + ' ' + thread.file, paper.ink))
        content.push(text('to ' + (thread.name || 'a session')))
        content.push(text(thread.state === 'ready' ? 'the file has changed since' : 'the file has not changed yet', thread.state === 'ready' ? paper.added : paper.dim))
        for (const line of wrapWords(`"${thread.text}"`, Math.max(8, width - 2))) content.push(text('  ' + line, paper.ink))
        content.push(row('request-open', thread.state === 'ready' ? `${glyph('changed')} re-review the file` : 'open the file',
          () => checkedWork(['open', '--root', root, '--action', 'file-diff', '--file', thread.file, '--session', session])))
        const peer = others.find(p => p.id === thread.sid)
        content.push(row('request-again', `${glyph('sent')} ` + (peer ? 'send it again' : 'send again · session ended'), async () => {
          if (!peer) { $.ui.toast('That session is no longer running. Withdraw this, then ask a live one from the review.'); return }
          // Delivery retries keep the original baseline: an answered request must stay ready for re-review.
          if (await sendNote($, peer, `Change request (again) for ${thread.file}: ${thread.text}`)) await refresh($)
        }))
        content.push(row('request-withdraw', `${CHARS.withdraw} withdraw it`, async () => {
          if (await checkedWork(['review-request', '--root', root, '--file', thread.file, '--clear', 'yes'])) { await refresh($); await page('overview') }
        }))
      }
      content.push(row('request-back', 'back', () => page('overview')))
    }

    if (view.form === 'none' && view.page === 'help') {
      const line = (mark: string, words: string) => wrapWords(words, Math.max(8, width - 7)).forEach((part, i) =>
        content.push(<Text><Text color={paper.ribbon}>{('  ' + (i === 0 ? mark : '')).padEnd(7)}</Text><Text color={paper.ink}>{part}</Text></Text>))
      rule('marks')
      for (const [shown, means] of Object.values(MARKS)) line(shown, means)
      line('!', 'in the header: this page is out of date or not live; the project page says which and retries')
      rule('keys')
      line('j k', 'move down and up')
      line(`l ${CHARS.enter}`, 'open the selected row')
      line('h', 'back to the front page')
      line('p', 'from the front page: the project page (branch, tasks, sessions, history)')
      line('n', 'the next thing that needs you')
      line('s', 'on a needs-you row from the project list: snooze it')
      line('e', 'on files: open the selected file to edit')
      line('d', 'the same page in the drawer')
      line('z', 'the compact notebook')
      line('q', 'hide the notebook')
      rule('words')
      for (const words of ['plan first: edits wait for an approved plan (the status line says when the gate is open)',
        'needs you: what failed, or is ready for another look; past three items it folds into one line, and Enter lists them'])
        wrapWords(words, Math.max(8, width - 2)).forEach((part, i) => content.push(text((i === 0 ? '  ' : '    ') + part, paper.ink)))
      content.push(row('help-back', 'back', () => page('overview')))
    }

    if (view.form === 'none' && view.page === 'files') {
      content.push(row('scope-session', (view.scope === 'session' ? CHARS.on : CHARS.off) + ' this session', () => setView({ scope: 'session', offset: 0, selected: '' })))
      content.push(row('scope-all', (view.scope === 'all' ? CHARS.on : CHARS.off) + ' all changes', () => setView({ scope: 'all', offset: 0, selected: '' })))
      const scoped = (now?.files ?? []).filter(f => view.scope === 'all' || f.own)
      const reviewed = reviewStates(now?.work?.review)
      // Filters: only what needs a review, only what changed since its review, and a part of a name. They persist.
      const show = view.show ?? 'all'
      const needing = scoped.filter(f => reviewed.get(f.path) !== 'checked').length
      const changedCount = scoped.filter(f => reviewed.get(f.path) === 'changed').length
      const nextShow = show === 'all' ? 'unreviewed' : show === 'unreviewed' ? 'changed' : 'all'
      content.push(row('files-show', show === 'all' ? `${CHARS.off} showing everything · ${needing} need review`
        : show === 'unreviewed' ? `${CHARS.on} only what needs review · ${needing}` : `${CHARS.on} only changed since review · ${changedCount}`,
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
        const mark = summary ? glyph(state === 'checked' ? 'checked' : state === 'changed' ? 'changed' : 'unread') + ' ' : ''
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
      // What the header's "!" stands for, with its retry.
      if (memory.lookFailed || (age !== null && age > 180))
        pair('refresh-now', `${glyph('changed')} this page may be out of date`, 'retry', retry,
          'The last refresh did not finish, so what is shown may be old. Enter reads everything again now.', paper.berry)
      else if (now && !now.work)
        pair('refresh-now', 'work tool unavailable', 'retry', retry,
          'desk-work did not answer, so tests, reviews and requests are not shown. Enter tries again.', paper.dim)
      if (memory.watchFailed && now?.work) pair('watch-retry', 'live updates delayed', 'retry', retry,
        'The change stream stopped. The recovery poll still refreshes this page; Enter reconnects it.', paper.dim)
      // Where the checkout stands against the push; the branch's name is on the status line.
      const standing = syncLabel(now?.git)
      if (standing) content.push(text(standing, paper.ink))
      if (ci) pair('work-ci', ci.label, '', async () => { if (/^https:\/\/github\.com\//.test(ci.url)) await launch(['xdg-open', ci.url], 'The browser did not open.') },
        'GitHub Actions on the pushed commit. Enter opens the run.', ci.state === 'failed' ? paper.berry : ci.state === 'passed' ? paper.added : paper.dim)
      if (now?.plan) {
        content.push(row('plan-open', (now.plan.pinned ? glyph('plan') + ' ' : '') + now.plan.title, () => openDocument(now.plan!.file)))
        planRuler()
        content.push(row('plan-pin', now.plan.pinned ? 'change active plan' : 'pin this plan', () => now.plan?.pinned ? setView({ form: 'plan' }) : pin(now.plan!.file)))
        content.push(row('plan-step', now.plan.step ? `${glyph('step')} ${now.plan.step}` : '+ current step', () => setView({ form: 'step' })))
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
      for (const job of now?.work?.jobs ?? []) jobRow(job, `${glyph('running')} ${job.title ?? job.command}`)
      // The figures the last job printed, each against the previous run of the same job (desk-work metrics).
      const figures = now?.work?.metrics
      if (figures?.job && figures.metrics.length) {
        const job = figures.job
        content.push(text(said('figures') + ' · ' + (job.title || job.command) + (job.ended ? ' ' + ago(clock / 1000 - job.ended) : ''), paper.ribbon))
        const against = figures.previous ? `the run of ${ago(clock / 1000 - figures.previous.ended)}` : 'nothing yet: this is its first run with figures'
        for (const m of figures.metrics.slice(0, 8)) {
          const [left, right] = metricLabel(m)
          pair('metric-' + m.name, left, right, () => openJob(job.id),
            `${m.name} against ${against}${m.better ? `; ${m.better} is better` : ''}. Enter opens the job's output.`,
            m.verdict === 'worse' ? paper.berry : m.verdict === 'better' ? paper.added : paper.ink)
        }
        if (figures.metrics.length > 8) content.push(text(`  ${figures.metrics.length - 8} more in desk-work metrics`))
      }
      if (now?.work) {
        for (const task of now.work.tasks.filter(t => !t.done)) {
          content.push(row(`task-draft-${task.id}`, `${glyph('step')} ${task.text}`, () => checkedWork(['open', '--root', root, '--action', 'tasks', '--id', task.id])))
          content.push(row(`task-done-${task.id}`, '  mark done', async () => {
            await checkedWork(['task-toggle', '--root', root, '--id', task.id, '--done', 'yes']); await refresh($)
          }))
        }
        content.push(row('task-add', '+ next step', () => setView({ form: 'task' })))
      }
      if (now?.card) {
        content.push(text(dosText(now.card.title), paper.ribbon))
        for (const [i, item] of now.card.rows.slice(0, 24).entries()) {
          const label = dosText(`${item.mark ? item.mark + ' ' : ''}${item.text}`)
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
      rule('more')
      const digest = now?.work?.digest
      if (digest?.total) pair('page-digest', 'since you last looked' + (digest.since ? ' ' + digest.since : ''), `${digest.total} events`, () => page('digest'),
        'Observed edits, requests and test results since you last marked this project caught up. Opening does not clear it.')
      // Counted with this one, so four running reads as "4 sessions".
      if (others.length) pair('page-sessions', `${others.length + 1} sessions`, '', () => page('sessions'),
        'The other agent sessions on this machine. Enter lists them, to go to one or leave it a note.')
      pair('page-help', 'marks and keys', '', () => page('help'), 'What each mark means and which keys work here.', paper.dim)
      pair('page-timeline', 'project timeline', '', () => page('timeline'), 'The shared history of requests, edits, tests and reviews.')
      pair('page-health', 'work health', '', () => page('health'), 'Loaded versions, refresh times, connection recovery and update backups.', paper.dim)
      describe()
    }

    if (view.form === 'none' && view.page === 'sessions') {
      if (mail.length) content.push(row('mail-clear', 'mark all notes read', () => acknowledgeMail($, mail)))
      for (const note of mail) {
        content.push(text(`${glyph('sent')} from ${note.from}`, paper.ribbon))
        const lines = wrapWords(note.text, Math.max(8, width))
        for (const [i, line] of lines.slice(0, 3).entries()) content.push(text(i === 2 && lines.length > 3 ? cut(line + ' ' + ELLIPSIS, width) : line, paper.ink))
        content.push(row(`envelope-${note.id ?? note.at}`, 'mark read', () => acknowledgeMail($, [note])))
      }
      if (others.length) content.push(text(`${others.length + 1} sessions · you and ${others.length} ${others.length === 1 ? 'other' : 'others'}`))
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
      const greeting = digest?.greeting ?? digest?.summary
      if (view.page === 'digest' && greeting) for (const line of wrapWords(greeting, width)) content.push(text(line, paper.ink))
      if (!events.length) content.push(text(view.page === 'digest' && digest && !digest.total ? 'Caught up: nothing new since you last marked it.' : 'No recorded events here yet.'))
      const offset = Math.min(view.offset, Math.max(0, Math.floor((events.length - 1) / 20) * 20))
      for (const event of events.slice(offset, offset + 20)) {
        const [label, when] = sides(event.label, ago(clock / 1000 - event.at), width - 2)
        content.push(row('event-' + event.id, event.label, () => checkedWork(['open', '--root', root, '--action', 'event', '--id', event.id]),
          <Text>{label}<Text color={paper.dim}>{when}</Text></Text>))
      }
      if (view.page === 'digest' && digest?.total) content.push(row('digest-caught-up', 'mark these events caught up', async () => {
        if (await checkedWork(['digest', '--root', root, '--consumer', 'notebook', '--through', String(digest.through)])) await refresh($)
      }))
      if (digest?.truncated && view.page === 'digest') content.push(text('Older events have expired; this digest is partial.'))
      if (events.length > 20) content.push(row('events-next', offset + 20 < events.length ? 'older events' : 'newest events',
        () => setView({ offset: offset + 20 < events.length ? offset + 20 : 0 })))
    }
    if (view.form === 'none' && view.page === 'health') {
      const checks = now?.work?.health?.checks ?? []
      // desk-work adds health only when asked, and the page asks as it opens: no answer yet is not a failure.
      if (!checks.length) content.push(text(now?.work && now.work.health === undefined ? 'Reading work health' + ELLIPSIS : 'Health details are unavailable; refresh to try again.'))
      for (const check of checks) {
        content.push(text(check.label, paper.ink))
        for (const line of check.detail.split('\n')) for (const part of wrapWords(line, width)) content.push(text(part))
        content.push(text(''))
      }
      content.push(row('health-controls', 'open recovery and backup controls', () => checkedWork(['open', '--root', root, '--action', 'health'])))
      content.push(row('health-refresh', 'refresh health', () => refresh($)))
    }
    if (view.form === 'snooze') {
      const selected = now?.work?.attention?.find(item => 'attention-' + item.id === (view.snoozing || view.selected))
      if (selected) {
        content.push(text(selected.label, paper.ink))
        for (const [key, label, option] of [['hour', 'later · one hour', '--seconds'], ['change', 'until this item changes', '--until-change']] as const)
          content.push(row('snooze-' + key, label, async () => {
            if (await checkedWork(['snooze', '--root', root, '--id', selected.id, option, key === 'hour' ? '3600' : 'yes'])) {
              await setView({ form: 'none', selected: '', snoozing: '' }); await refresh($)
            }
          }))
      } else content.push(text('That attention item is already settled.'))
    }
    if (view.form === 'aside') {
      const commits = needs.filter(n => n.key.startsWith('attention-commit:')).length
      content.push(text(`Set aside ${commits} ${commits === 1 ? 'commit' : 'commits'} to review?`, paper.ink))
      content.push(text('They stay unreviewed in the review; bringing them back undoes it.'))
      content.push(row('aside-confirm', 'set them aside', async () => {
        if (await checkedWork(['set-aside', '--root', root])) { await setView({ form: 'none', selected: '' }); await refresh($) }
      }))
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
    const activate = () => (view.selected ? navigation.find(n => n.key === view.selected) : navigation[0])?.press()
    const snoozable = view.form === 'none' && (now?.work?.attention ?? []).some(item => 'attention-' + item.id === view.selected)
    const back = () => view.form !== 'none' ? setView({ form: 'none' }) : page('overview')
    const nextNeed = firstNeed as (() => unknown) | null
    const front = view.page === 'overview' && view.form === 'none'
    // The header: the work's name, unread notes and one "!" when the page is not current (Enter on it retries).
    const mailWords = mail.length > 0 ? `${glyph('sent')} ${mail.length}` : ''
    const room = Math.max(4, width - (mailWords ? mailWords.length + 1 : 0) - (sync ? 2 : 0))
    const header = <Box key="header">
      <Text color={paper.ink}>{fit(name ?? 'notebook', room).padEnd(room)}</Text>
      {mailWords !== '' && <Text color={paper.ribbon}>{' ' + mailWords}</Text>}
      {sync !== '' && <Text> </Text>}
      {sync !== '' && <Button key="sync-retry" label="!" plain onPress={async () => { $.ui.toast(sync + ' Retrying now.'); await retry() }}>
        <Text color={paper.berry} weight="bold">!</Text>
      </Button>}
    </Box>
    // The key bar. The terminal draws a plain Button with a hotkey as "h: back" (the key in the accent colour, a colon,
    // the label), so each key is one Button whose label is only its word; retro's words are capitals on the selection
    // colour, the way Norton's bar sat its words on a block. Each group is packed into lines no wider than the pane,
    // so the terminal never wraps it, and the same groups are drawn every time, so the bar's height never changes.
    type Key = { key: string; hotkey?: string; word: string; press: () => unknown }
    const drawnWidth = (k: Key) => (k.hotkey ? k.hotkey.length + 2 : 0) + said(k.word).length
    const keyLines = (id: string, keys: Key[]) => {
      const lines: Key[][] = []
      let line: Key[] = [], used = 0
      for (const k of keys) {
        const add = (line.length ? 2 : 0) + drawnWidth(k)
        if (line.length && used + add > width) { lines.push(line); line = []; used = 0 }
        line.push(k); used += line.length > 1 ? add : drawnWidth(k)
      }
      if (line.length) lines.push(line)
      return lines.map((keysOnLine, n) => <Box key={`${id}-${n}`}>{keysOnLine.flatMap((k, i) => [
        ...(i > 0 ? [<Text key={`${id}-${n}-gap-${i}`}>{'  '}</Text>] : []),
        <Button key={k.key} label={said(k.word)} {...(k.hotkey ? { hotkey: k.hotkey } : {})} plain onPress={k.press}>
          {RETRO ? <Text color={paper.ink} backgroundColor={paper.selection}>{said(k.word)}</Text> : said(k.word)}
        </Button>])}</Box>)
    }
    const hideKey: Key = { key: 'nav-hide', ...(view.form === 'none' && writingId === null ? { hotkey: 'q' } : {}), word: 'hide', press: () => $.ui.close({ id: PANE }) }
    const moveKeys: Key[] = [{ key: 'nav-down', hotkey: 'j', word: '↓', press: () => move(1) }, { key: 'nav-up', hotkey: 'k', word: '↑', press: () => move(-1) }]
    const openKey: Key = { key: 'nav-open', hotkey: 'l', word: 'open', press: activate }
    const nextKey: Key[] = nextNeed !== null ? [{ key: 'nav-next', hotkey: 'n', word: 'next', press: () => nextNeed() }] : []
    const laterKey: Key[] = snoozable ? [{ key: 'nav-snooze', hotkey: 's', word: 'later', press: () => setView({ form: 'snooze', snoozing: view.selected }) }] : []
    const drawerKey: Key = { key: 'nav-drawer', hotkey: 'd', word: 'drawer', press: () => launch(['desktop-menu', '--open', drawerPage(view.page)], 'The drawer did not open.') }
    const compactKey: Key = { key: 'nav-compact', hotkey: 'z', word: 'compact', press: () => setView({ compact: true, page: 'overview', form: 'none', selected: '' }) }
    const selectedFile = () => (now?.files ?? []).find(f => `file:${f.path}` === view.selected)
    const fileKeys: Key[] = view.page === 'files' && view.form === 'none' ? [
      { key: 'nav-editor', hotkey: 'e', word: 'edit', press: () => { const f = selectedFile(); if (f) return openFile(f.path, true) } },
      { key: 'nav-file-tests', word: 'tests', press: () => { const f = selectedFile(); if (f) return checkedWork(['open', '--root', root, '--action', 'suggested-tests', '--file', f.path]) } }] : []
    // The front page: moving and opening on one line, the rest on the next, both always drawn.
    const frontBar = [...keyLines('keys', [...moveKeys, openKey, ...nextKey, ...laterKey]),
      ...keyLines('keys-more', [{ key: 'nav-more', hotkey: 'p', word: 'more', press: () => page('project') }, drawerKey, compactKey, hideKey])]
    return <Box flexDirection="column">
      {header}
      {!front && keyLines('keys', [{ key: 'nav-back', hotkey: 'h', word: 'back', press: back }, ...moveKeys, openKey, ...nextKey])}
      {!front && keyLines('keys-more', [drawerKey, ...laterKey, compactKey, hideKey])}
      {!front && fileKeys.length > 0 && keyLines('keys-files', fileKeys)}
      {view.page !== 'overview' && <Box>
        {(['files', 'project', 'sessions'] as const).flatMap(value => [<Button key={'nav-page-' + value} label={value} plain onPress={() => page(value)} />, <Text key={'nav-gap-' + value}> </Text>])}
      </Box>}
      {content}
      {front && frontBar}
    </Box>
  })
}
