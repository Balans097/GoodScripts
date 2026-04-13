#!/usr/bin/env bash
set -euo pipefail

# 1. Проверка зависимости
if ! command -v ddjvu &>/dev/null; then
    notify-send "📖 DJV/DJVU → PDF" "❌ Утилита ddjvu не найдена.\nУстановите: sudo dnf install djvulibre" -i dialog-error
    exit 1
fi

# 2. Получение выделенных путей от Nautilus
if [[ -z "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    notify-send "📖 DJV/DJVU → PDF" "⚠️ Не выделено ни одного файла или папки" -i dialog-warning
    exit 0
fi

mapfile -t SELECTED <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
# Фильтр пустых строк
SELECTED=("${SELECTED[@]//''/}")
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 3. Сбор всех DJVU/DJV файлов
declare -a DOCS=()
for item in "${SELECTED[@]}"; do
    [[ -z "$item" || ! -e "$item" ]] && continue
    
    if [[ -f "$item" ]]; then
        ext="${item##*.}"
        ext="${ext,,}" # к нижнему регистру
        if [[ "$ext" == "djvu" || "$ext" == "djv" ]]; then
            DOCS+=("$item")
        fi
    elif [[ -d "$item" ]]; then
        # Ищем рекурсивно .djvu ИЛИ .djv
        while IFS= read -r -d '' file; do
            DOCS+=("$file")
        done < <(find "$item" -type f \( -iname "*.djvu" -o -iname "*.djv" \) -print0 2>/dev/null)
    fi
done

if [[ ${#DOCS[@]} -eq 0 ]]; then
    notify-send "📖 DJV/DJVU → PDF" "⚠️ Файлы DJV/DJVU не найдены в выделенных объектах" -i dialog-warning
    exit 0
fi

SUCCESS=0
FAILED=0

notify-send "📖 DJV/DJVU → PDF" "🔄 Начата конвертация ${#DOCS[@]} файлов..." -i process-working

# 4. Конвертация (1 к 1)
for doc in "${DOCS[@]}"; do
    dir="$(dirname "$doc")"
    # Получаем имя файла без расширения (работает и для .djvu, и для .djv)
    clean_name="${doc%.*}"
    pdf="$clean_name.pdf"

    # Конвертация
    if ddjvu -format=pdf "$doc" "$pdf" 2>/dev/null; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        # Если файл был создан пустым (ошибка), удаляем его
        rm -f "$pdf" 2>/dev/null
    fi
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
[[ $FAILED -gt 0 ]] && MSG+=$'\n'"❌ Ошибки: $FAILED"
notify-send "📖 Конвертация завершена" "$MSG" -i x-office-document


