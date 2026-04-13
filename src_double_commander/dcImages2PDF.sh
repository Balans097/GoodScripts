#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Конвертация выделенных изображений в PDF для Double Commander
# Поддерживает: файлы, папки, смешанное выделение, рекурсию
# Вывод: рядом с верхней папкой в иерархии (или рядом с файлами)
# Параметр панели инструментов: %L
# ============================================================

# 1. Проверка зависимости
if ! command -v img2pdf &>/dev/null; then
    notify-send "🖼️ Изображения → PDF" \
        "❌ Утилита img2pdf не найдена.\nУстановите: sudo dnf install img2pdf" \
        -i dialog-error
    exit 1
fi

# 2. Получение списка файлов из параметра %L
if [[ -z "${1:-}" || ! -f "$1" ]]; then
    notify-send "🖼️ Изображения → PDF" \
        "⚠️ Не передан список файлов.\nИспользуйте параметр %L в настройках кнопки." \
        -i dialog-warning
    exit 1
fi

# 3. Чтение списка в массив, фильтрация пустых строк и кавычек
mapfile -t SELECTED < <(sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$1" | grep -v '^$')
[[ ${#SELECTED[@]} -eq 0 ]] && exit 0

# 4. Сбор всех изображений с дедупликацией
declare -A SEEN_FILES
IMAGES=()
DIRS_SELECTED=()

for item in "${SELECTED[@]}"; do
    if [[ -d "$item" ]]; then
        DIRS_SELECTED+=("$item")
        while IFS= read -r -d '' file; do
            [[ -z "${SEEN_FILES["$file"]:-}" ]] && {
                SEEN_FILES["$file"]=1
                IMAGES+=("$file")
            }
        done < <(find "$item" -type f \( \
            -iname "*.jpg" -o -iname "*.jpeg" -o \
            -iname "*.png" -o -iname "*.bmp" -o \
            -iname "*.tiff" -o -iname "*.tif" -o \
            -iname "*.webp" -o -iname "*.gif" -o \
            -iname "*.svg" -o -iname "*.tga" -o \
            -iname "*.ppm" -o -iname "*.pgm" -o \
            -iname "*.pbm" -o -iname "*.pnm" -o \
            -iname "*.ico" -o -iname "*.heic" -o \
            -iname "*.heif" \) -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
        ext="${item##*.}"
        ext="${ext,,}"
        case "$ext" in
            jpg|jpeg|png|bmp|tiff|tif|webp|gif|svg|tga|ppm|pgm|pbm|pnm|ico|heic|heif)
                [[ -z "${SEEN_FILES["$item"]:-}" ]] && {
                    SEEN_FILES["$item"]=1
                    IMAGES+=("$item")
                }
                ;;
        esac
    fi
done

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    notify-send "🖼️ Изображения → PDF" \
        "⚠️ Изображения не найдены в выбранных объектах" \
        -i dialog-warning
    exit 0
fi

# 5. Сортировка по имени (естественный порядок: img1, img2, img10)
mapfile -t IMAGES < <(printf '%s\n' "${IMAGES[@]}" | sort -V)

# 6. Определение целевой директории
# Находим "верхнюю" папку (самый короткий путь среди выделенных директорий)
TOP_FOLDER=""
for dir in "${DIRS_SELECTED[@]}"; do
    if [[ -z "$TOP_FOLDER" ]] || [[ ${#dir} -lt ${#TOP_FOLDER} ]]; then
        TOP_FOLDER="$dir"
    fi
done

if [[ -n "$TOP_FOLDER" ]]; then
    # Сохраняем рядом с верхней папкой (в её родительской директории)
    TARGET_DIR="$(dirname "$TOP_FOLDER")"
else
    # Если папки не выделены, сохраняем в папке первого изображения
    TARGET_DIR="$(dirname "${IMAGES[0]}")"
fi

# Проверка прав на запись
if [[ ! -w "$TARGET_DIR" ]]; then
    notify-send "🖼️ Изображения → PDF" \
        "❌ Нет прав на запись в:\n$TARGET_DIR" \
        -i dialog-error
    exit 1
fi

OUTPUT_FILE="$TARGET_DIR/merged_$(date +%Y%m%d_%H%M%S).pdf"

# 7. Конвертация
if img2pdf "${IMAGES[@]}" -o "$OUTPUT_FILE" 2>/dev/null; then
    notify-send "🖼️ Изображения → PDF" \
        "✅ Готово!\n📄 $(basename "$OUTPUT_FILE")\n📊 Страниц: ${#IMAGES[@]}" \
        -i x-office-document
else
    notify-send "🖼️ Изображения → PDF" \
        "❌ Ошибка при создании PDF.\nВозможно, один из файлов повреждён." \
        -i dialog-error
    rm -f "$OUTPUT_FILE" 2>/dev/null
    exit 1
fi