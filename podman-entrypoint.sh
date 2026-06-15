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
#   3. Start a socat proxy (0.0.0.0:3114 -> 127.0.0.1:3113) so the viewer
#      is reachable from outside the container despite its hardcoded loopback bind.
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

# Allow the viewer's Host-header check to accept requests arriving via the
# socat proxy on port 3114 (the externally published port).
export VIEWER_ALLOWED_HOSTS="localhost:3114,127.0.0.1:3114"
export VIEWER_ALLOWED_ORIGINS="http://localhost:3111,http://localhost:3113,http://localhost:3114,http://127.0.0.1:3111,http://127.0.0.1:3113,http://127.0.0.1:3114"

# Proxy the viewer's loopback-only port to all interfaces so it is reachable
# via the published -p 127.0.0.1:3114:3114 mapping.
# agentmemory starts the viewer on 127.0.0.1:3113 with no env var override,
# so socat is the least-invasive way to expose it without source changes.
# socat starts before the viewer is ready; the `fork` option means each
# connection attempt is handled independently — early browser requests get
# "connection refused" and the user just retries once the viewer is up.
socat TCP-LISTEN:3114,fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:3113 &

exec agentmemory "$@"
