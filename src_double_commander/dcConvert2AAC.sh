#!/usr/bin/env bash
# ============================================================
# Транскодирование аудио в AAC (M4A) для Double Commander
# Параметр панели инструментов: %L
# Результат: ../ИмяПапки_AAC/ (структура сохраняется)
# Команда: ffmpeg -i INPUT -vn -c:a libfdk_aac -b:a $BITRATE OUTPUT.m4a
# Многопоточность: параллельная обработка файлов
# ============================================================

# 🔧 НАСТРОЙКИ
DEBUG=0                    # 1 = открыть терминал с логами
PARALLEL_JOBS=0            # 0 = авто (по ядрам, макс 4), или укажите число
BITRATE="192k"             # 🔹 Битрейт AAC: 96k, 128k, 192k, 256k, 320k

# Запуск в терминале для отладки (приоритет: ptyxis > gnome-terminal)
if [[ "$DEBUG" -eq 1 && ! -t 0 ]]; then
    if command -v ptyxis &>/dev/null; then
        exec ptyxis -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    elif command -v gnome-terminal &>/dev/null; then
        exec gnome-terminal -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    fi
fi

# Настройка вывода
if [[ "$DEBUG" -eq 1 ]]; then
    exec > >(tee /tmp/dc_transcode_aac.log) 2>&1
    set -x
    echo "=========================================="
    echo "DEBUG MODE: $(date) | Args: $*"
    echo "=========================================="
    LOGLEVEL="warning"
else
    exec >/dev/null 2>&1
    LOGLEVEL="error"
fi

# 1. Проверка зависимостей
echo "[1] Checking dependencies..."
if ! command -v ffmpeg &>/dev/null; then
    echo "❌ ffmpeg not found"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "❌ Установите ffmpeg" -i dialog-error
    exit 1
fi
# Проверка наличия libfdk_aac
if ! ffmpeg -encoders 2>/dev/null | grep -q "libfdk_aac"; then
    echo "❌ libfdk_aac encoder not found"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "❌ ffmpeg без libfdk_aac" -i dialog-error
    echo "💡 Установите: sudo dnf install ffmpeg-freeworld"
    exit 1
fi
echo "✅ Dependencies OK"

# 2. Чтение списка из %L
echo "[2] Reading file list..."
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    echo "❌ No list file"
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "⚠️ Не передан список файлов (%L)" -i dialog-warning
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
    [[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "⚠️ Выделите папки с аудиофайлами" -i dialog-warning
    exit 0
fi
[[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "🔄 Обработка ${#DIRS[@]} папок..." -i process-working

# Настройка параллелизации
if [[ "$PARALLEL_JOBS" -le 0 ]]; then
    JOBS=$(nproc 2>/dev/null || echo 4)
    JOBS=$(( JOBS > 4 ? 4 : JOBS ))
    [[ "$JOBS" -lt 2 ]] && JOBS=2
else
    JOBS="$PARALLEL_JOBS"
fi
echo "⚙️ Parallel jobs: $JOBS | Bitrate: $BITRATE"

SUCCESS=0; FAILED=0; SKIPPED=0; TOTAL_FILES=0

# 4. Обработка каждой папки
echo "[4] Processing folders..."
for dir in "${DIRS[@]}"; do
    echo ""; echo "═══════════════════════════════════════"
    echo "Folder: $dir"
    echo "═══════════════════════════════════════"
    
    OUT_DIR="$(dirname "$dir")/$(basename "$dir")_AAC"
    mkdir -p "$OUT_DIR" || { echo "❌ Cannot create $OUT_DIR"; ((FAILED++)); continue; }
    
    # Сбор аудиофайлов (рекурсивно, с сортировкой)
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
    TOTAL_FILES=$((TOTAL_FILES + ${#AUDIO_FILES[@]}))
    
    # 🔹 Массив для отслеживания фоновых задач
    declare -a PIDS=()
    
    for src in "${AUDIO_FILES[@]}"; do
        # Вычисляем относительный путь для сохранения структуры папок
        rel="${src#$dir/}"
        dst_dir="$OUT_DIR/$(dirname "$rel")"
        dst_file="$dst_dir/$(basename "${rel%.*}").m4a"
        # Убираем /./ из пути (остатки от dirname ".")
        dst_file="${dst_file//\/.\//\/}"
        mkdir -p "$dst_dir"
        
        # 🔹 Пропускаем уже AAC/M4A файлы (избегаем деградации качества)
        if [[ "${src,,}" == *.m4a || "${src,,}" == *.aac ]]; then
            echo "  ⏭️  Skip (already AAC): $rel"
            ((SKIPPED++))
            continue
        fi
        
        # 🔹 Функция кодирования (использует ВАШУ команду с переменной $BITRATE)
        encode_file() {
            local src="$1" dst="$2" bitrate="$3" loglevel="$4"
            # ✅ ИСПОЛЬЗУЕМ ВАШУ КОМАНДУ с переменной битрейта:
            # ffmpeg -i INPUT -vn -c:a libfdk_aac -b:a $BITRATE OUTPUT.m4a
            if ffmpeg -y -loglevel "$loglevel" -i "$src" \
                -vn -c:a libfdk_aac -b:a "$bitrate" -movflags +faststart "$dst" 2>&1; then
                # Проверяем, что файл создан и имеет размер > 0
                [[ -s "$dst" ]]
            else
                return 1
            fi
        }
        export -f encode_file
        
        # 🔹 Запускаем в фоне с контролем ошибок
        {
            if encode_file "$src" "$dst_file" "$BITRATE" "$LOGLEVEL"; then
                exit 0
            else
                echo "❌ Encode failed: $(basename "$src")" >&2
                rm -f "$dst_file" 2>/dev/null
                exit 1
            fi
        } &
        PIDS+=($!)
        
        # 🔹 Контроль нагрузки: ждём завершения старейшей задачи при достижении лимита
        if [[ ${#PIDS[@]} -ge $JOBS ]]; then
            wait "${PIDS[0]}" 2>/dev/null || true
            PIDS=("${PIDS[@]:1}")
        fi
    done
    
    # 🔹 Ждём завершения всех оставшихся задач
    for pid in "${PIDS[@]}"; do 
        wait "$pid" 2>/dev/null || true
    done
    unset PIDS
    
    # 🔹 Подсчёт результатов для текущей папки
    folder_ok=0; folder_fail=0
    for src in "${AUDIO_FILES[@]}"; do
        rel="${src#$dir/}"
        dst_file="$OUT_DIR/$(dirname "$rel")/$(basename "${rel%.*}").m4a"
        dst_file="${dst_file//\/.\//\/}"
        if [[ "${src,,}" == *.m4a || "${src,,}" == *.aac ]]; then continue; fi
        if [[ -s "$dst_file" ]]; then
            ((folder_ok++))
        else
            echo "  ❌ Failed: $(basename "$src")" >&2
            ((folder_fail++))
        fi
    done
    
    SUCCESS=$((SUCCESS + folder_ok))
    FAILED=$((FAILED + folder_fail))
    echo "  ✅ Result: $folder_ok OK | $folder_fail ERR | $SKIPPED SKIP"
done

# 5. Итоговое уведомление
MSG="✅ Успешно: $SUCCESS файлов"$'\n'"⏭️ Пропущено (AAC): $SKIPPED"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
MSG+=$'\n'"📁 Всего обработано: $TOTAL_FILES"$'\n'"🎛️ Битрейт: $BITRATE"

echo ""; echo "=========================================="
echo "✅ Success: $SUCCESS | ❌ Failed: $FAILED | ⏭️ Skip: $SKIPPED"
echo "Log: /tmp/dc_transcode_aac.log"
[[ "$DEBUG" -eq 0 ]] && notify-send "🎧 Transcode AAC" "$MSG" -i audio-x-generic
[[ "$DEBUG" -eq 1 ]] && { echo; read -r; }