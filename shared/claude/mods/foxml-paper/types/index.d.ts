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
// What a finished turn left behind, shown as one card: this session's files it changed, the tests it ran, the commits
// it made and anything in the red zone it touched.
export type TurnReceipt = { at: number; files: string[]; tests: string | null; commits: { sha: string; subject: string }[]; risky: string[] }
export type WorkTask = { id: string; text: string; done: boolean }
// estimate: seconds the newest pass of the same command in the same checkout took (running jobs only).
export type WorkJob = { id: string; command: string; title?: string; state: string; elapsed: number; activity: number; session: string; estimate?: number }
// Review progress from desk-work, per review (a commit sha, a session id or "working"): each checked file is
// "checked", or "changed" when it was edited after it was read.
export type ReviewProgress = { files: Record<string, { state: 'checked' | 'changed'; at: number }>; checked: number; changed: number; total: number; completed: boolean; at: number }
export type AttentionItem = { id: string; kind: 'job' | 'agent' | 'request' | 'changed' | 'commit' | 'records'; root: string; label: string; why: string; at: number; file?: string; sha?: string; run?: string; action: { kind: string; id?: string; file?: string; key?: string } }
export type AgentSession = { key: string; id: string; agent: string; name: string; root: string; project: string; state: string; busy: boolean; pane: string; canMessage: boolean; files: string[]; attribution: string }
export type WorkEvent = { id: string; seq: number; kind: string; root: string; at: number; label: string; state?: string; file?: string; action: { kind: string; id?: string; file?: string } }
export type WorkDigest = { total: number; files: number; through: number; truncated: boolean; counts: Record<string, number>; events: WorkEvent[]; summary?: string; since?: string; greeting?: string }
export type WorkHealth = { status: string; checks: { id: string; label: string; detail: string; transaction?: string; recoverable?: boolean }[] }
export type WorkLook = { tests: WorkTest | null; tasks: WorkTask[]; jobs: WorkJob[]; failures?: WorkJob[]; review?: Record<string, ReviewProgress>; pending?: number; requests?: ReviewRequest[]; attention?: AttentionItem[]; agents?: AgentSession[]; revision?: string; timeline?: WorkEvent[]; digest?: WorkDigest; health?: WorkHealth; integration?: { status: string; message: string; sessions?: WorkSession[] }
  // Records desk-work cannot read (it refuses writes to them until they are set aside), and commits finished today.
  records?: { file: string; label: string; why: string }[]; reviewedToday?: string[]
  // Commits set aside to review later: how many, and when.
  aside?: { count: number; at: number } | null }
// A session's loaded code against what is installed; reload: the steps that load it while keeping its work.
export type WorkSession = { client: string; status: string; session?: string; reload?: string }
// A change request sent to a session about a file: waiting while the file is as it was, ready once it has changed.
export type ReviewRequest = { file: string; name: string; sid: string; text: string; at: number; state: 'waiting' | 'ready' }
export type NotebookView = { page: 'overview' | 'files' | 'project' | 'sessions' | 'help' | 'request' | 'timeline' | 'digest' | 'health' | 'attention'; scope: 'session' | 'all'; selected: string; focused?: string; offset: number; form: 'none' | 'task' | 'plan' | 'step' | 'search' | 'snooze' | 'aside'
  // The files page: which files to list, and a part of a name to find.
  show?: 'all' | 'unreviewed' | 'changed'; query?: string
  // The request page: which file's thread is open.
  request?: string; compact?: boolean; adaptive?: boolean }
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
  plan: { title: string; file: string; pinned?: boolean; step?: string; done?: number; total?: number; next?: string } | null
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

export type PaperPeer = { id: string; name: string; project: string; state: string; busy: boolean; pane: string; agent?: string; canMessage?: boolean; root?: string; files?: string[] }

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
      receipt: Shaped<TurnReceipt | null>
      // The turn under way: when your message came, and the latest step Claude described.
      turn: Shaped<TurnLook | null>
    }
  }
}
