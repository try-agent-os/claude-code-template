# Vendored Plugins

This directory holds plugins copied verbatim from upstream sources. They are bundled with the AgentOS template so that a fresh clone + install delivers a working default toolkit without runtime network dependencies.

## Sources

### Upstream Anthropic defaults

Four plugins from the official Anthropic `claude-code` repository:

- Repo: https://github.com/anthropics/claude-code
- Pinned commit: `fb063cd5e0716c2369955c8a9811849ba85f21d3`
- Vendored on: 2026-05-07

| Plugin | Upstream path |
|--------|---------------|
| `agent-sdk-dev` | `plugins/agent-sdk-dev/` |
| `code-review` | `plugins/code-review/` |
| `commit-commands` | `plugins/commit-commands/` |
| `security-guidance` | `plugins/security-guidance/` |

Each plugin keeps its original `.claude-plugin/plugin.json` (with upstream `version: "1.0.0"`). The marketplace entry pins each one at `version: "vendored-fb063cd"` to make it obvious that the bundled copy is locked to an upstream snapshot, not the upstream `1.0.0` release name.

### AgentOS channel plugins (single-server tools + channel push)

Two plugins from internal Novo Studio repos. Both expose tool calls AND `claude/channel` capability from one stdio MCP server (operator gets push when launched with `--channels plugin:<name>@agentos`; other agents get tools only).

| Plugin | Repo | Upstream commit | Vendored on |
|--------|------|-----------------|-------------|
| `claude-peers` | `novostudiotech/claude-peers-mcp` | `fc2649154d6c5aa94ae4fc766989d7f247be0617` | 2026-05-07 |
| `telegram` | `novostudiotech/telegram-mcp` | `3f6171ecf6e33d38669b6f0676f0ff336e731303` | 2026-05-07 |

Marketplace entries pin them at `version: "vendored-fc26491"` and `version: "vendored-3f6171e"` respectively.

#### What's NOT vendored (channel plugins)

**`claude-peers`:**
- `node_modules/` — installed by `install.sh` via `bun install`.
- `.git/` — vendored copies are not git checkouts.
- `.mcp.json` — replaced by the plugin-canonical `mcp.json` at plugin root pointing at `${CLAUDE_PLUGIN_ROOT}/server.ts`.

**`telegram`:**
- `node_modules/` — installed by `install.sh` via `npm install`.
- `.git/`, `.claude/` — local dev artifacts.
- `messages.db`, `messages.db-shm`, `messages.db-wal` — runtime SQLite database (created on first start).
- `messages.json` — runtime conversation cache (also created on first start).
- `models/` — Whisper voice-transcription models (hundreds of MB; downloaded lazily by `nodejs-whisper` on first transcription).
- `.env` — local secrets; `userConfig` (bot_token, user_id) replaces it via plugin manifest.

**Heavy runtime dependencies for `telegram`** are NOT bundled and must be installed by `install.sh`:
- `ffmpeg` (voice → wav for Whisper)
- `yt-dlp` (video download)
- `cmake`, `bubblewrap` (apt packages required by `nodejs-whisper`'s native compile step)

The `dist/` directory IS vendored (precompiled JS) so the plugin runs without a TypeScript compile step at install time. If the upstream source changes, refresh the snapshot AND re-run `npm run build` before committing.

## What is *not* vendored (Anthropic defaults)

The following upstream plugins are intentionally excluded from the default bundle (see `/tmp/template-audit-claudecode.md`):

- **Skipped entirely**: `claude-opus-4-5-migration`, `explanatory-output-style`, `learning-output-style`, `pr-review-toolkit`, `ralph-wiggum`.
- **Optional, available via `install.sh --with=...`**: `feature-dev`, `frontend-design`, `hookify`, `plugin-dev`. These are not vendored here; the install script fetches them on demand.

AgentOS-native plugins (`template-dev`, `agentos-core`) are listed in `marketplace.json` as placeholders and live under `./plugins/` once implemented. They are **not** vendored — they are first-party.

## Refreshing

Refresh policy: review upstream once per minor release of `claude-code` for the Anthropic four; for AgentOS channel plugins, refresh when bugfixes land in the source repos.

Refresh script (to be added in a later task): `scripts/refresh-vendored-plugins.sh`. The script will:

1. Clone or fast-forward a local mirror of each upstream repo.
2. Capture the new HEAD commit SHA.
3. For each vendored plugin name, `cp -r` (with the same exclude rules used during initial vendoring) upstream `<plugin>/` over `./plugins/<plugin>/` in this repo.
4. Update `version: "vendored-<sha>"` and the `source:` URL in `.claude-plugin/marketplace.json` for each refreshed plugin.
5. Update the pinned commit and date in this file.
6. Print a diff summary so the operator can review before committing.

Until that script lands, refreshes are manual: follow the same six steps by hand.

## License

- **Upstream `claude-code`** is MIT-licensed (see https://github.com/anthropics/claude-code/blob/main/LICENSE.md). Vendored copies retain MIT licensing.
- **`claude-peers-mcp` and `telegram-mcp`** are first-party Novo Studio code, MIT-licensed.
- **AgentOS template** itself is also MIT (see top-level `LICENSE`).

Redistribution within the AgentOS template is compliant. No attribution beyond the source URLs in `marketplace.json` and this file is required, but we keep both for traceability.
