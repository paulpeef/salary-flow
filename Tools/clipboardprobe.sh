#!/bin/bash
# Зонд буфера обмена: печатает, что в нём сейчас лежит и что из этого возьмёт
# заготовка. Ничего не меняет — только читает.
# Порядок: скопировать нужное в программе, потом запустить этот зонд.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
swiftc -O -target arm64-apple-macos14.0 \
  Sources/Model/Snippets.swift \
  Tools/ClipboardProbe/main.swift \
  -o .build/ClipboardProbe

.build/ClipboardProbe
