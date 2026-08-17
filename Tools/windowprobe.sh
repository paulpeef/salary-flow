#!/bin/bash
# Снимок настоящего SwiftUI-окна настроек вместе с хромом окна.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.build/preview/window-real.png}"
mkdir -p "$(dirname "$OUT")"

./Tools/fetch-sparkle.sh

swiftc -parse-as-library -O -F .build/sparkle -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/.build/sparkle" \
  Sources/Model/Settings.swift Sources/Model/Engine.swift Sources/Model/Holidays.swift Sources/Model/WorkCalendar.swift Sources/Model/Formatting.swift Sources/Model/Backup.swift \
  Sources/Model/Mood.swift Sources/Model/MoodStats.swift \
  Sources/Model/AppModel.swift Sources/UI/PanelView.swift Sources/UI/SettingsView.swift \
  Sources/UI/MenuBarLabel.swift \
  Sources/UI/CalendarGrid.swift \
  Sources/UI/MoodBlock.swift Sources/UI/MoodStatsView.swift \
  Sources/Support/AppDelegate.swift \
  Sources/Support/LaunchAgent.swift \
  Sources/Support/Migration.swift \
  Sources/Support/Log.swift Sources/Support/PrivacyMonitor.swift \
  Sources/Support/Updater.swift \
  Tools/WindowProbe/main.swift \
  -o .build/WindowProbe

SALARYFLOW_LOG_DIR="$(mktemp -d)/logs" \
SALARYFLOW_SETTINGS="$(mktemp -d)/probe-settings.json" \
SALARYFLOW_MOOD="$(mktemp -d)/probe-mood.json" \
.build/WindowProbe
