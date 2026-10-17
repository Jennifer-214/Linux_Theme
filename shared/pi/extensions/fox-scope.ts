/**
 * fox-scope — a project's own instructions only.
 *
 * pi reads a context file (AGENTS.md, CLAUDE.md, …) from the folder it runs in and from every folder above it, up to
 * `/`, so a project under ~/code also gets ~/code/CLAUDE.md — instructions written for another scope. Before each
 * request this leaves out every context file from a folder above the project's root: the nearest folder holding a
 * `.git` (a folder, or a file — a linked worktree, a submodule), else the folder pi runs in. Kept: the root's own, those
 * between the root and the working folder (a monorepo's subfolders), and pi's global one in its agent folder. At
 * session start it says what it leaves out, so pi's own list of the files it found never reads as what the model gets.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type ContextFile = { path: string; content: string };

/** pi's agent folder, where its global context file lives (pi's own rule: the env var, else ~/.pi/agent). */
export const agentDir = (): string =>
	resolve(process.env.PI_CODING_AGENT_DIR?.replace(/^~(?=$|\/)/, homedir()) || join(homedir(), ".pi", "agent"));

/** The project's root: the nearest folder at or above `cwd` holding a `.git` (a folder or a file), else `cwd`. */
export function projectRoot(cwd: string): string {
	const start = resolve(cwd);
	for (let dir = start; ; ) {
		if (existsSync(join(dir, ".git"))) return dir;
		const up = dirname(dir);
		if (up === dir) return start;
		dir = up;
	}
}

/** `dir` is above `root` — a strict ancestor, never a sibling: `/a/code-x` is not above `/a/code/p`. */
export function isAbove(dir: string, root: string): boolean {
	const rel = relative(resolve(dir), resolve(root));
	return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

/** The context files a project keeps, and those it leaves out (each from a folder above its root). */
export function scope(files: ContextFile[], cwd: string): { root: string; kept: ContextFile[]; out: ContextFile[] } {
	const root = projectRoot(cwd);
	const global = agentDir();
	const kept: ContextFile[] = [];
	const out: ContextFile[] = [];
	for (const f of files) {
		const dir = resolve(dirname(f.path));
		(dir !== global && isAbove(dir, root) ? out : kept).push(f);
	}
	return { root, kept, out };
}

const tilde = (p: string): string => (p === homedir() || p.startsWith(homedir() + sep) ? "~" + p.slice(homedir().length) : p);

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", (event) => {
		const opts = event.systemPromptOptions;
		const { kept, out } = scope(opts.contextFiles, opts.cwd);
		if (out.length > 0) opts.contextFiles = kept;
	});

	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		const opts = ctx.getSystemPromptOptions();
		const { root, out } = scope(opts.contextFiles ?? [], opts.cwd ?? ctx.cwd);
		if (out.length === 0) return;
		ctx.ui.notify(`fox-scope: left out ${out.map((f) => tilde(f.path)).join(", ")} (above this project, ${tilde(root)})`, "info");
	});
}
