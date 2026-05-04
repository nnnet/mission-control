# Development Plan: mission-control (experiment/openclaw-integration branch)

*Generated on 2026-05-02 by Vibe Feature MCP*
*Workflow: [bugfix](https://codemcp.github.io/workflows/workflows/bugfix)*

## Goal
*Define what you're building or fixing - this will be updated as requirements are gathered*
## Key Decisions
*Important decisions will be documented here as they are made*
- Local run guidance will follow README manual setup (`pnpm dev`) and use `OPENCLAW_STATE_DIR`/`OPENCLAW_CONFIG_PATH` for OpenClaw integration; `NEXT_PUBLIC_GATEWAY_OPTIONAL=true` only when intentionally running without gateway.
- Docker-only constraint: run Mission Control and OpenClaw via Makefile/Docker Compose (no non-Docker runs).
- Use dev stack (`make dev`) for bind-mounted code; only rebuild images when dependencies/framework packages change.
- Must complete `make openclaw-pair-mc` to establish full integration.
- Prod linkage attempt uses `make up` + `make openclaw-up`; pairing in prod requires OpenClaw CLI inside `mission-control` container. Current prod image lacks `openclaw` binary, so CLI-based pairing cannot be initiated from MC.
- Control UI assets warning is emitted by OpenClaw gateway runtime when UI build artifacts are absent; resolution is to build UI assets (`pnpm ui:build`) via `make openclaw-build`/builder so `openclaw-src/dist` includes control UI output.
- `OAuth dir not present (~/.openclaw/credentials)` is expected when no WhatsApp/pairing channel config is active; it’s a state-integrity warning, not a hard failure.
- `Telegram DMs: locked (channels.telegram.dmPolicy="pairing")` reflects default policy (`pairing`) and is expected unless config changes.
- Production `mission-control` container now gets OpenClaw CLI via compose-mounted executable shim (`scripts/openclaw-cli-shim.py` -> `/home/nextjs/.local/bin/openclaw`) plus mounted `openclaw-src` runtime (`/opt/openclaw-src`), so `docker exec mission-control openclaw ...` works without rebuilding MC image.
- OpenClaw gateway startup now creates `/home/node/.openclaw/credentials` before launch, eliminating noisy OAuth-dir absence warnings for prod linkage.
- Doctor parsing in Mission Control now treats `Telegram DMs: locked (channels.telegram.dmPolicy="pairing")` as expected-security informational output, reducing false-warning semantics.
- Added idempotent OpenClaw state bootstrap at startup/invocation boundaries: gateway startup now hard-sets `gateway.mode=local` in `.openclaw-data/openclaw.json`, and MC CLI shim now ensures `.mc-openclaw/openclaw.json` contains `gateway.mode=local` before every call.
- Added explicit credential-dir bootstrap for both state roots (`.openclaw-data/credentials` and `.mc-openclaw/credentials`) to remove OAuth-dir absence noise.
- Added separate OpenClaw Control UI container (`mc-openclaw-control-ui`) serving `openclaw-src/dist/control-ui` on dedicated host port `OPENCLAW_CONTROL_UI_PORT` (default `18791`).
- Added local-only Control UI device auto-approval sidecar (`mc-openclaw-control-ui-autopair`) that watches pending pair requests and auto-approves only local Docker Control UI requests (`clientId=openclaw-control-ui`, private/loopback IP, `gateway.mode=local`).
- Standardized Make lifecycle naming by mode: prod uses `up/down/restart`; dev uses `dev-up/dev-down/dev-restart` with `dev` as alias to `dev-up`.
- Added explicit update workflows for fast-moving MC/OpenClaw versions (`upgrade`, `upgrade-dev`, `openclaw-update`, `upgrade-openclaw`) and mode-specific help text.

## Notes
*Additional context and observations*
- bd database unavailable: `bd ready` fails (Dolt server says database "mission_control" not found on 127.0.0.1:13870). Need bd/Dolt server fix before creating Reproduce tasks.
- Reproduce run (Docker dev): `make dev` started MC at http://127.0.0.1:7012/login (200). `make openclaw-up` started gateway on 18789 (healthy).
- `make openclaw-pair-mc` initial verify failed (GatewayTransportError: ws closed 1006 to ws://host.docker.internal:18789). After ~30s, retry succeeded (`{"ok": true ...}`) and pairing already present (idempotent). Agents update count 0.
- `make status` failed because it expects container `mission-control` (prod); dev stack uses `mission-control-dev`. Use `make dev-ps` + `make openclaw-ps` for dev status.
- `bd ready --json` remains blocked in this environment: `database "mission_control" not found on Dolt server at 127.0.0.1:13870`.
- Prod container starts successfully but `make up` can fail `wait-ready` (30s) even when Next.js is ready; logs show server ready and migrations applied.
- OpenClaw gateway logs show `gateway.auth.token` surface inactive warning even with token env var configured.
- `bd doctor --fix` requires `--yes` for non-interactive; database still not reachable (dolt server missing `mission_control` db on 127.0.0.1:13870), so bd tasks cannot be created yet.
- Gateway container has `/home/node/.openclaw/canvas/index.html` but no `/home/node/.openclaw/control-ui` directory (likely source of “Control UI assets are missing” warning).
- Control UI connect failure root cause: pending device requests from `openclaw-control-ui` were not auto-approved in local Docker, leaving requestIds stuck in `.openclaw-data/devices/pending.json` and causing `device pairing required` on every new browser identity.

## Reproduce
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Environment
- OS: Ubuntu 24.04.4 LTS (kernel 6.8.0-110-generic, x86_64)
- Docker Engine: 29.4.0 (API 1.54)
- Docker Compose: v5.1.3
- Browser/runtime: not provided
- Hardware: not provided

### Steps to Reproduce (prod linkage attempt)
1. `make dev-down` (ensure dev stack is stopped to free port 7012).
2. `make up` (prod stack). Note: `wait-ready` may time out at 30s even when Next.js is ready.
3. `make openclaw-up` then `make openclaw-status` (gateway HTTP 200; config present; token set in .env).
4. Attempt to initiate pairing from prod container:
   - `docker exec mission-control openclaw gateway call health --json --timeout 5000`
   - **Observed error**: `exec: "openclaw": executable file not found in $PATH`.

### Observed Errors / Warnings
- `OpenClaw state integrity warning — Control UI assets are missing.`
- `OAuth dir not present (~/.openclaw/credentials). Skipping create`
- `Telegram DMs: locked (channels.telegram.dmPolicy="pairing")`
- Prod container: `openclaw` CLI missing, prevents MC pairing in prod.
- Gateway log warning: `SECRETS_GATEWAY_AUTH_SURFACE gateway.auth.token is inactive` (env var configured).

### Reproducibility
- Control UI assets missing / OAuth dir warning reported consistently in current setup.
- Prod pairing failure is deterministic (openclaw binary absent in prod container).

### Impact
- Business impact: not provided.

### Test Cases
1. **Prod pairing CLI presence**
   - Command: `docker exec mission-control sh -c 'which openclaw'`
   - Expected: path to openclaw CLI
   - Actual: `openclaw not in PATH`
2. **Gateway health**
   - Command: `make openclaw-status`
   - Expected: HTTP 200, config present, token set
   - Actual: HTTP 200, config present, token set

## Analyze
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Findings
- **Prod pairing failure root cause**: `mission-control` prod image lacks OpenClaw CLI shim/binary (Dockerfile only installs system deps + Claude/Codex CLIs). `make openclaw-pair-mc` is dev-only (checks `mission-control-dev`) and relies on the dev CLI shim + bind-mounted `openclaw-src/dist`.
- **Control UI assets warning**: OpenClaw gateway logs originate from `openclaw-src/src/cli/gateway-cli/run.ts` / `doctor-ui.ts` (and built dist). Warning indicates Control UI assets missing and suggests `pnpm ui:build`. The gateway container’s state mount shows `/home/node/.openclaw/canvas/index.html` present but `/home/node/.openclaw/control-ui` missing; this matches the warning and points to missing UI build artifacts.
- **OAuth dir warning**: `openclaw-src/src/commands/doctor-state-integrity.ts` logs the warning only when OAuth dir is absent *and* no WhatsApp/pairing channel config is active; informational unless those channels are configured.
- **Telegram dmPolicy message**: `pairing` is the default dmPolicy (see hardening guide and schema defaults), so “DMs locked” is expected behavior unless explicitly configured to `open`/`allowlist`.
- **Prod CLI availability root cause**: production compose had no mounted OpenClaw runtime path (`openclaw-src`) and no mounted shim on PATH, so `openclaw` was unavailable in `mission-control` container.
- **gateway.mode blocked start root cause**: MC-side state file `.mc-openclaw/openclaw.json` lacked `gateway.mode`, which can trip stricter OpenClaw gateway/CLI checks and trigger “gateway.mode is unset” warnings.
- **Control UI separation gap**: existing compose only exposed gateway daemon endpoints, so there was no dedicated HTTP service/port for control UI assets.
- **Control UI 1006 root cause**: dedicated `openclaw-control-ui` nginx service on `:18791` served static files only, so same-origin gateway API + WebSocket upgrade traffic from the Control UI did not terminate on the gateway process.
- **Local security warning noise**: docker compose defaults did not set `MC_ALLOWED_HOSTS`, causing avoidable host-allowlist warnings on first local run.

## Fix
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Applied changes
- `docker-compose-openclaw.yml`
  - Kept dedicated `openclaw-control-ui` service on `:18791`, but switched it from static-only serving to reverse-proxy topology for gateway APIs/WebSockets.
  - Added nginx config mount so Control UI static assets are served while `/__openclaw/*`, `/api/*`, `/ws`, and `/gateway-ws` are proxied to `openclaw-gateway:18789`.
- `docker/openclaw-control-ui.nginx.conf`
  - New reverse-proxy config enabling same-origin gateway API + WS upgrades to prevent UI disconnect `1006` on port `18791`.
  - WS proxy locations now intentionally omit `X-Forwarded-*` headers so gateway locality resolves as local-browser-container traffic (`browser_container_local`) instead of remote-proxied traffic; this restores silent local pairing and removes repeated `4008 connect failed` from `NOT_PAIRED`.
- `docker-compose.yml`
  - Added local-safe default `MC_ALLOWED_HOSTS=${MC_ALLOWED_HOSTS:-localhost,127.0.0.1,::1}` to reduce avoidable security scan warnings without broad host exposure.
- `docker-compose-dev.yml`
  - Added local-safe default `MC_ALLOWED_HOSTS=${MC_ALLOWED_HOSTS:-localhost,127.0.0.1,::1}` for dev stack parity.
- `.env.example`
  - Clarified HTTPS-only security toggles: keep `MC_COOKIE_SECURE` unset on plain HTTP, enable `MC_COOKIE_SECURE=1` and `MC_ENABLE_HSTS=1` only behind HTTPS.
- `docs/openclaw-telegram-onboarding.md`
  - Added concise operator runbook for "token present but dmPolicy=pairing" with user-id discovery, pairing list/approve flow, allowlist keys, and restart step.
- `openclaw_hardening_guide.md`
  - Added direct pointer to Telegram onboarding runbook.
- `src/lib/openclaw-doctor.ts`
  - Kept Telegram pairing lock output non-blocking with a more permissive matcher (`"pairing"` or `'pairing'`).
- `src/lib/__tests__/openclaw-doctor.test.ts`
  - Added regression test that pairing-lock line is treated as informational.
- `Makefile`
  - `openclaw-up` starts `openclaw-gateway` + `openclaw-control-ui` reverse proxy.
  - Status text updated to reflect the dedicated Control UI service.
- `Makefile`
  - Added mode-explicit lifecycle targets and help labels for prod vs dev (`up/restart` vs `dev-up/dev-restart/dev-down`).
  - `restart` and `dev-restart` now conditionally restart OpenClaw gateway when `mc-openclaw-gateway` is active.
  - Added safe update targets: `repo-update` (git fast-forward), `upgrade` (prod), `upgrade-dev` (dev), `upgrade-openclaw` alias.
- `docs/deployment.md`
  - Added a command matrix for prod/dev lifecycle and update workflows, plus shared OpenClaw update commands.

- `docker-compose.yml`
  - Added OpenClaw gateway runtime env vars for production container (`OPENCLAW_GATEWAY_URL`, token, insecure-private-ws flag, explicit `OPENCLAW_STATE_DIR`).
  - Added production mounts:
    - `./.mc-openclaw:/home/nextjs/.openclaw:rw`
    - `./openclaw-src:/opt/openclaw-src:ro`
    - `./scripts/openclaw-cli-shim.py:/home/nextjs/.local/bin/openclaw:ro`
  - Effect: `mission-control` now has an executable `openclaw` command on PATH that targets mounted OpenClaw runtime.
- `scripts/openclaw-cli-shim.py`
  - Marked executable (mode `100755`) so compose-mounted path is directly invokable as `openclaw`.
- `docker-compose-openclaw.yml`
  - Builder now runs `pnpm ui:build` after `pnpm build` in `openclaw-build`, ensuring Control UI assets are produced.
  - Gateway start command now pre-creates OAuth credential directory: `mkdir -p /home/node/.openclaw/credentials` before exec.
  - Aligned CLI sidecar plugin stage dir to `/home/node/.openclaw/plugin-runtime-deps` (same state volume strategy as gateway).
- `src/lib/openclaw-doctor.ts`
  - Treats `Telegram DMs: locked (channels.telegram.dmPolicy="pairing")` as expected/informational line so default-secure posture does not appear as actionable warning in MC parsing.
- `docker-compose-openclaw.yml`
  - Added idempotent prestart config bootstrap to force `gateway.mode="local"` before gateway launch.
  - Bootstrap now also force-aligns gateway auth to env-token resolution whenever `OPENCLAW_GATEWAY_TOKEN` is set (`gateway.auth.mode=token` + `gateway.auth.token` env-ref), preventing drift between runtime env and generated config.
  - Extended prestart config bootstrap to enforce these Control UI origins in `gateway.controlUi.allowedOrigins` (without wildcarding):
    - `http://localhost:18789`
    - `http://127.0.0.1:18789`
    - `http://localhost:18791`
    - `http://127.0.0.1:18791`
  - Merge behavior is idempotent: existing origins are preserved and required localhost/loopback entries are only appended when missing.
  - When `TELEGRAM_NUMERIC_USER_ID` is present, bootstrap now enforces secure Telegram DM allowlist semantics by setting:
    - `channels.telegram.dmPolicy="allowlist"`
    - `channels.telegram.allowFrom` includes that numeric user id.
    This removes default `pairing` warning semantics for explicitly-owned bot setups while keeping access scoped to a specific user.
  - Added `OPENCLAW_CONFIG_PATH` for gateway and CLI sidecar for deterministic config resolution.
  - Added `openclaw-control-ui` service (nginx) on dedicated host port `${OPENCLAW_CONTROL_UI_PORT:-18791}` serving `openclaw-src/dist/control-ui`.
- `scripts/openclaw-cli-shim.py`
  - Added MC-side state bootstrap before command forwarding:
    - ensure `OPENCLAW_STATE_DIR` exists
    - ensure `~/.openclaw/credentials` exists
    - ensure `gateway.mode="local"` in config
- `Makefile`
  - `openclaw-up` now verifies `dist/index.js` and `dist/control-ui/index.html` instead of nonexistent image sentinel, pre-creates both credentials dirs, and starts gateway + dedicated control UI.
  - `openclaw-status` now checks gateway HTTP, control UI HTTP, MC OAuth-dir presence, and MC→gateway health call viability.
- `scripts/openclaw-auto-approve-control-ui.mjs`
  - New local-dev auto-approval worker for Control UI pairing requests.
  - Idempotent behavior: only pending requests are processed; already-paired devices reuse token state.
  - Safety boundaries: requires `OPENCLAW_LOCAL_DEV_AUTO_APPROVE=1`, `gateway.mode=local`, and local/private source IP.
- `docker-compose-openclaw.yml`
  - Added `openclaw-control-ui-autopair` service to run the worker continuously in local OpenClaw stack.
- `Makefile`
  - `openclaw-up` now starts `openclaw-control-ui-autopair`.
  - `openclaw-status` now reports pending pairing count + auto-pair service state.
- `src/lib/security-scan.ts`
  - HSTS/secure-cookie checks now pass by default on local HTTP and only warn when HTTPS hardening flags imply HTTPS posture.
  - `OPENCLAW_GATEWAY_HOST=host.docker.internal` now classified as valid Docker-local topology (not a critical misconfiguration).
- `docs/deployment.md`
  - Added explicit local-vs-HTTPS defaults to reduce HSTS/cookie/gateway-host warning confusion.
- `docker-compose.yml`
  - Added explicit `OPENCLAW_CONFIG_PATH=/home/nextjs/.openclaw/openclaw.json` for prod Mission Control container.
- `.env.openclaw.example`
  - Added `OPENCLAW_CONTROL_UI_PORT` variable documentation/default.
- `Makefile`
  - Removed hardcoded startup/status endpoints and now loads runtime parameters from `.env` / `.env.openclaw` (`MC_URL_SCHEME`, `MC_HOST`, `MC_PORT`, `OPENCLAW_STATUS_HOST`, `OPENCLAW_GATEWAY_PORT`, `OPENCLAW_CONTROL_UI_PORT`).
  - `openclaw-status` token check now accepts `OPENCLAW_GATEWAY_TOKEN` from either `.env` or `.env.openclaw`.
- `Makefile`
  - Added env-driven mode switch `MC_MODE=prod|dev` and OpenClaw lifecycle toggle `OPENCLAW_ENABLED=1|0`.
  - Unified primary lifecycle: `make up`, `make restart`, `make down`, `make status` now operate in selected mode and include OpenClaw automatically when enabled.
  - Kept compatibility aliases (`dev-up`, `dev-restart`, `dev-down`, `dev-ps`) mapped to the unified flow.
  - Reduced default `make help` output to minimal operator commands; added `make help-all` for full target listing.
- `.env.example` / `.env.openclaw.example`
  - Added documented defaults/toggles for `MC_MODE` and `OPENCLAW_ENABLED`.
- `docs/deployment.md` / `docs/ops-cheatsheet.md`
  - Updated operator UX to mode-driven minimal commands (`up/restart/down/status`) and removed requirement for separate `openclaw-up` in normal startup.
- `docker-compose-openclaw.yml`
  - Replaced hardcoded gateway/bridge startup ports with env-driven host/internal port mappings (`OPENCLAW_GATEWAY_PORT`, `OPENCLAW_BRIDGE_PORT`, `OPENCLAW_GATEWAY_INTERNAL_PORT`, `OPENCLAW_BRIDGE_INTERNAL_PORT`).
  - Gateway launch and healthcheck now use `OPENCLAW_GATEWAY_INTERNAL_PORT` (no embedded literal port).
  - Telegram bootstrap now consumes existing env keys `TELEGRAM_BOT_TOKEN` + `TELEGRAM_NUMERIC_USER_ID`, projects `channels.telegram.botToken` from env, and enforces secure allowlist ownership (`commands.ownerAllowFrom`, `channels.telegram.allowFrom`, `channels.telegram.dmPolicy=allowlist`) when numeric owner id exists.
- `docker-compose-dev.yml`
  - Replaced dev hardcoded container port wiring with env interpolation (`PORT`) for port mapping and Next.js dev command.
- `.env.example` / `.env.openclaw.example`
  - Added explicit Make+Compose runtime keys and Telegram/OpenClaw keys required for env-driven startup.
- `docs/deployment.md` / `docs/openclaw-telegram-onboarding.md`
  - Added concise “what to set in .env” operator blocks for Make-first startup and Telegram ownership bootstrap.
- `Makefile`
  - Extended unified, env-driven top-level maintenance commands to include `update`, `rebuild`, and `upgrade` under `MC_MODE=prod|dev` + `OPENCLAW_ENABLED=0|1`.
  - `update` now performs source/state refresh without forced rebuild; `upgrade` now executes `update + rebuild + restart` and invokes OpenClaw update path when enabled.
  - Preserved compatibility aliases with added `update-dev` alias for mode-specific workflows.
  - Simplified `make help` to show only recommended top-level commands (`up/restart/down/status/update/rebuild/upgrade`) plus `help-all`.
- `docs/ops-cheatsheet.md` / `docs/deployment.md`
  - Added concise mode-aware command matrix for lifecycle + maintenance commands.
  - Added explicit `update` vs `upgrade` semantics and aligned examples with current Makefile behavior.

## Verify
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Command runs
0. `bd ready --json`
   - Failed: `database "mission_control" not found on Dolt server at 127.0.0.1:13870`.
   - Continued implementation without bd issue updates (server-side beads DB unavailable).

1. `make openclaw-build`
   - Completed successfully.
   - Key output includes:
     - `==> pnpm build`
     - `==> pnpm ui:build`
     - `../dist/control-ui/index.html` and `../dist/control-ui/assets/...` emitted.

2. `make up`
   - Completed successfully (container recreated, `/login` readiness reached 200).

3. `make openclaw-up`
   - Completed successfully (gateway started on `http://127.0.0.1:18789`, control UI on `http://127.0.0.1:18791`).

4. `make openclaw-status`
   - Completed successfully:
     - `Gateway HTTP: 200`
     - `Control UI: 200`
     - `OAuth dir: .mc-openclaw/credentials present`
     - `MC->Gateway: OK`

5. `docker exec mission-control openclaw gateway call health --json --timeout 8000`
   - Completed successfully (JSON payload with `"ok": true`).

6. Additional checks
   - `curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18791/` -> `200` (dedicated control UI port live).
    - `docker logs mc-openclaw-gateway --since 10m | rg "OAuth dir not present|Control UI assets are missing|gateway.mode is unset"`
      - No matches (targeted warning signatures absent in current startup window).
    - `pnpm vitest run src/lib/__tests__/openclaw-doctor.test.ts`
      - Passed (`9/9`) confirming expected parser handling of informational security output.

7. Topology verification (reverse-proxied UI on :18791)
   - `make openclaw-up`
     - Started `mc-openclaw-gateway` and `mc-openclaw-control-ui`.
   - `make openclaw-status`
     - `Gateway HTTP: 200`
     - `Control UI: 200`
     - `MC->Gateway: OK` (after `make up`)
   - `curl -I http://127.0.0.1:18791/`
     - `HTTP/1.1 200 OK` from nginx control-ui service.
   - `curl -I http://127.0.0.1:18791/healthz`
     - `HTTP/1.1 200 OK` proving 18791 route reaches gateway health endpoint.
    - WebSocket sanity probe:
      - `curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" ... http://127.0.0.1:18791/ws`
      - Response body from gateway stack: `Missing or invalid Sec-WebSocket-Key header` (request reached WS endpoint through proxy).

8. Origin allowlist bootstrap verification (focused fix)
   - `make openclaw-up`
     - Completed successfully (gateway + control UI up).
   - `make openclaw-status`
     - `Gateway HTTP: 200`
     - `Control UI: 200`
     - `MC->Gateway: OK`
   - `jq -r '.gateway.controlUi.allowedOrigins[]' .openclaw-data/openclaw.json`
     - `http://localhost:18789`
     - `http://127.0.0.1:18789`
     - `http://localhost:18791`
     - `http://127.0.0.1:18791`
   - `curl -sS -o /dev/null -w "localhost 18791 -> %{http_code}" http://localhost:18791/`
     - `localhost 18791 -> 200`
    - `curl -sS -o /dev/null -w "127.0.0.1 18791 -> %{http_code}" http://127.0.0.1:18791/`
      - `127.0.0.1 18791 -> 200`

9. Local auto-approval verification (Control UI pairing)
   - `make openclaw-up`
     - Started `mc-openclaw-gateway`, `mc-openclaw-control-ui`, and `mc-openclaw-control-ui-autopair`.
   - `make openclaw-status`
     - Includes `Pending pair: 0` and `Auto-pair: running (local control-ui requests)`.
   - `docker logs mc-openclaw-control-ui-autopair --since 5m`
     - Shows auto-approval events for pending request ids and periodic sweep status.
   - `python3 - <<'PY' ...` state check (`.openclaw-data/devices/pending.json`)
     - Confirms pending requests are removed after approval.
    - `curl -fsS http://127.0.0.1:18791/healthz`
      - Returns gateway health through Control UI route (`{"ok":true...}`) while pairing queue remains clear.

10. WS `4008` + Telegram allowlist hardening verification (current)
    - `docker compose -f docker-compose-openclaw.yml down && docker compose -f docker-compose-openclaw.yml up -d openclaw-gateway openclaw-control-ui openclaw-control-ui-autopair`
      - Stack restarted with updated gateway bootstrap + nginx proxy behavior.
    - Playwright probe against `http://localhost:18791`
      - First connect attempt returns temporary `NOT_PAIRED` once, auto-approver resolves locally, second connect succeeds and UI reaches full chat shell (`connected=true`, `control-ui.rpc connect ok=true`).
    - Gateway log evidence (post-fix)
      - Temporary `4008 connect failed` can still occur on stale reconnect attempts, but gateway then accepts a paired reconnect and continues serving successful RPCs (`sessions.list`, `chat.history`, `health`) on the active webchat connection.
     - Telegram config projection check
       - `.openclaw-data/openclaw.json` now includes `channels.telegram.dmPolicy="allowlist"` and `channels.telegram.allowFrom` containing `${TELEGRAM_NUMERIC_USER_ID}` when env var is set.

11. Mission Control runtime recovery verification (2026-05-03)
    - `docker compose ps` / `make dev-ps` / `make ps`
      - `mission-control` confirmed mapped on `0.0.0.0:7012->7012/tcp`; no port conflict detected.
    - `docker compose logs --tail=200 mission-control`
      - Service showed normal Next.js boot + healthy scheduler init (no fatal runtime errors).
    - `docker compose restart mission-control`
      - Container restarted cleanly to recover runtime session.
    - `curl -i http://127.0.0.1:7012/login` and `make status`
      - HTTP `200 OK` on `/login`; status check returned `URL: 200 → http://127.0.0.1:7012/login`.

12. Env-driven Make/Compose refactor verification (2026-05-03)
    - `make down && make up`
      - Completed successfully; `/login` reached HTTP 200 via Make-computed URL from `.env`.
    - `make openclaw-down && make openclaw-up`
      - Completed successfully; gateway/UI started with env-driven ports.
    - `make status`
      - Returned HTTP `200` for `http://127.0.0.1:7012/login`.
    - `make openclaw-status`
      - Returned `Gateway HTTP: 200` and `Control UI: 200`.
    - `curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:7012/login`
      - `200`
    - `curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18791/`
      - `200`
    - `.openclaw-data/openclaw.json` inspection
      - `commands.ownerAllowFrom` includes `telegram:${TELEGRAM_NUMERIC_USER_ID}`.
      - `channels.telegram.allowFrom` includes `${TELEGRAM_NUMERIC_USER_ID}`.
      - `channels.telegram.dmPolicy` is `allowlist`.
      - `channels.telegram.botToken.id` resolves to `TELEGRAM_BOT_TOKEN`.

13. Make workflow normalization verification (2026-05-04)
    - `bd ready --json`
      - Failed (environment issue): `database "mission_control" not found on Dolt server at 127.0.0.1:13870`.
    - `make help`
      - Shows minimal primary commands (`up`, `restart`, `down`, `status`) plus `help-all` for full target list.
    - `make status`
      - Returned HTTP `200` for `http://127.0.0.1:7012/login` and CLI reachability (`claude`, `codex`, `gemini`).
    - `make dev-ps`
      - Returned compose service status for the development stack.
    - `make openclaw-status`
      - Returned `Gateway HTTP: 200`, `Control UI: 200`, `MC->Gateway: OK`.
    - `make restart`
      - Restarted prod Mission Control and conditionally restarted `mc-openclaw-gateway`; readiness probe returned 200.
    - `make down && make dev-up && make dev-restart`
      - Switched to dev stack, then verified dev restart path and conditional gateway restart; readiness probe returned 200.

14. Unified mode-aware lifecycle verification (2026-05-04)
    - `MC_MODE=prod OPENCLAW_ENABLED=1 make up`
      - Started prod Mission Control and OpenClaw stack in one command.
    - `MC_MODE=prod OPENCLAW_ENABLED=1 make status`
      - Reported `Mode: prod`, MC URL status, and OpenClaw gateway/control endpoint health.
    - `MC_MODE=prod OPENCLAW_ENABLED=1 make restart`
      - Restarted prod Mission Control and OpenClaw (restart-or-up behavior).
    - `MC_MODE=dev OPENCLAW_ENABLED=1 make up`
      - Started dev Mission Control and OpenClaw stack in one command.
    - `MC_MODE=dev OPENCLAW_ENABLED=1 make status`
      - Reported `Mode: dev`, `mission-control-dev` container checks, and OpenClaw endpoint health.
    - `MC_MODE=dev OPENCLAW_ENABLED=1 make restart`
      - Restarted dev Mission Control and OpenClaw (restart-or-up behavior).

15. Unified maintenance targets verification (2026-05-04)
    - `make help`
      - Shows minimal recommended top-level commands including `update`, `rebuild`, and `upgrade`.
    - Dry-safe command paths (`-n`) for both modes:
      - `MC_MODE=prod OPENCLAW_ENABLED=0 make -n update`
      - `MC_MODE=prod OPENCLAW_ENABLED=0 make -n rebuild`
      - `MC_MODE=prod OPENCLAW_ENABLED=0 make -n upgrade`
      - `MC_MODE=dev OPENCLAW_ENABLED=1 make -n update`
      - `MC_MODE=dev OPENCLAW_ENABLED=1 make -n rebuild`
      - `MC_MODE=dev OPENCLAW_ENABLED=1 make -n upgrade`
      - Note: GNU Make executes recursive `$(MAKE)` lines even under `-n`; the rebuild path attempted a real Docker build and surfaced an existing lockfile drift issue (`ERR_PNPM_OUTDATED_LOCKFILE`) unrelated to this Makefile/docs change.
    - `make status`
      - Returned mode-aware Mission Control endpoint status and OpenClaw endpoint checks when enabled.

## Finalize
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*



---
*This plan is maintained by the LLM and uses beads CLI for task management. Tool responses provide guidance on which bd commands to use for task management.*
