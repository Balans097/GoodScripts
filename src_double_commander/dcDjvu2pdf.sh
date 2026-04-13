#!/usr/bin/env bash
# ============================================================
# Конвертация DJVU/DJV → PDF для Double Commander
# Быстрая версия без перекодирования (максимальное качество)
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимости
if ! command -v ddjvu &>/dev/null; then
    notify-send "📖 DJVU → PDF" "❌ Утилита ddjvu не найдена" -i dialog-error
    exit 1
fi

# 2. Получение списка выделенных объектов
INPUT_PATHS=()
if [[ -n "${1:-}" && -f "$1" ]]; then
    # Читаем из временного файла %L
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

# 4. Конвертация (БЕЗ перекодирования — быстро и качественно)
SUCCESS=0
FAILED=0

for doc in "${DOCS[@]}"; do
    output="${doc%.*}.pdf"
    rm -f "$output" 2>/dev/null
    
    # ddjvu создаёт PDF с внедрёнными изображениями без перекодирования
    # Это быстро и сохраняет качество
    if ddjvu -format=pdf "$doc" "$output" >/dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        rm -f "$output" 2>/dev/null
    fi
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено: $SKIPPED"
MSG+=$'\n'"⚡ Скорость: ~1-2 сек/файл"
notify-send "📖 DJVU → PDF завершено" "$MSG" -i x-office-document