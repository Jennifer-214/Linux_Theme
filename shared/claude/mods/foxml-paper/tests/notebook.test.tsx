import { expect, mock, test } from 'claude-code/testing'
import { mailId } from '../hooks/notebook'
import { BAND, NOW, PANE, PEERS, done, engine, fakeFs, opened, seen } from './kit'

test('the notebook shows the hearts, the session name and the pages touched', async ($, on) => {
  engine(on)
  await opened($)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /▰▰▰▱▱/ }))?.text).toBe('▰▰▰▱▱ 64%')
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
  await ui.press({ key: 'page-project' })
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
  expect((await ui.find({ key: 'page-sessions' }))?.props.label).toBe('3 claudes · you + 2 others')
  await ui.press({ key: 'page-sessions' })
  expect((await ui.find({ type: 'Text', text: /claudes · you/ }))?.text).toBe('3 claudes · you and 2 others')
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
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect((await ui.find({ key: 'plan-open' }))?.text).toContain('The active plan')
  expect((await ui.find({ key: 'plan-step' }))?.text).toContain('ship file selection')
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
  await ui.press({ key: 'page-project' })
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


test('the notebook at rest shows no key hints and no credit meter while credit is plentiful', async ($, on) => {
  engine(on, { credits: { short: 'API ~$180.00 left', headline: '$20.00 tracked of $200.00', detail: 'Tracked runs only · renews Dec 1',
    meter: '▰▰▰▰▰▰▰▰▰▱', status: 'tracked', source: 'local', remaining_percent: 90, as_of: '2026-11-09T00:00:00Z', projects: [] } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'api-credit-meter' })).toBeUndefined()
  expect(await ui.find({ key: 'nav-back' })).toBeUndefined()
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
  expect((await ui.find({ type: 'Text', text: /64%/ }))?.text).toContain('64%')
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
  expect(seen.argv).toContain('desk-work begin --root /code/paper --session abc --pid parent --command make -C src test --title Run the unit tests')
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
  expect((await ui.find({ type: 'Text', text: /✎.*about 2m left/ }))?.text).toMatch(/^ {2}━+✎┄+ about 2m left$/)
  const again = () => $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  projectWork.jobs = [{ ...job, estimate: 45 }]
  await again()
  expect(await ui.find({ type: 'Text', text: /taking longer than last time/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /✎/ })).toBeUndefined()
  projectWork.jobs = [job]
  await again()
  expect((await ui.find({ key: 'job-j1' }))?.text).toContain('· 1m')
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
  // The plan's row carries the step on the right; the ruler under it counts what is ticked.
  expect((await ui.find({ key: 'plan-open' }))?.props.label).toBe('⌑ The active plan · step 3 of 3')
  expect((await ui.find({ type: 'Text', text: /2 of 3 done/ }))?.text).toMatch(/^ {2}━+┄+ 2 of 3 done$/)
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
  expect((await ui.find({ key: 'page-project' }))?.props.label).toBe('main · pushed')
  expect((await ui.find({ key: 'page-project' }))?.text).toMatch(/main +pushed$/)
  expect((await ui.find({ key: 'work-ci' }))?.text).toContain('✗ CI · keybinds-sync failed')
  expect(seen.toasts).toContain('✗ CI · keybinds-sync failed')
  await ui.press({ key: 'work-ci' })
  expect(seen.argv).toContain('xdg-open https://github.com/o/paper/actions/runs/2')
  expect(await ui.find({ type: 'Text', text: /working/ })).toBeUndefined()
  await ui.unmount()

  await $.prompt.submit({ text: 'run the tests', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Bash', command: 'true', description: 'Run the drawer tests' })
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /working/ }))?.text).toBe('◷ working · Run the drawer tests')
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
  expect((await ui.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file changed · 0 of 1 reviewed')
  expect((await ui.find({ key: 'receipt-risk-bootctl' }))?.props.label).toBe('⚠ touched bootctl · red zone')
  expect(await ui.find({ type: 'Text', text: /── last turn/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /── review/ })).toBeDefined()
  await ui.unmount()
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
  expect((await again.find({ key: 'receipt-files' }))?.props.label).toBe('✎ 1 file changed · 0 of 1 reviewed')
  expect(await again.find({ key: 'receipt-risk-bootctl' })).toBeUndefined()
  await again.unmount()
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
  expect((await ui.find({ type: 'Text', text: /^ · Queue/ }))?.text).toMatch(/^ · Queue's `refactor`/)   // the header: the plan, not "Plan: …"
  await ui.unmount()
})

test('needs you comes first: a request whose file changed, files edited since review; waiting requests sit under review', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 0,
    review: { working: { files: { 'README.md': { state: 'changed', at: 1 } }, checked: 0, changed: 1, total: 2, completed: false, at: 1 } },
    requests: [
      { file: 'src/queue.cpp', name: 'Queue refactor', sid: 'q1', text: 'rename head', at: 1, state: 'ready' },
      { file: 'src/worker.cpp', name: 'Queue refactor', sid: 'q1', text: 'drain first', at: 1, state: 'waiting' }] } })
  await opened($)
  // Focused: the keys row is drawn while the notebook holds the keyboard.
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
  // The thread reads out under the list: who was asked and what for.
  expect(await ui.find({ type: 'Text', text: /You asked Queue refactor: "rename head"/ })).toBeDefined()
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
  await ui.press({ key: 'page-help' })
  expect(await ui.find({ type: 'Text', text: /edited since you reviewed it/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /── keys/ })).toBeDefined()
  await ui.unmount()
})

test('a page that could not refresh says so and offers a retry; one without the work tool says that', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'refresh-now' }))?.props.label).toBe('work tool unavailable · retry')
  expect(await ui.find({ type: 'Text', text: /── work .* updated just now/ })).toBeDefined()
  seen.argv = []
  await ui.press({ key: 'refresh-now' })
  expect(seen.argv.some(a => a.startsWith('git --no-optional-locks'))).toBe(true)
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
