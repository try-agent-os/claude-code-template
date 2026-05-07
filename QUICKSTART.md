# AgentOS — Quickstart Guide

Пошаговая инструкция по развёртыванию AgentOS на существующем проекте.

## Что получишь

Claude Code при открытии папки автоматически:
1. Читает состояние системы (память, очередь, агенты, проекты)
2. Выводит статус
3. Принимает задачи и маршрутизирует их агентам
4. Логирует действия
5. Блокирует опасные команды
6. Напоминает сохранить состояние при завершении

## Шаг 1: Создать структуру папок

```bash
cd /path/to/your/project

# AgentOS слой
mkdir -p agents memory logs .claude/hooks

# Файлы памяти
touch memory/context.md memory/decisions.md memory/learnings.md
touch queue.md
```

**Что это:**
- `agents/` — папки агентов (каждый = agent.md + tasks.md + memory.md)
- `memory/` — общая память системы между сессиями
- `logs/` — автоматические логи действий (append-only)
- `queue.md` — входящие задачи
- `.claude/hooks/` — скрипты автоматизации

## Шаг 2: Написать CLAUDE.md

Это system prompt оркестратора. Claude Code читает его автоматически при старте.

Скопируй шаблон из `os-ru/CLAUDE.md` и адаптируй:
- Секция 2 (маршрутизация) — впиши своих агентов
- Секция 3 (структура) — опиши свой проект
- Ключевые файлы — укажи важные файлы проекта

Принципы:
- Держи под 200 строк (дальше Claude хуже следует)
- Конкретные роли агентов >> размытые ("контент-стратег AI-студии" >> "писатель")
- Не дублируй то что Claude видит из кода

## Шаг 3: Создать агентов

Для каждого агента:

```bash
mkdir -p agents/{agent-name}
```

Создай три файла:

**agent.md** — кто он:
```markdown
# {Название} — {Конкретная роль}

## Роль
{Что делает, что знает}

## Доступ
{Какие папки может читать/писать}

## Тулы
{Read, Write, Edit, Glob, Grep, Bash, WebSearch...}

## Как работаешь
{Пошаговый процесс}

## Ограничения
{Что НЕ делает}
```

**tasks.md** — задачи:
```markdown
# Задачи {agent-name}

## В работе
- [ ] Задача — описание

## Завершено
- [x] Задача — результат, дата
```

**memory.md** — пустой, агент заполнит сам.

Рекомендация: начни с 1-3 агентов. Больше 5 — координация деградирует.

## Шаг 4: Заполнить память

**memory/context.md** — текущая ситуация:
```markdown
# Текущий контекст

## Статус
{Что сейчас происходит}

## Приоритеты
{Что важно}
```

**memory/decisions.md** — решения:
```markdown
# Решения

## YYYY-MM-DD: {Решение}
- {Что решили и почему}
```

## Шаг 5: Настроить хуки

Скопируй из шаблона:

```bash
# Из папки os-ru/ шаблона
cp os-ru/.claude/settings.json .claude/settings.json
cp os-ru/.claude/hooks/*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh
```

Или создай вручную `.claude/settings.json`:
```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/boot.sh"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-bash.sh"
      }]
    }],
    "PostToolUse": [{
      "matcher": "Bash|Write|Edit",
      "hooks": [{
        "type": "command",
        "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/log-action.sh"
      }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-end.sh"
      }]
    }]
  }
}
```

**Что делает каждый хук:**
| Хук | Скрипт | Действие |
|-----|--------|---------|
| SessionStart | boot.sh | Собирает состояние → Claude выполняет startup |
| PreToolUse(Bash) | guard-bash.sh | Блокирует rm -rf, sudo, chmod 777 |
| PostToolUse | log-action.sh | Логирует в logs/YYYY-MM-DD.log |
| Stop | session-end.sh | Напоминает сохранить состояние |

## Шаг 6: Обновить .gitignore

```bash
echo "logs/" >> .gitignore
```

`.claude/` уже должен быть в .gitignore (создаётся автоматически). Если нет — добавь.

## Шаг 6.5: Подготовка macOS (обязательно для автономной работы)

AgentOS работает без тебя — пока ты спишь или отошел. Если macOS не настроен правильно,
система зависнет на диалогах разрешений или заснет в самый неподходящий момент.

### Разрешения для iTerm / терминала

Без этого macOS будет прерывать работу агента диалогами "Разрешить доступ к...":

1. **System Settings → Privacy & Security → Automation**
   - Найди iTerm2 (или Terminal) → включи доступ к другим приложениям

2. **System Settings → Privacy & Security → Accessibility**
   - Добавь iTerm2 → включи

3. **System Settings → Privacy & Security → Full Disk Access**
   - Добавь iTerm2 → включи

> Без Full Disk Access агент не сможет читать файлы за пределами home-директории.
> Без Accessibility — диалоги разрешений будут блокировать выполнение.

### Предотвратить сон компьютера

AgentOS работает по cron — если компьютер заснет, heartbeat остановится:

```bash
# Создать tmux-сессию caffeinate (запускать один раз при старте системы)
tmux new-session -d -s caffeinate 'caffeinate -d'
```

`caffeinate -d` запрещает macOS переходить в sleep-режим пока сессия жива.

## Шаг 7: Запуск в tmux + Telegram

### Базовый запуск (tmux)

tmux = сессия живёт даже если закроешь терминал.

```bash
# Создать сессию и запустить Claude
tmux new-session -d -s myproject -c /path/to/your/project \
  'claude --permission-mode bypassPermissions'

# Подождать старта и отправить boot
sleep 5 && tmux send-keys -t myproject "boot" Enter
```

### С Telegram (рекомендуется)

Управление через телефон — пишешь боту, Claude выполняет.

```bash
# 1. Установить плагин (один раз)
claude plugins install telegram@claude-plugins-official

# 2. Создать бота в Telegram: напиши /newbot в @BotFather, скопируй токен

# 3. Настроить токен (в интерактивной сессии Claude Code)
#    /telegram:configure YOUR_BOT_TOKEN

# 4. Запустить все три сессии

# Предотвратить сон компьютера
tmux new-session -d -s caffeinate 'caffeinate -d'

# Heartbeat (отдельная сессия, cron будит каждые N минут)
tmux new-session -d -s myproject-heartbeat -c /path/to/your/project \
  'claude --permission-mode bypassPermissions --model sonnet'

# Убить зомби-процессы Telegram перед стартом (без этого сообщения дропаются)
# При каждом новом запуске Claude создает новый bun-процесс плагина.
# Telegram раздает сообщения round-robin — старые зомби дропают твои сообщения.
pkill -f 'telegram.*claude-plugins-official' 2>/dev/null; sleep 1

# Оркестратор + Telegram
tmux new-session -d -s myproject -c /path/to/your/project \
  'claude --permission-mode bypassPermissions --channels plugin:telegram@claude-plugins-official'

# 5. Отправить boot
sleep 6 && tmux send-keys -t myproject "boot" Enter

# 6. Привязать аккаунт:
#    - Напиши боту в Telegram любое сообщение
#    - Получишь 6-символьный код
#    - В Claude Code: /telegram:access pair <код>
```

### Полезные флаги

| Флаг | Что делает |
|------|-----------|
| `--permission-mode bypassPermissions` | Без подтверждений (для автономной работы) |
| `--channels plugin:telegram@...` | Подключить Telegram канал |
| `--model sonnet` | Использовать Sonnet (дешевле, быстрее) |
| `--model opus` | Использовать Opus (умнее) |
| `--effort high` | Высокий уровень усилий (Opus) |
| `-p "prompt"` | Headless режим (выполнить и выйти) |
| `-c` | Продолжить последнюю сессию |
| `-r "session-id"` | Продолжить конкретную сессию |
| `-n "name"` | Именовать сессию |
| `--max-turns 10` | Лимит ходов (headless) |
| `--max-budget-usd 5` | Лимит бюджета (headless) |
| `--allowedTools "Read,Edit"` | Разрешить только эти тулы |

### Управление tmux

```bash
tmux attach -t myproject                          # подключиться
# Ctrl+B, D                                      # отключиться (сессия живёт)
tmux send-keys -t myproject "задача" Enter        # команда извне
tmux ls                                           # список сессий
tmux kill-session -t myproject                    # убить
```

## Шаг 8: Heartbeat (cron)

Агент периодически просыпается, проверяет очередь и выполняет задачи.

### Вариант A: Пинг живой сессии (если tmux запущен)

```bash
# Каждые 10 минут будит сессию
crontab -e
*/10 * * * * tmux send-keys -t myproject "проверь очередь, есть ли задачи" Enter 2>/dev/null
```

### Вариант B: Отдельный запуск (headless)

```bash
# Каждые 30 минут запускает новую сессию, выполняет и выходит
*/30 * * * * cd /path/to/your/project && claude -p "проверь очередь и выполни задачи" --permission-mode bypassPermissions --allowedTools "Read,Write,Edit,Bash,Glob,Grep,Agent" >> /tmp/agent-heartbeat.log 2>&1
```

### Настройка

```bash
# Открыть crontab
crontab -e

# Добавить строку (пример: каждые 10 минут)
*/10 * * * * tmux send-keys -t myproject "проверь очередь" Enter 2>/dev/null

# Проверить что добавилось
crontab -l
```

## Пример сессии

```
$ tmux attach -t myproject

> AgentOS online.
> Агенты: content / sales / research — все свободны
> Очередь: пусто
> Жду задачу.

Ты: напиши пост для LinkedIn про AI-автоматизацию для малого бизнеса

> Делегирую content-agent.
> [запускает агента с контекстом из identity + personas + SEO keywords]
> ...
> Готово. Пост в projects/content/drafts/linkedin-ai-automation.md
> Опубликовать? (нужно подтверждение)
```

Или из Telegram:
```
Ты (Telegram): напиши пост для LinkedIn про AI
Бот: Делегирую content-agent... Готово. Пост в drafts/
```

## Чеклист

- [ ] Создана структура: agents/, memory/, logs/, queue.md
- [ ] CLAUDE.md написан (< 200 строк, конкретные роли)
- [ ] Агенты созданы (1-3 штуки, agent.md + tasks.md + memory.md)
- [ ] memory/context.md заполнен
- [ ] Хуки настроены (.claude/settings.json + .claude/hooks/*.sh)
- [ ] .gitignore обновлён (logs/, .claude/)
- [ ] macOS: iTerm/Terminal получил Automation + Accessibility + Full Disk Access
- [ ] tmux `caffeinate` сессия запущена (комп не засыпает)
- [ ] Telegram плагин установлен и бот привязан
- [ ] Зомби-процессы Telegram убиты перед стартом
- [ ] tmux сессии запущены (heartbeat + оркестратор)
- [ ] Heartbeat настроен (crontab)
- [ ] Первый boot отправлен
