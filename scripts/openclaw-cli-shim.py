#!/usr/bin/env python3
"""
openclaw CLI shim — additive compatibility layer.

Why:
    Mission Control's source uses an older openclaw CLI shape that the daemon
    has since retired:

        runOpenClaw(['gateway', 'sessions_send', '--session', X, '--message', Y])
        # -> openclaw gateway sessions_send --session X --message Y

    In openclaw 2026.4.x, `sessions_send` is no longer a `gateway`
    subcommand. It exists only as an RPC method behind the generic call
    surface:

        openclaw gateway call sessions_send --params '{"sessionKey":"X","message":"Y"}' --json

    The Linter agent "Failed to wake agent" error in /agents and the
    Orchestration → Command tab Send button both fail because MC keeps
    invoking the retired shape.

    Rather than patch MC source (the operator wants MC unmodified), this
    shim sits at /usr/local/bin/openclaw, recognizes the legacy shape,
    rewrites it into the modern RPC call shape, and forwards to the real
    openclaw CLI.

What gets rewritten:
    legacy: gateway sessions_send --session X --message Y [--json]
    modern: gateway call sessions_send --params {"sessionKey":"X","message":"Y"} --json

    legacy: gateway sessions_history --session X
    modern: gateway call sessions_history --params {"sessionKey":"X"} --json

    legacy: gateway sessions_list
    modern: gateway call sessions_list --params {} --json

Pass-through:
    Anything that doesn't match a known legacy shape is forwarded as-is to
    `node /opt/openclaw-src/dist/index.js`.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import List, Optional

OPENCLAW_DIST = "/opt/openclaw-src/dist/index.js"


def resolve_openclaw_paths() -> tuple[Path, Path, Path]:
    state_dir = Path(os.environ.get("OPENCLAW_STATE_DIR", str(Path.home() / ".openclaw"))).expanduser()
    config_path = Path(os.environ.get("OPENCLAW_CONFIG_PATH", str(state_dir / "openclaw.json"))).expanduser()
    credentials_dir = state_dir / "credentials"
    return state_dir, config_path, credentials_dir


def ensure_openclaw_state_defaults() -> None:
    state_dir, config_path, credentials_dir = resolve_openclaw_paths()
    state_dir.mkdir(parents=True, exist_ok=True)
    credentials_dir.mkdir(parents=True, exist_ok=True)

    config: dict = {}
    if config_path.exists():
        try:
            loaded = json.loads(config_path.read_text())
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Invalid OpenClaw config JSON at {config_path}: {exc}") from exc
        if isinstance(loaded, dict):
            config = loaded

    gateway = config.get("gateway")
    if not isinstance(gateway, dict):
        gateway = {}
        config["gateway"] = gateway

    if gateway.get("mode") != "local":
        gateway["mode"] = "local"

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


def find_flag_value(args: List[str], flag: str) -> Optional[str]:
    """Return the value following `flag` in args, or None if absent."""
    try:
        idx = args.index(flag)
    except ValueError:
        return None
    if idx + 1 >= len(args):
        return None
    return args[idx + 1]


def has_flag(args: List[str], flag: str) -> bool:
    return flag in args


def remaining_flags(args: List[str], known: List[str]) -> List[str]:
    """Return flags from `args` not in `known` (for pass-through)."""
    out: List[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in known:
            # skip flag and its value
            i += 2
            continue
        out.append(a)
        i += 1
    return out


def rewrite_sessions_send(rest: List[str]) -> List[str]:
    """gateway sessions_send --session X --message Y [--json] [--timeout ms]
    -> gateway call chat.send --params '{...}' --json [--timeout ms]

    The retired `sessions_send` RPC is now `chat.send`, which requires an
    `idempotencyKey` and a `deliver` flag in addition to `sessionKey` and
    `message`. We mint a deterministic-but-unique idempotencyKey based on
    pid+time so a re-issued wake-up is distinct from a duplicate.
    """
    import time
    session = find_flag_value(rest, "--session") or ""
    message = find_flag_value(rest, "--message") or ""
    timeout = find_flag_value(rest, "--timeout")

    idempotency = f"mc-shim-{os.getpid()}-{int(time.time() * 1000)}"
    params = json.dumps(
        {
            "sessionKey": session,
            "message": message,
            "idempotencyKey": idempotency,
            "deliver": False,
        }
    )
    out = ["gateway", "call", "chat.send", "--params", params, "--json"]
    if timeout:
        out.extend(["--timeout", timeout])
    return out


def rewrite_sessions_history(rest: List[str]) -> List[str]:
    """gateway sessions_history --session X
    -> gateway call sessions.history --params '{"key":"X"}' --json
    """
    session = find_flag_value(rest, "--session") or ""
    timeout = find_flag_value(rest, "--timeout")
    params = json.dumps({"key": session})
    out = ["gateway", "call", "sessions.history", "--params", params, "--json"]
    if timeout:
        out.extend(["--timeout", timeout])
    return out


def rewrite_sessions_list(rest: List[str]) -> List[str]:
    """gateway sessions_list -> gateway call sessions.list --params '{}' --json"""
    timeout = find_flag_value(rest, "--timeout")
    out = ["gateway", "call", "sessions.list", "--params", "{}", "--json"]
    if timeout:
        out.extend(["--timeout", timeout])
    return out


# Legacy shape: openclaw gateway <method> [flags]
# where <method> is one of these RPC names that used to be subcommands.
LEGACY_GATEWAY_METHODS = {
    "sessions_send": rewrite_sessions_send,
    "sessions_history": rewrite_sessions_history,
    "sessions_list": rewrite_sessions_list,
}


def rewrite(args: List[str]) -> List[str]:
    """Inspect args and rewrite legacy shapes. Return the args to forward."""
    if len(args) >= 2 and args[0] == "gateway" and args[1] in LEGACY_GATEWAY_METHODS:
        rewriter = LEGACY_GATEWAY_METHODS[args[1]]
        new_tail = rewriter(args[2:])
        return new_tail
    return args


def main() -> int:
    ensure_openclaw_state_defaults()
    raw = sys.argv[1:]
    rewritten = rewrite(raw)
    if rewritten is not raw and os.environ.get("OPENCLAW_SHIM_DEBUG"):
        print(f"[openclaw-shim] {' '.join(raw)}", file=sys.stderr)
        print(f"[openclaw-shim] -> {' '.join(rewritten)}", file=sys.stderr)
    os.execvp("node", ["node", OPENCLAW_DIST, *rewritten])


if __name__ == "__main__":
    sys.exit(main())
