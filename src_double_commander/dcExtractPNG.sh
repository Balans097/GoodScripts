#!/usr/bin/env bash
# ============================================================
# Извлечение страниц из PDF/DJVU в PNG для Double Commander
# Параметр панели инструментов: %L
# Результат: ./ИмяФайла/Page_001.png, Page_0001.png...
# АВТООПРЕДЕЛЕНИЕ количества страниц через djvused -e 'n'
# ============================================================

DEBUG=0
PARALLEL_JOBS=0  # 0 — автоматическое определение

# 🔧 Запуск в терминале для отладки (приоритет: ptyxis > gnome-terminal > xterm)
if [[ "$DEBUG" -eq 1 && ! -t 0 ]]; then
    if command -v ptyxis &>/dev/null; then
        exec ptyxis -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    elif command -v gnome-terminal &>/dev/null; then
        exec gnome-terminal -- bash -c "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    elif command -v xterm &>/dev/null; then
        exec xterm -e "bash '$0' '$1'; echo; read -p 'Нажмите Enter для закрытия...'"
    fi
fi

# Настройка вывода
if [[ "$DEBUG" -eq 1 ]]; then
    exec > >(tee /tmp/dc_extract_debug.log) 2>&1
    set -x
    echo "=========================================="
    echo "DEBUG MODE: $(date) | Args: $*"
    echo "=========================================="
else
    exec >/dev/null 2>&1
fi

# Проверка зависимостей
echo "[1] Checking dependencies..."
MISSING=()
command -v pdftoppm &>/dev/null || MISSING+=("poppler-utils")
command -v ddjvu &>/dev/null || MISSING+=("djvulibre")
command -v convert &>/dev/null || MISSING+=("ImageMagick")
if [[ ${#MISSING[@]} -ne 0 ]]; then
    echo "❌ Missing: ${MISSING[*]}"
    [[ "$DEBUG" -eq 0 ]] && notify-send "📄 Экспорт страниц" "❌ Отсутствуют: ${MISSING[*]}" -i dialog-error
    exit 1
fi
echo "✅ Dependencies OK"

# Чтение списка файлов из %L
echo "[2] Reading file list..."
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    echo "❌ No list file"
    [[ "$DEBUG" -eq 0 ]] && notify-send "📄 Экспорт страниц" "⚠️ Не передан список файлов" -i dialog-warning
    exit 0
fi
mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0
echo "📋 Selected: ${#SELECTED[@]}"

# Сбор файлов
echo "[3] Collecting files..."
declare -A SEEN
FILES=()
for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        while IFS= read -r -d '' f; do
            ext="${f##*.}"; ext="${ext,,}"
            if [[ "$ext" == "pdf" || "$ext" == "djvu" || "$ext" == "djv" ]]; then
                [[ -z "${SEEN["$f"]:-}" ]] && { SEEN["$f"]=1; FILES+=("$f"); }
            fi
        done < <(find "$item" -type f \( -iname "*.pdf" -o -iname "*.djvu" -o -iname "*.djv" \) -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"; ext="${ext,,}"
        if [[ "$ext" == "pdf" || "$ext" == "djvu" || "$ext" == "djv" ]]; then
            [[ -z "${SEEN["$item"]:-}" ]] && { SEEN["$item"]=1; FILES+=("$item"); }
        fi
    fi
done
[[ ${#FILES[@]} -eq 0 ]] && { [[ "$DEBUG" -eq 0 ]] && notify-send "📄 Экспорт страниц" "⚠️ Файлы не найдены" -i dialog-warning; exit 0; }
[[ "$DEBUG" -eq 0 ]] && notify-send "📄 Экспорт страниц" "🔄 Обработка ${#FILES[@]} файлов..." -i process-working

SUCCESS=0; FAILED=0

# === ФУНКЦИЯ: Определение количества страниц в DjVu ===
count_djvu_pages() {
    local file="$1"
    local page_count
    # ✅ ПРАВИЛЬНЫЙ синтаксис: -e 'n'
    page_count=$(djvused -e 'n' "$file" 2>&1 | grep -oE '^[0-9]+$' | head -1)
    
    # Фоллбэк: бинарный поиск, если djvused не сработал
    if [[ -z "$page_count" || ! "$page_count" =~ ^[0-9]+$ || "$page_count" -le 0 ]]; then
        echo "⚠️  djvused failed, using binary search..." >&2
        local low=1 high=5000 mid result=0
        if ! ddjvu -format=ppm -page=1 "$file" - 2>/dev/null | convert - -size 1x1 null: 2>/dev/null; then
            echo "0"; return
        fi
        while [[ $low -le $high ]]; do
            mid=$(( (low + high) / 2 ))
            if ddjvu -format=ppm -page="$mid" "$file" - 2>/dev/null | convert - -size 1x1 null: 2>/dev/null; then
                result=$mid; low=$((mid + 1))
            else
                high=$((mid - 1))
            fi
        done
        page_count=$result
    fi
    echo "$page_count"
}

echo "[4] Processing..."
for file in "${FILES[@]}"; do
    echo ""; echo "═══════════════════════════════════════"
    echo "File: $file"
    echo "═══════════════════════════════════════"
    
    DIR="$(dirname "$file")"; BASE="$(basename "$file")"; NAME="${BASE%.*}"
    OUTDIR="$DIR/$NAME"
    mkdir -p "$OUTDIR" || { echo "❌ Cannot create $OUTDIR"; ((FAILED++)); continue; }
    
    EXT="${BASE##*.}"; EXT="${EXT,,}"
    
    if [[ "$EXT" == "pdf" ]]; then
        echo "📄 PDF → pdftoppm"
        if pdftoppm -png "$file" "$OUTDIR/Page" 2>&1; then
            shopt -s nullglob
            for p in "$OUTDIR"/Page-*.png; do
                num="${p##*-}"; num="${num%.png}"
                mv "$p" "$OUTDIR/Page_${num}.png"
            done
            echo "✅ Done"; ((SUCCESS++)) || true
        else
            echo "❌ Failed"; ((FAILED++))
        fi
        
    elif [[ "$EXT" == "djvu" || "$EXT" == "djv" ]]; then
        echo "📖 DjVu → ddjvu + convert"
        pushd "$OUTDIR" > /dev/null || { ((FAILED++)); continue; }
        
        echo "  🔍 Auto-detecting page count..."
        PAGE_COUNT=$(count_djvu_pages "$file")
        
        if [[ -z "$PAGE_COUNT" || ! "$PAGE_COUNT" =~ ^[0-9]+$ || "$PAGE_COUNT" -le 0 ]]; then
            echo "  ❌ Could not determine page count"
            popd > /dev/null; ((FAILED++)); continue
        fi
        echo "  ✅ Pages detected: $PAGE_COUNT"
        
        if [[ "$PARALLEL_JOBS" -le 0 ]]; then
            MAX_JOBS=$(nproc 2>/dev/null || echo 4)
            [[ "$MAX_JOBS" -gt 8 ]] && MAX_JOBS=8
        else
            MAX_JOBS="$PARALLEL_JOBS"
        fi
        echo "  Parallel jobs: $MAX_JOBS"
        
        min_width=3
        padding_width=$(( ${#PAGE_COUNT} > min_width ? ${#PAGE_COUNT} : min_width ))
        
        echo "  Extracting pages..."
        declare -a PIDS=()
        for ((page=1; page<=PAGE_COUNT; page++)); do
            printf -v out_name "Page_%0${padding_width}d.png" "$page"
            {
                ddjvu -format=ppm -page="$page" "$file" - 2>/dev/null | \
                convert - "$out_name" 2>/dev/null && [[ -s "$out_name" ]]
            } &
            PIDS+=($!)
            if [[ ${#PIDS[@]} -ge $MAX_JOBS ]]; then
                wait "${PIDS[0]}" 2>/dev/null
                PIDS=("${PIDS[@]:1}")
            fi
        done
        for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null; done
        unset PIDS
        
        extracted=0
        for ((page=1; page<=PAGE_COUNT; page++)); do
            printf -v out_name "Page_%0${padding_width}d.png" "$page"
            [[ -s "$out_name" ]] && ((extracted++))
        done
        popd > /dev/null
        echo "  Result: $extracted / $PAGE_COUNT"
        
        if [[ $extracted -gt 0 ]]; then
            ((SUCCESS++)) || true
        else
            echo "  ❌ No pages"
            ((FAILED++))
        fi
    fi
done

# Итоги
echo ""; echo "=========================================="
echo "✅ Success: $SUCCESS | ❌ Failed: $FAILED"
echo "Log: /tmp/dc_extract_debug.log"
[[ "$DEBUG" -eq 0 ]] && notify-send "📄 Экспорт страниц" "✅ Успешно: $SUCCESS$([[ $FAILED -gt 0 ]] && echo $'\n'"❌ Ошибки: $FAILED")" -i image-x-generic
[[ "$DEBUG" -eq 1 ]] && { echo; read -r; }
