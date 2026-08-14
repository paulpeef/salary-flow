#!/bin/bash
# Прогон тестов расчётного ядра. Xcode не нужен — только Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=".build"
mkdir -p "$BUILD"

swiftc -O \
  Sources/Model/Settings.swift \
  Sources/Model/Engine.swift \
  Sources/Model/Holidays.swift Sources/Model/WorkCalendar.swift \
  Sources/Model/Formatting.swift \
  Sources/Model/Mood.swift Sources/Model/MoodStats.swift \
  Sources/Model/Reminders.swift \
  Sources/Support/Migration.swift \
  Sources/Support/Log.swift \
  Sources/Support/PrivacyMonitor.swift \
  Tests/main.swift \
  -o "$BUILD/EngineTests"

SALARYFLOW_LOG_DIR="$(mktemp -d)/logs" \
SALARYFLOW_MOOD="$(mktemp -d)/test-mood.json" \
"$BUILD/EngineTests"
