# Образцовый пример: команда из 3 агентов на Claude + OpenAI + Local LLM

Демонстрация мульти-провайдерной команды в Mission Control. Один master-проект → architect (Claude) декомпозирует → implementor (OpenAI) пишет код → linter (Local LMStudio) чистит → aegis (Claude) ревьюит.

Идея: разная цена/качество/скорость для разных ролей. Architect и review — Anthropic (reasoning quality). Implementor — OpenAI (масса быстрых задач). Linter — local (бесплатно, низкая ставка).

> Все значения в "копировать-вставить" формате. Если поля в UI у тебя называются иначе — скажи, обновлю файл.

---

## 0. Подготовка

### 0.1. `.env` в корне проекта

Создай (или допиши в существующий) `beads/discovered/mission-control/.env`:

```dotenv
# Anthropic — для architect и aegis
ANTHROPIC_API_KEY=sk-ant-api03-...

# OpenAI — для implementor
OPENAI_API_KEY=sk-...

# Local LLM (LMStudio дефолт). Замени на свою модель.
# Если LMStudio: оставь как есть, ключ не нужен.
# Если liteLLM proxy: укажи http://litellm:4000 и LOCAL_LLM_API_KEY.
LOCAL_LLM_ENDPOINT=http://host.docker.internal:1234/v1
LOCAL_LLM_API_KEY=

# Coexist для shared host claude sessions
MC_HOST_SESSION_MODE=coexist
```

### 0.2. LMStudio — поднять

1. Открой LMStudio на хосте.
2. Загрузи модель (рекомендую **`qwen2.5-coder-7b-instruct`** или **`qwen2.5-7b-instruct`** — хорошо ходят на 16GB RAM).
3. Перейди в Server tab, нажми **Start Server** (порт 1234 по умолчанию).
4. В правом верхнем углу выбери модель в dropdown (она станет дефолтной для запросов).
5. Запиши точный **API Identifier** модели (внизу карточки модели в Server tab) — например `qwen2.5-coder-7b-instruct`. Этот id пойдёт в dispatchModel агента.

### 0.3. Поднять MC

```bash
cd beads/discovered/mission-control
make recreate     # подхватит свежий .env
```

Дождись `✓ http://127.0.0.1:7012 → 200`.

### 0.4. Войти в MC

1. Открой http://127.0.0.1:7012/setup (если ещё не создавал админа) → создай. Иначе → `/login`.
2. После логина ты на дашборде.

---

## 1. Создать workspace (если пусто)

`/workspaces` → **New Workspace**:

| Поле | Значение |
|---|---|
| Name | `multi-provider-demo` |
| Description | `Demo: Claude (architect/aegis) + OpenAI (dev) + Local (linter)` |
| Active | ☑ (активный) |

Save. Переключись на этот workspace в верхнем правом селекторе.

---

## 2. Создать проект

`/projects` → **New Project**:

| Поле | Значение |
|---|---|
| Name | `Refactor Login Flow` |
| Slug / Key | `LOGIN` |
| Ticket Prefix | `LOGIN` |
| Description | `Migrate session-cookie auth to JWT. Demo project for multi-provider team.` |
| Repository URL | (пусто или твой репо) |
| Visibility | `private` |

Save.

---

## 3. Агент №1 — Architect (Claude)

`/agents` → **New Agent**:

| Поле | Значение |
|---|---|
| Display Name | `architect-claude` |
| Role | `researcher` |
| Workspace | `multi-provider-demo` (текущий) |
| Sandbox | `restricted` (или `default` если нет такого) |
| Network | `none` (агент только думает, в сеть не ходит) |
| Framework | `claude-code` |
| Capabilities | `planning, decomposition, architecture` |

После Save → открой агента → вкладка **Soul**:

```
You are an experienced software architect. Your job is to break a single
high-level task into 3-7 atomic implementation tasks.

For each subtask output exactly:
  TITLE: <one-line title>
  DESCRIPTION: <what to do, 2-4 sentences>
  ACCEPTANCE: <how to verify, 1-2 bullets>
  ESTIMATE: <hours, integer>

Do not write code. Do not explain your approach. Only the structured list.
Number subtasks 1, 2, 3, ...
```

Save Soul.

Вкладка **Settings → Agent Runtimes** (или Config):

| Поле | Значение |
|---|---|
| Provider | `anthropic` |
| Model | `claude-opus-4-6` |
| dispatchModel | `claude-opus-4-6` |
| Temperature | `0.2` |
| Max Tokens | `4096` |

Save.

---

## 4. Агент №2 — Implementor (OpenAI)

`/agents` → **New Agent**:

| Поле | Значение |
|---|---|
| Display Name | `dev-openai` |
| Role | `coder` |
| Workspace | `multi-provider-demo` |
| Sandbox | `restricted` |
| Network | `none` |
| Framework | `openai` |
| Capabilities | `implementation, refactor, typescript` |

Soul:

```
You implement code changes. Reply with file paths and unified diffs only.
No prose. No explanations. No "here is the code" preamble.

Format:
  --- a/<path> ---
  <full file content if new>

  *** edit a/<path> ***
  <unified diff with @@ markers>

If the task is unclear, reply with one line:
  CLARIFY: <single specific question>
```

Settings → Agent Runtimes:

| Поле | Значение |
|---|---|
| Provider | `openai` |
| Model | `gpt-4o-mini` |
| dispatchModel | `gpt-4o-mini` |
| Temperature | `0.1` |
| Max Tokens | `4096` |

Save.

---

## 5. Агент №3 — Linter (Local LMStudio)

`/agents` → **New Agent**:

| Поле | Значение |
|---|---|
| Display Name | `linter-local` |
| Role | `reviewer` |
| Workspace | `multi-provider-demo` |
| Sandbox | `restricted` |
| Network | `none` |
| Framework | `openai` (используем OpenAI-совместимый клиент) |
| Capabilities | `lint, format, style` |

Soul:

```
You only suggest lint/format/style fixes. Skip semantic changes.
Reply with bullet list of fixes:
  - <file>:<line> — <fix description>

If nothing to fix, reply:
  CLEAN
```

Settings → Agent Runtimes:

| Поле | Значение | Примечание |
|---|---|---|
| Provider | `openai` | local-LLM speak OpenAI REST shape |
| Model | `qwen2.5-coder-7b-instruct` | **точно как в LMStudio API Identifier** |
| dispatchModel | `local/qwen2.5-coder-7b-instruct` | префикс `local/` обязателен — он триггерит роутинг на `LOCAL_LLM_ENDPOINT` |
| Temperature | `0.1` | |
| Max Tokens | `2048` | |

Save.

---

## 6. Агент №4 — Aegis (Claude, reviewer)

> Aegis — встроенный reviewer-агент в MC. Если он уже создан системой — открой и проверь поля. Если нет — создай как ниже.

`/agents` → **New Agent** (если нет):

| Поле | Значение |
|---|---|
| Display Name | `aegis` |
| Role | `reviewer` |
| Workspace | `multi-provider-demo` |
| Sandbox | `restricted` |
| Network | `none` |
| Framework | `claude-code` |
| Capabilities | `review, qa, verification` |

Soul (формат строгий — MC парсит ответ):

```
You are Aegis, the quality reviewer.

Evaluate the agent's resolution against the acceptance criteria.

Reply with EXACTLY one of these two formats:

If acceptable:
VERDICT: APPROVED
NOTES: <one-line summary>

If needs fix:
VERDICT: REJECTED
NOTES: <specific issues to fix>
```

Settings → Agent Runtimes:

| Поле | Значение |
|---|---|
| Provider | `anthropic` |
| Model | `claude-sonnet-4-6` |
| dispatchModel | `claude-sonnet-4-6` |
| Temperature | `0.0` |
| Max Tokens | `1024` |

Save.

---

## 7. Master-задача через Architect

`/tasks` → **New Task**:

| Поле | Значение |
|---|---|
| Title | `Migrate /api/auth/login from session cookies to JWT` |
| Project | `Refactor Login Flow (LOGIN)` |
| Assigned To | `architect-claude` |
| Priority | `high` |
| Estimated Hours | `8` |
| Tags | `auth, refactor, jwt` |
| Description | (см. ниже) |

Description (полный текст для копирования):

```
Replace cookie-based session auth with JWT in the /api/auth/login endpoint.

Current state:
- /api/auth/login sets a session cookie via NextResponse.cookies.set('session', token)
- Server reads this cookie to authenticate subsequent /api/* requests
- Cookie is httpOnly + Secure + SameSite=Lax
- Session token is stored in `sessions` table, looked up by id

Goal:
- /api/auth/login returns { token: string, expiresAt: number } in the JSON body
- Token is a signed JWT (use existing AUTH_SECRET as HS256 signing key)
- Subsequent requests authenticate via Authorization: Bearer <token> header
- Drop the `sessions` table dependency entirely
- Keep /api/auth/logout working (now stateless: client just discards the token)

Constraints:
- All existing E2E tests must still pass after refactor
- Backward compatibility for ONE release: accept BOTH cookie and Bearer header
  during the deprecation window
- Document the migration in CHANGELOG.md

Decompose into 3-7 atomic subtasks. For each, give acceptance criteria
the implementor agent can verify locally before marking done.
```

**Status:** оставь `backlog`. Сохрани.

---

## 8. Запустить конвейер

### 8.1. Architect декомпозирует

В `/tasks` Kanban:
- Перетащи карточку **`Migrate /api/auth/login...`** из `Backlog` → `In Progress`.
- Через ~30-90с (Claude Opus думает) карточка обновится: в поле `resolution` появится список из 3-7 пронумерованных подзадач в формате TITLE/DESCRIPTION/ACCEPTANCE/ESTIMATE.

**Где смотреть:**
- В карточке задачи (клик на неё) — `resolution` блок.
- `make logs | grep "anthropic"` — увидишь dispatch event.
- `/cost-tracker` — строка с `claude-opus-4-6` и потраченными токенами.

### 8.2. Раскладка подзадач (вручную, ~2 мин)

Открой resolution architect'а. Для каждой подзадачи:
1. `/tasks` → **New Task**.
2. Title = `LOGIN-N: <TITLE>` (пример: `LOGIN-1: Add jwt sign helper`).
3. Project = `Refactor Login Flow`.
4. Assigned To = `dev-openai`.
5. Priority = inherited от architect estimate (≤2h → `medium`, >2h → `high`).
6. Description = блок DESCRIPTION + ACCEPTANCE из вывода architect.
7. Tags = `auth, jwt`.
8. Save.

(Можно автоматизировать через `pnpm mc tasks create-from-resolution --parent <master-id>` если такая команда есть — проверь `pnpm mc tasks --help`.)

### 8.3. Dev пишет код

Перетащи каждую подзадачу из `Backlog` → `In Progress`.
- Implementor (OpenAI) обработает — `resolution` получит файлы + diff'ы.
- Скорость: ~10-30с на подзадачу через `gpt-4o-mini`.
- В `/cost-tracker`: модель `gpt-4o-mini`.

### 8.4. Linter (опционально, но показывает local-LLM в работе)

Создай **новую** задачу для каждой готовой dev-задачи:
- Title: `Lint LOGIN-N output`.
- Assigned To: `linter-local`.
- Description: вставь diff из `LOGIN-N` resolution + одну строку `Suggest only style/lint fixes.`.

Перетащи в In Progress. LMStudio должна показать запрос в Server logs. Resolution = bullet list или `CLEAN`.

### 8.5. Aegis ревью

Перетащи каждую dev-задачу из `In Progress` → `Review`.
- MC автоматически вызовет Aegis на каждой review-задаче (см. `runAegisReviews` — runs every 60s).
- Aegis вернёт `VERDICT: APPROVED` → задача в `Done`. Или `VERDICT: REJECTED` + NOTES → задача обратно в `In Progress` с комментарием.
- В `/cost-tracker`: модель `claude-sonnet-4-6`.

---

## 9. Что должно получиться (приёмка demo)

Через 5-15 минут после старта конвейера ты должен увидеть:

| Проверка | Где | Ожидаемое |
|---|---|---|
| 4 агента онлайн | `/agents` | 4 строки, у всех `last_seen` свежий |
| Master-задача декомпозирована | `/tasks/<master-id>` | resolution содержит 3-7 пронумерованных пунктов TITLE/DESCRIPTION/ACCEPTANCE/ESTIMATE |
| 3-7 подзадач созданы | `/tasks` Kanban | колонки заполнены, у всех assigned `dev-openai` |
| Dev-задачи имеют diff | `/tasks/<id>` | resolution содержит unified diff блоки |
| Linter работает | LMStudio Server tab | ≥1 request в логе |
| Aegis verdicts | `/tasks/<id>` | resolution или comment имеет `VERDICT: APPROVED` или `REJECTED` |
| Cost tracker | `/cost-tracker` | три провайдера: anthropic (Opus + Sonnet), openai (gpt-4o-mini), local ($0) |
| Логи dispatch | `make logs` | `Dispatching task via direct anthropic`, `... openai`, `... local` |

---

## 10. Troubleshooting

### LMStudio не отвечает / `local API 404`

```bash
docker exec mission-control sh -c 'curl -sS http://host.docker.internal:1234/v1/models | head -20'
```

Если 404 → LMStudio не на 1234, проверь Server tab.
Если timeout → LMStudio не запущена или firewall.
Если `models` пустой → загрузи модель в LMStudio.

### `OPENAI_API_KEY not set` в логах

`.env` не подхватился. `make recreate` (а не просто `restart`).

### Aegis не запускается

Aegis сканирует задачи в статусе `review` каждые 60с. Подожди или принудительно `make logs` и смотри на `runAegisReviews`.

### Architect отвечает обычным текстом, не структурированно

Слишком "softный" Soul. Усиль: `OUTPUT EXACTLY THIS FORMAT, NO PROSE`. Или понизь temperature до `0`.

### dispatchModel `local/...` падает с timeout

LMStudio долго грузит модель в память на первом запросе (5-30с). Увеличь timeout либо подержи модель тёплой одним warmup запросом из консоли LMStudio.

### Я не знаю свой LMStudio model id

```bash
docker exec mission-control sh -c 'curl -sS http://host.docker.internal:1234/v1/models | jq ".data[].id"'
```

Покажет точные id всех моделей загруженных в LMStudio. Используй один из них (с префиксом `local/`).

---

## 11. Что менять для своего сценария

- **Другой local backend:** Ollama → `LOCAL_LLM_ENDPOINT=http://host.docker.internal:11434/v1`. Префикс агента `ollama/` (или `local/`).
- **Один liteLLM proxy для нескольких backend'ов:** `LOCAL_LLM_ENDPOINT=http://litellm:4000`, добавь сервис `litellm:` в `docker-compose.yml`, и ходи через `litellm/<routing-name>`.
- **Только Anthropic + OpenAI без local:** удали агент №3 (linter), `LOCAL_LLM_ENDPOINT` оставь как есть (просто не используется).
- **Только Anthropic:** не задавай `OPENAI_API_KEY` и не используй `gpt-*` префиксы — всё пойдёт по старому пути.

---

## 12. Открытые вопросы (если что-то не сошлось при прохождении)

- [ ] Поля `Sandbox` и `Network` в форме New Agent — точно так названы? Какие там значения в dropdown?
- [ ] `Settings → Agent Runtimes` — это вкладка внутри агента или глобальный page?
- [ ] `dispatchModel` — отдельное поле или часть JSON в Config?
- [ ] Aegis уже создан системой автоматически или нужно вручную?

Если что-то не совпадает — пометь в этом списке, я обновлю файл.
