
Ниже представлен bash-скрипт для автоматизированной установки и настройки всех ранее упомянутых инструментов. Скрипт использует пакетный менеджер **OCX** для плагинов и напрямую правит конфигурационный файл для подключения MCP-серверов.

```bash
#!/bin/bash

uv tool install reverse-api-engineer  # https://www.opencode.cafe/plugin/reverse-api-engineer

curl -sSL https://raw.githubusercontent.com/ramtinJ95/opencode-tokenscope/main/plugin/install.sh | bash # https://www.opencode.cafe/plugin/opencode-tokenscope

bunx @activade/opencode-auth-sync # https://www.opencode.cafe/plugin/opencode-auth-sync Secret name:   OPENCODE_AUTH 

bunx open-trees add   # https://www.opencode.cafe/plugin/open-trees


# 1. Установка базового пакетного менеджера OCX
# Источник называет его "недостающим пакетным менеджером" для OpenCode.
echo "Установка OpenCode package manager (OCX)..."
curl -fsSL https://ocx.kdco.dev/install.sh | sh
ocx init --global

# 2. Установка плагинов через OCX
# Плагины устанавливаются в локальную директорию проекта .opencode/plugin/.
echo "Установка плагинов..."
ocx add oh-my-opencode-slim  # Оркестрация и tmux
ocx add opencode-mem         # Долгосрочная память
ocx add opencode-snip        # Экономия токенов
ocx add envsitter-guard      # Защита .env файлов
ocx add opencode-notify      # Нативные уведомления

# https://www.opencode.cafe/plugin/opencode-background-agents
ocx registry add --name kdco https://registry.kdco.dev
ocx add kdco/background-agents

# https://www.opencode.cafe/plugin/opencode-background-agents
ocx registry add --name kdco https://registry.kdco.dev
ocx add kdco/background-agents

# https://www.opencode.cafe/plugin/opencode-notify
ocx registry add --name kdco https://registry.kdco.dev
ocx add kdco/notify

# https://www.opencode.cafe/plugin/opencode-workspace
ocx registry add kdco https://registry.kdco.dev
ocx add kdco/workspace

# https://www.opencode.cafe/plugin/opencode-worktree
ocx registry add --name kdco https://registry.kdco.dev
ocx add kdco/worktree


# 3. Настройка MCP-серверов в конфигурационном файле
# Конфигурация ищется в .opencode.json или ~/.config/opencode/opencode.json.
CONFIG_FILE="opencode.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Создание нового файла opencode.json..."
    echo '{"mcpServers": {}}' > "$CONFIG_FILE"
fi

# Добавление Playwright и Context7 в секцию mcpServers
# Примечание: Для корректной работы команд npx может потребоваться предварительная установка зависимостей.
echo "Настройка MCP-серверов (Playwright и Context7)..."
node <<EOF
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));

config.mcpServers = {
  ...config.mcpServers,
  "playwright": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-playwright"]
  },
  "context7": {
    "command": "npx",
    "args": ["-y", "@context7/mcp-server"]
  }
};

fs.writeFileSync('$CONFIG_FILE', JSON.stringify(config, null, 2));
EOF

echo "Установка завершена! Проверьте файл $CONFIG_FILE и наличие плагинов в .opencode/plugin/"
```

### Что делает этот скрипт:
1.  **Инсталлирует `ocx`**: Глобальная установка менеджера расширений, который работает по модели ShadCN.
2.  **Добавляет плагины**: Автоматически скачивает и размещает необходимые инструменты (Slim-версию для экономии токенов, систему памяти и защиту данных) в директорию вашего проекта.
3.  **Конфигурирует MCP**: Использует небольшой Node.js скрипт для безопасного редактирования JSON-файла настроек, добавляя туда сервера для автоматизации браузера (**Playwright**) и поиска по документации (**Context7**).
4.  **Соблюдает приоритеты**: Скрипт ориентирован на локальный файл `opencode.json`, который имеет приоритет над глобальными настройками.

**Важно:** Перед запуском убедитесь, что у вас установлен **Node.js** и **npm**, так как большинство инструментов OpenCode и сам SDK опираются на эту экосистему.


## Не установили
    ./.opencode/opencode.json
        "@ramtinj95/opencode-tokenscope@latest",
        "opencode-mem"
        "@th0rgal/ralph-wiggum",
        ocx remove --force kdco/worktree                                                                                                                                                                                                                                               
        ocx remove --force kdco/background-agents                                                                                                                                                                                                                                       
        ocx remove --force kdco/notify   
    
[//]: # (        login.microsoftonline.com/ )
        "@activade/opencode-auth-sync",
        "opencode-openai-codex-auth@4.1.1",
        "opencode-scheduler",


    ./.opencode/tui.json
        "@aexol/opencode-wizard",
        "@opencode-ai/plugin"
