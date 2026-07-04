#!/usr/bin/env python3
"""md2quill — convert a subset of Markdown to ClickUp's Quill-style comment.comment block array.

ClickUp v2 task comments don't render `**markdown**` in `comment_text` — but DO render
formatting via the `comment` array (Quill blocks: `{text, attributes:{bold,italic,code,...}}`).

This converts a subset of Markdown to Quill blocks. Supported:
  - Bold:           **text**, __text__
  - Italic:         _text_, *text*   (only when unambiguous w/r/t bold)
  - Inline code:    `text`
  - Strikethrough:  ~~text~~
  - Links:          [label](url)        → text with `link` attribute
  - Headings:       leading "## " etc.   → header attr in trailing newline block
  - Bullet lists:   leading "- " or "* " → list:"bullet" attr in trailing newline
  - Numbered:       leading "1. "        → list:"ordered" attr in trailing newline
  - Paragraphs:     blank-line separator → \\n\\n
Outputs JSON array on stdout. Reads input markdown from stdin.

Limitation: nested bold-in-italic (or vice versa) becomes single attribute. Tables/images skipped.
"""
import json
import re
import sys

INLINE_PATTERNS = [
    # (regex, attribute_dict) — order matters: longer/distinct delimiters first
    (re.compile(r"\*\*(.+?)\*\*"), {"bold": True}),
    (re.compile(r"__(.+?)__"),    {"bold": True}),
    (re.compile(r"~~(.+?)~~"),    {"strike": True}),
    (re.compile(r"`(.+?)`"),      {"code": True}),
    (re.compile(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"), {"italic": True}),
    (re.compile(r"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"),       {"italic": True}),
]
LINK_RE = re.compile(r"\[(.+?)\]\((https?://[^)\s]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$")
BULLET_RE = re.compile(r"^[\-\*]\s+(.+)$")
NUMBERED_RE = re.compile(r"^\d+\.\s+(.+)$")


def parse_inline(text):
    """Split text into Quill blocks honoring inline formatting + links.

    Returns a list of {text, attributes?} dicts. No trailing newline is added here.
    """
    if not text:
        return []
    # First handle links — replace each [label](url) with a sentinel, parse remainder, then re-inject.
    parts = []
    pos = 0
    for m in LINK_RE.finditer(text):
        if m.start() > pos:
            parts.extend(parse_inline_plain(text[pos:m.start()]))
        parts.append({"text": m.group(1), "attributes": {"link": m.group(2)}})
        pos = m.end()
    if pos < len(text):
        parts.extend(parse_inline_plain(text[pos:]))
    return parts


def parse_inline_plain(text):
    """Handle bold/italic/code/strike — recursively split at the FIRST matching delimiter."""
    if not text:
        return []
    earliest = None
    for regex, attrs in INLINE_PATTERNS:
        m = regex.search(text)
        if m and (earliest is None or m.start() < earliest[0]):
            earliest = (m.start(), m, attrs)
    if not earliest:
        return [{"text": text}]
    _, m, attrs = earliest
    blocks = []
    if m.start() > 0:
        blocks.append({"text": text[:m.start()]})
    inner = m.group(1)
    # Recurse on inner — but merge attributes
    inner_blocks = parse_inline_plain(inner)
    for ib in inner_blocks:
        merged = dict(attrs)
        merged.update(ib.get("attributes", {}))
        blocks.append({"text": ib["text"], "attributes": merged})
    if m.end() < len(text):
        blocks.extend(parse_inline_plain(text[m.end():]))
    return blocks


def emit_line_blocks(line):
    """Convert one logical line of markdown to Quill blocks + a trailing line-attribute newline.

    Returns a list of blocks ending in a newline block whose attributes describe the LINE
    (header, list bullet, etc.) — that's how Quill applies block-level formatting.
    """
    # Detect heading
    m = HEADING_RE.match(line)
    if m:
        level = len(m.group(1))
        body = parse_inline(m.group(2))
        nl = {"text": "\n", "attributes": {"header": min(level, 3)}}
        return body + [nl]
    # Detect bullet
    m = BULLET_RE.match(line)
    if m:
        body = parse_inline(m.group(1))
        nl = {"text": "\n", "attributes": {"list": "bullet"}}
        return body + [nl]
    # Detect numbered
    m = NUMBERED_RE.match(line)
    if m:
        body = parse_inline(m.group(1))
        nl = {"text": "\n", "attributes": {"list": "ordered"}}
        return body + [nl]
    # Plain paragraph line
    return parse_inline(line) + [{"text": "\n"}]


def md_to_quill(md):
    blocks = []
    lines = md.split("\n")
    for ln in lines:
        if ln == "":
            blocks.append({"text": "\n"})
            continue
        blocks.extend(emit_line_blocks(ln))
    # Coalesce adjacent text-only blocks with identical attributes (cleaner output)
    out = []
    for b in blocks:
        if out and b.get("attributes") == out[-1].get("attributes"):
            out[-1]["text"] += b["text"]
        else:
            out.append(b)
    return out


def main():
    md = sys.stdin.read()
    print(json.dumps(md_to_quill(md), ensure_ascii=False))


if __name__ == "__main__":
    main()
