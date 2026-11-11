/**
 * desk-credits — pi's Anthropic API replies count on the monthly API credit meter.
 *
 * Only in a pi started by `claude-api pi` (FOXML_API_CREDITS=1): that launcher hands pi the private API key, so
 * every assistant reply from provider "anthropic" is API credit. A pi using a subscription login or a local model is
 * never counted. Each reply is recorded once, by its response ID, with pi's catalog-price cost marked as an estimate,
 * and the footer shows what is left.
 */

import { execFile } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const PROJECT = /^[a-z]{1,20}$/;
const MODEL = /^[A-Za-z0-9._:/[\]-]{1,100}$/;
const whole = (n: unknown): number | undefined => (typeof n === "number" && Number.isInteger(n) && n >= 0 ? n : undefined);

/** The desk-credits record arguments for one pi message, or undefined when it is not tracked API usage. */
export function recordArgs(message: any, project: string | undefined, at: Date, fallbackId: () => string): string[] | undefined {
	if (!message || message.role !== "assistant" || message.provider !== "anthropic" || !message.usage) return undefined;
	const cost = message.usage.cost?.total;
	if (typeof cost !== "number" || !Number.isFinite(cost) || cost < 0) return undefined;
	const model = [message.responseModel, message.model].find((m) => typeof m === "string" && MODEL.test(m));
	const raw = typeof message.responseId === "string" && /^[A-Za-z0-9_-]{1,150}$/.test(message.responseId) ? message.responseId : fallbackId();
	const details: Record<string, unknown> = { source: "pi", label: "pi session" };
	if (model) details.model = model;
	for (const [ours, theirs] of [["input_tokens", "input"], ["output_tokens", "output"], ["cache_read_tokens", "cacheRead"], ["cache_write_tokens", "cacheWrite"]]) {
		const n = whole(message.usage[theirs]);
		if (n !== undefined) details[ours] = n;
	}
	return ["record", "--project", project && PROJECT.test(project) ? project : "other", "--cost-usd", cost.toFixed(6),
		"--id", `pi-${raw}`, "--at", at.toISOString(), "--estimate", "--details", JSON.stringify(details)];
}

export default function (pi: ExtensionAPI) {
	if (process.env.FOXML_API_CREDITS !== "1") return;
	const bin = process.env.FOX_CREDITS_BIN || "desk-credits";
	const run = (args: string[]) =>
		new Promise<string | undefined>((done) =>
			execFile(bin, args, { timeout: 10_000 }, (err, out) => done(err ? undefined : String(out))));
	const footer = async (ctx: any) => {
		try {
			const value = JSON.parse((await run(["status"])) ?? "null");
			if (value && typeof value.short === "string") ctx?.ui?.setStatus?.("desk-credits", value.short);
		} catch {}
	};
	let n = 0;
	pi.on("session_start", async (_event, ctx) => footer(ctx));
	pi.on("message_end", async (event, ctx) => {
		const args = recordArgs(event.message, process.env.FOXML_API_PROJECT, new Date(),
			() => `${process.pid}-${Date.now()}-${++n}`);
		if (!args) return;
		if ((await run(args)) === undefined) ctx?.ui?.notify?.("desk-credits: this reply's cost was not recorded", "warning");
		await footer(ctx);
	});
}
