#!/bin/bash
# Кладёт Sparkle.framework и его утилиты в .build/sparkle.
#
# Фреймворк не хранится в репозитории: это 3 МБ бинарников, которые
# скачиваются за секунды и одинаково нужны и на машине разработчика,
# и на сборочном сервере. Версия зафиксирована — обновляется осознанно.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.9.5"
DEST=".build/sparkle"

if [ -d "$DEST/Sparkle.framework" ] && [ -x "$DEST/bin/sign_update" ]; then
  exit 0
fi

echo "→ Скачиваю Sparkle $SPARKLE_VERSION"
rm -rf "$DEST"
mkdir -p "$DEST"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -fsSL "$URL" | tar xJ -C "$DEST"

# Тестовое приложение и символы в сборке не нужны — только фреймворк и утилиты.
rm -rf "$DEST/Sparkle Test App.app" "$DEST/Symbols"

echo "✓ Sparkle $SPARKLE_VERSION в $DEST"
