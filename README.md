# 🐧 GoodScripts: File Automation Toolkit for Linux

> A collection of Bash scripts for the **Nautilus (GNOME Files)** and **Double Commander** context menus, turning routine document and media operations into a single click.

## 🚀 Why This Improves Your Linux Workflow

GNOME embraces minimalism: a clean UI, fewer distractions, and a focus on content. However, Nautilus intentionally lacks built-in batch conversion or file manipulation tools. These scripts bridge that gap while staying true to that philosophy. For users of a dual-pane file manager, the same toolset is also available for **Double Commander**.

- 🔹 **Seamless Context Integration:** Everything is accessible via `Right Click → Scripts` (Nautilus) or a custom action/toolbar button (Double Commander). No heavy GUI apps, no drag-and-drop workflows.
- 🔹 **Background Processing + Native Notifications:** Scripts run silently. Progress and results are delivered via the desktop notification system.
- 🔹 **Batch Processing Out-of-the-Box:** Select a folder or dozens of files → run a script → get results instantly without manual iteration.
- 🔹 **100% Local & Private:** All operations happen on your machine. No cloud uploads, telemetry, watermarks, or file size/quantity limits.
- 🔹 **Transparent & Customizable:** Plain Bash + battle-tested CLI utilities. Read, tweak, or extend any script to suit your exact needs.
- 🔹 **Built for Productivity:** Saves hours for researchers, writers, developers, and anyone who regularly handles scans, documents, e-books, logs, or media.

## 📁 Repository Structure

```text
GoodScripts/
├── src_nautilus/           # Scripts for the Nautilus "Scripts" menu
├── src_double_commander/   # Scripts for Double Commander (dc*.sh)
└── RetroShare/             # RetroShare packaging helpers (Fedora RPM)
```

## 📦 What's Inside?

### 🗂️ Nautilus scripts (`src_nautilus/`)

Some scripts carry an emoji prefix in the file name so they sort to the top of the Nautilus menu.

| Script | Description | Key Dependencies |
|--------|-------------|------------------|
| `🔍  dav-файлы → mp4-файлы.sh` | Converts DVR video (`.dav`) to MP4 without re-encoding | `ffmpeg` |
| `✅  djvu → pdf.sh` | Batch converts `.djvu`/`.djv` to PDF (supports files & folders) | `djvulibre` (`ddjvu`) |
| `💡  Документы → PDF.sh` | Merges & converts docs (Word, Excel, ODT, TXT, EPUB, HTML, etc.) into a single PDF | `libreoffice`, `poppler-utils` |
| `Изображения → PDF.sh` | Creates PDF from images preserving original dimensions | `img2pdf` |
| `Изображения → PDF (A4).sh` | Same as above, but auto-scales to A4 paper size | `img2pdf` |
| `📌  Объединить текстовые файлы в один файл.sh` | Recursively merges text/code files into a single `.txt` with clear dividers | `file` |
| `Разбить pdf-файл на фрагменты по 19 МБ.sh` | Splits large PDFs into ≤19 MB chunks (using `poppler-utils`) | `poppler-utils` |
| `Разбить pdf-файл на фрагменты по 19 МБ (qpdf).sh` | More robust PDF splitting via `qpdf` with real-size verification | `qpdf` |

### 🖥️ Double Commander scripts (`src_double_commander/`)

| Script | Purpose |
|--------|---------|
| `dcDav2mp4.sh` | DVR video (`.dav`) → MP4 |
| `dcConvert2AAC.sh` | Convert audio to AAC |
| `dcDir2mp3.sh` | Folder-based audio → MP3 conversion |
| `dcDjvu2pdf.sh` | DjVu → PDF |
| `dcDjvu2pdf_ghostscript.sh` | DjVu → PDF, Ghostscript-based variant |
| `dcDocs2PDF.sh` | Documents → a single PDF |
| `dcImages2PDF.sh` | Images → PDF (original dimensions) |
| `dcImages2PDF_A4.sh` | Images → PDF scaled to A4 |
| `dcExtractPNG.sh` | Extract PNG images |
| `dcEpub2docx.sh` / `dcEpub2odt.sh` | EPUB → DOCX / ODT |
| `dcFb2ToDocx.sh` / `dcFb2ToOdt.sh` | FB2 → DOCX / ODT |
| `dcMerge2txt.sh` | Merge text files into one `.txt` |
| `dcSplitPdfs.sh` | Split large PDFs into chunks (poppler) |
| `dcSplitPdfs_qpdf.sh` | Split large PDFs into chunks (qpdf) |

> ℹ️ Each script's exact arguments and extra dependencies are documented in the comments at the top of the file.

### 📡 RetroShare helpers (`RetroShare/`)

`MakeRetroShareRPM.sh` builds a RetroShare RPM package for Fedora (Qt6 build from the upstream git sources). The `retroshare/` subfolder is a copy of the upstream project with its own build and test scripts; those belong to the RetroShare authors and are not part of this toolkit.

## 🛠️ Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Balans097/GoodScripts.git
   cd GoodScripts
   ```

### Nautilus

2. **Copy scripts to the Nautilus directory:**
   ```bash
   mkdir -p ~/.local/share/nautilus/scripts
   cp src_nautilus/*.sh ~/.local/share/nautilus/scripts/
   ```

3. **Make them executable:**
   ```bash
   chmod +x ~/.local/share/nautilus/scripts/*.sh
   ```

4. **Restart Nautilus:**
   ```bash
   nautilus -q
   ```

### Double Commander

1. Copy the scripts to a folder of your choice and make them executable:
   ```bash
   mkdir -p ~/.config/doublecmd/scripts
   cp src_double_commander/*.sh ~/.config/doublecmd/scripts/
   chmod +x ~/.config/doublecmd/scripts/*.sh
   ```
2. In Double Commander open **Configuration → Toolbar** (or **Actions / Hotkeys**), add an **external command** pointing to the desired script, and pass the selected files as parameters (e.g. `%LU` or `%L`, depending on the script — see its header).

## 📦 Dependencies

Scripts rely on standard CLI tools. Install the required packages for your distribution:

**Fedora / RHEL / AlmaLinux / Rocky:**
```bash
sudo dnf install ffmpeg djvulibre poppler-utils libreoffice img2pdf qpdf ghostscript file libnotify
```

**Ubuntu / Debian / Linux Mint / Pop!_OS:**
```bash
sudo apt install ffmpeg djvulibre-bin poppler-utils libreoffice img2pdf qpdf ghostscript file libnotify-bin
```

**Arch Linux / Manjaro / EndeavourOS:**
```bash
sudo pacman -S ffmpeg djvulibre poppler libreoffice-fresh img2pdf qpdf ghostscript file libnotify
```

> ⚠️ Dependencies are **not mandatory all at once**. Each script checks for its required tools at runtime and shows a clear desktop notification if something is missing.

## 🖱️ Usage

**Nautilus**
1. Select one or more files/folders in Nautilus.
2. Right-click → `Scripts` → choose the desired script.
3. Wait for the notification in the top-right corner.

**Double Commander**
1. Select files/folders in the active panel.
2. Press the toolbar button or hotkey bound to the script.

Output files are created in the same directory (or alongside the first selected item).

✅ **Data Safety:** Scripts **never overwrite** original files. New files use prefixes (`merged_`, `_part_X`) or modified extensions.

## 🔧 Customization & Troubleshooting

- All paths and parameters are configurable at the top of each script (e.g., `OUTPUT_PREFIX`, `SUPPORTED_EXT`, or page sizes).
- For debugging, add `set -x` to the beginning of a script or check logs in `/tmp/` (used by the `qpdf` split scripts).
- Fully supports paths with spaces and non-ASCII characters (Cyrillic, etc.).
- Missing dependencies trigger a clear desktop notification with install instructions.
- If a script does not appear in Nautilus, check that it is executable and restart Nautilus (`nautilus -q`).

## 🤝 Contributing

Open to improvements, bug fixes, new format support, or ports to Thunar/Nemo/Dolphin. Please submit PRs or Issues.  
Keep the `#!/usr/bin/env bash` shebang and use `notify-send` for user feedback to maintain consistency.

## 📜 License

Distributed under the [MIT License](LICENSE). Use freely, modify, and share with the community.

---
*Crafted for Linux users who value time, transparency, and a clean workflow.*
