/** What the live helper last made of the call. */
export type LiveNotes = {
  meetingId: string
  /** Audio clock of the newest line the notes cover. */
  upTo: number
  /** A short name for the call, so the pane has a real title. */
  title?: string
  gist: string
  questions: string[]
  actions: string[]
  say: string
}

/** The after-call wrap-up: from the live text first, then from the saved transcript. */
export type LiveWrapup = {
  meetingId: string
  source: 'live' | 'saved'
  title: string
  summary: string[]
  decisions: string[]
  actions: string[]
  openQuestions: string[]
  /** Named speakers in the saved transcript; empty for the live wrap-up. */
  speakers: string[]
  /** Every speaker label the saved transcript had; a rename in Transcripted changes it. */
  speakerKey?: string
  /** One sentence on what the call was. */
  overview?: string
  /** Things Claude could do next for the person, each a button. */
  nextActions?: LiveNextAction[]
}

/** A task the wrap-up offers to hand Claude: a short label and the prompt it sends. */
export type LiveNextAction = { label: string; prompt: string }

declare module 'claude-code' {
  interface PluginState {
    'transcripted-live': {
      sentUpTo: Record<string, number>
      notes: LiveNotes | null
      wrapups: Record<string, LiveWrapup>
    }
  }
}
