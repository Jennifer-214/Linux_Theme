import { expect, test } from 'claude-code/testing'
import { beginArgs, canTrack, exitOf, outputOf, shellQuote, testLabel } from '../hooks/work'

test('tracking records a command as written, keeps secrets out, and reads how the call ended', () => {
  const command = "make test && printf '%s' \"$HOME\""
  expect(canTrack(command)).toBe(true)
  expect(beginArgs(command, '/a folder', 'abc')).toEqual(['begin', '--root', '/a folder', '--session', 'abc', '--pid', 'parent', '--command', command])
  expect(beginArgs(command, '/r', 'abc', ' Run the unit tests ')).toContain('Run the unit tests')
  expect(beginArgs(command, '/r', 'abc', 'two\nlines')).not.toContain('--title')
  expect(shellQuote("a'b")).toBe("'a'\\''b'")
  for (const source of ['fjob make', 'fox-work run -- make', 'curl -H "Authorization: Bearer secret" example.test', 'sudo make install', 'make &'])
    expect(canTrack(source)).toBe(false)
  for (const source of ['cd src && make -j8', 'python3 -B tests/test_work.py', 'timeout 60 ctest --output-on-failure', './build/engine_test',
    'node --experimental-strip-types tests/a.test.mjs', 'npm run build', 'python3 -m pytest -q', 'CC=clang cmake -S . -B build'])
    expect(canTrack(source)).toBe(true)
  for (const source of ["rg -n 'USE_NATIVE' cmake/ tests/ CMakeLists.txt", 'sed -n 1,5p tests/test_work.py', 'grep -n make Makefile',
    'git diff --stat; git diff CMakeLists.txt | head', 'cat build/test_results.txt'])
    expect(canTrack(source)).toBe(false)
  expect(exitOf({ result: { stdout: 'ok', stderr: '', interrupted: false } })).toBe(0)
  expect(exitOf({ isError: true, text: 'Exit code 2\nboom', result: 'Exit code 2\nboom' })).toBe(2)
  expect(exitOf({ isError: true, text: 'something broke' })).toBe(1)
  expect(exitOf({ deny: 'no' })).toBe(130)
  expect(exitOf({ result: { stdout: '', stderr: '', interrupted: true } })).toBe(130)
  expect(outputOf({ result: { stdout: '3 passed', stderr: 'warn' } })).toBe('3 passed\nwarn')
  expect(outputOf({ text: 'Exit code 1\n1 failed', result: 'Exit code 1\n1 failed' })).toBe('Exit code 1\n1 failed')
})

test('a failed command remains visible even when its printed tests passed; unknown totals stay unknown', () => {
  expect(testLabel({ id: 'a', state: 'failed', stale: true, tests: { passed: 128, failed: 2, failures: [] } }))
    .toBe('✓ 128 passed · 2 failed · failed · may be out of date')
  expect(testLabel({ id: 'a', state: 'interrupted', tests: { passed: null, failed: null, failures: [] } }))
    .toBe('last run stopped early')
  expect(testLabel({ id: 'a', state: 'passed', tests: { passed: null, failed: null, failures: [] } })).toBe('✓ last run passed')
})

test('freshness names content changes and never treats an unknown snapshot as a current pass', () => {
  const base = { id: 'a', state: 'passed', stale: true, tests: { passed: 128, failed: 0, failures: [] } }
  expect(testLabel({ ...base, changedFiles: ['a.ts', 'b.ts', 'c.ts'] })).toBe('✓ 128 passed · 0 failed · 3 files changed since')
  expect(testLabel({ ...base, changedFiles: [], changedDuringRun: true })).toContain('code changed while it ran')
  expect(testLabel({ ...base, changedFiles: null })).toContain('may be out of date')
})
