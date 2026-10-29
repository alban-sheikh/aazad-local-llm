"""Tests for the server port: --port, AAZAD_CHAT_PORT, validation and the Host check.

Run with: python3 -m unittest discover -s tests
Uses a temporary data folder; never touches the real one. No Ollama needed.
"""
import http.client
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "server.py"
INVALID = ["abc", "0", "65536", "-1", "3.5", ""]

_tmp = tempfile.TemporaryDirectory()
os.environ["AAZAD_CHAT_DATA"] = _tmp.name  # before importing server, so it never sees the real folder
sys.path.insert(0, str(ROOT))
import server  # noqa: E402


def tearDownModule():
    _tmp.cleanup()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run_env(data_dir, port_env=None):
    env = {k: v for k, v in os.environ.items() if k != "AAZAD_CHAT_PORT"}
    env.update(AAZAD_CHAT_DATA=str(data_dir), AAZAD_CHAT_HOST="127.0.0.1", PYTHONUNBUFFERED="1")
    if port_env is not None:
        env["AAZAD_CHAT_PORT"] = port_env
    return env


class ResolvePortTest(unittest.TestCase):
    def test_default(self):
        self.assertEqual(server.resolve_port(None, None), 3210)
        self.assertEqual(server.resolve_port(None, ""), 3210)

    def test_env(self):
        self.assertEqual(server.resolve_port(None, "3298"), 3298)

    def test_flag_wins_over_env(self):
        self.assertEqual(server.resolve_port("3299", "3298"), 3299)
        self.assertEqual(server.resolve_port("3299", None), 3299)

    def test_limits(self):
        self.assertEqual(server.parse_port("1"), 1)
        self.assertEqual(server.parse_port("65535"), 65535)

    def test_invalid(self):
        for value in INVALID:
            with self.subTest(source="flag", value=value), self.assertRaises(ValueError):
                server.resolve_port(value, "3298")
            if value:  # an empty env variable means "not set"
                with self.subTest(source="env", value=value), self.assertRaises(ValueError):
                    server.resolve_port(None, value)

    def test_use_port_sets_allowed_hosts(self):
        try:
            server.use_port(3299)
            self.assertEqual(server.PORT, 3299)
            self.assertEqual(server.ALLOWED_HOSTS, {"127.0.0.1:3299", "localhost:3299"})
        finally:
            server.use_port(server.DEFAULT_PORT)


class CommandLineTest(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.TemporaryDirectory()
        self.addCleanup(self.data.cleanup)

    def run_server(self, args, port_env=None):
        return subprocess.run([sys.executable, str(SERVER), *args], env=run_env(self.data.name, port_env),
                              capture_output=True, text=True, timeout=30)

    def assert_plain_error(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 to 65535", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_invalid_flag(self):
        for value in INVALID:
            with self.subTest(value=value):
                result = self.run_server([f"--port={value}"])
                self.assert_plain_error(result)
                self.assertIn("--port", result.stderr)

    def test_invalid_env(self):
        for value in INVALID[:-1]:
            with self.subTest(value=value):
                result = self.run_server([], port_env=value)
                self.assert_plain_error(result)
                self.assertIn("AAZAD_CHAT_PORT", result.stderr)

    def test_import_with_bad_env_does_not_crash(self):
        result = subprocess.run([sys.executable, "-c", "import server"], cwd=ROOT,
                                env=run_env(self.data.name, "abc"), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_lists_port(self):
        result = self.run_server(["--help"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("--port", result.stdout)
        self.assertIn("AAZAD_CHAT_PORT", result.stdout)
        self.assertIn("3210", result.stdout)
        self.assertIn("--backup", result.stdout)


class LiveServerTest(unittest.TestCase):
    def start(self, args, port_env=None):
        data = tempfile.TemporaryDirectory()
        self.addCleanup(data.cleanup)
        proc = subprocess.Popen([sys.executable, str(SERVER), *args], env=run_env(data.name, port_env),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def stop():
            proc.terminate()
            proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()
        self.addCleanup(stop)
        line = proc.stdout.readline()  # the startup line, printed once the port is open
        self.assertIn("Aazad Chat on", line, proc.stderr.read() if proc.poll() is not None else "")
        return line

    def get(self, port, host):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        try:
            conn.putrequest("GET", "/", skip_host=True)
            conn.putheader("Host", host)
            conn.endheaders()
            response = conn.getresponse()
            return response.status, response.read()
        finally:
            conn.close()

    def test_port_flag(self):
        port, other = free_port(), free_port()
        line = self.start(["--port", str(port)], port_env=str(other))  # flag wins over env
        self.assertIn(f"http://127.0.0.1:{port} ", line)
        for host in (f"127.0.0.1:{port}", f"localhost:{port}"):
            status, body = self.get(port, host)
            self.assertEqual(status, 200, host)
            self.assertIn(b"<html", body.lower())
        for host in (f"127.0.0.1:{other}", "127.0.0.1:3210", f"example.com:{port}"):
            status, body = self.get(port, host)
            self.assertEqual(status, 403, host)
            self.assertIn(b"forbidden host", body)

    def test_env_port(self):
        port = free_port()
        line = self.start([], port_env=str(port))
        self.assertIn(f"http://127.0.0.1:{port} ", line)
        self.assertEqual(self.get(port, f"127.0.0.1:{port}")[0], 200)

    def test_port_in_use(self):
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", 0))
            busy.listen()
            port = busy.getsockname()[1]
            data = tempfile.TemporaryDirectory()
            self.addCleanup(data.cleanup)
            result = subprocess.run([sys.executable, str(SERVER), "--port", str(port)], env=run_env(data.name),
                                    capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot listen", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
