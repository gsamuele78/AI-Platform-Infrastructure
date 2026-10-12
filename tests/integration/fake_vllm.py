"""Minimal OpenAI-compatible stand-in for vLLM, used only by integration tests.

Enforces the same Bearer-token contract as `vllm serve` with VLLM_API_KEY, so
the test proves LiteLLM actually forwards the backend key.
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = os.environ["VLLM_API_KEY"]
MODEL = os.environ["SERVED_MODEL_NAME"]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self) -> bool:
        if self.headers.get("Authorization") == f"Bearer {API_KEY}":
            return True
        self._send(401, {"error": "Unauthorized"})
        return False

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send(200, {})
        elif self.path == "/v1/models" and self._authorised():
            self._send(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "fake"}]})
        elif not self.path.startswith("/v1/"):
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": "not found"})
            return
        if not self._authorised():
            return
        self._send(200, {
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", MODEL),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "pong"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - base signature
        return


ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
