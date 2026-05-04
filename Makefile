# Mission Control — local stack control plane.
# Use `make help` for minimal workflow, `make help-all` for full target list.

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

-include .env
-include .env.openclaw
export

PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
COMPOSE     := docker compose
COMPOSE_DEV := docker compose -f docker-compose-dev.yml
COMPOSE_OC  := docker compose -f docker-compose-openclaw.yml
OPENCLAW_SRC := $(PROJECT_DIR)/openclaw-src
OPENCLAW_REPO := https://github.com/openclaw/openclaw.git
OPENCLAW_REF  := main
MC_MODE ?= prod
MC_MODE_DEFAULT := $(MC_MODE)
OPENCLAW_ENABLED ?= 1
CONTAINER   := mission-control
CONTAINER_DEV := mission-control-dev
MC_URL_SCHEME ?= http
MC_HOST ?= 127.0.0.1
MC_PORT ?= 7012
URL         := $(MC_URL_SCHEME)://$(MC_HOST):$(MC_PORT)

OPENCLAW_STATUS_HOST ?= 127.0.0.1
OPENCLAW_GATEWAY_PORT ?= 18789
OPENCLAW_CONTROL_UI_PORT ?= 18791

MODE_WORDS := $(filter dev prod,$(MAKECMDGOALS))
ifneq ($(words $(MODE_WORDS)),0)
ifneq ($(words $(MODE_WORDS)),1)
$(error Conflicting mode selectors $(MODE_WORDS). Use only one of dev or prod)
endif
endif

CLI_MODE_OVERRIDE := $(firstword $(MODE_WORDS))
EFFECTIVE_MC_MODE := $(if $(CLI_MODE_OVERRIDE),$(CLI_MODE_OVERRIDE),$(MC_MODE))

# Propagate effective mode into recursive $(MAKE) invocations.
MC_MODE := $(EFFECTIVE_MC_MODE)

VALID_EFFECTIVE_MC_MODE := $(filter $(EFFECTIVE_MC_MODE),prod dev)
ifeq ($(VALID_EFFECTIVE_MC_MODE),)
$(error Invalid MC mode '$(EFFECTIVE_MC_MODE)'. Expected 'prod' or 'dev' (from positional mode token or MC_MODE))
endif

SCOPE_WORDS := $(filter all mc openclaw,$(MAKECMDGOALS))
ifneq ($(words $(SCOPE_WORDS)),0)
ifneq ($(words $(SCOPE_WORDS)),1)
$(error Conflicting component selectors $(SCOPE_WORDS). Use only one of all, mc, or openclaw)
endif
endif

TARGET_SCOPE := $(if $(SCOPE_WORDS),$(firstword $(SCOPE_WORDS)),all)

VALID_OPENCLAW_ENABLED := $(filter $(OPENCLAW_ENABLED),0 1)
ifeq ($(VALID_OPENCLAW_ENABLED),)
$(error Invalid OPENCLAW_ENABLED='$(OPENCLAW_ENABLED)'. Expected '0' or '1')
endif

ifeq ($(EFFECTIVE_MC_MODE),dev)
MC_COMPOSE := $(COMPOSE_DEV)
MC_CONTAINER := $(CONTAINER_DEV)
MC_STACK_LABEL := dev
else
MC_COMPOSE := $(COMPOSE)
MC_CONTAINER := $(CONTAINER)
MC_STACK_LABEL := prod
endif

.DEFAULT_GOAL := help
MAKE_SUB := $(MAKE) --no-print-directory MC_MODE=$(EFFECTIVE_MC_MODE)

# Selector/mode tokens for `make <verb> [scope] [mode]`
.PHONY: all mc openclaw dev prod
all mc openclaw dev prod:
	@:

# ── Help ───────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## Show minimal day-to-day commands
	@printf "\nMission Control Make workflow\n\n"
	@printf "  Effective mode:     %s\n" "$(EFFECTIVE_MC_MODE)"
	@printf "  Mode source:        %s\n" "$(if $(CLI_MODE_OVERRIDE),token $(firstword $(MODE_WORDS)),MC_MODE=$(MC_MODE_DEFAULT))"
	@printf "  Target scope:       %s\n" "$(TARGET_SCOPE)"
	@printf "  OpenClaw enabled:   %s (1=yes, 0=no)\n\n" "$(OPENCLAW_ENABLED)"
	@printf "Set defaults in .env/.env.openclaw:\n"
	@printf "  MC_MODE=prod|dev\n"
	@printf "  OPENCLAW_ENABLED=1|0\n\n"
	@printf "Grammar:\n"
	@printf "  %-20s %s\n\n" "make <verb> [scope] [mode]" "scope: all (default) | mc | openclaw; mode: dev|prod"
	@printf "Recommended commands:\n"
	@printf "  %-20s %s\n" "make up" "Start stack for scope (all respects OPENCLAW_ENABLED)"
	@printf "  %-20s %s\n" "make restart" "Deterministic stop+start for scope"
	@printf "  %-20s %s\n" "make down" "Stop stack for scope"
	@printf "  %-20s %s\n" "make status" "Show health for scope"
	@printf "  %-20s %s\n" "make update" "Refresh source/state only (no forced rebuild)"
	@printf "  %-20s %s\n" "make rebuild" "Force rebuild selected component(s)"
	@printf "  %-20s %s\n" "make upgrade" "update + rebuild + restart for scope"
	@printf "\nExamples:\n"
	@printf "  %-20s %s\n" "make status openclaw" "OpenClaw-only status"
	@printf "  %-20s %s\n" "make restart dev" "Restart all in dev mode for this invocation"
	@printf "  %-20s %s\n" "make restart mc dev" "Restart MC only in dev mode"
	@printf "  %-20s %s\n" "make status prod" "Check all scope in prod mode"
	@printf "\nAdvanced:\n"
	@printf "  %-20s %s\n" "make help-all" "List all available targets"

.PHONY: help-all
help-all:  ## List all targets
	@awk 'BEGIN{FS=":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	      /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
	      $(MAKEFILE_LIST)

# ── Unified lifecycle (mode selected via MC_MODE=prod|dev) ────────────────
.PHONY: mc-up
mc-up:
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) up -d $(ARGS)
	@$(MAKE_SUB) wait-ready

.PHONY: up
up:  ## Start selected mode (+ OpenClaw when enabled)
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) mc-up ARGS="$(ARGS)"; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) openclaw-up; \
	    ;; \
	  all) \
	    $(MAKE_SUB) mc-up ARGS="$(ARGS)"; \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      $(MAKE_SUB) openclaw-up; \
	    else \
	      echo "OpenClaw disabled (OPENCLAW_ENABLED=0): skipping OpenClaw startup"; \
	    fi; \
	    ;; \
	esac
	@if [ "$(TARGET_SCOPE)" != "openclaw" ]; then \
	  echo; \
	  echo "Mission Control ($(MC_STACK_LABEL)) is up at $(URL)"; \
	  echo "  /setup    — create admin (first run)"; \
	  echo "  /login    — sign in"; \
	  echo "  /tasks    — Kanban board"; \
	  echo "  /agents   — agent registry"; \
	fi
	@if [ "$(TARGET_SCOPE)" != "mc" ]; then \
	  if [ "$(TARGET_SCOPE)" = "openclaw" ] || [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	    echo "OpenClaw endpoints:"; \
	    echo "  gateway  — http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_GATEWAY_PORT)/healthz"; \
	    echo "  control  — http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_CONTROL_UI_PORT)/"; \
	  fi; \
	fi

.PHONY: mc-down
mc-down:
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) down

.PHONY: down
down:  ## Stop selected mode (+ OpenClaw when enabled)
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) mc-down; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) openclaw-down; \
	    ;; \
	  all) \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      $(MAKE_SUB) openclaw-down; \
	    fi; \
	    $(MAKE_SUB) mc-down; \
	    ;; \
	esac

.PHONY: mc-restart
mc-restart:
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) restart
	@$(MAKE_SUB) wait-ready

.PHONY: restart
restart:  ## Deterministic restart: down then up for selected scope
	@$(MAKE_SUB) down TARGET_SCOPE=$(TARGET_SCOPE)
	@$(MAKE_SUB) up TARGET_SCOPE=$(TARGET_SCOPE)

.PHONY: recreate
recreate:  ## Force recreate selected mode container
	@$(MAKE_SUB) up ARGS="--force-recreate"

.PHONY: build
build:  ## Build/refresh selected mode Mission Control image
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) build $(ARGS)

.PHONY: rebuild
rebuild:  ## Rebuild image (no cache) and recreate selected mode
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) rebuild-mc; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) rebuild-openclaw; \
	    ;; \
	  all) \
	    $(MAKE_SUB) rebuild-mc; \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      $(MAKE_SUB) rebuild-openclaw; \
	    else \
	      echo "OpenClaw disabled (OPENCLAW_ENABLED=0): skipping OpenClaw rebuild"; \
	    fi; \
	    ;; \
	esac

.PHONY: rebuild-mc
rebuild-mc:
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) build --no-cache
	@$(MAKE_SUB) recreate TARGET_SCOPE=mc

.PHONY: rebuild-openclaw
rebuild-openclaw: openclaw-build

.PHONY: ps
ps:  ## Show selected mode container status
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) ps

.PHONY: logs
logs:  ## Tail selected mode server logs (Ctrl+C to stop)
	@cd $(PROJECT_DIR)
	$(MC_COMPOSE) logs -f --tail=200

.PHONY: shell
shell:  ## Open interactive shell in selected mode container
	docker exec -it $(MC_CONTAINER) bash || docker exec -it $(MC_CONTAINER) sh

.PHONY: status
status:  ## Show selected mode and endpoint health
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) status-mc; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) openclaw-status; \
	    ;; \
	  all) \
	    $(MAKE_SUB) status-mc; \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      echo; \
	      $(MAKE_SUB) openclaw-status; \
	    else \
	      echo "OpenClaw status:   skipped (OPENCLAW_ENABLED=0)"; \
	    fi; \
	    ;; \
	esac

.PHONY: status-mc
status-mc:
	@echo "Mode:              $(EFFECTIVE_MC_MODE)"
	@echo "MC container:      $(MC_CONTAINER)"
	@echo "OpenClaw enabled:  $(OPENCLAW_ENABLED)"
	@printf "MC URL:            "; curl -sS -o /dev/null -L -w "%{http_code} → %{url_effective}\n" $(URL) || true
	@if docker ps --format '{{.Names}}' | grep -q '^$(MC_CONTAINER)$$'; then \
	  printf "claude:            "; docker exec $(MC_CONTAINER) sh -c 'which claude && claude --version' 2>&1 | tail -1; \
	  printf "codex:             "; docker exec $(MC_CONTAINER) sh -c 'which codex && codex --version 2>&1 | tail -1' 2>&1 | tail -1; \
	  printf "gemini:            "; docker exec $(MC_CONTAINER) sh -c 'which gemini' 2>&1 | tail -1; \
	else \
	  echo "MC CLI checks:     container not running"; \
	fi

# ── Update workflows ───────────────────────────────────────────────────────
.PHONY: repo-update
repo-update:  ## [shared] Fast-forward current git branch from origin
	@cd $(PROJECT_DIR)
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	  echo "==> fetching origin/$$branch"; \
	  git fetch origin "$$branch"; \
	  git merge --ff-only "origin/$$branch"

.PHONY: openclaw-source-update
openclaw-source-update: openclaw-clone  ## [openclaw] Refresh openclaw source only (no build/restart)
	@echo "==> openclaw source refreshed (no rebuild/restart)"

.PHONY: update
update:  ## Refresh source/state only (no forced rebuild)
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) update-mc; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) update-openclaw; \
	    ;; \
	  all) \
	    $(MAKE_SUB) update-mc; \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      $(MAKE_SUB) update-openclaw; \
	    else \
	      echo "OpenClaw disabled (OPENCLAW_ENABLED=0): skipping openclaw source refresh"; \
	    fi; \
	    ;; \
	esac

.PHONY: update-mc
update-mc: repo-update

.PHONY: update-openclaw
update-openclaw: openclaw-source-update

.PHONY: upgrade
upgrade:  ## update + rebuild + restart (+ OpenClaw update path when enabled)
	@case "$(TARGET_SCOPE)" in \
	  mc) \
	    $(MAKE_SUB) upgrade-mc; \
	    ;; \
	  openclaw) \
	    $(MAKE_SUB) upgrade-openclaw; \
	    ;; \
	  all) \
	    $(MAKE_SUB) upgrade-mc; \
	    if [ "$(OPENCLAW_ENABLED)" = "1" ]; then \
	      $(MAKE_SUB) upgrade-openclaw; \
	    else \
	      echo "OpenClaw disabled (OPENCLAW_ENABLED=0): skipping OpenClaw upgrade"; \
	    fi; \
	    ;; \
	esac

.PHONY: upgrade-mc
upgrade-mc:
	@$(MAKE_SUB) update-mc
	@$(MAKE_SUB) rebuild-mc
	@$(MAKE_SUB) mc-restart

.PHONY: upgrade-openclaw
upgrade-openclaw: openclaw-update

# ── Lifecycle utilities ────────────────────────────────────────────────────
.PHONY: wait-ready
wait-ready:  ## Block until /login responds 200
	@for i in $$(seq 1 30); do \
	  status=$$(curl -sS --connect-timeout 1 --max-time 2 -o /dev/null -L -w '%{http_code}' $(URL) 2>/dev/null || true); \
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
	@$(MAKE_SUB) up
	@echo
	@echo "Open $(URL)/setup to create a fresh admin."

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
openclaw-update: openclaw-clone openclaw-build openclaw-restart  ## [openclaw] Pull source + rebuild dist + restart gateway
	@echo "==> openclaw updated to $$(cd $(OPENCLAW_SRC) && git rev-parse --short HEAD); gateway restarted."

.PHONY: openclaw-up
openclaw-up:  ## Start openclaw gateway + control UI + local auto-pair (ports 18789, 18791)
	@cd $(PROJECT_DIR)
	if [ ! -f "$(OPENCLAW_SRC)/dist/index.js" ] || [ ! -f "$(OPENCLAW_SRC)/dist/control-ui/index.html" ]; then \
	  echo "openclaw dist/control-ui assets missing; building first..."; \
	  $(MAKE_SUB) openclaw-build; \
	fi
	mkdir -p .openclaw-data/credentials .mc-openclaw/credentials
	$(COMPOSE_OC) up -d openclaw-gateway openclaw-control-ui openclaw-control-ui-autopair
	@echo "openclaw-gateway is starting on http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_GATEWAY_PORT)"
	@echo "openclaw-control-ui is starting on http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_CONTROL_UI_PORT)"
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
	@curl -fsS -o /dev/null -w "%{http_code}\n" "http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_GATEWAY_PORT)/healthz" 2>&1 || echo "DOWN"
	@printf "Control UI:   "
	@curl -fsS -o /dev/null -w "%{http_code}\n" "http://$(OPENCLAW_STATUS_HOST):$(OPENCLAW_CONTROL_UI_PORT)/" 2>&1 || echo "DOWN"
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
	@if grep -q "^OPENCLAW_GATEWAY_TOKEN=." .env 2>/dev/null || grep -q "^OPENCLAW_GATEWAY_TOKEN=." .env.openclaw 2>/dev/null; then \
	  echo "MC token:     set in .env/.env.openclaw"; \
	else \
	  echo "MC token:     NOT set in .env/.env.openclaw — copy from .openclaw-data/openclaw.json"; \
	fi
	@if docker ps --format '{{.Names}}' | grep -q '^$(MC_CONTAINER)$$'; then \
	  printf "MC->Gateway: "; \
	  docker exec $(MC_CONTAINER) openclaw gateway call health --json --timeout 8000 >/dev/null 2>&1 && echo "OK" || echo "FAIL"; \
	else \
	  echo "MC->Gateway: selected MC container not running"; \
	fi
	@if [ -f .openclaw-data/devices/pending.json ]; then \
	  printf "Pending pair: "; \
	  python3 -c "import json,pathlib; p=pathlib.Path('.openclaw-data/devices/pending.json'); d=json.loads(p.read_text() or '{}'); print(len(d))"; \
	else \
	  echo "Pending pair: pending.json missing"; \
	fi
	@if docker ps --format '{{.Names}}' | grep -q '^mc-openclaw-control-ui-autopair$$'; then \
	  echo "Auto-pair:    running (local control-ui requests)"; \
	else \
	  echo "Auto-pair:    NOT running"; \
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
	@if ! docker ps --format '{{.Names}}' | grep -q '^$(MC_CONTAINER)$$'; then \
	  echo "ERROR: $(MC_CONTAINER) not running — run 'make up' first (mode: $(MC_MODE))" >&2; exit 1; \
	fi
	# 2. Trigger MC's openclaw CLI once so it generates ~/.openclaw/identity/device.json
	#    and submits a pending pairing request to the gateway. The call itself is
	#    expected to fail with "pairing required" — that is exactly what creates
	#    the pending entry. Subsequent retries after the patch will succeed.
	@echo "==> triggering pairing request from MC..."
	@docker exec $(MC_CONTAINER) openclaw gateway call health --json --timeout 5000 >/dev/null 2>&1 || true
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
	@docker exec $(MC_CONTAINER) sh -c "cd /app && node -e \"\
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
	@docker exec $(MC_CONTAINER) openclaw gateway call health --json --timeout 8000 2>&1 | head -3

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
	$(MC_COMPOSE) down -v
	docker image rm mission-control-mission-control 2>/dev/null || true
