/**
 * desk-notify — desktop notices from pi, through notify-send (mako / dunst):
 *
 *   a run of 15 s or more settled            pi is ready              📁 <project> · Ns
 *   a run settled on an error (any length)    pi stopped on an error   📁 <project>
 *   a select / confirm dialog open for 5 s    pi needs your yes        📁 <project>      (critical: mako keeps it 15 s)
 *   …right after the plan gate's hint          pi needs approval        📁 <project>      (critical)
 *
 * A run she stopped (Escape) pings nothing: she is there. Only in the terminal UI — never for pi -p, RPC or json runs
 * (subagents, an editor's own pi). pi's examples/extensions/notify.ts writes OSC 99/777 escapes, which tmux swallows
 * (kitty → tmux → pi); notify-send goes to mako directly.
 *
 * A notice never carries a dialog's title or any command text: a title can hold a command, and mako keeps a history.
 * Both strings start with a fixed emoji, so a project named "-x" can never be read as an option.
 */

import { basename } from "node:path";
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { BUILD_ID } from './foxml/build.ts';

export function makeNotify({ delayMs = 5000, minSecs = 15, hintMs = 1000 } = {}) {
	return function (pi: ExtensionAPI) {
		// Read while the session is live (session_start, agent_start): in print mode (pi -p, a subagent's child) the
		// session is torn down as the answer ends, and touching that ctx afterwards throws ("This extension ctx is
		// stale…"). No handler below reads its ctx.
		let tui = false;
		let project = "";
		let projectPath = "";
		let started = 0;
		let outcome: string | undefined; // agent_before_settle's: completed | aborted | error
		let timer: ReturnType<typeof setTimeout> | undefined;
		let hintAt = 0; // when the plan gate said its next dialog asks for approval

		const look = (ctx: { hasUI: boolean; mode: string; cwd: string }) => {
			tui = ctx.hasUI && ctx.mode === "tui";
			project = basename(ctx.cwd || "") || "pi";
			projectPath = ctx.cwd || "";
		};
		const send = (summary: string, body: string, critical = false) =>
			pi
				.exec("work-notice", ["agent", "pi", summary, `Project · ${body}`, projectPath, process.env.TMUX_PANE || "", critical ? "notification" : "stop"])
				.catch(() => {}); // no notify-send, no daemon: a notice is a courtesy, never an error in her session
		const clear = () => {
			if (timer) clearTimeout(timer);
			timer = undefined;
		};

		pi.on("session_start", async (_event, ctx) => look(ctx));
		pi.on("agent_start", async (_event, ctx) => {
			started = Date.now();
			outcome = undefined;
			look(ctx);
		});
		pi.on("agent_before_settle", async (event) => {
			outcome = event.outcome; // read only: returning nothing changes nothing at this boundary
		});
		// once per run, after any retry, compaction or queued follow-up — agent_end fires per loop, so a retry pinged twice
		pi.on("agent_settled", async (event) => {
			if (!tui || event.aborted || outcome === "aborted") return;
			if (outcome === "error") return void (await send("pi stopped on an error", project));
			const secs = Math.round((Date.now() - started) / 1000);
			if (secs < minSecs) return; // quick replies don't need a ping
			await send("pi is ready", `${project} · ${secs}s`);
		});

		pi.events.on("fox:approval", () => {
			hintAt = Date.now();
		});
		// pi merges nested dialogs itself (one start for the outermost, one end when the last closes); a start while the
		// timer is armed keeps it
		pi.on("ui_prompt_start", async (event) => {
			const approval = hintAt > 0 && Date.now() - hintAt <= hintMs;
			hintAt = 0; // a hint is for the next dialog only
			if (!tui || (event.kind !== "select" && event.kind !== "confirm") || timer) return;
			timer = setTimeout(() => {
				timer = undefined;
				void send(approval ? "pi needs approval" : "pi needs your yes", project, true);
			}, delayMs);
			timer.unref?.(); // never keeps pi alive
		});
		pi.on("ui_prompt_end", async () => clear());
		pi.on("session_shutdown", async () => clear()); // quit, reload, new, resume, fork
	};
}

type WorkCall = (args: string[], input?: string) => Promise<string | null>;
const workCall: WorkCall = (args, input) => new Promise(resolve => {
  const child = spawn('desk-work', args, { stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '', done = false;
  const finish = (result: string | null) => { if (!done) { done = true; clearTimeout(timer); resolve(result) } };
  const timer = setTimeout(() => { child.kill(); finish(null) }, 5000);
  child.on('error', () => finish(null));
  child.stdin.on('error', () => {});
  child.stdout.on('data', chunk => { if (output.length < 1024 * 1024) output += chunk.toString() });
  child.on('close', code => finish(code === 0 ? output : null));
  child.stdin.end(input ?? '');
});

// Copy session identity while its context is live. End-of-turn hooks must not dereference a stale pi context.
export function makeWork(call: WorkCall = workCall) {
  return (pi: ExtensionAPI) => {
    let identity: { id: string; root: string; title: string } | null = null;
    let outcome = '', busy = false;
    const jobs = new Map<string, string>();
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    const publish = (state: string, file?: string, who = identity) => who ? call([
      'agent-update', '--root', who.root, '--agent', 'pi', '--session', who.id, '--title', who.title,
      '--pid', String(process.pid), '--pane', process.env.TMUX_PANE || '', '--state', state, '--build', BUILD_ID,
      ...(file ? ['--file', file] : []),
    ]) : Promise.resolve(null);
    const remember = async (ctx: ExtensionContext) => {
      const next = { id: ctx.sessionManager.getSessionId(), root: ctx.cwd,
        title: ctx.sessionManager.getSessionName() || basename(ctx.cwd) || 'pi' };
      if (identity && (identity.id !== next.id || identity.root !== next.root)) await publish('done');
      identity = next;
    };
    const finishJobs = async () => {
      for (const id of jobs.values()) await call(['finish', '--id', id, '--exit', '130']);
      jobs.clear();
    };
    pi.on('session_start', async (_event, ctx) => {
      await remember(ctx); await publish('waiting');
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = setInterval(() => {
        if (identity) void call(['agent-heartbeat', '--root', identity.root, '--agent', 'pi', '--session', identity.id, '--pid', String(process.pid)]);
      }, 60000);
      heartbeat.unref?.();
    });
    pi.on('agent_start', async (_event, ctx) => { await remember(ctx); outcome = ''; busy = true; await publish('working') });
    pi.on('agent_before_settle', event => { outcome = event.outcome });
    pi.on('agent_settled', async () => { busy = false; await finishJobs(); await publish(outcome === 'error' ? 'error' : 'waiting') });
    pi.on('ui_prompt_start', async () => { await publish('needs') });
    pi.on('ui_prompt_end', async () => { await publish(busy ? 'working' : 'waiting') });
    const overlapNotices = new Map<string, number>();
    pi.on('tool_call', async (event, ctx) => {
      if (!identity || !ctx.hasUI || (event.toolName !== 'write' && event.toolName !== 'edit') || typeof event.input.path !== 'string') return;
      const file = event.input.path;
      if (Date.now() - (overlapNotices.get(file) ?? 0) < 900000) return;
      try {
        const others = JSON.parse(await call(['overlaps', '--root', identity.root, '--file', file, '--agent', 'pi', '--session', identity.id]) ?? '[]');
        if (Array.isArray(others) && others[0]) {
          overlapNotices.set(file, Date.now());
          ctx.ui.notify(`Shared edit · ${others[0].agent} · ${others[0].name} recently edited ${file}. Read its changes before continuing.`, 'warning');
        }
      } catch { /* observation must not prevent an edit */ }
    });
    pi.on('tool_execution_start', async event => {
      if (!identity || event.toolName !== 'bash' || typeof event.args?.command !== 'string') return;
      const id = (await call(['begin', '--root', identity.root, '--session', identity.id,
        '--pid', String(process.pid), '--safe', 'yes', '--cwd', identity.root, '--command', event.args.command]))?.trim();
      if (id && /^[a-f0-9]{32}$/.test(id)) jobs.set(event.toolCallId, id);
    });
    pi.on('tool_result', async event => {
      if (!event.isError && (event.toolName === 'write' || event.toolName === 'edit') && typeof event.input.path === 'string')
        await publish('working', event.input.path);
      const id = jobs.get(event.toolCallId);
      if (!id) return;
      jobs.delete(event.toolCallId);
      const structured = event.structuredContent as { exit_code?: unknown } | undefined;
      const exit = typeof structured?.exit_code === 'number' && Number.isInteger(structured.exit_code)
        ? structured.exit_code : event.isError ? 1 : 0;
      const output = event.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
      await call(['finish', '--id', id, '--exit', String(exit), '--output', '-'], output);
    });
    pi.on('session_shutdown', async () => { if (heartbeat) clearInterval(heartbeat); heartbeat = undefined; await finishJobs(); await publish('done'); identity = null });
  };
}

export default function (pi: ExtensionAPI) { makeNotify()(pi); makeWork()(pi) }
