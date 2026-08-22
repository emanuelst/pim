import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const agentDir = process.env.PIM_AGENT_DIR ?? process.env.PI_CODING_AGENT_DIR ?? path.join(os.homedir(), ".pi", "agent");
const statusPath = path.join(agentDir, `pim-status-${process.pid}.json`);
const role = process.env.PIM_BACKGROUND === "1" ? "background" : "foreground";
const ownerPid = Number(process.env.PIM_OWNER_PID);
type ActivityState = "idle" | "working";
let currentSession: string | undefined;
let currentState: ActivityState = "idle";
let interactiveReady = false;

function publish(session: string | undefined, state: ActivityState | "stopped"): void {
	if (state === "stopped") {
		try { fs.unlinkSync(statusPath); } catch {}
		return;
	}
	fs.mkdirSync(path.dirname(statusPath), { recursive: true });
	const temporaryPath = `${statusPath}.${process.pid}.tmp`;
	fs.writeFileSync(temporaryPath, JSON.stringify({
		version: 2,
		session,
		state,
		role,
		pid: process.pid,
		...(Number.isInteger(ownerPid) && ownerPid > 0 ? { ownerPid } : {}),
		updatedAt: Date.now(),
	}));
	fs.renameSync(temporaryPath, statusPath);
}

const heartbeat = setInterval(() => {
	if (interactiveReady && currentSession) publish(currentSession, currentState);
}, 2_000);
(heartbeat as NodeJS.Timeout).unref?.();

export default function pimBridge(pi: ExtensionAPI) {
	pi.registerCommand("pim-resume", {
		description: "Switch Pim to a session",
		handler: async (args, ctx) => {
			const file = Buffer.from(args.trim(), "base64").toString("utf8");
			if (!file.endsWith(".jsonl")) return;
			await ctx.switchSession(file);
		},
	});

	const publishWhenInteractive = (session: string | undefined) => {
		interactiveReady = false;
		setImmediate(() => {
			if (currentSession !== session || !session) return;
			interactiveReady = true;
			publish(session, currentState);
		});
	};

	pi.on("session_start", (_event, ctx) => {
		currentSession = ctx.sessionManager.getSessionFile();
		currentState = "idle";
		publishWhenInteractive(currentSession);
	});
	pi.on("session_switch", (_event, ctx) => {
		currentSession = ctx.sessionManager.getSessionFile();
		currentState = "idle";
		publishWhenInteractive(currentSession);
	});
	pi.on("session_shutdown", () => {
		interactiveReady = false;
		currentSession = undefined;
		publish(undefined, "stopped");
	});
	pi.on("agent_start", (_event, ctx) => {
		currentSession = ctx.sessionManager.getSessionFile();
		currentState = "working";
		interactiveReady = true;
		publish(currentSession, currentState);
	});
	pi.on("agent_settled", (_event, ctx) => {
		currentSession = ctx.sessionManager.getSessionFile();
		currentState = "idle";
		interactiveReady = true;
		publish(currentSession, currentState);
	});
}
