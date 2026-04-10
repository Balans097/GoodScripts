#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Настройки
# ============================================================
# Поддерживаемые расширения (регистронезависимо)
SUPPORTED_EXT="pdf|txt|md|doc|docx|xls|xlsx|ppt|pptx|odt|ods|odp|rtf|fb2|odf|csv|xml|json|html|htm|epub"
# Префикс выходного файла
OUTPUT_PREFIX="merged_docs"
# ============================================================

# 1. Проверка зависимостей
check_deps() {
    local missing=()
    command -v libreoffice &>/dev/null || missing+=("libreoffice")
    command -v pdfunite &>/dev/null || missing+=("poppler-utils (pdfunite)")
    command -v pdfinfo &>/dev/null || missing+=("poppler-utils (pdfinfo)")
    
    if [[ ${#missing[@]} -ne 0 ]]; then
        notify-send "📄 Документы → PDF" "❌ Отсутствуют зависимости:\n${missing[*]}\nУстановите: sudo dnf install libreoffice poppler-utils" -i dialog-error
        exit 1
    fi
}

# 2. Получение выделенных путей от Nautilus
if [[ -z "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    notify-send "📄 Документы → PDF" "⚠️ Не выделено ни одного файла или папки" -i dialog-warning
    exit 0
fi
mapfile -t SELECTED <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

# Фильтрация пустых строк
SELECTED=("${SELECTED[@]//''/}")
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 3. Определение директории для сохранения результата
TARGET_DIR="$(dirname "${SELECTED[0]}")"
OUTPUT_FILE="$TARGET_DIR/${OUTPUT_PREFIX}_$(date +%Y%m%d_%H%M%S).pdf"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 4. Сбор документов (файлы + рекурсивный поиск в папках)
declare -a DOC_FILES=()

for item in "${SELECTED[@]}"; do
    [[ -z "$item" || ! -e "$item" ]] && continue
    
    if [[ -f "$item" ]]; then
        ext="${item##*.}"
        ext="${ext,,}"
        if [[ "$ext" =~ ^($SUPPORTED_EXT)$ ]]; then
            DOC_FILES+=("$item")
        fi
    elif [[ -d "$item" ]]; then
        while IFS= read -r -d '' file; do
            ext="${file##*.}"
            ext="${ext,,}"
            if [[ "$ext" =~ ^($SUPPORTED_EXT)$ ]]; then
                DOC_FILES+=("$file")
            fi
        done < <(find "$item" -type f -print0 2>/dev/null)
    fi
done

# Удаление дубликатов и естественная сортировка
mapfile -t DOC_FILES < <(printf '%s\n' "${DOC_FILES[@]}" | sort -u -V)

if [[ ${#DOC_FILES[@]} -eq 0 ]]; then
    notify-send "📄 Документы → PDF" "⚠️ Поддерживаемые документы не найдены" -i dialog-warning
    exit 0
fi

# 5. Конвертация и сбор PDF-файлов
declare -a PDF_LIST=()
notify-send "📄 Документы → PDF" "🔄 Обработка ${#DOC_FILES[@]} файлов...\nЭто может занять несколько минут." -i process-working

for file in "${DOC_FILES[@]}"; do
    basename_file=$(basename "$file")
    ext="${file##*.}"
    ext="${ext,,}"

    # Уникальное имя для временной папки (защита от коллизий имён)
    safe_name=$(echo "$basename_file" | sed 's/[^a-zA-Z0-9._-]/_/g')
    counter=0
    while [[ -e "$TEMP_DIR/$safe_name" ]]; do
        safe_name="${safe_name%.*}_${counter}.${safe_name##*.}"
        ((counter++)) || true
    done

    if [[ "$ext" == "pdf" ]]; then
        # PDF копируем без изменений
        cp -- "$file" "$TEMP_DIR/$safe_name"
        PDF_LIST+=("$TEMP_DIR/$safe_name")
    else
        # Копируем в temp и конвертируем через LibreOffice
        cp -- "$file" "$TEMP_DIR/$safe_name"
        libreoffice --headless --invisible --convert-to pdf --outdir "$TEMP_DIR" "$TEMP_DIR/$safe_name" &>/dev/null || true
        
        lo_pdf="$TEMP_DIR/${safe_name%.*}.pdf"
        if [[ -f "$lo_pdf" && -s "$lo_pdf" ]]; then
            PDF_LIST+=("$lo_pdf")
        fi
        # Удаляем исходник из temp, оставляем только PDF
        rm -f "$TEMP_DIR/$safe_name"
    fi
done

# 6. Слияние PDF
if [[ ${#PDF_LIST[@]} -eq 0 ]]; then
    notify-send "📄 Документы → PDF" "❌ Не удалось создать ни одного PDF (ошибки конвертации)" -i dialog-error
    exit 1
fi

if pdfunite "${PDF_LIST[@]}" "$OUTPUT_FILE" 2>/dev/null; then
    PAGE_COUNT=$(pdfinfo "$OUTPUT_FILE" 2>/dev/null | grep -i Pages | awk '{print $2}' || echo "N/A")
    FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    notify-send "📄 Документы → PDF" "✅ Готово!\n📄 $(basename "$OUTPUT_FILE")\n📊 Страниц: $PAGE_COUNT | 💾 $FILE_SIZE\n📁 Сохранено в: $TARGET_DIR" -i x-office-document
else
    notify-send "📄 Документы → PDF" "❌ Ошибка при слиянии PDF" -i dialog-error
    rm -f "$OUTPUT_FILE" 2>/dev/null
fi