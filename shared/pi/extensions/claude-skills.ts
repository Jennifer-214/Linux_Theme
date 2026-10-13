/**
 * claude-skills — load the same skills Claude Code sees.
 *
 * Claude Code keeps per-project skills at <repo>/.claude/skills (often a symlink
 * to a private workspace). pi only scans .pi/ and .agents/, so this adds each .claude/skills found from
 * cwd up to the filesystem root. Skills stay per-project, which matters on a 32k
 * local context: each skill description costs tokens (a 40-skill set is ~4k).
 * ~/.claude/skills is skipped on purpose: it holds Claude-app skills synced from
 * claude.ai (pdf, docx, chrome-browser, …) that need tools pi doesn't have.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	pi.on("resources_discover", async (event) => {
		const skillPaths: string[] = [];
		for (let dir = event.cwd; ; dir = dirname(dir)) {
			const candidate = join(dir, ".claude", "skills");
			if (dir !== homedir() && existsSync(candidate)) skillPaths.push(candidate);
			if (dirname(dir) === dir) break;
		}
		return { skillPaths };
	});
}
