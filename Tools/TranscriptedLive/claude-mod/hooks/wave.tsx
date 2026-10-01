import type { ClientModule } from 'claude-code'

/**
 * The recording mark: a dot and a small text waveform drawn by the surface on
 * its own frame clock, so it moves smoothly without a redraw of the plugin.
 * The bars move only while someone is mid-sentence; quiet, they lie flat.
 */

type Props = { isLive: boolean; isTalking: boolean; color: string; width?: number; isDotHidden?: boolean }
type State = { frame: number }

const BARS = '▁▂▃▄▅▆▇█'
const DEFAULT_WIDTH = 7
const FRAME_MS = 110

const Wave: ClientModule<Props, State> = (props, surface) => {
  const { Text } = surface.elements
  if (surface.state === undefined) {
    surface.every(FRAME_MS, () => {
      surface.setState({ frame: (surface.state?.frame ?? 0) + 1 })
    })
  }
  const frame = surface.state?.frame ?? 0
  const live = props.isLive
  const dot = live ? (props.isTalking || frame % 14 < 9 ? '●' : '○') : '◌'
  let wave = ''
  const width = Math.max(3, Math.min(48, props.width ?? DEFAULT_WIDTH))
  for (let i = 0; i < width; i++) {
    if (!props.isTalking) {
      wave += BARS[0]
      continue
    }
    // Two sines at different speeds per bar: lively, never a visible loop.
    const level = 0.5 + 0.3 * Math.sin(frame * 0.55 + i * 1.3) + 0.2 * Math.sin(frame * 0.23 + i * 2.1)
    wave += BARS[Math.max(0, Math.min(BARS.length - 1, Math.round(level * (BARS.length - 1))))]
  }
  return (
    <Text>
      {props.isDotHidden ? null : <Text color={props.color}>{`${dot} `}</Text>}
      <Text color={props.color} dimColor={!props.isTalking}>{wave}</Text>
    </Text>
  )
}

export default Wave
