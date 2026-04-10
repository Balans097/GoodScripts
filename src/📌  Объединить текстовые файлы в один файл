#!/usr/bin/env bash
# Nautilus Script: Рекурсивное объединение текстовых файлов в один .txt
# Поддерживает: txt, md, c, cpp, hpp, fb2, json, xml, js, yaml, log и любые файлы ч текстом внутри 

# Проверка зависимости
if ! command -v file &>/dev/null; then
    notify-send "📄 Merge Text" "❌ Утилита 'file' не найдена.\nУстановите: sudo dnf install file" -i dialog-error
    exit 1
fi

# Получение выделенных путей от Nautilus
if [[ -z "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    notify-send "📄 Merge Text" "⚠️ Не выделено ни одного файла или папки" -i dialog-warning
    exit 0
fi

# Парсинг списка в массив
mapfile -t SELECTED <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

# Определение директории для сохранения результата
FIRST="${SELECTED[0]}"
if [[ -d "$FIRST" ]]; then
    OUT_DIR="$FIRST"
else
    OUT_DIR="$(dirname "$FIRST")"
fi

# Уникальное имя выходного файла
OUT_FILE="$OUT_DIR/merged_$(date +%Y%m%d_%H%M%S).txt"

# Счётчики
TOTAL=0
PROCESSED=0
SKIPPED=0

# Инициализация файла
> "$OUT_FILE"

# Обработка каждого выбранного объекта
for item in "${SELECTED[@]}"; do
    [[ -z "$item" ]] && continue
    
    # Рекурсивный поиск файлов, безопасная сортировка
    while IFS= read -r -d '' filepath; do
        TOTAL=$((TOTAL + 1))

        # Исключаем сам выходной файл (защита от зацикливания)
        [[ "$(realpath "$filepath" 2>/dev/null)" == "$(realpath "$OUT_FILE" 2>/dev/null)" ]] && continue

        # Определение MIME-типа
        MIME=$(file --mime-type -b "$filepath" 2>/dev/null)

        # Фильтр текстовых/код-файлов
        if [[ "$MIME" == text/* ]] || \
           [[ "$MIME" == application/json ]] || \
           [[ "$MIME" == application/xml ]] || \
           [[ "$MIME" == application/javascript ]] || \
           [[ "$MIME" == application/x-empty ]]; then
           
           # Добавление заголовка и содержимого
           {
               echo ""
               echo "========================================================"
               echo "ФАЙЛ: $filepath"
               echo "ТИП:  $MIME"
               echo "========================================================"
               cat "$filepath" 2>/dev/null
               echo ""
           } >> "$OUT_FILE"
           
           PROCESSED=$((PROCESSED + 1))
       else
           SKIPPED=$((SKIPPED + 1))
       fi
    done < <(find "$item" -type f -print0 2>/dev/null | sort -z)
done

# Итоговое уведомление
if (( TOTAL == 0 )); then
    notify-send "📄 Merge Text" "⚠️ Файлы не найдены в выбранных объектах" -i dialog-warning
    rm -f "$OUT_FILE"
else
    MSG="✅ Готово!\n📄 $(basename "$OUT_FILE")"
    MSG+=$'\n'"📊 Обработано: $PROCESSED"
    (( SKIPPED > 0 )) && MSG+=$'\n'"⏭️ Пропущено (бинарные): $SKIPPED"
    notify-send "📄 Merge Text" "$MSG" -i x-office-document
fi
