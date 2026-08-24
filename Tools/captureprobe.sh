#!/bin/bash
# Зонд захвата экрана: печатает, чем занят каждый подозреваемый процесс —
# сколько ест процессора и есть ли у него окна на экране. Нужен, чтобы
# отличить «Zoom поднял помощника при входе в звонок» от «экран реально
# показывают». Ничего не меняет, только смотрит.
#
#   ./Tools/captureprobe.sh                 # список подозреваемых по умолчанию
#   ./Tools/captureprobe.sh cpthost obs      # свои имена процессов
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
swiftc -O -target arm64-apple-macos14.0 \
  Tools/CaptureProbe/main.swift \
  -o .build/CaptureProbe 2>&1 | grep -v "deprecated" || true

.build/CaptureProbe "$@"
