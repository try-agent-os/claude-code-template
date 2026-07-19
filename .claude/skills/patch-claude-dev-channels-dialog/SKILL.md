---
name: patch-claude-dev-channels-dialog
description: Use when asked to remove / suppress / get rid of the "WARNING: Loading development channels" startup prompt in Claude Code CLI, or after a Claude Code auto-update brought it back. Triggers on phrases like "kill the dev channels WARNING", "the channels dialog is back", "that yes prompt on every launch", "DevChannelsDialog", "--dangerously-load-development-channels prompt", "re-patch claude like last time". Applies to both macOS (Apple Silicon, requires re-sign) and Linux servers (requires the atomic-mv pattern). NOT for runtime permission prompts (those are `permissions.defaultMode: "bypassPermissions"`).
---

# Patch Claude Code's DevChannelsDialog gate

End-to-end runbook for surgically patching the Claude Code CLI binary so it stops showing the `WARNING: Loading development channels … 1. I am using this for local development` prompt on every launch when you run with `--dangerously-load-development-channels server:<name>` (e.g. `server:claude-peers`).

## When this applies

AgentOS runs Claude Code with `--dangerously-load-development-channels` to wire in self-hosted MCP push channels (e.g. `claude-peers`). The stock CLI shows a confirmation dialog on every launch. There is no settings.json toggle — `skipDangerously*` keys for this do not exist (verified empirically against the runtime schema validator and via issue-tracker search). The only way to suppress it is a binary patch of the gate condition that decides "silent-merge vs show-dialog".

On an unattended server this is not cosmetic: the dialog blocks stdin, so a headless agent session hangs at startup until something types `yes`.

**Apply after:** any Claude Code auto-update (a new `~/.local/share/claude/versions/<NEW>` file appears, the `~/.local/bin/claude` symlink flips, and the patch is gone on the new version). The minified variable names inside the gate change between builds — do NOT assume a previous byte pattern still works; re-find it.

**Do NOT apply** if the pain is "yes-prompts for tool calls" (git push, file edits etc.) — that is `permissions.defaultMode` in `~/.claude/settings.json`, a different mechanism.

## The gate, conceptually

In the bundled JS (embedded in the single-file CLI binary) there is an `if(...) silentMerge(...) else showDialog(...)` block. When the condition is TRUE the channels are silently merged with `dev:true`; when FALSE, `DevChannelsDialog` is rendered. The patch forces the condition to always-TRUE by overwriting it with `if(1` + padding + `)` of the **exact same byte length** — otherwise binary offsets shift and other code breaks.

Pattern shape (var names are minified — they change per build):

```
if(!<X1>()||<X2>()!=="firstParty"||<X3>(<X4>("policySettings")))
```

Observed builds — illustrative only, to show how much the shape drifts:

| Build | Pattern | Len |
|-------|---------|-----|
| macOS arm64, older build | `if(!O()\|\|!M()?.accessToken)` | — (2-clause shape) |
| macOS arm64, 3-clause era | `if(!Y()\|\|Wq()!=="firstParty"\|\|w(j("policySettings")))` | 53 |
| Linux x86_64, same release | `if(!O()\|\|Wq()!=="firstParty"\|\|M(w("policySettings")))` | 53 |
| macOS arm64, later release | `if(!A()\|\|hq()!=="firstParty"\|\|w(j("policySettings")))` | 53 |
| Linux x86_64, later release | `if(!f()\|\|hq()!=="firstParty"\|\|M(j("policySettings")))` | 53 |

Note that the same release has **different** minified names on macOS and Linux, and consecutive releases sometimes keep the pattern byte-identical and sometimes re-minify every identifier. Run the discovery step every time.

## Automated (preferred) — `scripts/ensure-dev-channels-patch.py`

The manual procedure below is the fallback / reference. The durable path is the self-discovering idempotent script `scripts/ensure-dev-channels-patch.py`, which anchor-searches the gate, extracts the condition dynamically (so it survives re-minification), applies the same-length `if(1   )` patch, re-signs on macOS / atomic-mv on Linux, and no-ops if already patched. It needs no per-version editing.

Schedule it so a CC auto-update never leaves you with a blocking dialog:

- **Linux:** Dagu routine `routines/check-dev-channels-patch.yaml` (daily). Belt-and-suspenders on top of an `ExecStartPre` self-heal in your agent's systemd unit.
- **macOS:** a launchd plist running the script daily plus `RunAtLoad`.

After a CC auto-update you usually need to do nothing — the next scheduled run re-patches. Run the manual steps only if the script reports `gate not found` (the build changed shape).

> **macOS gotcha:** invoke the script with `/usr/bin/python3` in your test, not just whatever `python3` resolves to on PATH. The system interpreter can be considerably older than a Homebrew one; the script carries `from __future__ import annotations` so its PEP 604 `X | None` hints parse on Python 3.9, but any helper you add must be tested against the same interpreter launchd will use.

## Procedure

Throughout, `<VER>` is the Claude Code version directory and `<CLAUDE_HOME>` is the account that runs the CLI (`/Users/<user>` on macOS, `/home/<user>` on Linux).

### Step 1 — Locate the binary and check version

```bash
which claude && readlink -f "$(which claude)"
# or, over ssh to the server:
ssh <server> 'readlink -f "$(which claude || echo ~/.local/bin/claude)"'
```

Expected: `<CLAUDE_HOME>/.local/share/claude/versions/<VER>`. Note `<VER>`.

### Step 2 — Anchor-search for `DevChannelsDialog`

The string `DevChannelsDialog` appears several times in the binary. The invocation site (where the gate lives) is identifiable by `createElement` and `policySettings` nearby:

```python
python3 -c "
import re
data = open('/path/to/binary','rb').read()
for p in [m.start() for m in re.finditer(b'DevChannelsDialog', data)]:
    chunk = data[max(0,p-400):p+200]
    if b'createElement' in chunk and b'policySettings' in chunk:
        print('=== invocation @', p, '===')
        print(chunk.decode('latin-1', errors='replace'))
"
```

In the output, look for the `if(!...||...!=="firstParty"||...("policySettings"))` substring just before `[...dev:!0...else{let{DevChannelsDialog:...`. **Copy it byte-for-byte** — including exact paren counts and quotes — as the ORIGINAL pattern.

> On Linux this anchor filter sometimes returns nothing: that build keeps destructure-error strings in a separate region that pollutes the search, and once the binary is already patched there is no `firstParty` left near the gate at all. Fall back to anchoring on `createElement` + `dev:!0`, or just count the patched `if(1` + spaces pattern to confirm the current state.

### Step 3 — Build the same-length replacement

```python
python3 -c "
ORIGINAL = b'if(!O()||Wq()!==\"firstParty\"||M(w(\"policySettings\")))'  # <-- paste from step 2
inner_len = len(ORIGINAL) - 4   # subtract 'if(' and the trailing ')'
PATCHED = b'if(1' + b' ' * (inner_len - 1) + b')'
assert len(PATCHED) == len(ORIGINAL), f'{len(PATCHED)} != {len(ORIGINAL)}'
print(repr(ORIGINAL)); print(repr(PATCHED)); print('len:', len(ORIGINAL))
"
```

For the common 53-byte gate the patched form is `if(1` + **48** spaces + `)` — note 48, i.e. `inner_len - 1`, not 49.

### Step 4 — Back up the binary

```bash
cp <CLAUDE_HOME>/.local/share/claude/versions/<VER> /tmp/claude-<VER>.bak
```

### Step 5 — Apply the patch

**macOS (Apple Silicon)** — a direct write is fine, but Gatekeeper SIGKILLs modified signed binaries (exit 137 on first run). You must re-sign ad-hoc:

```bash
python3 -c "
import pathlib
target = pathlib.Path('<CLAUDE_HOME>/.local/share/claude/versions/<VER>')
ORIGINAL = b'<paste>'
PATCHED  = b'<paste>'
data = target.read_bytes()
print(f'replaced {data.count(ORIGINAL)} occurrence(s)')
target.write_bytes(data.replace(ORIGINAL, PATCHED))
"

# CRITICAL — re-sign, or the binary is SIGKILLed by macOS:
codesign --force --sign - <CLAUDE_HOME>/.local/share/claude/versions/<VER>

# Smoke test:
<CLAUDE_HOME>/.local/share/claude/versions/<VER> --version   # -> "<VER> (Claude Code)"
```

**Linux** — no codesign needed, BUT `write_bytes` fails with `OSError [Errno 26] Text file busy` if any process has the binary open (a running agent, dispatcher, etc.). Use the atomic-mv pattern:

```bash
python3 - <<'PY'
import pathlib, shutil
VER = "<VER>"
target = pathlib.Path.home() / ".local/share/claude/versions" / VER
tmp = pathlib.Path(f"/tmp/claude-{VER}.patched")
ORIGINAL = b'<paste>'
PATCHED  = b'<paste>'
data = target.read_bytes()
n = data.count(ORIGINAL)
tmp.write_bytes(data.replace(ORIGINAL, PATCHED))
shutil.move(str(tmp), str(target))
target.chmod(0o755)
print(f"replaced {n} via atomic mv")
PY
```

Why atomic mv: running processes keep their original inode, new launches resolve the new one. No need to stop services.

### Step 6 — Verify the dialog is gone

Restart Claude Code with your normal flags (`--dangerously-load-development-channels server:<name> --channels server:<name>`). Expected: no WARNING prompt, the channel loads silently.

If the dialog still appears: the pattern was wrong (a typo in a minified name) or you hit a stale binary — verify the occurrence count was exactly 1 and that the replacement actually wrote (count `if(1` + spaces occurrences in the post-patch binary).

## Rollback

```bash
# macOS
cp /tmp/claude-<VER>.bak <CLAUDE_HOME>/.local/share/claude/versions/<VER>
codesign --force --sign - <CLAUDE_HOME>/.local/share/claude/versions/<VER>

# Linux (atomic mv — processes may still hold the file)
cp /tmp/claude-<VER>.bak /tmp/claude-<VER>.restore
mv /tmp/claude-<VER>.restore ~/.local/share/claude/versions/<VER>
chmod 0755 ~/.local/share/claude/versions/<VER>
```

## Auto-update caveat

Claude Code auto-updates create a new `versions/<NEW>` file and flip the `~/.local/bin/claude` symlink. The previously patched binary is left behind (it still works if invoked by full path) but new sessions launch the unpatched version. On the next occurrence:

1. Detect the new `<NEW>` (compare `readlink -f "$(which claude)"` to the last known value).
2. Re-run steps 1–5 against the new binary — and redo the anchor search, because the minified names will likely have changed.

The patch is not persistent across upgrades by design. That is exactly why the scheduled script above exists.

## Related (do NOT confuse)

- **Yes-prompts for tool calls** (git push, file edits) — `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json`. Different mechanism, separate fix.
- **`skipDangerousModePermissionPrompt: true`** — suppresses the "are you sure about bypass mode?" dialog, NOT this dev-channels dialog.
- **Settings keys one might mistake for a toggle:** `channelsEnabled`, `allowedChannelPlugins`, the `--channels` flag. None of these suppress the WARNING for `--dangerously-load-development-channels`.

## Provenance

Original approach: https://gist.github.com/OhadRubin/0fda6190aa700696a16d961a980d0038 (macOS, an older 2-clause build, custom-pinned binary path). Since adapted for the 3-clause gate on both macOS arm64 and Linux x86_64, and generalised into the self-discovering script so that ongoing re-minification stops being a manual chore.
