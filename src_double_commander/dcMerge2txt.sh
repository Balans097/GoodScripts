#!/usr/bin/env bash
set -uo pipefail
# ============================================================
# Рекурсивное объединение текстовых/исходных файлов в один .txt
# Для Double Commander (параметр панели инструментов: %L)
# ============================================================

# 📜 СПИСОК ПОДДЕРЖИВАЕМЫХ РАСШИРЕНИЙ (разделитель "|")
# Регистр не важен: скрипт сам приведёт расширения к нижнему регистру.
# Добавляйте или удаляйте типы через символ |
SUPPORTED_EXT="txt|html|htm|md|cfg|ini|conf|yaml|yml|json|xml|toml|env|gitignore|dockerignore|c|cpp|cc|cxx|h|hpp|hxx|java|py|js|ts|jsx|tsx|go|rs|swift|nim|nimble|cs|php|rb|sh|bash|zsh|lua|pl|sql|make|cmake|gradle|kts|kt|dart|ex|exs|log|properties|lock"

# 1. Получение списка файлов из параметра %L
LIST_FILE="${1:-}"
if [[ -z "$LIST_FILE" || ! -f "$LIST_FILE" ]]; then
    notify-send "📄 Merge Text" \
        "⚠️ Не передан список файлов.\nВ параметрах кнопки DC укажите: %L" \
        -i dialog-warning
    exit 0
fi

# Очистка от кавычек, \r и пустых строк (стабильно для DC)
mapfile -t SELECTED < <(tr -d '\r' < "$LIST_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 2. Определение целевой директории (рядом с самой верхней папкой выделения)
TOP_FOLDER=""
for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        if [[ -z "$TOP_FOLDER" ]] || [[ ${#item} -lt ${#TOP_FOLDER} ]]; then
            TOP_FOLDER="$item"
        fi
    fi
done

if [[ -n "$TOP_FOLDER" ]]; then
    TARGET_DIR="$(dirname "$TOP_FOLDER")"
else
    TARGET_DIR="$(dirname "${SELECTED[0]}")"
fi
[[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]] && TARGET_DIR="$PWD"

OUT_FILE="$TARGET_DIR/merged_code_$(date +%Y%m%d_%H%M%S).txt"

# 3. Сбор файлов с дедупликацией (защита от дублей при пересечении папок)
declare -A SEEN_FILES
RAW_FILES=()

for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        while IFS= read -r -d '' f; do
            [[ -z "${SEEN_FILES["$f"]:-}" ]] && {
                SEEN_FILES["$f"]=1
                RAW_FILES+=("$f")
            }
        done < <(find "$item" -type f -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
            SEEN_FILES["$item"]=1
            RAW_FILES+=("$item")
        }
    fi
done

# Естественная сортировка (img1, img2, img10 / main.c, utils.c)
mapfile -t RAW_FILES < <(printf '%s\n' "${RAW_FILES[@]}" | sort -V)

# 4. Фильтрация по расширениям и слияние
> "$OUT_FILE"
PROCESSED=0
SKIPPED=0

notify-send "📄 Merge Text" "🔄 Анализ и объединение ${#RAW_FILES[@]} файлов..." -i process-working

for filepath in "${RAW_FILES[@]}"; do
    # Исключаем сам выходной файл (защита от зацикливания при повторном запуске)
    [[ "$(realpath "$filepath" 2>/dev/null)" == "$(realpath "$OUT_FILE" 2>/dev/null)" ]] && continue

    ext="${filepath##*.}"
    ext="${ext,,}" # приводим к нижнему регистру

    # Проверка попадания в белый список расширений
    if [[ "$ext" =~ ^($SUPPORTED_EXT)$ ]]; then
        {
            echo ""
            echo "========================================================"
            echo "ФАЙЛ: $filepath"
            echo "========================================================"
            cat "$filepath" 2>/dev/null
            echo ""
        } >> "$OUT_FILE"
        PROCESSED=$((PROCESSED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

# 5. Итоговое уведомление
if [[ $PROCESSED -eq 0 ]]; then
    notify-send "📄 Merge Text" \
        "⚠️ Файлы с указанными расширениями не найдены" \
        -i dialog-warning
    rm -f "$OUT_FILE"
else
    MSG="✅ Готово!\n📄 $(basename "$OUT_FILE")"
    MSG+=$'\n'"📊 Объединено: $PROCESSED файлов"
    [[ $SKIPPED -gt 0 ]] && MSG+=$'\n'"⏭️ Пропущено (другие типы): $SKIPPED"
    notify-send "📄 Merge Text" "$MSG" -i x-office-document
fi