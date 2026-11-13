import { expect, test } from 'claude-code/testing'
import { ago, beginArgs, branchLabel, canTrack, ciLabel, exitOf, greenAgain, jobPace, outputOf, parseBranchLine, pendingLine, planProgress, reviewStates, reviewSummary, ruler, shellQuote, stepLabel, testLabel, turnLabel, unreviewed, withoutHeredocs, workName, filterFiles, wrapWords } from '../hooks/work'

test('tracking records a command as written, keeps secrets out, and reads how the call ended', () => {
  const command = "make test && printf '%s' \"$HOME\""
  expect(canTrack(command)).toBe(true)
  expect(beginArgs(command, '/a folder', 'abc')).toEqual(['begin', '--root', '/a folder', '--session', 'abc', '--pid', 'parent', '--safe', 'yes', '--command', command])
  expect(beginArgs(command, '/r', 'abc', ' Run the unit tests ')).toContain('Run the unit tests')
  expect(beginArgs(command, '/r', 'abc', 'two\nlines')).not.toContain('--title')
  expect(shellQuote("a'b")).toBe("'a'\\''b'")
  for (const source of ['fjob make', 'desk-work run -- make', 'curl -H "Authorization: Bearer secret" example.test', 'sudo make install', 'make &'])
    expect(canTrack(source)).toBe(false)
  for (const source of ['cd src && make -j8', 'python3 -B tests/test_work.py', 'timeout 60 ctest --output-on-failure', './build/engine_test',
    'node --experimental-strip-types tests/a.test.mjs', 'npm run build', 'python3 -m pytest -q', 'CC=clang cmake -S . -B build'])
    expect(canTrack(source)).toBe(true)
  for (const source of ["rg -n 'USE_NATIVE' cmake/ tests/ CMakeLists.txt", 'sed -n 1,5p tests/test_work.py', 'grep -n make Makefile',
    'git diff --stat; git diff CMakeLists.txt | head', 'cat build/test_results.txt',
    // An edit script that only names a test file runs no test: not the line that assigns it, not a heredoc's body.
    "python3 -I - <<'EOF'\np='tests/test_x.py'; t=open(p).read()\nEOF", "cat > tests/test_a.py <<EOF\nimport unittest\nEOF",
    "p='tests/test_x.py' python3 -c 'print(1)'"])
    expect(canTrack(source)).toBe(false)
  expect(canTrack("python3 -B tests/test_x.py <<'EOF'\nanswer\nEOF")).toBe(true)
  expect(withoutHeredocs("a <<'EOF'\nbody tests/test_x.py\nEOF\nmake")).toBe("a <<EOF\nmake")
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
    .toBe('2 failed · 128 passed · may be out of date')
  expect(testLabel({ id: 'a', state: 'failed', tests: { passed: 128, failed: 0, failures: [] } })).toBe('tests failed')
  expect(testLabel({ id: 'a', state: 'interrupted', tests: { passed: null, failed: null, failures: [] } }))
    .toBe('tests stopped early')
  expect(testLabel({ id: 'a', state: 'passed', tests: { passed: null, failed: null, failures: [] } })).toBe('✓ tests passed')
  const ran = { id: 'a', state: 'passed', ended: 1000, tests: { passed: 12, failed: 0, failures: [] } }
  expect(testLabel(ran, 1000 + 7300)).toBe('✓ 12 passed 2h ago')
  expect(testLabel({ ...ran, changedDuringRun: true }, 1030)).toBe('✓ 12 passed just now · code changed while it ran')
  expect(testLabel({ ...ran, state: 'running' }, 5000)).toBe('◷ tests running')
  expect([ago(59), ago(61), ago(3 * 3600), ago(30 * 3600), ago(5 * 86400)]).toEqual(['just now', '1m ago', '3h ago', 'yesterday', '5 days ago'])
})

test('freshness names content changes and never treats an unknown snapshot as a current pass', () => {
  const base = { id: 'a', state: 'passed', stale: true, tests: { passed: 128, failed: 0, failures: [] } }
  expect(testLabel({ ...base, changedFiles: ['a.ts', 'b.ts', 'c.ts'] })).toBe('✓ 128 passed · 3 files changed since')
  expect(testLabel({ ...base, changedFiles: [], changedDuringRun: true })).toContain('code changed while it ran')
  expect(testLabel({ ...base, changedFiles: null })).toContain('may be out of date')
})

test('plan progress counts checkboxes outside code fences and names the step being worked on', () => {
  const plan = '# Plan\n- [x] one\n  - [X] two\n* [ ] three\n1. [ ] four\n```\n- [x] an example\n```\n- [] not a box\n'
  expect(planProgress(plan)).toEqual({ done: 2, total: 4, next: 'three' })
  expect(planProgress('- [x] `a`\n- [x] b\n')).toEqual({ done: 2, total: 2 })
  expect(planProgress('# Plan\n- a list\n')).toEqual({ done: 0, total: 0 })
  expect(stepLabel({ done: 3, total: 9 })).toBe('step 4 of 9')
  expect(stepLabel({ done: 9, total: 9 })).toBe('all 9 steps done ✿')
  expect(ruler(0.5, 10).join('')).toBe('━━━━━┄┄┄┄┄')
  expect(ruler(0.5, 10, true).join('')).toBe('━━━━━✎┄┄┄┄')
  expect(ruler(1, 10, true).join('')).toBe('━━━━━━━━━✎')
  expect(ruler(0, 10, true).join('').length).toBe(10)
})

test('a running job is measured only against a recorded pass, and never past it', () => {
  const job = { id: 'a', command: 'make', state: 'running', elapsed: 60, activity: 0, session: 's' }
  expect(jobPace(job)).toBeNull()
  expect(jobPace({ ...job, estimate: 150 })).toEqual({ fraction: 0.4, left: 'about 2m left' })
  expect(jobPace({ ...job, estimate: 90 })).toEqual({ fraction: 60 / 90, left: 'under a minute left' })
  expect(jobPace({ ...job, estimate: 60 })).toEqual({ late: true })
  expect(jobPace({ ...job, estimate: 0 })).toBeNull()
})

test('green again only after two or more failures in a row of a test run', () => {
  const said = (v: object) => JSON.stringify({ ok: true, state: 'passed', testRun: true, failedBefore: 2, ...v })
  expect(greenAgain(said({}))).toBe(true)
  expect(greenAgain(said({ failedBefore: 1 }))).toBe(false)
  expect(greenAgain(said({ testRun: false }))).toBe(false)
  expect(greenAgain(said({ state: 'failed' }))).toBe(false)
  expect(greenAgain(said({ failedBefore: undefined }))).toBe(false)
  expect(greenAgain(null)).toBe(false)
  expect(greenAgain('{"ok":true}')).toBe(false)
  expect(greenAgain('not json')).toBe(false)
})

test('the branch line says what is pushed, and CI says what the pushed commit got', () => {
  expect(parseBranchLine('## polish/x...origin/polish/x [ahead 2, behind 1]')).toEqual({ branch: 'polish/x', upstream: 'origin/polish/x', ahead: 2, behind: 1 })
  expect(parseBranchLine('## main...origin/main')).toEqual({ branch: 'main', upstream: 'origin/main', ahead: 0, behind: 0 })
  expect(parseBranchLine('## topic')).toEqual({ branch: 'topic', upstream: null, ahead: 0, behind: 0 })
  expect(parseBranchLine('## gone...origin/gone [gone]').upstream).toBe(null)
  expect(parseBranchLine('## No commits yet on main').branch).toBe('main')
  expect(branchLabel({ upstream: 'origin/x', ahead: 2, behind: 0, trees: 2 }, 'polish/x')).toBe('polish/x · 2 unpushed · 2 worktrees')
  expect(branchLabel({ upstream: 'origin/x', ahead: 0, behind: 3, trees: 1 }, 'x')).toBe('x · 3 to pull')
  expect(branchLabel({ upstream: 'origin/x', ahead: 0, behind: 0, trees: 1 }, 'x')).toBe('x · pushed')
  expect(branchLabel({ upstream: null, ahead: 0, behind: 0, trees: 1 }, 'topic')).toBe('topic · not pushed yet')
  expect(branchLabel(null, 'x')).toBe('x')

  const done = (workflowName: string, conclusion = 'success') => ({ workflowName, status: 'completed', conclusion, url: `https://github.com/o/r/actions/runs/${workflowName}` })
  expect(ciLabel([])).toBe(null)
  expect(ciLabel([done('ci'), done('shellcheck')])).toEqual({ label: '✓ CI passed', state: 'passed', url: 'https://github.com/o/r/actions/runs/ci' })
  expect(ciLabel([done('ci'), { workflowName: 'cpp-build', status: 'in_progress', conclusion: '' }])?.label).toBe('◷ CI running · 1 of 2 done')
  const failed = ciLabel([done('ci'), done('keybinds-sync', 'failure'), { workflowName: 'cpp-build', status: 'queued', conclusion: '' }])
  expect(failed?.label).toBe('✗ CI · keybinds-sync failed · still running')
  expect(failed?.url).toBe('https://github.com/o/r/actions/runs/keybinds-sync')
  expect(ciLabel([done('a', 'failure'), done('b', 'timed_out')])?.label).toBe('✗ CI · a failed and 1 more')
  expect(ciLabel([done('a'), done('b', 'cancelled')])?.label).toBe('CI cancelled')
})

test('the turn under way reads as how long and its latest step', () => {
  expect(turnLabel(null, 1)).toBe(null)
  expect(turnLabel({ started: 0, step: 'x' }, 1)).toBe(null)
  expect(turnLabel({ started: 1000, step: '' }, 1000 + 30000)).toBe('◷ working')
  expect(turnLabel({ started: 1000, step: 'Run the drawer tests' }, 1000 + 14 * 60000)).toBe('◷ working 14m · Run the drawer tests')
  expect(turnLabel({ started: 0 + 1, step: 'x', seen: 1 + 74 * 60000 }, 1 + 75 * 60000)).toBe('◷ working 1h 15m · x')
  expect(turnLabel({ started: 1, step: 'x' }, 1 + 75 * 60000)).toBe(null)                      // went quiet: interrupted
  expect(turnLabel({ started: 1, step: 'x', seen: 1 + 50 * 60000 }, 1 + 75 * 60000)).toBe(null)
})

test('review marks: edited-after-review wins, a commit review does not mark the working file, and counts are plain', () => {
  const mark = (state: 'checked' | 'changed') => ({ state, at: 1 })
  const one = (files: Record<string, { state: 'checked' | 'changed'; at: number }>) => ({ files, checked: 0, changed: 0, total: 0, completed: false, at: 1 })
  const states = reviewStates({
    working: one({ 'queue.hpp': mark('checked'), 'worker.cpp': mark('checked') }),
    'sess-1': one({ 'worker.cpp': mark('changed') }),
    ['a'.repeat(40)]: one({ 'old.cpp': mark('checked') }),
  })
  expect([...states]).toEqual([['queue.hpp', 'checked'], ['worker.cpp', 'changed']])
  expect(reviewSummary(['queue.hpp', 'worker.cpp', 'queue_test.cpp', 'new.cpp'], states)).toBe('1 of 4 reviewed · 1 changed since')
  expect(reviewSummary(['queue.hpp'], states)).toBe('1 of 1 reviewed')
  expect(reviewSummary(['untouched.cpp'], states)).toBe('')
  expect(reviewSummary([], states)).toBe('')
  expect([...reviewStates(null)]).toEqual([])
})

test('the one review line counts what waits, and says nothing when nothing does', () => {
  const states = new Map<string, 'checked' | 'changed'>([['a.ts', 'checked'], ['b.ts', 'changed']])
  expect(pendingLine(3, ['a.ts', 'b.ts', 'c.ts'], states)).toBe('3 changes to review · 1 file of yours unread · 1 changed since you looked')
  expect(pendingLine(1, [], states)).toBe('1 change to review')
  expect(pendingLine(0, ['a.ts'], states)).toBe('')
  expect(unreviewed(['a.ts', 'b.ts', 'c.ts'], states)).toBe(2)
  expect(unreviewed(['a.ts'], states)).toBe(0)
})

test('one name for a piece of work: the plan, else the session title, else the project', () => {
  expect(workName('Plan: Queue refactor (2026-11-12) — notes', 'tidy things', 'Linux_Theme')).toBe('Queue refactor')
  expect(workName('2026-11-10: Drop fox', null, 'Linux_Theme')).toBe('Drop fox')
  expect(workName(null, 'Tidy the drawer', 'Linux_Theme')).toBe('Tidy the drawer')
  expect(workName('', '  ', 'Linux_Theme')).toBe('Linux_Theme')
  expect(workName('x'.repeat(80), null, 'p').length).toBe(60)
})

test('file filters: needs review, changed since review and a part of the name combine', () => {
  const files = [{ path: 'src/a.ts' }, { path: 'src/b.ts' }, { path: 'docs/Guide.md' }]
  const states = new Map<string, 'checked' | 'changed'>([['src/a.ts', 'checked'], ['src/b.ts', 'changed']])
  expect(filterFiles(files, states, 'all', '').length).toBe(3)
  expect(filterFiles(files, states, 'unreviewed', '').map(f => f.path)).toEqual(['src/b.ts', 'docs/Guide.md'])
  expect(filterFiles(files, states, 'changed', undefined).map(f => f.path)).toEqual(['src/b.ts'])
  expect(filterFiles(files, states, 'unreviewed', 'GUIDE').map(f => f.path)).toEqual(['docs/Guide.md'])
})

test('detail text wraps without losing long paths or splitting Unicode characters', () => {
  expect(wrapWords('rename the head pointer before the drain', 16)).toEqual(['rename the head', 'pointer before', 'the drain'])
  expect(wrapWords('x'.repeat(30), 10)).toEqual(['x'.repeat(10), 'x'.repeat(10), 'x'.repeat(10)])
  expect(wrapWords('a very/long/path/with/no/spaces.txt', 10).join('')).toBe('avery/long/path/with/no/spaces.txt')
  expect(wrapWords('🌸🌸🌸', 1)).toEqual(['🌸', '🌸', '🌸'])
  expect(wrapWords('  ', 10)).toEqual([])
})
