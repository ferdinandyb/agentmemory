#!/bin/sh
# agentmemory Podman entrypoint.
#
# Runs as the `node` user (UID 1000 inside the container, mapped to an
# unprivileged sub-UID on the host via --userns=auto). No root, no gosu.
#
# Responsibilities:
#   1. Generate AGENTMEMORY_SECRET on first boot, persist to /data/.hmac.
#      If AGENTMEMORY_SECRET is already set in the environment, persist that
#      value instead (allows explicit secret injection via -e).
#   2. Set viewer env vars so the DNS-rebinding check accepts the socat port.
#   3. Start a socat proxy (0.0.0.0:3114 -> 127.0.0.1:3113) so the loopback-only
#      viewer is reachable; compose publishes it as host 3113. REST (3111) and
#      stream (3112) bind 0.0.0.0 in-container and are published directly.
#   4. exec agentmemory.

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${DATA_DIR}/.hmac"

mkdir -p "$DATA_DIR"

if [ -n "${AGENTMEMORY_SECRET:-}" ]; then
  # Explicit secret provided via -e — persist it so subsequent restarts are
  # consistent, then fall through to the export below.
  ( umask 077; printf '%s\n' "$AGENTMEMORY_SECRET" > "$HMAC_FILE" )
  chmod 600 "$HMAC_FILE"
elif [ ! -s "$HMAC_FILE" ]; then
  # First boot — generate a random secret and print it once.
  SECRET="$(openssl rand -hex 32)"
  ( umask 077; printf '%s\n' "$SECRET" > "$HMAC_FILE" )
  chmod 600 "$HMAC_FILE"
  echo "================================================================"
  echo "agentmemory: generated secret on first boot"
  echo "AGENTMEMORY_SECRET=$SECRET"
  echo "Copy this value — it will not be printed again."
  echo "Retrieve later with: podman exec agentmemory cat /data/.hmac"
  echo "To rotate: delete $HMAC_FILE on the persistent volume and restart."
  echo "================================================================"
fi

# Always export the persisted value so the process sees a consistent secret
# regardless of which branch above ran.
AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

# The viewer is reached from the host on port 3113 (compose maps host 3113 ->
# container 3114, the socat bridge below). The browser loads the page from
# :3113 and derives the REST port (3111) and stream port (3112) from it, so the
# Host header and Origin it presents are for :3113.
export VIEWER_ALLOWED_HOSTS="localhost:3113,127.0.0.1:3113"
export VIEWER_ALLOWED_ORIGINS="http://localhost:3111,http://localhost:3112,http://localhost:3113,http://127.0.0.1:3111,http://127.0.0.1:3112,http://127.0.0.1:3113"

# The viewer binds 127.0.0.1:3113 (loopback only), so Podman's published-port
# forwarding can't reach it. socat bridges 0.0.0.0:3114 -> 127.0.0.1:3113;
# compose publishes that as host 3113. The REST (3111) and stream (3112)
# workers already bind 0.0.0.0 in-container, so they need no proxy.
# socat starts before the viewer is ready; `fork` handles each connection
# independently — early requests get "connection refused" until the viewer is up.
socat TCP-LISTEN:3114,fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:3113 &

exec agentmemory "$@"
