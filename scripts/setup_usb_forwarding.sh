#!/bin/bash
set -e

echo "=================================================="
echo "  MacDroid Commander - USB Bridge Setup (ADB)    "
echo "=================================================="

# Проверка наличия утилиты adb
if ! command -v adb &> /dev/null; then
    # Проверяем стандартный путь в Android SDK macOS
    ANDROID_SDK_ADB="$HOME/Library/Android/sdk/platform-tools/adb"
    if [ -f "$ANDROID_SDK_ADB" ]; then
        ADB_CMD="$ANDROID_SDK_ADB"
    else
        echo "❌ Утилита 'adb' не найдена в PATH и в ~/Library/Android/sdk/platform-tools/"
        echo "   Пожалуйста, установите Android SDK или добавьте platform-tools в PATH."
        exit 1
    fi
else
    ADB_CMD="adb"
fi

echo "Используется adb: $($ADB_CMD version | head -n 1)"
echo "Поиск подключенных Android устройств..."

DEVICES=$($ADB_CMD devices | grep -v "List of devices" | grep "device" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    echo "⚠️  Подключенные устройства не найдены."
    echo "   Убедитесь, что:"
    echo "   1. Телефон (Xiaomi 14 Ultra) подключен по кабелю USB."
    echo "   2. Включена 'Отладка по USB' (USB Debugging) в настройках для разработчиков."
    echo "   3. На экране телефона подтвержден RSA-ключ компьютера."
    exit 1
fi

echo "Найдено устройств: $(echo "$DEVICES" | wc -l | tr -d ' ')"
for DEV in $DEVICES; do
    echo "Настройка проброса портов для устройства: $DEV"
    $ADB_CMD -s "$DEV" forward tcp:2222 tcp:2222
    $ADB_CMD -s "$DEV" reverse tcp:2222 tcp:2222
    echo "✓ [OK] Порт 2222 (SFTP/SSH) успешно перенаправлен (Host 127.0.0.1:2222 <-> Device :2222)"
done

echo ""
echo "🎉 Готово! Теперь вы можете подключаться в MacHost к источнику '127.0.0.1:2222' через надежный проводной USB-канал!"
