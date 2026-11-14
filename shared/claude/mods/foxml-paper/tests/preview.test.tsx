// The notebook drawn with sample data, for looking at: tests/notebook_preview.py prints these scenes in colour.
// Each scene goes through the real drawing code; nothing here is a mock-up.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { NOW, PANE, engine, fakeFs, opened } from './kit'

const say = (text: string) => (globalThis as { console?: { log: (line: string) => void } }).console?.log(text)
const WIDE = { ...PANE, props: { ...PANE.props, isFocused: true, bodyColumns: 44 }, surface: 'terminal' } as never
const scene = async ($: Engine, name: string, press: string[] = [], columns = 44) => {
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, isFocused: true, bodyColumns: columns }, surface: 'terminal' } as never)
  for (const key of press) await ui.press({ key })
  const tree = await ui.drawn()
  say('@@PREVIEW ' + JSON.stringify({ name, tree }))
  await ui.unmount()
  return tree
}
const WORK = {
  tests: { id: 't1', state: 'passed', ended: NOW / 1000 - 240, stale: false, changedFiles: [], tests: { passed: 128, failed: 0, failures: [] } },
  jobs: [], tasks: [{ id: 'k1', text: 'Write up the drain path', done: false }], pending: 2,
  review: { working: { files: { 'README.md': { state: 'changed', at: 1 } }, checked: 0, changed: 1, total: 2, completed: false, at: 1 } },
  requests: [
    { file: 'src/queue.cpp', name: 'Queue refactor', sid: 'q1', text: 'rename head to front, and keep the old name as an alias for now', at: NOW / 1000 - 900, state: 'ready' },
    { file: 'src/worker.cpp', name: 'Queue refactor', sid: 'q1', text: 'drain before the workers stop', at: NOW / 1000 - 300, state: 'waiting' }],
}
const PLAN = '# Plan: Queue refactor\n- [x] Split the queue header\n- [x] Move the workers onto the new queue\n- [ ] Cover the drain path\n- [ ] Document the queue\n'
const EVENTS = [
  { id: '4', seq: 4, kind: 'review', root: '/code/paper', at: NOW / 1000 - 60, label: 'queue.cpp · reviewed', action: { kind: 'file-diff', file: 'src/queue.cpp' } },
  { id: '3', seq: 3, kind: 'job', root: '/code/paper', at: NOW / 1000 - 120, label: 'Queue checks · passed', action: { kind: 'tests', id: 't1' } },
  { id: '2', seq: 2, kind: 'edit', root: '/code/paper', at: NOW / 1000 - 180, label: 'queue.cpp · pi edited', action: { kind: 'file-diff', file: 'src/queue.cpp' } },
  { id: '1', seq: 1, kind: 'request', root: '/code/paper', at: NOW / 1000 - 240, label: 'queue.cpp · changes requested', action: { kind: 'file-diff', file: 'src/queue.cpp' } },
]

test('preview: work health makes refresh and recovery state visible', async ($, on) => {
  engine(on, { projectWork: { ...WORK, health: { status: 'current', checks: [
    { id: 'versions', label: 'Installed integrations match', detail: 'Reported loaded versions are current' },
    { id: 'nvim', label: 'nvim · paper', detail: 'Stream: connected\nLoaded: current\nLast event: 2026-11-13 09:42:08\nLast refresh: 2026-11-13 09:42:08' },
    { id: 'backups', label: 'Update backups', detail: '4 transactions · 4820 KiB\nRollback chains are retained' },
  ] } } })
  await opened($)
  expect(await scene($, 'work health', ['page-health'])).toBeDefined()
})

test('preview: shared history and a quiet project digest', async ($, on) => {
  engine(on, { projectWork: { ...WORK, timeline: EVENTS, digest: { total: 4, files: 1, through: 4, counts: { edit: 1, job: 1, review: 1, request: 1 },
    events: EVENTS, truncated: false, summary: '1 observed file edited · 1 run passed' } } })
  await opened($)
  expect(await scene($, 'project timeline', ['page-timeline'])).toBeDefined()
  await $.command.run({ command: 'notebook', args: 'digest', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  expect(await scene($, 'since you last looked')).toBeDefined()
})

test('preview: the front page with a plan, a finished turn and things that need you', async ($, on) => {
  const files = fakeFs(on, { '/code/paper/plans/queue.md': PLAN, '/code/paper/README.md': 'new' }, { '/code/paper/README.md': NOW })
  engine(on, { runtime: '/run/t', clock: false, files, projectWork: WORK, ci: [
    { workflowName: 'ci', status: 'completed', conclusion: 'success', url: 'https://github.com/o/paper/actions/runs/1' }] })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  const ui = await $.ui.mount(WIDE)
  await ui.press({ key: 'plan-pin' })
  await ui.input({ key: 'plan-file', text: 'plans/queue.md', kind: 'submit' })
  await ui.unmount()
  await $.prompt.submit({ text: 'tidy the readme', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Bash', command: "sed -i 's/a/b/' README.md", description: 'Tidy the readme' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  expect(await scene($, 'front page')).toBeDefined()
  expect(await scene($, 'front page · a request selected', ['attention-request-src/queue.cpp'])).toBeDefined()
})

test('preview: the files page, a request thread and the marks page', async ($, on) => {
  engine(on, { projectWork: WORK })
  await opened($)
  expect(await scene($, 'files · only what needs review', ['page-files', 'scope-all', 'files-show'])).toBeDefined()
  expect(await scene($, 'a request thread', ['nav-back', 'request-src/worker.cpp'])).toBeDefined()
  expect(await scene($, 'marks and keys', ['request-back', 'page-help'])).toBeDefined()
})

test('preview: a quiet page with nothing wrong and no plan', async ($, on) => {
  engine(on, { projectWork: { tests: null, jobs: [], tasks: [], pending: 0 } })
  await opened($)
  expect(await scene($, 'quiet')).toBeDefined()
})

test('preview: a failed refresh keeps the last known files', async ($, on) => {
  const gitFailure = { value: false }
  engine(on, { gitFailure, projectWork: WORK })
  await opened($)
  gitFailure.value = true
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
  const tree = await scene($, 'refresh needs a retry')
  expect(tree).toBeDefined()
})

test('preview: the compact notebook keeps room for the conversation', async ($, on) => {
  engine(on, { compact: true, projectWork: { ...WORK, attention: [
    { id: 'request:src/queue.cpp', kind: 'request', root: '/code/paper', label: 'queue.cpp', why: 'Changed since you asked', at: 1, file: 'src/queue.cpp', action: { kind: 'file-diff', file: 'src/queue.cpp' } },
    { id: 'changed:README.md', kind: 'changed', root: '/code/paper', label: 'README.md', why: 'Edited since review', at: 1, file: 'README.md', action: { kind: 'file-diff', file: 'README.md' } },
  ] } })
  await opened($)
  expect(await scene($, 'compact · 30 columns', [], 30)).toBeDefined()
  expect(await scene($, 'expanded · 42 columns', ['compact-expand'], 42)).toBeDefined()
})

test('preview: a long needs-you list folds into one counted line, and its page lists it all', async ($, on) => {
  const item = (kind: string, id: string, label: string, why: string, action: { kind: string; id?: string }) =>
    ({ id: `${kind}:${id}`, kind, root: '/code/paper', label, why, at: 1, action })
  const attention = [
    item('job', 'r1', 'queue checks', 'Failed and has not passed since', { kind: 'tests', id: 'r1' }),
    item('job', 'r2', 'drawer tests', 'Failed and has not passed since', { kind: 'tests', id: 'r2' }),
    item('agent', 'pi:p1', 'Worker', 'pi needs you', { kind: 'agent' }),
    item('request', 'src/queue.cpp', 'queue.cpp', 'Changed since you asked Queue refactor', { kind: 'file-diff' }),
    ...Array.from({ length: 52 }, (_, i) => item('commit', String(i).padStart(40, 'c'), `queue: step ${52 - i}`, 'Not reviewed yet', { kind: 'reviews' })),
  ]
  engine(on, { projectWork: { ...WORK, attention,
    integration: { status: 'reload-pending', message: 'Update installed · reload pending',
      sessions: [{ client: 'notebook', status: 'reload-pending', reload: 'In that Claude pane: /exit, then claude --resume abc. The conversation comes back with the new notebook.' }] } } })
  await opened($)
  expect(await scene($, 'front page · 56 need you, folded')).toBeDefined()
  expect(await scene($, 'needs you · the whole list', ['attention-summary'])).toBeDefined()
})

test('preview: the compact notebook when nothing needs you', async ($, on) => {
  engine(on, { compact: true, projectWork: { tests: null, jobs: [], tasks: [], pending: 0, attention: [] } })
  await opened($)
  expect(await scene($, 'compact · all quiet', [], 30)).toBeDefined()
})
