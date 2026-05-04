# Daily Ops Cheatsheet (Makefile)

Use this as a fast copy-paste reference for daily container operations.

## 1) Choose mode once (.env)

```env
MC_MODE=prod            # or dev
OPENCLAW_ENABLED=1      # set 0 for MC-only lifecycle
```

## 2) Primary lifecycle (mode-aware)

```bash
make up
make restart
make down
make status
make update
make rebuild
make upgrade
```

## 3) Command matrix (prod/dev via `MC_MODE`)

| Intent | Command |
|---|---|
| Start selected mode (+ OpenClaw when enabled) | `make up` |
| Restart selected mode (+ OpenClaw when enabled) | `make restart` |
| Stop selected mode (+ OpenClaw when enabled) | `make down` |
| Health/status for selected mode | `make status` |
| Refresh git/source state only | `make update` |
| Force no-cache image rebuild + recreate selected mode | `make rebuild` |
| Full maintenance flow | `make upgrade` |

Mode override examples:

```bash
MC_MODE=prod OPENCLAW_ENABLED=1 make upgrade
MC_MODE=dev  OPENCLAW_ENABLED=0 make rebuild
```

## 4) `update` vs `upgrade`

- `make update` = **source/state refresh only**
  - Fast-forward current branch from origin
  - Refresh OpenClaw source when `OPENCLAW_ENABLED=1`
  - **No forced MC image rebuild** and **no forced restart**

- `make upgrade` = **`update` + `rebuild` + `restart`**
  - Runs `make update`
  - Runs `make rebuild` (no-cache MC image rebuild + recreate)
  - Runs `make restart`
  - When `OPENCLAW_ENABLED=1`, also runs OpenClaw update path (`make openclaw-update`: source refresh + dist rebuild + gateway restart)

## 5) Compatibility aliases (optional)

```bash
make dev-up
make dev-restart
make dev-down
make dev-ps
make update-dev
make upgrade-dev
```

## 6) OpenClaw lifecycle (direct commands)

```bash
make openclaw-up
make openclaw-restart
make openclaw-down
make openclaw-status
```

## 7) Quick health check URLs

```text
Mission Control base:   http://127.0.0.1:7012
Mission Control login:  http://127.0.0.1:7012/login
OpenClaw health:        http://127.0.0.1:18789/healthz
OpenClaw Control UI:    http://127.0.0.1:18791/
```

Defaults come from `MC_URL_SCHEME`, `MC_HOST`, `MC_PORT`, `OPENCLAW_STATUS_HOST`, `OPENCLAW_GATEWAY_PORT`, and `OPENCLAW_CONTROL_UI_PORT` in `.env` / `.env.openclaw`.
