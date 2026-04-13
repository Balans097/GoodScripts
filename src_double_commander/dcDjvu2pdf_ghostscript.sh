#!/usr/bin/env bash
# ============================================================
# Конвертация DJVU/DJV → PDF с оптимизацией размера
# Для Double Commander (параметр: %L)
# ============================================================

# 1. Проверка зависимостей
if ! command -v ddjvu &>/dev/null; then
    notify-send "📖 DJVU → PDF" "❌ Утилита ddjvu не найдена\nУстановите: sudo dnf install djvulibre" -i dialog-error
    exit 1
fi

if ! command -v gs &>/dev/null; then
    notify-send "📖 DJVU → PDF" "⚠️ Ghostscript не найден\nУстановите для сжатия: sudo dnf install ghostscript" -i dialog-warning
    # Продолжаем без сжатия
    USE_GS=0
else
    USE_GS=1
fi

# 2. Получение списка файлов из %L
INPUT_PATHS=()
if [[ -n "${1:-}" && -f "$1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//\"/}"
        line="$(echo "$line" | xargs)"
        [[ -n "$line" ]] && INPUT_PATHS+=("$line")
    done < "$1"
elif [[ $# -gt 0 ]]; then
    INPUT_PATHS=("$@")
else
    notify-send "📖 DJVU → PDF" "⚠️ Не выбрано файлов" -i dialog-warning
    exit 0
fi
[[ ${#INPUT_PATHS[@]} -eq 0 ]] && exit 0

# 3. Сбор DJVU файлов с рекурсией и дедупликацией
declare -A SEEN_FILES
DOCS=()
SKIPPED=0

for item in "${INPUT_PATHS[@]}"; do
    if [[ -d "$item" ]]; then
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                DOCS+=("$f")
            }
        done < <(find "$item" -type f \( -iname "*.djvu" -o -iname "*.djv" \) -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" == "djvu" || "${ext,,}" == "djv" ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                SEEN_FILES["$item"]=1
                DOCS+=("$item")
            }
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

if [[ ${#DOCS[@]} -eq 0 ]]; then
    notify-send "📖 DJVU → PDF" "⚠️ Файлы не найдены" -i dialog-warning
    exit 0
fi

notify-send "📖 DJVU → PDF" "🔄 Конвертация ${#DOCS[@]} файлов..." -i process-working

# 4. Конвертация с оптимизацией
SUCCESS=0
FAILED=0

for doc in "${DOCS[@]}"; do
    output="${doc%.*}.pdf"
    temp_pdf="${doc%.*}_temp.pdf"
    rm -f "$output" "$temp_pdf" 2>/dev/null
    
    # Шаг 1: Конвертация DJVU → PDF
    if ! ddjvu -format=pdf "$doc" "$temp_pdf" >/dev/null 2>&1; then
        FAILED=$((FAILED + 1))
        rm -f "$temp_pdf" 2>/dev/null
        continue
    fi
    
    # Шаг 2: Оптимизация через Ghostscript (если доступен)
    if [[ $USE_GS -eq 1 ]]; then
        # /ebook — баланс качества и размера (150 DPI)
        # /screen — минимальный размер (72 DPI)
        # /prepress — максимальное качество (300 DPI)
        if gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
              -dPDFSETTINGS=/ebook \
              -dNOPAUSE -dQUIET -dBATCH \
              -sOutputFile="$output" "$temp_pdf" 2>/dev/null; then
            rm -f "$temp_pdf" 2>/dev/null
        else
            # Если gs ошибся, используем исходный PDF
            mv "$temp_pdf" "$output"
        fi
    else
        mv "$temp_pdf" "$output"
    fi
    
    if [[ -f "$output" ]]; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

# 5. Итог
MSG="✅ Успешно: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено: $SKIPPED"
[[ $USE_GS -eq 1 ]] && MSG+=$'\n'"🗜️ Сжатие: включено (Ghostscript)"
notify-send "📖 DJVU → PDF завершено" "$MSG" -i x-office-document