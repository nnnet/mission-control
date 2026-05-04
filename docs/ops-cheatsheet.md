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
```

## 3) Compatibility aliases (optional)

```bash
make dev-up
make dev-restart
make dev-down
make dev-ps
```

## 4) OpenClaw lifecycle (direct commands)

```bash
make openclaw-up
make openclaw-restart
make openclaw-down
make openclaw-status
```

## 5) Upgrade flows

```bash
make upgrade
make upgrade-dev
make upgrade-openclaw
```

## 5) Quick health check URLs

```text
Mission Control base:   http://127.0.0.1:7012
Mission Control login:  http://127.0.0.1:7012/login
OpenClaw health:        http://127.0.0.1:18789/healthz
OpenClaw Control UI:    http://127.0.0.1:18791/
```

Defaults come from `MC_URL_SCHEME`, `MC_HOST`, `MC_PORT`, `OPENCLAW_STATUS_HOST`, `OPENCLAW_GATEWAY_PORT`, and `OPENCLAW_CONTROL_UI_PORT` in `.env` / `.env.openclaw`.
