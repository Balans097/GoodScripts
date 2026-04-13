#!/usr/bin/env bash
# ============================================================
# Разбиение PDF-файлов на фрагменты ≤ 19 МБ для Double Commander
# Поддерживает: файлы, папки, смешанное выделение, рекурсию
# Параметр панели инструментов: %L
# ============================================================

MAX_SIZE=$((14 * 1024 * 1024))  # 14 МБ в байтах (результат ~19 МБ)

# 1. Проверка зависимостей
for cmd in pdfseparate pdfunite stat; do
    if ! command -v "$cmd" &>/dev/null; then
        notify-send "📄 PDF Splitter" "❌ Утилита $cmd не найдена.\nУстановите: sudo dnf install poppler-utils" -i dialog-error
        exit 1
    fi
done

# 2. Получение списка выделенных объектов из %L
INPUT_PATHS=()
if [[ -n "${1:-}" && -f "$1" ]]; then
    # Читаем из временного файла %L
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//\"/}"  # убираем кавычки
        line="$(echo "$line" | xargs)"  # убираем пробелы
        [[ -n "$line" ]] && INPUT_PATHS+=("$line")
    done < "$1"
elif [[ $# -gt 0 ]]; then
    INPUT_PATHS=("$@")
else
    notify-send "📄 PDF Splitter" "⚠️ Не выбрано ни одного файла или папки" -i dialog-warning
    exit 0
fi
[[ ${#INPUT_PATHS[@]} -eq 0 ]] && exit 0

# 3. Сбор всех PDF файлов с дедупликацией
declare -A SEEN_FILES
PDF_FILES=()
SKIPPED=0

for item in "${INPUT_PATHS[@]}"; do
    if [[ -d "$item" ]]; then
        # Рекурсивный поиск .pdf (регистронезависимо)
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                PDF_FILES+=("$f")
            }
        done < <(find "$item" -type f -iname "*.pdf" -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        if [[ "${ext,,}" == "pdf" ]]; then
            [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                SEEN_FILES["$item"]=1
                PDF_FILES+=("$item")
            }
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

if [[ ${#PDF_FILES[@]} -eq 0 ]]; then
    notify-send "📄 PDF Splitter" "⚠️ PDF-файлы не найдены в выбранных объектах" -i dialog-warning
    exit 0
fi

notify-send "📄 PDF Splitter" "🔄 Обработка ${#PDF_FILES[@]} файлов..." -i process-working

# 4. Функция разбиения PDF
process_pdf() {
    local file="$1"
    local dir base size tmpdir pages=() chunk=() chunk_size=0 part=1
    
    dir="$(dirname "$file")"
    base="$(basename "$file" .pdf)"
    
    # Получаем размер файла
    size=$(stat -c%s "$file" 2>/dev/null) || return 1
    
    # Пропускаем, если файл уже укладывается в лимит
    if [[ "$size" -le "$MAX_SIZE" ]]; then
        return 0
    fi
    
    # Создаём временную директорию
    tmpdir=$(mktemp -d) || return 1
    
    # Разбиваем на страницы
    if ! pdfseparate "$file" "$tmpdir/page_%04d.pdf" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1
    fi
    
    # Получаем список страниц (отсортирован благодаря %04d)
    while IFS= read -r -d '' page; do
        pages+=("$page")
    done < <(find "$tmpdir" -name "page_*.pdf" -print0 | sort -z)
    
    [[ ${#pages[@]} -eq 0 ]] && { rm -rf "$tmpdir"; return 1; }
    
    # Собираем страницы в фрагменты
    for page in "${pages[@]}"; do
        local psize
        psize=$(stat -c%s "$page")
        
        # Если добавление страницы превысит лимит, сохраняем текущий фрагмент
        if [[ $((chunk_size + psize)) -gt $MAX_SIZE ]] && [[ ${#chunk[@]} -gt 0 ]]; then
            if ! pdfunite "${chunk[@]}" "${dir}/${base}_part_${part}.pdf" 2>/dev/null; then
                rm -rf "$tmpdir"
                return 1
            fi
            ((part++))
            chunk=("$page")
            chunk_size=$psize
        else
            chunk+=("$page")
            ((chunk_size += psize))
        fi
    done
    
    # Сохраняем последний фрагмент
    if [[ ${#chunk[@]} -gt 0 ]]; then
        if ! pdfunite "${chunk[@]}" "${dir}/${base}_part_${part}.pdf" 2>/dev/null; then
            rm -rf "$tmpdir"
            return 1
        fi
    fi
    
    # Очистка временных файлов
    rm -rf "$tmpdir"
    return 0
}

# 5. Обработка всех PDF файлов
SUCCESS=0
FAILED=0
SKIPPED_SMALL=0

for pdf in "${PDF_FILES[@]}"; do
    size=$(stat -c%s "$pdf" 2>/dev/null || echo 0)
    
    # Пропускаем файлы ≤ 14 МБ (они точно укладываются в 19 МБ)
    if [[ "$size" -le "$MAX_SIZE" ]]; then
        ((SKIPPED_SMALL++))
        continue
    fi
    
    if process_pdf "$pdf"; then
        ((SUCCESS++))
    else
        ((FAILED++))
    fi
done

# 6. Итоговое уведомление
MSG="✅ Разбито: $SUCCESS"
(( FAILED > 0 )) && MSG+=$'\n'"❌ Ошибки: $FAILED"
(( SKIPPED_SMALL > 0 )) && MSG+=$'\n'"⏭️ Пропущено (≤ 14 МБ): $SKIPPED_SMALL"
MSG+=$'\n'"📁 Фрагменты сохранены рядом с исходными файлами"
notify-send "📄 PDF Splitter завершено" "$MSG" -i x-office-document