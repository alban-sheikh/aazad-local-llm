# Aazad Chat

**Free, private AI on your own computer.**

Aazad Chat is a chat app for AI models that run locally, a bit like ChatGPT or Claude. The models run on your own machine through [Ollama](https://ollama.com), so conversations never leave it.

- Chats saved on your disk, with search, rename and delete
- Pick any installed model, and compare models with one-click Regenerate
- Streaming replies with Stop, Copy, Edit and Regenerate
- Thinking models show their reasoning in a collapsible box
- Image input for vision models (e.g. `gemma3:4b`)
- Speed stats under every reply: tokens/sec, GPU %, load time, time to first token
- Per-chat settings: system prompt, temperature, context length, max tokens, keep-alive
- Model manager: download (with progress), unload and delete models
- Markdown with syntax-highlighted code, light and dark themes

It has no build step and no dependencies: a small Python standard-library server plus plain HTML, CSS and JavaScript.

## Requirements

- Python 3.11+
- [Ollama](https://ollama.com/download) running on `http://127.0.0.1:11434`, with at least one model (e.g. `ollama pull llama3.2:3b`)

## Run

```bash
git clone https://github.com/<your-user>/aazad-local-llm.git
cd aazad-local-llm
python3 server.py
```

Open **http://127.0.0.1:3210**.

| Environment variable | Default | Purpose |
|---|---|---|
| `AAZAD_CHAT_PORT` | `3210` | Port for the web app |
| `AAZAD_CHAT_HOST` | `127.0.0.1` | Listen address (keep it local) |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama server to use |
| `AAZAD_CHAT_DATA` | `~/.local/share/aazad-chat` | Where chats are saved |

## Start automatically at login (Linux, systemd)

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

## Project layout

```
server.py                 web server: static files, chat storage, Ollama proxy
web/index.html            page structure
web/app.js                app logic
web/style.css             design and brand colours
web/theme.js              applies the saved theme before first paint
web/icon.svg              logo
web/vendor/               bundled libraries (see THIRD_PARTY_NOTICES.md)
```

Chats are saved as one JSON file per conversation in `~/.local/share/aazad-chat/chats/`, outside the repository.

## Security

- Listens on `127.0.0.1` only.
- Rejects requests with any other `Host` header, which blocks DNS rebinding.
- API calls need the `X-Aazad-Chat: 1` header, so other websites you visit can't use your models or read your chats.
- Model output is sanitized with DOMPurify and restricted by a strict Content-Security-Policy.

## Brand

- Name: **Aazad Chat** ("aazad" means free, independent)
- Tagline: "Free, private AI on your own computer."
- Colours: indigo `#4f46e5` → violet `#9333ea`; logo in `web/icon.svg`

## Credits

Bundled libraries: marked, DOMPurify and highlight.js. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
