# Running agentmemory in Podman

Fully isolated local deployment. The container has no access to your host
filesystem. All state lives in named volumes. Only the REST API (3111), the
WebSocket stream (3112), and the viewer (3113) are published, bound to loopback.

## Architecture

```
Host (macOS)
├── Claude Code hooks  ─── fetch() ──► localhost:3111
├── OpenCode plugin    ─── fetch() ──► localhost:3111
├── MCP shim (stdio)   ─── podman exec ──► localhost:3111
└── Browser            ───────────────► localhost:3113 (viewer)
                                         └─ page derives REST :3111, stream :3112

Podman container
├── iii-engine + agentmemory worker
├── 0.0.0.0:3111  REST API            (host 3111)
├── 0.0.0.0:3112  WebSocket stream    (host 3112)
├── 0.0.0.0:3114  socat ──► 127.0.0.1:3113 viewer  (host 3113)
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
- `docker-compose` or `podman-compose` available on PATH

**macOS with `podman machine`:** No subuid/subgid configuration needed.
The container runs as `node` (UID 1000) inside the Podman Linux VM, which
already provides process isolation from the macOS host.

**Note:** On macOS, Podman runs inside an `applehv` VM. Volume data lives
inside this VM — there is no host-side path to directly `cat` volume files.
Use `podman exec <container> cat /data/.hmac` to read from volumes.

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

## One-time volume setup

The named volumes must exist before the first `compose up`. Docker-compose
prefixes volume names with the project name when it creates them, which
would make subsequent `podman run` commands miss the data. Creating them
explicitly prevents this:

```bash
podman volume create agentmemory-data
podman volume create agentmemory-models
```

You only need to do this once. The volumes persist across container
rebuilds and restarts as long as you don't explicitly remove them.

## Run

`compose.local.yml` is the single source of truth for the local setup.
It declares the volumes as `external` so compose binds the volumes you
created above rather than creating new prefixed ones.

```bash
ANTHROPIC_API_KEY=$(pass show agentmemorykey) \
  AGENTMEMORY_SECRET=$(pass show agentmemorysecret) \
  podman compose -f compose.local.yml up -d
```

`pass` is the single source of truth for the secret. Both env vars are
passed through to the container via `compose.local.yml`'s `environment:`
list. The entrypoint persists the injected `AGENTMEMORY_SECRET` to
`/data/.hmac` on every boot, so the daemon, MCP shim, capture plugin,
and ad-hoc tooling all share the same value — no drift across restarts.

The container is configured with:
- **Memory limit** (`mem_limit`, `memswap_limit`) — size to your corpus (see below)
- `--cap-drop=ALL`, `--security-opt=no-new-privileges`
- `restart: unless-stopped`

## Connect the MCP shim

The MCP shim runs inside the already-running container and reads the secret
from the volume at startup. Add to your OpenCode MCP config
(`~/.config/opencode/opencode.jsonc`):

```jsonc
"agentmemory": {
  "type": "local",
  "command": [
    "sh", "-c",
    "AGENTMEMORY_SECRET=$(pass show agentmemorysecret) podman exec -i -e AGENTMEMORY_URL=http://127.0.0.1:3111 -e AGENTMEMORY_FORCE_PROXY=1 -e AGENTMEMORY_SECRET agentmemory agentmemory mcp"
  ],
  "enabled": true
}
```

`pass` is the source of truth — the secret is read at MCP launch time
so it always matches the running daemon.

For Claude Code (`.claude/settings.json`):

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "sh",
      "args": [
        "-c",
        "AGENTMEMORY_SECRET=$(pass show agentmemorysecret) podman exec -i -e AGENTMEMORY_URL=http://127.0.0.1:3111 -e AGENTMEMORY_FORCE_PROXY=1 -e AGENTMEMORY_SECRET agentmemory agentmemory mcp"
      ]
    }
  }
}
```

`AGENTMEMORY_FORCE_PROXY=1` skips the livez probe so the shim connects
immediately without waiting for a timeout on startup.

## Viewer

Open `http://localhost:3113` in your browser.

The viewer binds to `127.0.0.1:3113` inside the container (loopback only, so
Podman's published-port forwarding can't reach it directly). The entrypoint
runs a socat proxy `0.0.0.0:3114 → 127.0.0.1:3113`, and compose publishes that
as **host 3113** (`127.0.0.1:3113:3114`).

Serving the viewer on host port 3113 is deliberate: the viewer's browser code
derives the REST port (`servedPort − 2 = 3111`) and the live-stream WebSocket
port (`servedPort − 1 = 3112`) from the port it was loaded on. Publishing it on
any other host port (e.g. 3114) breaks that math and leaves the dashboard stuck
on "CONNECTING…". The stream worker (`iii-stream`) binds `0.0.0.0:3112` and is
published directly, so `ws://localhost:3112` resolves and real-time updates work.

## Secret management

The secret is stored in `pass` under the key `agentmemorysecret` and is
injected into the container at launch. The entrypoint writes it to
`/data/.hmac` so the daemon can validate requests. All clients — the
MCP shim, the capture plugin, and ad-hoc tooling — read from `pass`
directly, making it the single source of truth with no drift across
restarts.

```bash
# Read the secret (gpg prompt if agent is locked)
pass show agentmemorysecret

# Verify the running daemon has the expected value
diff <(pass show agentmemorysecret) <(podman exec agentmemory cat /data/.hmac)

# Rotate: update pass, then recreate the container
pass generate -f agentmemorysecret
ANTHROPIC_API_KEY=$(pass show agentmemorykey) \
  AGENTMEMORY_SECRET=$(pass show agentmemorysecret) \
  podman compose -f compose.local.yml up -d --force-recreate
```

## Import past sessions

### From OpenCode sessions

OpenCode stores sessions in JSON files under
`~/.local/share/opencode/storage/session/`. Copy the storage directory
into the running container and run the import:

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
`better-sqlite3` is included in the container image.

### From Claude Code transcripts

Your Claude Code sessions live at `~/.claude/projects/`. Copy them into the
running container and run the import via `podman exec`:

```bash
podman cp ~/.claude/projects agentmemory:/tmp/claude-projects

podman exec \
  -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" \
  agentmemory \
  agentmemory import-jsonl /tmp/claude-projects --max-files 500
```

### From an existing agentmemory instance

```bash
# 1. Export from the old instance
OLD_SECRET=<old-secret>
curl http://localhost:3111/agentmemory/export \
  -H "Authorization: Bearer $OLD_SECRET" \
  > /tmp/agentmemory-backup.json

# 2. Import into the running container
NEW_SECRET=$(podman exec agentmemory cat /data/.hmac)
jq '{exportData: ., strategy: "skip"}' /tmp/agentmemory-backup.json \
  | curl -X POST http://localhost:3111/agentmemory/import \
      -H "Authorization: Bearer $NEW_SECRET" \
      -H "Content-Type: application/json" \
      -d @-
```

`strategy: "skip"` is safe to re-run — it only writes records whose IDs
don't already exist in the live store.

## Useful commands

```bash
# Follow logs
podman compose -f compose.local.yml logs -f

# Stop (volumes preserved)
podman compose -f compose.local.yml down

# Restart after a rebuild
npm run build
podman build -t agentmemory-local -f Containerfile .
podman compose -f compose.local.yml down
ANTHROPIC_API_KEY=$(pass show agentmemorykey) podman compose -f compose.local.yml up -d

# Health check
curl http://localhost:3111/agentmemory/livez

# Open an interactive shell (secret injected)
podman exec -it \
  -e AGENTMEMORY_SECRET="$(podman exec agentmemory cat /data/.hmac)" \
  agentmemory sh

# Remove everything including volumes (destructive)
podman compose -f compose.local.yml down
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

All the following can be passed via the `environment:` key in
`compose.local.yml` or via `-e` to `podman run`. The defaults shown
are what the Containerfile and entrypoint set.

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required for LLM compression and summarization |
| `AGENTMEMORY_SECRET` | auto-generated | Set explicitly to override first-boot generation; persisted to `/data/.hmac` |
| `EMBEDDING_PROVIDER` | `local` | Use local `@xenova/transformers`; set to `anthropic` to use the API instead |
| `RERANK_ENABLED` | `true` | Neural reranker for search quality |
| `CONSOLIDATION_ENABLED` | `true` | Auto-consolidate observations into memories at session end |
| `AGENTMEMORY_AUTO_COMPRESS` | `true` | LLM-compress observations as they arrive |
| `GRAPH_EXTRACTION_ENABLED` | `true` | Build a knowledge graph from observations |
| `AGENTMEMORY_DROP_STALE_INDEX` | unset | Set to `true` to discard a persisted vector index built with a different embedding provider |
| `AGENTMEMORY_INJECT_CONTEXT` | unset | Set to `true` to inject memory context into model turns via hooks |
| `AGENTMEMORY_III_VERSION` | `0.11.2` | iii-engine version (informational; binary is baked into the image) |
