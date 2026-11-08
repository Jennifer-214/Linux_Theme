export type PaperFile = { path: string; added: number; removed: number }

// What the notebook shows, refreshed after edits and every little while.
export type PaperLook = {
  branch: string
  files: PaperFile[]
  // open: this session is approved in the repo's plan gate; closed: the gate exists and it is not.
  gate: 'open' | 'closed' | 'none'
  plan: { title: string; file: string } | null
  context: number | null
  // Other live sessions editing in this repo (from the shared edits ledgers).
  neighbours: { title: string; files: number }[]
  // A card another mod left for this session (cards/<session>.json).
  card: PaperCard | null
}

export type PaperTone = 'ink' | 'dim' | 'heart' | 'berry' | 'ribbon' | 'added' | 'removed'
export type PaperCard = {
  title: string
  rows: { mark?: string; text: string; tone?: PaperTone }[]
  alert?: { text: string; tone?: PaperTone } | null
}

export type PaperOverlap = { path: string; title: string; ago: string; pane?: string }

export type PaperRedZone = { what: string }

declare module 'claude-code' {
  interface PluginState {
    'foxml-paper': {
      look: Shaped<PaperLook | null>
      title: string | null
      redZone: Shaped<PaperRedZone | null>
      overlap: Shaped<PaperOverlap | null>
    }
  }
}
