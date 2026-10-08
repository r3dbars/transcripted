import type { On } from 'claude-code'
import { describe, expect, mock, test, tier } from 'claude-code/testing'

tier('user')

const ROOT = '/live'
const BIN = '/opt/test/transcripted-live'

/** An idle helper's session.json, last written `ageMs` before now. */
function idleSession(ageMs: number): string {
  return JSON.stringify({
    state: 'idle',
    model: 'parakeet-eou 320ms',
    updatedAt: new Date(Date.now() - ageMs).toISOString(),
    lineCount: 0,
    audioSeconds: 0,
    partial: {},
    pid: 1,
  })
}

type Spawned = { argv: readonly string[]; env?: Record<string, string> }

/** The helper's files and a fake process noun that records each spawn. */
function world(on: On, ageMs: number) {
  const spawned: Spawned[] = []
  const files: Record<string, string> = { [`${ROOT}/session.json`]: idleSession(ageMs) }
  mock.env(on, { HOME: '/Users/test', TRANSCRIPTED_LIVE_DIR: ROOT, TRANSCRIPTED_LIVE_BIN: BIN })
  const clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.register', ($, e) => ({ value: { tool: `mcp__transcripted-live__${e.name}` } }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('fs.list', () => ({ value: [] as never }))
  on('fs.exists', ($, e) => ({ value: e.path === BIN || files[e.path] !== undefined }))
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
  on('ui.status', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('ui.panes', () => ({ value: [] }))
  on('process.spawn', async function* ($, e) {
    spawned.push({ argv: e.argv, env: e.env })
    return { value: { code: 0, signal: null } }
  })
  return { spawned, clock }
}

describe('helper supervisor', () => {
  test('an idle helper that heartbeats every ~4 s is left alone', async ($, on) => {
    const { spawned, clock } = world(on, 4_500)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await clock.advance(2_000)

    expect(spawned).toEqual([])
  })

  test('a silent helper is restarted, told to exit with its parent', async ($, on) => {
    const { spawned, clock } = world(on, 20_000)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await clock.advance(2_000)

    expect(spawned.length).toBe(1)
    expect(spawned[0]?.argv).toEqual([BIN, 'watch'])
    expect(spawned[0]?.env?.TRANSCRIPTED_LIVE_EXIT_WITH_PARENT).toBe('1')
    expect(spawned[0]?.env?.TRANSCRIPTED_DISABLE_FILE_LOGGER).toBe('1')
  })
})
