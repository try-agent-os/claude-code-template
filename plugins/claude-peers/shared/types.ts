// Unique ID for each Claude Code instance (generated on registration)
export type PeerId = string;

export interface Peer {
  id: PeerId;
  pid: number;
  cwd: string;
  git_root: string | null;
  tty: string | null;
  slug: string | null;
  summary: string;
  status: "online" | "offline";
  // Originating host (os.hostname() of the peer's machine). Null for legacy
  // clients that predate host-aware federation — treated as local by the broker.
  host: string | null;
  registered_at: string; // ISO timestamp
  last_seen: string; // ISO timestamp
}

export interface Message {
  id: number;
  from_id: PeerId;
  to_id: PeerId;
  text: string;
  sent_at: string; // ISO timestamp
  delivered: boolean;
}

// --- Broker API types ---

export interface RegisterRequest {
  pid: number;
  cwd: string;
  git_root: string | null;
  tty: string | null;
  summary: string;
  slug?: string;
  // os.hostname() of the registering peer. Used by the broker to apply
  // host-aware liveness (PID check for same-host, heartbeat TTL for remote).
  host?: string;
}

export interface RegisterResponse {
  id: PeerId;
  slug?: string;
}

export interface ClaimSlugRequest {
  id: PeerId;
  slug: string;
}

export interface ClaimSlugResponse {
  ok: boolean;
  slug: string;
  error?: string;
}

export interface HeartbeatRequest {
  id: PeerId;
}

export interface SetSummaryRequest {
  id: PeerId;
  summary: string;
}

export interface ListPeersRequest {
  scope: "machine" | "directory" | "repo";
  // The requesting peer's context (used for filtering)
  cwd: string;
  git_root: string | null;
  exclude_id?: PeerId;
}

export interface SendMessageRequest {
  from_id: PeerId;
  to_id: PeerId;
  text: string;
}

export interface PollMessagesRequest {
  id: PeerId;
}

export interface PollMessagesResponse {
  messages: Message[];
}
