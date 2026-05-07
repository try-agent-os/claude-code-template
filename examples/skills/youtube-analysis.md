---
title: YouTube Analysis Pipeline
summary: Анализирует YouTube видео — извлекает транскрипт через youtube-transcript-api, генерирует инсайты через Claude, сохраняет результат в resources/youtube/.
read_when: Пользователь прислал YouTube URL для анализа; задача типа youtube-analysis или "извлеки инсайты из видео"; batch-анализ плейлиста.
---

# Skill: YouTube Analysis Pipeline

## Когда использовать
- Пользователь присылает YouTube URL и просит "разбери/проанализируй видео"
- Worker задача с типом "youtube-analysis" или "извлеки инсайты из видео"
- Batch-анализ плейлиста или списка видео

## Зависимости

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
/tmp/yt-env/bin/python3 scripts/youtube-analyze.py "https://www.youtube.com/watch?v=VIDEO_ID"

# Или через shell-wrapper (автоматически создаёт venv если нет)
./scripts/youtube-analyze.sh "https://www.youtube.com/watch?v=VIDEO_ID"

# Только транскрипт (без LLM)
./scripts/youtube-analyze.sh "https://www.youtube.com/watch?v=VIDEO_ID" --transcript-only
```

### Batch (список URL)
```bash
# Создать файл со списком URL
cat > /tmp/videos.txt << 'EOF'
https://www.youtube.com/watch?v=VIDEO_ID_1
https://www.youtube.com/watch?v=VIDEO_ID_2
# Строки с # игнорируются
EOF

/tmp/yt-env/bin/python3 scripts/youtube-analyze.py --batch /tmp/videos.txt
```

## Output

Файлы создаются в `resources/youtube/<video_id>.md`.

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
novo_relevance: high|medium|low
---

## Краткое резюме
## Ключевые тактики
## Результаты и цифры
## Кто это сработало
## Применимость для Novo Studio
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
1. Создать задачу в saga-mcp: epic_id=2 (Research), title="YouTube анализ: [тема]"
2. Поставить в queue.md для heartbeat
3. Worker выполняет, результат в `resources/youtube/`
4. Operator уведомляет пользователя с GitHub ссылкой на файл

## Пример on-demand через claude peers

```
Vasily → Telegram: "разбери это видео про cold outreach: youtube.com/watch?v=9yVKNBY-59g"
Operator → saga-mcp task: youtube-analysis-9yVKNBY-59g
Heartbeat → Worker: python3 scripts/youtube-analyze.py <url>
Worker → result: resources/youtube/9yVKNBY-59g.md
Operator → Telegram: "Готово: github.com/novostudiotech/claude/blob/main/resources/youtube/9yVKNBY-59g.md"
```
