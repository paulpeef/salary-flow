#!/bin/bash
# Обновляет снимки календарей праздников, вшиваемые в приложение.
#
# Снимок нужен, чтобы приложение знало праздники сразу после установки,
# без сети. В работе оно поверх этого подтягивает свежий календарь —
# даты мусульманских праздников уточняются, а в России выходят указы
# о переносах, и оба календаря меняются задним числом.
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() {
  local name="$1" id="$2"
  echo "→ $name"
  curl -fsSL --max-time 60 \
    "https://calendar.google.com/calendar/ical/${id}/public/basic.ics" \
    -o "Resources/holidays-$name.ics"
  echo "  событий: $(grep -c 'BEGIN:VEVENT' "Resources/holidays-$name.ics")"
}

fetch russia  "ru.russian%23holiday%40group.v.calendar.google.com"
fetch malaysia "en.malaysia%23holiday%40group.v.calendar.google.com"
echo "✓ Снимки обновлены"
