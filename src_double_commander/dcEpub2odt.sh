#!/usr/bin/env bash
set -uo pipefail
# ============================================================
# Конвертация EPUB → ODT для Double Commander (Надёжная версия)
# Использует цепочку: Calibre (EPUB->DOCX) + LibreOffice (DOCX->ODT)
# ============================================================

# 1. Проверка зависимостей
MISSING_DEPS=()
command -v ebook-convert &>/dev/null || MISSING_DEPS+=("calibre (ebook-convert)")
command -v libreoffice &>/dev/null || MISSING_DEPS+=("libreoffice")

if [[ ${#MISSING_DEPS[@]} -ne 0 ]]; then
    notify-send "📖 EPUB → ODT" \
        "❌ Отсутствуют зависимости:\n${MISSING_DEPS[*]}" \
        -i dialog-error
    exit 1
fi

# 2. Получение списка файлов из параметра %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📖 EPUB → ODT" \
        "⚠️ Не передан список файлов.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
    exit 0
fi

# Очистка от кавычек, \r и пустых строк
mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 3. Сбор всех .epub файлов с дедупликацией
declare -A SEEN_FILES
EPUBS=()
SKIPPED=0

for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                EPUBS+=("$f")
            }
        done < <(find "$item" -type f -iname "*.epub" -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" == "epub" ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                SEEN_FILES["$item"]=1
                EPUBS+=("$item")
            }
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

if [[ ${#EPUBS[@]} -eq 0 ]]; then
    notify-send "📖 EPUB → ODT" \
        "⚠️ Файлы .epub не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

notify-send "📖 EPUB → ODT" \
    "🔄 Начата конвертация ${#EPUBS[@]} файлов..." \
    -i process-working

# 4. Конвертация (EPUB -> DOCX -> ODT)
SUCCESS=0
FAILED=0

for epub in "${EPUBS[@]}"; do
    target_odt="${epub%.*}.odt"
    # Временный файл для промежуточной конвертации
    temp_docx="${epub}.temp_conv.docx"
    temp_odt="${temp_docx%.*}.odt" # Имя, которое создаст LibreOffice
    
    rm -f "$target_odt" "$temp_docx" "$temp_odt" 2>/dev/null

    # ШАГ 1: Calibre конвертирует EPUB в DOCX
    if timeout 120 ebook-convert "$epub" "$temp_docx" &>/dev/null; then
        
        # ШАГ 2: LibreOffice конвертирует DOCX в ODT
        if libreoffice --headless --invisible --convert-to odt --outdir "$(dirname "$epub")" "$temp_docx" &>/dev/null; then
            
            # Если ODT создан успешно
            if [[ -f "$temp_odt" && -s "$temp_odt" ]]; then
                mv "$temp_odt" "$target_odt"
                SUCCESS=$((SUCCESS + 1))
            else
                FAILED=$((FAILED + 1))
            fi
        else
            FAILED=$((FAILED + 1))
        fi
    else
        FAILED=$((FAILED + 1))
    fi
    
    # Удаляем временный DOCX в любом случае
    rm -f "$temp_docx" "$temp_odt" 2>/dev/null
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (не EPUB): $SKIPPED"
notify-send "📖 EPUB → ODT завершено" "$MSG" -i x-office-document