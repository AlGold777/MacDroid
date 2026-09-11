#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$PROJECT_ROOT/AndroidCompanion"

echo "=================================================="
echo "  Building Android Companion APK                 "
echo "=================================================="

# Настройка JAVA_HOME если не задан
if [ -z "$JAVA_HOME" ]; then
    if [ -d "/opt/homebrew/opt/openjdk@17" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
    elif [ -d "/Library/Java/JavaVirtualMachines" ]; then
        export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    fi
fi

# Настройка ANDROID_HOME
if [ -z "$ANDROID_HOME" ]; then
    if [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_HOME="$HOME/Library/Android/sdk"
    fi
fi

echo "Используется JAVA_HOME: $JAVA_HOME"
echo "Используется ANDROID_HOME: $ANDROID_HOME"

cd "$ANDROID_DIR"

WRAPPER_JAR="$ANDROID_DIR/gradle/wrapper/gradle-wrapper.jar"
if [ ! -f "$WRAPPER_JAR" ]; then
    echo "Загрузка gradle-wrapper.jar (Gradle 8.2)..."
    curl -sLo "$WRAPPER_JAR" "https://raw.githubusercontent.com/gradle/gradle/v8.2.0/gradle/wrapper/gradle-wrapper.jar" || {
        echo "⚠️  Не удалось загрузить gradle-wrapper.jar из сети."
        echo "   Откройте AndroidCompanion в Android Studio для автоматической загрузки."
    }
fi

if [ -f "$WRAPPER_JAR" ] && [ -n "$ANDROID_HOME" ]; then
    echo "Компиляция отладочного APK..."
    ./gradlew assembleDebug
    echo "=================================================="
    echo "✓ [УСПЕХ] APK успешно собран в:"
    echo "  $ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
    echo "=================================================="
else
    echo "=================================================="
    echo "ℹ️  Для сборки APK откройте проект в Android Studio"
    echo "   или убедитесь в наличии SDK в ~/Library/Android/sdk"
    echo "=================================================="
fi
