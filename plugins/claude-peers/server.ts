#!/usr/bin/env bun
/**
 * claude-peers MCP server
 *
 * Spawned by Claude Code as a stdio MCP server (one per instance).
 * Connects to the shared broker daemon for peer discovery and messaging.
 * Declares claude/channel capability to push inbound messages immediately.
 *
 * Usage:
 *   claude --dangerously-load-development-channels server:claude-peers
 *
 * With .mcp.json:
 *   { "claude-peers": { "command": "bun", "args": ["./server.ts"] } }
 *
 * Environment:
 *   CLAUDE_PEERS_SLUG     — optional persistent slug claimed at registration
 *                           (explicit override; used verbatim if set)
 *   CLAUDE_PEERS_HOST_ID  — short host alias for the slug prefix (e.g. "mac",
 *                           "hub"). Defaults to the first label of
 *                           os.hostname(), lowercased ("Mac.home" -> "mac").
 *   CLAUDE_PEERS_AGENT    — agent name (e.g. "operator", "sysadmin"). When set
 *                           (and CLAUDE_PEERS_SLUG is not) the slug becomes
 *                           `${host_id}:${agent}`. When unset, the agent name is
 *                           auto-derived from CLAUDE_PROJECT_DIR (.../agents/<name>),
 *                           so agents are host-aware with zero per-agent env —
 *                           Claude Code only forwards a curated env allowlist to
 *                           stdio MCP servers, so injected vars are unreliable.
 */

import os from "os";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type {
  PeerId,
  Peer,
  RegisterResponse,
  PollMessagesResponse,
  ClaimSlugResponse,
  Message,
} from "./shared/types.ts";
import {
  generateSummary,
  getGitBranch,
  getRecentFiles,
} from "./shared/summarize.ts";

// --- Configuration ---

const BROKER_PORT = parseInt(process.env.CLAUDE_PEERS_PORT ?? "7899", 10);
// Broker host. Defaults to loopback (local broker). Set CLAUDE_PEERS_HOST to a
// reachable address (e.g. a tailnet/VPN IP such as 100.x.y.z) to connect this MCP
// client to a central broker on another host over the mesh. When set to a
// remote host, do NOT rely on broker auto-launch — run the broker on that host.
const BROKER_HOST = process.env.CLAUDE_PEERS_HOST ?? "127.0.0.1";
const BROKER_URL = `http://${BROKER_HOST}:${BROKER_PORT}`;
const POLL_INTERVAL_MS = 1000;
const HEARTBEAT_INTERVAL_MS = 15_000;
const BROKER_SCRIPT = new URL("./broker.ts", import.meta.url).pathname;

// --- Broker communication ---

async function brokerFetch<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${BROKER_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Broker error (${path}): ${res.status} ${err}`);
  }
  return res.json() as Promise<T>;
}

async function isBrokerAlive(): Promise<boolean> {
  try {
    const res = await fetch(`${BROKER_URL}/health`, { signal: AbortSignal.timeout(2000) });
    return res.ok;
  } catch {
    return false;
  }
}

async function ensureBroker(): Promise<void> {
  if (await isBrokerAlive()) {
    log("Broker already running");
    return;
  }

  log("Starting broker daemon...");
  const proc = Bun.spawn(["bun", BROKER_SCRIPT], {
    stdio: ["ignore", "ignore", "inherit"],
  });

  proc.unref();

  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 200));
    if (await isBrokerAlive()) {
      log("Broker started");
      return;
    }
  }
  throw new Error("Failed to start broker daemon after 6 seconds");
}

// --- Utility ---

function log(msg: string) {
  console.error(`[claude-peers] ${msg}`);
}

async function getGitRoot(cwd: string): Promise<string | null> {
  try {
    const proc = Bun.spawn(["git", "rev-parse", "--show-toplevel"], {
      cwd,
      stdout: "pipe",
      stderr: "ignore",
    });
    const text = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code === 0) {
      return text.trim();
    }
  } catch {
    // not a git repo
  }
  return null;
}

function getTty(): string | null {
  try {
    const ppid = process.ppid;
    if (ppid) {
      const proc = Bun.spawnSync(["ps", "-o", "tty=", "-p", String(ppid)]);
      const tty = new TextDecoder().decode(proc.stdout).trim();
      if (tty && tty !== "?" && tty !== "??") {
        return tty;
      }
    }
  } catch {
    // ignore
  }
  return null;
}

// --- State ---

let myId: PeerId | null = null;
let mySlug: string | null = null;
let myCwd = process.cwd();
let myGitRoot: string | null = null;
// os.hostname() — the real machine host, used by the broker for host-aware
// liveness (PID check vs heartbeat TTL). Separate concept from the slug prefix.
const myHost = os.hostname();
// Short host alias used only as the slug prefix. Prefer CLAUDE_PEERS_HOST_ID;
// otherwise normalise os.hostname() to its first label, lowercased
// (e.g. "hub" stays "hub", "Mac.home" -> "mac"). This keeps slugs
// short and stable even when no env is injected (Claude Code passes only a
// curated env allowlist to stdio MCP servers, so we cannot rely on it).
const myHostId =
  process.env.CLAUDE_PEERS_HOST_ID || myHost.split(".")[0].toLowerCase();

// Derive the agent name when CLAUDE_PEERS_AGENT is not set, from
// CLAUDE_PROJECT_DIR (reliably present in the MCP child env) when it points at
// an `.../agents/<name>` directory — e.g. ".../agents/operator" -> "operator".
// Returns undefined for non-agent sessions (workers, ad-hoc dirs), leaving them
// slug-less, exactly as before.
function deriveAgentName(): string | undefined {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || myCwd;
  const m = projectDir.match(/\/agents\/([a-z0-9][a-z0-9-]*)\/?$/);
  return m ? m[1].toLowerCase() : undefined;
}

// --- MCP Server ---

const mcp = new Server(
  { name: "claude-peers", version: "0.2.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: {},
    },
    instructions: `You are connected to the claude-peers network. Other Claude Code instances on this machine can see you and send you messages.

IMPORTANT: When you receive a <channel source="claude-peers" ...> message, RESPOND IMMEDIATELY. Do not wait until your current task is finished. Pause what you are doing, reply to the message using send_message, then resume your work. Treat incoming peer messages like a coworker tapping you on the shoulder — answer right away, even if you're in the middle of something.

Read the from_id, from_slug, from_host, from_summary, and from_cwd attributes to understand who sent the message. Slugs follow the scheme <host>:<agent> (e.g. "hub:operator", "mac:operator"). Reply by calling send_message with their from_id or from_slug.

Available tools:
- get_my_id: Get your peer ID, slug, and connection info
- claim_slug: Claim a persistent slug (stable across restarts, e.g. "operator")
- list_peers: Discover other Claude Code instances (scope: machine/directory/repo)
- send_message: Send a message to another instance by peer ID or slug
- set_summary: Set a 1-2 sentence summary of what you're working on (visible to other peers)
- check_messages: Manually check for new messages

You can send messages using slugs (e.g., send_message(to_id: "operator", ...)) instead of random peer IDs. Slugs persist across restarts.

When you start, proactively call set_summary to describe what you're working on. This helps other instances understand your context.`,
  }
);

// --- Tool definitions ---

const TOOLS = [
  {
    name: "get_my_id",
    description:
      "Get this peer's ID, slug, and connection info. Useful for self-identification in reports.",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "claim_slug",
    description:
      'Claim a persistent slug for this peer session. The slug persists across restarts — when re-registering with the same slug, pending messages are inherited. If the slug is already claimed by this peer, this is a no-op success.',
    inputSchema: {
      type: "object" as const,
      properties: {
        slug: {
          type: "string" as const,
          description:
            'Persistent identifier following the <host>:<agent> scheme (e.g. "hub:operator", "mac:operator"). Lowercase alphanumeric + dashes, with at most one colon separator, max 64 chars. Plain slugs without a colon (e.g. "operator") also work for backward compatibility.',
        },
      },
      required: ["slug"],
    },
  },
  {
    name: "list_peers",
    description:
      "List other Claude Code instances running on this machine. Returns their ID, slug, working directory, git repo, and summary.",
    inputSchema: {
      type: "object" as const,
      properties: {
        scope: {
          type: "string" as const,
          enum: ["machine", "directory", "repo"],
          description:
            'Scope of peer discovery. "machine" = all instances on this computer. "directory" = same working directory. "repo" = same git repository (including worktrees or subdirectories).',
        },
      },
      required: ["scope"],
    },
  },
  {
    name: "send_message",
    description:
      'Send a message to another Claude Code instance by peer ID or slug. The message will be pushed into their session immediately via channel notification. You can use a slug (e.g. "operator") instead of the random peer ID.',
    inputSchema: {
      type: "object" as const,
      properties: {
        to_id: {
          type: "string" as const,
          description:
            'The peer ID or slug of the target Claude Code instance (from list_peers)',
        },
        message: {
          type: "string" as const,
          description: "The message to send",
        },
      },
      required: ["to_id", "message"],
    },
  },
  {
    name: "set_summary",
    description:
      "Set a brief summary (1-2 sentences) of what you are currently working on. This is visible to other Claude Code instances when they list peers.",
    inputSchema: {
      type: "object" as const,
      properties: {
        summary: {
          type: "string" as const,
          description: "A 1-2 sentence summary of your current work",
        },
      },
      required: ["summary"],
    },
  },
  {
    name: "check_messages",
    description:
      "Manually check for new messages from other Claude Code instances. Messages are normally pushed automatically via channel notifications, but you can use this as a fallback.",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
];

// --- Tool handlers ---

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  switch (name) {
    case "get_my_id": {
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(
              {
                id: myId,
                slug: mySlug,
                host: myHost,
                host_id: myHostId,
                cwd: myCwd,
                pid: process.pid,
                tty: getTty(),
              },
              null,
              2
            ),
          },
        ],
      };
    }

    case "claim_slug": {
      const { slug } = args as { slug: string };
      if (!myId) {
        return {
          content: [{ type: "text" as const, text: "Not registered with broker yet" }],
          isError: true,
        };
      }
      try {
        const result = await brokerFetch<ClaimSlugResponse>("/claim-slug", {
          id: myId,
          slug,
        });
        if (!result.ok) {
          return {
            content: [
              { type: "text" as const, text: `Failed to claim slug: ${result.error}` },
            ],
            isError: true,
          };
        }
        mySlug = result.slug;
        return {
          content: [
            {
              type: "text" as const,
              text: `Slug "${result.slug}" claimed successfully. Peers can now reach you via this slug.`,
            },
          ],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Error claiming slug: ${e instanceof Error ? e.message : String(e)}`,
            },
          ],
          isError: true,
        };
      }
    }

    case "list_peers": {
      const scope = (args as { scope: string }).scope as "machine" | "directory" | "repo";
      try {
        const peers = await brokerFetch<Peer[]>("/list-peers", {
          scope,
          cwd: myCwd,
          git_root: myGitRoot,
          exclude_id: myId,
        });

        if (peers.length === 0) {
          return {
            content: [
              {
                type: "text" as const,
                text: `No other Claude Code instances found (scope: ${scope}).`,
              },
            ],
          };
        }

        const lines = peers.map((p) => {
          const parts = [
            `ID: ${p.id}`,
          ];
          if (p.slug) parts.push(`Slug: ${p.slug}`);
          if (p.host) parts.push(`Host: ${p.host}`);
          parts.push(`PID: ${p.pid}`);
          parts.push(`CWD: ${p.cwd}`);
          if (p.git_root) parts.push(`Repo: ${p.git_root}`);
          if (p.tty) parts.push(`TTY: ${p.tty}`);
          if (p.summary) parts.push(`Summary: ${p.summary}`);
          parts.push(`Last seen: ${p.last_seen}`);
          return parts.join("\n  ");
        });

        return {
          content: [
            {
              type: "text" as const,
              text: `Found ${peers.length} peer(s) (scope: ${scope}):\n\n${lines.join("\n\n")}`,
            },
          ],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Error listing peers: ${e instanceof Error ? e.message : String(e)}`,
            },
          ],
          isError: true,
        };
      }
    }

    case "send_message": {
      const { to_id, message } = args as { to_id: string; message: string };
      if (!myId) {
        return {
          content: [{ type: "text" as const, text: "Not registered with broker yet" }],
          isError: true,
        };
      }
      try {
        const result = await brokerFetch<{ ok: boolean; error?: string }>("/send-message", {
          from_id: myId,
          to_id,
          text: message,
        });
        if (!result.ok) {
          return {
            content: [{ type: "text" as const, text: `Failed to send: ${result.error}` }],
            isError: true,
          };
        }
        return {
          content: [{ type: "text" as const, text: `Message sent to peer ${to_id}` }],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Error sending message: ${e instanceof Error ? e.message : String(e)}`,
            },
          ],
          isError: true,
        };
      }
    }

    case "set_summary": {
      const { summary } = args as { summary: string };
      if (!myId) {
        return {
          content: [{ type: "text" as const, text: "Not registered with broker yet" }],
          isError: true,
        };
      }
      try {
        await brokerFetch("/set-summary", { id: myId, summary });
        return {
          content: [{ type: "text" as const, text: `Summary updated: "${summary}"` }],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Error setting summary: ${e instanceof Error ? e.message : String(e)}`,
            },
          ],
          isError: true,
        };
      }
    }

    case "check_messages": {
      if (!myId) {
        return {
          content: [{ type: "text" as const, text: "Not registered with broker yet" }],
          isError: true,
        };
      }
      try {
        const result = await brokerFetch<PollMessagesResponse>("/poll-messages", { id: myId });
        if (result.messages.length === 0) {
          return {
            content: [{ type: "text" as const, text: "No new messages." }],
          };
        }
        const lines = result.messages.map(
          (m) => `From ${m.from_id} (${m.sent_at}):\n${m.text}`
        );
        return {
          content: [
            {
              type: "text" as const,
              text: `${result.messages.length} new message(s):\n\n${lines.join("\n\n---\n\n")}`,
            },
          ],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Error checking messages: ${e instanceof Error ? e.message : String(e)}`,
            },
          ],
          isError: true,
        };
      }
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// --- Polling loop for inbound messages ---

async function pollAndPushMessages() {
  if (!myId) return;

  try {
    const result = await brokerFetch<PollMessagesResponse>("/poll-messages", { id: myId });

    for (const msg of result.messages) {
      let fromSummary = "";
      let fromCwd = "";
      let fromSlug = "";
      let fromHost = "";
      try {
        const peers = await brokerFetch<Peer[]>("/list-peers", {
          scope: "machine",
          cwd: myCwd,
          git_root: myGitRoot,
        });
        const sender = peers.find((p) => p.id === msg.from_id);
        if (sender) {
          fromSummary = sender.summary;
          fromCwd = sender.cwd;
          fromSlug = sender.slug ?? "";
          fromHost = sender.host ?? "";
        }
      } catch {
        // Non-critical
      }

      await mcp.notification({
        method: "notifications/claude/channel",
        params: {
          content: msg.text,
          meta: {
            from_id: msg.from_id,
            from_slug: fromSlug,
            from_summary: fromSummary,
            from_cwd: fromCwd,
            from_host: fromHost,
            sent_at: msg.sent_at,
          },
        },
      });

      log(`Pushed message from ${msg.from_id}${fromSlug ? ` (${fromSlug})` : ""}: ${msg.text.slice(0, 80)}`);
    }
  } catch (e) {
    log(`Poll error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// --- Startup ---

async function main() {
  await ensureBroker();

  myCwd = process.cwd();
  myGitRoot = await getGitRoot(myCwd);
  const tty = getTty();

  // Slug construction (precedence):
  //   1. CLAUDE_PEERS_SLUG set        -> use verbatim (manual override / back-compat)
  //   2. agent name resolved          -> `${myHostId}:${agent}` (e.g. hub:operator)
  //      where agent = CLAUDE_PEERS_AGENT, else derived from CLAUDE_PROJECT_DIR
  //      (.../agents/<name>). host-id = CLAUDE_PEERS_HOST_ID or normalised hostname.
  //   3. no agent resolvable          -> no slug (null), as before (workers, ad-hoc)
  const explicitSlug = process.env.CLAUDE_PEERS_SLUG || undefined;
  const agent = process.env.CLAUDE_PEERS_AGENT || deriveAgentName();
  const envSlug = explicitSlug ?? (agent ? `${myHostId}:${agent}` : undefined);

  log(`CWD: ${myCwd}`);
  log(`Git root: ${myGitRoot ?? "(none)"}`);
  log(`TTY: ${tty ?? "(unknown)"}`);
  log(`Host: ${myHost} (host-id alias: ${myHostId})`);
  if (explicitSlug) {
    log(`Slug (from CLAUDE_PEERS_SLUG): ${envSlug}`);
  } else if (agent) {
    log(`Slug (host:agent): ${envSlug}`);
  }

  let initialSummary = "";
  const summaryPromise = (async () => {
    try {
      const branch = await getGitBranch(myCwd);
      const recentFiles = await getRecentFiles(myCwd);
      const summary = await generateSummary({
        cwd: myCwd,
        git_root: myGitRoot,
        git_branch: branch,
        recent_files: recentFiles,
      });
      if (summary) {
        initialSummary = summary;
        log(`Auto-summary: ${summary}`);
      }
    } catch (e) {
      log(`Auto-summary failed (non-critical): ${e instanceof Error ? e.message : String(e)}`);
    }
  })();

  await Promise.race([summaryPromise, new Promise((r) => setTimeout(r, 3000))]);

  const reg = await brokerFetch<RegisterResponse>("/register", {
    pid: process.pid,
    cwd: myCwd,
    git_root: myGitRoot,
    tty,
    summary: initialSummary,
    slug: envSlug,
    host: os.hostname(),
  });
  myId = reg.id;
  mySlug = reg.slug ?? null;
  log(`Registered as peer ${myId}${mySlug ? ` (slug: ${mySlug})` : ""}`);

  if (!initialSummary) {
    summaryPromise.then(async () => {
      if (initialSummary && myId) {
        try {
          await brokerFetch("/set-summary", { id: myId, summary: initialSummary });
          log(`Late auto-summary applied: ${initialSummary}`);
        } catch {
          // Non-critical
        }
      }
    });
  }

  await mcp.connect(new StdioServerTransport());
  log("MCP connected");

  const pollTimer = setInterval(pollAndPushMessages, POLL_INTERVAL_MS);

  const heartbeatTimer = setInterval(async () => {
    if (myId) {
      try {
        await brokerFetch("/heartbeat", { id: myId });
      } catch {
        // Non-critical
      }
    }
  }, HEARTBEAT_INTERVAL_MS);

  const cleanup = async () => {
    clearInterval(pollTimer);
    clearInterval(heartbeatTimer);
    if (myId) {
      try {
        await brokerFetch("/unregister", { id: myId });
        log("Unregistered from broker");
      } catch {
        // Best effort
      }
    }
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
}

main().catch((e) => {
  log(`Fatal: ${e instanceof Error ? e.message : String(e)}`);
  process.exit(1);
});
