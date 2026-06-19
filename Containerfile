ARG III_VERSION=0.11.2

# Stage 1: extract the iii engine binary
FROM iiidev/iii:${III_VERSION} AS iii-image

# Stage 2: runtime image built from local source
FROM node:22-slim

ARG III_VERSION=0.11.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssl \
      ca-certificates \
      tini \
      curl \
      socat \
 && rm -rf /var/lib/apt/lists/*

COPY --from=iii-image /app/iii /usr/local/bin/iii

WORKDIR /opt/agentmemory

# Install dependencies including optional ones (onnxruntime-node, @xenova/transformers).
# This must run inside the Linux container — the native .node binaries are
# platform-specific and cannot be copied from a macOS host.
COPY package.json ./
RUN npm install --include=optional --no-fund --no-audit --legacy-peer-deps \
 && npm install --no-fund --no-audit --legacy-peer-deps better-sqlite3

# Symlink the @xenova/transformers model cache to /models so the named volume
# mounted at /models persists downloaded models across container restarts.
# The library has no env var override; the symlink redirects its default path.
RUN mkdir -p /models \
 && chown node:node /models \
 && ln -sf /models /opt/agentmemory/node_modules/@xenova/transformers/.cache

# Copy the pre-built dist/ produced by `npm run build` on the host.
# Run `npm run build` before `podman build`.
COPY dist/ ./dist/

# Raise the iii-sdk client invocation timeout (src/index.ts registerWorker
# invocationTimeoutMs, minified to `18e4` = 180000ms) to 18e5 = 1800000ms (30 min).
# The 180s default makes the post-rebuild BM25/vector index save (~110 queued
# `state::set` writes) time out, so the index never persists and every boot
# re-embeds the whole corpus on CPU. Deliberately generous for now to isolate the
# timeout as the cap; dial back later. Patched here (glob over the content-hashed
# bundle) so it survives `npm run build` without editing tracked source.
RUN sed -i 's/invocationTimeoutMs: *18e4/invocationTimeoutMs: 18e5/' dist/*.mjs \
 && grep -q 'invocationTimeoutMs: 18e5' dist/src-*.mjs \
 && ! grep -rq 'invocationTimeoutMs: *18e4' dist/*.mjs

# Bake the container-tuned iii config directly into dist/ so the CLI finds it
# at first-path priority (same dir as dist/cli.mjs) without needing a runtime
# write. Binds on 0.0.0.0 inside the container; absolute /data/ paths for state.
RUN cat > /opt/agentmemory/dist/iii-config.yaml <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins:
          - "http://localhost:3111"
          - "http://localhost:3112"
          - "http://localhost:3113"
          - "http://127.0.0.1:3111"
          - "http://127.0.0.1:3112"
          - "http://127.0.0.1:3113"
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 1.0
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF

# Make the CLI binary executable and expose it on PATH
RUN chmod +x /opt/agentmemory/dist/cli.mjs \
 && ln -s /opt/agentmemory/dist/cli.mjs /usr/local/bin/agentmemory

# Drop to non-root for all runtime operations.
# With --userns=auto (rootless Podman) this UID maps to an unprivileged
# sub-UID on the host — not your own UID.
USER node

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    TINI_SUBREAPER=1 \
    NODE_OPTIONS="--max-old-space-size=2048" \
    EMBEDDING_PROVIDER=local \
    RERANK_ENABLED=true \
    CONSOLIDATION_ENABLED=true \
    AGENTMEMORY_AUTO_COMPRESS=true \
    GRAPH_EXTRACTION_ENABLED=true

# Published container ports: 3111 REST, 3112 stream (WebSocket), 3114 socat
# bridge for the loopback-only viewer. Host mapping in compose.local.yml maps
# host 3113 -> container 3114 so the viewer's port math (ws=port-1, rest=port-2)
# resolves correctly in the browser.
EXPOSE 3111 3112 3114

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3111/agentmemory/livez || exit 1

COPY --chmod=0755 podman-entrypoint.sh /usr/local/bin/agentmemory-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentmemory-entrypoint.sh"]
