---
name: telegram-formatting
description: Reference for formatting agent messages in Telegram via the Bot API parse_mode (HTML) — the supported tag subset, blockquote / expandable blockquote, tables, and the separate rich-message method. Use before sending formatted messages so markup renders instead of leaking as raw characters.
---

# Telegram message formatting (parse_mode HTML)

When an agent sends a message to Telegram via the Bot API, formatting requires a `parse_mode`. Without it, markup characters render literally (e.g. a raw `<b>` shows as text). Prefer `parse_mode: "HTML"` together with the supported HTML subset below. Plain text (no tags) is always safe; reach for tags when structure genuinely helps.

## Supported HTML tags (parse_mode HTML)

Telegram renders ONLY this subset. Any other tag (`ul`, `li`, `table`, `h1`, `div`, ...) is unsupported — do not use it:

- `b`, `strong` — bold
- `i`, `em` — italic
- `u`, `ins` — underline
- `s`, `strike`, `del` — strikethrough
- `tg-spoiler` (or `span class="tg-spoiler"`) — spoiler
- `a href="..."` — link, including `tg://user?id=<id>` inline mentions
- `tg-emoji emoji-id="..."` — custom (premium) emoji
- `tg-time` — formatted timestamp
- `code` — inline monospace
- `pre` — preformatted block; use `<pre><code class="language-xx">...</code></pre>` for syntax-highlighted code
- `blockquote` — block quote (Bot API 7.0)
- `blockquote expandable` — collapsible block quote (Bot API 7.4)

Escape literal `<`, `>`, `&` inside text as `&lt;`, `&gt;`, `&amp;`.

## Quotes and long sections — blockquote

- `<blockquote>…</blockquote>` (Bot API 7.0) — quote a person's words or a document excerpt; visually separates quoted text from the agent's own.
- `<blockquote expandable>…</blockquote>` (Bot API 7.4) — default for long sections (more than ~5-6 lines: detailed breakdowns, logs, diffs). It collapses in the chat and expands on tap, so long reports do not flood a phone screen. In long reports, wrap the bulky part in an expandable blockquote instead of sending a wall of text.

## Tables

`parse_mode` has NO native table support. Render tabular data as a monospaced `<pre>…</pre>` block with fixed-width columns.

Native tables and other rich content are a SEPARATE Bot API method — `sendRichMessage` (Bot API 10.1) — and are not part of `parse_mode`. Until your bot bridge implements that method, use `<pre>` for tables and `<blockquote expandable>` for long content.
