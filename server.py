#!/usr/bin/env python3
"""Aazad Chat: a small local web server for the chat UI.

- Serves the page from ./web
- Saves chats and settings in one SQLite database (aazad-chat.db in the data folder)
- Proxies /ollama/* to the shared Ollama server, so the browser talks to one origin

Only listens on 127.0.0.1. Standard library only (sqlite3 ships with Python).

    python3 server.py                     start the app
    python3 server.py --backup FILE       copy the database safely, even while the app runs
"""
import argparse
import base64
import binascii
import http.client
import json
import os
import re
import sqlite3
import sys
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HOST = os.environ.get("AAZAD_CHAT_HOST", "127.0.0.1")
PORT = int(os.environ.get("AAZAD_CHAT_PORT", "3210"))
OLLAMA = urlsplit(os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"))
WEB_DIR = Path(__file__).resolve().parent / "web"
DATA_DIR = Path(os.environ.get("AAZAD_CHAT_DATA", Path.home() / ".local/share/aazad-chat")).expanduser()
DB_PATH = DATA_DIR / "aazad-chat.db"
LEGACY_CHATS = DATA_DIR / "chats"  # one JSON file per chat, used before the database

CHAT_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SETTING_KEY = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
MAX_BODY = 64 * 1024 * 1024  # chats can hold base64 images
MAX_SETTING = 1024 * 1024
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".json": "application/json",
}
CSP = ("default-src 'self'; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; "
       "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")


# ================================================================ database
#
# SQLite, through Python's built-in sqlite3 module: nothing to install on any OS.
# Only features from SQLite 3.8 or older are used, so old Linux distributions work too.
# Each schema change is appended to MIGRATIONS; PRAGMA user_version records how many ran.

MIGRATIONS = [
    """
    CREATE TABLE chats (
        id            TEXT PRIMARY KEY,
        title         TEXT NOT NULL,
        model         TEXT,
        system        TEXT,
        options       TEXT,              -- JSON object: temperature, num_ctx, num_predict
        keep_alive    TEXT,
        think         INTEGER,           -- 1 or 0
        created       INTEGER NOT NULL,  -- milliseconds since 1970
        updated       INTEGER NOT NULL,
        message_count INTEGER NOT NULL DEFAULT 0,
        extra         TEXT               -- JSON: fields this version doesn't know about
    );
    CREATE INDEX chats_by_updated ON chats (updated);

    CREATE TABLE messages (
        id       INTEGER PRIMARY KEY,
        chat_id  TEXT NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        role     TEXT NOT NULL,
        content  TEXT,
        thinking TEXT,
        model    TEXT,
        stats    TEXT,                   -- JSON: tokens/sec, GPU %, load time, ...
        extra    TEXT,
        UNIQUE (chat_id, position)
    );

    CREATE TABLE attachments (
        id         INTEGER PRIMARY KEY,
        message_id INTEGER NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
        position   INTEGER NOT NULL,
        data       BLOB NOT NULL,        -- image bytes (base64-decoded, a quarter smaller)
        is_text    INTEGER NOT NULL DEFAULT 0,  -- 1 if the value wasn't base64 and is kept as-is
        UNIQUE (message_id, position)
    );

    CREATE TABLE settings (
        key     TEXT PRIMARY KEY,
        value   TEXT NOT NULL,           -- JSON
        updated INTEGER NOT NULL
    );
    """,
]

JOURNAL_MODE = "delete"  # set by init_db()


def connect():
    conn = sqlite3.connect(str(DB_PATH), timeout=15, isolation_level=None)
    conn.execute("PRAGMA foreign_keys = ON")
    if JOURNAL_MODE == "wal":
        conn.execute("PRAGMA synchronous = NORMAL")  # safe with WAL, and much faster
    return conn


@contextmanager
def db(write=False):
    """A connection inside one transaction: a consistent snapshot for reads, all-or-nothing for writes."""
    conn = connect()
    try:
        conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def init_db():
    global JOURNAL_MODE
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), timeout=15, isolation_level=None)
    try:
        if os.name == "posix":
            os.chmod(DB_PATH, 0o600)  # chats are private; SQLite gives -wal/-shm files the same mode
        # WAL: readers never wait for the writer, and fewer disk syncs. SQLite keeps the old
        # mode if WAL can't work here (e.g. some network drives).
        JOURNAL_MODE = conn.execute("PRAGMA journal_mode = WAL").fetchone()[0].lower()
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version > len(MIGRATIONS):
            sys.exit(f"{DB_PATH} was created by a newer Aazad Chat (schema {version}). Update the app.")
        for number in range(version, len(MIGRATIONS)):
            try:
                conn.executescript(f"BEGIN IMMEDIATE;\n{MIGRATIONS[number]}\nPRAGMA user_version = {number + 1};\nCOMMIT;")
            except BaseException:
                if conn.in_transaction:
                    conn.execute("ROLLBACK")
                raise
    finally:
        conn.close()


# ---------- chats <-> rows

CHAT_KEYS = {"id", "title", "model", "system", "options", "keep_alive", "think", "created", "updated", "messages"}
MESSAGE_KEYS = {"role", "content", "thinking", "model", "stats", "images"}


def opt_text(value):
    return None if value is None else str(value)


def opt_json(value):
    return None if value is None else json.dumps(value)


def to_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def extra_json(obj, known):
    extra = {k: v for k, v in obj.items() if k not in known}
    return json.dumps(extra) if extra else None


def pack_image(value):
    if not isinstance(value, str):
        raise ValueError("images must be base64 strings")
    try:
        raw = base64.b64decode(value, validate=True)
        if base64.b64encode(raw).decode("ascii") == value:
            return raw, 0
    except (ValueError, binascii.Error):
        pass
    return value.encode("utf-8"), 1


def save_chat(conn, chat):
    """Insert or replace a whole chat (the page always sends the full conversation)."""
    if not isinstance(chat, dict) or not isinstance(chat.get("id"), str) or not CHAT_ID.match(chat["id"]):
        raise ValueError("invalid chat id")
    messages = chat.get("messages") or []
    if not isinstance(messages, list) or not all(isinstance(m, dict) for m in messages):
        raise ValueError("messages must be a list of objects")
    chat_id, now = chat["id"], int(time.time() * 1000)
    think = chat.get("think")
    row = (str(chat.get("title") or "Untitled"), opt_text(chat.get("model")), opt_text(chat.get("system")),
           opt_json(chat.get("options")), opt_text(chat.get("keep_alive")), None if think is None else int(bool(think)),
           to_int(chat.get("created"), now), to_int(chat.get("updated"), now), len(messages),
           extra_json(chat, CHAT_KEYS), chat_id)
    # UPDATE then INSERT instead of an upsert, which needs SQLite 3.24+
    if conn.execute("UPDATE chats SET title = ?, model = ?, system = ?, options = ?, keep_alive = ?, think = ?,"
                    " created = ?, updated = ?, message_count = ?, extra = ? WHERE id = ?", row).rowcount == 0:
        conn.execute("INSERT INTO chats (title, model, system, options, keep_alive, think, created, updated,"
                     " message_count, extra, id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", row)
    delete_messages(conn, chat_id)
    for position, msg in enumerate(messages):
        images = msg.get("images") or []
        if not isinstance(images, list):
            raise ValueError("images must be a list")
        message_id = conn.execute(
            "INSERT INTO messages (chat_id, position, role, content, thinking, model, stats, extra)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (chat_id, position, str(msg.get("role") or "user"), opt_text(msg.get("content")),
             opt_text(msg.get("thinking")), opt_text(msg.get("model")), opt_json(msg.get("stats")),
             extra_json(msg, MESSAGE_KEYS))).lastrowid
        for index, image in enumerate(images):
            conn.execute("INSERT INTO attachments (message_id, position, data, is_text) VALUES (?, ?, ?, ?)",
                         (message_id, index, *pack_image(image)))


def delete_messages(conn, chat_id):
    # Explicit deletes, so nothing is left behind even where foreign keys are switched off
    conn.execute("DELETE FROM attachments WHERE message_id IN (SELECT id FROM messages WHERE chat_id = ?)", (chat_id,))
    conn.execute("DELETE FROM messages WHERE chat_id = ?", (chat_id,))


def load_chat(conn, chat_id):
    row = conn.execute("SELECT title, model, system, options, keep_alive, think, created, updated, extra"
                       " FROM chats WHERE id = ?", (chat_id,)).fetchone()
    if row is None:
        return None
    title, model, system, options, keep_alive, think, created, updated, extra = row
    chat = json.loads(extra) if extra else {}
    chat.update(id=chat_id, title=title, created=created, updated=updated)
    for key, value in (("model", model), ("system", system), ("keep_alive", keep_alive)):
        if value is not None:
            chat[key] = value
    if options is not None:
        chat["options"] = json.loads(options)
    if think is not None:
        chat["think"] = bool(think)

    images = {}
    for message_id, data, is_text in conn.execute(
            "SELECT a.message_id, a.data, a.is_text FROM attachments a JOIN messages m ON m.id = a.message_id"
            " WHERE m.chat_id = ? ORDER BY a.message_id, a.position", (chat_id,)):
        images.setdefault(message_id, []).append(bytes(data).decode("utf-8") if is_text
                                                 else base64.b64encode(data).decode("ascii"))
    chat["messages"] = []
    for message_id, role, content, thinking, msg_model, stats, msg_extra in conn.execute(
            "SELECT id, role, content, thinking, model, stats, extra FROM messages"
            " WHERE chat_id = ? ORDER BY position", (chat_id,)):
        msg = json.loads(msg_extra) if msg_extra else {}
        msg["role"] = role
        for key, value in (("content", content), ("thinking", thinking), ("model", msg_model)):
            if value is not None:
                msg[key] = value
        if stats is not None:
            msg["stats"] = json.loads(stats)
        if message_id in images:
            msg["images"] = images[message_id]
        chat["messages"].append(msg)
    return chat


def list_chats(conn, query=""):
    sql = "SELECT id, title, model, created, updated, message_count FROM chats"
    args = ()
    if query:
        # Search titles and message text. LIKE ignores case for English letters.
        pattern = "%" + re.sub(r"([\\%_])", r"\\\1", query) + "%"
        sql += (" WHERE title LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM messages m"
                " WHERE m.chat_id = chats.id AND m.content LIKE ? ESCAPE '\\')")
        args = (pattern, pattern)
    rows = conn.execute(sql + " ORDER BY updated DESC", args)
    return [{"id": i, "title": t, "model": m or "", "created": c, "updated": u, "message_count": n}
            for i, t, m, c, u, n in rows]


def import_legacy_chats():
    """Move chats saved as JSON files (before the database existed) into the database, once."""
    if not LEGACY_CHATS.is_dir():
        return
    files = sorted(LEGACY_CHATS.glob("*.json"))
    if not files and not any(LEGACY_CHATS.iterdir()):
        LEGACY_CHATS.rmdir()
        return
    imported, failed = 0, []
    for file in files:
        try:
            chat = json.loads(file.read_text(encoding="utf-8"))
            with db(write=True) as conn:
                row = conn.execute("SELECT updated FROM chats WHERE id = ?", (chat.get("id"),)).fetchone()
                if row is None or row[0] < to_int(chat.get("updated"), 0):
                    save_chat(conn, chat)
            imported += 1
        except (OSError, ValueError, AttributeError) as exc:
            failed.append(f"{file.name} ({exc})")
    # Keep the old files as a backup, out of the way, so this runs only once
    target = DATA_DIR / "chats-imported"
    if target.exists():
        target = DATA_DIR / time.strftime("chats-imported-%Y%m%d-%H%M%S")
    LEGACY_CHATS.rename(target)
    print(f"Imported {imported} chat(s) into {DB_PATH.name}. The old files are kept in {target}", flush=True)
    for item in failed:
        print(f"  Could not import {item}", flush=True)


def backup(target):
    target = Path(target).expanduser()
    if not DB_PATH.is_file():
        sys.exit(f"No database at {DB_PATH}")
    if target.exists():
        sys.exit(f"{target} already exists")
    src, dst = sqlite3.connect(str(DB_PATH), timeout=15), sqlite3.connect(str(target))
    try:
        src.backup(dst)  # consistent copy, safe while the app is writing
    finally:
        dst.close()
        src.close()
    print(f"Backed up {DB_PATH} to {target}")


# ================================================================ web server

class Handler(BaseHTTPRequestHandler):
    server_version = "AazadChat/1.0"

    def log_message(self, fmt, *args):
        pass  # keep the journal quiet; errors are returned to the page

    # ---------- helpers
    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self, limit=MAX_BODY):
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise ValueError("request too large")
        return self.rfile.read(length) if length else b""

    def allowed(self, api):
        """Reject DNS-rebinding hosts, and API calls from other websites.

        The page sends X-Aazad-Chat: 1. A cross-site page can't add that header
        without a CORS preflight, which this server never approves.
        """
        if self.headers.get("Host") not in ALLOWED_HOSTS:
            self.send_json(403, {"error": "forbidden host"})
            return False
        if api and self.headers.get("X-Aazad-Chat") != "1":
            self.send_json(403, {"error": "missing X-Aazad-Chat header"})
            return False
        return True

    # ---------- routing
    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def do_OPTIONS(self):
        self.send_json(403, {"error": "cross-origin requests are not allowed"})

    def route(self, method):
        url = urlsplit(self.path)
        path = url.path
        try:
            if path.startswith("/ollama/"):
                if self.allowed(api=True):
                    self.proxy(method, self.path[len("/ollama"):])
            elif path == "/api/chats" or path.startswith("/api/chats/"):
                if self.allowed(api=True):
                    self.chats(method, path, parse_qs(url.query))
            elif path == "/api/settings" or path.startswith("/api/settings/"):
                if self.allowed(api=True):
                    self.settings(method, path)
            elif method == "GET":
                if self.allowed(api=False):
                    self.static(path)
            else:
                self.send_json(405, {"error": "method not allowed"})
        except (BrokenPipeError, ConnectionResetError):
            pass  # browser closed the connection (e.g. Stop button)
        except ValueError as exc:  # bad JSON or an invalid chat
            self.send_json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - report anything to the page
            try:
                self.send_json(500, {"error": str(exc)})
            except OSError:
                pass

    # ---------- static files
    def static(self, path):
        rel = "index.html" if path in ("", "/") else path.lstrip("/")
        file = (WEB_DIR / rel).resolve()
        if not file.is_relative_to(WEB_DIR) or not file.is_file():
            return self.send_json(404, {"error": "not found"})
        body = file.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", TYPES.get(file.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        if file.suffix == ".html":
            self.send_header("Content-Security-Policy", CSP)
        self.end_headers()
        self.wfile.write(body)

    # ---------- saved chats
    def chats(self, method, path, query):
        parts = path.strip("/").split("/")  # ["api", "chats", <id>]
        if len(parts) == 2:
            if method != "GET":
                return self.send_json(405, {"error": "method not allowed"})
            with db() as conn:
                items = list_chats(conn, (query.get("q") or [""])[0].strip())
            return self.send_json(200, items)

        if len(parts) != 3 or not CHAT_ID.match(parts[2]):
            return self.send_json(404, {"error": "not found"})
        chat_id = parts[2]

        if method == "GET":
            with db() as conn:
                chat = load_chat(conn, chat_id)
            if chat is None:
                return self.send_json(404, {"error": "chat not found"})
            self.send_json(200, chat)
        elif method == "PUT":
            chat = json.loads(self.read_body())
            if not isinstance(chat, dict) or chat.get("id") != chat_id:
                return self.send_json(400, {"error": "chat id mismatch"})
            with db(write=True) as conn:
                save_chat(conn, chat)
            self.send_json(200, {"ok": True})
        elif method == "DELETE":
            with db(write=True) as conn:
                delete_messages(conn, chat_id)
                conn.execute("DELETE FROM chats WHERE id = ?", (chat_id,))
            self.send_json(200, {"ok": True})
        else:
            self.send_json(405, {"error": "method not allowed"})

    # ---------- app settings (e.g. defaults for new chats)
    def settings(self, method, path):
        parts = path.strip("/").split("/")  # ["api", "settings", <key>]
        if len(parts) == 2:
            if method != "GET":
                return self.send_json(405, {"error": "method not allowed"})
            with db() as conn:
                rows = conn.execute("SELECT key, value FROM settings").fetchall()
            return self.send_json(200, {key: json.loads(value) for key, value in rows})

        if len(parts) != 3 or not SETTING_KEY.match(parts[2]):
            return self.send_json(404, {"error": "not found"})
        key = parts[2]

        if method == "PUT":
            value = json.dumps(json.loads(self.read_body(MAX_SETTING)))
            with db(write=True) as conn:
                args = (value, int(time.time() * 1000), key)
                if conn.execute("UPDATE settings SET value = ?, updated = ? WHERE key = ?", args).rowcount == 0:
                    conn.execute("INSERT INTO settings (value, updated, key) VALUES (?, ?, ?)", args)
            self.send_json(200, {"ok": True})
        elif method == "DELETE":
            with db(write=True) as conn:
                conn.execute("DELETE FROM settings WHERE key = ?", (key,))
            self.send_json(200, {"ok": True})
        else:
            self.send_json(405, {"error": "method not allowed"})

    # ---------- Ollama proxy (streams responses as they arrive)
    def proxy(self, method, target):
        body = self.read_body() if method in ("POST", "PUT", "DELETE") else None
        conn = http.client.HTTPConnection(OLLAMA.hostname, OLLAMA.port or 80, timeout=900)
        try:
            try:
                conn.request(method, target, body=body,
                             headers={"Content-Type": "application/json"} if body else {})
                upstream = conn.getresponse()
            except OSError as exc:
                return self.send_json(502, {
                    "error": f"The AI engine is not reachable ({exc}). Start it with: systemctl --user start ollama"})
            self.send_response(upstream.status)
            self.send_header("Content-Type", upstream.getheader("Content-Type", "application/json"))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            # HTTP/1.0 response without Content-Length: the body ends when the connection closes.
            # If the browser disconnects (Stop), the write fails and closing conn cancels Ollama's work.
            while chunk := upstream.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            conn.close()


def main():
    parser = argparse.ArgumentParser(description="Aazad Chat: free, private AI on your own computer.")
    parser.add_argument("--backup", metavar="FILE", help="copy the chat database to FILE and exit")
    args = parser.parse_args()
    if args.backup:
        return backup(args.backup)

    init_db()
    import_legacy_chats()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"Aazad Chat on http://{HOST}:{PORT} (database: {DB_PATH}, {JOURNAL_MODE} mode;"
          f" ollama: {OLLAMA.geturl()})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
