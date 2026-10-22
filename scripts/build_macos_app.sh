#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacDroid Commander"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# 0. Авто-инкремент версии приложения
INFO_PLIST="$PROJECT_ROOT/MacHost/Resources/Info.plist"
if [ -f "$INFO_PLIST" ]; then
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null)
    if [ -n "$CURRENT_VERSION" ]; then
        IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
        if [ -n "$patch" ]; then
            new_patch=$((patch + 1))
            NEW_VERSION="${major}.${minor}.${new_patch}"
            /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
            /usr/libexec/PlistBuddy -c "Set :CFBundleName 'MacDroid Commander $NEW_VERSION'" "$INFO_PLIST" 2>/dev/null || true
            echo "Авто-инкремент версии: $CURRENT_VERSION -> $NEW_VERSION"
        fi
    fi
fi

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

# Автоматически синхронизируем имя приложения в строке меню с актуальной версией
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS/Info.plist" 2>/dev/null || echo "")
if [ -n "$APP_VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 'MacDroid Commander $APP_VERSION'" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'MacDroid Commander $APP_VERSION'" "$CONTENTS/Info.plist" 2>/dev/null || true
    echo "Имя приложения в меню установлено: MacDroid Commander $APP_VERSION"
fi

if [ -d "$PROJECT_ROOT/MacHost/Resources" ]; then
    cp "$PROJECT_ROOT/MacHost/Resources/"*.png "$RESOURCES/" 2>/dev/null || true
    cp "$PROJECT_ROOT/MacHost/Resources/"*.svg "$RESOURCES/" 2>/dev/null || true
fi

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
