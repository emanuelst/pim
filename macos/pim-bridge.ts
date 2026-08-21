import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const agentDir = process.env.PIM_AGENT_DIR ?? process.env.PI_CODING_AGENT_DIR ?? path.join(os.homedir(), ".pi", "agent");
const statusPath = path.join(agentDir, `pim-status-${process.pid}.json`);
const role = process.env.PIM_BACKGROUND === "1" ? "background" : "foreground";

function publish(session: string | undefined, state: "idle" | "working" | "stopped"): void {
	if (state === "stopped") {
		try { fs.unlinkSync(statusPath); } catch {}
		return;
	}
	fs.mkdirSync(path.dirname(statusPath), { recursive: true });
	fs.writeFileSync(statusPath, JSON.stringify({ session, state, role, pid: process.pid, updatedAt: Date.now() }));
}

export default function pimBridge(pi: ExtensionAPI) {
	pi.registerCommand("pim-resume", {
		description: "Switch Pim to a session",
		handler: async (args, ctx) => {
			const file = Buffer.from(args.trim(), "base64").toString("utf8");
			if (!file.endsWith(".jsonl")) return;
			await ctx.switchSession(file);
		},
	});

	pi.on("session_start", (_event, ctx) => {
		publish(ctx.sessionManager.getSessionFile(), "idle");
	});
	pi.on("session_shutdown", () => publish(undefined, "stopped"));
	pi.on("agent_start", (_event, ctx) => publish(ctx.sessionManager.getSessionFile(), "working"));
	pi.on("agent_settled", (_event, ctx) => publish(ctx.sessionManager.getSessionFile(), "idle"));
}
