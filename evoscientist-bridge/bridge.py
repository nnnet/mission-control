"""evoscientist-bridge — Mission Control ⇄ EvoScientist task adapter.

Lifecycle:
    1. On boot, register as Mission Control agent(s) via POST /api/agents/register.
       By default registers `evoscientist-orchestrator`. If
       EVOSCIENTIST_SUBAGENTS is set (comma-separated), also registers
       one MC agent per sub-agent name.
    2. Loops every POLL_INTERVAL_SECONDS asking MC for tasks assigned to
       any of the registered names (`/api/tasks/queue?agent=<name>`).
    3. For each pulled task:
        a. If MODE=stub      → return canned text (used for plumbing
                                tests before EvoScientist is wired up).
        b. If MODE=openai    → call OpenAI directly with the chosen model
                                (bypasses EvoScientist; cheap smoke test).
        c. If MODE=evoscientist → `docker exec evoscientist python -m
                                EvoScientist …` and capture stdout.
       Then PATCH/POST the result back to MC so the Kanban card moves
       to Done.
    4. Exposes a tiny FastAPI for /healthz + manual triggering.

Why a sidecar instead of editing MC: MC's task-dispatch.ts already
supports an external-agent flow via /api/agents/register + /api/tasks/queue.
Wrapping EvoScientist as an external agent keeps both codebases unmodified
(EvoScientist is a third-party Python package; Mission Control is a fork
with vendored treatment of agent code).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import sys
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI

LOG = logging.getLogger("evoscientist-bridge")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)


def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


# ---- Configuration ---------------------------------------------------------

MC_URL = env("MC_URL", "http://host.docker.internal:7012")
MC_API_KEY = env("MC_API_KEY")  # used as Bearer for admin-scoped MC routes
EVOSCIENTIST_CONTAINER = env("EVOSCIENTIST_CONTAINER", "evoscientist")
EVOSCIENTIST_PRIMARY_MODEL = env("EVOSCIENTIST_PRIMARY_MODEL", "gpt-5-nano")
EVOSCIENTIST_FALLBACK_MODEL = env("EVOSCIENTIST_FALLBACK_MODEL", "gpt-4o-mini")
OPENAI_API_KEY = env("OPENAI_API_KEY")

POLL_INTERVAL_SECONDS = int(env("POLL_INTERVAL_SECONDS", "5"))
TASK_TIMEOUT_SECONDS = int(env("TASK_TIMEOUT_SECONDS", "600"))

# stub | openai | evoscientist  (default openai while EvoScientist
# subprocess interface is still being shaped — see B5 of the plan)
MODE = env("MODE", "openai").lower()

ORCHESTRATOR_AGENT_NAME = env("ORCHESTRATOR_AGENT_NAME", "evoscientist-orchestrator")
SUBAGENT_NAMES = [
    name.strip()
    for name in env("EVOSCIENTIST_SUBAGENTS", "").split(",")
    if name.strip()
]
ALL_AGENT_NAMES = [ORCHESTRATOR_AGENT_NAME, *SUBAGENT_NAMES]


# ---- MC API helpers --------------------------------------------------------


def mc_headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if MC_API_KEY:
        headers["Authorization"] = f"Bearer {MC_API_KEY}"
    return headers


async def mc_register_agent(client: httpx.AsyncClient, name: str, role: str = "researcher") -> bool:
    body = {
        "name": name,
        "role": role,
        "framework": "EvoScientist",
        "capabilities": ["research", "literature-review", "summarisation"],
    }
    try:
        r = await client.post(
            f"{MC_URL}/api/agents/register",
            headers=mc_headers(),
            json=body,
            timeout=10,
        )
        if r.status_code in (200, 201):
            LOG.info("registered MC agent %r → %s", name, r.json().get("agent", {}).get("id"))
            return True
        LOG.warning("register %r failed: %s %s", name, r.status_code, r.text[:200])
    except Exception as exc:  # network, etc.
        LOG.error("register %r exception: %s", name, exc)
    return False


async def mc_pull_queued(client: httpx.AsyncClient, agent_name: str) -> list[dict[str, Any]]:
    """Pull pending tasks assigned to `agent_name`. Tolerant to schema —
    we look for an `items`/`tasks` array in the response."""
    try:
        r = await client.get(
            f"{MC_URL}/api/tasks/queue",
            headers=mc_headers(),
            params={"agent": agent_name},
            timeout=10,
        )
        if r.status_code != 200:
            LOG.debug("queue fetch %s -> %s", agent_name, r.status_code)
            return []
        data = r.json()
        for key in ("items", "tasks", "queue", "results"):
            if isinstance(data.get(key), list):
                return data[key]
        if isinstance(data, list):
            return data
    except Exception as exc:
        LOG.debug("queue fetch exception: %s", exc)
    return []


async def mc_complete_task(client: httpx.AsyncClient, task_id: int | str, result_text: str) -> bool:
    """Post the agent's answer back to MC. We try the most common shapes
    of MC's task-update routes and stop on the first success."""
    payloads = [
        {"resolution": result_text, "status": "done"},
        {"result": result_text, "status": "done"},
        {"answer": result_text, "status": "done"},
    ]
    for payload in payloads:
        for method in ("PATCH", "POST"):
            try:
                r = await client.request(
                    method,
                    f"{MC_URL}/api/tasks/{task_id}",
                    headers=mc_headers(),
                    json=payload,
                    timeout=15,
                )
                if r.status_code in (200, 201, 204):
                    LOG.info("task %s posted result via %s", task_id, method)
                    return True
            except Exception as exc:
                LOG.debug("complete %s %s exception: %s", method, task_id, exc)
    LOG.warning("could not post completion for task %s — check MC API contract", task_id)
    return False


# ---- Backends --------------------------------------------------------------


async def run_stub(prompt: str) -> str:
    return f"[evoscientist-bridge stub] received prompt of {len(prompt)} chars; returning canned reply for plumbing test."


async def run_openai(prompt: str) -> str:
    if not OPENAI_API_KEY:
        return "[error] OPENAI_API_KEY not set in evoscientist-bridge environment."
    async with httpx.AsyncClient(timeout=60) as client:
        r = await client.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": EVOSCIENTIST_PRIMARY_MODEL,
                "messages": [
                    {
                        "role": "system",
                        "content": "You are EvoScientist (proxy). Answer concisely.",
                    },
                    {"role": "user", "content": prompt},
                ],
                # gpt-5* family rejects `max_tokens`; both gpt-5-nano and
                # gpt-4o-mini accept `max_completion_tokens`.
                "max_completion_tokens": 1024,
            },
        )
        if r.status_code != 200:
            return f"[openai error {r.status_code}] {r.text[:300]}"
        return r.json()["choices"][0]["message"]["content"]


def run_evoscientist_blocking(prompt: str) -> str:
    """Drive the EvoScientist sidecar via `docker exec`. Returns last
    non-empty line of stdout as the answer (EvoScientist's CLI prints
    intermediate think-blocks; the final answer is the last paragraph)."""
    cmd = [
        "docker",
        "exec",
        "-i",
        EVOSCIENTIST_CONTAINER,
        "python",
        "-m",
        "EvoScientist",
        "--prompt",
        prompt,
        "--model",
        EVOSCIENTIST_PRIMARY_MODEL,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TASK_TIMEOUT_SECONDS,
            check=False,
        )
        if proc.returncode != 0:
            return (
                f"[evoscientist exit {proc.returncode}] "
                f"{(proc.stderr or proc.stdout)[:600]}"
            )
        non_empty = [
            line.strip() for line in proc.stdout.splitlines() if line.strip()
        ]
        return non_empty[-1] if non_empty else "[evoscientist] empty output"
    except subprocess.TimeoutExpired:
        return f"[evoscientist timeout after {TASK_TIMEOUT_SECONDS}s]"
    except FileNotFoundError:
        return "[evoscientist] docker CLI missing in bridge container"


async def run_evoscientist(prompt: str) -> str:
    return await asyncio.to_thread(run_evoscientist_blocking, prompt)


BACKENDS = {
    "stub": run_stub,
    "openai": run_openai,
    "evoscientist": run_evoscientist,
}


async def execute_task(task: dict[str, Any]) -> str:
    prompt = (
        task.get("prompt")
        or task.get("description")
        or task.get("title")
        or json.dumps(task, ensure_ascii=False)[:1000]
    )
    backend = BACKENDS.get(MODE, run_openai)
    LOG.info("executing task id=%s via mode=%s prompt[0:80]=%r",
             task.get("id"), MODE, prompt[:80])
    return await backend(prompt)


# ---- Polling loop ----------------------------------------------------------


async def poll_loop() -> None:
    async with httpx.AsyncClient() as client:
        for name in ALL_AGENT_NAMES:
            await mc_register_agent(client, name)

        while True:
            for name in ALL_AGENT_NAMES:
                tasks = await mc_pull_queued(client, name)
                for task in tasks:
                    task_id = task.get("id") or task.get("task_id")
                    if task_id is None:
                        continue
                    try:
                        result = await execute_task(task)
                    except Exception as exc:  # never crash the loop
                        result = f"[bridge exception] {exc}"
                        LOG.exception("task %s failed", task_id)
                    await mc_complete_task(client, task_id, result)
            await asyncio.sleep(POLL_INTERVAL_SECONDS)


# ---- FastAPI app -----------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(poll_loop())
    LOG.info(
        "evoscientist-bridge up: MC=%s mode=%s agents=%s primary=%s",
        MC_URL, MODE, ALL_AGENT_NAMES, EVOSCIENTIST_PRIMARY_MODEL,
    )
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="evoscientist-bridge", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    return {
        "ok": True,
        "mode": MODE,
        "mc_url": MC_URL,
        "agents": ALL_AGENT_NAMES,
        "primary_model": EVOSCIENTIST_PRIMARY_MODEL,
    }


@app.post("/run")
async def run(payload: dict[str, Any]) -> dict[str, Any]:
    """Manual smoke-test endpoint — bypass MC, run a prompt directly."""
    return {"result": await execute_task(payload)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("bridge:app", host="0.0.0.0", port=7920, log_level="info")
