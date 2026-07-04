#!/usr/bin/env python3
"""Idempotently patch Claude Code's DevChannelsDialog gate so it never prompts.

Claude Code shows a blocking "WARNING: Loading development channels … 1. I am
using this for local development" dialog on every launch when started with
`--dangerously-load-development-channels`. There is no settings toggle. The only
fix is a binary patch that forces the silent-merge branch.

This script is SELF-DISCOVERING and IDEMPOTENT — safe to run on every operator
boot. The minified variable names inside the gate change between Claude Code
builds, so we anchor-search the `DevChannelsDialog` invocation site and extract
the gate condition dynamically rather than hardcoding a byte pattern.

Gate shape (var names vary per build):
    if(!X1()||X2()!=="firstParty"||X3(X4("policySettings")))  silentMerge  else  showDialog

We overwrite the inner condition with `1` + spaces of the EXACT same byte length
(so binary offsets don't shift), turning it into `if(1            )` → always true
→ channels merge silently, dialog never renders.

Platforms:
  - macOS (Darwin): direct write, then `codesign --force --sign -` (else Gatekeeper
    SIGKILLs the modified signed binary, exit 137 on first run).
  - Linux: atomic mv (write tmp + rename) so running processes keep their inode;
    no codesign needed.

Exit codes: 0 = patched now OR already patched (success/no-op). 1 = error.

Usage:
    ensure-dev-channels-patch.py [path-to-claude-binary]
If no path given, resolves `claude` on PATH via realpath.
"""

from __future__ import (
    annotations,
)  # PEP 604 `X | None` annotations work on Python 3.9 (/usr/bin/python3 on macOS)

import os
import re
import shutil
import subprocess
import sys
import tempfile

LOG_PREFIX = "[dev-channels-patch]"


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", flush=True)


def resolve_binary(argv: list[str]) -> str:
    if len(argv) > 1:
        return os.path.realpath(argv[1])
    found = shutil.which("claude")
    if not found:
        # Non-interactive shells (ssh, systemd without a login PATH) may not have
        # ~/.local/bin on PATH. Fall back to the conventional launcher location.
        fallback = os.path.expanduser("~/.local/bin/claude")
        if os.path.exists(fallback):
            found = fallback
    if not found:
        log(
            "ERROR: `claude` not found on PATH, no ~/.local/bin/claude, and no path arg"
        )
        sys.exit(1)
    return os.path.realpath(found)


def find_gate(data: bytes) -> tuple[int, int, bytes] | None:
    """Locate the DevChannelsDialog gate. Returns (start, end, original_bytes)
    of the `if(...policySettings...))` condition, or None if not found."""
    for m in re.finditer(b"DevChannelsDialog", data):
        p = m.start()
        chunk_start = max(0, p - 600)
        chunk = data[chunk_start : p + 120]
        # Render-helper varies by build: older builds use `createElement`,
        # 2.1.186+ minifies JSX to `av.jsx(`/`jsxs(`. Accept any; the real
        # discriminator for the gate site is `policySettings` + the gate_re below.
        if b"policySettings" not in chunk:
            continue
        if (b"createElement" not in chunk and b".jsx(" not in chunk
                and b"jsxs(" not in chunk):
            continue
        # The gate is the LAST `if(...policySettings...))` before DevChannelsDialog.
        # Match a balanced-ish condition: if( ... policySettings ... ) ) immediately
        # followed by a non-`{` char (the silent-merge call), with the else-branch
        # carrying DevChannelsDialog.
        gate_re = re.compile(rb'if\((?:(?!if\().){0,200}?policySettings"\)\)\)')
        gm = None
        for cand in gate_re.finditer(chunk):
            gm = cand  # take the last one inside this chunk
        if gm:
            abs_start = chunk_start + gm.start()
            abs_end = chunk_start + gm.end()
            return (abs_start, abs_end, data[abs_start:abs_end])
    return None


def is_already_patched(data: bytes) -> bool:
    """True if a DevChannelsDialog invocation chunk already carries the
    `if(1   )` neutralised gate.

    NOTE: after patching, the `policySettings` literal that lived INSIDE the
    gate is overwritten with spaces, so we must NOT require it here (only
    `find_gate`, which runs on the un-patched binary, may rely on it). The
    `if(1` + 3-plus spaces + `)` shape is distinctive enough on its own."""
    for m in re.finditer(b"DevChannelsDialog", data):
        p = m.start()
        chunk = data[max(0, p - 600) : p + 200]
        if re.search(rb"if\(1 {3,}\)", chunk):
            return True
    return False


def build_replacement(original: bytes) -> bytes:
    """if(<cond>) -> if(1<spaces>) of identical byte length."""
    assert original.startswith(b"if(") and original.endswith(b")")
    inner_len = len(original) - len(b"if(") - len(b")")  # bytes between if( and final )
    patched = b"if(1" + b" " * (inner_len - 1) + b")"
    assert len(patched) == len(original), f"{len(patched)} != {len(original)}"
    return patched


def apply_patch(binary: str, original: bytes, patched: bytes) -> int:
    data = open(binary, "rb").read()
    n = data.count(original)
    if n != 1:
        log(f"ERROR: expected exactly 1 gate occurrence, found {n} — refusing to patch")
        return 1
    new_data = data.replace(original, patched)

    # Backup once per binary (by realpath basename = version).
    ver = os.path.basename(binary)
    backup = os.path.join(tempfile.gettempdir(), f"claude-{ver}.devchan.bak")
    if not os.path.exists(backup):
        shutil.copy2(binary, backup)
        log(f"backup -> {backup}")

    if sys.platform == "darwin":
        with open(binary, "wb") as f:
            f.write(new_data)
        # Re-sign ad-hoc or Gatekeeper SIGKILLs the modified signed binary.
        try:
            subprocess.run(
                ["codesign", "--force", "--sign", "-", binary],
                check=True,
                capture_output=True,
                text=True,
            )
            log("re-signed (codesign --force --sign -)")
        except subprocess.CalledProcessError as e:
            log(f"ERROR: codesign failed: {e.stderr.strip()}")
            # Restore to avoid leaving an unsigned (unrunnable) binary.
            shutil.copy2(backup, binary)
            return 1
    else:
        # Linux: atomic mv so running processes keep their open inode.
        d = os.path.dirname(binary)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".claude-patch-")
        with os.fdopen(fd, "wb") as f:
            f.write(new_data)
        os.chmod(tmp, 0o755)
        os.replace(tmp, binary)

    log(f"patched gate ({len(original)} bytes) — dialog suppressed")
    return 0


def main() -> int:
    binary = resolve_binary(sys.argv)
    if not os.path.isfile(binary):
        log(f"ERROR: not a file: {binary}")
        return 1

    data = open(binary, "rb").read()
    if is_already_patched(data):
        log(f"already patched: {binary} — no-op")
        return 0

    gate = find_gate(data)
    if gate is None:
        log(
            f"ERROR: DevChannelsDialog gate not found in {binary} "
            "(build changed shape? re-inspect manually)"
        )
        return 1

    _, _, original = gate
    log(f"found gate: {original.decode('latin-1')}")
    patched = build_replacement(original)
    return apply_patch(binary, original, patched)


if __name__ == "__main__":
    sys.exit(main())
