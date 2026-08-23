#!/bin/bash
# Зонд смены браузера по умолчанию: спрашивает систему тремя разными способами
# и печатает её ответы дословно. Настройки приложения не трогает.
#
#   ./Tools/browserprobe.sh                    # цель — Google Chrome
#   ./Tools/browserprobe.sh ru.yandex.desktop.yandex-browser
#
# Если какой-то способ сработает, браузер по умолчанию действительно сменится:
# вернуть обратно — этим же зондом, назвав прежний браузер.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
swiftc -O -target arm64-apple-macos14.0 \
  Tools/BrowserProbe/main.swift \
  -o .build/BrowserProbe 2>&1 | grep -v "deprecated" || true

.build/BrowserProbe "$@"
