#!/usr/bin/env bash
# ============================================================
# Объединение аудиофайлов в MP3 (VBR Max Quality) для Double Commander
# Параметр панели инструментов: %L
# Результат: ../ИмяПапки.mp3 (рядом с исходной папкой)
# Использует concat filter для надёжной склейки (исправляет ошибку Header missing)
# ============================================================

DEBUG=0
PARALLEL_JOBS=0

# Если DEBUG=1 и мы НЕ в терминале, перезапускаемся в ptyxis/gnome-terminal
if [[ "$DEBUG" -eq 1 && ! -t 0 ]]; then
    if command -v ptyxis &>/dev/null; then
        exec ptyxis -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    elif command -v gnome-terminal &>/dev/null; then
        exec gnome-terminal -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    fi
fi

if [[ "$DEBUG" -eq 1 ]]; then
    exec > >(tee /tmp/dc_audio_merge.log) 2>&1
    set -x
    echo "=========================================="
    echo "DEBUG MODE: $(date) | Args: $*"
    echo "=========================================="
else
    exec >/dev/null 2>&1
fi

# 1. Проверка зависимостей
echo "[1] Checking dependencies..."
MISSING=()
command -v ffmpeg &>/dev/null || MISSING+=("ffmpeg")
if [[ -z "$MISSING" ]]; then
    if ! ffmpeg -encoders 2>/dev/null | grep -q libmp3lame; then
        MISSING+=("ffmpeg (с поддержкой libmp3lame)")
    fi
fi

if [[ ${#MISSING[@]} -ne 0 ]]; then
    echo "❌ Missing: ${MISSING[*]}"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎵 Audio Merge" "❌ Отсутствуют: ${MISSING[*]}" -i dialog-error
    exit 1
fi
echo "✅ Dependencies OK"

# 2. Чтение списка из %L
echo "[2] Reading file list..."
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    echo "❌ No list file"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎵 Audio Merge" "⚠️ Не передан список файлов (%L)" -i dialog-warning
    exit 0
fi

mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0
echo "📋 Selected: ${#SELECTED[@]}"

# 3. Фильтрация только папок
echo "[3] Filtering directories..."
DIRS=()
for item in "${SELECTED[@]}"; do
    [[ -d "$item" ]] && DIRS+=("$(realpath "$item")")
done

if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "⚠️ No directories selected"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎵 Audio Merge" "⚠️ Выделите папки с аудиофайлами" -i dialog-warning
    exit 0
fi
[[ "$DEBUG" -eq 0 ]] && notify-send "🎵 Audio Merge" "🔄 Обработка ${#DIRS[@]} папок..." -i process-working

SUCCESS=0; FAILED=0
TOTAL_FILES=0

# 4. Обработка каждой папки
echo "[4] Processing folders..."
for dir in "${DIRS[@]}"; do
    echo ""; echo "═══════════════════════════════════════"
    echo "Folder: $dir"
    echo "═══════════════════════════════════════"
    
    PARENT="$(dirname "$dir")"
    FOLDER_NAME="$(basename "$dir")"
    OUT_MP3="$PARENT/${FOLDER_NAME}.mp3"
    
    # Поиск аудиофайлов (рекурсивно)
    echo "  🔍 Searching audio files..."
    mapfile -t AUDIO_FILES < <(find "$dir" -type f \( \
        -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.ogg" -o -iname "*.oga" \
        -o -iname "*.m4a" -o -iname "*.aac" -o -iname "*.wma" -o -iname "*.opus" -o -iname "*.aiff" \
        -o -iname "*.ape" -o -iname "*.alac" \) -print0 2>/dev/null | sort -z | tr '\0' '\n')
    
    if [[ ${#AUDIO_FILES[@]} -eq 0 ]]; then
        echo "  ⚠️  No audio files found"
        ((FAILED++)); continue
    fi
    echo "  🎶 Found: ${#AUDIO_FILES[@]} files"
    
    # Подготовка аргументов для concat FILTER (более надёжно, чем concat demuxer)
    declare -a FFMPEG_ARGS=()
    FFMPEG_ARGS+=(ffmpeg -y -loglevel error -strict experimental)
    
    # Добавляем каждый файл как отдельный вход (-i file)
    for f in "${AUDIO_FILES[@]}"; do
        FFMPEG_ARGS+=(-i "$f")
    done
    
    # Формируем строку фильтра: [0:a][1:a][2:a]concat=n=3:v=0:a=1 [a]
    FILTER_STRING=""
    for ((i=0; i<${#AUDIO_FILES[@]}; i++)); do
        FILTER_STRING+="[${i}:a]"
    done
    FILTER_STRING+="concat=n=${#AUDIO_FILES[@]}:v=0:a=1 [a]"
    
    FFMPEG_ARGS+=(-filter_complex "$FILTER_STRING")
    FFMPEG_ARGS+=(-map "[a]")
    # VBR 0 - максимальное качество
    FFMPEG_ARGS+=(-c:a libmp3lame -q:a 0 "$OUT_MP3")
    
    echo "  🔄 Merging to: $OUT_MP3"
    
    # Запуск ffmpeg
    if "${FFMPEG_ARGS[@]}" 2>/tmp/ffmpeg_last_error.log; then
        if [[ -s "$OUT_MP3" ]]; then
            FILE_SIZE=$(du -h "$OUT_MP3" | cut -f1)
            TOTAL_FILES=$((TOTAL_FILES + ${#AUDIO_FILES[@]}))
            echo "  ✅ Done! Size: $FILE_SIZE | Files: ${#AUDIO_FILES[@]}"
            ((SUCCESS++)) || true
        else
            echo "  ❌ Empty output"
            rm -f "$OUT_MP3"
            ((FAILED++))
        fi
    else
        echo "  ❌ FFmpeg error (see /tmp/ffmpeg_last_error.log)"
        rm -f "$OUT_MP3"
        ((FAILED++))
    fi
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS папок"$'\n'"🎵 Объединено файлов: $TOTAL_FILES"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"

echo ""; echo "=========================================="
echo "✅ Success: $SUCCESS | ❌ Failed: $FAILED | 📁 Files: $TOTAL_FILES"
echo "Log: /tmp/dc_audio_merge.log"
[[ "$DEBUG" -eq 0 ]] && notify-send "🎵 Audio Merge" "$MSG" -i audio-x-generic
[[ "$DEBUG" -eq 1 ]] && { echo; read -r; }