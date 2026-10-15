/**
 * fox-notify — desktop notices from pi, through notify-send (mako / dunst):
 *
 *   a run of 15 s or more settled            🦊 pi is ready              📁 <project> · Ns
 *   a run settled on an error (any length)    🦊 pi stopped on an error   📁 <project>
 *   a select / confirm dialog open for 5 s    🦊 pi needs your yes        📁 <project>      (critical: mako keeps it 15 s)
 *   …right after the plan gate's hint          🦊 pi needs approval        📁 <project>      (critical)
 *
 * A run she stopped (Escape) pings nothing: she is there. Only in the terminal UI — never for pi -p, RPC or json runs
 * (subagents, an editor's own pi). pi's examples/extensions/notify.ts writes OSC 99/777 escapes, which tmux swallows
 * (kitty → tmux → pi); notify-send goes to mako directly.
 *
 * A notice never carries a dialog's title or any command text: a title can hold a command, and mako keeps a history.
 * Both strings start with a fixed emoji, so a project named "-x" can never be read as an option.
 */

import { basename } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export function makeNotify({ delayMs = 5000, minSecs = 15, hintMs = 1000 } = {}) {
	return function (pi: ExtensionAPI) {
		// Read while the session is live (session_start, agent_start): in print mode (pi -p, a subagent's child) the
		// session is torn down as the answer ends, and touching that ctx afterwards throws ("This extension ctx is
		// stale…"). No handler below reads its ctx.
		let tui = false;
		let project = "";
		let started = 0;
		let outcome: string | undefined; // agent_before_settle's: completed | aborted | error
		let timer: ReturnType<typeof setTimeout> | undefined;
		let hintAt = 0; // when the plan gate said its next dialog asks for approval

		const look = (ctx: { hasUI: boolean; mode: string; cwd: string }) => {
			tui = ctx.hasUI && ctx.mode === "tui";
			project = basename(ctx.cwd || "") || "pi";
		};
		const send = (summary: string, body: string, critical = false) =>
			pi
				.exec("notify-send", ["-a", "pi", ...(critical ? ["-u", "critical"] : []), summary, `📁 ${body}`])
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
			if (outcome === "error") return void (await send("🦊 pi stopped on an error", project));
			const secs = Math.round((Date.now() - started) / 1000);
			if (secs < minSecs) return; // quick replies don't need a ping
			await send("🦊 pi is ready", `${project} · ${secs}s`);
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
				void send(approval ? "🦊 pi needs approval" : "🦊 pi needs your yes", project, true);
			}, delayMs);
			timer.unref?.(); // never keeps pi alive
		});
		pi.on("ui_prompt_end", async () => clear());
		pi.on("session_shutdown", async () => clear()); // quit, reload, new, resume, fork
	};
}

export default makeNotify();
