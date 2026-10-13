/**
 * fox-guard — permission gate + protected paths for pi.
 *
 * pi runs every bash/write/edit call without asking. Local models misfire more
 * than frontier ones, so:
 *   - write/edit into a protected path            → blocked outright
 *   - bash that names a secret path               → asks first (reads too: cat ~/.ssh/… leaks)
 *   - read/grep/find/ls of a secret path          → asks first (lands in session logs / cloud models)
 *   - bash matching a destructive pattern         → asks first
 * With no UI (pi -p / RPC) anything that would ask is blocked instead.
 *
 * Based on pi's examples/extensions/{permission-gate,protected-paths}.ts.
 */

import { homedir } from "node:os";
import { resolve } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const HOME = homedir();

// Absolute prefixes (after ~ expansion) and path fragments that agents never write.
const PROTECTED_PREFIXES = [
	`${HOME}/.ssh`,
	`${HOME}/.gnupg`,
	`${HOME}/.claude`, // credentials + Claude Code state
	`${HOME}/.config/foxml`, // knock/spa/tripwire/honeypot config
	`${HOME}/.local/share/keyrings`,
	"/etc",
	"/boot",
	"/usr",
];
const PROTECTED_FRAGMENTS = ["/.git/", "/priv/", "/.env", ".pem", ".key", "id_rsa", "id_ed25519"];
// For bash, only secrets count: /etc, /usr, /boot writes need sudo (gated below), and
// reading them — or poking at .git/ — is routine.
const SYSTEM_PREFIXES = new Set(["/etc", "/boot", "/usr"]);

const DANGEROUS_BASH: [RegExp, string][] = [
	[/\brm\s+(-[a-z]*[rf]|--recursive|--force)/i, "recursive/forced delete"],
	[/\bsudo\b|\bdoas\b|\bpkexec\b/, "privilege escalation"],
	[/\b(chmod|chown)\b.*\b(777|-R)\b/, "broad permission change"],
	[/\bgit\s+push\b/, "git push"],
	[/\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|restore\s)/, "discards uncommitted work"],
	[/\bgit\s+(rebase|filter-branch|filter-repo)\b/, "history rewrite"],
	[/\b(dd|mkfs(\.\w+)?|wipefs|shred|fdisk|parted)\b/, "disk-level tool"],
	[/\bsystemctl\s+(--user\s+)?(stop|disable|mask|kill|enable|restart)\b/, "service change"],
	[/\b(curl|wget)\b[^|]*\|\s*(ba|z)?sh\b/, "pipes a download into a shell"],
	[/\b(pacman|yay|paru|npm\s+(i|install)\s+-g)\b/, "package install"],
	[/>\s*\/dev\/(sd|nvme)/, "writes to a block device"],
];

function expand(p: string, cwd: string): string {
	const home = p === "~" || p.startsWith("~/") ? HOME + p.slice(1) : p;
	return resolve(cwd, home);
}

function protectedReason(absPath: string, secretsOnly = false): string | undefined {
	const prefix = PROTECTED_PREFIXES.find(
		(p) => (absPath === p || absPath.startsWith(`${p}/`)) && !(secretsOnly && SYSTEM_PREFIXES.has(p)),
	);
	if (prefix) return `inside ${prefix.replace(HOME, "~")}`;
	const frag = PROTECTED_FRAGMENTS.find((f) => absPath.includes(f) && !(secretsOnly && f === "/.git/"));
	return frag ? `matches "${frag}"` : undefined;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName === "write" || event.toolName === "edit") {
			const abs = expand(event.input.path as string, ctx.cwd);
			const why = protectedReason(abs);
			if (!why) return undefined;
			if (ctx.hasUI) ctx.ui.notify(`fox-guard blocked ${event.toolName}: ${abs} (${why})`, "warning");
			return { block: true, reason: `Path "${abs}" is protected (${why}). Do not retry; ask the user.` };
		}

		if (["read", "grep", "find", "ls"].includes(event.toolName) && typeof event.input.path === "string") {
			const abs = expand(event.input.path as string, ctx.cwd);
			const why = protectedReason(abs, true);
			if (!why) return undefined;
			if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${event.toolName} ${abs} (${why})` };
			const choice = await ctx.ui.select(`🔑 ${event.toolName} of a secret path: ${abs} (${why})\n\nAllow?`, ["No", "Yes"]);
			return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
		}

		if (event.toolName !== "bash") return undefined;
		const command = event.input.command as string;

		const reasons = DANGEROUS_BASH.filter(([re]) => re.test(command)).map(([, why]) => why);
		// Any path-looking token that names a secret.
		for (const tok of command.match(/(~|\.{0,2}\/)[^\s'";|&<>()]+/g) ?? []) {
			const why = protectedReason(expand(tok, ctx.cwd), true);
			if (why) reasons.push(`touches ${tok} (${why})`);
		}
		if (reasons.length === 0) return undefined;

		if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${reasons.join("; ")}` };
		const choice = await ctx.ui.select(`⚠️  ${reasons.join("; ")}\n\n  ${command}\n\nAllow?`, ["No", "Yes"]);
		return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
	});
}
