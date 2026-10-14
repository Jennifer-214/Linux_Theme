/**
 * fox-guard — permission gate + protected paths for pi.
 *
 * pi runs every bash/write/edit call without asking. Local models misfire more
 * than frontier ones, so:
 *   - write/edit into a protected path            → blocked outright
 *   - bash that names a secret path               → asks first (reads too: cat ~/.ssh/… leaks)
 *   - read/grep/find/ls of a secret path          → asks first (lands in session logs / cloud models)
 *   - grep from a folder that holds a secret one  → asks first (pi greps hidden folders too)
 *   - bash matching a destructive pattern         → asks first
 * With no UI (pi -p / RPC) anything that would ask is blocked instead.
 *
 * One dialog per bash command (2026-10-14, her call): fox-symdeps' pi package carries a gate that asks before any
 * command that does not only read, so a destructive one used to ask twice. Over pi's event bus (`pi.events`, emitted
 * synchronously) this guard speaks that gate's protocol — the contract lives in the plugin's DOCS/DECISIONS.md (SD-148):
 *   fox:bash-reasons   { command, cwd, reasons: [] } — this guard adds its reasons; the gate names them in its dialog
 *   fox:bash-gate?     { gate: false } — a gate sets it true; then this guard does not ask for bash itself
 * With no gate loaded (no plugin, an older pi), it asks as it always did.
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

// The path as pi's tools take it: one leading "@" dropped first (resolveToCwd / resolveReadPath strip it, both
// versions) — `@~/.ssh/config` IS ~/.ssh/config to read and write, so it must be to this guard (2026-10-14).
function expand(p: string, cwd: string): string {
	const s = p.startsWith("@") ? p.slice(1) : p;
	const home = s === "~" || s.startsWith("~/") ? HOME + s.slice(1) : s;
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

// grep reads every folder below its root, hidden ones too (pi runs rg --hidden): a root that HOLDS a secret folder
// reads it — grep from ~ for "PRIVATE KEY" returns key material (2026-10-14, her call: grep only; find/ls list names).
function holdsSecret(root: string): string | undefined {
	const p = PROTECTED_PREFIXES.find((x) => !SYSTEM_PREFIXES.has(x) && (root === "/" || x.startsWith(`${root}/`)));
	return p ? `searches ${root.replace(HOME, "~")}, which holds ${p.replace(HOME, "~")}` : undefined;
}

// Why a bash command needs a yes: a destructive pattern, or a path token that names a secret (reads too).
function bashReasons(command: string, cwd: string): string[] {
	const reasons = DANGEROUS_BASH.filter(([re]) => re.test(command)).map(([, why]) => why);
	for (const tok of command.match(/(~|\.{0,2}\/)[^\s'";|&<>()]+/g) ?? []) {
		const why = protectedReason(expand(tok, cwd), true);
		if (why) reasons.push(`touches ${tok} (${why})`);
	}
	return reasons;
}

export default function (pi: ExtensionAPI) {
	const events = (pi as any).events as { on: (c: string, f: (d: any) => void) => unknown; emit: (c: string, d: any) => void } | undefined;
	events?.on("fox:bash-reasons", (req: any) => {
		if (req && Array.isArray(req.reasons)) req.reasons.push(...bashReasons(String(req.command ?? ""), String(req.cwd ?? process.cwd())));
	});

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName === "write" || event.toolName === "edit") {
			const abs = expand(event.input.path as string, ctx.cwd);
			const why = protectedReason(abs);
			if (!why) return undefined;
			if (ctx.hasUI) ctx.ui.notify(`fox-guard blocked ${event.toolName}: ${abs} (${why})`, "warning");
			return { block: true, reason: `Path "${abs}" is protected (${why}). Do not retry; ask the user.` };
		}

		const grep = event.toolName === "grep";
		if (["read", "grep", "find", "ls"].includes(event.toolName) && (typeof event.input.path === "string" || grep)) {
			// grep with no path searches the folder pi runs in
			const abs = expand(typeof event.input.path === "string" ? event.input.path : ".", ctx.cwd);
			const why = protectedReason(abs, true) ?? (grep ? holdsSecret(abs) : undefined);
			if (!why) return undefined;
			if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${event.toolName} ${abs} (${why})` };
			const choice = await ctx.ui.select(`🔑 ${event.toolName} of a secret path: ${abs} (${why})\n\nAllow?`, ["No", "Yes"]);
			return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
		}

		if (event.toolName !== "bash") return undefined;
		const command = event.input.command as string;

		const reasons = bashReasons(command, ctx.cwd);
		if (reasons.length === 0) return undefined;
		// a gate that asks with these reasons in its one dialog (fox:bash-reasons) — then this guard does not ask too
		const probe = { gate: false };
		events?.emit("fox:bash-gate?", probe);
		if (probe.gate) return undefined;

		if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${reasons.join("; ")}` };
		const choice = await ctx.ui.select(`⚠️  ${reasons.join("; ")}\n\n  ${command}\n\nAllow?`, ["No", "Yes"]);
		return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
	});
}
