# Mission Control — local stack control plane.
# Use `make help` for the full target list.

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
COMPOSE     := docker compose
CONTAINER   := mission-control
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
.PHONY: nuke
nuke:  ## DANGER: down, drop volumes, drop image. Confirm via CONFIRM=yes
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "Refusing to nuke without CONFIRM=yes"; exit 1; \
	fi
	@cd $(PROJECT_DIR)
	$(COMPOSE) down -v
	docker image rm mission-control-mission-control 2>/dev/null || true
