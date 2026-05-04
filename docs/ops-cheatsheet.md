# Daily Ops Cheatsheet (Makefile)

Use this as a fast copy-paste reference for daily container operations.

## 1) Choose mode once (.env)

```env
MC_MODE=prod            # or dev
OPENCLAW_ENABLED=1      # set 0 for MC-only lifecycle
```

## 2) Primary lifecycle (universal verbs)

```bash
make up
make restart
make down
make status
make update
make rebuild
make upgrade
```

## 3) Command grammar

```text
make <verb> [all|mc|openclaw] [dev|prod]
```

- `all` is the default scope.
- `dev` / `prod` overrides `MC_MODE` for a single invocation.
- Why no `--dev` / `--prod`: GNU Make consumes unknown `--xxx` as Make options before Makefile goal parsing, so mode uses positional tokens for deterministic behavior.
- `make restart [scope]` is deterministic and always executes `make down [scope]` followed by `make up [scope]`.
- For default scope `all`, OpenClaw participation is controlled only by `OPENCLAW_ENABLED` (`1` includes OpenClaw in both down/up, `0` skips it in both).

Examples:

```bash
make restart dev
make restart mc dev
make status openclaw
make status prod
```

## 4) Command matrix (scope + mode-aware)

| Intent | Command |
|---|---|
| Start selected component(s) | `make up [all|mc|openclaw]` |
| Restart selected component(s) | `make restart [all|mc|openclaw]` |
| Stop selected component(s) | `make down [all|mc|openclaw]` |
| Health/status for selected component(s) | `make status [all|mc|openclaw]` |
| Refresh source/state only for selected component(s) | `make update [all|mc|openclaw]` |
| Force rebuild selected component(s) | `make rebuild [all|mc|openclaw]` |
| Full maintenance flow for selected component(s) | `make upgrade [all|mc|openclaw]` |

Mode override examples:

```bash
make up dev
make restart mc prod
```

## 5) `update` vs `upgrade`

- `make update [scope]` = **source/state refresh only**
  - Fast-forward current branch from origin
  - Refresh OpenClaw source when `OPENCLAW_ENABLED=1`
  - **No forced MC image rebuild** and **no forced restart**

- `make upgrade [scope]` = **`update` + `rebuild` + `restart`** for the selected scope
  - `scope=mc`: MC-only update/rebuild/restart
  - `scope=openclaw`: OpenClaw source/build/restart
  - `scope=all` (default): both; OpenClaw path runs only when `OPENCLAW_ENABLED=1`

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
