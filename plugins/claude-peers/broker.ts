#!/usr/bin/env bun
/**
 * claude-peers broker daemon
 *
 * A singleton HTTP server on localhost:7899 backed by SQLite.
 * Tracks all registered Claude Code peers and routes messages between them.
 * Supports persistent slugs for stable peer identification across restarts.
 *
 * Auto-launched by the MCP server if not already running.
 * Run directly: bun broker.ts
 */

import { Database } from "bun:sqlite";
import os from "os";
import type {
  RegisterRequest,
  RegisterResponse,
  HeartbeatRequest,
  SetSummaryRequest,
  ListPeersRequest,
  SendMessageRequest,
  PollMessagesRequest,
  PollMessagesResponse,
  ClaimSlugRequest,
  ClaimSlugResponse,
  Peer,
  Message,
} from "./shared/types.ts";

const PORT = parseInt(process.env.CLAUDE_PEERS_PORT ?? "7899", 10);
// Bind interface. Defaults to loopback (single-host, original behaviour).
// Set "0.0.0.0" (restrict with a firewall, e.g. allow :7899 only on tailscale0)
// to let peers on other hosts federate against a central broker over a mesh.
const BIND = process.env.CLAUDE_PEERS_BIND ?? "127.0.0.1";
const DB_PATH = process.env.CLAUDE_PEERS_DB ?? `${process.env.HOME}/.claude-peers.db`;

// --- Host-aware liveness ---
// This broker's own host id. Same-host peers are checked via process.kill(pid,0);
// remote-host peers (cross-host federation over a mesh) can't be PID-checked here,
// so their liveness is based on heartbeat freshness only.
const BROKER_OWN_HOST = os.hostname();
// A remote peer is considered alive if it heartbeated within this window.
// server.ts heartbeats every 15s; 60s gives 4x slack for cross-host latency/restarts.
const HEARTBEAT_TTL_MS = parseInt(process.env.CLAUDE_PEERS_HEARTBEAT_TTL_MS ?? "60000", 10);

// --- Database setup ---

const db = new Database(DB_PATH);
db.run("PRAGMA journal_mode = WAL");
db.run("PRAGMA busy_timeout = 3000");

db.run(`
  CREATE TABLE IF NOT EXISTS peers (
    id TEXT PRIMARY KEY,
    pid INTEGER NOT NULL,
    cwd TEXT NOT NULL,
    git_root TEXT,
    tty TEXT,
    summary TEXT NOT NULL DEFAULT '',
    registered_at TEXT NOT NULL,
    last_seen TEXT NOT NULL
  )
`);

db.run(`
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_id TEXT NOT NULL,
    to_id TEXT NOT NULL,
    text TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    delivered INTEGER NOT NULL DEFAULT 0
  )
`);

// --- Schema migration (idempotent) ---

const cols = (db.query("PRAGMA table_info(peers)").all() as { name: string }[]).map(
  (c) => c.name
);

if (!cols.includes("slug")) {
  db.run("ALTER TABLE peers ADD COLUMN slug TEXT");
}
if (!cols.includes("status")) {
  db.run("ALTER TABLE peers ADD COLUMN status TEXT NOT NULL DEFAULT 'online'");
}
if (!cols.includes("host")) {
  // Nullable: legacy rows (and legacy clients) have no host and are treated as local.
  db.run("ALTER TABLE peers ADD COLUMN host TEXT");
}

db.run(
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_peers_slug_online ON peers(slug) WHERE slug IS NOT NULL AND status = 'online'"
);

// --- Stale peer cleanup ---

function cleanStalePeers() {
  const peers = db
    .query("SELECT id, pid, host, last_seen FROM peers WHERE status = 'online'")
    .all() as { id: string; pid: number; host: string | null; last_seen: string }[];
  for (const peer of peers) {
    if (!isPeerAlive(peer)) {
      db.run("UPDATE peers SET status = 'offline' WHERE id = ?", [peer.id]);
    }
  }
  // Purge offline peers older than 7 days
  db.run(
    "DELETE FROM peers WHERE status = 'offline' AND last_seen < datetime('now', '-7 days')"
  );
  // Purge delivered messages older than 1 day
  db.run(
    "DELETE FROM messages WHERE delivered = 1 AND sent_at < datetime('now', '-1 day')"
  );
}

cleanStalePeers();
setInterval(cleanStalePeers, 30_000);

// --- Prepared statements ---

const insertPeer = db.prepare(`
  INSERT INTO peers (id, pid, cwd, git_root, tty, slug, summary, host, status, registered_at, last_seen)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'online', ?, ?)
`);

const updateLastSeen = db.prepare(`
  UPDATE peers SET last_seen = ? WHERE id = ?
`);

const updateSummary = db.prepare(`
  UPDATE peers SET summary = ? WHERE id = ?
`);

const markPeerOffline = db.prepare(`
  UPDATE peers SET status = 'offline' WHERE id = ?
`);

const selectAllOnlinePeers = db.prepare(`
  SELECT * FROM peers WHERE status = 'online'
`);

const selectPeersByDirectoryOnline = db.prepare(`
  SELECT * FROM peers WHERE cwd = ? AND status = 'online'
`);

const selectPeersByGitRootOnline = db.prepare(`
  SELECT * FROM peers WHERE git_root = ? AND status = 'online'
`);

const insertMessage = db.prepare(`
  INSERT INTO messages (from_id, to_id, text, sent_at, delivered)
  VALUES (?, ?, ?, ?, 0)
`);

const selectUndelivered = db.prepare(`
  SELECT * FROM messages WHERE to_id = ? AND delivered = 0 ORDER BY sent_at ASC
`);

const markDelivered = db.prepare(`
  UPDATE messages SET delivered = 1 WHERE id = ?
`);

// --- Generate peer ID ---

function generateId(): string {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  let id = "";
  for (let i = 0; i < 8; i++) {
    id += chars[Math.floor(Math.random() * chars.length)];
  }
  return id;
}

// --- Check if PID is alive ---

function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    // EPERM = the process EXISTS but is owned by another uid. On a shared host
    // the broker runs as one user while sibling instances run their peers under
    // other uids; probing those PIDs with signal 0 throws EPERM, which must be
    // treated as ALIVE. Only ESRCH (no such process) means the peer is truly
    // dead. Without this, cross-user same-host peers register and then get
    // reaped on the next liveness sweep, never appearing in list-peers.
    return (e as NodeJS.ErrnoException)?.code === "EPERM";
  }
}

// --- Host-aware peer liveness ---
// For peers originating on the broker's own host (or legacy peers with no host),
// liveness is the existing PID check. For peers on a different host (cross-host
// federation), the PID doesn't exist locally, so liveness is heartbeat freshness.
function isPeerAlive(peer: { pid: number; host: string | null; last_seen: string }): boolean {
  const isRemote = peer.host != null && peer.host !== BROKER_OWN_HOST;
  if (!isRemote) {
    return isPidAlive(peer.pid);
  }
  const lastSeenMs = Date.parse(peer.last_seen);
  if (Number.isNaN(lastSeenMs)) return false;
  return Date.now() - lastSeenMs < HEARTBEAT_TTL_MS;
}

// --- Request handlers ---

function handleRegister(body: RegisterRequest): RegisterResponse {
  const now = new Date().toISOString();

  // Mark any existing online registration for this PID as offline
  const existingByPid = db
    .query("SELECT id FROM peers WHERE pid = ? AND status = 'online'")
    .get(body.pid) as { id: string } | null;
  if (existingByPid) {
    markPeerOffline.run(existingByPid.id);
  }

  // If slug provided, try to reclaim an existing row
  if (body.slug) {
    const existingBySlug = db
      .query("SELECT id, pid, status FROM peers WHERE slug = ?")
      .get(body.slug) as { id: string; pid: number; status: string } | null;

    if (existingBySlug) {
      if (existingBySlug.status === "online") {
        if (isPidAlive(existingBySlug.pid)) {
          throw new Error(
            `Slug "${body.slug}" is already claimed by live peer ${existingBySlug.id}`
          );
        }
        // Process dead but still marked online — fix it
        markPeerOffline.run(existingBySlug.id);
      }

      // Reclaim: update existing row, inherit pending messages
      db.run(
        `UPDATE peers SET pid = ?, cwd = ?, git_root = ?, tty = ?, summary = ?, host = ?,
                          status = 'online', last_seen = ?, registered_at = ?
         WHERE id = ?`,
        [body.pid, body.cwd, body.git_root, body.tty, body.summary, body.host ?? null, now, now, existingBySlug.id]
      );

      return { id: existingBySlug.id, slug: body.slug };
    }
  }

  // Create new peer
  const id = generateId();
  insertPeer.run(
    id,
    body.pid,
    body.cwd,
    body.git_root,
    body.tty,
    body.slug ?? null,
    body.summary,
    body.host ?? null,
    now,
    now
  );
  return { id, slug: body.slug };
}

function handleHeartbeat(body: HeartbeatRequest): void {
  updateLastSeen.run(new Date().toISOString(), body.id);
}

function handleSetSummary(body: SetSummaryRequest): void {
  updateSummary.run(body.summary, body.id);
}

function handleListPeers(body: ListPeersRequest): Peer[] {
  let peers: Peer[];

  switch (body.scope) {
    case "machine":
      peers = selectAllOnlinePeers.all() as Peer[];
      break;
    case "directory":
      peers = selectPeersByDirectoryOnline.all(body.cwd) as Peer[];
      break;
    case "repo":
      if (body.git_root) {
        peers = selectPeersByGitRootOnline.all(body.git_root) as Peer[];
      } else {
        peers = selectPeersByDirectoryOnline.all(body.cwd) as Peer[];
      }
      break;
    default:
      peers = selectAllOnlinePeers.all() as Peer[];
  }

  if (body.exclude_id) {
    peers = peers.filter((p) => p.id !== body.exclude_id);
  }

  // Verify liveness (host-aware), mark dead peers offline
  return peers.filter((p) => {
    if (isPeerAlive(p)) return true;
    markPeerOffline.run(p.id);
    return false;
  });
}

function handleSendMessage(body: SendMessageRequest): { ok: boolean; error?: string } {
  let targetId = body.to_id;

  // Try direct ID lookup first
  const byId = db
    .query("SELECT id FROM peers WHERE id = ?")
    .get(body.to_id) as { id: string } | null;

  if (!byId) {
    // Try slug resolution (online peers only)
    const bySlug = db
      .query("SELECT id FROM peers WHERE slug = ? AND status = 'online'")
      .get(body.to_id) as { id: string } | null;

    if (!bySlug) {
      return { ok: false, error: `No peer found with id or slug "${body.to_id}"` };
    }
    targetId = bySlug.id;
  }

  insertMessage.run(body.from_id, targetId, body.text, new Date().toISOString());
  return { ok: true };
}

function handlePollMessages(body: PollMessagesRequest): PollMessagesResponse {
  const messages = selectUndelivered.all(body.id) as Message[];
  for (const msg of messages) {
    markDelivered.run(msg.id);
  }
  return { messages };
}

function handleUnregister(body: { id: string }): void {
  markPeerOffline.run(body.id);
}

function handleClaimSlug(body: ClaimSlugRequest): ClaimSlugResponse {
  // Allow a single ":" separator for the <host>:<agent> scheme (e.g.
  // "hub:operator"). Still lowercase-alnum start, then lowercase-alnum,
  // dash, or colon; max 64 chars to fit host:agent. Plain slugs (no colon)
  // remain valid — this is a strict superset of the old pattern.
  if (!/^[a-z0-9][a-z0-9:-]{0,63}$/.test(body.slug)) {
    return {
      ok: false,
      slug: body.slug,
      error:
        "Slug must be 1-64 chars, start with lowercase alphanumeric, contain only lowercase alphanumeric, dashes, and at most one colon (host:agent)",
    };
  }
  // Permit at most one colon (the host:agent separator); reject "a:b:c".
  if ((body.slug.match(/:/g)?.length ?? 0) > 1) {
    return {
      ok: false,
      slug: body.slug,
      error: "Slug may contain at most one colon (the host:agent separator)",
    };
  }

  const peer = db
    .query("SELECT id, slug FROM peers WHERE id = ? AND status = 'online'")
    .get(body.id) as { id: string; slug: string | null } | null;
  if (!peer) {
    return { ok: false, slug: body.slug, error: "Peer not found or offline" };
  }

  // Already has this slug — no-op
  if (peer.slug === body.slug) {
    return { ok: true, slug: body.slug };
  }

  // Check if slug is taken by another online peer
  const holder = db
    .query("SELECT id, pid FROM peers WHERE slug = ? AND status = 'online' AND id != ?")
    .get(body.slug, body.id) as { id: string; pid: number } | null;

  if (holder) {
    if (isPidAlive(holder.pid)) {
      return {
        ok: false,
        slug: body.slug,
        error: `Slug "${body.slug}" is already claimed by live peer ${holder.id}`,
      };
    }
    // Holder is dead — mark offline
    markPeerOffline.run(holder.id);
  }

  // Clear slug from offline peers to avoid any ambiguity
  db.run("UPDATE peers SET slug = NULL WHERE slug = ? AND id != ?", [body.slug, body.id]);

  db.run("UPDATE peers SET slug = ? WHERE id = ?", [body.slug, body.id]);
  return { ok: true, slug: body.slug };
}

function handleGetMyId(body: { id: string }): Peer | null {
  return db
    .query("SELECT * FROM peers WHERE id = ?")
    .get(body.id) as Peer | null;
}

// --- HTTP Server ---

Bun.serve({
  port: PORT,
  hostname: BIND,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    if (req.method !== "POST") {
      if (path === "/health") {
        return Response.json({
          status: "ok",
          peers: (selectAllOnlinePeers.all() as Peer[]).length,
        });
      }
      return new Response("claude-peers broker", { status: 200 });
    }

    try {
      const body = await req.json();

      switch (path) {
        case "/register":
          return Response.json(handleRegister(body as RegisterRequest));
        case "/heartbeat":
          handleHeartbeat(body as HeartbeatRequest);
          return Response.json({ ok: true });
        case "/set-summary":
          handleSetSummary(body as SetSummaryRequest);
          return Response.json({ ok: true });
        case "/list-peers":
          return Response.json(handleListPeers(body as ListPeersRequest));
        case "/send-message":
          return Response.json(handleSendMessage(body as SendMessageRequest));
        case "/poll-messages":
          return Response.json(handlePollMessages(body as PollMessagesRequest));
        case "/unregister":
          handleUnregister(body as { id: string });
          return Response.json({ ok: true });
        case "/claim-slug":
          return Response.json(handleClaimSlug(body as ClaimSlugRequest));
        case "/get-my-id":
          return Response.json(handleGetMyId(body as { id: string }));
        default:
          return Response.json({ error: "not found" }, { status: 404 });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return Response.json({ error: msg }, { status: 400 });
    }
  },
});

console.error(`[claude-peers broker] listening on ${BIND}:${PORT} (db: ${DB_PATH})`);
