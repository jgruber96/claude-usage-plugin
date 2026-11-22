// Plan usage for the desktop app, where the terminal's statusLine script does
// not run. Two parts, drawn from one snapshot:
//
//   - a row above the prompt: session and weekly bars, the week's pace, context
//   - a "Usage" panel (the row's Details button, or /plan-usage): context and
//     every limit, each with a bar, a pace line above it and its reset time
//
// The look follows the usage popover idea of a thick usage bar under a thin
// pace line. The line is grey as far as usage and time agree, then green where
// time is ahead of usage, orange where usage is ahead of time, and red when
// that happens close to the limit.
//
// The figures are the ones Claude Code hands the status line. No network, no
// credentials, no token counting.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Context, Snapshot, Window } from '../types'

const snapshot = atom({ plugin: 'plan-usage', key: 'snapshot' } as const, null)

const PANE = 'plan-usage'
const PANE_TITLE = 'Usage'
const PACE_SLACK = 3 // points either side that count as "on pace"
const NEAR_LIMIT = 80 // percent used from which the limit counts as close

// An Svg is drawn as an image, so it cannot follow the theme: these are fixed
// colours picked to read on both a dark and a light background.
const BLUE = '#4a8fe8'
const YELLOW = '#e0b050'
const GREEN = '#5fb37a'
const ORANGE = '#e09a3c'
const RED = '#d9534f'
const GREY = '#9a9a9a'
const TRACK = 'rgba(128,128,128,0.28)'

const KNOWN: Record<string, { label: string; short: string; seconds: number }> = {
  five_hour: { label: 'Session limit', short: 'Session', seconds: 5 * 3600 },
  seven_day: { label: 'Weekly', short: 'Weekly', seconds: 7 * 86400 },
}
const IN_ROW = ['five_hour', 'seven_day']

type Status = 'under' | 'on' | 'over'

type Reading = {
  kind: string
  label: string
  short: string
  percent?: number // absent: nothing to show for this window
  used: number // clamped 0..100
  isNear: boolean
  status: Status
  points?: number // used minus elapsed, rounded; absent without a known length
  elapsed?: number // percent of the window gone
  remaining?: number // seconds until reset
  shortBy?: number // seconds before reset the limit would be reached
}

const formatSpan = (seconds: number): string => {
  const m = Math.floor(seconds / 60)
  if (m < 1) return '<1 min'
  const d = Math.floor(m / 1440)
  const h = Math.floor((m % 1440) / 60)
  const mm = m % 60
  if (d >= 1) return `${d} d ${h} hr`
  if (h >= 1) return `${h} hr ${mm} min`
  return `${mm} min`
}

const formatTokens = (n: number): string => {
  const trim = (x: number) => x.toFixed(1).replace(/\.0$/, '')
  if (n >= 1_000_000) return `${trim(n / 1_000_000)}M`
  if (n >= 1000) return `${trim(n / 1000)}k`
  return `${n}`
}

const titleCase = (kind: string): string =>
  kind
    .split('_')
    .map(w => w.slice(0, 1).toUpperCase() + w.slice(1))
    .join(' ')

const measure = (kind: string, now: number, window?: Window): Reading => {
  const known = KNOWN[kind]
  const reading: Reading = {
    kind,
    label: known?.label ?? titleCase(kind),
    short: known?.short ?? titleCase(kind),
    used: 0,
    isNear: false,
    status: 'on',
  }
  if (window === undefined || !Number.isFinite(window.percentUsed)) return reading

  const used = window.percentUsed
  const reset =
    window.resetsAt === undefined ? NaN : Date.parse(window.resetsAt) / 1000
  const hasReset = Number.isFinite(reset)
  // A window whose reset time has passed holds last window's numbers.
  if (hasReset && reset <= now) return reading

  reading.percent = Math.round(used)
  reading.used = Math.max(0, Math.min(100, used))
  reading.isNear = used >= NEAR_LIMIT
  if (!hasReset) return reading

  reading.remaining = reset - now
  // Pace needs the window's length, which only the known windows have.
  if (known === undefined) return reading

  const remaining = Math.min(reading.remaining, known.seconds)
  const gone = known.seconds - remaining
  const elapsed = (gone / known.seconds) * 100
  const diff = used - elapsed

  reading.remaining = remaining
  reading.elapsed = elapsed
  reading.points = Math.round(diff)
  reading.status =
    Math.abs(diff) <= PACE_SLACK ? 'on' : diff < 0 ? 'under' : 'over'

  // A projection from the first few percent of a window swings too much.
  if (reading.status === 'over' && elapsed >= 5 && used < 100) {
    const shortBy = known.seconds - gone * (100 / used)
    if (shortBy > 0) reading.shortBy = shortBy
  }

  return reading
}

const paceText = (r: Reading): string => {
  if (r.points === undefined) return ''
  if (r.status === 'on') return 'On pace'
  return `${Math.abs(r.points)}% ${r.points < 0 ? 'under' : 'over'} pace`
}

// The theme colour a pace figure is written in; none when on pace.
const paceColor = (r: Reading): string | undefined =>
  r.status === 'on'
    ? undefined
    : r.status === 'under'
      ? 'success'
      : r.isNear
        ? 'error'
        : 'warning'

const lineColor = (r: Reading): string =>
  r.status === 'on'
    ? GREY
    : r.status === 'under'
      ? GREEN
      : r.isNear
        ? RED
        : ORANGE

const rect = (x: number, y: number, w: number, h: number, fill: string) =>
  `<rect x="${x.toFixed(1)}" y="${y}" width="${Math.max(0, w).toFixed(1)}" height="${h}" rx="${h / 2}" fill="${fill}"/>`

// A usage bar, with the pace line above it when the window's elapsed share is
// known. `width` and the returned height are CSS pixels.
const drawBars = (
  width: number,
  r: { used: number; isNear: boolean; elapsed?: number },
  line: string,
  bar: number,
): { source: string; height: number } => {
  const fill = (percent: number) =>
    percent <= 0 ? 0 : Math.max(bar, (width * Math.min(100, percent)) / 100)
  const parts: string[] = []
  let y = 0

  if (r.elapsed !== undefined) {
    const used = fill(r.used)
    const elapsed = fill(r.elapsed)
    parts.push(rect(0, 0, width, 3, TRACK))
    // The coloured stretch lies between usage and time; grey covers the rest.
    parts.push(rect(0, 0, Math.max(used, elapsed), 3, line))
    parts.push(rect(0, 0, Math.min(used, elapsed), 3, GREY))
    y = 5
  }

  parts.push(rect(0, y, width, bar, TRACK))
  parts.push(rect(0, y, fill(r.used), bar, r.isNear ? YELLOW : BLUE))

  const height = y + bar

  return {
    source: `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${parts.join('')}</svg>`,
    height,
  }
}

const barAlt = (r: Reading): string =>
  r.elapsed === undefined
    ? `${r.label}: ${r.percent}% used`
    : `${r.label}: ${r.percent}% used, ${Math.round(r.elapsed)}% of the window passed`

async function store(
  $: EngineInterface,
  usage: { rateLimits: Window[]; context?: Context; cost?: { usd: number } },
  isFresh: boolean,
) {
  const at = await $.clock.now()
  const next_: Snapshot = {
    windows: usage.rateLimits.map(w => ({
      kind: w.kind,
      percentUsed: w.percentUsed,
      resetsAt: w.resetsAt,
    })),
    at,
  }
  if (usage.context !== undefined) {
    next_.context = {
      tokens: usage.context.tokens,
      window: usage.context.window,
      percent: usage.context.percent,
    }
  }
  if (usage.cost !== undefined) next_.costUsd = usage.cost.usd
  await update($, snapshot, () => next_)

  // The overlay window (overlay/overlay.ps1) reads this file. Only a fresh
  // measurement is written: a session that sits idle re-times an old reading
  // every minute, and would otherwise write it over a busier session's newer
  // one. The plan windows are account-wide; the context is this session's, so
  // the file names the folder it belongs to.
  if (isFresh && next_.windows.length > 0) {
    const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME'))
    if (home !== undefined) {
      const cwd = await $.session.cwd().catch(() => '')
      const folder = cwd.replace(/[\\/]+$/, '').replace(/^.*[\\/]/, '')
      await $.fs
        .write(
          `${home}/.claude/plan-usage.json`,
          JSON.stringify({
            at: next_.at,
            windows: next_.windows,
            context: next_.context,
            folder,
          }),
        )
        .catch(() => undefined)
    }
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'plan-usage',
      description: 'Open the usage panel: context, session and weekly limits',
    })

    const refresh = async () => store($, await $.session.usage(), false)

    await refresh()
    // Keeps time left and pace moving between turns.
    $.clock.every(60_000, refresh)

    // Nothing is opened here: the row above the prompt is the always-on view,
    // so no panel has to stay open. The panel and its widget come from the
    // row's Details button or /plan-usage.

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await store($, e, true)

    return next(e)
  })

  on('command.run', { command: 'plan-usage' }, async $ => {
    await $.ui.open({ id: PANE, title: PANE_TITLE })

    return { text: 'Usage panel opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const snap = await read($, snapshot)

    // The terminal already shows these figures through the statusLine script.
    if (e.surface === 'terminal' || e.props.hasSurvey || snap === null) {
      return next(e)
    }

    // While the widget or the panel is on screen the row would say it twice.
    const panes = await $.ui.panes().catch(() => [])
    if (panes.some(p => p.id === PANE && p.isPlaced && p.isShown)) {
      return next(e)
    }

    const { Box, Button, Svg, Text } = $.ui.resolve(e)
    const now = snap.at / 1000
    const readings = IN_ROW.map(kind =>
      measure(
        kind,
        now,
        snap.windows.find(w => w.kind === kind),
      ),
    )
    // The week's pace is the one worth planning by; the session's stands in
    // when the week has none.
    const paced = [...readings].reverse().find(r => r.points !== undefined)
    const context = snap.context?.percent

    return (
      <Box alignItems="center" columnGap="md">
        <Text weight="semibold">Usage</Text>
        {readings.map(r => {
          if (r.percent === undefined) {
            return <Text dimColor>{r.short} -</Text>
          }
          const bars = drawBars(72, r, lineColor(r), 5)

          return (
            <Box alignItems="center" columnGap="sm">
              <Text dimColor>{r.short}</Text>
              <Svg
                source={bars.source}
                alt={barAlt(r)}
                width={72}
                height={bars.height}
              />
              <Text tabular>{r.percent}%</Text>
              {r.remaining === undefined ? null : (
                <Text size="footnote" dimColor>
                  resets in {formatSpan(r.remaining)}
                </Text>
              )}
            </Box>
          )
        })}
        {paced === undefined ? null : (
          <Text
            size="footnote"
            color={paceColor(paced)}
            dimColor={paceColor(paced) === undefined}
          >
            {paceText(paced)}
          </Text>
        )}
        {context === undefined ? null : (
          <Text size="footnote" dimColor>
            Context {Math.round(context)}%
          </Text>
        )}
        <Button
          key="details"
          label="Details"
          plain
          dimColor
          onPress={() => $.ui.open({ id: PANE, title: PANE_TITLE })}
        />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Progress, Text } = ui
    const snap = await read($, snapshot)

    if (snap === null) {
      return (
        <Box padding={1}>
          <Text dimColor>No reading yet.</Text>
        </Box>
      )
    }

    const now = snap.at / 1000
    // The two plan windows first, present or not, then any other the account has.
    const kinds = [
      ...IN_ROW,
      ...snap.windows.map(w => w.kind).filter(k => !IN_ROW.includes(k)),
    ]
    const readings = kinds.map(kind =>
      measure(
        kind,
        now,
        snap.windows.find(w => w.kind === kind),
      ),
    )
    const paced = [...readings]
      .filter(r => IN_ROW.includes(r.kind))
      .reverse()
      .find(r => r.points !== undefined)
    const context = snap.context
    const WIDTH = 280

    // As a widget: a glance, with nothing to click. Only the desktop has them.
    if (e.props.placement === 'widget' && e.surface !== 'terminal') {
      const { Svg } = $.ui.resolve(e)
      const GLANCE = 200

      return (
        <Box flexDirection="column" paddingX={1} rowGap="sm">
          <Box justifyContent="space-between" alignItems="center">
            <Text weight="semibold">Usage</Text>
            {paced === undefined ? null : (
              <Text
                size="footnote"
                color={paceColor(paced)}
                dimColor={paceColor(paced) === undefined}
              >
                {paceText(paced)}
              </Text>
            )}
          </Box>
          {readings
            .filter(r => IN_ROW.includes(r.kind))
            .map(r => {
              const drawn = drawBars(GLANCE, r, lineColor(r), 6)

              return (
                <Box flexDirection="column">
                  <Box justifyContent="space-between">
                    <Text size="footnote">{r.short}</Text>
                    <Text size="footnote" dimColor>
                      {r.percent === undefined ? '-' : `${r.percent}% used`}
                    </Text>
                  </Box>
                  {r.percent === undefined ? null : (
                    <Svg
                      source={drawn.source}
                      alt={barAlt(r)}
                      width={GLANCE}
                      height={drawn.height}
                    />
                  )}
                  {r.remaining === undefined ? null : (
                    <Text size="footnote" dimColor>
                      Resets in {formatSpan(r.remaining)}
                    </Text>
                  )}
                </Box>
              )
            })}
          {context?.percent === undefined ? null : (
            <Text size="footnote" dimColor>
              Context {Math.round(context.percent)}%
            </Text>
          )}
        </Box>
      )
    }

    // The terminal has no Svg: a Progress stands in for the pair of bars.
    const bars = (
      r: { used: number; isNear: boolean; elapsed?: number },
      line: string,
      alt: string,
      label: string,
    ) => {
      if (e.surface === 'terminal') {
        return (
          <Progress
            label={label}
            value={r.used}
            max={100}
            valueText={`${Math.round(r.used)}%`}
            color={r.isNear ? 'warning' : undefined}
          />
        )
      }
      const { Svg } = $.ui.resolve(e)
      const drawn = drawBars(WIDTH, r, line, 7)

      return (
        <Svg source={drawn.source} alt={alt} width={WIDTH} height={drawn.height} />
      )
    }

    return (
      <Box flexDirection="column" padding={1}>
        <Box
          flexDirection="column"
          borderStyle="round"
          borderDimColor
          paddingX={1}
          rowGap="md"
        >
          <Box justifyContent="space-between" alignItems="center">
            <Text weight="semibold" size="heading">
              Usage
            </Text>
            {paced === undefined ? null : (
              <Text
                size="footnote"
                color={paceColor(paced)}
                dimColor={paceColor(paced) === undefined}
              >
                {paceText(paced)}
              </Text>
            )}
          </Box>

          {context === undefined ? null : (
            <Box flexDirection="column">
              <Box justifyContent="space-between">
                <Text weight="medium">Context</Text>
                <Text dimColor>
                  {context.percent === undefined
                    ? 'no reading yet'
                    : `${Math.round(context.percent)}% used`}
                </Text>
              </Box>
              {context.percent === undefined
                ? null
                : bars(
                    {
                      used: Math.max(0, Math.min(100, context.percent)),
                      isNear: context.percent >= 90,
                    },
                    GREY,
                    `Context: ${Math.round(context.percent)}% used`,
                    'Context',
                  )}
              <Text size="footnote" dimColor>
                {context.tokens === undefined
                  ? ''
                  : `${formatTokens(context.tokens)} / `}
                {formatTokens(context.window)}
              </Text>
            </Box>
          )}

          {readings.map(r => (
            <Box flexDirection="column">
              <Box justifyContent="space-between">
                <Text weight="medium">{r.label}</Text>
                <Text dimColor>
                  {r.percent === undefined
                    ? 'no reading yet'
                    : `${r.percent}% used`}
                </Text>
              </Box>
              {r.percent === undefined
                ? null
                : bars(r, lineColor(r), barAlt(r), r.label)}
              {r.percent === undefined ? null : (
                <Box justifyContent="space-between">
                  <Text size="footnote" dimColor>
                    {r.remaining === undefined
                      ? ''
                      : `Resets in ${formatSpan(r.remaining)}`}
                  </Text>
                  {r.points === undefined ? null : (
                    <Text
                      size="footnote"
                      color={paceColor(r)}
                      dimColor={paceColor(r) === undefined}
                    >
                      {paceText(r)}
                    </Text>
                  )}
                </Box>
              )}
              {r.shortBy === undefined ? null : (
                <Text size="footnote" dimColor>
                  At this rate the limit is reached {formatSpan(r.shortBy)}{' '}
                  before reset
                </Text>
              )}
            </Box>
          ))}

          {snap.costUsd === undefined ? null : (
            <Text size="footnote" dimColor>
              Session cost at API prices: about ${snap.costUsd.toFixed(2)} (an
              estimate, not a bill)
            </Text>
          )}
        </Box>
      </Box>
    )
  })
}
