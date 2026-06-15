# Running agentmemory in Podman

Fully isolated local deployment. The container has no access to your host
filesystem. All state lives in named volumes. Only the REST API (port 3111)
and the viewer (port 3114) are published, bound to loopback.

## Architecture

```
Host (macOS)
├── Claude Code hooks  ─── fetch() ──► localhost:3111
├── OpenCode plugin    ─── fetch() ──► localhost:3111
├── MCP shim (stdio)   ─── fetch() ──► localhost:3111
└── Browser           ────────────► localhost:3114 (viewer)

Podman container
├── iii-engine + agentmemory worker
├── 0.0.0.0:3111  REST API
├── 0.0.0.0:3114  socat proxy ──► 127.0.0.1:3113 (viewer)
├── /data/        named volume  (KV state, stream store, secret)
└── /models/      named volume  (ONNX model cache, ~50 MB after first use)
```

## Security properties

| Property | How |
|---|---|
| No host filesystem access | Named volumes only; no bind mounts in steady state |
| Not running as your UID | Container runs as `node` (UID 1000) inside the Podman VM, isolated from the macOS host |
| No capabilities | `--cap-drop=ALL`, no additions |
| No privilege escalation | `--security-opt=no-new-privileges` |
| Auth always on | Secret auto-generated on first boot, stored in `/data/.hmac` |
| Immutable deps | Container image freezes all dependencies at build time |
| Local embeddings | `@xenova/transformers` + `onnxruntime-node` run inside the container |
| Local reranker | `Xenova/ms-marco-MiniLM-L-6-v2` runs inside the container |
| Only LLM is remote | Outbound HTTPS to `api.anthropic.com` only |

## Prerequisites

- Podman (rootless mode configured — `podman info` should show `rootless: true`)
**macOS with `podman machine`:** No subuid/subgid configuration needed.
The container runs as `node` (UID 1000) inside the Podman Linux VM, which
already provides process isolation from the macOS host.

**Linux (native Podman, no VM):** To avoid the container running as your
host UID, set up subuid/subgid entries and add `--userns=auto:size=4096`
to the `podman run` command:
```bash
grep $(whoami) /etc/subuid /etc/subgid   # verify entries exist
# if missing:
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)
```

## Build

Build the TypeScript first, then the container image:

```bash
npm run build
podman build -t agentmemory-local -f Containerfile .
```

The `npm run build` step must run on the host before each `podman build` —
the Containerfile copies the local `dist/` rather than pulling from npm.

## Run

```bash
podman run -d \
  --name agentmemory \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=2560m \
  -v agentmemory-data:/data:rw \
  -v agentmemory-models:/models:rw \
  -p 127.0.0.1:3111:3111 \
  -p 127.0.0.1:3114:3114 \
  -e ANTHROPIC_API_KEY="$(pass show agentmemorykey)" \
  agentmemory-local
```

On first boot, the container generates a random `AGENTMEMORY_SECRET` and
prints it once to the logs. Retrieve it:

```bash
# From the first-boot log output
podman logs agentmemory 2>&1 | grep AGENTMEMORY_SECRET

# Or at any time from the persisted file
podman exec agentmemory cat /data/.hmac
```

The secret is stored at `/data/.hmac` in the named volume and reloaded on
every subsequent start.

## Connect Claude Code and OpenCode

Set these in your shell profile (`~/.zshrc` or `~/.zprofile`):

```bash
export AGENTMEMORY_URL=http://localhost:3111
export AGENTMEMORY_SECRET=<secret from first-boot logs>
```

Both Claude Code hooks and the OpenCode plugin read these variables directly —
no other configuration is needed.

## Connect the MCP shim

Add to your Claude Code and OpenCode MCP config (`.claude/settings.json` /
`.opencode/config.json`):

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "npx",
      "args": ["-y", "@agentmemory/mcp"],
      "env": {
        "AGENTMEMORY_URL": "http://localhost:3111",
        "AGENTMEMORY_SECRET": "<secret>",
        "AGENTMEMORY_FORCE_PROXY": "1"
      }
    }
  }
}
```

`AGENTMEMORY_FORCE_PROXY=1` skips the livez probe so the shim connects
immediately without waiting for a timeout on startup.

## Viewer

Open `http://localhost:3114` in your browser.

The viewer binds to `127.0.0.1:3113` inside the container (hardcoded). The
entrypoint runs a socat proxy that maps `0.0.0.0:3114` to `127.0.0.1:3113`,
which is then published to the host via `-p 127.0.0.1:3114:3114`. The viewer's
DNS-rebinding protection is configured to accept `Host: localhost:3114` via
`VIEWER_ALLOWED_HOSTS`.

## Import past sessions

### From OpenCode sessions

OpenCode stores sessions in a SQLite database at
`~/.local/share/opencode/opencode.db`. Copy it into the running container
and run the import:

```bash
# Copy the database into the container's tmp
podman cp ~/.local/share/opencode/opencode.db agentmemory:/tmp/opencode.db

# Import all sessions
podman exec \
  -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" \
  agentmemory \
  agentmemory import-opencode /tmp/opencode.db

# Or import specific sessions only
podman exec \
  -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" \
  agentmemory \
  agentmemory import-opencode /tmp/opencode.db \
    --session-ids ses_abc123,ses_def456
```

The database is opened read-only. The `/tmp` copy is ephemeral.
`better-sqlite3` is included in the container image (baked into the
Containerfile's `npm install` step).

### From Claude Code transcripts

Your Claude Code sessions live at `~/.claude/projects/`. Copy them into the
running container and run the import via `podman exec`:

```bash
# Copy transcripts into the container's tmp
podman cp ~/.claude/projects agentmemory:/tmp/claude-projects

# Run the import against the already-running server.
# AGENTMEMORY_SECRET must be injected explicitly — podman exec sessions do not
# inherit variables exported by the entrypoint shell.
podman exec \
  -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" \
  agentmemory \
  agentmemory import-jsonl /tmp/claude-projects --max-files 500
```

`import-jsonl` is a client command — it needs the agentmemory server running
inside the container to POST to. The data lands in `/data` (the named volume)
immediately. The `/tmp` copy is ephemeral and disappears on the next
`podman restart`.

### From an existing agentmemory instance

If you already have agentmemory running on the host (e.g., before moving to
Podman):

```bash
# 1. Export everything from the host instance
curl http://localhost:3111/agentmemory/export \
  -H "Authorization: Bearer <old-secret>" \
  > /tmp/agentmemory-backup.json

# 2. Start the container on a temporary port to avoid conflict with the
#    still-running host instance
podman run -d --name agentmemory-new \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --memory=2560m \
  -v agentmemory-data:/data:rw \
  -v agentmemory-models:/models:rw \
  -p 127.0.0.1:3211:3111 \
  -e ANTHROPIC_API_KEY="$(pass show agentmemorykey)" \
  agentmemory-local

# 3. Retrieve the new secret from the volume (avoids parsing log output)
NEW_SECRET=$(podman exec agentmemory-new cat /data/.hmac)

# 4. Import — pipe via jq to avoid shell ARG_MAX limits on large exports
jq -n --slurpfile data /tmp/agentmemory-backup.json \
  '{exportData: $data[0], strategy: "merge"}' | \
curl -X POST http://localhost:3211/agentmemory/import \
  -H "Authorization: Bearer $NEW_SECRET" \
  -H "Content-Type: application/json" \
  -d @-
```

## Useful commands

```bash
# Follow logs
podman logs -f agentmemory

# Stop and remove container (volumes are preserved)
podman stop agentmemory && podman rm agentmemory

# Restart after a rebuild
npm run build && podman build -t agentmemory-local -f Containerfile . \
  && podman stop agentmemory && podman rm agentmemory \
  && podman run -d ... (same run command as above)

# Health check
curl http://localhost:3111/agentmemory/livez

# Rotate the secret (generates a new one on next start)
podman exec agentmemory rm /data/.hmac
podman restart agentmemory
podman logs agentmemory 2>&1 | grep AGENTMEMORY_SECRET

# Inspect what's running inside (AGENTMEMORY_SECRET not set in exec sessions;
# inject it if you need to run CLI commands interactively)
podman exec -it -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" agentmemory sh

# Remove everything including volumes (destructive)
podman stop agentmemory && podman rm agentmemory
podman volume rm agentmemory-data agentmemory-models
```

## Model downloads

On first use of search or memory recall, `@xenova/transformers` downloads two
models from HuggingFace (~45 MB total):

| Model | Task | Size |
|---|---|---|
| `Xenova/all-MiniLM-L6-v2` | Text embeddings (384-dim) | ~23 MB |
| `Xenova/ms-marco-MiniLM-L-6-v2` | Reranking | ~22 MB |

Models are cached in the `agentmemory-models` named volume via a symlink at
`node_modules/@xenova/transformers/.cache` → `/models`. They are downloaded
once and reused across container rebuilds as long as the volume is preserved.

The first search after a fresh volume will be slow (~5–15 s on first call).
Subsequent calls are fast.

## Environment variables

All the following can be passed via `-e` to `podman run`. The defaults shown
are what the Containerfile and entrypoint set.

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required for LLM compression and summarization |
| `AGENTMEMORY_SECRET` | auto-generated | Set explicitly to override first-boot generation |
| `EMBEDDING_PROVIDER` | `local` | Use local `@xenova/transformers`; set to `anthropic` to use the API instead |
| `RERANK_ENABLED` | `true` | Neural reranker for search quality |
| `CONSOLIDATION_ENABLED` | `true` | Auto-consolidate observations into memories at session end |
| `AGENTMEMORY_AUTO_COMPRESS` | `true` | LLM-compress observations as they arrive |
| `GRAPH_EXTRACTION_ENABLED` | `true` | Build a knowledge graph from observations |
| `AGENTMEMORY_INJECT_CONTEXT` | unset | Set to `true` to inject memory context into model turns via hooks |
| `AGENTMEMORY_III_VERSION` | `0.11.2` | iii-engine version (informational; binary is baked into the image) |
