#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Настройки
# ============================================================
SUPPORTED_EXT="pdf|txt|md|doc|docx|xls|xlsx|ppt|pptx|odt|ods|odp|rtf|fb2|odf|csv|xml|json|html|htm|epub|nim"
OUTPUT_PREFIX="merged_docs"

# 1. Проверка обязательных зависимостей
check_deps() {
    local missing=()
    command -v libreoffice &>/dev/null || missing+=("libreoffice")
    command -v pdfunite &>/dev/null || missing+=("poppler-utils")
    command -v pdfinfo &>/dev/null || missing+=("poppler-utils")
    
    if [[ ${#missing[@]} -ne 0 ]]; then
        notify-send "📄 Документы → PDF" \
            "❌ Отсутствуют критические зависимости:\n${missing[*]}\nУстановите: sudo dnf install libreoffice poppler-utils" \
            -i dialog-error
        exit 1
    fi
}
check_deps

# Проверка Calibre (не критично, но нужно для EPUB)
HAS_CALIBRE=0
command -v ebook-convert &>/dev/null && HAS_CALIBRE=1

# 2. Получение списка из %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📄 Документы → PDF" \
        "⚠️ Не передан список файлов.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
    exit 0
fi

mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 3. Определение целевой директории (рядом с самой верхней папкой)
TOP_FOLDER=""
for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        if [[ -z "$TOP_FOLDER" ]] || [[ ${#item} -lt ${#TOP_FOLDER} ]]; then
            TOP_FOLDER="$item"
        fi
    fi
done

if [[ -n "$TOP_FOLDER" ]]; then
    TARGET_DIR="$(dirname "$TOP_FOLDER")"
else
    TARGET_DIR="$(dirname "${SELECTED[0]}")"
fi
[[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]] && TARGET_DIR="$PWD"

# 4. Сбор документов с фильтрацией и дедупликацией
declare -A SEEN_FILES
DOC_FILES=()

for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        while IFS= read -r -d '' f; do
            ext="${f##*.}"
            if [[ "${ext,,}" =~ ^($SUPPORTED_EXT)$ ]]; then
                [[ -z "${SEEN_FILES["$f"]:-}" ]] && { SEEN_FILES["$f"]=1; DOC_FILES+=("$f"); }
            fi
        done < <(find "$item" -type f -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" =~ ^($SUPPORTED_EXT)$ ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && { SEEN_FILES["$item"]=1; DOC_FILES+=("$item"); }
        fi
    fi
done

mapfile -t DOC_FILES < <(printf '%s\n' "${DOC_FILES[@]}" | sort -V)

if [[ ${#DOC_FILES[@]} -eq 0 ]]; then
    notify-send "📄 Документы → PDF" "⚠️ Поддерживаемые документы не найдены" -i dialog-warning
    exit 0
fi

OUTPUT_FILE="$TARGET_DIR/${OUTPUT_PREFIX}_$(date +%Y%m%d_%H%M%S).pdf"
TEMP_DIR=$(mktemp -d) || { notify-send "📄 Документы → PDF" "❌ Ошибка создания временной папки" -i dialog-error; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT

declare -a PDF_LIST=()
FAIL_LOG="$TEMP_DIR/failures.log"
: > "$FAIL_LOG"

# Массив для пропущенных EPUB (если нет Calibre)
SKIPPED_EPUBS=()

notify-send "📄 Документы → PDF" "🔄 Обработка ${#DOC_FILES[@]} файлов...\nЭто может занять несколько минут." -i process-working

# 5. Конвертация
for file in "${DOC_FILES[@]}"; do
    basename_file=$(basename "$file")
    ext="${file##*.}"
    ext="${ext,,}"
    
    safe_base=$(echo "${basename_file%.*}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    temp_src="$TEMP_DIR/${safe_base}.${ext}"
    temp_pdf="$TEMP_DIR/${safe_base}.pdf"
    
    cp -- "$file" "$temp_src" 2>/dev/null || continue
    
    # PDF просто добавляем в список
    if [[ "$ext" == "pdf" ]]; then
        PDF_LIST+=("$temp_src")
        continue
    fi
    
    # --- ЛОГИКА КОНВЕРТАЦИИ ---
    if [[ "$ext" == "epub" ]]; then
        if [[ $HAS_CALIBRE -eq 0 ]]; then
            SKIPPED_EPUBS+=("$basename_file")
            continue
        fi
        
        # ШАГ 1: EPUB -> DOCX (Calibre)
        intermediate_docx="$TEMP_DIR/${safe_base}.docx"
        if timeout 120 ebook-convert "$temp_src" "$intermediate_docx" &>/dev/null; then
            # ШАГ 2: DOCX -> PDF (LibreOffice)
            if timeout 60 libreoffice --headless --invisible --norestore --nofirststartwizard \
                --convert-to pdf --outdir "$TEMP_DIR" "$intermediate_docx" &>/dev/null; then
                : # Успех
            else
                echo "❌ $basename_file: Ошибка LibreOffice (после Calibre)" >> "$FAIL_LOG"
            fi
            rm -f "$intermediate_docx"
        else
            echo "❌ $basename_file: Ошибка ebook-convert" >> "$FAIL_LOG"
        fi
    else
        # Стандартные форматы
        timeout 45 libreoffice --headless --invisible --norestore --nofirststartwizard \
            --convert-to pdf --outdir "$TEMP_DIR" "$temp_src" &>/dev/null
    fi
    
    # Проверка результата
    if [[ -f "$temp_pdf" && -s "$temp_pdf" ]]; then
        PDF_LIST+=("$temp_pdf")
        rm -f "$temp_src" 2>/dev/null
    else
        echo "❌ $basename_file ($ext) → конвертация не удалась" >> "$FAIL_LOG"
        rm -f "$temp_src" "$temp_pdf" 2>/dev/null
    fi
done

# 6. Слияние PDF
if [[ ${#PDF_LIST[@]} -eq 0 ]]; then
    notify-send "📄 Документы → PDF" "❌ Не удалось создать ни одного PDF" -i dialog-error
    exit 1
fi

if pdfunite "${PDF_LIST[@]}" "$OUTPUT_FILE" 2>/dev/null; then
    PAGE_COUNT=$(pdfinfo "$OUTPUT_FILE" 2>/dev/null | grep -i Pages | awk '{print $2}' || echo "?")
    FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    
    # Формируем текст уведомления
    MSG="✅ Готово!\n📄 $(basename "$OUTPUT_FILE")\n📊 Страниц: $PAGE_COUNT | 💾 $FILE_SIZE"
    
    if [[ -s "$FAIL_LOG" ]]; then
        ERR_COUNT=$(wc -l < "$FAIL_LOG")
        MSG+=$'\n'"⚠️ Ошибки конвертации: $ERR_COUNT"
        if [[ $ERR_COUNT -le 3 ]]; then
            MSG+=$'\n'"$(cat "$FAIL_LOG")"
        else
            MSG+=$'\n'"$(head -3 "$FAIL_LOG")"$'\n'"... и ещё $((ERR_COUNT - 3))"
        fi
    fi
    
    if [[ $HAS_CALIBRE -eq 0 && ${#SKIPPED_EPUBS[@]} -gt 0 ]]; then
        SKIP_COUNT=${#SKIPPED_EPUBS[@]}
        MSG+=$'\n'"📕 Пропущено EPUB: $SKIP_COUNT (установите calibre)"
        if [[ $SKIP_COUNT -le 3 ]]; then
            MSG+=$'\n'"$(printf '  • %s\n' "${SKIPPED_EPUBS[@]}")"
        else
            MSG+=$'\n'"$(printf '  • %s\n' "${SKIPPED_EPUBS[@]:0:3}")"
            MSG+=$'\n'"  ... и ещё $((SKIP_COUNT - 3))"
        fi
    fi
    
    notify-send "📄 Документы → PDF" "$MSG" -i x-office-document
else
    notify-send "📄 Документы → PDF" "❌ Ошибка при слиянии PDF" -i dialog-error
    rm -f "$OUTPUT_FILE" 2>/dev/null
    exit 1
fi
