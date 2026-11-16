import { expect, mock, test } from 'claude-code/testing'
import { mailId } from '../hooks/notebook'
import { BAND, NOW, PANE, PEERS, done, engine, fakeFs, hide, opened, seen } from './kit'

test('hiding and toggling the notebook preserves its page and does not send a prompt', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'page-files' })
  await ui.press({ key: 'scope-all' })
  await $.command.run({ command: 'notebook', args: 'toggle', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(seen.closed).toEqual(['paper-notebook'])
  await $.command.run({ command: 'notebook', args: 'toggle', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await ui.find({ key: 'file:README.md' })).toBeDefined()
  expect(await ui.find({ key: 'scope-all' })).toBeDefined()
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('explicit hide closes only the notebook and discards an unfinished form', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'task-add' })
  await ui.input({ key: 'work-next-step', text: 'unfinished draft', kind: 'change' })
  await ui.press({ key: 'nav-hide' })
  expect(seen.closed).toEqual(['paper-notebook'])
  await $.command.run({ command: 'notebook', args: 'toggle', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  expect(await ui.find({ key: 'task-add' })).toBeDefined()
  expect(seen.argv.some(value => value.startsWith('desk-work task-add '))).toBe(false)
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('health shows backend diagnostics and opens explicit recovery controls without running them', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], health: { status: 'interrupted', checks: [
    { id: 'nvim', label: 'nvim · paper', detail: 'Stream: retrying\nLast refresh: 2026-11-13 09:00:00\nNext retry: 2026-11-13 09:00:10' },
    { id: 'update', label: 'Interrupted update', detail: 'applying · 100-1', transaction: '100-1', recoverable: true },
  ] } } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'page-health' })
  expect(await ui.find({ type: 'Text', text: 'Stream: retrying' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Interrupted update' })).toBeDefined()
  expect(seen.argv.some(value => value.includes('--health yes'))).toBe(true)
  expect(seen.argv.some(value => /integrations (recover|cleanup) /.test(value))).toBe(false)
  await ui.press({ key: 'health-controls' })
  expect(seen.argv.some(value => value.includes('open --root /code/paper --action health'))).toBe(true)
  await ui.unmount()
})

test('the notebook shows the session name and the pages touched, and leaves the context meter to the status line', async ($, on) => {
  engine(on)
  await opened($)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /^notebook +$/ }), 'the header').toBeDefined()
    expect(await ui.find({ type: 'Text', text: /▰|64%/ }), 'no second context meter').toBeUndefined()
    expect((await ui.find({ key: 'page-files' }))?.text).toContain('2 changed')
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
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ type: 'Text', text: /128 passed/ }))?.text).toContain('may be out of date')
  await ui.press({ key: 'work-failure-0' })
  expect(seen.argv).toContain(`desk-work open --root /code/paper --action tests --id ${'a'.repeat(32)} --index 1`)
  await ui.press({ key: 'task-draft-next' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action tasks --id next')
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
  const spinner = { plugin: 'desk-notebook', component: 'Spinner', requestId: 'main', props: { word: 'Sauteing', message: null, suffix: '…', mode: 'thinking' } } as const
  const terminal = await $.ui.mount({ ...spinner, surface: 'terminal' })
  const word = (await terminal.find({ type: 'Text' }))?.text ?? ''
  expect(['Reading', 'Checking', 'Tracing', 'Writing', 'Reviewing', 'Working']).toContain(word)
  await terminal.unmount()
  const desktop = await $.ui.mount({ ...spinner, surface: 'desktop' })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('Sauteing')
  await desktop.unmount()
})

test('other sessions are listed with go and note, and a note reaches the session it was written to', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ key: 'page-sessions' }))?.props.label).toBe('3 sessions')
  await ui.press({ key: 'page-sessions' })
  expect((await ui.find({ type: 'Text', text: /sessions · you/ }))?.text).toBe('3 sessions · you and 2 others')
  expect(await ui.find({ type: 'Text', text: /this one/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Ledger tidy/ }))?.text).toBe('● Ledger tidy · trader')
  expect(await ui.find({ key: 'go-p2' })).toBeUndefined()

  await ui.press({ key: 'go-p1' })
  expect(seen.argv).toContain('desk-drawer run claude-jump %4')

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

test('a file a shell command wrote counts as this session’s edit; one it did not touch does not', async ($, on) => {
  // git reports two changed files; only README.md was modified while the command ran.
  const files = fakeFs(on, { '/code/paper/README.md': 'new', '/code/paper/shared/a very long folder/notes.txt': 'old' },
    { '/code/paper/README.md': NOW, '/code/paper/shared/a very long folder/notes.txt': NOW - 3600_000 })
  engine(on, { runtime: '/run/t', clock: false, files })
  mock.clock(on, { now: NOW })
  await opened($)
  await $.tool.call({ tool: 'Bash', command: "sed -i 's/a/b/' README.md", description: 'Tidy the readme' })
  const ledger = JSON.parse(files['/run/t/foxml-claude/edits/abc.json'] ?? '{}')
  expect((ledger.all ?? []).map((e: { path: string }) => e.path)).toEqual(['/code/paper/README.md'])
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'page-files' }))?.text).toContain('1 this session')
  await ui.unmount()
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
  // Two scope rows, the filter row and the search row come before the first file.
  for (let i = 0; i < 5; i++) await ui.press({ key: 'nav-down' })
  expect((await ui.find({ key: 'file:README.md' }))?.text).toStartWith('› ')
  await ui.press({ key: 'nav-open' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file README.md --session abc')
  await ui.press({ key: 'nav-editor' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file --file README.md --session abc')
  expect((await ui.find({ key: 'nav-drawer' }))?.props.hotkey).toBe('d')
  await ui.press({ key: 'nav-drawer' })
  expect(seen.argv).toContain('desktop-menu --open reviews')
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 101 } })
  expect((await ui.find({ key: 'file:README.md' }))?.text).toStartWith('› ')
  await ui.press({ key: 'scope-all' })
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeDefined()
  await ui.press({ key: 'file:shared/a very long folder/notes.txt' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file shared/a very long folder/notes.txt --session ')
  await ui.unmount()
})

test('pinning the plan and current step survives another plan read, and task inputs stay collapsed until asked', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/plans/one.md': '# The active plan\n', '/code/paper/plans/two.md': '# Another plan\n' })
  engine(on, { runtime: '/run/t', files, projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'task-add' })
  expect((await ui.find({ key: 'work-next-step' }))?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'task-add' }))?.props.autoFocus).toBeUndefined()
  await ui.input({ key: 'work-next-step', text: 'check hjkl in the terminal', kind: 'submit' })
  expect(seen.argv).toContain('desk-work task-add --root /code/paper --text check hjkl in the terminal')
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/one.md', kind: 'submit' })
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  await ui.press({ key: 'plan-step' })
  await ui.input({ key: 'plan-current-step', text: 'ship file selection', kind: 'submit' })
  await $.tool.call({ tool: 'Read', file_path: '/code/paper/plans/two.md' })
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ key: 'plan-open' }))?.text).toContain('The active plan')
  expect((await ui.find({ key: 'plan-step' }))?.text).toContain('ship file selection')
  await $.command.run({ command: 'notebook', args: 'overview', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ key: 'plan-open' }))?.text, 'the front page names the step in hand').toContain('ship file selection')
  const ledger = JSON.parse(files['/run/t/foxml-claude/edits/abc.json'] ?? '{}')
  expect(ledger.plan).toBe('/code/paper/plans/one.md')
  expect(seen.sent).toEqual([])
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('next-step editors keep cancel visible, request native Escape closing, and discard unfinished forms on reopening', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'task-add' })
  expect(seen.opened.at(-1)?.closeOnEscape).toBe(true)
  expect(await ui.find({ key: 'work-next-step' })).toBeDefined()
  expect(await ui.find({ key: 'form-cancel' })).toBeDefined()
  expect(await ui.find({ key: 'page-files' })).toBeUndefined()
  await ui.input({ key: 'work-next-step', text: 'unfinished thought', kind: 'change' })
  await ui.press({ key: 'form-cancel' })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  expect(seen.opened.at(-1)?.closeOnEscape).toBeUndefined()
  await ui.press({ key: 'task-add' })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  expect(await ui.find({ key: 'task-add' })).toBeDefined()
  await ui.press({ key: 'task-add' })
  await ui.input({ key: 'work-next-step', text: '  ', kind: 'submit' })
  expect(await ui.find({ key: 'work-next-step' })).toBeUndefined()
  expect(seen.argv.some(argv => argv.startsWith('desk-work task-add '))).toBe(false)
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
  expect(seen.argv).toContain(`desk-work open --root /code/paper --action log --id ${failed.id}`)
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'card-0' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file --file plans/state.md --session abc')
  await ui.press({ key: 'tree:/code/paper-feature' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action worktree --file /code/paper-feature')
  await ui.press({ key: 'document:package.json' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file --file package.json')
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
  expect((await ui.find({ key: 'attention-mail' }))?.text).toContain('1 unread')
  await ui.unmount()
})


test('the front page keeps its one key bar at rest, and no credit row while credit is plentiful', async ($, on) => {
  engine(on, { credits: { short: 'API ~$180.00 left', headline: '$20.00 tracked of $200.00', detail: 'Tracked runs only · renews Dec 1',
    meter: '▰▰▰▰▰▰▰▰▰▱', status: 'tracked', source: 'local', remaining_percent: 90, as_of: '2026-11-09T00:00:00Z', projects: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'api-credit-meter' })).toBeUndefined()
  expect(await ui.find({ key: 'nav-back' })).toBeUndefined()
  expect((await ui.find({ key: 'nav-hide' }))?.props.hotkey, 'drawn at rest too, so focusing the pane moves nothing').toBe('q')
  await ui.press({ key: 'page-files' })
  expect((await ui.find({ key: 'nav-back' }))?.props.hotkey).toBe('h')
  await ui.unmount()
})

test('the API credit meter appears when credit runs low and opens the shared credit drawer', async ($, on) => {
  engine(on, { credits: { short: 'API ~$30.00 left', headline: '$170.00 tracked of $200.00', detail: 'Tracked runs only · renews Dec 1',
    meter: '▰▱▱▱▱▱▱▱▱▱', status: 'tracked', source: 'local', remaining_percent: 15, as_of: '2026-11-09T00:00:00Z', projects: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'api-credit-meter' }))?.text).toContain('API ~$30.00 left')
  expect((await ui.find({ key: 'api-credit-meter' }))?.text).toContain('▰▱▱▱▱▱▱▱▱▱ tracked')
  await ui.press({ key: 'api-credit-meter' })
  expect(seen.argv).toContain('desktop-menu --open api-credits')
  expect(seen.argv.some(argv => argv.includes('desk-credits sync'))).toBe(false)
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('a build Claude runs is recorded around the call, never rewritten, under its plain-words title', async ($, on) => {
  engine(on, { bash: () => ({ result: 'Exit code 2\n128 passed, 2 failed', text: 'Exit code 2\n128 passed, 2 failed', isError: true }) })
  await opened($)
  await $.tool.call({ tool: 'Bash', command: 'make -C src test', description: 'Run the unit tests' })
  expect(seen.bash).toEqual(['make -C src test'])
  expect(seen.argv).toContain('desk-work begin --root /code/paper --session abc --pid parent --safe yes --command make -C src test --title Run the unit tests --cwd /code/paper')
  expect(seen.argv).toContain(`desk-work finish --id ${'f'.repeat(32)} --exit 2 --output -`)
  expect(seen.stdin).toContain('Exit code 2\n128 passed, 2 failed')
  expect(seen.argv.some(argv => argv.includes('desk-work run'))).toBe(false)
  await $.tool.call({ tool: 'Bash', command: 'ls', description: 'List files' })
  expect(seen.argv.filter(argv => argv.startsWith('desk-work begin')).length).toBe(1)
})

test('tests that failed twice in a row and pass again say green again, once; a flaky one stays quiet', async ($, on) => {
  let failedBefore = 2
  engine(on, { bash: () => ({ result: { stdout: '4 passed', stderr: '' } }), finished: () => ({ ok: true, state: 'passed', testRun: true, failedBefore }) })
  await opened($)
  await $.tool.call({ tool: 'Bash', command: 'make test', description: 'Run the tests' })
  expect(seen.toasts.filter(t => t === 'green again ✿').length).toBe(1)
  failedBefore = 1
  seen.toasts = []
  await $.tool.call({ tool: 'Bash', command: 'make test', description: 'Run the tests' })
  expect(seen.toasts).not.toContain('green again ✿')
})

test('a running job draws a pencil ruler against its last pass, and says so plainly once it runs long', async ($, on) => {
  const job = { id: 'j1', command: 'make', title: 'Build the engine', state: 'running', elapsed: 60, activity: 0, session: 'abc' }
  const projectWork = { tests: null, tasks: [], jobs: [{ ...job, estimate: 150 } as typeof job & { estimate?: number }] }
  engine(on, { projectWork })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'job-j1' }))?.text).toContain('Build the engine · 1m')
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ type: 'Text', text: /✎.*about 2m left/ }))?.text).toMatch(/^ {2}━+✎┄+ about 2m left$/)
  const again = () => $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  projectWork.jobs = [{ ...job, estimate: 45 }]
  await again()
  expect(await ui.find({ type: 'Text', text: /taking longer than last time/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /✎/ })).toBeUndefined()
  projectWork.jobs = [job]
  await again()
  expect(await ui.find({ key: 'job-j1' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /left|longer|✎/ })).toBeUndefined()
  await ui.unmount()
})

test("the plan row shows which checkbox step is next, and nothing for a plan without boxes", async ($, on) => {
  const files = fakeFs(on, { '/code/paper/plans/one.md': '# The active plan\n- [x] a\n- [x] b\n- [ ] c\n',
    '/code/paper/plans/two.md': '# Prose only\n' })
  engine(on, { runtime: '/run/t', files, projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/one.md', kind: 'submit' })
  // The front page's one plan line: the first unticked step, and where it stands; the project page has the ruler.
  expect((await ui.find({ key: 'plan-open' }))?.props.label).toBe('◇ c · 3/3')
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await ui.find({ type: 'Text', text: /step 3 of 3/ })).toBeDefined()
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/two.md', kind: 'submit' })
  expect(await ui.find({ type: 'Text', text: /step \d+ of/ })).toBeUndefined()
  await ui.unmount()
})

test("last night's goodnight note is pointed to at the start and opens from the project page, never sent to Claude", async ($, on) => {
  const note = '/state/foxml/goodnight/paper.md'
  const files = fakeFs(on, { [note]: '# where we left off\n\nthe ruler works; the drawer is next\n' }, { [note]: NOW - 10 * 3600 * 1000 })
  engine(on, { state: '/state', files, projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  expect(seen.toasts).toContain("last night's note is waiting · /notebook project")
  expect(seen.submitted).toEqual([])
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'last-night' }))?.text).toContain('last night · where we left off')
  await ui.press({ key: 'last-night' })
  expect(seen.argv).toContain('desk-work open --root /state/foxml/goodnight --action file --file paper.md')
  await ui.unmount()
})

test("an old goodnight note stays out of the way", async ($, on) => {
  const note = '/state/foxml/goodnight/paper.md'
  const files = fakeFs(on, { [note]: 'old news\n' }, { [note]: NOW - 40 * 3600 * 1000 })
  engine(on, { state: '/state', files, projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  expect(seen.toasts.some(t => t.includes('last night'))).toBe(false)
  await $.command.run({ command: 'notebook', args: 'project', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'last-night' })).toBeUndefined()
  await ui.unmount()
})

test('the notebook says where the branch stands, what CI made of the push, and how long the turn has run', async ($, on) => {
  engine(on, { ci: [
    { workflowName: 'ci', status: 'completed', conclusion: 'success', url: 'https://github.com/o/paper/actions/runs/1' },
    { workflowName: 'keybinds-sync', status: 'completed', conclusion: 'failure', url: 'https://github.com/o/paper/actions/runs/2' },
  ] })
  await opened($)
  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'work-ci' }))?.text).toContain('! CI · keybinds-sync failed')
  expect(seen.toasts).toContain('! CI · keybinds-sync failed')
  await ui.press({ key: 'work-ci' })
  expect(seen.argv).toContain('xdg-open https://github.com/o/paper/actions/runs/2')
  expect(await ui.find({ type: 'Text', text: /working/ })).toBeUndefined()
  // The branch's name is on the status line; the project page says only where it stands.
  await ui.press({ key: 'nav-more' })
  expect(await ui.find({ type: 'Text', text: /^pushed$/ })).toBeDefined()
  await ui.press({ key: 'nav-back' })
  await ui.unmount()

  await $.prompt.submit({ text: 'run the tests', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Bash', command: 'true', description: 'Run the drawer tests' })
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^── last turn ─+ working ──$/ }), 'the turn under way, on the last turn\'s rule').toBeDefined()
  expect((await ui.find({ type: 'Text', text: /Run the drawer tests/ }))?.text).toBe('  ◷ Run the drawer tests')
  await ui.unmount()
  expect(seen.argv.filter(a => a.startsWith('gh run list')).length).toBe(1)
})

test('a finished turn leaves a receipt: its files, its tests, its commits and what it touched in the red zone', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  const clock = mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)          // nothing beneath the plugin answers the engine's own event
  await opened($)
  await $.prompt.submit({ text: 'tidy the readme', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Bash', command: "sed -i 's/a/b/' README.md", description: 'Tidy the readme' })
  await $.tool.call({ tool: 'Bash', command: 'sudo bootctl update', description: 'Update the boot loader' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file · ⚠ bootctl')
  expect(await ui.find({ type: 'Text', text: /── last turn/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /── review/ })).toBeDefined()
  await ui.unmount()
  await hide($)
  const band = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  // The red-zone warning comes first; once acknowledged, the turn's receipt is the line above the prompt.
  expect((await band.find({ type: 'Text', text: /red zone/ }))).toBeDefined()
  await band.press({ key: 'dismiss' })
  await band.unmount()
  const after = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  expect((await after.find({ type: 'Text', text: /turn done/ }))).toBeDefined()
  expect((await after.find({ type: 'Text', text: /1 file/ }))?.text).toContain('⚠ bootctl')
  await after.unmount()
  // The row opens what it names: this turn's file in this session's review, not the general queue.
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  seen.argv = []
  await pane.press({ key: 'receipt-files' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file README.md --session abc')
  await pane.unmount()
  // A later turn that edits the same file again lists it again, though its first edit was a turn ago.
  await clock.advance(60_000)
  await $.prompt.submit({ text: 'again', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'new', new_string: 'newer' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const again = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await again.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file')
  expect(await again.find({ key: 'receipt-risk-bootctl' })).toBeUndefined()
  await again.unmount()
})

test('the last turn counts the functions it changed, and each opens its call graph in Neovim', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'old' }, { '/code/paper/README.md': NOW })
  const symbols = JSON.stringify({ version: 1, files: [{ rel: 'README.md', symbols: [
    { name: 'M.alpha', kind: 'function_declaration', side: 'after', line: 2 },
    { name: 'M.delta', kind: 'function_declaration', side: 'after', line: 8 },
    { name: 'gamma', kind: 'function_declaration', side: 'before', line: 8 },
    { name: 'lines 12–14', kind: 'hunk', side: 'after', line: 12 }] }] })
  engine(on, { runtime: '/run/t', clock: false, files, symbols })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'change a', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'old', new_string: 'new' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  // The file as the turn found it goes to Neovim on stdin, never to a file.
  const asked = seen.stdin.map(s => { try { return JSON.parse(s) } catch { return null } }).find(v => v && v.root)
  expect(asked).toEqual({ root: '/code/paper', files: [{ rel: 'README.md', before: 'old' }] })
  expect(seen.argv.some(a => a.startsWith('sh -c exec nvim --headless --clean -l ') && a.endsWith('--turn-symbols'))).toBe(true)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  // One row on the fixed front page: the count is on the right of the turn's own line.
  expect((await ui.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file · 3 functions')
  await ui.press({ key: 'receipt-files' })
  expect(await ui.find({ type: 'Text', text: /── this turn/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /gamma — removed/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /lines 12–14/ })).toBeDefined()
  expect(await ui.find({ key: 'turn-symbol:README.md:8:gamma' }), 'a removed function has no graph to open').toBeUndefined()
  seen.argv = []
  await ui.press({ key: 'turn-symbol:README.md:2:M.alpha' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action callgraph --file README.md --index 2')
  seen.argv = []
  await ui.press({ key: 'turn-review' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file README.md --session abc')
  await ui.unmount()
})

test('without Neovim the turn card is as before: no count, and Enter opens the review', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'old' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'change a', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'old', new_string: 'new' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file')
  seen.argv = []
  await ui.press({ key: 'receipt-files' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file README.md --session abc')
  await ui.unmount()
})

test('before a push the notebook says what goes out unreviewed, and never stops it', async ($, on) => {
  engine(on, { pushCheck: { unpushed: 3, unreviewed: 2, risky: [{ sha: 'abc1234', what: '/etc/pam.d' }],
    line: '2 Claude commits not reviewed · 1 touches the red zone (/etc/pam.d)' } })
  await opened($)
  seen.toasts = []
  const ran = await $.tool.call({ tool: 'Bash', command: 'git push origin main', description: 'Push' })
  expect(seen.toasts).toContain('pushing · 2 Claude commits not reviewed · 1 touches the red zone (/etc/pam.d)')
  expect((ran as { deny?: string }).deny).toBeUndefined()
  expect(seen.bash).toContain('git push origin main')
  seen.toasts = []
  await $.tool.call({ tool: 'Bash', command: 'git push --dry-run', description: 'Try' })
  await $.tool.call({ tool: 'Bash', command: 'git status', description: 'Look' })
  expect(seen.toasts.filter(t => t.startsWith('pushing'))).toEqual([])
})

test('the work takes one name: the plan in the header, and on the pane as a label free of shell characters', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/plans/one.md': "# Plan: Queue's `refactor` $(x); now\n- [ ] a\n" })
  engine(on, { runtime: '/run/t', files, pane: '%7' })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/one.md', kind: 'submit' })
  const set = seen.argv.filter(c => c.startsWith('tmux set-option -p -t %7 @work '))
  expect(set.at(-1)).toBe('tmux set-option -p -t %7 @work Queue s refactor (x) now')
  expect((await ui.find({ type: 'Text', text: /^Queue/ }))?.text).toMatch(/^Queue's `refactor`/)   // the header: the plan, not "Plan: …"
  await ui.unmount()
})

test('needs you comes first: a request whose file changed, files edited since review; waiting requests sit under review', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 0,
    review: { working: { files: { 'README.md': { state: 'changed', at: 1 } }, checked: 0, changed: 1, total: 2, completed: false, at: 1 } },
    requests: [
      { file: 'src/queue.cpp', name: 'Queue refactor', sid: 'q1', text: 'rename head', at: 1, state: 'ready' },
      { file: 'src/worker.cpp', name: 'Queue refactor', sid: 'q1', text: 'drain first', at: 1, state: 'waiting' }] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  const rules = (await ui.findAll({ type: 'Text', text: /^── / })).map(t => String(t.text).replace(/ ─.*$/, ''))
  expect(rules.indexOf('── needs you')).toBe(0)
  expect(rules.indexOf('── needs you')).toBeLessThan(rules.indexOf('── plan'))
  expect((await ui.find({ key: 'attention-request-src/queue.cpp' }))?.props.label).toBe('↻ queue.cpp · re-review')
  expect((await ui.find({ key: 'attention-changed' }))?.props.label).toBe('↻ 1 changed since you reviewed · README.md')
  expect((await ui.find({ key: 'request-src/worker.cpp' }))?.props.label).toBe('✉ worker.cpp · sent · Queue refactor')
  seen.argv = []
  await ui.press({ key: 'attention-request-src/queue.cpp' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file src/queue.cpp --session abc')
  // One key goes to the first thing that needs you.
  seen.argv = []
  await ui.press({ key: 'nav-next' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action file-diff --file src/queue.cpp --session abc')
  expect((await ui.find({ key: 'nav-next' }))?.props.hotkey).toBe('n')
  // A waiting request opens its thread: the words, where it stands, send again or withdraw.
  await ui.press({ key: 'request-src/worker.cpp' })
  expect(await ui.find({ type: 'Text', text: /"drain first"/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /the file has not changed yet/ })).toBeDefined()
  expect((await ui.find({ key: 'request-again' }))?.props.label).toBe('✉ send again · session ended')
  seen.argv = []
  await ui.press({ key: 'request-withdraw' })
  expect(seen.argv).toContain('desk-work review-request --root /code/paper --file src/worker.cpp --clear yes')
  await ui.unmount()
})

test('resending preserves the original request baseline, including when delivery fails', async ($, on) => {
  engine(on, { delivery: false, projectWork: { tests: null, jobs: [], tasks: [], pending: 0, requests: [
    { file: 'README.md', name: 'Ledger tidy', sid: 'p1', text: 'keep the old name', at: 1, state: 'waiting' }] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'request-README.md' })
  seen.argv = []
  await ui.press({ key: 'request-again' })
  expect(seen.toasts).toContain('not sent: session ended')
  expect(seen.argv.some(a => a.startsWith('desk-work review-request'))).toBe(false)
  expect((await ui.find({ type: 'Text', text: /"keep the old name"/ }))?.text).toBe('  "keep the old name"')
  await ui.unmount()
})

test('a delivered retry does not reset the request baseline or repeat changed counts in the overview', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 2,
    review: { working: { files: { 'README.md': { state: 'changed', at: 1 } }, checked: 0, changed: 1, total: 2, completed: false, at: 1 } },
    requests: [{ file: 'src/worker.cpp', name: 'Ledger tidy', sid: 'p1', text: 'drain first', at: 1, state: 'waiting' }] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'review-open' }), 'one review line, not a second count of the same files').toBeUndefined()
  expect((await ui.find({ key: 'page-files' }))?.props.label).toBe('✎ 2 changed · 0 reviewed')
  await ui.press({ key: 'request-src/worker.cpp' })
  seen.argv = []
  await ui.press({ key: 'request-again' })
  expect(seen.toasts).toContain('note left for Ledger tidy')
  expect(seen.argv.some(a => a.startsWith('desk-work review-request'))).toBe(false)
  await ui.unmount()
})

test('a failed git refresh keeps the last file list and offers a retry', async ($, on) => {
  const gitFailure = { value: false }
  engine(on, { gitFailure })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  gitFailure.value = true
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ key: 'page-files' }))?.text).toContain('2 changed')
  expect(await ui.find({ key: 'sync-retry' }), 'the header says the page is not current').toBeDefined()
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ key: 'refresh-now' }))?.props.label).toContain('may be out of date')
  gitFailure.value = false
  await ui.press({ key: 'refresh-now' })
  expect((await ui.find({ key: 'refresh-now' }))?.props.label).toContain('work tool unavailable')
  await ui.unmount()
})

test('compact mode reserves thirty columns, remembers its choice and expands without sending a prompt', async ($, on) => {
  engine(on, { compact: true, projectWork: { tests: null, tasks: [], jobs: [], pending: 9, attention: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns: 30 }, surface: 'terminal' })
  expect((await ui.find({ key: 'compact-attention' }))?.props.label).toBe('all quiet')
  expect(await ui.find({ key: 'page-files' })).toBeUndefined()
  await ui.press({ key: 'compact-expand' })
  expect(await ui.find({ key: 'page-files' })).toBeDefined()
  expect(seen.opened.at(-1)).toMatchObject({ columns: 42, rows: 17 })
  await $.command.run({ command: 'notebook', args: 'compact', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(seen.opened.at(-1)).toMatchObject({ columns: 30, rows: 4 })
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('the notebook uses shared attention actions and separates agents without message support', async ($, on) => {
  engine(on, { agents: [{ key: 'pi:p1', id: 'p1', agent: 'pi', name: 'Worker', root: '/code/paper', project: 'paper', state: 'working', busy: true, pane: '%7', canMessage: false, files: [], attribution: 'observed tool edits' }],
    projectWork: { tests: null, tasks: [], jobs: [], pending: 0,
      attention: [{ id: 'request:README.md', kind: 'request', root: '/code/paper', label: 'README.md', why: 'Changed since you asked', at: 1, file: 'README.md', action: { kind: 'file-diff', file: 'README.md' } }] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  await ui.press({ key: 'nav-next' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action attention --id request:README.md')
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ key: 'page-sessions' }))?.props.label).toBe('2 sessions')
  await ui.press({ key: 'page-sessions' })
  expect(await ui.find({ key: 'go-pi:p1' })).toBeDefined()
  expect(await ui.find({ key: 'note-pi:p1' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'note delivery unavailable' })).toBeDefined()
  await ui.unmount()
})

test('past three items needs you folds into one counted line, and its page lists every item', async ($, on) => {
  const item = (kind: string, id: string, label: string, action: { kind: string; id?: string }) =>
    ({ id: `${kind}:${id}`, kind, root: '/code/paper', label, why: 'Waiting', at: 1, action })
  const attention = [
    item('job', 'r1', 'unit tests', { kind: 'tests', id: 'r1' }),
    item('agent', 'pi:p1', 'Worker', { kind: 'agent' }),
    ...Array.from({ length: 23 }, (_, i) => item('commit', 'c'.repeat(39) + String(i % 10), `commit ${i}`, { kind: 'reviews', id: 'c'.repeat(40) })),
  ]
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 23, attention } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  expect((await ui.find({ key: 'attention-summary' }))?.props.label).toBe('! 25 need you · open list')
  expect(await ui.find({ key: 'attention-commit:' + 'c'.repeat(39) + '0' })).toBeUndefined()
  for (const words of [/23 commits to review/, /1 test run failed/, /1 agent waiting/]) expect(await ui.find({ type: 'Text', text: words }), String(words)).toBeDefined()
  await ui.press({ key: 'nav-next' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action attention --id job:r1')
  await ui.press({ key: 'attention-summary' })
  expect(await ui.find({ key: 'attention-job:r1' })).toBeDefined()
  expect(await ui.find({ key: 'attention-next' })).toBeDefined()
  await ui.press({ key: 'attention-next' })
  expect(await ui.find({ key: 'attention-job:r1' })).toBeUndefined()
  expect(await ui.find({ key: 'attention-previous' })).toBeDefined()
  await ui.press({ key: 'nav-next' })
  expect(seen.argv.filter(a => a === 'desk-work open --root /code/paper --action attention --id job:r1').length, 'n opens the most urgent from any page of the list').toBe(2)
  await ui.unmount()
})

test('the review backlog can be set aside from the needs-you page and brought back', async ($, on) => {
  const commit = (c: string) => ({ id: 'commit:' + c.repeat(40), kind: 'commit', root: '/code/paper', label: 'step ' + c, why: 'Not reviewed yet', at: 1, action: { kind: 'reviews', id: c.repeat(40) } })
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 2, attention: [commit('a'), commit('b')], aside: { count: 7, at: NOW / 1000 - 3600 } } })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'attention', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  expect((await ui.find({ key: 'needs-aside' }))?.props.label).toBe('set aside 2 commits to review · catch up later')
  expect((await ui.find({ key: 'needs-bring-back' }))?.props.label).toBe('bring back 7 set-aside commits · undo')
  await ui.press({ key: 'needs-aside' })
  expect(seen.argv.some(a => a.startsWith('desk-work set-aside')), 'nothing is set aside until it is confirmed').toBe(false)
  await ui.press({ key: 'aside-confirm' })
  expect(seen.argv).toContain('desk-work set-aside --root /code/paper')
  await ui.press({ key: 'needs-bring-back' })
  expect(seen.argv).toContain('desk-work set-aside --root /code/paper --undo yes')
  await ui.unmount()
})

test('three or fewer stay as rows, and a refusal toasts what desk-work said', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 0,
    attention: [{ id: 'records:review-marks.json', kind: 'records', root: '/code/paper', label: 'The review marks record cannot be read', why: 'Writes to it are refused until work health sets it aside (not valid JSON)', at: 1, file: 'review-marks.json', action: { kind: 'health' } }],
    records: [{ file: 'review-marks.json', label: 'review marks', why: 'not valid JSON' }] },
    refusals: { 'desk-work open ': 'That item is settled. Refresh the list.' } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  expect(await ui.find({ key: 'attention-summary' })).toBeUndefined()
  expect((await ui.find({ key: 'attention-records:review-marks.json' }))?.props.label).toBe('! The review marks record cannot be read · repair')
  expect((await ui.find({ key: 'page-files' }))?.props.label, 'an unreadable record is said, not counted as zero').toMatch(/review marks unreadable$/)
  await ui.press({ key: 'attention-records:review-marks.json' })
  expect(seen.toasts).toContain('That item is settled. Refresh the list.')
  await ui.unmount()
})

test('an installed update this session has not loaded names the steps that keep the conversation', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 0,
    integration: { status: 'reload-pending', message: 'Update installed · reload pending',
      sessions: [{ client: 'notebook', status: 'reload-pending', reload: 'In that Claude pane: /exit, then claude --resume abc. The conversation comes back with the new notebook.' }] } } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  expect((await ui.find({ key: 'reload-pending' }))?.props.label, 'a needs-you row on the front page').toBe('↻ update installed · reload to use it')
  await $.command.run({ command: 'notebook', args: 'attention', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  let shown = false
  for (let i = 0; i < 20 && !shown; ++i) {
    await ui.press({ key: 'nav-down' })
    shown = (await ui.find({ type: 'Text', text: /claude --resume abc/ })) !== undefined
  }
  expect(shown, 'the reload row says, when selected, the steps for this session').toBe(true)
  await ui.press({ key: 'reload-pending' })
  expect(seen.argv.some(a => a.startsWith('desk-work notebook') && a.includes('--health yes')), 'the row opens work health').toBe(true)
  await ui.unmount()
})

test('a burst of fifty change events refreshes the notebook at once and once more a second later, not fifty times', async ($, on) => {
  engine(on, { clock: false, watchBurst: 50, projectWork: { tests: null, tasks: [], jobs: [], pending: 0 } })
  const clock = mock.clock(on, { now: NOW })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const reads = () => seen.argv.filter(a => a.startsWith('desk-work notebook')).length
  await clock.advance(10)
  expect(seen.argv.some(a => a.startsWith('desk-work watch')), 'the notebook subscribes to the change stream').toBe(true)
  const during = reads()
  expect(during, `refreshes while 50 events arrive: ${during}`).toBeLessThanOrEqual(4)
  await clock.advance(1000)
  expect(reads(), 'the last event is still read, a second later').toBe(during + 1)
  await clock.advance(5000)
  expect(reads(), 'and nothing more once the burst is over').toBe(during + 1)
  // One report for the first refresh and one when this test's stream ends (a real change of state); none per event.
  expect(seen.argv.filter(a => a.startsWith('desk-work client-report')).length, 'no client report per event').toBeLessThanOrEqual(2)
  await ui.unmount()
})

test('the files page filters to what needs review, to what changed since, and by name; the marks page explains', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 0,
    review: { working: { files: { 'README.md': { state: 'checked', at: 1 } }, checked: 1, changed: 0, total: 2, completed: false, at: 1 } } } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'page-files' })
  await ui.press({ key: 'scope-all' })
  expect(await ui.find({ key: 'file:README.md' })).toBeDefined()
  expect((await ui.find({ key: 'files-show' }))?.props.label).toBe('○ showing everything · 1 need review')
  await ui.press({ key: 'files-show' })
  expect((await ui.find({ key: 'files-show' }))?.props.label).toBe('● only what needs review · 1')
  expect(await ui.find({ key: 'file:README.md' })).toBeUndefined()
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeDefined()
  await ui.press({ key: 'files-show' })
  expect((await ui.find({ key: 'files-show' }))?.props.label).toBe('● only changed since review · 0')
  expect(await ui.find({ type: 'Text', text: /Nothing matches these filters/ })).toBeDefined()
  await ui.press({ key: 'files-show' })
  await ui.press({ key: 'files-search' })
  await ui.input({ key: 'files-query', text: 'readme', kind: 'submit' })
  expect(await ui.find({ key: 'file:README.md' })).toBeDefined()
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeUndefined()
  expect((await ui.find({ key: 'files-search' }))?.props.label).toBe('/ readme · clear')
  await ui.press({ key: 'files-search' })
  expect(await ui.find({ key: 'file:shared/a very long folder/notes.txt' })).toBeDefined()
  await ui.press({ key: 'nav-back' })
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'page-help' })
  expect(await ui.find({ type: 'Text', text: /edited since you reviewed it/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /── keys/ })).toBeDefined()
  await ui.unmount()
})

test('a page that could not refresh says so and offers a retry; one without the work tool says that', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'sync-retry' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /updated/ }), 'no clock ticking on the front page').toBeUndefined()
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ key: 'refresh-now' }))?.props.label).toBe('work tool unavailable · retry')
  seen.argv = []
  await ui.press({ key: 'refresh-now' })
  expect(seen.argv.some(a => a.startsWith('git --no-optional-locks'))).toBe(true)
  await ui.unmount()
})

test('the timeline and digest use backend event identities and acknowledge only the displayed revision', async ($, on) => {
  const events = [{ id: '12', seq: 12, kind: 'edit', root: '/code/paper', at: NOW / 1000,
    label: 'queue.cpp · pi edited', action: { kind: 'file-diff', file: 'queue.cpp' } }]
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [], timeline: events,
    digest: { total: 1, files: 1, through: 12, counts: { edit: 1 }, events, truncated: false, summary: '1 observed file edited' } } })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'timeline', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'event-12' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action event --id 12')
  await $.command.run({ command: 'notebook', args: 'digest', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await ui.find({ type: 'Text', text: '1 observed file edited' })).toBeDefined()
  await ui.press({ key: 'digest-caught-up' })
  expect(seen.argv).toContain('desk-work digest --root /code/paper --consumer notebook --through 12')
  expect(seen.submitted).toEqual([])
  await ui.unmount()
})

test('automatic sizing follows the measured viewport and does not request keyboard focus', async ($, on) => {
  engine(on, { clock: false, projectWork: { tests: null, tasks: [], jobs: [], attention: [] } })
  const clock = mock.clock(on, { now: NOW })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'auto', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  seen.opened = []
  const small = await $.ui.mount({ ...PANE, surface: 'terminal', viewport: { columns: 120, rows: 40, isFullscreen: true } })
  expect(await small.find({ key: 'compact-expand' })).toBeDefined()
  await clock.advance(1000)
  expect(seen.opened.at(-1)).toMatchObject({ columns: 30 })
  expect((seen.opened.at(-1) as { focus?: true })?.focus).toBeUndefined()
  await small.unmount()
  seen.opened = []
  const large = await $.ui.mount({ ...PANE, surface: 'terminal', viewport: { columns: 180, rows: 40, isFullscreen: true } })
  expect(await large.find({ key: 'page-files' })).toBeDefined()
  await clock.advance(1000)
  expect(seen.opened.at(-1)).toMatchObject({ columns: 42 })
  expect((seen.opened.at(-1) as { focus?: true })?.focus).toBeUndefined()
  expect(seen.submitted).toEqual([])
  await large.unmount()
})

test('snoozing an attention item changes the shared record without marking the file reviewed', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [{ id: 'request:queue.cpp', kind: 'request', root: '/code/paper',
    label: 'queue.cpp', why: 'Changed since requested', at: NOW / 1000, action: { kind: 'file-diff', file: 'queue.cpp' } }] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' })
  await ui.press({ key: 'attention-request:queue.cpp' })
  await ui.press({ key: 'nav-snooze' })
  await ui.press({ key: 'snooze-change' })
  expect(seen.argv).toContain('desk-work snooze --root /code/paper --id request:queue.cpp --until-change yes')
  expect(seen.argv.some(argv => argv.startsWith('desk-work review-mark '))).toBe(false)
  await ui.unmount()
})

test('after a push the review stamps follow only where the repository asks, and a refusal is said', async ($, on) => {
  engine(on, { pushNotes: { pushed: true, remote: 'origin' } })
  await opened($)
  seen.toasts = []
  await $.tool.call({ tool: 'Bash', command: 'git push origin main', description: 'Push' })
  expect(seen.argv.some(a => a.startsWith('desk-work push-notes --root /code/paper'))).toBe(true)
  expect(seen.toasts).toContain('review stamps pushed too')
  seen.argv = []
  await $.tool.call({ tool: 'Bash', command: 'git status', description: 'Look' })
  expect(seen.argv.some(a => a.startsWith('desk-work push-notes'))).toBe(false)
})

test('the needs-you list groups commits under a heading per day, newest day first, and j/k pass over the headings', async ($, on) => {
  const at = (days: number, hour: number) => { const d = new Date(NOW); d.setDate(d.getDate() - days); d.setHours(hour, 0, 0, 0); return d.getTime() / 1000 }
  const commit = (c: string, when: number) => ({ id: 'commit:' + c.repeat(40), kind: 'commit', root: '/code/paper', label: 'step ' + c, why: 'Not reviewed yet', at: when, action: { kind: 'reviews', id: c.repeat(40) } })
  // desk-work's order: an older day's commit first, then two of today's, newest first.
  const attention = [commit('a', at(1, 10)), commit('b', at(0, 15)), commit('c', at(0, 9)),
    { id: 'job:r1', kind: 'job', root: '/code/paper', label: 'unit tests', why: 'Failed', at: at(0, 8), action: { kind: 'tests', id: 'r1' } }]
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 3, attention } })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'attention', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never)
  const label = (days: number) => { const d = new Date(at(days, 12) * 1000)
    return `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]} ${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
  const texts = (await ui.findAll({ type: 'Text' })).map(t => String(t.text))
  const today = texts.findIndex(t => t.startsWith(`── ${label(0)} `)), yesterday = texts.findIndex(t => t.startsWith(`── ${label(1)} `))
  expect(today, texts.join('\n')).toBeGreaterThan(-1)
  expect(yesterday, 'the older day comes after the newer one').toBeGreaterThan(today)
  expect(texts[today], "the day's count").toMatch(/ 2 ──$/)
  expect(texts[yesterday]).toMatch(/ 1 ──$/)
  // The rows in order: the failed job, then today's two in desk-work's order, then yesterday's.
  const keys = (await ui.findAll({ type: 'Button' })).map(b => String(b.key ?? b.props.key ?? '')).filter(k => k.startsWith('attention-'))
  expect(keys).toEqual(['attention-job:r1', 'attention-commit:' + 'b'.repeat(40), 'attention-commit:' + 'c'.repeat(40), 'attention-commit:' + 'a'.repeat(40)])
  // j walks row to row: from today's last commit straight onto yesterday's, over its heading.
  const cursor = async () => (await ui.findAll({ type: 'Button' })).find(b => String(b.text ?? '').startsWith('› '))?.props.label
  for (let i = 0; i < 3; ++i) await ui.press({ key: 'nav-down' })
  expect(await cursor()).toBe('○ step c · to review')
  await ui.press({ key: 'nav-down' })
  expect(await cursor(), 'j skips the heading').toBe('○ step a · to review')
  await ui.press({ key: 'nav-up' })
  expect(await cursor(), 'and k skips it going back').toBe('○ step c · to review')
  await ui.unmount()
})

test("the project page lists the last job's figures with their change; the front page stays as it was", async ($, on) => {
  const id = 'e'.repeat(32)
  const metric = (name: string, value: number, unit: string, delta: string, verdict: string, better: string | null) =>
    ({ name, value, unit, source: 'output', previous: null, change: delta ? Number(delta) : null, percent: null, delta, better, verdict })
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], metrics: {
    job: { id, title: 'Queue bench', command: 'make bench', state: 'passed', ended: NOW / 1000 - 120, testRun: false },
    previous: { id: 'd'.repeat(32), ended: NOW / 1000 - 3600 },
    metrics: [metric('p99', 412, 'ns', '+38', 'worse', 'lower'), metric('throughput', 1.2, 'M/s', '+0.1', 'better', 'higher'),
      metric('rss', 12, 'MB', '', 'same', null)] } } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'metric-p99' }), 'not on the front page').toBeUndefined()
  await ui.press({ key: 'nav-more' })
  expect((await ui.find({ type: 'Text', text: /Queue bench/ }))?.text).toMatch(/^(figures|FIGURES) · Queue bench/)
  expect((await ui.find({ key: 'metric-p99' }))?.text).toMatch(/p99 412ns \(\+38\) +↑ (worse|WORSE)$/)
  expect((await ui.find({ key: 'metric-throughput' }))?.text).toMatch(/throughput 1\.2M\/s \(\+0\.1\) +↑ (better|BETTER)$/)
  expect((await ui.find({ key: 'metric-rss' }))?.text).toMatch(/rss 12MB +(same|SAME)$/)
  await ui.press({ key: 'metric-p99' })
  expect(seen.argv).toContain(`desk-work open --root /code/paper --action log --id ${id}`)
  await ui.unmount()
})

test("the project page opens Neovim's since page through desk-work, with nothing but the action in its arguments", async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'nvim-since' }), 'not on the front page').toBeUndefined()
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'nvim-since' })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action since')
  await ui.unmount()
})

test('a job with no figures adds nothing to the project page', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], metrics: { job: null, previous: null, metrics: [] } } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'nav-more' })
  expect(await ui.find({ type: 'Text', text: /figures|FIGURES/ })).toBeUndefined()
  await ui.unmount()
})
