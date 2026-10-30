#!/usr/bin/env bash
set -euo pipefail

# Создание каталога бэкапов в ../MacDroid Backup (или переопределённого переменной BACKUP_ROOT)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-"${PROJECT_ROOT}/../MacDroid Backup"}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

echo "[BACKUP] Создание полного снимка проекта в ${BACKUP_DIR}..."

# Сохраняем git diff и статус
git -C "${PROJECT_ROOT}" status --porcelain > "${BACKUP_DIR}/git_status.txt" 2>&1 || true
git -C "${PROJECT_ROOT}" diff > "${BACKUP_DIR}/working_tree.patch" 2>&1 || true
git -C "${PROJECT_ROOT}" diff --cached > "${BACKUP_DIR}/staged.patch" 2>&1 || true

# Сохраняем весь рабочий исходный код (MacHost, AndroidCompanion, scripts, docs) исключая .build и артефакты
rsync -a --exclude='.build' \
         --exclude='.git' \
         --exclude='.backups' \
         --exclude='MacDroid Backup' \
         --exclude='build/' \
         --exclude='DerivedData' \
         --exclude='*.app' \
         "${PROJECT_ROOT}/" "${BACKUP_DIR}/source_tree/"

# Сохраняем готовый скомпилированный бандл приложения, если он существует
if [ -d "${PROJECT_ROOT}/build/MacDroid Commander.app" ]; then
    echo "[BACKUP] Сохранение собранного бандла приложения..."
    mkdir -p "${BACKUP_DIR}/app"
    cp -R "${PROJECT_ROOT}/build/MacDroid Commander.app" "${BACKUP_DIR}/app/"
fi

echo "[BACKUP] ✓ Успешно! Снимок сохранён: ${BACKUP_DIR}"
