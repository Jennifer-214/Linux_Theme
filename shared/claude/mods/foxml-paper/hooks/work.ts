import type { EngineInterface } from 'claude-code'
import type { CiRun, GitLook, ReviewProgress, TurnReceipt, WorkJob, WorkLook, WorkTest } from '../types'

export function shellQuote(s: string): string { return "'" + s.replace(/'/g, "'\\''") + "'" }
// A build, test or download is the command a segment starts with, not a word it mentions:
// "rg foo cmake/ tests/" is a search, "cd src && make" and "python3 -B tests/test_x.py" are jobs.
const RUNNER = /^(?:(?:make|ninja|cmake|ctest|pytest|cargo|meson|curl|wget|aria2c|llm-update)\b|(?:npm|pnpm|bun|go) (?:run )?(?:test|build)\b|python3? (?:-\S+ )*-m (?:unittest|pytest)\b|(?:python3?|node|bun) (?:-\S+ )*[\w.~\/-]*(?:test_\w+|\w+_test|\w+\.test)\.\w+|[\w.~\/-]*\/(?:test_\w+|\w+_test)\b)/
const PREFIX = /^(?:\w+=\S*\s+|command\s+|env\s+|nice\s+|timeout\s+(?:-\S+\s+)*\S+\s+)+/
// A heredoc's body is text the command reads, not commands: an edit script naming tests/test_x.py runs no test.
export function withoutHeredocs(command: string): string {
  return command.replace(/<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?(?:\n[ \t]*\2[ \t]*(?=\n|$)|$)/g, '<<$2')
}
export function canTrack(command: string): boolean {
  return command.length <= 4000 && !/^\s/.test(command) && !/&\s*$/.test(command) && !/desk-work|\bfjob\b|password|token|secret|authorization|\bpass\b|\bsudo\b|\bexport\b|sk-|ghp_| -u |--user /i.test(command)
    && withoutHeredocs(command).split(/&&|\|\||[;|\n()]/).some(part => RUNNER.test(part.trim().replace(PREFIX, '')))
}
// The command runs exactly as written (so auto mode reviews what really runs); desk-work only records it around the call.
export function beginArgs(command: string, root: string, session: string, title = ''): string[] {
  const named = title.trim() && !title.includes('\n') ? ['--title', title.trim().slice(0, 160)] : []
  return ['begin', '--root', root, '--session', session, '--pid', 'parent', '--command', command, ...named]
}
// What the call ended as: Claude Code reports "Exit code N" in an error's text; a denial or interruption never finished.
export function exitOf(ran: { deny?: string; isError?: boolean; text?: unknown; result?: unknown }): number {
  if (ran.deny !== undefined) return 130
  const result = ran.result as { interrupted?: boolean } | string | undefined
  if (typeof result === 'object' && result?.interrupted) return 130
  if (!ran.isError) return 0
  const said = typeof ran.text === 'string' ? ran.text : typeof result === 'string' ? result : ''
  const code = Number(said.match(/Exit code (\d+)/)?.[1] ?? 1)
  return Number.isInteger(code) && code > 0 && code < 256 ? code : 1
}
export function outputOf(ran: { text?: unknown; result?: unknown }): string {
  const result = ran.result as { stdout?: unknown; stderr?: unknown } | string | undefined
  if (typeof result === 'object' && result && (typeof result.stdout === 'string' || typeof result.stderr === 'string'))
    return [result.stdout, result.stderr].filter(part => typeof part === 'string' && part !== '').join('\n')
  return typeof ran.text === 'string' ? ran.text : typeof result === 'string' ? result : ''
}
// "2h ago": how long since, in the words a person uses.
export function ago(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  if (s < 172800) return 'yesterday'
  return `${Math.floor(s / 86400)} days ago`
}
// "✓ 128 passed 2h ago · 3 files changed since": what the last test run said, how old it is, and whether it still holds.
export function testLabel(test: WorkTest, now?: number): string {
  const p = test.tests?.passed, f = test.tests?.failed
  let head: string
  if (test.state === 'running') head = '◷ tests running'
  else if (test.state === 'passed') head = '✓ ' + (p == null ? 'tests passed' : `${p} passed`) + (f ? ` · ${f} failed` : '')
  else if (test.state === 'failed') head = f ? `${f} failed` + (p == null ? '' : ` · ${p} passed`) : 'tests failed'
  else if (test.state === 'interrupted') head = 'tests stopped early'
  else head = `tests ${test.state}`
  if (test.state !== 'running' && typeof test.ended === 'number' && typeof now === 'number' && test.ended > 0) head += ' ' + ago(now - test.ended)
  const changed = test.changedFiles?.length
  const freshness = changed ? ` · ${changed} ${changed === 1 ? 'file' : 'files'} changed since`
    : test.changedDuringRun ? ' · code changed while it ran'
    : test.stale ? ' · may be out of date' : ''
  return head + freshness
}
// git status --branch's first line: "## main...origin/main [ahead 2, behind 1]"; "[gone]" is an upstream deleted.
export function parseBranchLine(line: string): { branch: string; upstream: string | null; ahead: number; behind: number } {
  const m = line.replace(/^## /, '').match(/^(?:No commits yet on |Initial commit on )?(.*?)(?:\.\.\.(\S+))?(?: \[(.*)\])?$/)
  const branch = m?.[1] ?? '', notes = m?.[3] ?? ''
  const upstream = m?.[2] && !/\bgone\b/.test(notes) ? m[2] : null
  return { branch, upstream, ahead: Number(notes.match(/ahead (\d+)/)?.[1] ?? 0), behind: Number(notes.match(/behind (\d+)/)?.[1] ?? 0) }
}
// "polish/drawer · 2 unpushed · 2 worktrees": where this checkout stands against what was pushed.
export function branchLabel(git: GitLook | null | undefined, branch: string): string {
  const parts = [branch || 'no branch']
  if (git) {
    if (!git.upstream) parts.push('not pushed yet')
    else {
      if (git.ahead > 0) parts.push(`${git.ahead} unpushed`)
      if (git.behind > 0) parts.push(`${git.behind} to pull`)
      if (git.ahead === 0 && git.behind === 0) parts.push('pushed')
    }
    if (git.trees > 1) parts.push(`${git.trees} worktrees`)
  }
  return parts.join(' · ')
}
// The pushed commit's CI, from its GitHub Actions runs: running, failed (which), or passed. null when it has none.
export function ciLabel(runs: CiRun[] | null | undefined): { label: string; state: 'running' | 'failed' | 'passed' | 'other'; url: string } | null {
  if (!runs || runs.length === 0) return null
  const failed = runs.filter(r => r.status === 'completed' && (r.conclusion === 'failure' || r.conclusion === 'timed_out' || r.conclusion === 'startup_failure'))
  const open = runs.filter(r => r.status !== 'completed')
  if (failed.length) {
    const names = [...new Set(failed.map(r => r.workflowName || r.name || 'a check'))]
    return { label: `✗ CI · ${names[0]} failed` + (names.length > 1 ? ` and ${names.length - 1} more` : '') + (open.length ? ' · still running' : ''),
      state: 'failed', url: failed[0]!.url ?? '' }
  }
  if (open.length) return { label: `◷ CI running · ${runs.length - open.length} of ${runs.length} done`, state: 'running', url: open[0]!.url ?? '' }
  if (runs.every(r => r.conclusion === 'success' || r.conclusion === 'skipped' || r.conclusion === 'neutral'))
    return { label: '✓ CI passed', state: 'passed', url: runs[0]!.url ?? '' }
  return { label: `CI ${runs.find(r => r.conclusion !== 'success')?.conclusion ?? 'finished'}`, state: 'other', url: runs[0]!.url ?? '' }
}
// One state per file across the live reviews (working tree and sessions; a commit's review is about that commit, not
// the file as it is now): changed-since-review wins over checked, so nothing edited later reads as reviewed.
export function reviewStates(review: Record<string, ReviewProgress> | null | undefined): Map<string, 'checked' | 'changed'> {
  const out = new Map<string, 'checked' | 'changed'>()
  for (const [key, one] of Object.entries(review ?? {})) {
    if (/^[0-9a-f]{40}$/.test(key)) continue
    for (const [rel, mark] of Object.entries(one.files ?? {}))
      if (mark.state === 'changed' || !out.has(rel)) out.set(rel, mark.state)
  }
  return out
}
// "2 of 4 reviewed · 1 changed since": the files that still differ, counted against what was checked.
export function reviewSummary(paths: string[], states: Map<string, 'checked' | 'changed'>): string {
  if (!paths.length || !paths.some(p => states.has(p))) return ''
  const checked = paths.filter(p => states.get(p) === 'checked').length
  const changed = paths.filter(p => states.get(p) === 'changed').length
  return `${checked} of ${paths.length} reviewed` + (changed ? ` · ${changed} changed since` : '')
}
// The notebook's one review line: "3 changes to review · 2 files of yours unread · 1 changed since you looked".
// Empty when there is nothing to look at.
export function pendingLine(pending: number, own: string[], states: Map<string, 'checked' | 'changed'>): string {
  const changed = own.filter(p => states.get(p) === 'changed').length
  const unread = own.filter(p => !states.has(p)).length
  const parts = [
    pending > 0 ? `${pending} ${pending === 1 ? 'change' : 'changes'} to review` : '',
    unread > 0 ? `${unread} ${unread === 1 ? 'file' : 'files'} of yours unread` : '',
    changed > 0 ? `${changed} changed since you looked` : '',
  ].filter(Boolean)
  return parts.join(' · ')
}
// How many of this session's changed files nobody has reviewed as they are now.
export function unreviewed(own: string[], states: Map<string, 'checked' | 'changed'>): number {
  return own.filter(p => states.get(p) !== 'checked').length
}
// The one name for a piece of work, used by the notebook's header, the window title, the Terminals page and line
// blame: the plan's title when there is a plan (without "Plan:" or a leading date), else Claude's own session title,
// else the project.
export function workName(plan: string | null | undefined, session: string | null | undefined, project: string): string {
  const tidy = (s: string) => s.replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').trim()
  const planned = tidy(plan ?? '').replace(/^plan\s*[:—-]\s*/i, '').replace(/^\d{4}-\d{2}-\d{2}\s*[:—·-]?\s*/, '').replace(/\s*\(\d{4}-\d{2}-\d{2}\).*$/, '')
  const name = planned || tidy(session ?? '') || tidy(project) || 'Claude'
  return name.length > 60 ? name.slice(0, 59) + '…' : name
}
// One line for a finished turn: "3 files · tests passed · 1 commit · ⚠ /etc/pam.d". Empty when it left nothing.
export function receiptLine(receipt: TurnReceipt | null | undefined): string {
  if (!receipt) return ''
  const parts = [
    receipt.files.length ? `${receipt.files.length} ${receipt.files.length === 1 ? 'file' : 'files'}` : '',
    receipt.tests ?? '',
    receipt.commits.length ? `${receipt.commits.length} ${receipt.commits.length === 1 ? 'commit' : 'commits'}` : '',
    receipt.risky.length ? `⚠ ${receipt.risky[0]}` : '',
  ].filter(Boolean)
  return parts.join(' · ')
}
// The files page's filters: only what still needs a review (never checked, or edited since), only what was edited
// since its review, and a part of the path to find. They combine.
export function filterFiles<T extends { path: string }>(files: T[], states: Map<string, 'checked' | 'changed'>,
  show: 'all' | 'unreviewed' | 'changed' | undefined, query: string | undefined): T[] {
  const wanted = (query ?? '').trim().toLowerCase()
  return files.filter(f => {
    const state = states.get(f.path)
    if (show === 'unreviewed' && state === 'checked') return false
    if (show === 'changed' && state !== 'changed') return false
    return wanted === '' || f.path.toLowerCase().includes(wanted)
  })
}
// A left text and a right text on one line of `width`: the right one keeps its place, the left one gives way.
export function spread(left: string, right: string, width: number): string {
  if (right === '') return left.length > width ? left.slice(0, Math.max(1, width - 1)) + '…' : left
  const room = Math.max(4, width - right.length - 1)
  const shown = left.length > room ? left.slice(0, room - 1) + '…' : left
  return shown + ' '.repeat(Math.max(1, width - shown.length - right.length)) + right
}
// A group's rule line, to symdeps' menu rules: " ── label ─────── right ──".
export function ruleLine(label: string, right: string, width: number): string {
  const head = `── ${label} `
  const tail = right ? ` ${right} ──` : ''
  return head + '─'.repeat(Math.max(2, width - head.length - tail.length)) + tail
}
// "◷ working 14m · Run the drawer tests": the turn under way, from your message to now, and its latest step.
export const TURN_QUIET_MS = 15 * 60 * 1000
export function turnLabel(turn: { started: number; step: string; seen?: number } | null | undefined, nowMs: number): string | null {
  if (!turn || !(turn.started > 0)) return null
  // An interrupted turn never says it ended: after a quarter of an hour with no sign of life it is not "working".
  if (nowMs - (turn.seen ?? turn.started) > TURN_QUIET_MS) return null
  const minutes = Math.floor(Math.max(0, nowMs - turn.started) / 60000)
  const took = minutes < 1 ? 'working' : minutes < 60 ? `working ${minutes}m` : `working ${Math.floor(minutes / 60)}h ${minutes % 60}m`
  return '◷ ' + took + (turn.step ? ' · ' + turn.step : '')
}
// Markdown checkboxes outside code fences, counted the way desk-work's plan output counts them.
export function planProgress(text: string): { done: number; total: number } {
  let done = 0, total = 0, fence = false
  for (const line of text.split('\n')) {
    const t = line.trim()
    if (t.startsWith('```') || t.startsWith('~~~')) { fence = !fence; continue }
    const box = fence ? null : line.match(/^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]/)
    if (box) { total++; if (box[1] !== ' ') done++ }
  }
  return { done, total }
}
export function stepLabel(p: { done: number; total: number }): string {
  return p.done >= p.total ? `all ${p.total} ${p.total === 1 ? 'step' : 'steps'} done ✿` : `step ${p.done + 1} of ${p.total}`
}
// A little ruler: drawn up to `fraction`, with a pencil at the point when one is asked for.
export function ruler(fraction: number, length: number, pencil = false): [string, string, string] {
  const n = Math.max(3, length), at = Math.round(Math.min(1, Math.max(0, fraction)) * n)
  if (!pencil) return ['━'.repeat(at), '', '┄'.repeat(n - at)]
  const drawn = Math.min(at, n - 1)
  return ['━'.repeat(drawn), '✎', '┄'.repeat(n - drawn - 1)]
}
// How a running job compares with the last time the same command passed here; no estimate, no guess.
export function jobPace(job: WorkJob): { fraction: number; left: string } | { late: true } | null {
  const estimate = job.estimate
  if (typeof estimate !== 'number' || !(estimate > 0)) return null
  const left = estimate - job.elapsed
  if (left <= 0) return { late: true }
  return { fraction: job.elapsed / estimate, left: left < 60 ? 'under a minute left' : `about ${Math.round(left / 60)}m left` }
}
// desk-work finish says how many runs of this command failed in a row before; a pass after two or more is a recovery.
export function greenAgain(finished: string | null): boolean {
  try {
    const value = JSON.parse(finished ?? 'null') as { ok?: boolean; state?: string; testRun?: boolean; failedBefore?: number } | null
    return value?.ok === true && value.state === 'passed' && value.testRun === true && (value.failedBefore ?? 0) >= 2
  } catch { return false }
}
export async function work($: EngineInterface, args: string[], stdin?: string): Promise<string | null> {
  try {
    const out = await $.process.run(['desk-work', ...args], { timeoutMs: 10000, ...(stdin === undefined ? {} : { stdin }) })
    return out.exitCode === 0 ? out.stdout : null
  } catch { return null }
}
export async function workLook($: EngineInterface, root: string, session: string): Promise<WorkLook | null> {
  try {
    const value = JSON.parse(await work($, ['notebook', '--root', root, '--session', session]) ?? 'null') as WorkLook | null
    return value && Array.isArray(value.tasks) && Array.isArray(value.jobs) ? value : null
  } catch { return null }
}
