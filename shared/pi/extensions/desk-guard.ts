/**
 * desk-guard — permission gate + protected paths for pi.
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
 * A Claude model through Anthropic is trusted the way Claude Code's auto mode trusts it (2026-11-17, her call: "i dont
 * have to approve every single command you run, since i trust the opus model" — pi with her API credits is her Claude
 * Code fallback): only MAJOR_BASH asks (a deleted tree, root, a push, lost or rewritten work, disks, a download run,
 * packages, a service off for good, the session ended) and only real secrets count (SECRET_PREFIXES, SECRET_FILE).
 * Writes into protected paths stay blocked for every model. Any other model — a local one — is judged by every rule, as
 * before. The model is read per call: /model can switch mid-session.
 *
 * One dialog per bash command (2026-10-14, her call): fox-symdeps' pi package carries a gate that asks before any
 * command that does not only read, so a destructive one used to ask twice. Over pi's event bus (`pi.events`, emitted
 * synchronously) this guard speaks that gate's protocol — the contract lives in the plugin's DOCS/DECISIONS.md (SD-148):
 *   fox:bash-reasons   { command, cwd, reasons: [] } — this guard adds its reasons; the gate names them in its dialog
 *   fox:bash-gate?     { gate: false } — a gate sets it true; then this guard does not ask for bash itself
 * With no gate loaded (no plugin, an older pi), it asks as it always did.
 *
 * Where a call lands is asked of pi's OWN tool (2026-10-14, fox-symdeps SD-162/SD-164): pi 1.2.0 reads a file: URL as
 * its path and takes `..` out as text, so a model of pi's path rules is right on one pi and wrong on the next. Each
 * write/edit/read — and grep/find/ls by their root — is run through pi's exported tool factories with operations that
 * only record (nothing reaches the disk), then every link on the way is followed as the kernel does. When pi's tools
 * cannot be asked, only plain paths are judged without a yes.
 *
 * Based on pi's examples/extensions/{permission-gate,protected-paths}.ts.
 */

import { lstatSync, readFileSync, readlinkSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
// the RUNNING pi's public API: pi's loader maps this name to the pi that loaded this file (both versions)
import * as piApi from "@mariozechner/pi-coding-agent";

const HOME = homedir();
// The retro theme draws in Big Blue Term, a DOS font with no emoji: there the dialogs lead with "!!". The style is read
// from the last theme render (the Claude notebook's theme file carries it); anything unreadable keeps the emoji.
const RETRO = (() => {
	try {
		const state = process.env.XDG_STATE_HOME || join(HOME, ".local/state");
		return /style: 'retro'/.test(readFileSync(join(state, "foxml/rendered/claude/mods/desk-notebook/hooks/theme.ts"), "utf8"));
	} catch {
		return false;
	}
})();
const SECRET_MARK = RETRO ? "!!" : "🔑";
const DANGER_MARK = RETRO ? "!! " : "⚠️ ";

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

// The major commands: asked for EVERY model, and for a trusted one the only commands that ask. Matched as text, so a
// command named inside an argument asks too; each is shaped like the command itself, so prose rarely does.
const GIT = String.raw`\bgit\s+(?:(?:-C|-c|--git-dir|--work-tree|--namespace)\s+[^\s|;&]+\s+|--?[\w-]+(?:=[^\s|;&]*)?\s+)*`;
const WORDS = String.raw`(?:[^\s|;&]+\s+)*`; // the words before a flag, never past a ; | or &
const MAJOR_BASH: [RegExp, string][] = [
	[new RegExp(String.raw`\brm\s+${WORDS}(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)(?=\s|$)`), "recursive delete"],
	[/\bfind\b[^|;&\n]*\s-delete\b/, "recursive delete"],
	[/\b(?:sudo|doas|pkexec|run0)\s+\S/, "privilege escalation"],
	[/\b(?:chmod|chown|chgrp)\b[^|;&\n]*\s(?:-[a-zA-Z]*R|--recursive|0?777|a\+rwx)(?=\s|$)/, "broad permission change"],
	[new RegExp(GIT + String.raw`push\b`), "git push"],
	[new RegExp(GIT + String.raw`(?:reset\s+${WORDS}--hard\b|clean\s+${WORDS}-[a-zA-Z]*f|checkout\s+${WORDS}(?:--(?:\s|$)|-f\b|--force\b|\.(?:\s|$))|restore\s+(?!(?:[^|;&\n]*\s)?(?:--staged|-S)\b)|stash\s+(?:drop|clear)\b|branch\s+${WORDS}-[a-zA-Z]*D\b|worktree\s+remove\s+${WORDS}(?:-f|--force)\b)`),
		"discards uncommitted work"],
	[new RegExp(GIT + String.raw`(?:rebase|filter-branch|filter-repo)\b`), "history rewrite"],
	[/\bdd\b[^|;&\n]*\bof=|\b(?:mkfs(?:\.\w+)?|wipefs|shred|fdisk|sfdisk|parted)\b/, "disk-level tool"],
	[/\b(?:curl|wget)\b[^|]*\|\s*(?:sudo\s+)?(?:(?:ba|z|da|k)?sh|python3?|perl|ruby|node)\b/, "pipes a download into a shell"],
	// -S that is not a search or a listing (-Ss -Si -Sl -Sg -Sp), -U, -R; a bare yay or paru upgrades everything
	[/\b(?:pacman|yay|paru)\s+(?:--?[\w-]+\s+)*?-(?:S(?![a-zA-Z]*[silgp])|U|R)|\b(?:yay|paru)\s*(?:$|[;&|])/, "package install"],
	[/\bnpm\s+(?:(?:i|install|add|un|uninstall|remove|rm)\b[^|;&\n]*\s(?:-g|--global)\b|(?:-g|--global)\s+(?:i|install|add|un|uninstall|remove|rm)\b)/, "package install"],
	[/>\s*\/dev\/(?:sd|nvme|mmcblk|vd|hd)/, "writes to a block device"],
	[/\bsystemctl\s+(?:--?[\w-]+\s+)*(?:disable|mask)\b/, "turns a service off for good"],
	[/(?:^|[;&|\n]\s*|\b(?:sudo|exec|systemctl)\s+)(?:reboot|poweroff|shutdown|halt|suspend|hibernate|kexec|soft-reboot)\b|\bhyprctl\s+dispatch\s+exit\b|\bloginctl\s+(?:terminate|kill)-/,
		"powers off or ends your session"],
];

// Real secrets, for a trusted model (reading one sends it to the model's provider): what shared/bin/claude-api's API
// tasks deny (its SECRETS) plus the agents' own credentials. A local model counts every PROTECTED path above as one.
const SECRET_PREFIXES = [".ssh", ".gnupg", ".password-store", ".local/share/keyrings", ".config/foxml/secrets", ".aws",
	".netrc", ".claude/.credentials.json", ".pi/agent/auth.json", ".codex/auth.json", ".config/gh/hosts.yml"].map((p) => `${HOME}/${p}`);
const SECRET_FILE = /(?:^|\/)(?:\.env(?:\.[^/]*)?|id_(?:rsa|ed25519|ecdsa)[^/]*|[^/]+\.(?:pem|key))$/;
const SECRET_DIR = /\/(?:secrets|priv)(?:\/|$)/;
const HOME_SECRETS = PROTECTED_PREFIXES.filter((p) => !SYSTEM_PREFIXES.has(p));

/** A Claude model through Anthropic's own API — trusted like Claude Code's auto mode. */
export function trusted(model: { provider?: string; id?: string } | undefined): boolean {
	return model?.provider === "anthropic" && /^claude-/.test(model.id ?? "");
}

function secretReason(abs: string): string | undefined {
	const p = SECRET_PREFIXES.find((x) => abs === x || abs.startsWith(`${x}/`));
	if (p) return `secret: ${p.replace(HOME, "~")}`;
	if (SECRET_FILE.test(abs)) return "a secret's file name";
	return SECRET_DIR.test(abs) ? "inside a secrets folder" : undefined;
}

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
function holdsSecret(root: string, secrets: string[]): string | undefined {
	const p = secrets.find((x) => root === "/" || x.startsWith(`${root}/`));
	return p ? `searches ${root.replace(HOME, "~")}, which holds ${p.replace(HOME, "~")}` : undefined;
}

// ── where pi's OWN tool lands a path — the same probe as fox-symdeps' gate (its pi/lib/core.ts: probeLanding, plainPath,
// realish), copied: this guard runs without that plugin. Each check is tested against the installed pi
// (tests/desk-guard-test.mjs), as the plugin's are.
const STOP = Symbol("desk-guard-probe");
type Tool = "write" | "edit" | "read" | "ls";
const FACTORY: Record<Tool, string> = { write: "createWriteToolDefinition", edit: "createEditToolDefinition",
	read: "createReadToolDefinition", ls: "createLsToolDefinition" };
const FILE_OPS: Record<Tool, string[]> = { write: ["writeFile"], edit: ["access", "readFile", "writeFile"],
	read: ["access", "readFile", "detectImageMimeType"], ls: ["exists", "stat", "readdir"] };

// Where pi's own `tool` would touch the filesystem for `input`: the path of its first file call (`paths`), pi's tool
// refusing the input first (`refused` — in use it would refuse too), or neither (`unknown` — fall back). The recorded
// path is the answer, never the error (pi may re-wrap the stop). grep/find/ls resolve their root as `ls` does — grep's
// own tool is never probed (it may fetch rg before it resolves).
async function landing(tool: Tool, input: unknown, cwd: string): Promise<{ paths: string[]; refused?: string; unknown?: string }> {
	const make = (piApi as any)[FACTORY[tool]];
	if (typeof make !== "function") return { paths: [], unknown: `this pi exports no ${tool} tool factory` };
	const paths: string[] = [];
	let other: string | undefined;
	const stop = async (p: unknown) => { if (typeof p === "string") paths.push(p); throw STOP; };
	const known: Record<string, (p?: unknown) => Promise<unknown>> = Object.fromEntries(FILE_OPS[tool].map((k) => [k, stop]));
	if (tool === "write") known.mkdir = async () => undefined;
	const operations = new Proxy(known, { get: (t, k) => (typeof k !== "string" || k === "then" ? undefined
		: Object.prototype.hasOwnProperty.call(t, k) ? t[k] : async () => { other ??= k; throw STOP; }) });
	let def: any, copy: unknown;
	try { def = make(cwd, { operations }); copy = structuredClone(input); } catch (e) { return { paths, unknown: String((e as Error)?.message ?? e) }; }
	let timer: ReturnType<typeof setTimeout> | undefined;
	const late = new Promise<typeof STOP>((done) => { timer = setTimeout(() => done(STOP), 5000); });
	let threw: unknown, answered = true;
	try {
		const r = await Promise.race([Promise.resolve().then(() => def.execute("desk-guard-probe", copy, undefined, undefined, { cwd })), late]);
		if (r === STOP) answered = false;
	} catch (e) { threw = e; } finally { clearTimeout(timer); }
	if (other !== undefined) return { paths, unknown: `pi's ${tool} tool asked for "${other}", an operation the guard does not know` };
	if (paths.length) return { paths };
	if (!answered) return { paths, unknown: `pi's ${tool} tool did not answer in time` };
	if (threw !== undefined) return { paths, refused: String((threw as Error)?.message ?? threw).slice(0, 200) };
	return { paths, unknown: `pi's ${tool} tool returned without a file call` };
}

// A plain path — the one class judged without pi's tools (on it both pis read the same text): an optional @, ~ or ~/ at
// the start, then ASCII letters, digits, space and . _ - + = , / only; no space at either end; no //, no trailing /; no
// `.` or `..` segment once absolute.
function plainPath(p: string): boolean {
	let s = p.startsWith("@") ? p.slice(1) : p;
	if (s === "~") return true;
	if (s.includes("//")) return false;
	let abs = s.startsWith("/");
	if (s.startsWith("~/")) { s = s.slice(2); abs = true; }
	if (!/^[A-Za-z0-9 ._+=,\/-]+$/.test(s) || /^\s|\s$/.test(s) || s.endsWith("/")) return false;
	const segs = s.split("/");
	return !(abs && (segs.includes("..") || segs.includes(".")));
}

// The path the kernel reaches: every link followed (a dangling last one too), each `..` from the real folder reached so far.
function realish(abs: string): string {
	let rest = (isAbsolute(abs) ? abs : resolve(abs)).split(sep).filter(Boolean);
	let at = sep;
	for (let hops = 0; rest.length; ) {
		const name = rest.shift()!;
		const next = join(at, name);
		let link = false;
		try { link = lstatSync(next).isSymbolicLink(); } catch { /* missing: the rest is new */ }
		if (!link) { at = next; continue; }
		if (++hops > 40) return join(next, ...rest);
		let target: string;
		try { target = readlinkSync(next); } catch { at = next; continue; }
		rest = [...target.split(sep).filter(Boolean), ...rest];
		if (isAbsolute(target)) at = sep;
	}
	return at;
}

// Where a call lands, as pi's own tool says — or, when it cannot be asked, a plain path the old way; undefined: unknown.
async function lands(tool: Tool, input: unknown, given: string, cwd: string): Promise<{ paths?: string[]; refused?: string; why?: string }> {
	const l = await landing(tool, input, cwd);
	if (l.refused !== undefined) return { refused: l.refused };
	if (l.paths.length) return { paths: l.paths };
	return plainPath(given) ? { paths: [expand(given, cwd)] } : { why: l.unknown };
}

// Protected by the path as written or by where the kernel takes it.
function judged(abs: string, secretsOnly = false): string | undefined {
	return protectedReason(abs, secretsOnly) ?? protectedReason(realish(abs), secretsOnly);
}

// Why a bash command needs a yes: a destructive pattern, or a path token that names a secret (reads too). `trust`: a
// trusted model — only the major commands and real secrets.
function bashReasons(command: string, cwd: string, trust = false): string[] {
	const rules = trust ? MAJOR_BASH : [...DANGEROUS_BASH, ...MAJOR_BASH];
	const reasons = rules.filter(([re]) => re.test(command)).map(([, why]) => why);
	for (const tok of command.match(/(~|\.{0,2}\/)[^\s'";|&<>()]+/g) ?? []) {
		const abs = expand(tok, cwd);
		const why = trust ? secretReason(abs) : protectedReason(abs, true);
		if (why) reasons.push(`touches ${tok} (${why})`);
	}
	// a secret named without a slash (cat .env, cp id_ed25519 …): its file name is enough
	for (const word of command.split(/[\s'";|&<>()=]+/))
		if (word && !word.includes("/") && SECRET_FILE.test(`/${word}`)) reasons.push(`touches ${word} (a secret's file name)`);
	return [...new Set(reasons)];
}

export default function (pi: ExtensionAPI) {
	const events = (pi as any).events as { on: (c: string, f: (d: any) => void) => unknown; emit: (c: string, d: any) => void } | undefined;
	// a gate asks with these reasons: it says nothing of the model, so they are a local model's (every rule)
	events?.on("fox:bash-reasons", (req: any) => {
		if (req && Array.isArray(req.reasons)) req.reasons.push(...bashReasons(String(req.command ?? ""), String(req.cwd ?? process.cwd())));
	});

	pi.on("tool_call", async (event, ctx) => {
		const trust = trusted(ctx.model);
		if (event.toolName === "write" || event.toolName === "edit") {
			const given = String(event.input.path ?? "");
			const l = await lands(event.toolName, event.input, given, ctx.cwd);
			if (l.refused !== undefined) return { block: true, reason: `pi's own ${event.toolName} tool refuses this path (${l.refused}). Do not retry; ask the user.` };
			// pi cannot be asked where it lands: a trusted model's path is judged as written, a local model's asks
			const paths = l.paths ?? (trust ? [expand(given, ctx.cwd)] : undefined);
			if (!paths) {
				const ask = `desk-guard cannot ask pi where ${event.toolName} "${given}" lands (${l.why})`;
				if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${ask}` };
				const choice = await ctx.ui.select(`${SECRET_MARK} ${ask}\n\nAllow?`, ["No", "Yes"]);
				return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
			}
			for (const abs of paths) {
				const why = judged(abs);
				if (!why) continue;
				if (ctx.hasUI) ctx.ui.notify(`desk-guard blocked ${event.toolName}: ${abs} (${why})`, "warning");
				return { block: true, reason: `Path "${abs}" is protected (${why}). Do not retry; ask the user.` };
			}
			return undefined;
		}

		const grep = event.toolName === "grep";
		if (["read", "grep", "find", "ls"].includes(event.toolName) && (typeof event.input.path === "string" || grep)) {
			// grep with no path searches the folder pi runs in; grep/find/ls resolve their root as ls does
			const given = typeof event.input.path === "string" ? event.input.path : ".";
			const l = await lands(event.toolName === "read" ? "read" : "ls", event.toolName === "read" ? event.input : { path: given }, given, ctx.cwd);
			const abs = l.paths?.[0] ?? expand(given, ctx.cwd);
			const why = l.refused !== undefined ? undefined
				: trust ? secretReason(abs) ?? secretReason(realish(abs))
					?? (grep ? holdsSecret(realish(abs), SECRET_PREFIXES) ?? holdsSecret(abs, SECRET_PREFIXES) : undefined)
				: !l.paths ? `desk-guard cannot ask pi where it lands (${l.why})`
				: judged(abs, true) ?? (grep ? holdsSecret(realish(abs), HOME_SECRETS) ?? holdsSecret(abs, HOME_SECRETS) : undefined);
			if (!why) return undefined;
			if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${event.toolName} ${abs} (${why})` };
			const choice = await ctx.ui.select(`${SECRET_MARK} ${event.toolName} of a secret path: ${abs} (${why})\n\nAllow?`, ["No", "Yes"]);
			return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
		}

		if (event.toolName !== "bash") return undefined;
		const command = event.input.command as string;

		const reasons = bashReasons(command, ctx.cwd, trust);
		if (reasons.length === 0) return undefined;
		// a gate that asks with these reasons in its one dialog (fox:bash-reasons) — then this guard does not ask too
		const probe = { gate: false };
		events?.emit("fox:bash-gate?", probe);
		if (probe.gate) return undefined;

		if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${reasons.join("; ")}` };
		const choice = await ctx.ui.select(`${DANGER_MARK} ${reasons.join("; ")}\n\n  ${command}\n\nAllow?`, ["No", "Yes"]);
		return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
	});
}
