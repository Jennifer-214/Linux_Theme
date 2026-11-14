import type { NotebookView, PaperFile } from '../types'
import type { Ledger, Other } from './ledger'

// -z preserves tabs, newlines and non-ASCII names; a rename has two extra fields.
export function gitFiles(numstat: string, status: string): PaperFile[] {
  const files = new Map<string, PaperFile>()
  const parts = numstat.split('\0')
  for (let i = 0; i < parts.length; i++) {
    const match = parts[i]?.match(/^(\d+|-)\t(\d+|-)\t([\s\S]*)$/)
    if (!match) continue
    let path = match[3] ?? ''
    if (path === '') { i++; path = parts[++i] ?? '' }
    if (path) files.set(path, { path, added: match[1] === '-' ? null : Number(match[1]), removed: match[2] === '-' ? null : Number(match[2]) })
  }
  const entries = status.split('\0')
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i] ?? ''
    if (entry.length < 4) continue
    const code = entry.slice(0, 2), path = entry.slice(3)
    if (code.includes('R') || code.includes('C')) i++
    if (path && !files.has(path)) files.set(path, { path, added: null, removed: null, status: code === '??' ? 'new' : code.trim() })
  }
  return [...files.values()].sort((a, b) => a.path.localeCompare(b.path))
}

export function attributeFiles(files: PaperFile[], root: string, own: Ledger | null, others: Other[]): PaperFile[] {
  const mine = new Set((own?.all ?? own?.edits ?? []).map(e => e.path))
  return files.map(file => {
    const path = root.replace(/\/$/, '') + '/' + file.path
    const owners = others.filter(o => o.live && o.ledger.root === root && (o.ledger.all ?? o.ledger.edits).some(e => e.path === path))
      .map(o => ({ sid: o.sid, name: o.ledger.title ?? 'another session', ...(o.ledger.pane ? { pane: o.ledger.pane } : {}) }))
    return { ...file, own: mine.has(path), owners }
  })
}

export function shortPath(path: string, width: number): string {
  if (width < 2) return ''
  if (path.length <= width) return path
  return '…' + path.slice(-(width - 1))
}

export function fileColumns(files: PaperFile[]): [number, number] {
  return [Math.max(2, ...files.map(f => f.added === null ? 1 : String(f.added).length + 1)),
    Math.max(2, ...files.map(f => f.removed === null ? 1 : String(f.removed).length + 1))]
}

export function fileCounts(file: PaperFile, columns: [number, number]): [string, string] {
  return [(file.added === null ? '·' : '+' + file.added).padStart(columns[0]),
    (file.removed === null ? '·' : '−' + file.removed).padStart(columns[1])]
}

export async function mailId(from: string, body: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify([from, body])))
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('')
}

// The drawer page that shows the same thing at desk size: `d` in the notebook opens it.
// The pages /notebook <page> opens and a saved view may return to; the rest are reached from a row.
export const NAMED_PAGES: readonly NotebookView['page'][] = ['overview', 'files', 'project', 'sessions', 'timeline', 'digest', 'health', 'attention']
export function drawerPage(page: NotebookView['page']): string {
  return { overview: 'workbench', files: 'reviews', project: 'projects', sessions: 'agents', help: 'workbench', request: 'reviews', timeline: 'work-history', digest: 'work-digest', health: 'work-health', attention: 'attention' }[page]
}
