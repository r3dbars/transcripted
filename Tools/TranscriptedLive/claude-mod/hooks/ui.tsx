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
  /** The person closed the "wrap-up ready" line, or it has been up 30 minutes. */
  isWrapDismissed: boolean
  /** Transcripted takes stop requests (its companion socket answers). */
  canStop: boolean
  /** Stop is pressed once and waits for the second press. */
  isStopArmed: boolean
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
  /** Hides the "wrap-up ready" line for this call. */
  dismiss: () => void
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

/**
 * The one line above the prompt: a red dot and the time while recording, with
 * Notes (show or hide the sidebar) and Stop (two presses). After the call it
 * says the wrap-up is ready.
 */
export function band(el: Els, m: ViewModel, act: Actions, prompts: Prompts): RenderElement | null {
  const { Box, Text, Button } = el
  const isLive = m.phase === 'live' || m.phase === 'stalled'
  // The newest question aimed at the person, with a one-click draft.
  const question = m.questions.at(-1)
  if (isLive) {
    return (
      <Box flexDirection="row" alignItems="center" gap={1}>
        <Box flexShrink={0}>{dot(el, m.phase === 'live')}</Box>
        <Box flexShrink={0}>
          <Text dimColor>{m.phase === 'live' ? m.clock : `${m.clock} · reconnecting`}</Text>
        </Box>
        {question ? (
          <Box flexGrow={1} flexShrink={1} flexDirection="row" alignItems="center" gap={1}>
            <Box flexShrink={1}>
              <Text wrap="truncate-end">{`Asked: “${question}”`}</Text>
            </Box>
            <Button
              key="band-draft"
              variant="primary"
              label={m.pending.has(prompts.answer(question)) ? 'Drafting…' : 'Draft answer'}
              onPress={() => act.ask(prompts.answer(question))}
            />
          </Box>
        ) : (
          <Box flexGrow={1} />
        )}
        {notesButton(el, m, act)}
        {m.canStop ? stopButton(el, m, act) : null}
      </Box>
    )
  }
  if (m.phase === 'wrapped' && m.wrap && !m.isWrapDismissed) {
    return (
      <Box flexDirection="row" alignItems="center" gap={1}>
        <Box flexShrink={0}>
          <Text color="green">✓</Text>
        </Box>
        <Box flexShrink={0}>
          <Text dimColor>Wrap-up ready</Text>
        </Box>
        <Box flexGrow={1} flexShrink={1}>
          <Text wrap="truncate-end">{m.wrap.title}</Text>
        </Box>
        {notesButton(el, m, act)}
        <Button key="band-dismiss" plain label="×" onPress={act.dismiss} />
      </Box>
    )
  }
  if (m.phase === 'ending') {
    return (
      <Box flexDirection="row" alignItems="center" gap={1}>
        <Box flexGrow={1}>
          <Text dimColor>Writing the wrap-up…</Text>
        </Box>
        {notesButton(el, m, act)}
      </Box>
    )
  }
  return null
}

/** The recording dot: softly pulsing on the desktop, a plain dot in the terminal. */
function dot(el: Els, isLive: boolean): RenderElement {
  const { Svg, Text } = el
  const color = isLive ? RED : AMBER
  if (!Svg) return <Text color={color}>{isLive ? '●' : '◌'}</Text>
  const source = isLive
    ? `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5.5" fill="${color}" opacity="0.2"><animate attributeName="r" values="3;5.5;3" dur="2s" repeatCount="indefinite"/><animate attributeName="opacity" values="0.35;0;0.35" dur="2s" repeatCount="indefinite"/></circle><circle cx="6" cy="6" r="3.2" fill="${color}"/></svg>`
    : `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="3" fill="none" stroke="${color}" stroke-width="1.3"/></svg>`
  return <Svg key="band-dot" source={source} alt={isLive ? 'Recording' : 'Reconnecting'} width={12} height={12} />
}

function notesButton(el: Els, m: ViewModel, act: Actions): RenderElement {
  const { Button } = el
  return <Button key="band-notes" plain label={m.isPaneOpen ? 'Hide notes' : 'Notes'} onPress={act.togglePane} />
}

function stopButton(el: Els, m: ViewModel, act: Actions): RenderElement {
  const { Button } = el
  if (m.isStopping) return <Button key="band-stop" plain label="Stopping…" onPress={() => undefined} />
  // `plain` is true or absent, never false: the armed state drops it for the primary look.
  return m.isStopArmed ? (
    <Button key="band-stop" variant="primary" label="Stop? click again" onPress={act.stop} />
  ) : (
    <Button key="band-stop" plain label="Stop" onPress={act.stop} />
  )
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
        {isLive ? (
          <Box flexShrink={0}>
            <Text color={m.phase === 'live' ? RED : AMBER}>{m.phase === 'live' ? '●' : '◌'}</Text>
          </Box>
        ) : null}
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
    m.gist ? `**Now**\n${m.gist}` : '',
    m.actions.length > 0 ? `**Action items**\n${m.actions.map(item => `- [ ] ${item}`).join('\n')}` : '',
    m.say ? `**You could say**\n> ${m.say}` : '',
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
    <Box flexDirection="column">
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
              <Box flexDirection="row">
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
  if (owners.length < 2 || owners.includes('')) return `**Action items**\n${actions.map(item => `- [ ] ${item}`).join('\n')}`
  // You first, then named people, then whatever nobody took.
  const rank = (owner: string) => (/^you$/i.test(owner) ? 0 : /^unassigned$/i.test(owner) ? 2 : 1)
  owners.sort((a, b) => rank(a) - rank(b))
  return [
    '**Who owes what**',
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
    items.length > 0 ? `**${title}**\n${items.map(item => `${prefix}${item}`).join('\n')}` : ''
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
