import io
import json
import unittest
from unittest.mock import Mock

from server import Handler


class ServerTest(unittest.TestCase):
    def request(self, path):
        connection = Mock()
        connection.makefile.return_value = io.BytesIO(
            f"GET {path} HTTP/1.0\r\n\r\n".encode()
        )
        Handler(connection, ("127.0.0.1", 0), None)
        response = b"".join(call.args[0] for call in connection.sendall.call_args_list)
        headers, body = response.split(b"\r\n\r\n", 1)
        status = int(headers.split()[1])
        self.assertIn(b"Content-Type: application/json", headers)
        return status, json.loads(body)

    def test_service(self):
        status, body = self.request("/")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "pathnex")

    def test_probes(self):
        for path in ("/healthz", "/readyz"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path), (200, {"status": "ok"}))

    def test_missing_route(self):
        self.assertEqual(self.request("/missing"), (404, {"error": "not found"}))
