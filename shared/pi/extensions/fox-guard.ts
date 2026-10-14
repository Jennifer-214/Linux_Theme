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
 * Where a call lands is asked of pi's OWN tool (2026-10-14, fox-symdeps SD-162/SD-164): pi 1.2.0 reads a file: URL as
 * its path and takes `..` out as text, so a model of pi's path rules is right on one pi and wrong on the next. Each
 * write/edit/read — and grep/find/ls by their root — is run through pi's exported tool factories with operations that
 * only record (nothing reaches the disk), then every link on the way is followed as the kernel does. When pi's tools
 * cannot be asked, only plain paths are judged without a yes.
 *
 * Based on pi's examples/extensions/{permission-gate,protected-paths}.ts.
 */

import { lstatSync, readlinkSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
// the RUNNING pi's public API: pi's loader maps this name to the pi that loaded this file (both versions)
import * as piApi from "@mariozechner/pi-coding-agent";

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

// ── where pi's OWN tool lands a path — the same probe as fox-symdeps' gate (its pi/lib/core.ts: probeLanding, plainPath,
// realish), copied: this guard runs without that plugin. Each check is tested against the installed pi
// (tests/fox-guard-test.mjs), as the plugin's are.
const STOP = Symbol("fox-guard-probe");
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
		const r = await Promise.race([Promise.resolve().then(() => def.execute("fox-guard-probe", copy, undefined, undefined, { cwd })), late]);
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
			const given = String(event.input.path ?? "");
			const l = await lands(event.toolName, event.input, given, ctx.cwd);
			if (l.refused !== undefined) return { block: true, reason: `pi's own ${event.toolName} tool refuses this path (${l.refused}). Do not retry; ask the user.` };
			if (!l.paths) {
				const ask = `fox-guard cannot ask pi where ${event.toolName} "${given}" lands (${l.why})`;
				if (!ctx.hasUI) return { block: true, reason: `Blocked without UI: ${ask}` };
				const choice = await ctx.ui.select(`🔑 ${ask}\n\nAllow?`, ["No", "Yes"]);
				return choice === "Yes" ? undefined : { block: true, reason: "Blocked by user" };
			}
			for (const abs of l.paths) {
				const why = judged(abs);
				if (!why) continue;
				if (ctx.hasUI) ctx.ui.notify(`fox-guard blocked ${event.toolName}: ${abs} (${why})`, "warning");
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
				: !l.paths ? `fox-guard cannot ask pi where it lands (${l.why})`
				: judged(abs, true) ?? (grep ? holdsSecret(realish(abs)) ?? holdsSecret(abs) : undefined);
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
