#!/bin/bash
# Рендер интерфейса в PNG без запуска приложения.
# Настройки берутся из временного файла, боевые не затрагиваются.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/preview}"
mkdir -p "$OUT" .build

./Tools/fetch-sparkle.sh

swiftc -O -F .build/sparkle -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/.build/sparkle" \
  -target arm64-apple-macos14.0 \
  Sources/Model/Settings.swift \
  Sources/Model/Engine.swift \
  Sources/Model/Holidays.swift Sources/Model/WorkCalendar.swift \
  Sources/Model/Formatting.swift Sources/Model/Backup.swift \
  Sources/Model/Mood.swift Sources/Model/MoodStats.swift \
  Sources/Model/Reminders.swift Sources/Model/Browsers.swift \
  Sources/Model/AppModel.swift \
  Sources/UI/PanelView.swift \
  Sources/UI/SettingsView.swift \
  Sources/UI/MenuBarLabel.swift \
  Sources/UI/CalendarGrid.swift \
  Sources/UI/MoodBlock.swift Sources/UI/MoodStatsView.swift \
  Sources/UI/BrowserBlock.swift \
  Sources/Support/AppDelegate.swift \
  Sources/Support/LaunchAgent.swift \
  Sources/Support/MoodReminder.swift \
  Sources/Support/Migration.swift \
  Sources/Support/Log.swift \
  Sources/Support/PrivacyMonitor.swift Sources/Support/BrowserSwitcher.swift \
  Sources/Support/Updater.swift \
  Tools/RenderPreview/main.swift \
  -o .build/RenderPreview

# Значок строки меню лежит в бандле, а у превью бандла нет — показываем путь
# к исходнику, иначе на месте капли будет системный символ.
SALARYFLOW_LOG_DIR="$(mktemp -d)/logs" SALARYFLOW_SETTINGS="$(mktemp -d)/preview-settings.json" \
SALARYFLOW_MOOD="$(mktemp -d)/preview-mood.json" \
SALARYFLOW_MENUBAR_ICON="$PWD/Resources/MenuBarIcon@2x.png" \
.build/RenderPreview "$OUT"
