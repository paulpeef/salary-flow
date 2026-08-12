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
  Sources/Model/Holidays.swift \
  Sources/Model/Formatting.swift \
  Sources/Model/AppModel.swift \
  Sources/UI/PanelView.swift \
  Sources/UI/SettingsView.swift \
  Sources/UI/MenuBarLabel.swift \
  Sources/Support/AppDelegate.swift \
  Sources/Support/LaunchAgent.swift \
  Sources/Support/Migration.swift \
  Sources/Support/Log.swift \
  Sources/Support/PrivacyMonitor.swift \
  Sources/Support/Updater.swift \
  Tools/RenderPreview/main.swift \
  -o .build/RenderPreview

SALARYFLOW_LOG_DIR="$(mktemp -d)/logs" SALARYFLOW_SETTINGS="$(mktemp -d)/preview-settings.json" .build/RenderPreview "$OUT"
