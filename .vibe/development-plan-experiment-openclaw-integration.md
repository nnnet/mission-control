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

## Notes
*Additional context and observations*
- bd database unavailable: `bd ready` fails (Dolt server says database "mission_control" not found on 127.0.0.1:13870). Need bd/Dolt server fix before creating Reproduce tasks.
- Reproduce run (Docker dev): `make dev` started MC at http://127.0.0.1:7012/login (200). `make openclaw-up` started gateway on 18789 (healthy).
- `make openclaw-pair-mc` initial verify failed (GatewayTransportError: ws closed 1006 to ws://host.docker.internal:18789). After ~30s, retry succeeded (`{"ok": true ...}`) and pairing already present (idempotent). Agents update count 0.
- `make status` failed because it expects container `mission-control` (prod); dev stack uses `mission-control-dev`. Use `make dev-ps` + `make openclaw-ps` for dev status.
- Prod container starts successfully but `make up` can fail `wait-ready` (30s) even when Next.js is ready; logs show server ready and migrations applied.
- OpenClaw gateway logs show `gateway.auth.token` surface inactive warning even with token env var configured.
- `bd doctor --fix` requires `--yes` for non-interactive; database still not reachable (dolt server missing `mission_control` db on 127.0.0.1:13870), so bd tasks cannot be created yet.
- Gateway container has `/home/node/.openclaw/canvas/index.html` but no `/home/node/.openclaw/control-ui` directory (likely source of “Control UI assets are missing” warning).

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

## Fix
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Applied changes
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

## Verify
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*

### Command runs
1. `make openclaw-build`
   - Completed successfully.
   - Key output includes:
     - `==> pnpm build`
     - `==> pnpm ui:build`
     - `../dist/control-ui/index.html` and `../dist/control-ui/assets/...` emitted.

2. `make up`
   - Completed successfully (container recreated, `/login` readiness reached 200).

3. `make openclaw-up`
   - Completed successfully (gateway started on `http://127.0.0.1:18789`).

4. `docker exec mission-control openclaw gateway call health --json --timeout 8000`
   - Completed successfully (JSON payload with `"ok": true`).

5. Additional checks
   - `docker exec mission-control sh -c 'which openclaw && ls -l /home/nextjs/.local/bin/openclaw'`
     - Output confirms path and executable mode:
       - `/home/nextjs/.local/bin/openclaw`
       - `-rwxrwxr-x ... /home/nextjs/.local/bin/openclaw`
   - `make openclaw-status` -> `Gateway HTTP: 200`, config present, token set.
   - `docker logs mc-openclaw-gateway --tail 200`
     - No `Control UI assets are missing` warning observed after build update.
     - No `OAuth dir not present` warning observed after credential-dir bootstrap.

## Finalize
<!-- beads-phase-id: TBD -->
### Tasks

*Tasks managed via `bd` CLI*



---
*This plan is maintained by the LLM and uses beads CLI for task management. Tool responses provide guidance on which bd commands to use for task management.*
