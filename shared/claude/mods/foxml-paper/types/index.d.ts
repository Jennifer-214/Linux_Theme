export type PaperOwner = { sid: string; name: string; pane?: string }
export type PaperFile = { path: string; added: number | null; removed: number | null; own?: boolean; owners?: PaperOwner[]; status?: string }
export type WorkTest = { id: string; state: string; stale?: boolean; changedFiles?: string[] | null; changedDuringRun?: boolean; tests: { passed: number | null; failed: number | null; failures: { filename: string; lnum: number; text: string }[] } }
export type WorkTask = { id: string; text: string; done: boolean }
// estimate: seconds the newest pass of the same command in the same checkout took (running jobs only).
export type WorkJob = { id: string; command: string; title?: string; state: string; elapsed: number; activity: number; session: string; estimate?: number }
export type WorkLook = { tests: WorkTest | null; tasks: WorkTask[]; jobs: WorkJob[]; failures?: WorkJob[] }
export type NotebookView = { page: 'overview' | 'files' | 'project' | 'sessions'; scope: 'session' | 'all'; selected: string; focused?: string; offset: number; form: 'none' | 'task' | 'plan' | 'step' }
export type PaperTree = { path: string; branch: string; status: string; bare?: boolean; sessions: PaperPeer[] }
export type ApiCredits = {
  short: string; headline: string; detail: string; meter: string
  status: string; source: string; remaining_percent: number | null; as_of: string | null
  projects: { id: string; label: string; spent_usd: string | null; detail: string }[]
}

// What the notebook shows, refreshed after edits and every little while.
export type PaperLook = {
  branch: string
  root: string
  session: string
  files: PaperFile[]
  // open: this session is approved in the repo's plan gate; closed: the gate exists and it is not.
  gate: 'open' | 'closed' | 'none'
  plan: { title: string; file: string; pinned?: boolean; step?: string; done?: number; total?: number } | null
  // Last night's /goodnight note for this project, while it is fresh (under 36 hours).
  lastNight?: { file: string; line: string } | null
  project?: { trees: PaperTree[]; documents: { path: string; label: string }[] }
  context: number | null
  // Other live sessions editing in this repo (from the shared edits ledgers).
  neighbours: { sid: string; title: string; files: number }[]
  // A card another mod left for this session (cards/<session>.json).
  card: PaperCard | null
  work: WorkLook | null
  credits?: ApiCredits | null
}

export type PaperTone = 'ink' | 'dim' | 'heart' | 'berry' | 'ribbon' | 'added' | 'removed'
export type PaperCard = {
  title: string
  rows: { mark?: string; text: string; tone?: PaperTone; action?: PaperAction }[]
  alert?: { text: string; tone?: PaperTone } | null
}
export type PaperAction = { kind: 'file' | 'file-diff' | 'log' | 'tests' | 'compare'; file?: string; id?: string }

export type PaperOverlap = { path: string; title: string; ago: string; pane?: string }

export type PaperRedZone = { what: string }

// Another live Claude on this machine, as fox-drawer's Agents page sees it (fox-drawer claude-peers).
// A note that reached this session: from you in nvim, or from another Claude.
export type PaperEnvelope = { id?: string; from: string; text: string; at: number }

export type PaperPeer = { id: string; name: string; project: string; state: string; busy: boolean; pane: string }

declare module 'claude-code' {
  interface PluginState {
    'foxml-paper': {
      look: Shaped<PaperLook | null>
      title: string | null
      redZone: Shaped<PaperRedZone | null>
      overlap: Shaped<PaperOverlap | null>
      peers: Shaped<PaperPeer[]>
      // The peer a note is being written to, by session id.
      writingTo: string | null
      envelopes: Shaped<PaperEnvelope[]>
      notebookView: Shaped<NotebookView>
    }
  }
}
