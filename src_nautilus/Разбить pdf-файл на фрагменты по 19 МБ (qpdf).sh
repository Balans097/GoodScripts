#!/usr/bin/env bash
# Nautilus Script: Надёжное разделение PDF ≤ 19 МБ
# Зависимости: qpdf (≥10.0), coreutils, libnotify-bin

MAX_SIZE=$((19 * 1024 * 1024))
LOG="/tmp/nautilus_pdf_split_$(date +%s).log"
: > "$LOG"

log() { printf "[%s] %s\n" "$(date +%T)" "$*" >> "$LOG"; }

process_pdf() {
    local file="$1"
    local dir base size tmpdir
    dir=$(dirname "$file")
    base=$(basename "$file" .pdf)
    size=$(stat -c%s "$file" 2>/dev/null)
    [ -z "$size" ] && { log "ERR: Невозможно прочитать $file"; return 1; }

    [ "$size" -le "$MAX_SIZE" ] && { log "OK: $file уже ≤ 19 МБ"; return 0; }

    tmpdir=$(mktemp -d) || { log "ERR: mktemp failed"; return 1; }

    # 1. Разбиваем на страницы нативным qpdf (надёжнее poppler)
    if ! qpdf "$file" --split-pages "$tmpdir/p.pdf" 2>>"$LOG"; then
        log "ERR: qpdf не смог разделить $file"
        return 1
    fi

    local pages=("$tmpdir"/p-*.pdf)
    if [ ${#pages[@]} -eq 0 ]; then
        log "ERR: Страницы не извлечены из $file"
        return 1
    fi

    local chunk=() part=1 est_size=0
    for page in "${pages[@]}"; do
        local psize
        psize=$(stat -c%s "$page" 2>/dev/null) || psize=0
        chunk+=("$page")
        ((est_size += psize))

        # Если оценка превысила лимит → проверяем реальным слиянием
        if [ "$est_size" -gt "$MAX_SIZE" ]; then
            local verify="$tmpdir/_v.pdf"
            if qpdf --empty --pages "${chunk[@]}" -- "$verify" 2>>"$LOG"; then
                local actual
                actual=$(stat -c%s "$verify" 2>/dev/null) || actual=0

                if [ "$actual" -gt "$MAX_SIZE" ]; then
                    # Убираем последнюю страницу, вызвавшую переполнение
                    unset 'chunk[-1]'
                    if [ ${#chunk[@]} -gt 0 ]; then
                        qpdf --empty --pages "${chunk[@]}" -- "${dir}/${base}_part_${part}.pdf" 2>>"$LOG"
                        ((part++))
                        chunk=("$page")
                        est_size=$(stat -c%s "$page" 2>/dev/null) || est_size=0
                    else
                        log "WARN: Отдельная страница > 19 МБ: ${page##*/}"
                        chunk=()
                        est_size=0
                    fi
                fi
            else
                log "ERR: Сбой слияния в $file"
                unset 'chunk[-1]'
                est_size=$((est_size - psize))
            fi
        fi
    done

    # Сохраняем остаток
    if [ ${#chunk[@]} -gt 0 ]; then
        qpdf --empty --pages "${chunk[@]}" -- "${dir}/${base}_part_${part}.pdf" 2>>"$LOG"
    fi

    # Финальная проверка: файлы действительно созданы?
    local count
    count=$(ls -1 "${dir}/${base}_part_"*.pdf 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        log "FAIL: Выходные файлы не созданы для $file"
    else
        log "SUCCESS: $file → ${count} фрагментов"
    fi
}

# ── Инициализация ──────────────────────────────────────────────
command -v qpdf >/dev/null || { notify-send "PDF Split" "Установите пакет qpdf"; exit 1; }

for arg in "$@"; do
    if [[ -f "$arg" && "${arg,,}" == *.pdf ]]; then
        process_pdf "$arg"
    elif [[ -d "$arg" ]]; then
        while IFS= read -r -d '' f; do
            process_pdf "$f"
        done < <(find "$arg" -type f -iname "*.pdf" -print0)
    fi
done

# ── Итоговое уведомление ───────────────────────────────────────
if [ -f "$LOG" ]; then
    local ok=$(grep -c "SUCCESS" "$LOG" 2>/dev/null) || ok=0
    local fail=$(grep -c "ERR\|FAIL" "$LOG" 2>/dev/null) || fail=0
    notify-send "PDF Split" "✅ Успешно: $ok | ❌ Ошибки: $fail\nЛог: $LOG" 2>/dev/null
fi