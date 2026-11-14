// What the notebook's tests and its preview share: a stand-in engine, sample files and the two places it draws.
import { mock } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'
import { mailId } from '../hooks/notebook'

export const PANE = {
  plugin: 'foxml-paper',
  component: 'Pane',
  requestId: 'paper-notebook',
  props: { title: 'notebook', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

export const BAND = {
  plugin: 'foxml-paper',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  props: { hasSurvey: false, isCollapsed: false, isWorking: true, maxRows: 4, bodyColumns: 80, scroll: { offset: 0, bodyRows: 4 }, view: {} },
} as const

export const done = (stdout: string) => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

export const PEERS = JSON.stringify([
  { id: 'abc', name: 'this one', project: 'paper', state: 'working', busy: true, pane: '%1' },
  { id: 'p1', name: 'Ledger tidy', project: 'trader', state: 'needs you', busy: false, pane: '%4' },
  { id: 'p2', name: 'docs', project: 'docs', state: 'waiting', busy: false, pane: '' },
])
export const seen = { stdin: [] as string[], bash: [] as string[], argv: [] as string[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[], submitted: [] as string[],
  opened: [] as { id: string; closeOnEscape?: true }[], closed: [] as string[] }
export const NOW = 1_800_000_000_000

// A small file system in memory, for the runtime and state folders.
export function fakeFs(on: On, files: Record<string, string>, mtimes: Record<string, number> = {}) {
  const entries = (dir: string) => Object.keys(files).filter(f => f.startsWith(dir + '/') && !f.slice(dir.length + 1).includes('/'))
  on('fs.read', (_, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error('missing ' + e.path)
    return { value: text }
  })
  on('fs.write', (_, e) => { files[e.path] = e.text; return { value: undefined } })
  on('fs.exists', (_, e) => ({ value: e.path in files }))
  on('fs.stat', (_, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error('missing ' + e.path)
    return { value: { kind: 'file' as const, size: text.length, mtimeMs: mtimes[e.path] ?? 0, isLink: false, realPath: e.path } }
  })
  on('fs.list', (_, e) => {
    const found = entries(e.path ?? '.')
    if (found.length === 0) throw new Error('missing ' + e.path)
    return { value: found.map(f => ({ name: f.slice((e.path ?? '.').length + 1), kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }
  })
  return files
}

// Nothing sits beneath the plugin in a test: these stand for the engine and the machine.
export function engine(on: On, options: { pane?: string; pushNotes?: unknown; pushCheck?: unknown; ci?: unknown[]; bash?: (command: string) => unknown; runtime?: string; state?: string; clock?: boolean; files?: Record<string, string>; projectWork?: unknown; finished?: () => unknown; credits?: unknown; trees?: unknown; readIds?: { id: string; at: number }[]; delivery?: boolean; gitFailure?: { value: boolean }; compact?: boolean; agents?: unknown[]; refusals?: Record<string, string>; watchBurst?: number; percent?: number | null; changes?: { status: string; numstat: string } } = {}) {
  let pinned: { file: string; step: string } | null = null
  let workspace: Record<string, unknown> | null = null
  let paneOpen = false
  seen.argv = []; seen.stdin = []; seen.bash = []; seen.sent = []; seen.toasts = []; seen.submitted = []; seen.opened = []
  seen.closed = []
  mock.store(on, { 'notebook-read-mail:abc': options.readIds ?? [], 'notebook-layout': options.compact ? 'compact' : 'expanded' })
  on('session.receive', (_, e) => ({ text: e.text }))
  on('session.send', (_, e) => { seen.sent.push({ to: e.to, text: e.text }); return options.delivery === false
    ? { isDelivered: false, reason: 'session ended' } : { isDelivered: true } })
  on('ui.focus', () => ({ value: {}, deny: undefined }))
  on('ui.scroll', () => ({ value: {}, deny: undefined }))
  if (!options.files) on('fs.exists', () => ({ value: false }))
  on('ui.toast', (_, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('command.register', () => ({ value: { command: 'notebook' } }))
  on('ui.open', (_, e) => { seen.opened.push(e); paneOpen = true; return { value: { isPlaced: true } } })
  on('ui.close', (_, e) => { paneOpen = false; seen.closed.push(e.id); return { value: undefined } })
  on('ui.panes', () => ({ value: paneOpen ? [{ id: 'paper-notebook', title: 'notebook', isShown: true, isFocused: false, isPlaced: true }] : [] }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/code/paper' }))
  on('session.repo', () => ({ value: { root: '/code/paper', remote: null, internal: false, name: null } }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.turns', () => ({ value: 3 }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000, percent: options.percent === null ? undefined : options.percent ?? 64 }, rateLimits: [] } }))
  on('process.run', (_, e) => {
    const argv = e.argv.join(' ')
    seen.argv.push(argv)
    if (options.gitFailure?.value && argv.includes('diff --numstat')) return { value: { ...done(''), exitCode: 1 } }
    // A refusal the way desk-work gives one: exit 1 and its reason as JSON on stdout.
    for (const [prefix, message] of Object.entries(options.refusals ?? {}))
      if (argv.startsWith(prefix)) return { value: { ...done(JSON.stringify({ ok: false, message }) + '\n'), exitCode: 1 } }
    if (e.init?.stdin !== undefined) seen.stdin.push(e.init.stdin)
    if (options.pane && argv === 'sh -c printf %s "$TMUX_PANE"') return { value: done(options.pane) }
    if (argv.startsWith('desk-work begin ')) return { value: done('f'.repeat(32) + '\n') }
    if (argv === 'desk-work agents' && options.agents) return { value: done(JSON.stringify(options.agents)) }
    if (argv.startsWith('desk-work push-check ') && options.pushCheck) return { value: done(JSON.stringify(options.pushCheck)) }
    if (argv.startsWith('desk-work push-notes ') && options.pushNotes) return { value: done(JSON.stringify(options.pushNotes)) }
    if (argv.startsWith('desk-work finish ') && options.finished) return { value: done(JSON.stringify(options.finished())) }
    if (argv.startsWith('desk-work plan-pin ')) {
      const file = e.argv[e.argv.indexOf('--file') + 1] ?? ''
      pinned = file ? { file: file.startsWith('/') ? file : '/code/paper/' + file, step: e.argv[e.argv.indexOf('--step') + 1] ?? '' } : null
      return { value: done('{"ok":true}') }
    }
    if (argv.startsWith('desk-work plan ')) return { value: done(JSON.stringify(pinned)) }
    if (argv.startsWith('desk-work open ')) return { value: done('') }
    if (argv.startsWith('desk-work workspace ')) {
      if (e.init?.stdin) workspace = JSON.parse(e.init.stdin)
      return { value: done(JSON.stringify(e.init?.stdin ? { ok: true } : workspace)) }
    }
    if (argv.startsWith('desk-work digest ') || argv.startsWith('desk-work snooze ') || argv.startsWith('desk-work set-aside ')) return { value: done('{"ok":true}') }
    if (argv.startsWith('desk-work task-add ')) return { value: done('{"ok":true}') }
    if (argv.startsWith('desk-work worktrees ')) return { value: done(JSON.stringify(options.trees ?? [])) }
    if (argv.startsWith('desk-work notebook') && options.projectWork) return { value: done(JSON.stringify(options.projectWork)) }
    if (argv === 'sh -c printf %s "$XDG_RUNTIME_DIR"' && options.runtime) return { value: done(options.runtime) }
    if (argv.startsWith('sh -c printf %s "${XDG_STATE_HOME') && options.state) return { value: done(options.state) }
    if (argv.startsWith('rm -f -- ') && options.files) { delete options.files[e.argv[3] ?? '']; return { value: done('') } }
    if (argv.startsWith('chmod ')) return { value: done('') }
    if (argv.includes('log -1 --format=%ct%x00%B'))
      return { value: done(`${NOW / 1000}\u0000feat: a thing\n\nClaude-Session: https://claude.ai/code/session_X\n`) }
    if (argv.includes('-- /code/paper/clean.txt')) return { value: done('') }
    if (options.ci && argv.includes('rev-parse --verify origin/main^{commit}')) return { value: done('c'.repeat(40) + '\n') }
    if (options.ci && argv === 'git -C /code/paper remote get-url origin') return { value: done('git@github.com:o/paper.git\n') }
    if (options.ci && argv.startsWith('gh run list --commit ' + 'c'.repeat(40))) return { value: done(JSON.stringify(options.ci)) }
    if (argv === 'desk-credits status' && options.credits) return { value: done(JSON.stringify(options.credits)) }
    if (argv === 'desktop-menu --open api-credits') return { value: done('') }
    if (argv === 'desk-drawer claude-peers') return { value: done(PEERS) }
    if (argv.startsWith('desk-drawer run claude-jump')) return { value: done('{"ok":true}') }
    if (argv.includes('status') && !argv.includes('--no-optional-locks')) return { value: { ...done(''), exitCode: 9 } }
    if (options.changes && argv.includes('status') && e.argv.includes('-z')) return { value: done(options.changes.status) }
    if (options.changes && argv.includes('numstat')) return { value: done(options.changes.numstat) }
    if (argv.includes('status') && e.argv.includes('-z')) return { value: done(' M shared/a very long folder/notes.txt\0 M README.md\0') }
    if (argv.includes('status')) return { value: done('## main...origin/main\n M a.txt\n') }
    if (argv.includes('numstat')) return { value: done('12\t3\tshared/a very long folder/notes.txt\u00001\t0\tREADME.md\0') }
    return { value: { ...done(''), exitCode: 1 } }
  })
  // The change stream, when a test asks for one: a burst of watchBurst events as fast as they can be read, then the
  // watcher ends (the notebook falls back to its recovery poll, as it does when a watcher dies).
  if (options.watchBurst !== undefined) on('process.spawn', async function* (_, e) {
    seen.argv.push(e.argv.join(' '))
    if (e.argv[0] === 'desk-work' && e.argv[1] === 'watch')
      for (let i = 0; i < (options.watchBurst ?? 0); ++i) yield { stream: 'stdout' as const, text: JSON.stringify({ version: 1, revision: 'r' + i }) + '\n' }
    return { value: { code: 0, signal: null } }
  })
  on('tool.call', (_, e) => {
    const command = e.tool === 'Bash' && 'command' in e && typeof e.command === 'string' ? e.command : null
    if (command !== null) seen.bash.push(command)
    return options.bash && command !== null ? options.bash(command) as { result: unknown } : ({ result: {} })
  })
  on('prompt.submit', (_, e) => {
    if (e.origin.kind === 'plugin') seen.submitted.push(e.text)
    return { text: e.text }
  })
  if (options.clock !== false) {
    on('clock.every', () => ({ value: undefined }))
    on('clock.now', () => ({ value: NOW }))
  }
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.component === 'Spinner' ? e.props.word : 'engine'}</Text>
  })
}

export async function opened($: Engine) {
  await $.session.start({ cwd: '/code/paper', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
}
