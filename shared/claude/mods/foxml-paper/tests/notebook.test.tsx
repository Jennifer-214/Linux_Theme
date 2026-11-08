import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

const PANE = {
  plugin: 'foxml-paper',
  component: 'Pane',
  requestId: 'paper-notebook',
  props: { title: 'notebook', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

const BAND = {
  plugin: 'foxml-paper',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  props: { hasSurvey: false, isWorking: true, maxRows: 4, bodyColumns: 80, scroll: { offset: 0, bodyRows: 4 }, view: {} },
} as const

const done = (stdout: string) => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

const PEERS = JSON.stringify([
  { id: 'abc', name: 'this one', project: 'paper', state: 'working', busy: true, pane: '%1' },
  { id: 'p1', name: 'Ledger tidy', project: 'trader', state: 'needs you', busy: false, pane: '%4' },
  { id: 'p2', name: 'docs', project: 'docs', state: 'waiting', busy: false, pane: '' },
])
const seen = { argv: [] as string[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[] }

// Nothing sits beneath the plugin in a test: these stand for the engine and the machine.
function engine(on: On) {
  seen.argv = []; seen.sent = []; seen.toasts = []
  on('session.send', (_, e) => { seen.sent.push({ to: e.to, text: e.text }); return { isDelivered: true } })
  on('ui.focus', () => ({}))
  on('ui.toast', (_, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('command.register', () => ({ value: { command: 'notebook' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/code/paper' }))
  on('session.repo', () => ({ value: { root: '/code/paper', remote: null, internal: false, name: null } }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.turns', () => ({ value: 3 }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000, percent: 64 }, rateLimits: [] } }))
  on('process.run', (_, e) => {
    const argv = e.argv.join(' ')
    seen.argv.push(argv)
    if (argv === 'fox-drawer claude-peers') return { value: done(PEERS) }
    if (argv.startsWith('fox-drawer run claude-jump')) return { value: done('{"ok":true}') }
    if (argv.includes('status') && !argv.includes('--no-optional-locks')) return { value: { ...done(''), exitCode: 9 } }
    if (argv.includes('status')) return { value: done('## main...origin/main\n M a.txt\n') }
    if (argv.includes('numstat')) return { value: done('12\t3\tshared/a very long folder/notes.txt\n1\t0\tREADME.md\n') }
    return { value: { ...done(''), exitCode: 1 } }
  })
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('clock.every', () => ({ value: undefined }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.component === 'Spinner' ? e.props.word : 'engine'}</Text>
  })
}

async function opened($: Engine) {
  await $.session.start({ cwd: '/code/paper', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'notebook', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })
}

test('the notebook shows the hearts, the session name and the pages touched', async ($, on) => {
  engine(on)
  await opened($)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /♥♥♥♡♡/ }))?.text).toBe('♥♥♥♡♡ 64%')
    expect((await ui.find({ type: 'Text', text: /pages touched/ }))?.text).toBe('2 pages touched')
    expect((await ui.find({ type: 'Text', text: /README/ }))?.text).toBe('+1 −0 README.md')
    expect((await ui.find({ type: 'Text', text: /⎇/ }))?.text).toBe('⎇ main')
    await ui.unmount()
  }
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
  expect(['Knitting', 'Pressing flowers', 'Baking', 'Stitching', 'Doodling', 'Steeping tea', 'Folding paper',
    'Tending the garden', 'Sketching', 'Tidying up', 'Writing a little note', 'Threading a needle']).toContain(word)
  await terminal.unmount()
  const desktop = await $.ui.mount({ ...spinner, surface: 'desktop' })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('Sauteing')
  await desktop.unmount()
})

test('other claudes are listed with go and note, and a note reaches the session it was written to', async ($, on) => {
  engine(on)
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /other claudes/ }))?.text).toBe('other claudes')
  expect(await ui.find({ type: 'Text', text: /this one/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Ledger tidy/ }))?.text).toBe('♥ Ledger tidy · trader')
  expect(await ui.find({ key: 'go-p2' })).toBeUndefined()

  await ui.press({ key: 'go-p1' })
  expect(seen.argv).toContain('fox-drawer run claude-jump %4')

  await ui.press({ key: 'note-p2' })
  expect(await ui.find({ key: 'note-p2' })).toBeUndefined()
  await ui.input({ key: 'peer-note', text: '  the tests are green, go ahead  ', kind: 'submit' })
  expect(seen.sent).toEqual([{ to: 'p2', text: 'the tests are green, go ahead' }])
  expect(seen.toasts).toContain('note left for docs ♡')
  expect(await ui.find({ key: 'peer-note' })).toBeUndefined()

  await ui.press({ key: 'note-p1' })
  await ui.press({ key: 'peer-cancel' })
  expect(await ui.find({ key: 'peer-note' })).toBeUndefined()
  expect(seen.sent).toHaveLength(1)
  await ui.unmount()
})
