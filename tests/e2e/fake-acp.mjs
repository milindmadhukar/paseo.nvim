#!/usr/bin/env node
// A scripted ACP agent: the e2e provider.
//
// The packaged Paseo daemon ships without its dev-only `mock` provider, so the
// end-to-end checks bring their own -- registered in the throwaway daemon's
// config.json as `"fake": { "extends": "acp", "command": ["node", <this>] }`.
// It speaks just enough of the Agent Client Protocol (JSON-RPC 2.0, one message
// per line on stdio) for Paseo to create a session and run turns, and streams
// the way real models do: reasoning in small chunks, then a tool call, then the
// answer in small chunks. No network, no cost, the same every run.
//
// The prompt picks the script. Words it looks for, any order:
//   think    many reasoning chunks (the thinking-merge regression)
//   tool     a tool call between the reasoning and the answer
//   slow     40ms between chunks instead of 5ms, so a turn can be watched
//   long     a turn that lasts ~20s, for steering and interrupt checks
//   echo     the answer repeats the prompt
// With none of them it does think + tool + a short answer.

import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

const out = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const reply = (id, result) => out({ jsonrpc: "2.0", id, result });
const fail = (id, code, message) => out({ jsonrpc: "2.0", id, error: { code, message } });
const update = (sessionId, body) =>
  out({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: body } });

const sessions = new Map();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const MODES = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Default", description: "Asks before acting" },
    { id: "auto", name: "Auto", description: "Acts without asking" },
  ],
};

// Advertised so Paseo's catalog probe has a model to list: a provider with
// none is hidden from the new-agent screen.
const MODELS = {
  currentModelId: "scripted",
  availableModels: [{ modelId: "scripted", name: "Scripted", description: "The e2e script" }],
};

function words(text) {
  return text.match(/\S+\s*/g) ?? [];
}

function promptText(blocks) {
  return (blocks ?? [])
    .map((block) => (block?.type === "text" ? block.text : ""))
    .join("")
    .trim();
}

async function turn(id, params) {
  const session = sessions.get(params.sessionId);
  if (!session) return fail(id, -32602, `unknown session ${params.sessionId}`);
  const text = promptText(params.prompt);
  const has = (word) => new RegExp(`\\b${word}\\b`, "i").test(text);
  const plain = !["think", "tool", "echo", "long"].some(has);
  const gap = has("slow") ? 40 : has("long") ? 400 : 5;
  const cancelled = () => session.cancelled;
  session.cancelled = false;

  const stream = async (kind, sentence) => {
    for (const chunk of words(sentence)) {
      if (cancelled()) return false;
      update(params.sessionId, {
        sessionUpdate: kind,
        content: { type: "text", text: chunk },
        ...(kind === "agent_message_chunk" ? { messageId: session.messageId } : {}),
      });
      await sleep(gap);
    }
    return true;
  };

  session.messageId = randomUUID();
  if (has("think") || has("long") || plain) {
    const thought =
      "I'm looking at what the user asked for, and I want to check the files " +
      "before answering, because the answer depends on what is actually there.";
    if (!(await stream("agent_thought_chunk", has("long") ? thought.repeat(3) : thought))) {
      return reply(id, { stopReason: "cancelled" });
    }
  }

  if (has("tool") || plain) {
    const toolCallId = `call_${randomUUID().slice(0, 8)}`;
    update(params.sessionId, {
      sessionUpdate: "tool_call",
      toolCallId,
      title: "Read README.md",
      kind: "read",
      status: "in_progress",
      locations: [{ path: `${session.cwd}/README.md` }],
      rawInput: { path: `${session.cwd}/README.md` },
    });
    await sleep(gap * 4);
    update(params.sessionId, {
      sessionUpdate: "tool_call_update",
      toolCallId,
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "# fixture\n" } }],
    });
  }

  const answer = has("echo")
    ? `You said: ${text}`
    : "Done. The fixture has a README and nothing else worth reporting.";
  if (!(await stream("agent_message_chunk", answer))) {
    return reply(id, { stopReason: "cancelled" });
  }
  reply(id, { stopReason: "end_turn" });
}

const handlers = {
  initialize: (id) =>
    reply(id, {
      protocolVersion: 1,
      agentCapabilities: {
        loadSession: false,
        promptCapabilities: { image: true, embeddedContext: true },
      },
      authMethods: [],
    }),
  "session/new": (id, params) => {
    const sessionId = `fake_${randomUUID().slice(0, 12)}`;
    sessions.set(sessionId, { cwd: params?.cwd ?? process.cwd(), cancelled: false });
    reply(id, { sessionId, modes: MODES, models: MODELS });
  },
  "session/prompt": (id, params) => {
    turn(id, params).catch((error) => fail(id, -32603, String(error)));
  },
  "session/cancel": (_id, params) => {
    const session = sessions.get(params?.sessionId);
    if (session) session.cancelled = true;
  },
  "session/set_model": (id) => reply(id, {}),
  "session/set_mode": (id, params) => {
    update(params.sessionId, { sessionUpdate: "current_mode_update", currentModeId: params.modeId });
    reply(id, {});
  },
};

createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (!message.method) return; // a response to something we never send
  const handler = handlers[message.method];
  if (handler) return handler(message.id, message.params);
  if (message.id !== undefined) fail(message.id, -32601, `method not found: ${message.method}`);
});
