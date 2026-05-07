#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=7902

# Kill any existing instance on this port
lsof -ti tcp:$PORT | xargs kill -9 2>/dev/null || true
sleep 0.5

echo "Starting saga-dashboard server on http://localhost:$PORT"
node "$DIR/server.js" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to be ready
for i in {1..10}; do
  curl -s "http://localhost:$PORT/api/dashboard" > /dev/null 2>&1 && break
  sleep 0.5
done

echo "Starting cloudflared tunnel..."
cloudflared tunnel --url "http://localhost:$PORT" &
TUNNEL_PID=$!
echo "Tunnel PID: $TUNNEL_PID"

# Write PIDs for cleanup
echo "$SERVER_PID" > "$DIR/.server.pid"
echo "$TUNNEL_PID" > "$DIR/.tunnel.pid"

echo ""
echo "Dashboard: http://localhost:$PORT"
echo "Cloudflared URL will appear above (look for trycloudflare.com URL)"
echo ""
echo "To stop: kill $SERVER_PID $TUNNEL_PID"
echo "Or run: bash $(dirname $0)/stop.sh"

wait $TUNNEL_PID
