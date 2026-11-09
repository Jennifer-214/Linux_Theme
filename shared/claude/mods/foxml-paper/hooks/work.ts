import type { EngineInterface } from 'claude-code'
import type { WorkLook, WorkTest } from '../types'

export function shellQuote(s: string): string { return "'" + s.replace(/'/g, "'\\''") + "'" }
// A build, test or download is the command a segment starts with, not a word it mentions:
// "rg foo cmake/ tests/" is a search, "cd src && make" and "python3 -B tests/test_x.py" are jobs.
const RUNNER = /^(?:(?:make|ninja|cmake|ctest|pytest|cargo|meson|curl|wget|aria2c|fox-llm-update)\b|(?:npm|pnpm|bun|go) (?:run )?(?:test|build)\b|python3? (?:-\S+ )*-m (?:unittest|pytest)\b|(?:python3?|node|bun) (?:-\S+ )*\S*(?:test_\w+|\w+_test|\w+\.test)\.\w+|\S*\/(?:test_\w+|\w+_test)\b)/
const PREFIX = /^(?:\w+=\S*\s+|command\s+|env\s+|nice\s+|timeout\s+(?:-\S+\s+)*\S+\s+)+/
export function canTrack(command: string): boolean {
  return command.length <= 4000 && !/^\s/.test(command) && !/&\s*$/.test(command) && !/fox-work|\bfjob\b|password|token|secret|authorization|\bpass\b|\bsudo\b|\bexport\b|sk-|ghp_| -u |--user /i.test(command)
    && command.split(/&&|\|\||[;|\n()]/).some(part => RUNNER.test(part.trim().replace(PREFIX, '')))
}
// The command runs exactly as written (so auto mode reviews what really runs); fox-work only records it around the call.
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
export function testLabel(test: WorkTest): string {
  const p = test.tests?.passed, f = test.tests?.failed
  const counts = [p == null ? '' : `✓ ${p} passed`, f == null ? '' : `${f} failed`].filter(Boolean).join(' · ')
  const changed = test.changedFiles?.length
  const freshness = changed ? ` · ${changed} ${changed === 1 ? 'file' : 'files'} changed since`
    : test.changedDuringRun ? ' · code changed while it ran'
    : test.stale ? ' · may be out of date' : ''
  const plain: Record<string, string> = { passed: '✓ last run passed', failed: 'last run failed', interrupted: 'last run stopped early', running: '◷ running' }
  return (counts || plain[test.state] || `last run ${test.state}`) + (counts && test.state !== 'passed' ? ` · ${test.state}` : '') + freshness
}
export async function work($: EngineInterface, args: string[], stdin?: string): Promise<string | null> {
  try {
    const out = await $.process.run(['fox-work', ...args], { timeoutMs: 10000, ...(stdin === undefined ? {} : { stdin }) })
    return out.exitCode === 0 ? out.stdout : null
  } catch { return null }
}
export async function workLook($: EngineInterface, root: string, session: string): Promise<WorkLook | null> {
  try {
    const value = JSON.parse(await work($, ['notebook', '--root', root, '--session', session]) ?? 'null') as WorkLook | null
    return value && Array.isArray(value.tasks) && Array.isArray(value.jobs) ? value : null
  } catch { return null }
}
