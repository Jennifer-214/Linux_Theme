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

	pi.on("agent_start", async () => {
		started = Date.now();
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		const secs = Math.round((Date.now() - started) / 1000);
		if (secs < 15) return; // quick replies don't need a ping
		await pi.exec("notify-send", ["-a", "pi", "🦊 pi is ready", `${basename(ctx.cwd)} · ${secs}s`]);
	});
}
