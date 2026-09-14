#!/usr/bin/env python3
"""Aazad Chat: a small local web server for the chat UI.

- Serves the page from ./web
- Saves conversations as JSON files in ~/.local/share/aazad-chat/chats
- Proxies /ollama/* to the shared Ollama server, so the browser talks to one origin

Only listens on 127.0.0.1. Standard library only.
"""
import http.client
import json
import os
import re
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HOST = os.environ.get("AAZAD_CHAT_HOST", "127.0.0.1")
PORT = int(os.environ.get("AAZAD_CHAT_PORT", "3210"))
OLLAMA = urlsplit(os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"))
WEB_DIR = Path(__file__).resolve().parent / "web"
DATA_DIR = Path(os.environ.get("AAZAD_CHAT_DATA", Path.home() / ".local/share/aazad-chat")) / "chats"

CHAT_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_BODY = 64 * 1024 * 1024  # chats can hold base64 images
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

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
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
        path = urlsplit(self.path).path
        try:
            if path.startswith("/ollama/"):
                if self.allowed(api=True):
                    self.proxy(method, self.path[len("/ollama"):])
            elif path == "/api/chats" or path.startswith("/api/chats/"):
                if self.allowed(api=True):
                    self.chats(method, path)
            elif method == "GET":
                if self.allowed(api=False):
                    self.static(path)
            else:
                self.send_json(405, {"error": "method not allowed"})
        except (BrokenPipeError, ConnectionResetError):
            pass  # browser closed the connection (e.g. Stop button)
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
    def chats(self, method, path):
        parts = path.strip("/").split("/")  # ["api", "chats", <id>]
        if len(parts) == 2:
            if method != "GET":
                return self.send_json(405, {"error": "method not allowed"})
            items = []
            for file in DATA_DIR.glob("*.json"):
                try:
                    chat = json.loads(file.read_text())
                    items.append({"id": chat["id"], "title": chat.get("title", "Untitled"),
                                  "model": chat.get("model", ""), "updated": chat.get("updated", 0)})
                except (OSError, ValueError, KeyError):
                    continue
            items.sort(key=lambda c: c["updated"], reverse=True)
            return self.send_json(200, items)

        if len(parts) != 3 or not CHAT_ID.match(parts[2]):
            return self.send_json(404, {"error": "not found"})
        file = DATA_DIR / f"{parts[2]}.json"

        if method == "GET":
            if not file.is_file():
                return self.send_json(404, {"error": "chat not found"})
            body = file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif method == "PUT":
            chat = json.loads(self.read_body())
            if not isinstance(chat, dict) or chat.get("id") != parts[2]:
                return self.send_json(400, {"error": "chat id mismatch"})
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=DATA_DIR, suffix=".tmp")
            with os.fdopen(fd, "w") as out:
                json.dump(chat, out)
            os.replace(tmp, file)  # atomic: never leaves a half-written chat
            self.send_json(200, {"ok": True})
        elif method == "DELETE":
            file.unlink(missing_ok=True)
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
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"Aazad Chat on http://{HOST}:{PORT} (chats: {DATA_DIR}, ollama: {OLLAMA.geturl()})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
