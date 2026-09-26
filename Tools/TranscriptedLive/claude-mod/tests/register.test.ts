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

function sessionJson(state: 'recording' | 'ended'): string {
  const now = new Date().toISOString()
  return JSON.stringify({
    state,
    meetingId: 'meeting_test',
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

type World = { statuses: (string | undefined)[]; opened: string[] }

/** The helper's files and the engine calls the mod makes, answered from memory. */
function world(on: On, state: 'recording' | 'ended' = 'recording'): World {
  const seen: World = { statuses: [], opened: [] }
  const files: Record<string, string> = {
    [`${ROOT}/session.json`]: sessionJson(state),
    [JSONL_PATH]: UTTERANCES.map(line => JSON.stringify(line)).join('\n') + '\n',
  }

  mock.env(on, { HOME: '/Users/test', TRANSCRIPTED_LIVE_DIR: ROOT })
  mock.clock(on)
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
    return { value: undefined }
  })
  return seen
}

describe('register', () => {
  test('a live meeting pins a status line and opens the pane once', async ($, on) => {
    const seen = world(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await $.command.run({ command: 'meeting', args: 'status', ...COMPOSER })

    expect(seen.statuses.at(-1)).toBe('● 06:50 · /meeting attach')
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

    expect(seen.statuses.at(-1)).toBe('○ ended · /meeting attach')
    expect(seen.opened).toEqual([])
  })
})
