#!/usr/bin/env bash
set -euo pipefail

# 1. Проверка зависимости
if ! command -v img2pdf &>/dev/null; then
    notify-send "🖼️ Изображения → PDF" "❌ Утилита img2pdf не найдена.\nУстановите: sudo dnf install img2pdf" -i dialog-error
    exit 1
fi

# 2. Получение выделенных файлов от Nautilus
if [[ -z "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    notify-send "🖼️ Изображения → PDF" "⚠️ Не выделено ни одного файла" -i dialog-warning
    exit 0
fi

# 3. Парсинг списка в массив
mapfile -t SELECTED <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

# 4. Фильтрация только графических файлов
IMAGES=()
for file in "${SELECTED[@]}"; do
    [[ -z "$file" || ! -f "$file" ]] && continue
    ext="${file##*.}"
    ext="${ext,,}" # приводим к нижнему регистру
    case "$ext" in
        jpg|jpeg|png|bmp|tiff|tif|webp|gif|svg|tga|ppm|pgm|pbm|pnm|ico|heic|heif)
            IMAGES+=("$file")
            ;;
    esac
done

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    notify-send "🖼️ Изображения → PDF" "⚠️ Среди выделенных файлов нет поддерживаемых изображений" -i dialog-warning
    exit 0
fi

# 5. Сортировка по имени (естественный порядок: img1, img2, img10)
mapfile -t IMAGES < <(printf '%s\n' "${IMAGES[@]}" | sort -V)

# 6. Формирование пути к выходному PDF (в той же папке, что и изображения)
TARGET_DIR="$(dirname "${IMAGES[0]}")"
OUTPUT_FILE="$TARGET_DIR/merged_$(date +%Y%m%d_%H%M%S).pdf"

# 7. Конвертация
# Примечание: img2pdf по умолчанию сохраняет исходные размеры (без потерь).
# Если нужно принудительно вписать в A4, замените команду ниже на:
# img2pdf --pagesize A4 --fit into "${IMAGES[@]}" -o "$OUTPUT_FILE"
if img2pdf "${IMAGES[@]}" -o "$OUTPUT_FILE" 2>/dev/null; then
    notify-send "🖼️ Изображения → PDF" "✅ Готово!\n📄 $(basename "$OUTPUT_FILE")\n📊 Страниц: ${#IMAGES[@]}" -i x-office-document
else
    notify-send "🖼️ Изображения → PDF" "❌ Ошибка при создании PDF.\nВозможно, один из файлов повреждён или имеет неподдерживаемый профиль." -i dialog-error
    rm -f "$OUTPUT_FILE" 2>/dev/null
fi
