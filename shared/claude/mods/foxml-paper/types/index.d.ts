export type PaperFile = { path: string; added: number; removed: number }

// What the notebook shows, refreshed after edits and every little while.
export type PaperLook = {
  branch: string
  files: PaperFile[]
  // open: this session is approved in the repo's plan gate; closed: the gate exists and it is not.
  gate: 'open' | 'closed' | 'none'
  plan: { title: string; file: string } | null
  context: number | null
}

export type PaperRedZone = { what: string }

declare module 'claude-code' {
  interface PluginState {
    'foxml-paper': {
      look: Shaped<PaperLook | null>
      title: string | null
      redZone: Shaped<PaperRedZone | null>
    }
  }
}
