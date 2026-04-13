#!/usr/bin/env bash
set -uo pipefail
# ============================================================
# Конвертация FB2 → DOCX для Double Commander
# Поддерживает: файлы, папки, смешанное выделение, рекурсию
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимости
if ! command -v ebook-convert &>/dev/null; then
    notify-send "📖 FB2 → DOCX" \
        "❌ Утилита ebook-convert не найдена.\nУстановите: sudo dnf install calibre" \
        -i dialog-error
    exit 1
fi

# 2. Получение списка файлов из параметра %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📖 FB2 → DOCX" \
        "⚠️ Не передан список файлов.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
    exit 0
fi

# Очистка от кавычек, \r и пустых строк
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
    notify-send "📖 FB2 → DOCX" \
        "⚠️ Файлы .fb2 не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

notify-send "📖 FB2 → DOCX" \
    "🔄 Начата конвертация ${#FB2_FILES[@]} файлов...\nЭто может занять несколько минут." \
    -i process-working

# 4. Конвертация
SUCCESS=0
FAILED=0

for fb2 in "${FB2_FILES[@]}"; do
    docx="${fb2%.*}.docx"
    
    # Удаляем возможный старый результат во избежание конфликтов
    rm -f "$docx" 2>/dev/null

    # timeout 120 предотвращает вечное зависание на сложных/повреждённых книгах
    if timeout 120 ebook-convert "$fb2" "$docx" &>/dev/null; then
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
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (не FB2): $SKIPPED"
notify-send "📖 FB2 → DOCX завершено" "$MSG" -i x-office-document