#!/bin/bash
# Сборка SalaryFlow.app без Xcode — хватает Command Line Tools.
#   ./build.sh            — собрать в .build/SalaryFlow.app
#   ./build.sh --run      — собрать и запустить
#   ./build.sh --install  — собрать и положить в /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SalaryFlow"
BUNDLE_ID="io.github.paulpeef.salaryflow"
VERSION="${VERSION:-1.7}"
FEED_URL="https://raw.githubusercontent.com/paulpeef/salary-flow/main/appcast.xml"
# Публичный ключ проверки обновлений. Приватный лежит в связке ключей
# разработчика и в секретах репозитория — сюда он не попадает никогда.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-oHSDimtXW5KkFmck6f786b9x//NPa6Zgat0oSw0qzOE=}"
BUILD_DIR=".build"
APP="$BUILD_DIR/$APP_NAME.app"

RUN=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --run) RUN=true ;;
    --install) INSTALL=true ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

./Tools/fetch-sparkle.sh
SPARKLE=".build/sparkle"

echo "→ Тесты расчётного ядра"
./Tests/run.sh

echo "→ Компиляция"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -target arm64-apple-macos14.0 \
  Sources/AppEntry.swift \
  Sources/Model/Settings.swift \
  Sources/Model/Engine.swift \
  Sources/Model/Holidays.swift Sources/Model/WorkCalendar.swift \
  Sources/Model/Formatting.swift \
  Sources/Model/Mood.swift Sources/Model/MoodStats.swift \
  Sources/Model/AppModel.swift \
  Sources/UI/PanelView.swift \
  Sources/UI/SettingsView.swift \
  Sources/UI/MenuBarLabel.swift \
  Sources/UI/CalendarGrid.swift \
  Sources/UI/MoodBlock.swift Sources/UI/MoodStatsView.swift \
  Sources/Support/AppDelegate.swift \
  Sources/Support/LaunchAgent.swift \
  Sources/Support/Migration.swift \
  Sources/Support/Log.swift \
  Sources/Support/PrivacyMonitor.swift \
  Sources/Support/Updater.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

# Фреймворк едет внутри бандла: rpath выше указывает именно сюда.
# Снимки производственных календарей: с ними приложение знает праздники
# сразу после установки, ещё до первого выхода в сеть.
cp Resources/* "$APP/Contents/Resources/"

mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Salary Flow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Личный инструмент, без гарантий</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableInstallerLauncherService</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "✓ Готово: $APP"

if $INSTALL; then
  echo "→ Установка в /Applications"
  pkill -f "/Applications/$APP_NAME.app" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  APP="/Applications/$APP_NAME.app"
  echo "✓ Установлено: $APP"
fi

if $RUN; then
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 1
  open "$APP"

  # «Запустилось» надо проверять, а не объявлять: open возвращает успех и тогда,
  # когда приложение упало через секунду после старта.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
      RUNNING=true
      break
    fi
  done

  if [ "${RUNNING:-false}" = true ]; then
    echo "✓ Запущено — значок капли в строке меню"
  else
    echo "✗ Приложение не поднялось. Последние строки журнала:"
    tail -20 "$HOME/Library/Logs/SalaryFlow/salaryflow.log" 2>/dev/null || echo "  журнала нет"
    exit 1
  fi
fi
