#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacDroid Commander"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "=================================================="
echo "  Building macOS Production App Bundle           "
echo "=================================================="

# 1. Сборка бинарника через SPM
cd "$PROJECT_ROOT/MacHost"
echo "Компиляция MacHost в режиме Release..."
swift build -c release --product MacHost

RELEASE_BIN="$PROJECT_ROOT/MacHost/.build/release/MacHost"
if [ ! -f "$RELEASE_BIN" ]; then
    echo "⚠️  Релизный бинарник не найден в .build/release/MacHost. Используем debug сборку..."
    swift build --product MacHost
    RELEASE_BIN="$PROJECT_ROOT/MacHost/.build/debug/MacHost"
fi

# 2. Создание структуры каталогов .app
echo "Создание бандла: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# 3. Копирование исполняемого файла и ресурсов
cp "$RELEASE_BIN" "$MACOS/MacHost"
chmod +x "$MACOS/MacHost"

cp "$PROJECT_ROOT/MacHost/Resources/Info.plist" "$CONTENTS/Info.plist"
echo "APPL????" > "$CONTENTS/PkgInfo"

# Копирование приложения-компаньона Android APK в ресурсы бандла
APK_SRC="$PROJECT_ROOT/AndroidCompanion/app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$APK_SRC" ] && [ -f "$PROJECT_ROOT/MacHost/Resources/app-debug.apk" ]; then
    APK_SRC="$PROJECT_ROOT/MacHost/Resources/app-debug.apk"
fi
if [ -f "$APK_SRC" ]; then
    echo "Копирование Android Companion APK ($APK_SRC) в $RESOURCES/app-debug.apk..."
    cp "$APK_SRC" "$RESOURCES/app-debug.apk"
else
    echo "⚠️  Внимание: Android Companion APK не найден ни в AndroidCompanion, ни в MacHost/Resources!"
fi

# 4. Ad-hoc подпись кода (требуется на Apple Silicon)
if command -v codesign &> /dev/null; then
    echo "Выполняется ad-hoc подпись бандла..."
    codesign --force --deep --sign - "$APP_BUNDLE" || true
fi

echo "=================================================="
echo "✓ [УСПЕХ] Бандл $APP_NAME.app собран в:"
echo "  $APP_BUNDLE"
echo "=================================================="
