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
}

export type Actions = {
  ask: (prompt: string) => void
  setTab: (tab: Tab) => void
  openPane: () => void
  copy: (text: string) => void
}

export type Prompts = {
  answer: (question: string) => string
  email: string
  todos: string
  notes: string
}

// Loose element constructors: the surface tables differ.
type El = (props: Record<string, unknown>) => RenderElement
/** `wave` draws the animated recording mark where the surface runs client modules. */
export type Els = {
  Box: El
  Text: El
  Button: El
  Markdown: El
  wave?: (key: string, isLive: boolean, isTalking: boolean, color: string) => RenderElement
}

const RED = '#FF5A4E'
const AMBER = '#E5A93B'

// MARK: band

/** One quiet line above the prompt while a call is live, or just wrapped up. */
export function band(el: Els, m: ViewModel, act: Actions): RenderElement | null {
  const { Box, Text, Button } = el
  if (m.phase === 'live' || m.phase === 'stalled') {
    const asked = m.questions.length
    return (
      <Box flexDirection="row" alignItems="center" gap={1} paddingX={1}>
        <Box flexShrink={0}>{recordingMark(el, 'band-wave', m.phase === 'live', m.isTalking)}</Box>
        <Box flexShrink={0}>
          <Text>
            <Text bold>{m.phase === 'live' ? 'Recording' : 'Reconnecting'}</Text>
            <Text dimColor>{`  ${m.clock}  ·  ${m.isContextOn ? 'in context' : 'context off'}`}</Text>
          </Text>
        </Box>
        <Box flexGrow={1} flexShrink={1} marginLeft={1}>
          <Text dimColor italic wrap="truncate-end">
            {m.latest ? `“${m.latest}”` : ''}
          </Text>
        </Box>
        {asked > 0 ? (
          <Button key="band-asked" plain label={`${asked} asked of you`} onPress={act.openPane} />
        ) : null}
        {!m.isPaneOpen ? <Button key="band-notes" plain label="Notes ›" onPress={act.openPane} /> : null}
      </Box>
    )
  }
  if (m.phase === 'wrapped' && m.wrap && !m.isPaneOpen) {
    return (
      <Box flexDirection="row" alignItems="center" gap={1} paddingX={1}>
        <Text color="green">✓</Text>
        <Text bold>Wrap-up ready</Text>
        <Box flexGrow={1} flexShrink={1}>
          <Text dimColor wrap="truncate-end">
            {m.wrap.title}
          </Text>
        </Box>
        <Button key="band-open" plain label="Open ›" onPress={act.openPane} />
      </Box>
    )
  }
  return null
}

/** A dot and a text waveform that moves while someone is talking; a plain dot where it can't animate. */
function recordingMark(el: Els, key: string, isLive: boolean, isTalking: boolean): RenderElement {
  const color = isLive ? RED : AMBER
  if (el.wave) return el.wave(key, isLive, isTalking, color)
  const { Text } = el
  return <Text color={color}>{isLive ? (isTalking ? '● ▃▅▇▅▃' : '● ▁▁▁▁▁') : '◌'}</Text>
}

// MARK: pane

export function pane(el: Els, m: ViewModel, act: Actions, prompts: Prompts): RenderElement {
  if (m.phase === 'none') return emptyState(el)
  if (m.phase === 'wrapped' && m.wrap) return wrapUp(el, m, m.wrap, act, prompts)
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
        {isLive ? <Box flexShrink={0}>{recordingMark(el, 'pane-wave', m.phase === 'live', m.isTalking)}</Box> : null}
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
  return (
    <Box
      key={`q-card-${index}`}
      flexDirection="column"
      borderStyle="round"
      borderDimColor
      paddingX={1}
      gap={1}
      hover={{ borderStyle: 'round' }}
    >
      <Text wrap="wrap">{question}</Text>
      <Box flexDirection="row">
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

function wrapUp(el: Els, m: ViewModel, wrap: LiveWrapup, act: Actions, prompts: Prompts): RenderElement {
  const { Box, Button, Markdown, Text } = el
  const people = wrap.speakers.length > 0 ? wrap.speakers.join(', ') : ''
  const meta = [m.when, durationLabel(m.clock), people || (wrap.source === 'saved' ? '' : 'names coming…')]
    .filter(Boolean)
    .join('  ·  ')
  const next = wrap.nextActions ?? []
  const markdown = wrapupMarkdown(wrap, false)
  const button = (key: string, label: string, prompt: string, hotkey: string, isPrimary: boolean) => (
    <Button
      key={key}
      label={m.pending.has(prompt) ? `${label} ✓` : label}
      hotkey={hotkey}
      variant={isPrimary ? 'primary' : 'secondary'}
      dimColor={m.pending.has(prompt)}
      onPress={() => act.ask(prompt)}
    />
  )
  return (
    <Box flexDirection="column" paddingX={1} paddingTop={1}>
      <Text color="green">✓ Wrap-up</Text>
      {header(el, m, wrap.title || 'Call wrap-up', meta, false)}
      {wrap.overview ? (
        <Box marginTop={1}>
          <Text wrap="wrap">{wrap.overview}</Text>
        </Box>
      ) : null}
      <Box marginTop={1}>
        <Markdown key="wrap-md" text={markdown} />
      </Box>
      {next.length > 0 ? (
        <Box flexDirection="column" marginTop={1} gap={1}>
          <Text bold>Claude can do next</Text>
          {next.map((action, index) => {
            const isSent = m.pending.has(action.prompt)
            return (
              <Box
                key={`next-${index}`}
                flexDirection="row"
                alignItems="center"
                gap={1}
                borderStyle="round"
                borderDimColor
                paddingX={1}
              >
                <Box flexGrow={1} flexShrink={1}>
                  <Text wrap="wrap" dimColor={isSent}>
                    {action.label}
                  </Text>
                </Box>
                <Button
                  key={`next-btn-${index}`}
                  label={isSent ? 'Working…' : 'Do it'}
                  hotkey={String(index + 4)}
                  variant="primary"
                  dimColor={isSent}
                  onPress={() => act.ask(action.prompt)}
                />
              </Box>
            )
          })}
        </Box>
      ) : null}
      <Box flexDirection="row" flexWrap="wrap" gap={1} marginTop={1}>
        {button('email', 'Follow-up email', prompts.email, '1', true)}
        {button('todos', 'Todo list', prompts.todos, '2', false)}
        {button('notes', 'Meeting notes', prompts.notes, '3', false)}
        <Button key="copy" label="Copy" hotkey="c" onPress={() => act.copy(wrapupMarkdown(wrap, true))} />
      </Box>
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
    withTitle && wrap.overview ? wrap.overview : '',
    section('Summary', wrap.summary, '- '),
    section('Decisions', wrap.decisions, '- '),
    actionsByOwner(wrap.actions),
    section('Still open', wrap.openQuestions, '- '),
  ]
    .filter(Boolean)
    .join('\n\n')
}
