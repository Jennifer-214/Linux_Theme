// Who edited what, shared between Claude sessions through $XDG_RUNTIME_DIR/foxml-claude/edits/<session>.json.
// Pure functions: register.tsx does the reading and writing.

export type EditEntry = { path: string; at: number }
// pane: the tmux pane the session runs in (%N), which is how Claude Code's peer list tells sessions apart.
// all: every file this session edited, first edit first, kept for the whole session (the review list in nvim).
// before: file → its copy in edits/<session>/before/, kept only for a file that had uncommitted changes already.
export type Ledger = {
  title: string | null; root: string; pane?: string; edits: EditEntry[]
  all?: EditEntry[]; before?: Record<string, string>
  // The plan file this session read or wrote last, and when: nvim's :Plan opens it.
  plan?: string; plan_at?: number
}
export type Other = { sid: string; ledger: Ledger; live: boolean }
export type Overlap = { path: string; title: string; ago: string; pane?: string }

export const WINDOW_MS = 15 * 60 * 1000
const KEEP_MS = 60 * 60 * 1000
const KEEP = 50
const KEEP_ALL = 500

export function parseLedger(text: string): Ledger | null {
  try {
    const data = JSON.parse(text) as Partial<Ledger>
    if (!data || typeof data !== 'object' || !Array.isArray(data.edits)) return null
    const edits = data.edits.filter(
      (e): e is EditEntry => !!e && typeof e.path === 'string' && typeof e.at === 'number',
    )
    const pane = typeof data.pane === 'string' && /^%[0-9]{1,6}$/.test(data.pane) ? data.pane : undefined
    const all = Array.isArray(data.all)
      ? data.all.filter((e): e is EditEntry => !!e && typeof e.path === 'string' && typeof e.at === 'number')
      : undefined
    const before: Record<string, string> = {}
    if (data.before && typeof data.before === 'object')
      for (const [path, copy] of Object.entries(data.before))
        if (typeof copy === 'string' && /^[0-9]{1,4}\.txt$/.test(copy)) before[path] = copy
    return {
      title: typeof data.title === 'string' ? data.title : null, root: typeof data.root === 'string' ? data.root : '', pane, edits,
      ...(all ? { all } : {}), ...(Object.keys(before).length ? { before } : {}),
      ...(typeof data.plan === 'string' && typeof data.plan_at === 'number' ? { plan: data.plan, plan_at: data.plan_at } : {}),
    }
  } catch {
    return null
  }
}

// This session's ledger after an edit: newest first, one entry per file, an hour and fifty files at most.
// The paths a ledger says were edited at or after `since`. `edits` keeps each file's LATEST edit and `all` its
// first, so a file edited in an earlier turn and again in this one is found through `edits`; `all` covers a turn
// with more edits than `edits` holds.
export function editedSince(ledger: Ledger | null, since: number): string[] {
  const out = new Set<string>()
  for (const e of [...(ledger?.edits ?? []), ...(ledger?.all ?? [])]) if (e.at >= since) out.add(e.path)
  return [...out]
}
export function addEdit(ledger: Ledger | null, path: string, at: number, title: string | null, root: string, pane?: string): Ledger {
  const kept = (ledger?.edits ?? []).filter(e => e.path !== path && at - e.at < KEEP_MS)
  const where = pane ?? ledger?.pane
  const all = ledger?.all ?? []
  return {
    title: title ?? ledger?.title ?? null, root, ...(where ? { pane: where } : {}), edits: [{ path, at }, ...kept].slice(0, KEEP),
    all: all.some(e => e.path === path) ? all : [...all, { path, at }].slice(-KEEP_ALL),
    ...(ledger?.before ? { before: ledger.before } : {}),
    ...(ledger?.plan !== undefined && ledger.plan_at !== undefined ? { plan: ledger.plan, plan_at: ledger.plan_at } : {}),
  }
}

export function withPlan(ledger: Ledger | null, plan: string, at: number, root: string): Ledger {
  return { ...(ledger ?? { title: null, root, edits: [] }), plan, plan_at: at }
}

// The ledger with a before-copy noted for this file; the copy's name is the next free number.
export function addBefore(ledger: Ledger | null, path: string, root: string): { ledger: Ledger; copy: string } {
  const base: Ledger = ledger ?? { title: null, root, edits: [] }
  const before = { ...(base.before ?? {}) }
  const copy = `${Object.keys(before).length + 1}.txt`
  before[path] = copy
  return { ledger: { ...base, before }, copy }
}

// ─── Commit names: a commit's Claude-Session trailer → the title of the session that made it ──────────────────
// $XDG_STATE_HOME/foxml/claude-sessions.jsonl, one {url, title, at} per line, newest title per url.
export type SessionName = { url: string; title: string; at: number }
const KEEP_NAMES = 500

export function trailerUrl(body: string): string | null {
  const m = body.match(/^Claude-Session:\s*(https:\/\/\S+)\s*$/m)
  return m?.[1] ?? null
}

export function parseNames(text: string): SessionName[] {
  const names: SessionName[] = []
  for (const line of text.split('\n')) {
    try {
      const n = JSON.parse(line) as Partial<SessionName>
      if (n && typeof n.url === 'string' && typeof n.title === 'string' && typeof n.at === 'number')
        names.push({ url: n.url, title: n.title.slice(0, 120), at: n.at })
    } catch {
      // a blank or broken line: skipped
    }
  }
  return names
}

export function addName(names: SessionName[], url: string, title: string, at: number): SessionName[] {
  return [...names.filter(n => n.url !== url), { url, title: title.slice(0, 120), at }].slice(-KEEP_NAMES)
}

export function namesText(names: SessionName[]): string {
  return names.map(n => JSON.stringify(n)).join('\n') + (names.length ? '\n' : '')
}

// ─── Notes from nvim: foxml-claude/inbox/<session>/<time>-<rand>.json ─────────────────────────────────────────
export type Note = { from: string; text: string; file?: string; lines?: string; code?: string }

export function parseNote(raw: string): Note | null {
  try {
    const n = JSON.parse(raw) as Partial<Note>
    if (!n || typeof n.text !== 'string' || n.text.trim() === '' || n.text.length > 2000) return null
    const short = (v: unknown, max: number) => (typeof v === 'string' && v.length <= max ? v : undefined)
    const file = short(n.file, 500), lines = short(n.lines, 20), code = short(n.code, 8000)
    return {
      from: short(n.from, 40) ?? 'nvim', text: n.text.trim(),
      ...(file ? { file } : {}), ...(lines && /^[0-9]+(-[0-9]+)?$/.test(lines) ? { lines } : {}), ...(code ? { code } : {}),
    }
  } catch {
    return null
  }
}

// What Claude reads: the note in your words, then where it points and the code it quotes.
export function noteText(note: Note): string {
  const where = note.file ? `${note.file}${note.lines ? ':' + note.lines : ''}` : ''
  const fence = note.code?.includes('```') ? '~~~~' : '```'
  return [
    note.text,
    where ? `\n(${where})` : '',
    note.code ? `\n${fence}\n${note.code}\n${fence}` : '',
  ].join('')
}

export function agoText(ms: number): string {
  const minutes = Math.floor(ms / 60000)
  if (minutes < 1) return 'just now'
  return minutes === 1 ? '1 minute ago' : `${minutes} minutes ago`
}

function nameOf(other: Other): string {
  if (other.ledger.title) return other.ledger.title
  const folder = other.ledger.root.split('/').filter(Boolean).pop()
  return folder ? `a session in ${folder}` : 'another session'
}

// The live session that last edited this file within the window, if any; never this session itself.
export function overlapFor(path: string, now: number, self: string, others: Other[]): Overlap | null {
  let best: { other: Other; at: number } | null = null
  for (const other of others) {
    if (other.sid === self || !other.live) continue
    for (const edit of other.ledger.edits) {
      if (edit.path !== path || now - edit.at > WINDOW_MS || edit.at > now + 60000) continue
      if (!best || edit.at > best.at) best = { other, at: edit.at }
    }
  }
  if (!best) return null
  const pane = best.other.ledger.pane
  return { path, title: nameOf(best.other), ago: agoText(now - best.at), ...(pane ? { pane } : {}) }
}

// The other live sessions working in the same repo, with how many files each touched in the window.
export function neighbours(root: string, now: number, self: string, others: Other[]): { sid: string; title: string; files: number }[] {
  return others
    .filter(o => o.sid !== self && o.live && root !== '' && o.ledger.root === root)
    .map(o => ({ sid: o.sid, title: nameOf(o), files: o.ledger.edits.filter(e => now - e.at <= WINDOW_MS).length }))
    .filter(n => n.files > 0)
}
