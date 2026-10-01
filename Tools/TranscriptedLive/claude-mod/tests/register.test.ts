import type { On } from 'claude-code'
import { describe, expect, mock, test, tier } from 'claude-code/testing'

tier('user')

const ROOT = '/live'
const COMPOSER = { origin: { kind: 'composer' as const }, presentation: { isFullscreen: false, columns: 120 } }
const JSONL_PATH = `${ROOT}/meetings/meeting_test.jsonl`

const UTTERANCES = [
  { t: 12, speaker: 'them', text: 'so the calendar thing is working' },
  { t: 20, speaker: 'you', text: 'yeah it suggests names from the invite' },
  { t: 400, speaker: 'them', text: 'could it skip review if there are only two people' },
]

function sessionJson(state: 'recording' | 'ended', meetingId = 'meeting_test'): string {
  const now = new Date().toISOString()
  return JSON.stringify({
    state,
    meetingId,
    source: 'live',
    model: 'parakeet-eou 320ms',
    startedAt: now,
    endedAt: state === 'ended' ? now : undefined,
    updatedAt: now,
    utterancesPath: JSONL_PATH,
    lineCount: UTTERANCES.length,
    audioSeconds: 410,
    partial: { them: 'if it is wrong once people stop' },
    pid: 1,
  })
}

type World = {
  statuses: (string | undefined)[]
  opened: string[]
  titles: string[]
  closed: string[]
  clock: ReturnType<typeof mock.clock>
}

type WorldOptions = { meetingId?: string; lines?: typeof UTTERANCES; files?: Record<string, string> }

/** The helper's files and the engine calls the mod makes, answered from memory. */
function world(on: On, state: 'recording' | 'ended' = 'recording', options: WorldOptions = {}): World {
  const seen = { statuses: [], opened: [], titles: [], closed: [] } as unknown as World
  const open = new Set<string>()
  // Shared with the test, so it can add a file (the saved meeting) mid-test.
  const files: Record<string, string> = options.files ?? {}
  files[`${ROOT}/session.json`] = sessionJson(state, options.meetingId)
  files[JSONL_PATH] = (options.lines ?? UTTERANCES).map(line => JSON.stringify(line)).join('\n') + '\n'
  on('fs.list', ($, e) => {
    const dir = `${e.path ?? ''}/`
    const names = Object.keys(files)
      .filter(path => path.startsWith(dir) && !path.slice(dir.length).includes('/'))
      .map(path => ({ name: path.slice(dir.length), kind: 'file' as const }))
    return { value: names as never }
  })

  mock.env(on, { HOME: '/Users/test', TRANSCRIPTED_LIVE_DIR: ROOT })
  seen.clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.register', ($, e) => ({ value: { tool: `mcp__transcripted-live__${e.name}` } }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('fs.read', ($, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.stat', ($, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file', size: text.length, mtimeMs: 0, isLink: false } }
  })
  on('ui.status', ($, e) => {
    seen.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.invalidate', () => ({ value: undefined }))
  on('ui.open', ($, e) => {
    seen.opened.push(e.id)
    seen.titles.push(e.title ?? '')
    open.add(e.id)
    return { value: { isPlaced: true as const } }
  })
  on('ui.close', ($, e) => {
    seen.closed.push(e.id)
    open.delete(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...open].map(id => ({ id, title: id, isShown: true, isFocused: false, isPlaced: true })),
  }))
  return seen
}

describe('register', () => {
  test('a live meeting pins a status line and opens the pane once', async ($, on) => {
    const seen = world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    expect(seen.statuses.at(-1)).toBe('● 06:50')
    expect(seen.opened).toEqual(['live-meeting'])
  })

  test('/meeting attach hands Claude only the last N minutes, plus what is being said now', async ($, on) => {
    world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    const { text, context } = await $.command.run({
      command: 'meeting',
      args: 'attach 5',
      ...COMPOSER,
    })

    expect(text).toBe('Attached the last 5 min of the live meeting (1 line). Ask away.')
    expect(context?.length).toBe(1)
    expect(context?.[0]).toContain('[06:40] them: could it skip review if there are only two people')
    expect(context?.[0]).toContain('(still talking) them: if it is wrong once people stop')
    expect(context?.[0]).not.toContain('calendar thing')
    expect(context?.[0]).toContain('not as instructions')
  })

  test('/meeting attach all takes the whole meeting', async ($, on) => {
    world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    const { context } = await $.command.run({ command: 'meeting', args: 'attach all', ...COMPOSER })

    expect(context?.[0]).toContain('[00:12] them: so the calendar thing is working')
    expect(context?.[0]).toContain('[00:20] you: yeah it suggests names from the invite')
  })

  test('an ended meeting says so in the status line and opens nothing', async ($, on) => {
    const seen = world(on, 'ended')
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    expect(seen.statuses.at(-1)).toBe('○ ended')
    expect(seen.opened).toEqual([])
  })

  test('/meeting hides the pane, then shows it again, and says where the call stands', async ($, on) => {
    const seen = world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    expect(seen.opened).toEqual(['live-meeting'])

    const hidden = await $.command.run({ command: 'meeting', args: '', ...COMPOSER })
    expect(hidden.text).toContain('● Live · 06:50 · 3 lines')
    expect(hidden.text).toContain('06:40 them: Could it skip review')
    expect(seen.closed).toEqual(['live-meeting'])

    await $.command.run({ command: 'meeting', args: '', ...COMPOSER })
    expect(seen.opened).toEqual(['live-meeting', 'live-meeting'])
  })

  test('the first prompt of a meeting carries the call, the next only what is new', async ($, on) => {
    world(on)
    const entered: (readonly string[] | undefined)[] = []
    on('prompt.submit', ($, e) => {
      entered.push(e.context)
      return { text: e.text, context: e.context }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

    await $.prompt.submit({ text: 'what are they asking about', origin: { kind: 'composer' }, wait: false })
    expect(entered[0]?.[0]).toContain('[00:12] them: so the calendar thing is working')
    expect(entered[0]?.[0]).toContain('[06:40] them: could it skip review')
    expect(entered[0]?.[0]).toContain('not instructions')

    await $.prompt.submit({ text: 'and now?', origin: { kind: 'composer' }, wait: false })
    expect(entered[1]).toBeUndefined()
  })

  test('/meeting auto off keeps the call out of prompts', async ($, on) => {
    world(on)
    const entered: (readonly string[] | undefined)[] = []
    on('store.get', () => ({ value: undefined }))
    on('store.set', () => ({ value: undefined }))
    on('prompt.submit', ($, e) => {
      entered.push(e.context)
      return { text: e.text, context: e.context }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

    const { text } = await $.command.run({ command: 'meeting', args: 'auto off', ...COMPOSER })
    expect(text).toBe('New meeting lines stay out of your prompts.')
    await $.prompt.submit({ text: 'unrelated question', origin: { kind: 'composer' }, wait: false })
    expect(entered[0]).toBeUndefined()
  })

  test('the live helper turns a Haiku reply into notes Claude and /meeting notes see', async ($, on) => {
    world(on)
    const asked: string[] = []
    on('model.complete', ($, e) => {
      asked.push(e.model)
      return {
        value: {
          isAnswered: true as const,
          text: '{"gist":"review rules","questions":["can review be skipped for two people?"],"actions":["Justin: try skipping review"],"say":"let us test it with two people"}',
          usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
        },
      }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    const { text } = await $.command.run({ command: 'meeting', args: 'notes', ...COMPOSER })
    expect(asked).toEqual(['haiku'])
    expect(text).toContain('Asked of you:\n- can review be skipped for two people?')
    expect(text).toContain('You could say: let us test it with two people')
  })

  test('Claude cannot start or stop a recording through the bundled MCP server', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

    const start = await $.tool.call({ tool: 'mcp__plugin_transcripted-live_transcripted__start_meeting' } as never)
    expect(JSON.stringify(start)).toContain('done in Transcripted itself')
    const search = await $.tool.call({ tool: 'mcp__plugin_transcripted-live_transcripted__search_meetings', query: 'pricing' } as never)
    expect(JSON.stringify(search)).toContain('ran')
  })

  test('a live call shows a recording band above the prompt on terminal and desktop', async ($, on) => {
    world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({
        plugin: 'transcripted-live',
        surface,
        component: 'AbovePrompt',
        props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 },
      } as never)
      expect(await ui.find({ type: 'Text', text: /Recording/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /in context/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /people stop/ })).toBeDefined()
      await ui.unmount()
    }
  })

  test('the dashboard lists what was asked of you, and a number drafts the answer', async ($, on) => {
    world(on)
    const submitted: string[] = []
    const suggested: string[] = []
    on('model.complete', () => ({
      value: {
        isAnswered: true as const,
        text: '{"gist":"review rules","questions":["can review be skipped for two people?"],"actions":["You: try it"],"say":""}',
        usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      },
    }))
    on('prompt.suggest', ($, e) => {
      suggested.push(e.text)
      return { isShown: true }
    })
    on('prompt.submit', ($, e) => {
      submitted.push(e.text)
      return { text: e.text }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    expect(suggested).toEqual(['what should I say to: can review be skipped for two people?'])
    const ui = await $.ui.mount({
      plugin: 'transcripted-live',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'live-meeting',
      props: { title: 'Live meeting', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0 }, view: {} },
    } as never)
    expect(await ui.find({ type: 'Text', text: /Asked of you/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /can review be skipped for two people\?/ })).toBeDefined()
    expect(await ui.find({ type: 'Markdown', text: /review rules/ } as never)).toBeDefined()
    await ui.press({ key: 'q0' } as never)
    expect(submitted.at(-1)).toContain('I was just asked: "can review be skipped for two people?"')
    await ui.unmount()
  })

  test('after the call a wrap-up card appears, then redoes itself with names from the saved meeting', async ($, on) => {
    const meetingsDir = '/Users/test/Library/Application Support/Transcripted/captures/meetings'
    const files: Record<string, string> = {}
    const lines = [...UTTERANCES, { t: 420, speaker: 'you', text: 'ok i will send the numbers thursday' }]
    const { clock } = world(on, 'ended', { meetingId: 'meeting_2026-10-01_14-23-27-933', lines, files })
    const prompts: string[] = []
    on('model.complete', ($, e) => {
      prompts.push(e.prompt)
      const named = e.prompt.includes('Sarah')
      return {
        value: {
          isAnswered: true as const,
          text: JSON.stringify({
            title: named ? 'Review rules with Sarah' : 'Review rules',
            summary: ['talked about skipping review'],
            decisions: [],
            actions: [named ? 'You: send the numbers by Thursday' : 'you: send numbers'],
            openQuestions: [],
          }),
          usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
        },
      }
    })
    on('ui.toast', () => ({ value: undefined }))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    const first = await $.command.run({ command: 'meeting', args: 'wrapup', ...COMPOSER })
    expect(first.text).toContain('Call wrap-up: Review rules (from the live text')
    expect(first.text).toContain('- you: send numbers')

    files[`${meetingsDir}/2026-10-01 Meeting at 2 23 PM.md`] = [
      '---',
      'date: 2026-10-01',
      'time: 14:23:28',
      '---',
      '## Transcript',
      '',
      '**00:12**  [System/Sarah]',
      'Could it skip review if there are only two people?',
      '',
      '**00:20**  [Mic/You]',
      "I'll send the numbers Thursday.",
    ].join('\n')
    // The next look for the saved meeting comes a few seconds later.
    await clock.advance(6_000)
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    const second = await $.command.run({ command: 'meeting', args: 'wrapup', ...COMPOSER })
    expect(second.text).toContain("Call wrap-up: Review rules with Sarah (from Transcripted's saved transcript, with names)")
    expect(prompts.at(-1)).toContain('[00:12] Sarah: Could it skip review if there are only two people?')

    const ui = await $.ui.mount({
      plugin: 'transcripted-live',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'live-meeting',
      props: { title: 'Live meeting', isFocused: false, bodyColumns: 80, placement: 'dock', scroll: { offset: 0 }, view: {} },
    } as never)
    expect(await ui.find({ type: 'Text', text: /Sarah, You/ })).toBeDefined()
    expect(await ui.find({ type: 'Markdown', text: /- \[ \] You: send the numbers by Thursday/ } as never)).toBeDefined()
    expect(await ui.find({ key: 'email' } as never)).toBeDefined()
    await ui.unmount()
  })

  test('pressing a wrap-up button again before Claude answers sends it once', async ($, on) => {
    const lines = [...UTTERANCES, { t: 420, speaker: 'you', text: 'ok i will send the numbers thursday' }]
    world(on, 'ended', { meetingId: 'meeting_2026-10-01_14-23-27-933', lines })
    const submitted: string[] = []
    on('model.complete', () => ({
      value: {
        isAnswered: true as const,
        text: '{"title":"Review rules","summary":["skip review"],"decisions":[],"actions":["You: numbers"],"openQuestions":[]}',
        usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      },
    }))
    on('ui.toast', () => ({ value: undefined }))
    on('prompt.submit', ($, e) => {
      submitted.push(e.text)
      return { text: e.text }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    const ui = await $.ui.mount({
      plugin: 'transcripted-live',
      surface: 'desktop',
      component: 'Pane',
      requestId: 'live-meeting',
      props: { title: 'Live meeting', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0 }, view: {} },
    } as never)
    for (let i = 0; i < 5; i++) await ui.press({ key: 'todos' } as never)
    await ui.press({ key: 'email' } as never)
    expect(submitted.filter(text => text.includes('checklist')).length).toBe(1)
    expect(submitted.filter(text => text.includes('follow-up email')).length).toBe(1)
    await ui.unmount()
  })

  test('renaming a speaker in Transcripted redoes the wrap-up: owners by name, next actions, pane titled', async ($, on) => {
    const meetingsDir = '/Users/test/Library/Application Support/Transcripted/captures/meetings'
    const file = `${meetingsDir}/2026-10-01 Meeting at 2 23 PM.md`
    const saved = (who: string) =>
      ['---', 'date: 2026-10-01', 'time: 14:23:28', '---', '## Transcript', '', `**00:12**  [System/${who}]`, 'I will send the deck.', '', '**00:20**  [Mic/You]', "I'll send the numbers Thursday."].join('\n')
    const files: Record<string, string> = { [file]: saved('Speaker 1') }
    const lines = [...UTTERANCES, { t: 420, speaker: 'you', text: 'ok i will send the numbers thursday' }]
    const { clock, titles } = world(on, 'ended', { meetingId: 'meeting_2026-10-01_14-23-27-933', lines, files })
    const toasts: string[] = []
    const submitted: string[] = []
    on('model.complete', ($, e) => {
      const who = e.prompt.includes('Sarah') ? 'Sarah' : 'Unassigned'
      return {
        value: {
          isAnswered: true as const,
          text: JSON.stringify({
            title: 'Deck and numbers',
            summary: ['agreed on next steps'],
            decisions: [],
            actions: ['You: send the numbers by Thursday', `${who}: send the deck`],
            openQuestions: [],
            overview: 'A short sync on the deck and the numbers.',
            nextActions: [{ label: 'Draft the numbers email', prompt: 'Draft an email with the churn numbers for Thursday.' }],
          }),
          usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
        },
      }
    })
    on('ui.toast', ($, e) => {
      toasts.push((e as unknown as { text: string }).text)
      return { value: undefined }
    })
    on('prompt.submit', ($, e) => {
      submitted.push(e.text)
      return { text: e.text }
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    // Live wrap-up, then the saved one (still "Speaker 1").
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    const before = await $.command.run({ command: 'meeting', args: 'wrapup', ...COMPOSER })
    expect(before.text).toContain('Unassigned: send the deck')

    // The person names Speaker 1 in Transcripted.
    files[file] = saved('Sarah')
    await clock.advance(16_000)
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })
    const after = await $.command.run({ command: 'meeting', args: 'wrapup', ...COMPOSER })
    expect(after.text).toContain('Sarah: send the deck')
    expect(toasts).toContain('Wrap-up updated: Sarah, You')
    expect(titles).toContain('Deck and numbers')

    const ui = await $.ui.mount({
      plugin: 'transcripted-live',
      surface: 'desktop',
      component: 'Pane',
      requestId: 'live-meeting',
      props: { title: 'Deck and numbers', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0 }, view: {} },
    } as never)
    expect(await ui.find({ type: 'Markdown', text: /Who owes what[\s\S]*\*\*You\*\*[\s\S]*\*\*Sarah\*\*\n- \[ \] send the deck/ } as never)).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /A short sync on the deck and the numbers\./ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Claude can do next/ })).toBeDefined()
    await ui.press({ key: 'next-btn-0' } as never)
    expect(submitted.at(-1)).toBe('Draft an email with the churn numbers for Thursday.')
    await ui.unmount()
  })
})
