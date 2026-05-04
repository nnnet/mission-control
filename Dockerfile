FROM node:22.22.0-slim AS base
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app

FROM base AS deps
# Copy only dependency manifests first for better layer caching
COPY package.json ./
COPY pnpm-lock.yaml* ./
# better-sqlite3 requires native compilation tools
RUN apt-get update && apt-get upgrade && apt-get install -y python3 make g++ --no-install-recommends && rm -rf /var/lib/apt/lists/*
RUN if [ -f pnpm-lock.yaml ]; then \
      pnpm install --frozen-lockfile; \
    else \
      echo "WARN: pnpm-lock.yaml not found in build context; running non-frozen install" && \
      pnpm install --no-frozen-lockfile; \
    fi

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

FROM node:22.22.0-slim AS runtime

ARG MC_VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/builderz-labs/mission-control"
LABEL org.opencontainers.image.description="Mission Control - operations dashboard"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${MC_VERSION}"

WORKDIR /app
ENV NODE_ENV=production
# curl, CA certs, python3, git needed for agent runtime installers (OpenClaw, Hermes)
# procps provides `ps` and `uptime` used by system-monitor APIs
RUN apt-get update && apt-get upgrade && apt-get install -y curl ca-certificates python3 git make g++ procps tmux jq --no-install-recommends && rm -rf /var/lib/apt/lists/*

# Bake Claude Code + Codex CLIs into the image as a fallback so the
# Settings → Agent Runtimes panel reports "Installed" even before the host
# bind-mounts (compose adds ${HOME}/.local/bin at runtime, which takes
# precedence in PATH and provides authenticated host binaries).
RUN npm install -g @anthropic-ai/claude-code @openai/codex 2>&1 | tail -5

# node:22-slim already ships a `node` user at uid 1000; reuse it as our
# `nextjs` alias so bind-mounted host files (typical Linux uid 1000) read directly.
RUN if ! id -u nextjs >/dev/null 2>&1; then \
      usermod --login nextjs --move-home --home /home/nextjs node && \
      groupmod --new-name nodejs node ; \
    fi
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
COPY --from=build /app/src/lib/schema.sql ./src/lib/schema.sql
# node-pty is a native addon; Next standalone tracing can omit built artifacts.
# Copy the fully installed package (including native binary artifacts) from deps stage.
COPY --from=deps /app/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty ./node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty
# Create data directory with correct ownership for SQLite
RUN mkdir -p .data && chown nextjs:nodejs .data
RUN echo 'const http=require("http");const r=http.get("http://localhost:"+(process.env.PORT||3000)+"/api/status?action=health",s=>{process.exit(s.statusCode===200?0:1)});r.on("error",()=>process.exit(1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)})' > /app/healthcheck.js
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod 755 /app/docker-entrypoint.sh && \
    chmod -R a+rX /app/public/ /app/src/ && \
    chown -R nextjs:nodejs /app /home/nextjs
USER nextjs
ENV PORT=3000
EXPOSE 3000
ENV HOSTNAME=0.0.0.0
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "/app/healthcheck.js"]
ENTRYPOINT ["/app/docker-entrypoint.sh"]
