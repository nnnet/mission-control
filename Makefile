# Mission Control — local stack control plane.
# Use `make help` for the full target list.

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
COMPOSE     := docker compose
COMPOSE_DEV := docker compose -f docker-compose-dev.yml
COMPOSE_OC  := docker compose -f docker-compose-openclaw.yml
OPENCLAW_SRC := $(PROJECT_DIR)/openclaw-src
OPENCLAW_REPO := https://github.com/openclaw/openclaw.git
OPENCLAW_REF  := main
CONTAINER   := mission-control
CONTAINER_DEV := mission-control-dev
URL         := http://127.0.0.1:7012

.DEFAULT_GOAL := help

# ── Help ───────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## List targets
	@awk 'BEGIN{FS=":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	      /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
	      $(MAKEFILE_LIST)

# ── Compose lifecycle ──────────────────────────────────────────────────────
.PHONY: up
up:  ## Bring stack up and wait for /login to respond
	@cd $(PROJECT_DIR)
	$(COMPOSE) up -d $(ARGS)
	@$(MAKE) --no-print-directory wait-ready
	@echo
	@echo "Mission Control is up at $(URL)"
	@echo "  /setup    — create admin (first run)"
	@echo "  /login    — sign in"
	@echo "  /tasks    — Kanban board"
	@echo "  /agents   — agent registry"

.PHONY: down
down:  ## Stop and remove container + network (volumes preserved)
	@cd $(PROJECT_DIR)
	$(COMPOSE) down

.PHONY: restart
restart:  ## Restart the running container
	@cd $(PROJECT_DIR)
	$(COMPOSE) restart
	@$(MAKE) --no-print-directory wait-ready

.PHONY: recreate
recreate:  ## Force recreate the container (apply compose changes)
	@$(MAKE) --no-print-directory up ARGS="--force-recreate"

.PHONY: build
build:  ## Build/refresh the mission-control image
	@cd $(PROJECT_DIR)
	$(COMPOSE) build $(ARGS)

.PHONY: rebuild
rebuild:  ## Rebuild image (no cache) and recreate
	@cd $(PROJECT_DIR)
	$(COMPOSE) build --no-cache
	@$(MAKE) --no-print-directory recreate

.PHONY: ps
ps:  ## Show container status
	@cd $(PROJECT_DIR)
	$(COMPOSE) ps

.PHONY: logs
logs:  ## Tail server logs (Ctrl+C to stop)
	@cd $(PROJECT_DIR)
	$(COMPOSE) logs -f --tail=200

.PHONY: shell
shell:  ## Open an interactive shell inside the container
	docker exec -it $(CONTAINER) bash || docker exec -it $(CONTAINER) sh

.PHONY: status
status:  ## One-liner health: HTTP code + which agent CLIs are reachable
	@printf "URL:     "; curl -sS -o /dev/null -L -w "%{http_code} → %{url_effective}\n" $(URL) || true
	@printf "claude:  "; docker exec $(CONTAINER) sh -c 'which claude && claude --version' 2>&1 | tail -1
	@printf "codex:   "; docker exec $(CONTAINER) sh -c 'which codex && codex --version 2>&1 | tail -1' 2>&1 | tail -1
	@printf "gemini:  "; docker exec $(CONTAINER) sh -c 'which gemini' 2>&1 | tail -1

# ── Lifecycle utilities ────────────────────────────────────────────────────
.PHONY: wait-ready
wait-ready:  ## Block until /login responds 200
	@for i in $$(seq 1 30); do \
	  status=$$(curl -sS -o /dev/null -L -w '%{http_code}' $(URL) 2>/dev/null || true); \
	  if [ "$$status" = "200" ]; then echo "  ✓ $(URL) → 200"; exit 0; fi; \
	  sleep 1; \
	done; \
	echo "Mission Control did not become ready in 30s" >&2; exit 1

.PHONY: reset-db
reset-db:  ## Wipe SQLite db (forces /setup again — admin password recovery)
	@if ! docker ps --format '{{.Name}}' | grep -qx '$(CONTAINER)'; then \
	  echo "ERROR: $(CONTAINER) is not running" >&2; exit 1; \
	fi
	@echo "===> 1. Stop $(CONTAINER)"
	@$(COMPOSE) stop | sed 's/^/   /'
	@echo
	@echo "===> 2. Wipe SQLite files in mc-data volume"
	@docker run --rm -v mission-control_mc-data:/data alpine \
	  sh -c 'find /data -maxdepth 2 \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite-shm" -o -name "*.sqlite-wal" \) | xargs -r rm -v' \
	  | sed 's/^/   /'
	@echo
	@echo "===> 3. Restart"
	@$(MAKE) --no-print-directory up
	@echo
	@echo "Open $(URL)/setup to create a fresh admin."

# ── Bookkeeping ────────────────────────────────────────────────────────────
# ── Dev mode (hot-reload, source bind-mounted) ─────────────────────────────
.PHONY: dev
dev:  ## Bring up dev stack (pnpm dev, hot-reload from bind-mounted src/)
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) up -d $(ARGS)
	@$(MAKE) --no-print-directory wait-ready
	@echo
	@echo "Mission Control (dev) is up at $(URL)"
	@echo "  Code edits in src/ auto-reload via turbopack."
	@echo "  Rebuild image only when package.json or Dockerfile.dev changes:"
	@echo "    make dev-build"

.PHONY: dev-down
dev-down:  ## Stop dev stack (volumes preserved)
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) down

.PHONY: dev-build
dev-build:  ## Rebuild dev image (run when package.json / Dockerfile.dev change)
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) build $(ARGS)

.PHONY: dev-rebuild
dev-rebuild:  ## Rebuild dev image (no cache) and recreate
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) build --no-cache
	$(COMPOSE_DEV) up -d --force-recreate
	@$(MAKE) --no-print-directory wait-ready

.PHONY: dev-logs
dev-logs:  ## Tail dev container logs (Ctrl+C to stop)
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) logs -f --tail=200

.PHONY: dev-shell
dev-shell:  ## Open shell inside dev container
	docker exec -it $(CONTAINER_DEV) bash || docker exec -it $(CONTAINER_DEV) sh

.PHONY: dev-ps
dev-ps:  ## Show dev container status
	@cd $(PROJECT_DIR)
	$(COMPOSE_DEV) ps

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw integration — additive. Brings up the gateway daemon next to MC.
# MC auto-detects it via host.docker.internal:18789 and switches dispatch to
# the gateway path. When this stack is down, MC silently falls back to the
# direct-API/CLI path, so the rest of the stack is unaffected.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: openclaw-clone
openclaw-clone:  ## Clone github.com/openclaw/openclaw into ./openclaw-src (idempotent)
	@cd $(PROJECT_DIR)
	if [ -d "$(OPENCLAW_SRC)/.git" ]; then \
	  echo "openclaw-src already cloned; pulling latest $(OPENCLAW_REF)"; \
	  git -C "$(OPENCLAW_SRC)" fetch --depth 1 origin "$(OPENCLAW_REF)" && \
	  git -C "$(OPENCLAW_SRC)" reset --hard FETCH_HEAD; \
	else \
	  git clone --depth 1 --branch "$(OPENCLAW_REF)" "$(OPENCLAW_REPO)" "$(OPENCLAW_SRC)"; \
	fi
	@echo "openclaw source ready at $(OPENCLAW_SRC)"

.PHONY: openclaw-build
openclaw-build: openclaw-clone  ## Build the openclaw image (5-10 min on first run)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) build openclaw-gateway
	@echo "openclaw image built; run 'make openclaw-up' to start it"

.PHONY: openclaw-up
openclaw-up:  ## Start openclaw gateway daemon (port 18789); auto-builds if image missing
	@cd $(PROJECT_DIR)
	if ! docker image inspect mc-openclaw:local >/dev/null 2>&1; then \
	  echo "image mc-openclaw:local not present; building first..."; \
	  $(MAKE) openclaw-build; \
	fi
	$(COMPOSE_OC) up -d openclaw-gateway
	@echo "openclaw-gateway is starting on http://127.0.0.1:18789"
	@echo "Wait 30-60s for healthy status, then run: make openclaw-status"

.PHONY: openclaw-down
openclaw-down:  ## Stop openclaw stack (MC keeps running on direct-API fallback)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) down
	@echo "openclaw stopped; MC dispatch falls back to direct API/CLI"

.PHONY: openclaw-restart
openclaw-restart:  ## Restart openclaw gateway
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) restart openclaw-gateway

.PHONY: openclaw-logs
openclaw-logs:  ## Tail openclaw gateway logs
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) logs -f openclaw-gateway

.PHONY: openclaw-ps
openclaw-ps:  ## Show openclaw container status
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) ps

.PHONY: openclaw-status
openclaw-status:  ## Quick health check (HTTP /healthz + token presence)
	@cd $(PROJECT_DIR)
	@printf "Gateway HTTP: "
	@curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18789/healthz 2>&1 || echo "DOWN"
	@if [ -f .openclaw-data/openclaw.json ]; then \
	  echo "Config:       .openclaw-data/openclaw.json present"; \
	else \
	  echo "Config:       not yet generated (gateway may still be initializing)"; \
	fi
	@if grep -q "^OPENCLAW_GATEWAY_TOKEN=." .env 2>/dev/null; then \
	  echo "MC token:     set in .env"; \
	else \
	  echo "MC token:     NOT set in .env — copy from .openclaw-data/openclaw.json"; \
	fi

.PHONY: openclaw-onboard
openclaw-onboard:  ## Interactive provider/skills wizard (one-time setup)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) run --rm openclaw-cli onboard

.PHONY: openclaw-shell
openclaw-shell:  ## Drop into the openclaw CLI container (interactive)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) run --rm --entrypoint /bin/bash openclaw-cli

.PHONY: openclaw-doctor
openclaw-doctor:  ## Run openclaw doctor (config + connectivity diagnostics)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) run --rm openclaw-cli doctor

.PHONY: openclaw-token
openclaw-token:  ## Print the gateway token from .openclaw-data/openclaw.json (for MC .env)
	@cd $(PROJECT_DIR)
	@if [ ! -f .openclaw-data/openclaw.json ]; then \
	  echo "ERROR: .openclaw-data/openclaw.json not found — start openclaw first" >&2; exit 1; \
	fi
	@if command -v jq >/dev/null 2>&1; then \
	  jq -r '.gateway.auth.token // empty' .openclaw-data/openclaw.json; \
	else \
	  grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]*"' .openclaw-data/openclaw.json | head -1 | sed 's/.*"\([^"]*\)"$$/\1/'; \
	fi

.PHONY: nuke
nuke:  ## DANGER: down, drop volumes, drop image. Confirm via CONFIRM=yes
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "Refusing to nuke without CONFIRM=yes"; exit 1; \
	fi
	@cd $(PROJECT_DIR)
	$(COMPOSE) down -v
	docker image rm mission-control-mission-control 2>/dev/null || true
