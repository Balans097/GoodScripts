#!/usr/bin/env bash
set -uo pipefail
# ============================================================
# Конвертация EPUB → DOCX для Double Commander
# Поддерживает: файлы, папки, смешанное выделение, рекурсию
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимости
if ! command -v ebook-convert &>/dev/null; then
    notify-send "📖 EPUB → DOCX" \
        "❌ Утилита ebook-convert не найдена.\nУстановите: sudo dnf install calibre" \
        -i dialog-error
    exit 1
fi

# 2. Получение списка файлов из параметра %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📖 EPUB → DOCX" \
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
        # Рекурсивный поиск (регистронезависимо)
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
    notify-send "📖 EPUB → DOCX" \
        "⚠️ Файлы .epub не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

notify-send "📖 EPUB → DOCX" \
    "🔄 Начата конвертация ${#EPUBS[@]} файлов...\nЭто может занять несколько минут." \
    -i process-working

# 4. Конвертация
SUCCESS=0
FAILED=0

for epub in "${EPUBS[@]}"; do
    docx="${epub%.*}.docx"
    
    # Удаляем возможный старый результат во избежание конфликтов
    rm -f "$docx" 2>/dev/null

    # timeout 120 предотвращает вечное зависание на сложных книгах
    if timeout 120 ebook-convert "$epub" "$docx" &>/dev/null; then
        # Проверяем, что файл реально создан и не пустой
        if [[ -f "$docx" && -s "$docx" ]]; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
            rm -f "$docx" 2>/dev/null
        fi
    else
        FAILED=$((FAILED + 1))
        rm -f "$docx" 2>/dev/null
    fi
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (не EPUB): $SKIPPED"
notify-send "📖 EPUB → DOCX завершено" "$MSG" -i x-office-document