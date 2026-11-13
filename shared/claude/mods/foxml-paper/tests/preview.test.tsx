// The notebook drawn with sample data, for looking at: tests/notebook_preview.py prints these scenes in colour.
// Each scene goes through the real drawing code; nothing here is a mock-up.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { NOW, PANE, engine, fakeFs, opened } from './kit'

const say = (text: string) => (globalThis as { console?: { log: (line: string) => void } }).console?.log(text)
const WIDE = { ...PANE, props: { ...PANE.props, isFocused: true, bodyColumns: 44 }, surface: 'terminal' } as never
const scene = async ($: Engine, name: string, press: string[] = []) => {
  const ui = await $.ui.mount(WIDE)
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
