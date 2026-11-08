import { expect, test } from 'claude-code/testing'
import { canTrack, shellQuote, testLabel, wrapped } from '../hooks/work'

test('supervision preserves literal shell source and does not nest wrappers or capture secret commands', () => {
  const command = "make test && printf '%s' \"$HOME\""
  expect(canTrack(command)).toBe(true)
  expect(wrapped(command, '/a folder', 'abc')).toBe(`command fox-work run --root '/a folder' --session 'abc' -- bash -c ${shellQuote(command)}`)
  expect(shellQuote("a'b")).toBe("'a'\\''b'")
  for (const source of ['fjob make', 'fox-work run -- make', 'curl -H "Authorization: Bearer secret" example.test', 'sudo make install', 'make &'])
    expect(canTrack(source)).toBe(false)
})

test('a failed command remains visible even when its printed tests passed; unknown totals stay unknown', () => {
  expect(testLabel({ id: 'a', state: 'failed', stale: true, tests: { passed: 128, failed: 2, failures: [] } }))
    .toBe('✓ 128 passed · 2 failed · failed · stale')
  expect(testLabel({ id: 'a', state: 'interrupted', tests: { passed: null, failed: null, failures: [] } }))
    .toBe('interrupted · no test totals')
})
