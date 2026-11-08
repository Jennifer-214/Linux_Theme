// Who edited what, shared between Claude sessions through $XDG_RUNTIME_DIR/foxml-claude/edits/<session>.json.
// Pure functions: register.tsx does the reading and writing.

export type EditEntry = { path: string; at: number }
// pane: the tmux pane the session runs in (%N), which is how Claude Code's peer list tells sessions apart.
export type Ledger = { title: string | null; root: string; pane?: string; edits: EditEntry[] }
export type Other = { sid: string; ledger: Ledger; live: boolean }
export type Overlap = { path: string; title: string; ago: string; pane?: string }

export const WINDOW_MS = 15 * 60 * 1000
const KEEP_MS = 60 * 60 * 1000
const KEEP = 50

export function parseLedger(text: string): Ledger | null {
  try {
    const data = JSON.parse(text) as Partial<Ledger>
    if (!data || typeof data !== 'object' || !Array.isArray(data.edits)) return null
    const edits = data.edits.filter(
      (e): e is EditEntry => !!e && typeof e.path === 'string' && typeof e.at === 'number',
    )
    const pane = typeof data.pane === 'string' && /^%[0-9]{1,6}$/.test(data.pane) ? data.pane : undefined
    return { title: typeof data.title === 'string' ? data.title : null, root: typeof data.root === 'string' ? data.root : '', pane, edits }
  } catch {
    return null
  }
}

// This session's ledger after an edit: newest first, one entry per file, an hour and fifty files at most.
export function addEdit(ledger: Ledger | null, path: string, at: number, title: string | null, root: string, pane?: string): Ledger {
  const kept = (ledger?.edits ?? []).filter(e => e.path !== path && at - e.at < KEEP_MS)
  const where = pane ?? ledger?.pane
  return { title: title ?? ledger?.title ?? null, root, ...(where ? { pane: where } : {}), edits: [{ path, at }, ...kept].slice(0, KEEP) }
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
export function neighbours(root: string, now: number, self: string, others: Other[]): { title: string; files: number }[] {
  return others
    .filter(o => o.sid !== self && o.live && root !== '' && o.ledger.root === root)
    .map(o => ({ title: nameOf(o), files: o.ledger.edits.filter(e => now - e.at <= WINDOW_MS).length }))
    .filter(n => n.files > 0)
}
