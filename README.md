# Aazad Chat

**Free, private AI on your own computer.**

Aazad Chat is a chat app for AI models that run locally, a bit like ChatGPT or Claude. The models run on your own machine through [Ollama](https://ollama.com), so conversations never leave it.

- Chats saved on your disk in a small SQLite database, with rename, delete and search inside every message
- Pick any installed model, and compare models with one-click Regenerate
- Streaming replies with Stop, Copy, Edit and Regenerate
- Thinking models show their reasoning in a collapsible box
- Image input for vision models (e.g. `gemma3:4b`)
- Speed stats under every reply: tokens/sec, GPU %, load time, time to first token
- Per-chat settings: system prompt, temperature, context length, max tokens, keep-alive
- Model manager: download (with progress), unload and delete models
- Markdown with syntax-highlighted code, light and dark themes

It has no build step and no dependencies: a small Python standard-library server (with the SQLite that ships inside Python) plus plain HTML, CSS and JavaScript.

## Contents

- [Install with one command](#install-with-one-command) · [Manual quick start](#quick-start)
- [1. Install Ollama](#1-install-ollama): [Linux](#linux) · [macOS](#macos) · [Windows](#windows) · [Docker](#docker-any-os) · [Check it works](#check-that-ollama-works) · [Settings](#change-ollama-settings)
- [2. Choose models for your hardware](#2-choose-models-for-your-hardware)
- [3. Run Aazad Chat](#3-run-aazad-chat)
- [Your data](#your-data) · [Troubleshooting](#troubleshooting) · [Project layout](#project-layout) · [Security](#security) · [Credits](#credits)

## Install with one command

The installer checks your computer (GPU, memory, disk space, anything already installed), asks you a few questions, shows a summary, and **changes nothing until you confirm**. Run it again any time to update Aazad Chat or change settings.

**Linux and macOS** (Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.sh | bash
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.ps1 | iex
```

### What it asks

| # | Question | Default |
|---|---|---|
| 1 | **AI engine:** use your existing Ollama, or install it (Linux: official system service or no-sudo home install · macOS: Homebrew or the app · Windows: winget or installer) | Existing Ollama, or the recommended install |
| 2 | **Models:** a list with what each model is good for, its capabilities (chat, code, reasoning, vision, embeddings), download size, and how it will run on *your* hardware (fast on GPU, partly GPU, CPU, too big) | The ★ recommended models for your hardware |
| 3 | **Model storage folder:** e.g. a bigger second drive; it can move models you already have | Where Ollama keeps them now |
| 4 | **Keep models loaded:** 5 min, 30 min, 1 hour, or always | 30 minutes |
| 5 | **Context length:** automatic, 4K, 8K, 16K or 32K | Automatic |
| 6 | **App folder, data folder (for the chats database) and port** | Standard folders for your OS, port 3210 |
| 7 | **Start at login, app menu shortcut, open the browser** | Yes |

It never deletes Ollama or your models, and it skips models you already have.

### Options

| What | Linux / macOS | Windows |
|---|---|---|
| Preview every change without making any | `… \| bash -s -- --dry-run` | `& ([scriptblock]::Create((irm <url>))) -DryRun` |
| Accept all defaults, no questions | `… \| bash -s -- --yes` | `… -Yes` |
| Remove Aazad Chat (asks before deleting chats) | `… \| bash -s -- --uninstall` | `… -Uninstall` |
| All options | `… \| bash -s -- --help` | see the top of `install.ps1` |

Every question also has an option to answer it ahead of time (for example `--models=r --port=3210`), which is useful for scripted installs.

**Prefer to read the script before running it?**

```bash
curl -fsSL https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.sh -o install.sh
less install.sh
bash install.sh
```

**Tested:**
- **Linux (Ubuntu, systemd):** tested with dry runs, a real install and uninstall.
- **Windows:** the installer passes PowerShell's parser and analyzer and its logic tests. It hasn't yet been run on a Windows PC.
- **macOS:** also not yet run on a Mac.

If something goes wrong on Windows or macOS, please open an issue.

## Quick start

Prefer to set things up by hand? Here are the steps (details for each OS below).

```bash
# 1. Install Ollama (see your OS below), then download a model that fits your hardware
ollama pull llama3.2:3b

# 2. Get Aazad Chat and start it
git clone https://github.com/alban-sheikh/aazad-local-llm.git
cd aazad-local-llm
python3 server.py        # Windows: py server.py
```

Open **http://127.0.0.1:3210**.

---

## 1. Install Ollama

Ollama is the engine that downloads and runs the models. Aazad Chat connects to it at `http://127.0.0.1:11434`.

### Linux

**Standard install** (needs `sudo`; installs a background service that starts at boot):

```bash
curl -fsSL https://ollama.com/install.sh | sh
systemctl status ollama          # should show "active (running)"
```

The script detects NVIDIA and AMD GPUs and installs the pieces it needs. Models are stored in `/usr/share/ollama/.ollama/models` because the service runs as the `ollama` user.

**Install without sudo** (everything in your home folder):

```bash
mkdir -p ~/.local/opt/ollama ~/.local/bin
curl -fsSL https://ollama.com/download/ollama-linux-amd64.tar.zst | zstd -d | tar -xf - -C ~/.local/opt/ollama
ln -sfn ~/.local/opt/ollama/bin/ollama ~/.local/bin/ollama
ollama serve                     # keep this running, or create a systemd --user service
```

Models are then stored in `~/.ollama/models`.

**GPU notes:**
- **NVIDIA:** install the proprietary NVIDIA driver first (`nvidia-smi` should work).
- **AMD:** uses ROCm on supported Radeon cards.
- **No GPU:** Ollama runs on the CPU.

### macOS

Requires **macOS 14 Sonoma or later**.

**Option A: the app (recommended).**
1. Download from **https://ollama.com/download/mac**.
2. Move **Ollama** to Applications and open it.
3. It sits in the menu bar, runs the server automatically and adds the `ollama` command.

**Option B: Homebrew.**

```bash
brew install --cask ollama-app          # the desktop app
# or, command line only:
brew install ollama
brew services start ollama              # run the server in the background
```

On Apple Silicon (M1–M4), the GPU is used automatically through Metal. Models are stored in `~/.ollama/models`.

### Windows

Requires **Windows 10 or later**.

**Option A: installer.** Download and run **OllamaSetup.exe** from **https://ollama.com/download/windows**.

**Option B: winget** (PowerShell or Terminal):

```powershell
winget install Ollama.Ollama
```

Ollama runs in the system tray and starts when you sign in. NVIDIA GPUs need a current NVIDIA driver; supported AMD Radeon cards are also used. Models are stored in `C:\Users\<you>\.ollama\models`.

### Docker (any OS)

```bash
# CPU only
docker run -d -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama

# NVIDIA GPU (needs the NVIDIA Container Toolkit)
docker run -d --gpus=all -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama

docker exec -it ollama ollama pull llama3.2:3b
```

### Check that Ollama works

```bash
ollama --version
ollama pull llama3.2:3b
ollama run llama3.2:3b "Say hello in one sentence"
ollama ps                          # PROCESSOR column: "100% GPU" means it fits on your GPU
curl http://127.0.0.1:11434/api/version
```

On Windows PowerShell, use `curl.exe` instead of `curl`, or `Invoke-RestMethod http://127.0.0.1:11434/api/version`.

### Change Ollama settings

Useful variables:

| Variable | Example | Effect |
|---|---|---|
| `OLLAMA_KEEP_ALIVE` | `30m` | How long a model stays loaded after use (default 5 min) |
| `OLLAMA_MODELS` | `/data/ollama/models` | Store models somewhere else (e.g. a bigger disk) |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Default context size |
| `OLLAMA_FLASH_ATTENTION` | `1` | Less memory for long context |

**How to set them on each OS:**

| OS | Steps |
|---|---|
| **Linux** (service) | `sudo systemctl edit ollama`, add `[Service]` and a line `Environment="OLLAMA_KEEP_ALIVE=30m"`, then `sudo systemctl daemon-reload && sudo systemctl restart ollama` |
| **macOS** (app) | `launchctl setenv OLLAMA_KEEP_ALIVE 30m`, then quit Ollama from the menu bar and open it again |
| **Windows** | Quit Ollama from the tray. Open Settings and search **"environment variables"**. Choose **Edit environment variables for your account**, add the variable, then start Ollama again |
| **Docker** | Add `-e OLLAMA_KEEP_ALIVE=30m` to `docker run` |

---

## 2. Choose models for your hardware

**Rule of thumb:** a model runs at full speed when **its download size + about 1–2 GB fits in your GPU memory (VRAM)**. If it doesn't fit, Ollama puts part of it in normal RAM on the CPU. It still works but gets much slower. Without a GPU, you need **RAM of at least the model size + 2 GB**, and small models give roughly a few to ~15 tokens/sec depending on the CPU.

Longer conversations (bigger context) need extra memory, so leave headroom. `ollama ps` shows how much of a loaded model is on the GPU.

### Recommended models by hardware

Download sizes are exact (default 4-bit versions from the Ollama library).

| Your hardware | Good models (download size) | Notes |
|---|---|---|
| **No GPU, 8 GB RAM** | `gemma3:1b` (0.8 GB), `llama3.2:1b` (1.3 GB), `qwen3:1.7b` (1.4 GB) | Basic chat and summaries |
| **No GPU, 16 GB RAM** or **GPU with 4–6 GB** | `llama3.2:3b` (2.0 GB), `qwen2.5-coder:3b` (1.9 GB), `qwen3:4b` (2.5 GB), `phi4-mini` (2.5 GB), `gemma3:4b` (3.3 GB) | Good everyday assistant; `gemma3:4b` reads images |
| **GPU with 8 GB** (RTX 3050 8 GB, 3060 Ti, 4060) | everything above, plus `qwen2.5-coder:7b` (4.7 GB), `llama3.1:8b` (4.9 GB), `qwen3:8b` (5.2 GB), `deepseek-r1:8b` (5.2 GB) | **Measured below.** Sweet spot for 7–8B models |
| **GPU with 12 GB** (RTX 3060 12 GB, 4070) | `gemma3:12b` (8.2 GB), `deepseek-r1:14b` (9.0 GB), `qwen2.5-coder:14b` (9.0 GB), `phi4:14b` (9.1 GB), `qwen3:14b` (9.3 GB) | Noticeably smarter than 8B |
| **GPU with 16 GB** (RTX 4080, 4060 Ti 16 GB) | 12–14B models with long context; `gemma3:27b` (17.4 GB) runs partly on CPU | |
| **GPU with 24 GB** (RTX 3090, 4090) | `gemma3:27b` (17.4 GB), `qwen3:30b` (18.6 GB), `qwen2.5-coder:32b` (19.9 GB), `deepseek-r1:32b` (19.9 GB), `qwen3:32b` (20.2 GB) | Close to hosted-AI quality for many tasks |
| **48 GB+ GPU memory** (2× 24 GB, workstation cards) | `llama3.3:70b` (42.5 GB), `deepseek-r1:70b` (42.5 GB), `qwen2.5:72b` (47.4 GB) | Largest common open models |
| **Any hardware: search / RAG** | `nomic-embed-text` (0.27 GB) | Embeddings only, it can't chat |

### Apple Silicon Macs (M1–M4)

Macs share memory between the CPU and GPU. macOS lets the GPU use roughly two-thirds to three-quarters of it, so pick by total memory:

| Mac memory | Pick from the row for |
|---|---|
| 8 GB | No GPU, 8 GB RAM (1–3B models) |
| 16 GB | GPU with 8 GB (up to 7–8B) |
| 24 GB | GPU with 12 GB (up to 14B) |
| 32–36 GB | GPU with 24 GB (27–32B, close to the limit) |
| 64 GB+ | 48 GB+ (70B models) |

### Best pick by task

| Task | Small (≤ 6 GB) | 8 GB GPU / 16 GB Mac | 24 GB GPU / 32 GB+ Mac |
|---|---|---|---|
| General chat | `llama3.2:3b` | `llama3.1:8b` | `gemma3:27b` |
| Coding | `qwen2.5-coder:3b` | `qwen2.5-coder:7b` | `qwen2.5-coder:32b` |
| Reasoning / math | `qwen3:4b` | `qwen3:8b`, `deepseek-r1:8b` | `qwen3:32b`, `deepseek-r1:32b` |
| Images (vision) | `gemma3:4b` | `gemma3:4b` | `gemma3:27b` |
| Search / RAG | `nomic-embed-text` | `nomic-embed-text` | `nomic-embed-text` |

### Measured: NVIDIA RTX 3050 (8 GB), 30 GB RAM

Reply speed in tokens/sec (about 0.75 words per token). Anything above ~20 feels fast.

| Model | 4K context | 16K context | GPU memory used (4K → 16K) |
|---|---|---|---|
| `llama3.2:3b` | **87 tok/s** · 100% GPU | **86** · 100% GPU | 2.6 → 4.1 GB |
| `gemma3:4b` | **66** · 100% GPU | **66** · 100% GPU | 2.9 → 2.9 GB |
| `qwen2.5-coder:7b` | **43** · 100% GPU | **43** · 100% GPU | 4.7 → 5.5 GB |
| `llama3.1:8b` | **42** · 100% GPU | 33 · 90% GPU | 5.3 → 7.3 GB |
| `qwen3:8b` | **39** · 100% GPU | 26 · 85% GPU | 5.6 → 7.8 GB |
| `deepseek-r1:8b` | **40** · 100% GPU | 26 · 85% GPU | 5.6 → 7.8 GB |
| `nomic-embed-text` | 290 texts/sec · 100% GPU | | 0.3 GB |

**What this shows:**
- **All 7–8B models run fully on an 8 GB GPU at normal context.**
- **At 16K context, the 8B models no longer fit** and slow down 20–35%. `qwen2.5-coder:7b`, `gemma3:4b` and `llama3.2:3b` stay at full speed.
- **Disk speed only affects loading.** From a hard disk, the first load took up to ~40 s; from RAM cache, 3–13 s. Replies run from GPU memory, so they aren't slowed.
- **`deepseek-r1` always thinks before answering.** Don't set a small "Max reply length", or the answer can come back empty.

---

## 3. Run Aazad Chat

Requires **Python 3.9+** and a running Ollama.

```bash
git clone https://github.com/alban-sheikh/aazad-local-llm.git
cd aazad-local-llm
```

| OS | Start it |
|---|---|
| Linux / macOS | `python3 server.py` |
| Windows | `py server.py` |

Open **http://127.0.0.1:3210**, choose a model at the top, and start chatting. The 📦 **Models** button downloads more models.

| Environment variable | Default | Purpose |
|---|---|---|
| `AAZAD_CHAT_PORT` | `3210` | Port for the web app |
| `AAZAD_CHAT_HOST` | `127.0.0.1` | Listen address (keep it local) |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama server to use |
| `AAZAD_CHAT_DATA` | `~/.local/share/aazad-chat` | Folder for the chats database |

### Start automatically at login (Linux, systemd)

`~/.config/systemd/user/aazad-chat.service` (adjust the path to where you cloned it):

```ini
[Unit]
Description=Aazad Chat web app (http://127.0.0.1:3210)
Wants=ollama.service
After=ollama.service

[Service]
ExecStart=/usr/bin/python3 %h/Projects/aazad/aazad-local-llm/server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now aazad-chat
systemctl --user restart aazad-chat     # after editing server.py
journalctl --user -u aazad-chat -f
```

Changes to files in `web/` only need a page reload.

---

## Your data

Everything is stored in one SQLite file, `aazad-chat.db`, in the data folder:

| OS | Data folder (installer default) |
|---|---|
| Linux | `~/.local/share/aazad-chat/` |
| macOS | `~/Library/Application Support/AazadChat/` |
| Windows | `%LOCALAPPDATA%\AazadChat\` |

SQLite is built into Python on every OS, so there is nothing extra to install or run. The database holds:

| Table | What's in it |
|---|---|
| `chats` | Title, model, system prompt, options, created and updated times, message count |
| `messages` | Each message's text, thinking, the model that wrote it, and its speed stats |
| `attachments` | Images you sent, stored as bytes |
| `settings` | App settings, such as the defaults for new chats |

It uses write-ahead logging (WAL), so you'll also see `aazad-chat.db-wal` and `aazad-chat.db-shm` next to it while the app runs. **Don't copy the `.db` file on its own while the app is running.** Make a backup this way instead, which is safe at any time:

```bash
python3 server.py --backup ~/aazad-chat-backup.db        # Windows: py server.py --backup %USERPROFILE%\aazad-chat-backup.db
```

To restore, stop the app, replace `aazad-chat.db` with the backup (and delete any `-wal`/`-shm` files), then start it. You can browse the file with any SQLite tool, such as [DB Browser for SQLite](https://sqlitebrowser.org).

- **Upgrading from an older version:** chats saved as JSON files in `chats/` are imported automatically on first start, and the old files are kept in `chats-imported/`.
- **Keep the data folder on a local disk**, not a network drive. SQLite's locking isn't reliable over network file systems.
- New versions update the database layout automatically. An older app refuses to open a database from a newer one rather than damage it.

## Troubleshooting

| Problem | Fix |
|---|---|
| "AI engine offline" in the app | Start Ollama: open the Ollama app (macOS/Windows), or `systemctl start ollama` (Linux) |
| No models in the picker | `ollama pull llama3.2:3b`, or use 📦 **Models** in the app |
| Replies are slow | Run `ollama ps`. If it isn't `100% GPU`, pick a smaller model or lower the context length in ⚙ settings |
| First reply takes long | The model is loading. Raise `OLLAMA_KEEP_ALIVE` so it stays loaded |
| Image attach says the model can't read images | Switch to a vision model such as `gemma3:4b` |
| Port 3210 already in use | `AAZAD_CHAT_PORT=3211 python3 server.py` |
| `No module named '_sqlite3'` | Your Python was built without SQLite (usually pyenv). Install the SQLite headers (`libsqlite3-dev` / `sqlite-devel`) and rebuild it, or use your system's Python |
| "database is locked" | Another program has the database open for writing, often a DB browser with unsaved changes. Close it |

## Project layout

```
server.py                 web server: static files, SQLite chat storage, Ollama proxy
web/index.html            page structure
web/app.js                app logic
web/style.css             design and brand colours
web/theme.js              applies the saved theme before first paint
web/icon.svg              logo
web/vendor/               bundled libraries (see THIRD_PARTY_NOTICES.md)
```

Chats are saved in `aazad-chat.db` in the data folder, outside the repository (see [Your data](#your-data)).

## Security

- Listens on `127.0.0.1` only.
- Rejects requests with any other `Host` header, which blocks DNS rebinding.
- API calls need the `X-Aazad-Chat: 1` header, so other websites you visit can't use your models or read your chats.
- Model output is sanitized with DOMPurify and restricted by a strict Content-Security-Policy.

## Credits

- **Engine:** [Ollama](https://ollama.com).
- **Bundled libraries:** marked, DOMPurify and highlight.js. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
