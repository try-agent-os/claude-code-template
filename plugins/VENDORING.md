# Vendored Plugins

This directory holds plugins copied verbatim from upstream sources. They are bundled with the AgentOS template so that a fresh clone + install delivers a working default toolkit without runtime network dependencies.

## Source

All four currently vendored plugins come from the official Anthropic `claude-code` repository:

- Repo: https://github.com/anthropics/claude-code
- Pinned commit: `fb063cd5e0716c2369955c8a9811849ba85f21d3`
- Vendored on: 2026-05-07

Per-plugin source URLs (also recorded in `.claude-plugin/marketplace.json`):

| Plugin | Upstream path |
|--------|---------------|
| `agent-sdk-dev` | `plugins/agent-sdk-dev/` |
| `code-review` | `plugins/code-review/` |
| `commit-commands` | `plugins/commit-commands/` |
| `security-guidance` | `plugins/security-guidance/` |

Each plugin keeps its original `.claude-plugin/plugin.json` (with upstream `version: "1.0.0"`). The marketplace entry pins each one at `version: "vendored-fb063cd"` to make it obvious that the bundled copy is locked to an upstream snapshot, not the upstream `1.0.0` release name.

## What is *not* vendored

The following upstream plugins are intentionally excluded from the default bundle (see `/tmp/template-audit-claudecode.md`):

- **Skipped entirely**: `claude-opus-4-5-migration`, `explanatory-output-style`, `learning-output-style`, `pr-review-toolkit`, `ralph-wiggum`.
- **Optional, available via `install.sh --with=...`**: `feature-dev`, `frontend-design`, `hookify`, `plugin-dev`. These are not vendored here; the install script fetches them on demand.

AgentOS-native plugins (`template-dev`, `agentos-core`) are listed in `marketplace.json` as placeholders and live under `./plugins/` once implemented. They are **not** vendored — they are first-party.

## Refreshing

Refresh policy: review upstream once per minor release of `claude-code`, or when a vendored plugin has a bugfix we need.

Refresh script (to be added in a later task): `scripts/refresh-vendored-plugins.sh`. The script will:

1. Clone or fast-forward a local mirror of `https://github.com/anthropics/claude-code`.
2. Capture the new HEAD commit SHA.
3. For each vendored plugin name, `cp -r` upstream `plugins/<name>/` over `./plugins/<name>/` in this repo.
4. Update `version: "vendored-<sha>"` and the `source:` URL in `.claude-plugin/marketplace.json` for each refreshed plugin.
5. Update the pinned commit and date at the top of this file.
6. Print a diff summary so the operator can review before committing.

Until that script lands, refreshes are manual: follow the same six steps by hand.

## License

Upstream `claude-code` is MIT-licensed (see https://github.com/anthropics/claude-code/blob/main/LICENSE.md). Vendored copies retain MIT licensing; redistribution within the AgentOS template is compliant with that license. The AgentOS template itself is also MIT (see top-level `LICENSE`). No attribution beyond the source URLs in `marketplace.json` and this file is required by upstream, but we keep both for traceability.
