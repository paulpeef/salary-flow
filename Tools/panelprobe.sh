#!/bin/bash
# Зонд раскрытия панели из кода: меряет, открывается ли панель меню-бара
# по программному нажатию, когда приложение неактивно, — как при нажатии
# на уведомление. Боевые настройки и журнал не трогает.
set -euo pipefail
cd "$(dirname "$0")/.."

./Tools/fetch-sparkle.sh

swiftc -parse-as-library -O -F .build/sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker "$PWD/.build/sparkle" \
  -target arm64-apple-macos14.0 \
  Sources/Model/Settings.swift Sources/Model/Engine.swift \
  Sources/Model/Holidays.swift Sources/Model/WorkCalendar.swift \
  Sources/Model/Formatting.swift Sources/Model/Backup.swift \
  Sources/Model/Mood.swift Sources/Model/MoodStats.swift \
  Sources/Model/Reminders.swift Sources/Model/AppModel.swift \
  Sources/UI/PanelView.swift Sources/UI/SettingsView.swift \
  Sources/UI/MenuBarLabel.swift Sources/UI/CalendarGrid.swift \
  Sources/UI/MoodBlock.swift Sources/UI/MoodStatsView.swift \
  Sources/Support/AppDelegate.swift Sources/Support/LaunchAgent.swift \
  Sources/Support/MoodReminder.swift Sources/Support/Migration.swift \
  Sources/Support/Log.swift Sources/Support/PrivacyMonitor.swift \
  Sources/Support/Updater.swift \
  Tools/PanelProbe/main.swift \
  -o .build/PanelProbe

SALARYFLOW_LOG_DIR="$(mktemp -d)/logs" \
SALARYFLOW_SETTINGS="$(mktemp -d)/probe-settings.json" \
SALARYFLOW_MOOD="$(mktemp -d)/probe-mood.json" \
.build/PanelProbe
