// What the rows, keys and band promise (docs/ui-style.md, or the row's own words), each held by a test. From an audit
// of the notebook, 2026-11-14: every one of these failed before its fix.
import { expect, mock, test } from 'claude-code/testing'
import { BAND, NOW, PANE, engine, fakeFs, opened, seen } from './kit'

const FOCUSED = (columns = 40) => ({ ...PANE, props: { ...PANE.props, isFocused: true, bodyColumns: columns }, surface: 'terminal' }) as never
const REQUEST = { id: 'request:queue.cpp', kind: 'request', root: '/code/paper', label: 'queue.cpp', why: 'Changed since requested',
  at: NOW / 1000, action: { kind: 'file-diff', file: 'queue.cpp' } }

test('moving the cursor inside the snooze form keeps the item being snoozed', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [REQUEST] } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  await ui.press({ key: 'attention-request:queue.cpp' })
  await ui.press({ key: 'nav-snooze' })
  expect(await ui.find({ key: 'snooze-hour' })).toBeDefined()
  await ui.press({ key: 'nav-down' })   // j, onto "later · one hour"
  expect(await ui.find({ type: 'Text', text: /already settled/ }), 'j inside the form says the item is settled').toBeUndefined()
  expect(await ui.find({ key: 'snooze-change' }), 'the second option is still there').toBeDefined()
  await ui.unmount()
})

test('a page opened from the front page starts at its top, whatever page was scrolled before', async ($, on) => {
  const commit = (i: number) => ({ id: 'commit:' + String(i).padStart(40, 'c'), kind: 'commit', root: '/code/paper', label: `step ${i}`,
    why: 'Not reviewed yet', at: i, action: { kind: 'reviews' } })
  const events = Array.from({ length: 5 }, (_, i) => ({ id: String(i), seq: i, kind: 'edit', root: '/code/paper', at: NOW / 1000 - 60 * i,
    label: `event ${i}`, action: { kind: 'file-diff', file: 'a' } }))
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 25, attention: Array.from({ length: 25 }, (_, i) => commit(i)), timeline: events } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  await ui.press({ key: 'attention-summary' })
  await ui.press({ key: 'attention-next' })      // the second twenty
  await ui.press({ key: 'nav-back' })
  await ui.press({ key: 'page-timeline' })
  const rows = (await ui.findAll({ type: 'Button' })).map(b => String(b.props.label ?? '')).filter(l => !/^(back|↑|↓|open|hide|drawer|compact|files|project|sessions)$/.test(l))
  expect(await ui.find({ key: 'event-0' }), `the timeline shows its newest event; its rows: ${JSON.stringify(rows)}`).toBeDefined()
  await ui.unmount()
})

test('the needs-you list opens on its most urgent item after another page was scrolled', async ($, on) => {
  const commit = (i: number) => ({ id: 'commit:' + String(i).padStart(40, 'c'), kind: 'commit', root: '/code/paper', label: `step ${i}`,
    why: 'Not reviewed yet', at: i, action: { kind: 'reviews' } })
  const events = Array.from({ length: 30 }, (_, i) => ({ id: String(i), seq: i, kind: 'edit', root: '/code/paper', at: NOW / 1000 - 60 * i,
    label: `event ${i}`, action: { kind: 'file-diff', file: 'a' } }))
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], pending: 25, attention: Array.from({ length: 25 }, (_, i) => commit(i)), timeline: events } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  await ui.press({ key: 'page-timeline' })
  await ui.press({ key: 'events-next' })         // older events
  await ui.press({ key: 'nav-back' })
  await ui.press({ key: 'attention-summary' })
  expect(await ui.find({ key: 'attention-' + commit(0).id }), 'the most urgent item is on screen').toBeDefined()
  await ui.unmount()
})

test('a long turn of edits still reads as working, and the previous turn is not shown as the last one', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  const clock = mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'tidy', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'new', new_string: 'newer' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  await clock.advance(60_000)
  await $.prompt.submit({ text: 'keep going', wait: false, origin: { kind: 'composer' } })
  for (let i = 0; i < 4; ++i) {
    await clock.advance(5 * 60_000)
    await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'a', new_string: 'b' })
  }
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const working = await ui.find({ type: 'Text', text: /◷ working/ }) !== undefined
  const lastTurn = await ui.find({ type: 'Text', text: /── last turn/ }) !== undefined
  expect({ working, lastTurn }, 'Claude edited a file seconds ago, 21 minutes into the turn').toEqual({ working: true, lastTurn: false })
  await ui.unmount()
})

test('a row with a long right-hand part still fits the pane (40 columns)', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 0, requests: [
    { file: 'src/worker.cpp', name: 'Workspace system build and template parity', sid: 'q1', text: 'drain first', at: 1, state: 'waiting' }] } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED(40))
  const drawn = String((await ui.find({ key: 'request-src/worker.cpp' }))?.text ?? '')
  expect(drawn.length, JSON.stringify(drawn)).toBeLessThanOrEqual(40)
  await ui.unmount()
})

test('the header fits 40 columns with an unread note and a long name', async ($, on) => {
  engine(on)
  on('classic.UserPromptSubmit', () => ({}) as never)
  await opened($)
  await $.classic.UserPromptSubmit({ hook_event_name: 'UserPromptSubmit', prompt: 'x', session_title: 'Notebook audit of every page and key binding' } as never)
  await $.session.receive({ origin: { kind: 'peer' }, text: '✉ from docs: the build is yours now' })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount(FOCUSED(40))
  const header = String((await ui.find({ type: 'Text', text: /▰/ }))?.text ?? '')
  expect(header.length, JSON.stringify(header)).toBeLessThanOrEqual(40)
  await ui.unmount()
})

test('the header fits 40 columns before the context is measured', async ($, on) => {
  engine(on, { percent: null })
  on('classic.UserPromptSubmit', () => ({}) as never)
  await opened($)
  await $.classic.UserPromptSubmit({ hook_event_name: 'UserPromptSubmit', prompt: 'x', session_title: 'Notebook audit of every page and key binding' } as never)
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount(FOCUSED(40))
  const header = String((await ui.find({ type: 'Text', text: /context not measured/ }))?.text ?? '')
  expect(header.length, JSON.stringify(header)).toBeLessThanOrEqual(40)
  await ui.unmount()
})

test('a timeline row from yesterday fits 40 columns', async ($, on) => {
  const events = [{ id: '1', seq: 1, kind: 'edit', root: '/code/paper', at: NOW / 1000 - 30 * 3600,
    label: 'src/desk-work/main.cpp · claude edited', action: { kind: 'file-diff', file: 'src/desk-work/main.cpp' } }]
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [], timeline: events } })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'timeline', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount(FOCUSED(40))
  const drawn = String((await ui.find({ key: 'event-1' }))?.text ?? '')
  expect(drawn.length, JSON.stringify(drawn)).toBeLessThanOrEqual(40)
  await ui.unmount()
})

test('the review button above the prompt says why desk-work refused to open the review', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files, refusals: { 'desk-work open ': 'No Neovim is running for this project' } })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'tidy', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'new', new_string: 'newer' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const band = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  expect(await band.find({ type: 'Text', text: /turn done/ })).toBeDefined()
  seen.toasts = []
  await band.press({ key: 'review' })
  expect(seen.argv.some(a => a.startsWith('desk-work open --root /code/paper --action reviews'))).toBe(true)
  expect(seen.toasts, 'the refusal is said').toContain('No Neovim is running for this project')
  await band.unmount()
})

test('the red-zone line of the last turn says what ran, and opens nothing unrelated', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'tidy the readme', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Bash', command: "sed -i 's/a/b/' README.md", description: 'Tidy the readme' })
  await $.tool.call({ tool: 'Bash', command: 'sudo bootctl update', description: 'Update the boot loader' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /touched bootctl · red zone/ }), 'the line says what ran').toBeDefined()
  expect(await ui.find({ key: 'receipt-risk-bootctl' }), 'it is not a row that opens something').toBeUndefined()
  await ui.unmount()
})

test('one shell command that changed two files publishes the agent state once', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new', '/code/paper/shared/a very long folder/notes.txt': 'x' },
    { '/code/paper/README.md': NOW, '/code/paper/shared/a very long folder/notes.txt': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  mock.clock(on, { now: NOW })
  await opened($)
  seen.argv = []
  await $.tool.call({ tool: 'Bash', command: "sed -i 's/a/b/' README.md notes.txt", description: 'Tidy' })
  const updates = seen.argv.filter(a => a.startsWith('desk-work agent-update'))
  expect(updates.length, updates.join('\n')).toBeLessThanOrEqual(1)
})

test('moving the cursor does not write the saved view on every key', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [] } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  seen.argv = []
  for (let i = 0; i < 5; ++i) await ui.press({ key: 'nav-down' })
  const saves = seen.argv.filter(a => a.startsWith('desk-work workspace'))
  expect(saves.length, `${saves.length} view saves for 5 key presses`).toBeLessThanOrEqual(1)
  await ui.unmount()
})

test('one changed file reads "1 changed file"', async ($, on) => {
  engine(on, { changes: { status: ' M README.md\0', numstat: '1\t0\tREADME.md\0' } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'page-files' }))?.props.label).toMatch(/^1 changed file(?!s)/)
  await ui.unmount()
})

test('the compact count and the expanded page agree (work tool without the shared list)', async ($, on) => {
  engine(on, { compact: true, projectWork: { tests: null, tasks: [], jobs: [], pending: 9 } })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns: 30 }, surface: 'terminal' })
  const said = String((await ui.find({ key: 'compact-attention' }))?.props.label)
  await ui.press({ key: 'compact-expand' })
  const rule = await ui.find({ type: 'Text', text: /── needs you/ })
  expect(said === 'all quiet' ? rule === undefined : rule !== undefined, `compact says "${said}"; the page has ${rule ? 'a' : 'no'} needs-you group`).toBe(true)
  await ui.unmount()
})

test('the marks page lists every key the footer offers', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [] } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED(44))
  expect((await ui.find({ key: 'nav-compact' }))?.props.hotkey).toBe('z')
  expect((await ui.find({ key: 'nav-hide' }))?.props.hotkey).toBe('q')
  await ui.press({ key: 'page-help' })
  expect(await ui.find({ type: 'Text', text: /^ {2}z / }), 'z is listed').toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}q / }), 'q is listed').toBeDefined()
  await ui.unmount()
})

type Node = { type?: string; key?: string; props?: Record<string, unknown>; children?: unknown[] }
const flat = (n: unknown): string => typeof n === 'string' ? n : !n || typeof n !== 'object' ? ''
  : (n as Node).type === 'Button' && !(n as Node).children?.length ? String((n as Node).props?.label ?? '')
  : ((n as Node).children ?? []).map(flat).join('')
const boxWith = (n: unknown, key: string): Node | undefined => {
  if (!n || typeof n !== 'object') return undefined
  const node = n as Node
  if (node.type === 'Box' && (node.children ?? []).some(c => !!c && typeof c === 'object' && ((c as Node).key === key || (c as Node).props?.key === key))) return node
  for (const c of node.children ?? []) { const found = boxWith(c, key); if (found) return found }
  return undefined
}

test('the key row keeps a space between drawer and later', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [REQUEST] } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  await ui.press({ key: 'attention-request:queue.cpp' })
  expect(flat(boxWith(await ui.drawn(), 'nav-drawer'))).toBe('drawer later compact')
  await ui.unmount()
})

test('when the selected row goes away in a refresh, l does not open a different one', async ($, on) => {
  const work = { tests: null, tasks: [], jobs: [], attention: [REQUEST, { ...REQUEST, id: 'request:b.cpp', label: 'b.cpp', action: { kind: 'file-diff', file: 'b.cpp' } }] }
  engine(on, { projectWork: work })
  await opened($)
  const ui = await $.ui.mount(FOCUSED())
  for (let i = 0; i < 2; ++i) await ui.press({ key: 'nav-down' })   // the cursor on b.cpp
  work.attention = [REQUEST]                                       // b.cpp settled elsewhere
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const cursor = (await ui.findAll({ type: 'Button' })).filter(b => String(b.text ?? '').startsWith('› ')).map(b => String(b.props.label))
  seen.argv = []
  await ui.press({ key: 'nav-open' })
  const opened_ = seen.argv.filter(a => a.startsWith('desk-work open'))
  expect({ cursor, opened: opened_ }, 'nothing is shown selected, so l should open nothing (or the row the cursor moved to)').toEqual({ cursor: [], opened: [] })
  await ui.unmount()
})

test('a question-only turn after "later" does not say the turn changed files', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files })
  const clock = mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'tidy', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'new', new_string: 'newer' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  let band = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  await band.press({ key: 'later' })
  await band.unmount()
  await clock.advance(60_000)
  await $.prompt.submit({ text: 'what does refreshSoon do?', wait: false, origin: { kind: 'composer' } })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  band = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  const said = (await band.findAll({ type: 'Text' })).map(t => String(t.text)).join('')
  expect(said, 'the band after a turn that changed nothing').not.toMatch(/turn done.*changed/)
  await band.unmount()
})

test('the end of a turn reads the project once more, not twice, and still sees the turn\'s own edit', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files, projectWork: { tests: null, tasks: [], jobs: [], attention: [] } })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'go', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/README.md', old_string: 'new', new_string: 'newer' })   // leaves a refresh in flight
  seen.argv = []
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const reads = seen.argv.filter(a => a.startsWith('desk-work notebook')).length
  expect(reads, `${seen.argv.length} processes before the Stop hook returned`).toBeLessThanOrEqual(2)
  const band = await $.ui.mount({ ...BAND, props: { ...BAND.props, isWorking: false }, surface: 'terminal' } as never)
  expect(await band.find({ type: 'Text', text: /turn done/ }), 'the band names the edit the turn made').toBeDefined()
  await band.unmount()
})

test('the health page says it is reading before the answer comes, not that health is unavailable', async ($, on) => {
  engine(on, { projectWork: { tests: null, tasks: [], jobs: [], attention: [] } })
  await opened($)
  await $.command.run({ command: 'notebook', args: 'health', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const ui = await $.ui.mount(FOCUSED())
  expect(await ui.find({ type: 'Text', text: /Reading work health/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /unavailable/ })).toBeUndefined()
  await ui.unmount()
})
