
# 🐧 GNOME Scripts: File Automation Toolkit

> A collection of Bash scripts for the Nautilus (GNOME Files) context menu, turning routine document and media operations into a single click.

## 🚀 Why This Improves Your GNOME/Linux Workflow

GNOME embraces minimalism: a clean UI, fewer distractions, and a focus on content. However, Nautilus intentionally lacks built-in batch conversion or file manipulation tools. These scripts bridge that gap while staying true to the GNOME philosophy:

- 🔹 **Seamless Context Integration:** Everything is accessible via `Right Click → Scripts`. No terminal, no heavy GUI apps, no drag-and-drop workflows.
- 🔹 **Background Processing + Native Notifications:** Scripts run silently. Progress and results are delivered via GNOME Shell's standard notification system.
- 🔹 **Batch Processing Out-of-the-Box:** Select a folder or dozens of files → run a script → get results instantly without manual iteration.
- 🔹 **100% Local & Private:** All operations happen on your machine. No cloud uploads, telemetry, watermarks, or file size/quantity limits.
- 🔹 **Transparent & Customizable:** Plain Bash + battle-tested CLI utilities. Read, tweak, or extend any script to suit your exact needs.
- 🔹 **Built for Productivity:** Saves hours for researchers, writers, developers, and anyone who regularly handles scans, documents, logs, or media.

## 📦 What's Inside?
Some examples

| Script | Description | Key Dependencies |
|--------|-------------|------------------|
| `dav-файлы → mp4-файлы.sh` | Converts DVR video (`.dav`) to MP4 without re-encoding | `ffmpeg` |
| `djvu → pdf.sh` | Batch converts `.djvu`/`.djv` to PDF (supports files & folders) | `djvulibre` (`ddjvu`) |
| `Документы → PDF.sh` | Merges & converts docs (Word, Excel, ODT, TXT, EPUB, HTML, etc.) into a single PDF | `libreoffice`, `poppler-utils` |
| `Изображения → PDF.sh` | Creates PDF from images preserving original dimensions | `img2pdf` |
| `Изображения → PDF (A4).sh` | Same as above, but auto-scales to A4 paper size | `img2pdf` |
| `Объединить текстовые файлы в один файл.sh` | Recursively merges text/code files into a single `.txt` with clear dividers | `file` |
| `Разбить pdf-файл на фрагменты по 19 МБ.sh` | Splits large PDFs into ≤19 MB chunks (using `poppler-utils`) | `poppler-utils` |
| `Разбить pdf-файл на фрагменты по 19 МБ (qpdf).sh` | More robust PDF splitting via `qpdf` with real-size verification | `qpdf` |

## 🛠️ Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Balans097/GoodScripts.git
   cd GoodScripts
   ```

2. **Copy scripts to the Nautilus directory:**
   ```bash
   mkdir -p ~/.local/share/nautilus/scripts
   cp *.sh ~/.local/share/nautilus/scripts/
   ```

3. **Make them executable:**
   ```bash
   chmod +x ~/.local/share/nautilus/scripts/*.sh
   ```

4. **Restart Nautilus:**
   ```bash
   nautilus -q
   ```

> 💡 **Note for GNOME 43+ Users:**  
> If the `Scripts` submenu doesn't appear in the context menu, install the [Nautilus Scripts Manager](https://extensions.gnome.org/extension/5434/nautilus-scripts-manager/) extension, or ensure your file manager settings allow custom scripts to be displayed.

## 📦 Dependencies

Scripts rely on standard CLI tools. Install the required packages for your distribution:

**Fedora / RHEL / AlmaLinux / Rocky:**
```bash
sudo dnf install ffmpeg djvulibre poppler-utils libreoffice img2pdf qpdf file libnotify
```

**Ubuntu / Debian / Linux Mint / Pop!_OS:**
```bash
sudo apt install ffmpeg djvulibre-bin poppler-utils libreoffice img2pdf qpdf file libnotify-bin
```

**Arch Linux / Manjaro / EndeavourOS:**
```bash
sudo pacman -S ffmpeg djvulibre poppler libreoffice-fresh img2pdf qpdf file libnotify
```

> ⚠️ Dependencies are **not mandatory all at once**. Each script checks for its required tools at runtime and shows a clear desktop notification if something is missing.

## 🖱️ Usage

1. Select one or more files/folders in Nautilus.
2. Right-click → `Scripts` → choose the desired script.
3. Wait for the GNOME notification in the top-right corner.
4. Output files are created in the same directory (or alongside the first selected item).

✅ **Data Safety:** Scripts **never overwrite** original files. New files use prefixes (`merged_`, `_part_X`) or modified extensions.

## 🔧 Customization & Troubleshooting

- All paths and parameters are configurable at the top of each script (e.g., `OUTPUT_PREFIX`, `SUPPORTED_EXT`, or page sizes).
- For debugging, add `set -x` to the beginning of a script or check logs in `/tmp/` (used by the `qpdf` split script).
- Fully supports paths with spaces and non-ASCII characters (Cyrillic, etc.).
- Missing dependencies trigger a clear desktop notification with install instructions.

## 🤝 Contributing

Open to improvements, bug fixes, new format support, or ports to Thunar/Nemo/Dolphin. Please submit PRs or Issues.  
Keep the `#!/usr/bin/env bash` shebang and use `notify-send` for user feedback to maintain consistency.

## 📜 License

Distributed under the [MIT License](LICENSE). Use freely, modify, and share with the community.

---
*Crafted for Linux users who value time, transparency, and a clean GNOME workflow.*





