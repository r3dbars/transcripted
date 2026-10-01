import type { RenderElement } from 'claude-code'

import type { LiveWrapup } from '../types'

/**
 * How the live meeting looks: the band above the prompt and the pane beside the
 * transcript. Pure drawing from a model the hooks module builds; no `$` here,
 * only the element table and the handlers it is handed.
 *
 * The look is quiet on purpose: one accent (recording red), the theme's own
 * text colours, Markdown for anything that reads like notes, and vector
 * drawings where the surface has them (desktop), plain glyphs where it does not.
 */

export type Phase = 'none' | 'waiting' | 'live' | 'stalled' | 'ending' | 'ended' | 'wrapped'
export type Tab = 'notes' | 'transcript'

export type TranscriptLine = { time: string; who: string; text: string; isNewTurn: boolean }

export type ViewModel = {
  phase: Phase
  clock: string
  /** When the call started, "Oct 1 · 2:23 PM"; '' when unknown. */
  when: string
  isReplay: boolean
  isContextOn: boolean
  isHelperOn: boolean
  /** Someone is mid-sentence right now (drives the waveform). */
  isTalking: boolean
  /** Advances while someone talks; the waveform's animation step. */
  frame: number
  title: string
  gist: string
  questions: string[]
  actions: string[]
  say: string
  lines: TranscriptLine[]
  lineCount: number
  partials: { who: string; text: string }[]
  /** The newest thing said, for the band's ticker. */
  latest: string
  wrap: LiveWrapup | null
  tab: Tab
  isPaneOpen: boolean
  /** Prompts sent from a button that Claude has not answered yet. */
  pending: ReadonlySet<string>
  /** Stop is pressed once and waits for the second press. */
  isStopArmed: boolean
  /** Transcripted takes stop requests (the companion socket is there). */
  canStop: boolean
  /** A stop was sent and the call is winding down. */
  isStopping: boolean
}

export type Actions = {
  ask: (prompt: string) => void
  setTab: (tab: Tab) => void
  openPane: () => void
  togglePane: () => void
  /** First press arms it, a second within a few seconds stops the recording. */
  stop: () => void
}

export type Prompts = {
  answer: (question: string) => string
}

// Loose element constructors: the surface tables differ.
type El = (props: Record<string, unknown>) => RenderElement
/** `Svg` is there on the desktop (and other remote surfaces), not the terminal. */
export type Els = { Box: El; Text: El; Button: El; Markdown: El; Svg?: El }

const RED = '#FF5A4E'
const AMBER = '#E5A93B'

// MARK: band

/** The band's looks, picked with `/meeting style 1-6`. */
export const BAND_STYLES = [
  { id: 1, name: 'Dot', about: 'just a recording dot, the time and the notes toggle' },
  { id: 2, name: 'Pill', about: 'waveform, "Recording", the time and the toggle' },
  { id: 3, name: 'Ticker', about: 'waveform and time, then the last thing said scrolling by' },
  { id: 4, name: 'Captions', about: 'a small status line over live captions of what is being said' },
  { id: 5, name: 'Coach', about: 'whatever was just asked of you, with a Draft answer button' },
  { id: 6, name: 'Topic', about: 'the call\'s name and what is being discussed right now' },
  { id: 7, name: 'Wave', about: 'only a wide waveform, the time and two icons' },
] as const
export type BandStyle = (typeof BAND_STYLES)[number]['id']

/** The band above the prompt while a call is live, or just wrapped up. */
export function band(el: Els, m: ViewModel, act: Actions, style: BandStyle, prompts: Prompts): RenderElement | null {
  const { Box, Text, Button } = el
  if (m.phase === 'wrapped' && m.wrap) {
    if (m.isPaneOpen) return null
    return (
      <Box flexDirection="row" alignItems="center" gap={1} paddingX={1}>
        <Text color="green">✓</Text>
        <Box flexShrink={0}>
          <Text bold>Wrap-up ready</Text>
        </Box>
        <Box flexGrow={1} flexShrink={1}>
          <Text dimColor wrap="truncate-end">
            {m.wrap.title}
          </Text>
        </Box>
        {toggle(el, m, act, style === 1)}
      </Box>
    )
  }
  if (m.phase !== 'live' && m.phase !== 'stalled') return null

  const isLive = m.phase === 'live'
  const mark = <Box flexShrink={0}>{recordingMark(el, 'band-wave', isLive, m.isTalking, 7, m.frame)}</Box>
  const dot = (
    <Box flexShrink={0}>
      <Text color={isLive ? RED : AMBER}>{isLive ? '●' : '◌'}</Text>
    </Box>
  )
  const time = (
    <Box flexShrink={0}>
      <Text dimColor>{m.clock}</Text>
    </Box>
  )
  const grow = (child: RenderElement | null) => (
    <Box flexGrow={1} flexShrink={1}>
      {child}
    </Box>
  )
  const asked = m.questions.length
  const askedChip =
    asked > 0 ? <Button key="band-asked" plain label={`${asked} asked`} onPress={act.openPane} /> : null
  const row = (children: (RenderElement | null)[]) => (
    <Box flexDirection="row" alignItems="center" gap={1} paddingX={1}>
      {children}
    </Box>
  )

  switch (style) {
    case 1:
      return row([dot, time, grow(null), askedChip, toggle(el, m, act, true)])
    case 2:
      return row([
        mark,
        <Box flexShrink={0}>
          <Text bold>{isLive ? 'Recording' : 'Reconnecting'}</Text>
        </Box>,
        time,
        grow(m.isContextOn ? null : <Text color="yellow">context off</Text>),
        askedChip,
        toggle(el, m, act, false),
      ])
    case 4: {
      const caption = m.partials[0] ?? (m.lines.at(-1) ? { who: m.lines.at(-1)?.who ?? '', text: m.lines.at(-1)?.text ?? '' } : null)
      return (
        <Box flexDirection="column" paddingX={1}>
          <Box flexDirection="row" alignItems="center" gap={1}>
            {mark}
            {time}
            <Box flexShrink={0}>
              <Text dimColor>{m.isContextOn ? '· Claude is listening' : '· context off'}</Text>
            </Box>
            {grow(null)}
            {askedChip}
            {toggle(el, m, act, false)}
          </Box>
          <Text wrap="truncate-start" italic={!!m.partials[0]} dimColor={!caption}>
            {caption ? `${caption.who}: ${caption.text}${m.partials[0] ? '…' : ''}` : 'Listening…'}
          </Text>
        </Box>
      )
    }
    case 5: {
      const question = m.questions.at(-1)
      if (!question) {
        return row([
          mark,
          time,
          grow(
            <Text dimColor wrap="truncate-end">
              {m.gist ? `Now: ${m.gist}` : 'Nothing asked of you yet'}
            </Text>,
          ),
          toggle(el, m, act, false),
        ])
      }
      const prompt = prompts.answer(question)
      return row([
        mark,
        <Box flexShrink={0}>
          <Text bold color={RED}>
            Asked
          </Text>
        </Box>,
        grow(<Text wrap="truncate-end">{`“${question}”`}</Text>),
        <Button
          key="band-draft"
          label={m.pending.has(prompt) ? 'Drafting…' : 'Draft answer'}
          variant="primary"
          dimColor={m.pending.has(prompt)}
          onPress={() => act.ask(prompt)}
        />,
        toggle(el, m, act, true),
      ])
    }
    case 6:
      return row([
        mark,
        time,
        <Box flexShrink={1}>
          <Text bold wrap="truncate-end">
            {m.title || 'Live call'}
          </Text>
        </Box>,
        grow(
          <Text dimColor wrap="truncate-end">
            {m.gist ? `— ${m.gist}` : ''}
          </Text>,
        ),
        askedChip,
        toggle(el, m, act, false),
      ])
    case 7:
      return row([
        <Box flexGrow={1} flexShrink={1}>
          {recordingMark(el, 'band-wave-wide', isLive, m.isTalking, 32, m.frame)}
        </Box>,
        time,
        toggle(el, m, act, true),
      ])
    case 3:
    default:
      return row([
        mark,
        <Box flexShrink={0}>
          <Text>
            <Text bold>{isLive ? 'Recording' : 'Reconnecting'}</Text>
            <Text dimColor>{`  ${m.clock}  ·  ${m.isContextOn ? 'in context' : 'context off'}`}</Text>
          </Text>
        </Box>,
        <Box flexGrow={1} flexShrink={1} marginLeft={1}>
          <Text dimColor italic wrap="truncate-end">
            {m.latest ? `“${m.latest}”` : ''}
          </Text>
        </Box>,
        askedChip,
        toggle(el, m, act, false),
      ])
  }
}

/**
 * The band's controls: show or hide the notes sidebar, and stop the recording
 * (while live, where Transcripted takes it). Icons in the minimal styles.
 */
function toggle(el: Els, m: ViewModel, act: Actions, isIcon: boolean): RenderElement {
  const { Box, Button } = el
  const label = isIcon ? (m.isPaneOpen ? '◨' : '◧') : m.isPaneOpen ? 'Hide notes' : 'Show notes'
  const isLive = m.phase === 'live' || m.phase === 'stalled'
  return (
    <Box flexDirection="row" flexShrink={0} gap={1}>
      <Button key="band-toggle" plain label={label} onPress={act.togglePane} />
      {isLive && m.canStop ? stopButton(el, m, act, isIcon) : null}
    </Box>
  )
}

function stopButton(el: Els, m: ViewModel, act: Actions, isIcon: boolean): RenderElement {
  const { Button } = el
  const label = m.isStopping ? (isIcon ? '…' : 'Stopping…') : m.isStopArmed ? 'Stop? click again' : isIcon ? '■' : '■ Stop'
  // `plain` is true or absent, never false: the armed state drops it for the primary look.
  return m.isStopArmed ? (
    <Button key="band-stop" variant="primary" label={label} onPress={act.stop} />
  ) : (
    <Button key="band-stop" plain label={label} onPress={act.stop} />
  )
}

/**
 * A dot and a waveform that moves while someone is talking, flat when quiet.
 * Desktop: a small vector image that animates itself (no frame, so no white
 * box). Terminal: block-character bars the band redraws each poll.
 */
function recordingMark(el: Els, key: string, isLive: boolean, isTalking: boolean, width = 7, frame = 0): RenderElement {
  const { Text, Svg } = el
  const color = isLive ? RED : AMBER
  const showDot = width <= 12
  if (Svg) {
    const px = Math.max(36, Math.round(width * 7.5)) + (showDot ? 14 : 0)
    return (
      <Svg
        key={key}
        source={waveSvg(width, isLive, isTalking, showDot, px)}
        alt={isLive ? (isTalking ? 'Recording, someone is talking' : 'Recording') : 'Reconnecting'}
        width={px}
        height={16}
      />
    )
  }
  const dot = isLive ? '●' : '◌'
  return (
    <Text key={key}>
      {showDot ? <Text color={color}>{`${dot} `}</Text> : null}
      <Text color={color} dimColor={!isTalking}>
        {waveform(width, isTalking ? frame : -1)}
      </Text>
    </Text>
  )
}

/** The waveform as SVG: rounded bars that breathe while someone talks (SMIL plays in an image). */
function waveSvg(bars: number, isLive: boolean, isTalking: boolean, showDot: boolean, px: number): string {
  const color = isLive ? RED : AMBER
  const h = 16
  const mid = h / 2
  const start = showDot ? 14 : 1
  const step = (px - start) / bars
  const barW = Math.max(2, Math.min(3, step * 0.55))
  let out = ''
  for (let i = 0; i < bars; i++) {
    const x = (start + i * step).toFixed(1)
    const rest = 2
    if (!isTalking) {
      out += `<rect x="${x}" y="${mid - rest / 2}" width="${barW}" height="${rest}" rx="${barW / 2}" fill="${color}" opacity="0.35"/>`
      continue
    }
    const peak = 4 + Math.round(10 * (0.5 + 0.5 * Math.sin(i * 1.7)))
    const dur = (0.7 + ((i * 37) % 9) * 0.07).toFixed(2)
    const heights = [rest, peak, rest + 3, Math.round(peak * 0.6), rest].join(';')
    const ys = [rest, peak, rest + 3, Math.round(peak * 0.6), rest].map(v => (mid - v / 2).toFixed(1)).join(';')
    out +=
      `<rect x="${x}" y="${mid - rest / 2}" width="${barW}" height="${rest}" rx="${barW / 2}" fill="${color}" opacity="0.9">` +
      `<animate attributeName="height" values="${heights}" dur="${dur}s" repeatCount="indefinite"/>` +
      `<animate attributeName="y" values="${ys}" dur="${dur}s" repeatCount="indefinite"/></rect>`
  }
  const dot = showDot
    ? isLive
      ? `<circle cx="6" cy="${mid}" r="6" fill="${color}" opacity="0.25"><animate attributeName="r" values="3.5;6.5;3.5" dur="1.8s" repeatCount="indefinite"/><animate attributeName="opacity" values="0.35;0;0.35" dur="1.8s" repeatCount="indefinite"/></circle><circle cx="6" cy="${mid}" r="3.5" fill="${color}"/>`
      : `<circle cx="6" cy="${mid}" r="3.5" fill="none" stroke="${color}" stroke-width="1.5"/>`
    : ''
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${h}" viewBox="0 0 ${px} ${h}">${dot}${out}</svg>`
}

const BARS = '▁▂▃▄▅▆▇█'

/** Block-character bars; two sines per bar so it never looks like a loop. Flat when `frame` is -1. */
export function waveform(width: number, frame: number): string {
  let out = ''
  for (let i = 0; i < width; i++) {
    if (frame < 0) {
      out += BARS[0]
      continue
    }
    const level = 0.5 + 0.3 * Math.sin(frame * 1.1 + i * 1.3) + 0.2 * Math.sin(frame * 0.47 + i * 2.1)
    out += BARS[Math.max(0, Math.min(BARS.length - 1, Math.round(level * (BARS.length - 1))))]
  }
  return out
}

// MARK: pane

export function pane(el: Els, m: ViewModel, act: Actions, prompts: Prompts): RenderElement {
  if (m.phase === 'none') return emptyState(el)
  if (m.phase === 'wrapped' && m.wrap) return wrapUp(el, m, m.wrap, act)
  if (m.phase === 'ending' || m.phase === 'ended') return endingState(el, m)
  return liveNotes(el, m, act, prompts)
}

function emptyState(el: Els): RenderElement {
  const { Box, Text } = el
  return (
    <Box flexDirection="column" paddingX={1} paddingY={1} gap={1}>
      <Text bold>No call yet</Text>
      <Text dimColor wrap="wrap">
        Start recording in Transcripted. Notes, questions aimed at you and the transcript show up here as the
        call goes.
      </Text>
    </Box>
  )
}

function header(el: Els, m: ViewModel, title: string, meta: string, isLive: boolean): RenderElement {
  const { Box, Text } = el
  return (
    <Box flexDirection="column">
      <Text bold wrap="wrap">
        {title}
      </Text>
      <Box flexDirection="row" alignItems="center" gap={1}>
        {isLive ? <Box flexShrink={0}>{recordingMark(el, 'pane-wave', m.phase === 'live', m.isTalking, 7, m.frame)}</Box> : null}
        <Text dimColor wrap="truncate-end">
          {meta}
        </Text>
      </Box>
    </Box>
  )
}

function tabs(el: Els, m: ViewModel, act: Actions): RenderElement {
  const { Box, Button } = el
  const tab = (key: Tab, label: string) => (
    <Button
      key={`tab-${key}`}
      label={label}
      variant={m.tab === key ? 'primary' : 'secondary'}
      onPress={() => act.setTab(key)}
    />
  )
  return (
    <Box flexDirection="row" gap={1} marginTop={1}>
      {tab('notes', 'Notes')}
      {tab('transcript', m.lineCount > 0 ? `Transcript · ${m.lineCount}` : 'Transcript')}
    </Box>
  )
}

function liveNotes(el: Els, m: ViewModel, act: Actions, prompts: Prompts): RenderElement {
  const { Box } = el
  const title = m.title || (m.phase === 'waiting' ? 'Waiting for the call' : 'Live call')
  const meta = [
    m.phase === 'live' ? `Live · ${m.clock}` : m.phase === 'stalled' ? `Reconnecting · ${m.clock}` : 'Waiting',
    m.isReplay ? 'replay' : '',
    m.isContextOn ? 'Claude is listening' : 'context off',
  ]
    .filter(Boolean)
    .join('  ·  ')
  return (
    <Box flexDirection="column" paddingX={1} paddingTop={1}>
      {header(el, m, title, meta, true)}
      {m.canStop && (m.phase === 'live' || m.phase === 'stalled') ? (
        <Box flexDirection="row" marginTop={1}>
          {stopButton(el, m, act, false)}
        </Box>
      ) : null}
      {tabs(el, m, act)}
      <Box flexDirection="column" marginTop={1}>
        {m.tab === 'notes' ? notesBody(el, m, act, prompts) : transcriptBody(el, m)}
      </Box>
    </Box>
  )
}

function notesBody(el: Els, m: ViewModel, act: Actions, prompts: Prompts): RenderElement {
  const { Box, Text, Markdown } = el
  const hasNotes = m.gist !== '' || m.questions.length > 0 || m.actions.length > 0
  if (!hasNotes) {
    return (
      <Box flexDirection="column" gap={1}>
        <Text dimColor wrap="wrap">
          {m.isHelperOn
            ? 'Listening. Notes start after a minute or so of conversation.'
            : 'Live notes are off. Turn them on with /meeting helper on.'}
        </Text>
        {m.latest ? (
          <Text dimColor italic wrap="wrap">
            {`“${m.latest}”`}
          </Text>
        ) : null}
      </Box>
    )
  }

  const markdown = [
    m.gist ? `#### Now\n${m.gist}` : '',
    m.actions.length > 0 ? `#### Action items\n${m.actions.map(item => `- [ ] ${item}`).join('\n')}` : '',
    m.say ? `#### You could say\n> ${m.say}` : '',
  ]
    .filter(Boolean)
    .join('\n\n')

  return (
    <Box flexDirection="column" gap={1}>
      {m.questions.length > 0 ? (
        <Box flexDirection="column" gap={1}>
          <Text bold>Asked of you</Text>
          {m.questions.map((question, index) => questionCard(el, m, act, prompts, question, index))}
        </Box>
      ) : null}
      {markdown ? <Markdown key="notes-md" text={markdown} /> : null}
    </Box>
  )
}

function questionCard(
  el: Els,
  m: ViewModel,
  act: Actions,
  prompts: Prompts,
  question: string,
  index: number,
): RenderElement {
  const { Box, Text, Button } = el
  const prompt = prompts.answer(question)
  const isSent = m.pending.has(prompt)
  // No border around the button: a bordered box swallowed clicks on the desktop.
  return (
    <Box key={`q-card-${index}`} flexDirection="column">
      <Text wrap="wrap">{`“${question}”`}</Text>
      <Box flexDirection="row" marginTop={1}>
        <Button
          key={`q${index}`}
          label={isSent ? 'Drafting…' : 'Draft answer'}
          hotkey={String(index + 1)}
          variant="primary"
          dimColor={isSent}
          onPress={() => act.ask(prompt)}
        />
      </Box>
    </Box>
  )
}

function transcriptBody(el: Els, m: ViewModel): RenderElement {
  const { Box, Text } = el
  if (m.lines.length === 0 && m.partials.length === 0) {
    return <Text dimColor>Listening…</Text>
  }
  return (
    <Box flexDirection="column">
      {m.lineCount > m.lines.length ? (
        <Box marginBottom={1}>
          <Text dimColor>{`Earlier lines: ask Claude, it has the whole call (${m.lineCount} lines).`}</Text>
        </Box>
      ) : null}
      {m.lines.map((line, index) => (
        <Box flexDirection="column" marginTop={line.isNewTurn && index > 0 ? 1 : 0}>
          {line.isNewTurn ? (
            <Text>
              <Text bold color={line.who === 'You' ? 'cyan' : undefined}>
                {line.who}
              </Text>
              <Text dimColor>{`  ${line.time}`}</Text>
            </Text>
          ) : null}
          <Text wrap="wrap">{line.text}</Text>
        </Box>
      ))}
      {m.partials.map(partial => (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>
            {partial.who}
          </Text>
          <Text dimColor italic wrap="wrap">
            {`${partial.text}…`}
          </Text>
        </Box>
      ))}
    </Box>
  )
}

function endingState(el: Els, m: ViewModel): RenderElement {
  const { Box, Text } = el
  return (
    <Box flexDirection="column" paddingX={1} paddingTop={1} gap={1}>
      {header(el, m, m.title || 'Call ended', `Ended · ${m.clock}`, false)}
      <Text dimColor wrap="wrap">
        {m.phase === 'ending' ? 'Writing your wrap-up…' : 'This call was too short for a wrap-up.'}
      </Text>
    </Box>
  )
}

function wrapUp(el: Els, m: ViewModel, wrap: LiveWrapup, act: Actions): RenderElement {
  const { Box, Button, Markdown, Text } = el
  const people = wrap.speakers.length > 0 ? wrap.speakers.join(', ') : ''
  const meta = [m.when, durationLabel(m.clock), people || (wrap.source === 'saved' ? '' : 'names coming…')]
    .filter(Boolean)
    .join('  ·  ')
  const next = (wrap.nextActions ?? []).slice(0, 3)
  const markdown = wrapupMarkdown(wrap, false)
  return (
    <Box flexDirection="column" paddingX={1} paddingTop={1}>
      <Text color="green">✓ Wrap-up</Text>
      {header(el, m, wrap.title || 'Call wrap-up', meta, false)}
      <Box marginTop={1}>
        <Markdown key="wrap-md" text={markdown} />
      </Box>
      {next.length > 0 ? (
        <Box flexDirection="column" marginTop={1} gap={1}>
          <Text bold>Claude can do next</Text>
          {next.map((action, index) => {
            const isSent = m.pending.has(action.prompt)
            return (
              <Box key={`next-${index}`} flexDirection="row">
                <Button
                  key={`next-btn-${index}`}
                  label={isSent ? `${action.label}  ·  working…` : `${action.label}  →`}
                  hotkey={String(index + 1)}
                  variant={index === 0 ? 'primary' : 'secondary'}
                  dimColor={isSent}
                  onPress={() => act.ask(action.prompt)}
                />
              </Box>
            )
          })}
        </Box>
      ) : null}
    </Box>
  )
}

/**
 * Action items grouped by who owns them ("Sarah: send the deck" under **Sarah**)
 * when there is more than one owner; a plain checklist otherwise.
 */
function actionsByOwner(actions: string[]): string {
  if (actions.length === 0) return ''
  const groups = new Map<string, string[]>()
  for (const item of actions) {
    const match = /^([^:]{1,40}):\s+(.+)$/.exec(item)
    const owner = match?.[1]?.trim() ?? ''
    const task = match?.[2]?.trim() ?? item
    groups.set(owner, [...(groups.get(owner) ?? []), task])
  }
  const owners = [...groups.keys()]
  if (owners.length < 2 || owners.includes('')) return `#### Action items\n${actions.map(item => `- [ ] ${item}`).join('\n')}`
  // You first, then named people, then whatever nobody took.
  const rank = (owner: string) => (/^you$/i.test(owner) ? 0 : /^unassigned$/i.test(owner) ? 2 : 1)
  owners.sort((a, b) => rank(a) - rank(b))
  return [
    '#### Who owes what',
    ...owners.map(owner => `**${owner}**\n${(groups.get(owner) ?? []).map(task => `- [ ] ${task}`).join('\n')}`),
  ].join('\n\n')
}

/** "06:05" as "6 min"; under a minute, "under a minute". */
function durationLabel(clock: string): string {
  const parts = clock.split(':').map(Number)
  const minutes = parts.length === 3 ? (parts[0] ?? 0) * 60 + (parts[1] ?? 0) : (parts[0] ?? 0)
  if (!Number.isFinite(minutes)) return clock
  return minutes < 1 ? 'under a minute' : `${minutes} min`
}

/** The wrap-up as Markdown: for the card, and with its title for the clipboard. */
export function wrapupMarkdown(wrap: LiveWrapup, withTitle: boolean): string {
  const section = (title: string, items: string[], prefix: string) =>
    items.length > 0 ? `#### ${title}\n${items.map(item => `${prefix}${item}`).join('\n')}` : ''
  return [
    withTitle ? `## ${wrap.title || 'Call wrap-up'}` : '',
    section('Summary', wrap.summary, '- '),
    section('Decisions', wrap.decisions, '- '),
    section('Still open', wrap.openQuestions, '- '),
    actionsByOwner(wrap.actions),
  ]
    .filter(Boolean)
    .join('\n\n')
}
