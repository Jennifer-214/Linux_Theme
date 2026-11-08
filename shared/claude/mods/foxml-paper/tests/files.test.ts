import { expect, test } from 'claude-code/testing'
import { attributeFiles, fileColumns, fileCounts, gitFiles, shortPath } from '../hooks/notebook'

test('Git paths retain tabs, Unicode, renames, new files and binary counts', () => {
  const files = gitFiles('12\t3\ta.ts\u00001\t0\t\u0000old.ts\u0000新\tname.ts\u0000-\t-\timage.png\u0000',
    ' M a.ts\u0000R  新\tname.ts\u0000old.ts\u0000?? new file.ts\u0000')
  expect(files.map(f => f.path).sort()).toEqual(['a.ts', 'image.png', 'new file.ts', '新\tname.ts'].sort())
  expect(files.find(f => f.path === 'image.png')?.added).toBe(null)
  expect(files.find(f => f.path === 'new file.ts')?.status).toBe('new')
})

test('session attribution includes old session edits and marks shared files without assigning unknown authors', () => {
  const files = gitFiles('1\t0\ta.ts\u00002\t1\tb.ts\u00003\t0\tc.ts\u0000', '')
  const own = { title: 'me', root: '/r', edits: [], all: [{ path: '/r/a.ts', at: 1 }] }
  const result = attributeFiles(files, '/r', own, [
    { sid: 'peer', live: true, ledger: { title: 'docs', root: '/r', edits: [{ path: '/r/a.ts', at: 2 }], pane: '%4' } },
    { sid: 'gone', live: false, ledger: { title: 'ended', root: '/r', edits: [{ path: '/r/c.ts', at: 2 }] } },
  ])
  expect(result.filter(f => f.own).map(f => f.path)).toEqual(['a.ts'])
  expect(result[0]?.owners).toEqual([{ sid: 'peer', name: 'docs', pane: '%4' }])
  expect(result[2]?.owners).toEqual([])
})

test('file counts align while shortened paths preserve filenames', () => {
  const files = [{ path: 'a', added: 379, removed: 70 }, { path: 'b', added: 2, removed: 0 }]
  expect(fileCounts(files[1]!, fileColumns(files))).toEqual(['  +2', ' −0'])
  expect(shortPath('a/very/long/path/notes.ts', 12)).toBe('…th/notes.ts')
})
