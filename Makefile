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
openclaw-build: openclaw-clone  ## Build openclaw dist into ./openclaw-src/ (5-10 min on first run)
	@cd $(PROJECT_DIR)
	$(COMPOSE_OC) --profile build run --rm openclaw-builder
	@echo "openclaw dist + node_modules populated under ./openclaw-src/"
	@echo "Run 'make openclaw-up' to start the gateway."

.PHONY: openclaw-update
openclaw-update: openclaw-clone openclaw-build openclaw-restart  ## git pull openclaw-src + rebuild dist + restart gateway (no docker rebuild)
	@echo "==> openclaw updated to $$(cd $(OPENCLAW_SRC) && git rev-parse --short HEAD); gateway restarted."

.PHONY: openclaw-up
openclaw-up:  ## Start openclaw gateway + control UI (ports 18789, 18791)
	@cd $(PROJECT_DIR)
	if [ ! -f "$(OPENCLAW_SRC)/dist/index.js" ] || [ ! -f "$(OPENCLAW_SRC)/dist/control-ui/index.html" ]; then \
	  echo "openclaw dist/control-ui assets missing; building first..."; \
	  $(MAKE) openclaw-build; \
	fi
	mkdir -p .openclaw-data/credentials .mc-openclaw/credentials
	$(COMPOSE_OC) up -d openclaw-gateway openclaw-control-ui
	@echo "openclaw-gateway is starting on http://127.0.0.1:18789"
	@echo "openclaw-control-ui is starting on http://127.0.0.1:$${OPENCLAW_CONTROL_UI_PORT:-18791}"
	@echo "Wait 30-60s for healthy status, then run: make openclaw-status"

.PHONY: openclaw-down
openclaw-down:  ## Stop openclaw stack (gateway + control UI)
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
openclaw-status:  ## Quick health check (gateway + control UI + token/linkage)
	@cd $(PROJECT_DIR)
	@printf "Gateway HTTP: "
	@curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18789/healthz 2>&1 || echo "DOWN"
	@printf "Control UI:   "
	@curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:$${OPENCLAW_CONTROL_UI_PORT:-18791}/ 2>&1 || echo "DOWN"
	@if [ -f .openclaw-data/openclaw.json ]; then \
	  echo "Config:       .openclaw-data/openclaw.json present"; \
	else \
	  echo "Config:       not yet generated (gateway may still be initializing)"; \
	fi
	@if [ -d .mc-openclaw/credentials ]; then \
	  echo "OAuth dir:    .mc-openclaw/credentials present"; \
	else \
	  echo "OAuth dir:    .mc-openclaw/credentials missing"; \
	fi
	@if grep -q "^OPENCLAW_GATEWAY_TOKEN=." .env 2>/dev/null; then \
	  echo "MC token:     set in .env"; \
	else \
	  echo "MC token:     NOT set in .env — copy from .openclaw-data/openclaw.json"; \
	fi
	@if docker ps --format '{{.Names}}' | grep -q '^$(CONTAINER)$$'; then \
	  printf "MC->Gateway: "; \
	  docker exec $(CONTAINER) openclaw gateway call health --json --timeout 8000 >/dev/null 2>&1 && echo "OK" || echo "FAIL"; \
	else \
	  echo "MC->Gateway: mission-control container not running"; \
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

.PHONY: openclaw-pair-mc
openclaw-pair-mc:  ## Auto-pair MC's openclaw CLI with the gateway (one-shot, idempotent)
	@cd $(PROJECT_DIR)
	# 1. Ensure both stacks are up
	@if ! docker ps --format '{{.Names}}' | grep -q '^mc-openclaw-gateway$$'; then \
	  echo "ERROR: mc-openclaw-gateway not running — run 'make openclaw-up' first" >&2; exit 1; \
	fi
	@if ! docker ps --format '{{.Names}}' | grep -q '^mission-control-dev$$'; then \
	  echo "ERROR: mission-control-dev not running — run 'make dev' first" >&2; exit 1; \
	fi
	# 2. Trigger MC's openclaw CLI once so it generates ~/.openclaw/identity/device.json
	#    and submits a pending pairing request to the gateway. The call itself is
	#    expected to fail with "pairing required" — that is exactly what creates
	#    the pending entry. Subsequent retries after the patch will succeed.
	@echo "==> triggering pairing request from MC..."
	@docker exec mission-control-dev openclaw gateway call health --json --timeout 5000 >/dev/null 2>&1 || true
	# Give the gateway a moment to flush the pending entry to disk.
	@sleep 1
	# 3. Patch pending → paired transactionally on host filesystem.
	@if [ -x ./.venv/bin/python3 ]; then \
	  ./.venv/bin/python3 scripts/openclaw-auto-pair.py; \
	else \
	  python3 scripts/openclaw-auto-pair.py; \
	fi
	# 4. Map MC's agent display names to openclaw agent ids declared in
	#    openclaw.json. Without this, runOpenClaw passes "Architect (Claude
	#    Opus)" as agentId which the gateway rejects as unknown.
	#    Also populate session_key so the Orchestration → Command tab in MC
	#    UI doesn't disable the agent dropdown (it requires non-null
	#    session_key on agents).
	@echo "==> binding MC agents to openclaw agent ids..."
	@docker exec mission-control-dev sh -c "cd /app && node -e \"\
	const Database=require('better-sqlite3'); \
	const db=new Database('.data/mission-control.db'); \
	const map={'Architect (Claude Opus)':'architect','Aegis (Claude Sonnet, reviewer)':'aegis','Dev (OpenAI)':'dev','Linter (Local LLM)':'linter'}; \
	let changed=0; \
	for (const a of db.prepare('SELECT id, name, config, session_key FROM agents').all()) { \
	  const oc=map[a.name]; if (!oc) continue; \
	  const cfg=a.config?JSON.parse(a.config):{}; \
	  let touched=false; \
	  if (cfg.openclawId!==oc) { cfg.openclawId=oc; touched=true; } \
	  const expectedKey='mc-'+oc; \
	  if (a.session_key!==expectedKey) { \
	    db.prepare('UPDATE agents SET session_key=?, updated_at=? WHERE id=?').run(expectedKey, Math.floor(Date.now()/1000), a.id); \
	    touched=true; \
	  } \
	  if (touched) { \
	    db.prepare('UPDATE agents SET config=? WHERE id=?').run(JSON.stringify(cfg), a.id); \
	    changed++; \
	  } \
	} \
	console.log('agents updated:', changed); \
	\""
	# 5. Verify by re-issuing the call.
	@echo "==> verifying pairing..."
	@docker exec mission-control-dev openclaw gateway call health --json --timeout 8000 2>&1 | head -3

.PHONY: openclaw-unpair-mc
openclaw-unpair-mc:  ## Remove MC's paired entry (gateway side) and MC's local identity. Confirm with CONFIRM=yes.
	@cd $(PROJECT_DIR)
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "Refusing to unpair without CONFIRM=yes"; exit 1; \
	fi
	@rm -rf .mc-openclaw/identity .mc-openclaw/devices 2>/dev/null || true
	@if [ -f .openclaw-data/devices/paired.json ]; then \
	  python3 -c "import json,pathlib; p=pathlib.Path('.openclaw-data/devices/paired.json'); d=json.loads(p.read_text()); mc=[k for k,v in d.items() if v.get('clientId')=='cli' and v.get('platform')=='linux']; [d.pop(k) for k in mc]; p.write_text(json.dumps(d,indent=2)); print(f'removed {len(mc)} entries from paired.json')"; \
	fi
	@echo "MC openclaw pairing cleared. Restart MC and run 'make openclaw-pair-mc' to re-pair."

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
