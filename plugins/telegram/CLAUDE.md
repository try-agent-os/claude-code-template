# Telegram MCP Server

Telegram bot + MCP server for Claude Code. Single process, stable connection.

## Stack
- Node.js + TypeScript
- grammY (Telegram bot framework)
- @modelcontextprotocol/sdk (MCP server)
- better-sqlite3 (SQLite + FTS5)
- nodejs-whisper (local voice transcription via whisper.cpp)

## Commands
```bash
npm run build    # tsc
npm run dev      # tsx src/index.ts
npm start        # node dist/index.js
```

## Structure
```
src/
  index.ts    — entry: MCP server + grammY bot startup
  bot.ts      — grammY setup, message handler
  db.ts       — SQLite init, CRUD, FTS search
  access.ts   — access policy (allowlist/pending/deny)
  tools.ts    — MCP tool definitions
  types.ts    — shared types
```

## Environment Variables
- `TELEGRAM_BOT_TOKEN` — bot token (required)
- `WHISPER_MODEL` — `tiny | small | medium | large`. Default `small`. Determines which `ggml-<name>.bin` is loaded.
- `WHISPER_SERVER_URL` — optional. When set, transcription POSTs to that whisper-server `/inference` endpoint instead of spawning whisper-cli per call. Default on Linux installs (`http://127.0.0.1:8088`); unset on Mac (Metal is fast enough per-call).

## Setup prerequisites

See `SETUP.md` for full instructions. Key things to keep in mind when making changes or deploying:

- **System deps**: `cmake`, `ffmpeg`, `pkg-config`, `libopenblas-dev` (Linux) must be installed (not npm deps). Missing cmake → whisper.cpp won't build → voice transcription silently fails. Missing libopenblas-dev → encoder is ~1.7x slower on CPU-only droplets.
- **Whisper model**: `ggml-<WHISPER_MODEL>.bin` must be downloaded into `node_modules/nodejs-whisper/cpp/whisper.cpp/models/`. Not in git, not auto-downloaded in non-TTY. See SETUP.md for the command. small = 244MB (sweet spot for CPU + Russian voice); medium = 1.5GB.
- **whisper.cpp build**: happens on first `transcribeVoice()` call (~30s cold). install.sh pre-builds with `-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS`.
- **Transcription paths** (in `src/media-pipeline.ts`):
  - `transcribeViaServer()` — when `WHISPER_SERVER_URL` is set. POSTs audio (multipart, `file` field, `language=auto`, `response_format=text`) via `fs.openAsBlob()` + `fetch()`. Model resident in RAM in the server process.
  - `transcribeViaCli()` — fallback. Spawns `whisper-cli` per call via `nodejs-whisper`, parses `[hh:mm:ss --> ...]` timestamps out via `parseWhisperOutput()`.
- **Performance**: Mac (Metal, per-call CLI): ~1.3x realtime. Linux 4 vCPU droplet (small + OpenBLAS + whisper-server): ~2-4x realtime, ~16s for a 7.4-sec clip. Longer messages take proportionally longer — user waits synchronously.
