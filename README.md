# AgentOS Instance Template

Your AI agent's brain, as a git repository.

This repo holds the **state** of an AgentOS instance — charter, prompts, skills,
memory, and machine manifests. It contains no runtime. The agent itself is an
AgentOS **node**: a long-running Claude agent with a Telegram interface that
clones this repo, runs on top of the checkout, and syncs what it accumulates
back to git.

**Repo = brain. Node = runtime.**

- The node dies — your context survives. Connect a fresh node and continue.
- Read and edit your agent's memory from any device: plain markdown, git history.
- Push a change — the node picks it up within minutes; what the agent
  accumulates comes back as checkpoint commits.

> **Status:** the AgentOS node is in active development, including
> connect-from-Telegram onboarding (GitHub App + Mini App). Until that lands,
> pointing a node at this repo is a manual step. The previous generation of this
> template — a self-contained VPS deployment (tmux + Dagu + worker fleet) — is
> frozen on the [`v1-vps`](../../tree/v1-vps) branch (tag `v1-final`).

## Layout

| Path | What lives here |
|---|---|
| `CLAUDE.md` | The instance charter — the agent's standing instructions. Yours to edit. |
| `.agentos/` | Machine config the node reads: `workspace.yaml` (managed repos), `deps.yaml` (extra binaries), `routines/` (scheduled routines) |
| `agents/` | Sub-agent definitions and prompts |
| `skills/` | Live skills of this instance (Claude Code skill format) |
| `memory/` | Durable memory the agent curates — owner profile, people, decisions |
| `workspace/` | The agent's working files; clones of managed repos (gitignored) |
| `data/` | Runtime scratch — gitignored, never committed |
| `examples/` | Reference skills and routines to copy from |

This layout is the node's canonical contract: connecting an **empty** repo
scaffolds exactly this skeleton. The template starts you with the same skeleton
plus documentation and examples.

## Getting started

1. **Create your repo from this template.** Make it private — it will hold
   personal context.
2. Fill in `CLAUDE.md` (the charter) and `memory/owner.md` (copy
   `memory/owner._template.md`).
3. Connect the repo to your AgentOS node. To install a node, follow
   [try-agent-os/agentos](https://github.com/try-agent-os/agentos) — or use the
   DigitalOcean button below.
4. Talk to your agent in Telegram — and teach it: skills go to `skills/`,
   scheduled routines to `.agentos/routines/`, knowledge to `memory/`.

## Deploy to DigitalOcean

[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/droplets/new?image=ubuntu-24-04-x64&size=s-2vcpu-4gb&region=fra1&refcode=6f9a0892dd0a&user_data=https%3A%2F%2Fraw.githubusercontent.com%2Ftry-agent-os%2Fagentos%2Fmain%2Fcloud-init.yaml)

One click provisions an Ubuntu 24.04 droplet that boots an **AgentOS node** —
the runtime: a Telegram bot with Claude in-process, a scheduler, and the Mini
App, all from one prebuilt image. cloud-init installs Docker and stages the
installer; you finish with a single SSH command. Nothing is compiled on the
droplet.

**Before you click** (60 seconds):

- A **bot token** from [@BotFather](https://t.me/BotFather) (`/newbot`).
- Your **numeric Telegram id** from [@userinfobot](https://t.me/userinfobot)
  (auto-approves you as admin).

**After the droplet boots** (~1 min), SSH in and run the command the login
banner shows:

```bash
ssh root@<droplet-ip>
bash /opt/agentos-bootstrap/install.sh --no-https --token <BOT_TOKEN> --admin <YOUR_TELEGRAM_ID>
```

That pulls the node image and starts your bot. Then **DM your bot `/login`**
(admin-only) to connect Claude, and send it a message — it replies.

Secrets never touch the deploy URL (which would leak them into your browser
history), so the token is supplied on your own terminal instead of baked into
the button.

**Cost:** the button provisions `s-2vcpu-4gb` (~$24/mo); the node runs on as
little as 2 GB RAM. **Want the Mini App?** Point a DNS A record at the droplet
and swap `--no-https` for `--domain your.host.name` (opens 80+443; Let's
Encrypt cert issued automatically).

Full installation docs — other providers, HTTPS and the Mini App, upgrades,
troubleshooting — live in the node's repo:
**[try-agent-os/agentos](https://github.com/try-agent-os/agentos)**. This
section is just the button; the node repo is the manual.

No DigitalOcean account yet? Signing up through this badge supports the
project:

<a href="https://www.digitalocean.com/?refcode=6f9a0892dd0a&utm_campaign=Referral_Invite&utm_medium=Referral_Program&utm_source=badge"><img src="https://web-platforms.sfo2.cdn.digitaloceanspaces.com/WWW/Badge%201.svg" alt="DigitalOcean Referral Badge" /></a>

## Ground rules

- **No secrets in the repo — ever.** Tokens and keys live in the node
  environment. The sync engine refuses to commit obvious credentials; don't
  lean on it.
- `data/` is scratch and never committed. Durable knowledge belongs in `memory/`.
- Prompts and structure stay in English. The agent's working language is a
  setting in `CLAUDE.md`, not a fork of the tree.

## License

MIT
