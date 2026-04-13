#!/usr/bin/env bash
set -uo pipefail
# ============================================================
# Конвертация FB2 → ODT для Double Commander (Надёжная версия)
# Цепочка: Calibre (FB2→DOCX) + LibreOffice (DOCX→ODT)
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимостей
MISSING_DEPS=()
command -v ebook-convert &>/dev/null || MISSING_DEPS+=("calibre (ebook-convert)")
command -v libreoffice &>/dev/null || MISSING_DEPS+=("libreoffice")

if [[ ${#MISSING_DEPS[@]} -ne 0 ]]; then
    notify-send "📖 FB2 → ODT" \
        "❌ Отсутствуют зависимости:\n${MISSING_DEPS[*]}" \
        -i dialog-error
    exit 1
fi

# 2. Получение списка файлов из параметра %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📖 FB2 → ODT" \
        "⚠️ Не передан список файлов.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
    exit 0
fi

# Очистка от кавычек, \r (Windows-переносов) и пустых строк
mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 3. Сбор всех .fb2 файлов с дедупликацией
declare -A SEEN_FILES
FB2_FILES=()
SKIPPED=0

for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        # Рекурсивный поиск (регистронезависимо)
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                FB2_FILES+=("$f")
            }
        done < <(find "$item" -type f -iname "*.fb2" -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" == "fb2" ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                SEEN_FILES["$item"]=1
                FB2_FILES+=("$item")
            }
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

if [[ ${#FB2_FILES[@]} -eq 0 ]]; then
    notify-send "📖 FB2 → ODT" \
        "⚠️ Файлы .fb2 не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

notify-send "📖 FB2 → ODT" \
    "🔄 Начата конвертация ${#FB2_FILES[@]} файлов...\nЭто может занять несколько минут." \
    -i process-working

# 4. Конвертация (FB2 → DOCX → ODT)
SUCCESS=0
FAILED=0

for fb2 in "${FB2_FILES[@]}"; do
    target_odt="${fb2%.*}.odt"
    # Временные файлы для промежуточной конвертации
    temp_docx="${fb2}.temp_conv.docx"
    temp_odt="${temp_docx%.*}.odt" # Имя, которое создаст LibreOffice
    
    rm -f "$target_odt" "$temp_docx" "$temp_odt" 2>/dev/null

    # ШАГ 1: Calibre конвертирует FB2 в DOCX
    if timeout 120 ebook-convert "$fb2" "$temp_docx" &>/dev/null; then
        
        # ШАГ 2: LibreOffice конвертирует DOCX в ODT
        if libreoffice --headless --invisible --convert-to odt --outdir "$(dirname "$fb2")" "$temp_docx" &>/dev/null; then
            
            # Если ODT создан успешно и не пустой
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
    
    # Удаляем временный DOCX и возможный остаток ODT
    rm -f "$temp_docx" "$temp_odt" 2>/dev/null
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (не FB2): $SKIPPED"
notify-send "📖 FB2 → ODT завершено" "$MSG" -i x-office-document