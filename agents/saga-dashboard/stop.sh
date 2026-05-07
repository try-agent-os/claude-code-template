#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"

for f in .server.pid .tunnel.pid; do
  if [ -f "$DIR/$f" ]; then
    PID=$(cat "$DIR/$f")
    kill "$PID" 2>/dev/null && echo "Killed $PID" || true
    rm "$DIR/$f"
  fi
done

lsof -ti tcp:7902 | xargs kill -9 2>/dev/null || true
echo "saga-dashboard stopped"
