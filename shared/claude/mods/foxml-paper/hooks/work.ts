import type { EngineInterface } from 'claude-code'
import type { WorkLook, WorkTest } from '../types'

export function shellQuote(s: string): string { return "'" + s.replace(/'/g, "'\\''") + "'" }
export function canTrack(command: string): boolean {
  return command.length <= 4000 && !/^\s/.test(command) && !/&\s*$/.test(command) && !/fox-work|\bfjob\b|password|token|secret|authorization|\bpass\b|\bsudo\b|\bexport\b|sk-|ghp_| -u |--user /i.test(command)
    && /\b(make|ninja|cmake|ctest|pytest|cargo|meson|curl|wget|aria2c|fox-llm-update|unittest)\b|\b(?:npm|pnpm|bun|go) (?:run )?(?:test|build)\b|(?:^|\/)\w*(?:_test|test_\w+)\b/.test(command)
}
export function wrapped(command: string, root: string, session: string): string {
  return `command fox-work run --root ${shellQuote(root)} --session ${shellQuote(session)} -- bash -c ${shellQuote(command)}`
}
export function testLabel(test: WorkTest): string {
  const p = test.tests?.passed, f = test.tests?.failed
  const counts = [p == null ? '' : `✓ ${p} passed`, f == null ? '' : `${f} failed`].filter(Boolean).join(' · ')
  const changed = test.changedFiles?.length
  const freshness = changed ? ` · ${changed} ${changed === 1 ? 'file' : 'files'} changed since`
    : test.changedDuringRun ? ' · source changed during run'
    : test.stale ? ' · freshness unknown' : ''
  return (counts || `${test.state} · no test totals`) + (counts && test.state !== 'passed' ? ` · ${test.state}` : '') + freshness
}
export async function work($: EngineInterface, args: string[]): Promise<string | null> {
  try {
    const out = await $.process.run(['fox-work', ...args], { timeoutMs: 10000 })
    return out.exitCode === 0 ? out.stdout : null
  } catch { return null }
}
export async function workLook($: EngineInterface, root: string, session: string): Promise<WorkLook | null> {
  try {
    const value = JSON.parse(await work($, ['notebook', '--root', root, '--session', session]) ?? 'null') as WorkLook | null
    return value && Array.isArray(value.tasks) && Array.isArray(value.jobs) ? value : null
  } catch { return null }
}
