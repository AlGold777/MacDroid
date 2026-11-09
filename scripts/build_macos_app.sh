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
# Имя содержит версию (MacDroidCompanion-2.1.14.apk); берётся самая свежая: сначала свежесобранная, затем из MacHost/Resources
newest_companion_apk() {
    ls "$1"/MacDroidCompanion-*.apk 2>/dev/null | grep -E 'MacDroidCompanion-[0-9.]+\.apk$' | sort -V | tail -1
}
APK_SRC="$(newest_companion_apk "$PROJECT_ROOT/AndroidCompanion/app/build/outputs/apk/debug")"
RES_APK="$(newest_companion_apk "$PROJECT_ROOT/MacHost/Resources")"
if [ -n "$RES_APK" ] && { [ -z "$APK_SRC" ] || [ "$(printf '%s\n%s\n' "$(basename "$APK_SRC")" "$(basename "$RES_APK")" | sort -V | tail -1)" = "$(basename "$RES_APK")" ]; }; then
    APK_SRC="$RES_APK"
fi
if [ -n "$APK_SRC" ] && [ -f "$APK_SRC" ]; then
    rm -f "$RESOURCES"/MacDroidCompanion-*.apk "$RESOURCES/app-debug.apk"
    echo "Копирование Android Companion APK ($APK_SRC) в $RESOURCES/..."
    cp "$APK_SRC" "$RESOURCES/"
else
    echo "⚠️  Внимание: Android Companion APK не найден ни в AndroidCompanion, ни в MacHost/Resources!"
fi

# 4. Подпись кода постоянным локальным сертификатом (подпись обязательна на Apple Silicon).
# Ad-hoc подпись меняется с каждой сборкой, и macOS теряет разрешения приложения («Локальная сеть»):
# приложение перестаёт видеть телефон в домашней сети. С постоянным сертификатом требование подписи
# (identifier + certificate leaf) одно и то же у всех сборок. Самоподписанный сертификат лежит в
# отдельной связке ключей без пароля и создаётся при первой сборке; связка входа не затрагивается.
SIGN_KEYCHAIN="$HOME/Library/Keychains/macdroid-codesign.keychain-db"
SIGN_NAME="MacDroid Commander Local Signing"

signing_identity_hash() {
    security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }'
}

create_signing_identity() {
    local tmp
    tmp="$(mktemp -d)" || return 1
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # Пароль p12 нужен только для импорта во временном файле
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -days 3650 -config "$tmp/cert.cnf" >/dev/null 2>&1 \
    && openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
        -passout pass:macdroid -name "$SIGN_NAME" >/dev/null 2>&1 \
    && { [ -f "$SIGN_KEYCHAIN" ] || security create-keychain -p "" "$SIGN_KEYCHAIN"; } \
    && security unlock-keychain -p "" "$SIGN_KEYCHAIN" \
    && security set-keychain-settings "$SIGN_KEYCHAIN" \
    && security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P macdroid -T /usr/bin/codesign >/dev/null
    local rc=$?
    # Разрешает codesign брать ключ без запроса; сбой не мешает подписи, если запрос не возникнет
    [ $rc -eq 0 ] && { security set-key-partition-list -S apple-tool:,apple: -s -k "" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true; }
    rm -rf "$tmp"
    return $rc
}

# codesign ищет сертификат только в списке связок пользователя: связка добавляется на время подписи,
# затем список восстанавливается как был.
sign_with_local_identity() {
    local hash="$1" rc line
    local original=()
    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [ -n "$line" ] && original+=("$line")
    done < <(security list-keychains -d user)
    # Пустой список восстановить нельзя: без этой проверки в нём осталась бы только связка подписи
    [ ${#original[@]} -gt 0 ] || return 1
    security unlock-keychain -p "" "$SIGN_KEYCHAIN" || return 1
    security list-keychains -d user -s "${original[@]}" "$SIGN_KEYCHAIN" || return 1
    codesign --force --deep --sign "$hash" "$APP_BUNDLE"
    rc=$?
    security list-keychains -d user -s "${original[@]}" \
        || echo "⚠️  Не удалось восстановить список связок ключей: проверьте «security list-keychains -d user»."
    return $rc
}

if command -v codesign &> /dev/null; then
    SIGN_HASH="$(signing_identity_hash)"
    if [ -z "$SIGN_HASH" ]; then
        echo "Создаётся локальный сертификат подписи «$SIGN_NAME»..."
        create_signing_identity && SIGN_HASH="$(signing_identity_hash)"
    fi
    if [ -n "$SIGN_HASH" ] && sign_with_local_identity "$SIGN_HASH"; then
        echo "Бандл подписан локальным сертификатом «$SIGN_NAME»."
    else
        echo "⚠️  Локальный сертификат недоступен — ad-hoc подпись (разрешение «Локальная сеть» может сбрасываться)."
        codesign --force --deep --sign - "$APP_BUNDLE" || true
    fi
fi

echo "=================================================="
echo "✓ [УСПЕХ] Бандл $APP_NAME.app собран в:"
echo "  $APP_BUNDLE"
echo "=================================================="
