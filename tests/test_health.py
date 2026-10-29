"""Tests for GET /api/health (standard library only)."""
import http.client
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

DATA = tempfile.TemporaryDirectory()
os.environ["AAZAD_CHAT_DATA"] = DATA.name
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server  # noqa: E402


class HealthTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=5)

    def request(self, method, path, host=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            # ALLOWED_HOSTS is built from server.PORT, not the random test port.
            hdrs = {"Host": host or f"127.0.0.1:{server.PORT}"}
            hdrs.update(headers or {})
            conn.request(method, path, headers=hdrs)
            resp = conn.getresponse()
            return resp.status, resp.getheader("Content-Type"), resp.read()
        finally:
            conn.close()

    def test_get_returns_ok_and_version(self):
        status, ctype, body = self.request("GET", "/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(ctype, "application/json")
        self.assertEqual(json.loads(body), {"ok": True, "version": server.VERSION})

    def test_version_is_non_empty_string(self):
        self.assertIsInstance(server.VERSION, str)
        self.assertTrue(server.VERSION)

    def test_works_without_x_aazad_chat_header(self):
        # self.request never sends X-Aazad-Chat
        status, _, body = self.request("GET", "/api/health", host=f"localhost:{server.PORT}")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["ok"], True)

    def test_query_string(self):
        status, _, body = self.request("GET", "/api/health?x=1")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True, "version": server.VERSION})

    def test_bad_host_forbidden(self):
        status, _, _ = self.request("GET", "/api/health", host="evil.example")
        self.assertEqual(status, 403)

    def test_other_methods_not_allowed(self):
        for method in ("POST", "PUT", "DELETE"):
            with self.subTest(method=method):
                status, ctype, body = self.request(method, "/api/health")
                self.assertEqual(status, 405)
                self.assertEqual(ctype, "application/json")
                self.assertIn("error", json.loads(body))

    def test_does_not_create_database(self):
        self.request("GET", "/api/health")
        self.assertFalse(os.path.exists(os.path.join(DATA.name, "aazad-chat.db")))


if __name__ == "__main__":
    unittest.main()
