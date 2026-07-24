---
name: youtube-analysis
description: Анализирует YouTube видео — извлекает транскрипт через youtube-transcript-api, генерирует инсайты через Claude, сохраняет результат в resources/youtube/.
when_to_use: Пользователь прислал YouTube URL и просит "разбери/проанализируй видео"; задача youtube-analysis или "извлеки инсайты из видео"; batch-анализ плейлиста.
allowed-tools: Read, Edit, Write, Bash, WebFetch
---

# Skill: YouTube Analysis Pipeline

## Когда использовать
- Пользователь присылает YouTube URL и просит "разбери/проанализируй видео"
- Worker задача с типом "youtube-analysis" или "извлеки инсайты из видео"
- Batch-анализ плейлиста или списка видео

## Зависимости

- Python 3 + `youtube-transcript-api` (pip)
- `yt-dlp` (fallback для видео без субтитров через стандартный API)
- `claude` CLI для генерации инсайтов (опционально — можно делать прямо в этой сессии)

### Установка (первый раз)
```bash
python3 -m venv /tmp/yt-env
/tmp/yt-env/bin/pip install youtube-transcript-api
# yt-dlp через brew (fallback для видео без субтитров):
brew install yt-dlp
```

### Проверка готовности
```bash
/tmp/yt-env/bin/python3 -c "from youtube_transcript_api import YouTubeTranscriptApi; print('OK')"
which yt-dlp && yt-dlp --version
```

**Важно:** venv создаётся в `/tmp/yt-env` — не сохраняется после перезагрузки. При "module not found" — пересоздать venv.

## Команды

### Одно видео
```bash
# Полный анализ (транскрипт + LLM инсайты)
/tmp/yt-env/bin/python3 "${CLAUDE_PROJECT_DIR}/scripts/youtube-analyze.py" "https://www.youtube.com/watch?v=VIDEO_ID"

# Или через shell-wrapper (автоматически создаёт venv если нет)
"${CLAUDE_PROJECT_DIR}/scripts/youtube-analyze.sh" "https://www.youtube.com/watch?v=VIDEO_ID"

# Только транскрипт (без LLM)
"${CLAUDE_PROJECT_DIR}/scripts/youtube-analyze.sh" "https://www.youtube.com/watch?v=VIDEO_ID" --transcript-only
```

### Batch (список URL)
```bash
# Создать файл со списком URL
cat > /tmp/videos.txt << 'EOF'
https://www.youtube.com/watch?v=VIDEO_ID_1
https://www.youtube.com/watch?v=VIDEO_ID_2
# Строки с # игнорируются
EOF

/tmp/yt-env/bin/python3 "${CLAUDE_PROJECT_DIR}/scripts/youtube-analyze.py" --batch /tmp/videos.txt
```

(Скрипт `youtube-analyze.py` нужно положить в `scripts/` — это простой wrapper над youtube-transcript-api + claude CLI.)

## Output

Файлы создаются в `${CLAUDE_PROJECT_DIR}/resources/youtube/<video_id>.md`.

Формат:
```yaml
---
video_id: ...
title: "..."
channel: "..."
url: ...
analyzed_at: YYYY-MM-DD
topics: [тема1, тема2]
speaker_credibility: high|medium|low
relevance: high|medium|low
---

## Краткое резюме
## Ключевые тактики
## Результаты и цифры
## Кто это сработало
## Применимость
## Цитаты
## Красные флаги
```

## Архитектура пайплайна

```
YouTube URL
  → extract_video_id()
  → get_video_metadata()  [yt-dlp --dump-json]
  → get_transcript_via_api()  [youtube-transcript-api]
      fallback: get_transcript_via_ytdlp()  [yt-dlp --write-auto-sub]
  → analyze_with_claude()  [claude -p ...]
  → resources/youtube/<video_id>.md
```

## Известные ограничения

- Видео без субтитров и без auto-generated captions — недоступны (редко для публичного контента)
- Очень длинные видео (>3ч) — транскрипт обрезается до 80K символов (~1ч контента)
- Закрытые/age-restricted видео — требуют cookies, не поддерживается в headless режиме
- venv в `/tmp/` — удаляется при перезагрузке, нужно пересоздавать

## Интеграция с operator

Когда пользователь пишет в Telegram что-то вроде "разбери видео youtube.com/...", operator должен:
1. Создать задачу в saga-mcp: epic "Research", title="YouTube анализ: [тема]"
2. Поставить в очередь для heartbeat-dispatcher
3. Worker выполняет, результат в `resources/youtube/`
4. Operator уведомляет пользователя со ссылкой на файл
