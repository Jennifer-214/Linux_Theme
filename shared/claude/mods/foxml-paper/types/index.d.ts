export type PaperOwner = { sid: string; name: string; pane?: string }
export type PaperFile = { path: string; added: number | null; removed: number | null; own?: boolean; owners?: PaperOwner[]; status?: string }
export type WorkTest = { id: string; state: string; ended?: number; stale?: boolean; changedFiles?: string[] | null; changedDuringRun?: boolean; tests: { passed: number | null; failed: number | null; failures: { filename: string; lnum: number; text: string }[] } }
// Where the checkout stands against its upstream (null upstream: never pushed), and how many worktrees it has.
export type GitLook = { upstream: string | null; ahead: number; behind: number; trees: number }
// One GitHub Actions run of the pushed commit (gh run list --json).
export type CiRun = { name?: string; workflowName?: string; status: string; conclusion: string; url?: string }
export type CiLook = { sha: string; runs: CiRun[]; at: number }
// seen: the last sign of life in the turn (its start, a tool call); a turn that went quiet is not shown as working.
export type TurnLook = { started: number; step: string; seen?: number }
export type WorkTask = { id: string; text: string; done: boolean }
// estimate: seconds the newest pass of the same command in the same checkout took (running jobs only).
export type WorkJob = { id: string; command: string; title?: string; state: string; elapsed: number; activity: number; session: string; estimate?: number }
// Review progress from desk-work, per review (a commit sha, a session id or "working"): each checked file is
// "checked", or "changed" when it was edited after it was read.
export type ReviewProgress = { files: Record<string, { state: 'checked' | 'changed'; at: number }>; checked: number; changed: number; total: number; completed: boolean; at: number }
export type WorkLook = { tests: WorkTest | null; tasks: WorkTask[]; jobs: WorkJob[]; failures?: WorkJob[]; review?: Record<string, ReviewProgress>; pending?: number }
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
  git?: GitLook | null
  // The pushed commit's GitHub Actions runs, when the repo is on GitHub and gh is set up.
  ci?: CiLook | null
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

// Another live Claude on this machine, as desk-drawer's Agents page sees it (desk-drawer claude-peers).
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
      // After a turn that left files of this session unreviewed: how many, until looked at or dismissed.
      nudge: number | null
      // The turn under way: when your message came, and the latest step Claude described.
      turn: Shaped<TurnLook | null>
    }
  }
}
