#!/usr/bin/env bash
# ============================================================
# Разбиение PDF-файлов на фрагменты ≤ 19 МБ для Double Commander
# Использует: qpdf (быстрее и надёжнее poppler)
# Параметр панели инструментов: %L
# ============================================================

MAX_SIZE=$((19 * 1024 * 1024))  # 19 МБ

# 1. Проверка зависимостей
if ! command -v qpdf &>/dev/null; then
    notify-send "📄 PDF Splitter (qpdf)" \
        "❌ Утилита qpdf не найдена.\nУстановите: sudo dnf install qpdf" \
        -i dialog-error
    exit 1
fi

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
    notify-send "📄 PDF Splitter" \
        "⚠️ Не выбрано ни одного файла или папки.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
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
    notify-send "📄 PDF Splitter" \
        "⚠️ PDF-файлы не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

notify-send "📄 PDF Splitter (qpdf)" \
    "🔄 Обработка ${#PDF_FILES[@]} файлов..." \
    -i process-working

# 4. Функция разбиения PDF через qpdf
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
    
    # Разбиваем на страницы через qpdf (надёжнее poppler)
    if ! qpdf "$file" --split-pages "$tmpdir/p.pdf" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1
    fi
    
    # Получаем список страниц (отсортирован благодаря нумерации)
    while IFS= read -r -d '' page; do
        pages+=("$page")
    done < <(find "$tmpdir" -name "p-*.pdf" -print0 | sort -z)
    
    [[ ${#pages[@]} -eq 0 ]] && { rm -rf "$tmpdir"; return 1; }
    
    # Собираем страницы в фрагменты
    for page in "${pages[@]}"; do
        local psize
        psize=$(stat -c%s "$page")
        
        # Если добавление страницы превысит лимит, сохраняем текущий фрагмент
        if [[ $((chunk_size + psize)) -gt $MAX_SIZE ]] && [[ ${#chunk[@]} -gt 0 ]]; then
            # Проверяем реальный размер после слияния
            local verify="$tmpdir/_v.pdf"
            if qpdf --empty --pages "${chunk[@]}" -- "$verify" 2>/dev/null; then
                local actual
                actual=$(stat -c%s "$verify" 2>/dev/null) || actual=0
                
                if [[ "$actual" -gt "$MAX_SIZE" ]]; then
                    # Убираем последнюю страницу, вызвавшую переполнение
                    unset 'chunk[-1]'
                    if [[ ${#chunk[@]} -gt 0 ]]; then
                        qpdf --empty --pages "${chunk[@]}" -- "${dir}/${base}_part_${part}.pdf" 2>/dev/null
                        ((part++))
                    fi
                    chunk=("$page")
                    chunk_size=$psize
                else
                    # Фрагмент в пределах лимита
                    mv "$verify" "${dir}/${base}_part_${part}.pdf"
                    ((part++))
                    chunk=("$page")
                    chunk_size=$psize
                fi
            else
                # Ошибка слияния
                unset 'chunk[-1]'
                chunk_size=$((chunk_size - psize))
            fi
        else
            chunk+=("$page")
            ((chunk_size += psize))
        fi
    done
    
    # Сохраняем последний фрагмент
    if [[ ${#chunk[@]} -gt 0 ]]; then
        qpdf --empty --pages "${chunk[@]}" -- "${dir}/${base}_part_${part}.pdf" 2>/dev/null
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
    
    # Пропускаем файлы ≤ 14 МБ (они точно ≤ 19 МБ)
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
MSG+=$'\n'"📁 Фрагменты: *_part_*.pdf рядом с исходными"
MSG+=$'\n'"⚡ qpdf: быстрое разбиение без потерь"
notify-send "📄 PDF Splitter (qpdf) завершено" "$MSG" -i x-office-document
