import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'plan-usage',
  component: 'AbovePrompt',
  requestId: 'plan-usage',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 4,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 4 },
    view: {},
  },
} as const

const PANE = {
  plugin: 'plan-usage',
  component: 'Pane',
  requestId: 'plan-usage',
  props: {
    title: 'Usage',
    isFocused: false,
    bodyColumns: 48,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const AT = Date.parse('2026-11-21T12:00:00Z')
const iso = (secondsAhead: number) =>
  new Date(AT + secondsAhead * 1000).toISOString()

// Session: 24% used with 2h 14m of 5h left, so 55.3% elapsed: 31 under, on
// track for 43%. Week: 62% used with 5 of 7 days left, so 28.6% elapsed: 33
// over, and the limit is reached 3d 18h before reset.
const BOTH = {
  at: AT,
  windows: [
    { kind: 'five_hour', percentUsed: 24, resetsAt: iso(8040) },
    { kind: 'seven_day', percentUsed: 62, resetsAt: iso(5 * 86400) },
  ],
  context: { tokens: 84_000, window: 200_000, percent: 42 },
  costUsd: 1.234,
}

const stored = (value: unknown) => () => ({ value: { value, version: 1 } })

test('the row draws both windows and context, outside the terminal', async ($, on) => {
  on('state.get', stored(BOTH))

  // The terminal draws nothing: its statusLine script shows the same figures.
  const terminal = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await terminal.find({ type: 'Text', text: /Session/ })).toBeUndefined()
  await terminal.unmount()

  for (const surface of ['desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })

    expect(await ui.find({ type: 'Text', text: /^Session$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^24%$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Weekly$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^62%$/ })).toBeDefined()
    // The row states the week's pace.
    expect(await ui.find({ type: 'Text', text: /^33% over pace$/ })).toBeDefined()
    expect(await ui.find({ type: 'Svg' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^resets in 2 hr 14 min$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^resets in 5 d 0 hr$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Context 42%/ })).toBeDefined()
    expect(await ui.find({ key: 'details' })).toBeDefined()
    await ui.unmount()
  }
})

test('a missing window and a window past its reset draw a dash', async ($, on) => {
  on(
    'state.get',
    stored({
      at: AT,
      windows: [{ kind: 'five_hour', percentUsed: 80, resetsAt: iso(-60) }],
    }),
  )

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })

  expect(await ui.find({ type: 'Text', text: /Session -/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Weekly -/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /80%/ })).toBeUndefined()
  await ui.unmount()
})

test('the Details button opens the panel', async ($, on) => {
  let opened: string | undefined
  on('state.get', stored(BOTH))
  on('ui.open', (_, e) => {
    opened = e.id

    return { value: { isPlaced: true } }
  })

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  await ui.press({ key: 'details' })
  expect(opened).toBe('plan-usage')
  await ui.unmount()
})

test('the panel breaks each window down, on every surface', async ($, on) => {
  on('state.get', stored(BOTH))

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })

    expect(
      await ui.find({ type: 'Text', text: /^31% under pace$/ }),
    ).toBeDefined()
    expect(
      await ui.find({ type: 'Text', text: /^33% over pace$/ }),
    ).toBeDefined()
    expect(
      await ui.find({ type: 'Text', text: /limit is reached 3 d 18 hr before reset/ }),
    ).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Resets in 2 hr 14 min/ })).toBeDefined()
    expect(
      await ui.find({ type: 'Text', text: /84k \/ 200k/ }),
    ).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /about \$1\.23/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a snapshot the first version stored still draws', async ($, on) => {
  on('state.get', stored({ at: AT, windows: BOTH.windows }))

  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await band.find({ type: 'Text', text: /^24%$/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /Context/ })).toBeUndefined()
  await band.unmount()

  const pane = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await pane.find({ type: 'Text', text: /Resets in 2 hr 14 min/ })).toBeDefined()
  await pane.unmount()
})

test('the widget draws a glance of both limits', async ($, on) => {
  on('state.get', stored(BOTH))

  const ui = await $.ui.mount({
    ...PANE,
    props: { ...PANE.props, placement: 'widget', anchoredEdges: ['bottom', 'left'] },
    surface: 'desktop',
  })

  expect(await ui.find({ type: 'Text', text: /^33% over pace$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^24% used$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^62% used$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Resets in 2 hr 14 min$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Resets in 5 d 0 hr$/ })).toBeDefined()
  await ui.unmount()
})

test('the row steps aside while the widget or panel is on screen', async ($, on) => {
  on('state.get', stored(BOTH))
  on('ui.panes', () => ({
    value: [
      { id: 'plan-usage', title: 'Usage', isShown: true, isFocused: false, isPlaced: true },
    ],
  }))

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /^Weekly$/ })).toBeUndefined()
  await ui.unmount()
})
