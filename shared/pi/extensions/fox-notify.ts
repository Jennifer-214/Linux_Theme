/**
 * fox-notify — desktop notification when pi finishes and waits for input.
 *
 * pi's examples/extensions/notify.ts writes OSC 99/777 escapes, which tmux
 * swallows (kitty → tmux → pi). notify-send goes through mako/dunst directly.
 */

import { basename } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	let started = 0;
	// Read at agent_start, while the session is live: in print mode (pi -p, a subagent's child) the session is torn
	// down as the answer ends, and touching that ctx at agent_end throws ("This extension ctx is stale…").
	let hasUI = false;
	let cwd = "";

	pi.on("agent_start", async (_event, ctx) => {
		started = Date.now();
		hasUI = ctx.hasUI;
		cwd = ctx.cwd;
	});

	pi.on("agent_end", async () => {
		if (!hasUI) return;
		const secs = Math.round((Date.now() - started) / 1000);
		if (secs < 15) return; // quick replies don't need a ping
		await pi.exec("notify-send", ["-a", "pi", "🦊 pi is ready", `${basename(cwd)} · ${secs}s`]);
	});
}
