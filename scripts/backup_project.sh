#!/usr/bin/env bash
set -euo pipefail

# Создание изолированного каталога бэкапов вне Git
BACKUP_ROOT=".backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

echo "[BACKUP] Создание полного снимка проекта в ${BACKUP_DIR}..."

# Сохраняем git diff и статус
git status --porcelain > "${BACKUP_DIR}/git_status.txt" 2>&1 || true
git diff > "${BACKUP_DIR}/working_tree.patch" 2>&1 || true
git diff --cached > "${BACKUP_DIR}/staged.patch" 2>&1 || true

# Сохраняем весь рабочий исходный код (MacHost, AndroidCompanion, scripts, docs) исключая .build и артефакты
rsync -a --exclude='.build' \
         --exclude='.git' \
         --exclude='.backups' \
         --exclude='build/' \
         --exclude='DerivedData' \
         --exclude='*.app' \
         ./ "${BACKUP_DIR}/source_tree/"

# Сохраняем готовый скомпилированный бандл приложения, если он существует
if [ -d "build/MacDroid Commander.app" ]; then
    echo "[BACKUP] Сохранение собранного бандла приложения..."
    mkdir -p "${BACKUP_DIR}/app"
    cp -R "build/MacDroid Commander.app" "${BACKUP_DIR}/app/"
fi

echo "[BACKUP] ✓ Успешно! Снимок сохранён: ${BACKUP_DIR}"
