---
description: Serve a markdown or HTML file (or a folder) over a cloudflared quick tunnel so it can be read on a phone. Use when the user says "show this on my phone", "send it to my phone", "open it from my phone", "md2phone", "preview on phone", "share this doc to my phone", or wants a public link to a local file without deploying anything.
allowed-tools: Bash Read
---

# md2phone — read a local file on your phone

Serves a local file or directory over a **cloudflared quick tunnel** (`*.trycloudflare.com`)
— a temporary public URL, no Cloudflare account or config. Markdown is rendered as a
clean, mobile-friendly GitHub-styled page; HTML is served as-is.

## When to use

The user wants to look at a local document — a generated report, a spec, a dashboard —
on their phone, and there is no deployed URL for it.

## How to run

One command. The script renders, serves, and opens the tunnel, then prints the URL:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/md2phone/scripts/md2phone.sh" <file-or-dir>
```

- `.md` / `.markdown` → rendered to a self-contained HTML page (client-side `marked` +
  `github-markdown-css` from CDN; dark mode follows the phone). Mobile-responsive.
- `.html` → served verbatim.
- a directory → served as-is (its `index.html` if present).
- any other file → served at `<url>/<filename>`.

Then **deliver the printed URL to the user's phone** — it will not reach the phone on its
own.

### Delivering the link to Telegram (preferred convention)

Send the tunnel URL as an **inline url-button**, not as a bare URL in the message text:

```
telegram_send_message(
  chat_id=<id>,
  text="<1–2 line teaser of what the doc is>",
  buttons=[[{"text": "📄 Open report", "url": "<tunnel-url>"}]]
)
```

- The message body is a short teaser; the button carries the link.
- Telegram shows an **"Open this link? Yes/No" confirmation dialog** for buttons that point
  to an external domain (`*.trycloudflare.com`). This is a Telegram limitation — only
  `web_app`/Mini App buttons skip it. For the md2phone stage we accept the confirmation
  dialog as an intermediate step.

### OG preview card

When md2phone renders a markdown file it now injects **Open Graph meta tags**
(`og:title` from the first heading or filename, `og:description` from the first paragraph,
`og:type=article`, plus a `twitter:card`). Telegram fetches these server-side and renders a
**preview card** (title + teaser) for the tunnel link — close to a native instant-view feel,
without any per-domain template. Set `MD2PHONE_OG_IMAGE=<url>` to add an `og:image` thumbnail.

If `telegram-mcp` tools are unavailable, just present the URL clearly so the user can open it.

## Stopping

The static server and the tunnel keep running in the background until stopped:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/md2phone/scripts/md2phone.sh" --stop
```

Offer to stop the tunnel once the user says they are done reading. Starting a new
`md2phone` run stops the previous one automatically.

## Notes

- Requires `cloudflared` and `python3`. The script reports a clear error if either is
  missing. Install `cloudflared` via `brew install cloudflared` (Mac) or Cloudflare's
  apt/rpm repo (Linux — see the `cloudflared` downloads page).
- The tunnel URL is **public** while it is up — anyone with the link can read the file.
  Do not use it for secrets; stop the tunnel when finished.
- Override the local port with `MD2PHONE_PORT` if `8765` is taken.
- Set `MD2PHONE_OG_IMAGE=<url>` to attach an `og:image` thumbnail to the preview card.
- `--render <md>` prints the standalone HTML to stdout without serving — handy for saving
  a shareable HTML file.
