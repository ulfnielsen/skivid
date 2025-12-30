## Ski Video Sorting Toolkit

Unapologetically vibe coded terminal-driven workflow for reviewing ski videos, tagging them by athlete, and batch-resizing footage and uploading to Google Drive.

### Components
- `rename.py`: launches mpv for quick preview, captures keyboard controls in the terminal, and moves tagged files into per-athlete folders.
- `resize_video.py`: ffmpeg-powered helper to resize/brighten/expose multiple clips. Provides both a CLI and importable API.
- `upload_to_drive.py`: mirrors a local video folder (with subdirectories) into Google Drive using a service-account credential.

### Requirements
- Python 3.11+ (tested with macOS 14 and Ubuntu 22.04)
- [mpv](https://mpv.io) media player (for video preview)
- [ffmpeg](https://ffmpeg.org) 4.x or newer (for resizing)
- Google Drive uploads rely on `google-api-python-client`, `google-auth`, and `google-auth-httplib2` (installed automatically when syncing the project dependencies)
- Optional: `readline`/`libedit` already bundled on macOS; GNU readline on Linux improves tab completion.

### Setup
1. Clone or copy the repo to your machine.
2. Install Python dependencies:
	- `uv pip sync` (recommended) or `uv pip install -e .`
	- alternatively: `python -m venv .venv && . .venv/bin/activate && python -m pip install -e .`
3. Install OS-specific prerequisites:

#### macOS
- Install Homebrew if you have not already: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- `brew install mpv ffmpeg`
- Optionally `brew install readline` for enhanced history/completion when running inside certain shells.

#### Linux (Ubuntu/Debian example)
- Update package lists: `sudo apt update`
- Install dependencies: `sudo apt install -y python3 python3-venv ffmpeg mpv`
- For better terminal completion: `sudo apt install -y readline-common libreadline-dev`

#### Using uv (optional but recommended)
1. Install uv (macOS/Linux): `curl -Ls https://astral.sh/uv/install.sh | sh`
2. From the repo root, run tools without creating a venv manually:
	- `uv run python rename.py --help`
	- `uv run python resize_video.py -w 1280 -h 720 clip.mp4`
	- `uv run python upload_to_drive.py --help`
3. uv respects the `pyproject.toml` settings, so upgrading Python or pinning dependencies later only requires editing that file.

### Usage
#### Sorting & Tagging
```bash
python rename.py \
	--source ~/Ski/Zurs20251213 \
	--dest ~/Ski/Zurs20251213/organized \
	--window-width 960 \
	--window-height 540
```
- The script prompts for an event date/title (defaults to the first .mp4 timestamp) and reads optional athlete names from `~/Ski/athletes.txt` (one per line).
- Controls: arrow keys to scrub/navigate, PageUp/PageDown for ±5s, `.`/`,` for frame step, `s` toggles slow-mo, `Enter` tags the current clip.

#### Resizing Videos
Command-line:
```bash
python resize_video.py \
	-w 1280 -h 720 \
	-b 10 \
	-e 0.5 \
	path/to/*.mp4
```
- Each clip shows `[current/total] Resizing …` plus a live `ffmpeg <file>: XX%` line pulled from ffmpeg's progress feed so you can track long exports without opening another window.
- Use `--overwrite-output` if you need to regenerate existing `_resized` files; by default the script skips them and raises an error so you can investigate before clobbering outputs.
Python API:
```python
from resize_video import resize_videos

resize_videos([
		"run1.mp4",
		"run2.mp4",
], brighten_percent=5.0, replace=False)
```

#### Uploading Folder Trees to Google Drive
Prerequisites (common):
- Google Cloud project with the Drive API enabled
- Drive folder (or Shared Drive) where you have permission to create files/folders

##### Option A: OAuth user credentials (default)
1. In Google Cloud Console, enable the Drive API for your project and open **APIs & Services → OAuth consent screen**.
2. Configure the consent screen (App name, logo optional, scopes include `../auth/drive.file`, add yourself to *Test users* while in testing mode).
3. Go to **Credentials → Create credentials → OAuth client ID**, choose *Desktop app*, and download the `client_secret_XXXX.json` file (keep it outside version control).
4. Run the uploader; the first run opens a browser window so you can approve Drive access. The refresh token is cached in `token.json` (override with `--token` if you want a different path).

```bash
python upload_to_drive.py \
	~/Ski/Zurs20251213/organized \
	--client-secrets ~/keys/client_secret.json \
	--drive-folder-name Zurs-2025
```

##### Option B: Service account (key-based)
1. Create a service account, enable the Drive API, and generate a JSON key (if your org policy allows).
2. Share the destination folder with the service-account email if it lives outside its own My Drive.

```bash
python upload_to_drive.py \
	~/Ski/Zurs20251213/organized \
	--auth-method service-account \
	--credentials ~/keys/drive-uploader.json \
	--drive-parent 1AbCdEfGhIjKlMnOp
```

- Only standard video extensions upload by default; add `--include-non-video` to send every file.
- `--drive-parent` points to the Drive folder (or Shared Drive) that should receive all athlete/event folders. By default the uploader merges directly into that parent; omit the flag to target your own Drive root.
- Use `--drive-folder-name` only when you want the script to create a fresh subfolder under `--drive-parent` before uploading. Leave it unset to avoid creating an extra top-level folder.
- To find a parent ID, open the folder (or Shared Drive) in your browser and copy the long ID that appears after `shared-drives/` (drive root) or `folders/` (subfolder). You need at least *Content manager* access for uploads to succeed.

### Tips
- Keep an `athletes.txt` list up to date for instant autocompletion while tagging.
- mpv logs are written to `/tmp/mpv-sorter-<pid>.log` if you need to troubleshoot playback.
- For best performance, pin the terminal window (where you launch `rename.py`) to keep keyboard focus there; mpv ignores VO keyboard events by default.
- When using Google Drive uploads, store credentials securely (e.g., outside the repo); treat both OAuth tokens and service-account keys as secrets.

