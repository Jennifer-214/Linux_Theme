import { expect, test } from 'claude-code/testing'

import { addBefore, addEdit, addName, agoText, neighbours, noteText, overlapFor, parseLedger, parseNames, parseNote, trailerUrl, WINDOW_MS, withPlan, editedSince } from '../hooks/ledger'
import type { Other } from '../hooks/ledger'

const NOW = 1_800_000_000_000
const ledger = (title: string | null, root: string, edits: [string, number][]) =>
  ({ title, root, edits: edits.map(([path, ago]) => ({ path, at: NOW - ago })) })

test('the live session that last edited a file is the one to coordinate with', async () => {
  const others: Other[] = [
    { sid: 'a', live: true, ledger: ledger('Ledger tidy', '/code/t', [['/code/t/main.cpp', 4 * 60000]]) },
    { sid: 'b', live: true, ledger: ledger(null, '/code/t', [['/code/t/main.cpp', 60000]]) },
  ]
  expect(overlapFor('/code/t/main.cpp', NOW, 'me', others)).toEqual({ path: '/code/t/main.cpp', title: 'a session in t', ago: '1 minute ago' })
  expect(overlapFor('/code/t/other.cpp', NOW, 'me', others)).toBe(null)
  const paned: Other = { sid: 'c', live: true, ledger: { ...ledger('Pane', '/code/t', [['/code/t/x', 1000]]), pane: '%2' } }
  expect(overlapFor('/code/t/x', NOW, 'me', [paned])?.pane).toBe('%2')
  expect(addEdit(null, '/a', NOW, null, '/', '%7').pane).toBe('%7')
  expect(addEdit(addEdit(null, '/a', NOW, null, '/', '%7'), '/b', NOW, null, '/').pane).toBe('%7')
  expect(parseLedger('{"pane":"%3;rm","edits":[]}')?.pane).toBe(undefined)
})

test('old edits, ended sessions and this session never count', async () => {
  const old: Other = { sid: 'a', live: true, ledger: ledger('Old', '/r', [['/r/f', WINDOW_MS + 1000]]) }
  const gone: Other = { sid: 'b', live: false, ledger: ledger('Gone', '/r', [['/r/f', 1000]]) }
  const self: Other = { sid: 'me', live: true, ledger: ledger('Me', '/r', [['/r/f', 1000]]) }
  expect(overlapFor('/r/f', NOW, 'me', [old, gone, self])).toBe(null)
})

test("this session's ledger keeps one entry per file, newest first, and forgets after an hour", async () => {
  let mine = addEdit(null, '/r/a', NOW - 2 * 3600000, 'Me', '/r')
  mine = addEdit(mine, '/r/b', NOW - 1000, null, '/r')
  mine = addEdit(mine, '/r/b', NOW, null, '/r')
  expect(mine.edits.map(e => e.path)).toEqual(['/r/b'])
  expect(mine.title).toBe('Me')
  for (let i = 0; i < 80; i++) mine = addEdit(mine, `/r/${i}`, NOW + i, null, '/r')
  expect(mine.edits.length).toBe(50)
})

test('neighbours are the other live sessions in the same repo, and a bad ledger is ignored', async () => {
  const others: Other[] = [
    { sid: 'a', live: true, ledger: ledger('Same repo', '/r', [['/r/x', 1000], ['/r/y', 2000]]) },
    { sid: 'b', live: true, ledger: ledger('Elsewhere', '/q', [['/q/x', 1000]]) },
  ]
  expect(neighbours('/r', NOW, 'me', others)).toEqual([{ sid: 'a', title: 'Same repo', files: 2 }])
  expect(parseLedger('not json')).toBe(null)
  expect(parseLedger('{"edits":[{"path":1}]}')?.edits).toEqual([])
  expect(agoText(30000)).toBe('just now')
})

test('commit names: one per session url, newest title, a broken line skipped', async () => {
  expect(trailerUrl('fix: x\n\nClaude-Session: https://claude.ai/code/session_A\n')).toBe('https://claude.ai/code/session_A')
  expect(trailerUrl('fix: x\nClaude-Session: not-a-url')).toBe(null)
  let names = parseNames('{"url":"u1","title":"Old","at":1}\nnot json\n')
  names = addName(names, 'u1', 'New', 2)
  names = addName(names, 'u2', 'Other', 3)
  expect(names).toEqual([{ url: 'u1', title: 'New', at: 2 }, { url: 'u2', title: 'Other', at: 3 }])
})

test('notes from nvim are checked before Claude reads them', async () => {
  expect(parseNote('{"text":"  hi  "}')).toEqual({ from: 'nvim', text: 'hi' })
  expect(parseNote('{"text":""}')).toBe(null)
  expect(parseNote(JSON.stringify({ text: 'x'.repeat(2001) }))).toBe(null)
  expect(parseNote('{"text":"hi","lines":"1;rm"}')).toEqual({ from: 'nvim', text: 'hi' })
  expect(noteText({ from: 'nvim', text: 'see', code: 'a ``` b' })).toBe('see\n~~~~\na ``` b\n~~~~')
})

test('the session-long list keeps first edits; before-copies are numbered', async () => {
  let mine = addEdit(null, '/r/a', NOW - 3 * 3600000, null, '/r')
  mine = addEdit(mine, '/r/b', NOW, null, '/r')
  mine = addEdit(mine, '/r/a', NOW + 1, null, '/r')
  expect(mine.all?.map(e => e.path)).toEqual(['/r/a', '/r/b'])
  const first = addBefore(mine, '/r/a', '/r')
  expect(first.copy).toBe('1.txt')
  expect(addBefore(first.ledger, '/r/b', '/r').copy).toBe('2.txt')
  expect(parseLedger(JSON.stringify({ edits: [], before: { '/r/a': '../../x' } }))?.before).toBe(undefined)
})

test('the plan a session read stays in its ledger through later edits', async () => {
  let mine = withPlan(null, '/w/plans/p.md', NOW, '/r')
  mine = addEdit(mine, '/r/a', NOW + 1, null, '/r')
  const back = parseLedger(JSON.stringify(mine))
  expect([back?.plan, back?.plan_at]).toEqual(['/w/plans/p.md', NOW])
})

test('a file edited again is found by its latest edit, not its first', () => {
  let ledger = addEdit(null, '/r/a.ts', 1000, null, '/r')
  ledger = addEdit(ledger, '/r/b.ts', 2000, null, '/r')
  ledger = addEdit(ledger, '/r/a.ts', 9000, null, '/r')
  expect(editedSince(ledger, 5000)).toEqual(['/r/a.ts'])
  expect(editedSince(ledger, 0).sort()).toEqual(['/r/a.ts', '/r/b.ts'])
  expect(editedSince(null, 0)).toEqual([])
})
