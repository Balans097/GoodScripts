#!/usr/bin/env bash

# Проверяем наличие ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    notify-send "DAV → MP4" "❌ Утилита ffmpeg не найдена в PATH" -i dialog-error
    exit 1
fi

# Получаем список файлов: из Nautilus или из аргументов командной строки
FILES=()
if [[ -n "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && FILES+=("$line")
    done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
elif [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    notify-send "DAV → MP4" "⚠️ Не выбрано ни одного файла" -i dialog-warning
    exit 0
fi

SUCCESS=0
FAILED=0
SKIPPED=0

for file in "${FILES[@]}"; do
    # Пропускаем несуществующие пути и директории
    [[ -f "$file" ]] || continue

    # Проверка расширения (регистронезависимо: .dav, .DAV, .Dav)
    ext="${file##*.}"
    if [[ "${ext,,}" != "dav" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Формируем путь к выходному файлу в той же папке
    output="${file%.*}.mp4"

    # Конвертация без рекомпрессии (копируем потоки)
    if ffmpeg -i "$file" -c:v copy -c:a copy -y "$output" >/dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
        rm -f "$output" 2>/dev/null
    fi
done

# Итоговое уведомление GNOME
if (( SUCCESS + FAILED + SKIPPED > 0 )); then
    MSG="✅ Успешно: $SUCCESS"
    (( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
    (( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (не DAV): $SKIPPED"
    notify-send "📹 DAV → MP4 завершено" "$MSG" -i video-x-generic
fi