#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Конвертация DAV → MP4 для Double Commander
# Поддерживает: файлы, папки, смешанное выделение, рекурсию
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимости
if ! command -v ffmpeg &>/dev/null; then
    notify-send "📹 DAV → MP4" "❌ Утилита ffmpeg не найдена в PATH" -i dialog-error
    exit 1
fi

# 2. Получение списка выделенных объектов
INPUT_PATHS=()
if [[ -n "${1:-}" && -f "$1" ]]; then
    # Читаем из временного файла %L
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//\"/}" # убираем возможные кавычки
        [[ -n "$line" ]] && INPUT_PATHS+=("$line")
    done < "$1"
elif [[ $# -gt 0 ]]; then
    # Прямая передача аргументов (резерв)
    INPUT_PATHS=("$@")
else
    notify-send "📹 DAV → MP4" "⚠️ Не выбрано ни одного файла или папки" -i dialog-warning
    exit 0
fi

[[ ${#INPUT_PATHS[@]} -eq 0 ]] && exit 0

# 3. Сбор всех .dav файлов с дедупликацией
declare -A SEEN_FILES
DAV_FILES=()
SUCCESS=0
FAILED=0
SKIPPED=0

for item in "${INPUT_PATHS[@]}"; do
    if [[ -d "$item" ]]; then
        # Рекурсивный поиск .dav (регистронезависимо)
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                DAV_FILES+=("$f")
            }
        done < <(find "$item" -type f -iname "*.dav" -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" == "dav" ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                SEEN_FILES["$item"]=1
                DAV_FILES+=("$item")
            }
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

if [[ ${#DAV_FILES[@]} -eq 0 ]]; then
    notify-send "📹 DAV → MP4" "⚠️ Файлы .dav не найдены в выбранных объектах" -i dialog-warning
    exit 0
fi

# 4. Конвертация
for file in "${DAV_FILES[@]}"; do
    output="${file%.*}.mp4"
    # -nostdin предотвращает зависание ffmpeg при вызове из GUI-среды
    if ffmpeg -nostdin -i "$file" -c:v copy -c:a copy -y "$output" >/dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        rm -f "$output" 2>/dev/null
    fi
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS"
if (( FAILED > 0 )); then MSG+=$'\n❌ Ошибки: $FAILED'; fi
if (( SKIPPED > 0 )); then MSG+=$'\n⏭️ Пропущено (не DAV): $SKIPPED'; fi
notify-send "📹 DAV → MP4 завершено" "$MSG" -i video-x-generic