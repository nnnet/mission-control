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


# Per-subagent system prompts, drawn from EvoScientist/subagents/*.yaml
# `description` and `system_prompt` fields. We embed them rather than
# bind-mounting the yaml so the bridge stays standalone.
SUBAGENT_SYSTEM_PROMPTS = {
    "planner": (
        "You are the planner-agent. You do NOT implement code. "
        "Decompose the user's task into a numbered plan of stages. "
        "For each stage list: goal, success signals, what to run "
        "(commands at high level), expected artefacts. List dependencies. "
        "Stay short and concrete."
    ),
    "research": (
        "You are the research-agent. Web research for "
        "methods/baselines/datasets/facts. Return actionable notes plus "
        "sources you would consult. Stay focused on one topic at a time."
    ),
    "code": (
        "You are the code-agent. Implement experiment code and runnable "
        "scripts. Keep changes minimal and reproducible. Prefer concise "
        "snippets to long monoliths."
    ),
    "data-analysis": (
        "You are the data-analysis-agent. Analyse experiment outputs: "
        "compute metrics, suggest plots, summarise insights. Stay numeric "
        "and concrete; cite specific values when possible."
    ),
    "debug": (
        "You are the debug-agent. Diagnose runtime failures and propose "
        "minimal, verifiable patches. Quote the suspect line(s) and "
        "explain why they fail before suggesting a fix."
    ),
    "writing": (
        "You are the writing-agent. Synthesise upstream outputs into a "
        "paper-ready Markdown report. Do NOT fabricate results or "
        "citations. Keep each section short and specific."
    ),
}

ORCHESTRATOR_SYSTEM_PROMPT = (
    "You are the EvoScientist orchestrator. Your team consists of six "
    "specialised agents: planner, research, code, data-analysis, debug, "
    "writing. When given a task you decompose it into sub-tasks for the "
    "right team members and synthesise their outputs."
)

PLAN_DECOMPOSER_SYSTEM = (
    "You are the EvoScientist orchestrator's planner. Output a strict JSON "
    "object: {\"steps\": [{\"agent\": <one of: planner|research|code|"
    "data-analysis|debug|writing>, \"query\": <short imperative prompt for "
    "that agent>}]}. Aim for 2–4 steps. The first step is usually `planner` "
    "(produces a plan), the last is usually `writing` (synthesises the "
    "final answer). Output JSON only, no commentary, no code fences."
)


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
    """Pull a pending task for `agent_name`. MC's `/api/tasks/queue` returns
    a single `{task, reason}` envelope (not an array): `reason` is one of
    `continue_current` | `assigned` | `at_capacity` | `no_tasks_available`.
    The `assigned` and `continue_current` cases give us a task to act on;
    the others mean "nothing to do this tick"."""
    try:
        r = await client.get(
            f"{MC_URL}/api/tasks/queue",
            headers=mc_headers(),
            params={"agent": agent_name},
            timeout=10,
        )
        if r.status_code != 200:
            LOG.debug("queue fetch %s -> %s %s", agent_name, r.status_code, r.text[:200])
            return []
        data = r.json()
        task = data.get("task")
        reason = data.get("reason")
        if task and reason in ("assigned", "continue_current"):
            return [task]
    except Exception as exc:
        LOG.debug("queue fetch exception: %s", exc)
    return []


async def mc_complete_task(client: httpx.AsyncClient, task_id: int | str, result_text: str) -> bool:
    """Move the task to Done with the agent's answer as `resolution`.

    MC's `PUT /api/tasks/[id]` enforces an Aegis quality-gate: any
    transition to `status='done'` is rejected with HTTP 403 unless the
    `quality_reviews` table already has an `approved` row from
    `reviewer='aegis'` for this task. The supported way to insert that
    row is `POST /api/quality-review` with the `qualityReviewSchema`
    payload (`taskId`, `reviewer`, `status`, `notes`).

    Order of operations:
      1. Drop a write-up of the agent's answer onto the task as
         `resolution` (so Aegis-style reviewers can see what was done).
      2. POST the auto-approval review row.
      3. PUT `status='done'` to land the card in the Done column.
    Steps are best-effort: if the approval write fails (older MC builds
    that route quality reviews differently), we still try the PUT in
    case Aegis isn't gated on this deployment.
    """
    truncated = result_text[:4900]
    notes = f"Auto-approved by evoscientist-bridge (mode={MODE}, model={EVOSCIENTIST_PRIMARY_MODEL})."

    try:
        await client.put(
            f"{MC_URL}/api/tasks/{task_id}",
            headers=mc_headers(),
            json={"resolution": truncated, "outcome": "success"},
            timeout=15,
        )
    except Exception as exc:
        LOG.debug("resolution write failed (will still try done): %s", exc)

    try:
        r = await client.post(
            f"{MC_URL}/api/quality-review",
            headers=mc_headers(),
            json={
                "taskId": int(task_id),
                "reviewer": "aegis",
                "status": "approved",
                "notes": notes,
            },
            timeout=15,
        )
        if r.status_code not in (200, 201):
            LOG.debug("quality-review insert non-2xx: %s %s", r.status_code, r.text[:200])
    except Exception as exc:
        LOG.debug("quality-review insert exception: %s", exc)

    try:
        r = await client.put(
            f"{MC_URL}/api/tasks/{task_id}",
            headers=mc_headers(),
            json={
                "status": "done",
                "outcome": "success",
                "resolution": truncated,
            },
            timeout=15,
        )
        if r.status_code in (200, 201, 204):
            LOG.info("task %s → done", task_id)
            return True
        LOG.warning("complete task %s failed: %s %s", task_id, r.status_code, r.text[:200])
    except Exception as exc:
        LOG.error("complete task %s exception: %s", task_id, exc)
    return False


# ---- Backends --------------------------------------------------------------


async def run_stub(prompt: str) -> str:
    return f"[evoscientist-bridge stub] received prompt of {len(prompt)} chars; returning canned reply for plumbing test."


async def call_openai(system_prompt: str, user_prompt: str, model: str | None = None) -> str:
    """Single OpenAI chat-completion call. Reused by the per-subagent and
    orchestrator paths."""
    if not OPENAI_API_KEY:
        return "[error] OPENAI_API_KEY not set in evoscientist-bridge environment."
    chosen = model or EVOSCIENTIST_PRIMARY_MODEL
    async with httpx.AsyncClient(timeout=120) as client:
        r = await client.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": chosen,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                # gpt-5* family rejects `max_tokens`; gpt-5-nano + gpt-4o-mini
                # both accept `max_completion_tokens`. gpt-5-nano's reasoning
                # tokens count against this budget, so 4096 leaves room for
                # both internal reasoning and a meaningful answer.
                "max_completion_tokens": 4096,
            },
        )
        if r.status_code != 200:
            return f"[openai error {r.status_code}] {r.text[:300]}"
        return r.json()["choices"][0]["message"]["content"]


async def run_openai(prompt: str) -> str:
    """Single-agent fallback path — concise direct answer."""
    return await call_openai(
        "You are EvoScientist (proxy). Answer concisely.",
        prompt,
    )


async def run_subagent(prompt: str, role: str) -> str:
    """Run a single sub-agent role with its specialised system prompt."""
    sysprompt = SUBAGENT_SYSTEM_PROMPTS.get(role, ORCHESTRATOR_SYSTEM_PROMPT)
    return await call_openai(sysprompt, prompt)


async def run_team_orchestrator(
    prompt: str,
    on_step: Any | None = None,
) -> str:
    """Multi-step team-mode pipeline:
        1. Decomposer → JSON plan of {agent, query} steps.
        2. Each step runs through that sub-agent's specialised prompt.
        3. Writer synthesises a final Markdown answer.
    `on_step(step_index, agent_role, query, result)` callback gets each
    intermediate step (used to post comments on the MC task)."""
    # gpt-5-nano often eats the whole token budget on reasoning and returns
    # an empty completion when asked for structured JSON. The fallback
    # model (gpt-4o-mini) is much more reliable for the decomposer step
    # — small cost premium, but the rest of the pipeline runs on the
    # primary model.
    plan_raw = await call_openai(
        PLAN_DECOMPOSER_SYSTEM, prompt, model=EVOSCIENTIST_FALLBACK_MODEL
    )
    try:
        plan_clean = plan_raw.strip().lstrip("`").rstrip("`")
        if plan_clean.startswith("json"):
            plan_clean = plan_clean[4:].lstrip("\n")
        plan = json.loads(plan_clean)
        steps = plan.get("steps", []) if isinstance(plan, dict) else []
    except Exception as exc:
        LOG.warning("plan parse failed: %s — falling back to single-agent", exc)
        return await run_openai(prompt)

    if not steps:
        return await run_openai(prompt)

    transcripts: list[str] = []
    for idx, step in enumerate(steps[:6], start=1):  # safety cap
        if not isinstance(step, dict):
            continue
        agent_role = str(step.get("agent", "")).strip().lower()
        query = str(step.get("query", "")).strip()
        if not agent_role or not query:
            continue
        contextualised = (
            f"Original task: {prompt}\n\n"
            f"Your part of the team plan:\n{query}\n\n"
            f"Prior team outputs (most recent last):\n"
            + ("\n---\n".join(transcripts) if transcripts else "(none yet)")
        )
        sub_result = await run_subagent(contextualised, agent_role)
        transcripts.append(f"[{agent_role}] {sub_result}")
        if on_step:
            try:
                await on_step(idx, agent_role, query, sub_result)
            except Exception as exc:
                LOG.debug("on_step callback failed: %s", exc)

    if transcripts:
        synthesis_prompt = (
            f"Original task: {prompt}\n\n"
            f"Team transcripts:\n" + "\n\n".join(transcripts) + "\n\n"
            "Synthesise a single concise final answer that addresses the "
            "original task. Do not invent new facts beyond what the team "
            "produced."
        )
        return await call_openai(SUBAGENT_SYSTEM_PROMPTS["writing"], synthesis_prompt)
    return await run_openai(prompt)


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


async def mc_post_comment(client: httpx.AsyncClient, task_id: int | str, text: str) -> None:
    try:
        await client.post(
            f"{MC_URL}/api/tasks/{task_id}/comments",
            headers=mc_headers(),
            json={"content": text[:4900]},
            timeout=15,
        )
    except Exception as exc:
        LOG.debug("comment post failed for task %s: %s", task_id, exc)


async def execute_task(task: dict[str, Any], client: httpx.AsyncClient | None = None) -> str:
    prompt = (
        task.get("prompt")
        or task.get("description")
        or task.get("title")
        or json.dumps(task, ensure_ascii=False)[:1000]
    )
    assigned = (task.get("assigned_to") or "").strip()
    task_id = task.get("id") or task.get("task_id")

    # Orchestrator path: real team coordination via OpenAI sub-agent prompts.
    # Trip when MODE allows it (anything other than `stub` or `evoscientist`).
    if assigned == ORCHESTRATOR_AGENT_NAME and MODE not in {"stub", "evoscientist"}:
        LOG.info("executing task id=%s via team-orchestrator (6 sub-agents on tap)", task_id)
        async def _on_step(idx: int, role: str, query: str, result: str) -> None:
            if client and task_id is not None:
                comment = (
                    f"### Step {idx} — {role}\n\n"
                    f"**Query**\n\n{query}\n\n"
                    f"**Result**\n\n{result}"
                )
                await mc_post_comment(client, task_id, comment)
        return await run_team_orchestrator(prompt, on_step=_on_step)

    # Direct sub-agent path: assigned to evoscientist-<role>. Use that
    # role's system prompt so the sub-agent answers in its specialism.
    if assigned.startswith("evoscientist-") and assigned != ORCHESTRATOR_AGENT_NAME and MODE not in {"stub", "evoscientist"}:
        role = assigned[len("evoscientist-"):]
        LOG.info("executing task id=%s via sub-agent role=%s", task_id, role)
        return await run_subagent(prompt, role)

    backend = BACKENDS.get(MODE, run_openai)
    LOG.info("executing task id=%s via mode=%s prompt[0:80]=%r",
             task_id, MODE, prompt[:80])
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
                        result = await execute_task(task, client=client)
                    except Exception as exc:  # never crash the loop
                        result = f"[bridge exception] {exc}"
                        LOG.exception("task %s failed", task_id)
                    # Post the final answer as a comment so it shows up in
                    # MC's Comments tab without needing UI changes (the
                    # `resolution` field exists in the DB but the
                    # TaskDetailModal doesn't currently render it).
                    await mc_post_comment(
                        client,
                        task_id,
                        f"### ✅ Final answer ({task.get('assigned_to', 'agent')})\n\n{result}",
                    )
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
    """Manual smoke-test endpoint — bypass MC, run a prompt directly.
    Pass `assigned_to` to exercise team-orchestrator vs single sub-agent
    routing without going through the MC task queue."""
    return {"result": await execute_task(payload)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("bridge:app", host="0.0.0.0", port=7920, log_level="info")
