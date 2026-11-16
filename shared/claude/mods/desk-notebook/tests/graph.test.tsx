// g: a function's call graph in her editor's pop-out, from the rows that name one (a turn's changed functions, a test
// failure's spot). desk-work editor is a stub here: it keeps the message it got on stdin and answers as desk-work does
// (src/desk-work/main.cpp "editor": the editor's answer, or ok/message with exit 1 refused, 2 no editor answered).
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'
import { NOW, PANE, engine, fakeFs, opened, seen } from './kit'
import type { EditorStub } from './kit'

const FOCUSED = { ...PANE, props: { ...PANE.props, isFocused: true }, surface: 'terminal' } as never
const PUSH = 'turn-symbol:src/queue.cpp:18:Queue::push'
const SYMBOLS = JSON.stringify({ version: 1, files: [{ rel: 'src/queue.cpp', symbols: [
  { name: 'Queue::push', kind: 'function_definition', side: 'after', line: 18 },
  { name: 'legacy_flush', kind: 'function_definition', side: 'before', line: 60 },
  { name: 'lines 70–72', kind: 'hunk', side: 'after', line: 70 }] }] })
const POPOUT = () => ({ exitCode: 0, stdout: '{"shown":"popout"}\n' })
type Ui = Awaited<ReturnType<Engine['ui']['mount']>>

// A turn that changed src/queue.cpp, its functions read, and the notebook on the page that lists them.
async function turnPage($: Engine, on: On, editor: EditorStub): Promise<Ui> {
  const files = fakeFs(on, { '/code/paper/src/queue.cpp': 'old' }, { '/code/paper/src/queue.cpp': NOW })
  engine(on, { runtime: '/run/t', clock: false, files, symbols: SYMBOLS, editor })
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({}) as never)
  await opened($)
  await $.prompt.submit({ text: 'change the queue', wait: false, origin: { kind: 'composer' } })
  await $.tool.call({ tool: 'Edit', file_path: '/code/paper/src/queue.cpp', old_string: 'old', new_string: 'new' })
  await $.classic.Stop({ hook_event_name: 'Stop', stop_hook_active: false } as never)
  const ui = await $.ui.mount(FOCUSED)
  await ui.press({ key: 'receipt-files' })
  expect(await ui.find({ type: 'Text', text: /── this turn/ }), 'the turn page').toBeDefined()
  return ui
}
// j until the row is the selected one (the pane's focus sits on it).
async function select(ui: Ui, key: string) {
  for (let i = 0; i < 40; i++) {
    if ((await ui.findAll({ type: 'Button' })).find(b => b.props.autoFocus === true)?.key === key) return
    await ui.press({ key: 'nav-down' })
  }
  throw new Error(key + ' was never selected')
}
// What the pane says, as one run of words: the leaf texts in order (a row's parts, the strip's lines, the keys page).
async function words(ui: Ui): Promise<string> {
  return (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text).join(' ').replace(/\s+/g, ' ')
}
type Node = { type?: string; key?: string; props?: Record<string, unknown>; children?: unknown[] }
// A line of the key bar as the terminal draws it ("h: back  j: ↓"), found by one of its keys; and how many lines it has.
const flat = (n: unknown): string => {
  if (typeof n === 'string') return n
  if (!n || typeof n !== 'object') return ''
  const node = n as Node
  const key = node.type === 'Button' && node.props?.plain && node.props?.hotkey ? `${String(node.props.hotkey)}: ` : ''
  if (node.type === 'Button' && !node.children?.length) return key + String(node.props?.label ?? '')
  return key + (node.children ?? []).map(flat).join('')
}
async function barLine(ui: Ui, key: string): Promise<string> {
  const box = (await ui.findAll({ type: 'Box' })).find(b => /^keys/.test(b.key ?? '') && b.children.some(c => (c as Node)?.key === key || (c as Node)?.props?.key === key))
  return box ? flat(box) : ''
}
async function barLines(ui: Ui): Promise<number> {
  return (await ui.findAll({ type: 'Box' })).filter(b => /^keys(-[a-z]+)*-\d+$/.test(b.key ?? '')).length
}
// Every key the drawing offers, as { letter: word }; two Buttons on one letter is a clash.
async function letters(ui: Ui): Promise<Record<string, string>> {
  const keys: Record<string, string> = {}
  for (const b of await ui.findAll({ type: 'Button' })) {
    const hotkey = b.props.hotkey
    if (typeof hotkey !== 'string') continue
    expect(keys[hotkey], `two keys on "${hotkey}"`).toBeUndefined()
    keys[hotkey] = String(b.props.label)
  }
  return keys
}

test('g on a changed function shows its call graph in the pop-out: the message desk-work editor gets, and where it went', async ($, on) => {
  const ui = await turnPage($, on, POPOUT)
  await select(ui, PUSH)
  const key = await ui.find({ key: 'nav-graph' })
  expect({ hotkey: key?.props.hotkey, label: key?.props.label }).toEqual({ hotkey: 'g', label: 'graph' })
  seen.argv = []; seen.toasts = []
  await ui.press({ key: 'nav-graph' })
  expect(seen.argv.filter(a => a.startsWith('desk-work editor'))).toEqual(['desk-work editor --root /code/paper --input -'])
  expect(seen.editor).toEqual([{ version: 1, type: 'callgraph', root: '/code/paper', file: '/code/paper/src/queue.cpp', line: 18, name: 'Queue::push' }])
  expect(seen.toasts).toEqual(['call graph of Queue::push in the pop-out'])
  expect(seen.argv.some(a => a.startsWith('desk-work open ')), 'g opens no Neovim tab: Enter does').toBe(false)
  // Enter on the same row is as before: the graph tab in Neovim.
  await ui.press({ key: PUSH })
  expect(seen.argv).toContain('desk-work open --root /code/paper --action callgraph --file src/queue.cpp --index 18')
  await ui.unmount()
})

test("the editor's answer in words: the panel without a pop-out, a refusal's own reason, no editor, no desk-work", async ($, on) => {
  let answer: ReturnType<EditorStub> = POPOUT()
  const ui = await turnPage($, on, () => answer)
  await select(ui, PUSH)
  const told = async (next: ReturnType<EditorStub>) => { answer = next; seen.toasts = []; await ui.press({ key: 'nav-graph' }); return seen.toasts }
  expect(await told({ exitCode: 0, stdout: '{"shown":"panel"}\n' })).toEqual(["call graph of Queue::push in the editor's panel · no pop-out is open"])
  // A refusal comes back as the editor's answer with ok and message beside it, exit 1.
  expect(await told({ exitCode: 1, stdout: '{"refused":"typing in this editor","ok":false,"message":"typing in this editor"}\n' }))
    .toEqual(['call graph not shown: typing in this editor'])
  expect(await told({ exitCode: 1, stdout: '{"refused":"a review is open","ok":false,"message":"a review is open"}\n' }))
    .toEqual(['call graph not shown: a review is open'])
  expect(await told({ exitCode: 2, stdout: '{"ok":false,"message":"No Neovim on this checkout is listening"}\n' }))
    .toEqual(['call graph not shown: no editor open for this project'])
  expect(await told({ exitCode: 2, stdout: '{"ok":false,"message":"The editor did not answer within 1000 ms"}\n' }))
    .toEqual(['call graph not shown: the editor did not answer within 1000 ms'])
  expect(await told('missing')).toEqual(['call graph not shown: requires desk-work'])
  // A desk-work from before the bridge knows no editor command (main() names it on stderr, exit 2).
  expect(await told({ exitCode: 2, stdout: '', stderr: 'desk-work editor: missing or invalid arguments (desk-work help lists them)\n' }))
    .toEqual(['call graph not shown: requires a newer desk-work, one with desk-work editor'])
  expect(seen.editor).toHaveLength(7)
  await ui.unmount()
})

test('only a row that names a function offers g: not the review row, a removed function, a hunk, or a page of files', async ($, on) => {
  const ui = await turnPage($, on, POPOUT)
  expect(await ui.find({ key: 'turn-symbol:src/queue.cpp:60:legacy_flush' }), 'a removed function is listed, not a row').toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /lines 70–72/ }), 'a hunk no parser placed is listed').toBeDefined()
  expect((await ui.findAll({ type: 'Button' })).some(b => /lines 70/.test(String(b.props.label))), '… as text, not a row').toBe(false)
  await select(ui, 'turn-review')
  expect(await ui.find({ key: 'nav-graph' }), "the turn's review row names no function").toBeUndefined()
  await select(ui, PUSH)
  expect(await ui.find({ key: 'nav-graph' }), 'the changed function does').toBeDefined()
  await select(ui, 'turn-back')
  expect(await ui.find({ key: 'nav-graph' }), 'back does not').toBeUndefined()
  await ui.press({ key: 'turn-back' })
  for (let i = 0; i < 8; i++) {
    await ui.press({ key: 'nav-down' })
    expect(await ui.find({ key: 'nav-graph' }), 'no row of the front page names a function').toBeUndefined()
  }
  await ui.press({ key: 'page-files' })
  for (let i = 0; i < 6; i++) {
    await ui.press({ key: 'nav-down' })
    expect(await ui.find({ key: 'nav-graph' }), 'nor does a file').toBeUndefined()
  }
  expect(seen.editor, 'nothing was sent').toEqual([])
  await ui.unmount()
})

test("a test failure offers g at its spot: the file the run reported, its line, and no name of the notebook's", async ($, on) => {
  const run = 'a'.repeat(32)
  engine(on, { editor: POPOUT, projectWork: { jobs: [], tasks: [], tests: { id: run, state: 'failed', tests: { passed: 3, failed: 1, failures: [
    { filename: '/code/paper/tests/test_queue.cpp', lnum: 42, text: 'expected 3, got 2.' }] } } } })
  await opened($)
  const ui = await $.ui.mount(FOCUSED)
  await ui.press({ key: 'nav-more' })
  await select(ui, 'work-tests')
  expect(await ui.find({ key: 'nav-graph' }), 'the run names no function').toBeUndefined()
  await select(ui, 'work-failure-0')
  seen.toasts = []
  await ui.press({ key: 'nav-graph' })
  expect(seen.editor).toEqual([{ version: 1, type: 'callgraph', root: '/code/paper', file: '/code/paper/tests/test_queue.cpp', line: 42 }])
  expect(seen.toasts).toEqual(['call graph of test_queue.cpp:42 in the pop-out'])
  expect(await words(ui)).toContain("test_queue.cpp:42 · expected 3, got 2. Enter opens it in Neovim's list of failures; g shows the call graph of the function around it in the pop-out.")
  seen.argv = []
  await ui.press({ key: 'work-failure-0' })
  expect(seen.argv, 'Enter is as before: the failure in Neovim').toContain(`desk-work open --root /code/paper --action tests --id ${run} --index 1`)
  await ui.unmount()
})

test('g is one key with one meaning: no other key on any page shares its letter, and none moves it', async ($, on) => {
  const ui = await turnPage($, on, POPOUT)
  const seenLetters: Record<string, string> = {}
  const look = async (where: string) => {
    for (const [letter, word] of Object.entries(await letters(ui))) {
      expect(seenLetters[letter] ?? word, `"${letter}" is "${seenLetters[letter]}" elsewhere and "${word}" on ${where}`).toBe(word)
      seenLetters[letter] = word
    }
  }
  await select(ui, PUSH)
  await look('a changed function')
  await ui.press({ key: 'turn-back' })
  await look('the front page')
  await ui.press({ key: 'page-files' })
  await look('the files page')
  await ui.press({ key: 'nav-back' })
  await ui.press({ key: 'nav-more' })
  await look('the project page')
  await ui.press({ key: 'page-help' })
  await look('the keys page')
  expect(seenLetters.g).toBe('graph')
  await ui.unmount()
})

test('g sits beside open on the moving keys, and the bar keeps its height as the cursor moves on and off a function', async ($, on) => {
  const ui = await turnPage($, on, POPOUT)
  await select(ui, 'turn-review')
  const without = await barLines(ui)
  await select(ui, PUSH)
  const line = await barLine(ui, 'nav-graph')
  expect(line).toBe('h: back  j: ↓  k: ↑  l: open  g: graph')
  expect(line.length, 'it fits the pane: the terminal never wraps the bar').toBeLessThanOrEqual(40)
  expect(await barLines(ui), 'as many bar lines with g as without').toBe(without)
  await ui.unmount()
})

test('the strip under a changed function says what g does, and the keys page lists it', async ($, on) => {
  const ui = await turnPage($, on, POPOUT)
  await select(ui, PUSH)
  expect(await words(ui)).toContain("Enter opens Neovim with its call graph: what calls it above, what it calls below. g shows it in the pop-out on the other screen (the editor's panel without one).")
  await ui.press({ key: 'turn-back' })
  await ui.press({ key: 'nav-more' })
  await ui.press({ key: 'page-help' })
  expect(await words(ui)).toContain("e on files: open the selected file to edit g on a changed function or a test failure: its call graph in the editor's pop-out, on the other screen")
  await ui.unmount()
})
