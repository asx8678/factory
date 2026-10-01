/**
 * Factory's extension for pi, loaded when Factory runs an agent on pi (Factory.Runtime).
 *
 * pi doesn't take MCP servers and never asks before it uses a tool, so this does both
 * jobs over Factory's MCP endpoint:
 *
 *   - Factory's tools (the plan's, a run's) are registered as pi tools and passed on.
 *   - Before every other tool pi runs, Factory is asked whether the agent may
 *     (Factory.Kiro.Permit), and a no blocks the tool. Factory unreachable is a no.
 *
 * From the environment: FACTORY_MCP_URL, FACTORY_MCP_TOKEN (the tools' token, empty
 * when the session has none) and FACTORY_PERMIT_TOKEN.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const url = process.env.FACTORY_MCP_URL || "";
const token = process.env.FACTORY_MCP_TOKEN || "";
const permit = process.env.FACTORY_PERMIT_TOKEN || "";

let nextId = 1;

// One JSON-RPC request to Factory. JSON only: a tool that would ask the person now
// (an event stream) gets Factory's fallback, the question shown when the turn ends.
async function rpc(method: string, params: unknown, signal?: AbortSignal): Promise<any> {
	const headers: Record<string, string> = { "content-type": "application/json", accept: "application/json" };
	if (token) headers.authorization = `Bearer ${token}`;
	if (permit) headers["x-factory-permit"] = permit;

	const response = await fetch(url, {
		method: "POST",
		headers,
		body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
		signal,
	});

	const message = await response.json();
	if (message.error) throw new Error(message.error.message || "Factory refused the request.");
	return message.result;
}

function text(result: any): string {
	return (result?.content || [])
		.filter((part: any) => part?.type === "text")
		.map((part: any) => part.text)
		.join("\n");
}

export default async function (pi: ExtensionAPI) {
	if (!url) return;

	const own = new Set<string>();

	// Factory's tools for this session. Without a token there are none to call.
	if (token) {
		try {
			const { tools } = await rpc("tools/list", {});

			for (const tool of tools || []) {
				own.add(tool.name);

				pi.registerTool({
					name: tool.name,
					label: tool.name,
					description: tool.description,
					parameters: tool.inputSchema || { type: "object", properties: {} },
					async execute(_toolCallId: string, params: unknown, signal?: AbortSignal) {
						const result = await rpc("tools/call", { name: tool.name, arguments: params || {} }, signal);
						// A failed tool is thrown, so pi shows the model an error result.
						if (result?.isError) throw new Error(text(result));
						return { content: [{ type: "text", text: text(result) }], details: undefined };
					},
				});
			}
		} catch (error) {
			console.error(`Factory's tools couldn't be loaded: ${error}`);
		}
	}

	// Factory decides what the agent may run. Its own tools check for themselves.
	pi.on("tool_call", async (event: any) => {
		if (own.has(event.toolName)) return undefined;

		try {
			const answer = await rpc("factory/permit", {
				tool: event.toolName,
				input: event.input || {},
				cwd: process.cwd(),
			});

			if (answer?.allow) return undefined;
			return { block: true, reason: `Factory refused it: ${answer?.reason || "not allowed"}.` };
		} catch (error) {
			return { block: true, reason: `Factory couldn't be asked whether this is allowed (${error}).` };
		}
	});
}
