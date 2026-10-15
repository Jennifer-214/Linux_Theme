/**
 * fox-budget — /budget: what pi's prompt costs the current model to read, part by part.
 *
 * Reading the prompt is the slow part on a laptop GPU (~80–150 tokens/s on the 4–9B models), and pi's opening prompt is
 * read again by every new session: pi's own instructions, the context files (AGENTS.md / CLAUDE.md, or a project's brief),
 * the skills it lists, the tool definitions. /budget counts each in the current model's own tokens — llama.cpp's
 * llama-tokenize loads only the vocabulary of the model's GGUF in the fox-llm folder — and gives the read time at the
 * speed fox-llm-grade measured for that model. With no GGUF here (a cloud model) the counts are estimates
 * (characters ÷ 3.6), and say so. The report is a notice on screen: it never enters the conversation.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const HOME = homedir();
const tilde = (p: string): string => (p.startsWith(`${HOME}/`) ? `~${p.slice(HOME.length)}` : p);

/** The model's GGUF in the fox-llm folder, when pi's model is one fox-llm-serve serves. */
export function gguf(id: string | undefined): string | undefined {
	if (!id || id.includes("/")) return undefined;
	const p = join(process.env.XDG_DATA_HOME || join(HOME, ".local/share"), "fox-llm", "gguf", `${id}.gguf`);
	return existsSync(p) ? p : undefined;
}

const estimate = (text: string): number => Math.ceil(text.length / 3.6);

/** Token counts for each text — in parallel, one llama-tokenize each — and whether they are exact. */
export async function countAll(texts: string[], file: string | undefined): Promise<{ counts: number[]; exact: boolean }> {
	if (!file) return { counts: texts.map(estimate), exact: false };
	const bin = process.env.FOX_LLAMA_TOKENIZE || "llama-tokenize";
	const one = (text: string) =>
		new Promise<number | undefined>((done) => {
			if (!text) return done(0);
			const child = execFile(bin, ["-m", file, "--stdin", "--ids", "--show-count", "--log-disable", "--no-bos"],
				{ timeout: 60_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
					const m = /Total number of tokens:\s*(\d+)/.exec(String(out ?? ""));
					done(err || !m ? undefined : Number(m[1]));
				});
			child.stdin?.end(text);
		});
	const got = await Promise.all(texts.map(one));
	return got.every((n) => n !== undefined)
		? { counts: got as number[], exact: true }
		: { counts: texts.map(estimate), exact: false };
}

/** The read speed fox-llm-grade last measured for this model: tokens/s and the day, if it has one. */
export function readSpeed(id: string | undefined): { tps: number; day: string } | undefined {
	try {
		const file = join(process.env.XDG_STATE_HOME || join(HOME, ".local/state"), "fox-llm-update", "grades.tsv");
		const rows = readFileSync(file, "utf8").split("\n").map((l) => l.split("\t"))
			.filter((r) => r.length === 6 && r[2] === id && r[4] === "read_tps" && Number(r[5]) > 0)
			.sort((a, b) => (a[0] < b[0] ? -1 : 1));
		const last = rows.at(-1);
		return last ? { tps: Number(last[5]), day: last[0].slice(0, 10) } : undefined;
	} catch {
		return undefined;
	}
}

const fmt = (n: number): string => n.toLocaleString("en-US");

/** The report's lines. `parts` are [label, text]; `tools` the active tool definitions; `prompt` the last system
 *  prompt pi built, when one was built this session. */
export async function report(o: {
	model: { id?: string } | undefined;
	parts: [string, string][];
	tools: unknown[];
	prompt: string | undefined;
	usage: { tokens: number | null; contextWindow: number } | undefined;
}): Promise<string[]> {
	const file = gguf(o.model?.id);
	const texts = [...o.parts.map(([, t]) => t), JSON.stringify(o.tools), o.prompt ?? ""];
	const { counts, exact } = await countAll(texts, file);
	const nParts = o.parts.length, toolTokens = counts[nParts], promptTokens = counts[nParts + 1];
	const rows: [string, number][] = o.parts.map(([label], i) => [label, counts[i]]);
	rows.push([`tool definitions (${o.tools.length})`, toolTokens]);
	const lines: string[] = [];
	const name = o.model?.id ?? "no model";
	if (o.prompt !== undefined) {
		const own = Math.max(0, promptTokens - rows.slice(0, -1).reduce((a, [, n]) => a + n, 0));
		rows.unshift(["pi's own instructions", own]);
		const total = promptTokens + toolTokens;
		const speed = readSpeed(o.model?.id);
		const time = speed ? `, ~${Math.round(total / speed.tps)} s to read at ${speed.tps} tok/s (graded ${speed.day})`
			: ` — read speed not measured yet (fox-llm-grade ${name})`;
		lines.push(`pi's opening prompt for ${name}: ${fmt(total)} tokens${time}`);
	} else {
		lines.push(`pi's opening prompt for ${name} — send one message for its total (pi's own instructions)`);
	}
	const width = Math.max(...rows.map(([l]) => l.length));
	for (const [label, n] of rows) lines.push(`  ${label.padEnd(width)}  ${fmt(n).padStart(7)}`);
	if (o.usage?.tokens != null)
		lines.push(`this session so far: ${fmt(o.usage.tokens)} of ${fmt(o.usage.contextWindow)} tokens`);
	lines.push(exact ? `counted with ${name}'s own tokenizer` : "estimated (characters ÷ 3.6): no local GGUF for this model");
	return lines;
}

export default function (pi: ExtensionAPI) {
	let prompt: string | undefined;
	pi.on("before_agent_start", async (event) => {
		prompt = event.systemPrompt;
	});
	pi.registerCommand("budget", {
		description: "What pi's prompt costs the current model to read, part by part",
		handler: async (_args, ctx) => {
			const opts = ctx.getSystemPromptOptions();
			const parts: [string, string][] = [];
			for (const cf of opts.contextFiles ?? []) parts.push([`context ${tilde(cf.path)}`, cf.content]);
			const skills = (opts.skills ?? []).filter((s) => !s.disableModelInvocation);
			if (skills.length) parts.push([`skills (${skills.length})`, skills.map((s) => `${s.name}: ${s.description}`).join("\n")]);
			if (opts.appendSystemPrompt) parts.push(["appended instructions", opts.appendSystemPrompt]);
			for (const [tag, text] of Object.entries(opts.sections ?? {})) parts.push([`section <${tag}>`, text]);
			const active = new Set(pi.getActiveTools());
			const tools = pi.getAllTools().filter((t) => active.has(t.name))
				.map((t) => ({ name: t.name, description: t.description, parameters: t.parameters }));
			const lines = await report({ model: ctx.model, parts, tools, prompt, usage: ctx.getContextUsage() });
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
