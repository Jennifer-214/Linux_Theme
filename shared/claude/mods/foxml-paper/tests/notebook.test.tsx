import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'
import { mailId } from '../hooks/notebook'

const PANE = {
  plugin: 'foxml-paper',
  component: 'Pane',
  requestId: 'paper-notebook',
  props: { title: 'notebook', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

const BAND = {
  plugin: 'foxml-paper',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  props: { hasSurvey: false, isWorking: true, maxRows: 4, bodyColumns: 80, scroll: { offset: 0, bodyRows: 4 }, view: {} },
} as const

const done = (stdout: string) => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

const PEERS = JSON.stringify([
  { id: 'abc', name: 'this one', project: 'paper', state: 'working', busy: true, pane: '%1' },
  { id: 'p1', name: 'Ledger tidy', project: 'trader', state: 'needs you', busy: false, pane: '%4' },
  { id: 'p2', name: 'docs', project: 'docs', state: 'waiting', busy: false, pane: '' },
])
const seen = { argv: [] as string[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[], submitted: [] as string[] }
const NOW = 1_800_000_000_000

// A small file system in memory, for the runtime and state folders.
function fakeFs(on: On, files: Record<string, string>) {
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
    return { value: { kind: 'file' as const, size: text.length, mtimeMs: 0, isLink: false, realPath: e.path } }
  })
  on('fs.list', (_, e) => {
    const found = entries(e.path ?? '.')
    if (found.length === 0) throw new Error('missing ' + e.path)
    return { value: found.map(f => ({ name: f.slice((e.path ?? '.').length + 1), kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }
  })
  return files
}

// Nothing sits beneath the plugin in a test: these stand for the engine and the machine.
function engine(on: On, options: { runtime?: string; state?: string; clock?: boolean; files?: Record<string, string>; projectWork?: unknown; trees?: unknown; readIds?: { id: string; at: number }[] } = {}) {
  let pinned: { file: string; step: string } | null = null
  seen.argv = []; seen.sent = []; seen.toasts = []; seen.submitted = []
  mock.store(on, { 'notebook-read-mail:abc': options.readIds ?? [] })
  on('session.receive', (_, e) => ({ text: e.text }))
  on('session.send', (_, e) => { seen.sent.push({ to: e.to, text: e.text }); return { isDelivered: true } })
  on('ui.focus', () => ({ value: {}, deny: undefined }))
  on('ui.scroll', () => ({ value: {}, deny: undefined }))
  if (!options.files) on('fs.exists', () => ({ value: false }))
  on('ui.toast', (_, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('command.register', () => ({ value: { command: 'notebook' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/code/paper' }))
  on('session.repo', () => ({ value: { root: '/code/paper', remote: null, internal: false, name: null } }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.turns', () => ({ value: 3 }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000, percent: 64 }, rateLimits: [] } }))
  on('process.run', (_, e) => {
    const argv = e.argv.join(' ')
    seen.argv.push(argv)
    if (argv.startsWith('fox-work plan-pin ')) {
      const file = e.argv[e.argv.indexOf('--file') + 1] ?? ''
      pinned = file ? { file: file.startsWith('/') ? file : '/code/paper/' + file, step: e.argv[e.argv.indexOf('--step') + 1] ?? '' } : null
      return { value: done('{"ok":true}') }
    }
    if (argv.startsWith('fox-work plan ')) return { value: done(JSON.stringify(pinned)) }
    if (argv.startsWith('fox-work open ')) return { value: done('') }
    if (argv.startsWith('fox-work task-add ')) return { value: done('{"ok":true}') }
    if (argv.startsWith('fox-work worktrees ')) return { value: done(JSON.stringify(options.trees ?? [])) }
    if (argv.startsWith('fox-work notebook') && options.projectWork) return { value: done(JSON.stringify(options.projectWork)) }
    if (argv === 'sh -c printf %s "$XDG_RUNTIME_DIR"' && options.runtime) return { value: done(options.runtime) }
    if (argv.startsWith('sh -c printf %s "${XDG_STATE_HOME') && options.state) return { value: done(options.state) }
    if (argv.startsWith('rm -f -- ') && options.files) { delete options.files[e.argv[3] ?? '']; return { value: done('') } }
    if (argv.startsWith('chmod ')) return { value: done('') }
    if (argv.includes('log -1 --format=%ct%x00%B'))
      return { value: done(`${NOW / 1000}\u0000feat: a thing\n\nClaude-Session: https://claude.ai/code/session_X\n`) }
    if (argv.includes('-- /code/paper/clean.txt')) return { value: done('') }
    if (argv === 'fox-drawer claude-peers') return { value: done(PEERS) }
    if (argv.startsWith('fox-drawer run claude-jump')) return { value: done('{"ok":true}') }
    if (argv.includes('status') && !argv.includes('--no-optional-locks')) return { value: { ...done(''), exitCode: 9 } }
    if (argv.includes('status') && e.argv.includes('-z')) return { value: done(' M shared/a very long folder/notes.txt\0 M README.md\0') }
    if (argv.includes('status')) return { value: done('## main...origin/main\n M a.txt\n') }
    if (argv.includes('numstat')) return { value: done('12\t3\tshared/a very long folder/notes.txt\u00001\t0\tREADME.md\0') }
    return { value: { ...done(''), exitCode: 1 } }
  })
  on('tool.call', () => ({ result: {} }))
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

async function opened($: Engine) {
  await $.session.start({ cwd: '/code/paper', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
}

test('the notebook shows the hearts, the session name and the pages touched', async ($, on) => {
  engine(on)
  await opened($)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /▰▰▰▱▱/ }))?.text).toBe('▰▰▰▱▱ 64%')
    expect((await ui.find({ key: 'page-files' }))?.text).toContain('2 all files')
    await ui.press({ key: 'page-files' })
    await ui.press({ key: 'scope-all' })
    expect((await ui.find({ key: 'file:README.md' }))?.text).toContain('README.md')
    await ui.press({ key: 'nav-back' })
    await ui.unmount()
  }
})

test('test failures open their quickfix location, and next steps prepare a draft without sending it', async ($, on) => {
  engine(on, { projectWork: {
    tests: { id: 'a'.repeat(32), state: 'failed', stale: true, tests: { passed: 128, failed: 2, failures: [{ filename: '/code/paper/test.cpp', lnum: 12, text: 'failed' }] } },
    jobs: [], tasks: [{ id: 'next', text: 'rerun the sanitizer', done: false }],
  } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'page-project' })
  expect((await ui.find({ type: 'Text', text: /128 passed/ }))?.text).toContain('freshness unknown')
  await ui.press({ key: 'work-failure-0' })
  expect(seen.argv).toContain(`fox-work open --root /code/paper --action tests --id ${'a'.repeat(32)} --index 1`)
  await ui.press({ key: 'task-draft-next' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action tasks --id next')
  expect(seen.sent).toEqual([])
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('a privileged edit of login or boot raises the red-zone band, and the next prompt clears it', async ($, on) => {
  engine(on)
  await opened($)

  await $.tool.call({ tool: 'Bash', command: 'cat /etc/fstab' })
  let band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /red zone/ })).toBeUndefined()
  await band.unmount()

  await $.tool.call({ tool: 'Bash', command: 'echo x | sudo tee -a /etc/pam.d/sudo' })
  band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /pam/ }))?.text).toBe('/etc/pam.d')
  await band.unmount()

  await $.prompt.submit({ text: 'ok', wait: false, origin: { kind: 'composer' } })
  band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /red zone/ })).toBeUndefined()
  await band.unmount()

  await $.tool.call({ tool: 'Edit', file_path: '/boot/loader/entries/arch.conf', old_string: 'a', new_string: 'b' })
  band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /boot/ }))?.text).toBe('/boot/')
  await band.unmount()
})

test('the spinner knits in the terminal and leaves other surfaces their words', async ($, on) => {
  engine(on)
  await opened($)
  const spinner = { plugin: 'foxml-paper', component: 'Spinner', requestId: 'main', props: { word: 'Sauteing', message: null, suffix: '…', mode: 'thinking' } } as const
  const terminal = await $.ui.mount({ ...spinner, surface: 'terminal' })
  const word = (await terminal.find({ type: 'Text' }))?.text ?? ''
  expect(['Reading', 'Checking', 'Tracing', 'Writing', 'Reviewing', 'Working']).toContain(word)
  await terminal.unmount()
  const desktop = await $.ui.mount({ ...spinner, surface: 'desktop' })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('Sauteing')
  await desktop.unmount()
})

test('other claudes are listed with go and note, and a note reaches the session it was written to', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'page-sessions' })
  expect((await ui.find({ type: 'Text', text: /other claudes/ }))?.text).toBe('other claudes')
  expect(await ui.find({ type: 'Text', text: /this one/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Ledger tidy/ }))?.text).toBe('● Ledger tidy · trader')
  expect(await ui.find({ key: 'go-p2' })).toBeUndefined()

  await ui.press({ key: 'go-p1' })
  expect(seen.argv).toContain('fox-drawer run claude-jump %4')

  await ui.press({ key: 'note-p2' })
  expect(await ui.find({ key: 'note-p2' })).toBeUndefined()
  await ui.input({ key: 'peer-note', text: '  the tests are green, go ahead  ', kind: 'submit' })
  expect(seen.sent).toEqual([{ to: 'p2', text: '✉ from another session: the tests are green, go ahead' }])
  expect(seen.toasts).toContain('note left for docs')
  expect(await ui.find({ key: 'peer-note' })).toBeUndefined()

  await ui.press({ key: 'note-p1' })
  await ui.press({ key: 'peer-cancel' })
  expect(await ui.find({ key: 'peer-note' })).toBeUndefined()
  expect(seen.sent).toHaveLength(1)
  await ui.unmount()
})

test('a note from nvim becomes an envelope and reaches Claude as your words', async ($, on) => {
  const files = fakeFs(on, { '/run/t/foxml-claude/inbox/abc/1-a.json':
    JSON.stringify({ from: 'nvim', text: ' look at this ', file: 'src/a.cpp', lines: '3-5', code: 'int x;' }),
    '/run/t/foxml-claude/inbox/abc/2-b.json': '{"text": 5}' })
  engine(on, { runtime: '/run/t', clock: false, files })
  const clock = mock.clock(on, { now: NOW })
  await opened($)
  await clock.advance(5000)
  expect(seen.submitted).toEqual(['look at this\n(src/a.cpp:3-5)\n```\nint x;\n```'])
  expect(Object.keys(files).filter(f => f.includes('/inbox/'))).toEqual([])
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await $.command.run({ command: 'notebook', args: 'sessions', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ type: 'Text', text: /✉ from/ }))?.text).toBe('✉ from you, in nvim')
  expect(await ui.find({ type: 'Text', text: /✉ 1/ })).toBeDefined()
  await ui.press({ key: 'envelope-nvim-1-a.json' })
  expect(await ui.find({ type: 'Text', text: /✉ from/ })).toBeUndefined()
  await clock.advance(5000)
  expect(seen.submitted).toHaveLength(1)
  await ui.unmount()
})

test("a Claude commit is named by its session, and another Claude's note shows as an envelope", async ($, on) => {
  const files = fakeFs(on, {})
  engine(on, { state: '/state', clock: false, files })
  mock.clock(on, { now: NOW })
  await opened($)
  await $.tool.call({ tool: 'Bash', command: 'git commit -m "feat: a thing"' })
  expect(JSON.parse(files['/state/foxml/claude-sessions.jsonl'] ?? 'null'))
    .toEqual({ url: 'https://claude.ai/code/session_X', title: 'paper', at: NOW })
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: the build is yours now' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await $.command.run({ command: 'notebook', args: 'sessions', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ type: 'Text', text: /✉ from/ }))?.text).toBe('✉ from docs')
  expect((await ui.find({ type: 'Text', text: /build is yours/ }))?.text).toBe('the build is yours now')
  await ui.unmount()
})

test('the first edit of a file with uncommitted changes keeps it as it was; a clean file needs no copy', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/a.txt': 'before', '/code/paper/clean.txt': 'tidy' })
  engine(on, { runtime: '/run/t', clock: false, files })
  mock.clock(on, { now: NOW })
  await opened($)
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/a.txt', old_string: 'before', new_string: 'after' })
  files['/code/paper/a.txt'] = 'after'
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/a.txt', old_string: 'after', new_string: 'again' })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/clean.txt', old_string: 'tidy', new_string: 'x' })
  expect(files['/run/t/foxml-claude/edits/abc/before/1.txt']).toBe('before')
  expect(files['/run/t/foxml-claude/edits/abc/before/2.txt']).toBeUndefined()
  const ledger = JSON.parse(files['/run/t/foxml-claude/edits/abc.json'] ?? '{}')
  expect(ledger.before).toEqual({ '/code/paper/a.txt': '1.txt' })
  expect(ledger.all.map((e: { path: string }) => e.path)).toEqual(['/code/paper/a.txt', '/code/paper/clean.txt'])
})

test('session files, keyboard selection and editor actions retain the selected file through refresh', async ($, on) => {
  const files = fakeFs(on, {
    '/run/t/foxml-claude/edits/abc.json': JSON.stringify({ root: '/code/paper', edits: [], all: [{ path: '/code/paper/README.md', at: 1 }] }),
  })
  engine(on, { runtime: '/run/t', files })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'page-files' })
  expect(await ui.find({ key: 'file:README.md' })).toBeDefined()
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeUndefined()
  expect((await ui.find({ key: 'nav-down' }))?.props.hotkey).toBe('j')
  expect((await ui.find({ key: 'nav-up' }))?.props.hotkey).toBe('k')
  expect((await ui.find({ key: 'nav-back' }))?.props.hotkey).toBe('h')
  expect((await ui.find({ key: 'nav-open' }))?.props.hotkey).toBe('l')
  await ui.press({ key: 'nav-down' })
  await ui.press({ key: 'nav-down' })
  await ui.press({ key: 'nav-down' })
  expect((await ui.find({ key: 'file:README.md' }))?.text).toStartWith('› ')
  await ui.press({ key: 'nav-open' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action file-diff --file README.md --session abc')
  await ui.press({ key: 'nav-editor' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action file --file README.md --session abc')
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 101 } })
  expect((await ui.find({ key: 'file:README.md' }))?.text).toStartWith('› ')
  await ui.press({ key: 'scope-all' })
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeDefined()
  await ui.press({ key: 'file:shared/a very long folder/notes.txt' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action file-diff --file shared/a very long folder/notes.txt --session ')
  await ui.unmount()
})

test('pinning the plan and current step survives another plan read, and task inputs stay collapsed until asked', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/plans/one.md': '# The active plan\n', '/code/paper/plans/two.md': '# Another plan\n' })
  engine(on, { runtime: '/run/t', files, projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  await ui.press({ key: 'task-add' })
  expect((await ui.find({ key: 'work-next-step' }))?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'task-add' }))?.props.autoFocus).toBeUndefined()
  await ui.input({ key: 'work-next-step', text: 'check hjkl in the terminal', kind: 'submit' })
  expect(seen.argv).toContain('fox-work task-add --root /code/paper --text check hjkl in the terminal')
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/one.md', kind: 'submit' })
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  await ui.press({ key: 'plan-step' })
  await ui.input({ key: 'plan-current-step', text: 'ship file selection', kind: 'submit' })
  await $.tool.call({ tool: 'Read', file_path: '/code/paper/plans/two.md' })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ key: 'plan-open' }))?.text).toContain('The active plan')
  expect((await ui.find({ key: 'plan-step' }))?.text).toContain('ship file selection')
  const ledger = JSON.parse(files['/run/t/foxml-claude/edits/abc.json'] ?? '{}')
  expect(ledger.plan).toBe('/code/paper/plans/one.md')
  expect(seen.sent).toEqual([])
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('the attention summary and project cards lead to job output, source files and worktrees', async ($, on) => {
  const files = fakeFs(on, {
    '/run/t/foxml-claude/cards/abc.json': JSON.stringify({ title: 'ledger book', rows: [{ text: 'readiness', action: { kind: 'file', file: 'plans/state.md' } }] }),
    '/code/paper/package.json': '{}',
  })
  const failed = { id: 'b'.repeat(32), command: 'make test', state: 'failed', elapsed: 1, activity: 0, session: 'abc' }
  engine(on, { runtime: '/run/t', files,
    projectWork: { tests: null, jobs: [], tasks: [], failures: [failed] },
    trees: [{ path: '/code/paper-feature', branch: 'feature', status: '## feature\n M a.ts\n', sessions: [] }],
  })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'attention-job-' + failed.id })
  expect(seen.argv).toContain(`fox-work open --root /code/paper --action log --id ${failed.id}`)
  await ui.press({ key: 'page-project' })
  await ui.press({ key: 'card-0' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action file --file plans/state.md --session abc')
  await ui.press({ key: 'tree:/code/paper-feature' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action worktree --file /code/paper-feature')
  await ui.press({ key: 'document:package.json' })
  expect(seen.argv).toContain('fox-work open --root /code/paper --action file --file package.json')
  await ui.unmount()
})

test('read notes disappear with their unread count, duplicate delivery stays read, and new notes can be cleared together', async ($, on) => {
  engine(on)
  await opened($)
  const prefix = 'a'.repeat(210)
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: ' + prefix + ' first' })
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: ' + prefix + ' second' })
  await $.command.run({ command: 'notebook', args: 'sessions', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /✉ 2/ }))?.text).toContain('✉ 2')
  const first = await mailId('docs', prefix + ' first')
  await ui.press({ key: 'envelope-' + first })
  expect(await ui.find({ type: 'Text', text: /first$/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /✉ 1/ }))?.text).toContain('✉ 1')
  await $.session.receive({ origin: { kind: 'peer-send-message' }, text: '✉ from docs: ' + prefix + ' first' })
  expect(await ui.find({ key: 'envelope-' + first })).toBeUndefined()
  await ui.press({ key: 'mail-clear' })
  expect(await ui.find({ type: 'Text', text: /✉ from/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /✉ [0-9]/ })).toBeUndefined()
  expect(await ui.find({ key: 'mail-clear' })).toBeUndefined()
  await ui.unmount()
})

test('read markers restored at startup suppress a retried peer message after reload', async ($, on) => {
  const id = await mailId('docs', 'already read')
  engine(on, { readIds: [{ id, at: NOW - 1000 }] })
  await opened($)
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: already read' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'attention-mail' })).toBeUndefined()
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: a different new note' })
  expect((await ui.find({ key: 'attention-mail' }))?.text).toContain('1 unread note')
  await ui.unmount()
})
