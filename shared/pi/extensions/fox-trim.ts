/**
 * fox-trim — shorter tool results for local models.
 *
 * pi cuts a tool's output at 2,000 lines / 50 KB (its tools/truncate.js), a size for cloud models. A local model on a 4 GB
 * GPU reads ~80–150 tokens/s, so one such result (~12k tokens) costs it over a minute before it can answer, and again on
 * every request that carries it. On a local model, a text result of pi's reading tools over CAP keeps its start and its
 * end (a build's error comes last) and says what was cut:
 *   - read: the lines not shown, as the offset/limit that reads them;
 *   - bash/grep/find/ls: the whole output, saved to a file the model can page through with read.
 * Cloud models, other tools and image results pass untouched. FOX_TRIM_KB changes the cap (default 8).
 */

import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const CAP = Math.max(1, Number(process.env.FOX_TRIM_KB) || 8) * 1024; // characters a local model sees per result
const HEAD = Math.floor((CAP * 3) / 8);
const TAIL = Math.floor(CAP / 2);
const TOOLS = new Set(["bash", "read", "grep", "find", "ls"]);
const LOCAL_PROVIDERS = new Set(["llamacpp", "llamacpp-turbo"]);
const KEEP_DAYS = 7;

export const outputDir = (): string =>
	join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "pi-tool-output");

/** A model served on this machine: one of the llama.cpp routers' providers, or any loopback URL. */
export function isLocal(model: { provider?: string; baseUrl?: string } | undefined): boolean {
	if (!model) return false;
	if (model.provider && LOCAL_PROVIDERS.has(model.provider)) return true;
	try {
		const host = new URL(model.baseUrl ?? "").hostname;
		return host === "127.0.0.1" || host === "localhost" || host === "[::1]" || host === "::1";
	} catch {
		return false;
	}
}

const newlines = (s: string): number => s.split("\n").length - 1;

/** The text cut to its start and end, on line boundaries; undefined when it fits. `note(first, n, total)` words what
 *  was cut: n lines, the first of them line `first` (1-based) of the text's `total`. */
export function trim(text: string, note: (first: number, n: number, total: number) => string): string | undefined {
	if (text.length <= CAP) return undefined;
	let head = text.slice(0, HEAD);
	const nl = head.lastIndexOf("\n");
	if (nl > 0) head = head.slice(0, nl + 1);
	let tail = text.slice(text.length - TAIL);
	const nl2 = tail.indexOf("\n");
	if (nl2 >= 0 && nl2 < tail.length - 1) tail = tail.slice(nl2 + 1);
	const cut = text.slice(head.length, text.length - tail.length);
	const first = newlines(head) + 1;                              // the line the cut starts in
	const n = newlines(cut) + (cut.endsWith("\n") ? 0 : 1);       // the lines it touches
	return `${head}\n… [fox-trim: ${note(first, n, newlines(text) + 1)}] …\n\n${tail}`;
}

/** Saved outputs older than KEEP_DAYS go. */
function cleanup(dir: string): void {
	try {
		const old = Date.now() - KEEP_DAYS * 86400_000;
		for (const name of readdirSync(dir)) {
			const p = join(dir, name);
			if (statSync(p).mtimeMs < old) rmSync(p, { recursive: true, force: true });
		}
	} catch {
		// no folder yet
	}
}

export default function (pi: ExtensionAPI) {
	const day = new Date().toISOString().slice(0, 10);
	cleanup(outputDir());

	pi.on("tool_result", async (event, ctx) => {
		if (!TOOLS.has(event.toolName) || !isLocal(ctx.model)) return;
		if (event.content.some((c) => c.type !== "text")) return; // an image read: as it is
		const text = event.content.map((c) => (c as { text: string }).text).join("\n");
		if (text.length <= CAP) return;
		const why = "cut to keep this short for a local model";
		let note: (first: number, n: number, total: number) => string;
		if (event.toolName === "read") {
			const input = event.input as { path?: string; offset?: number };
			const start = Math.max(1, Number(input.offset) || 1);
			note = (first, n) => {
				const a = start + first - 1;
				return `file lines ${a}–${a + n - 1} ${why}; read ${input.path ?? "the file"} with offset=${a} limit=${n} to see them`;
			};
		} else {
			const dir = join(outputDir(), day);
			const file = join(dir, `${event.toolCallId.replace(/[^\w.-]/g, "_")}.txt`);
			try {
				mkdirSync(dir, { recursive: true });
				writeFileSync(file, text);
			} catch {
				return; // can't keep the whole output: show it all rather than lose the middle
			}
			note = (first, n, total) =>
				`lines ${first}–${first + n - 1} of ${total} ${why}; the whole output is in ${file}: read it with offset=${first} limit=${n} to see them`;
		}
		const short = trim(text, note);
		if (short === undefined) return;
		return { content: [{ type: "text", text: short }], structuredContent: event.structuredContent };
	});
}
