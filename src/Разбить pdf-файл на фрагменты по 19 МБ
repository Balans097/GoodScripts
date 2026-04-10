#!/usr/bin/env bash
# Nautilus Script: Разделяет PDF-файлы на части ≤ 19 МБ
# Если файл уже ≤ 19 МБ, он остаётся без изменений.

MAX_SIZE=$((14 * 1024 * 1024)) # 14 МБ в байтах (в результате ~19 МБ каждый)

# Проверка зависимостей
for cmd in pdfseparate pdfunite stat; do
    command -v "$cmd" >/dev/null 2>&1 || {
        notify-send "Ошибка" "Установите пакет poppler-utils" 2>/dev/null
        exit 1
    }
done

process_pdf() {
    local file="$1"
    local dir base size tmpdir pages chunk=() chunk_size=0 part=1

    dir=$(dirname "$file")
    base=$(basename "$file" .pdf)
    size=$(stat -c%s "$file" 2>/dev/null) || return 1

    # Пропускаем, если файл уже укладывается в лимит
    if [ "$size" -le "$MAX_SIZE" ]; then
        return 0
    fi

    # Создаём временную директорию и разбиваем на страницы
    tmpdir=$(mktemp -d) || return 1
    pdfseparate "$file" "$tmpdir/page_%04d.pdf" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }

    # Получаем список страниц (отсортирован благодаря %04d)
    pages=("$tmpdir"/page_*.pdf)
    [ ${#pages[@]} -eq 0 ] && { rm -rf "$tmpdir"; return 1; }

    for page in "${pages[@]}"; do
        local psize
        psize=$(stat -c%s "$page")
        
        # Если добавление страницы превысит лимит, сохраняем текущий фрагмент
        if [ $((chunk_size + psize)) -gt $MAX_SIZE ] && [ ${#chunk[@]} -gt 0 ]; then
            pdfunite "${chunk[@]}" "${dir}/${base}_part_${part}.pdf" 2>/dev/null
            ((part++))
            chunk=("$page")
            chunk_size=$psize
        else
            chunk+=("$page")
            ((chunk_size += psize))
        fi
    done

    # Сохраняем последний фрагмент
    [ ${#chunk[@]} -gt 0 ] && pdfunite "${chunk[@]}" "${dir}/${base}_part_${part}.pdf" 2>/dev/null
    
    # Очистка временных файлов
    rm -rf "$tmpdir"
}

# Обработка аргументов Nautilus (файлы и папки)
for arg in "$@"; do
    if [ -f "$arg" ] && [[ "${arg,,}" == *.pdf ]]; then
        process_pdf "$arg"
    elif [ -d "$arg" ]; then
        while IFS= read -r -d '' pdf; do
            process_pdf "$pdf"
        done < <(find "$arg" -type f -iname "*.pdf" -print0)
    fi
done

# Уведомление о завершении
notify-send "PDF Splitting" "Готово. Файлы > 19 МБ разделены на части." 2>/dev/null
