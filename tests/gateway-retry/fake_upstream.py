# Fake upstream for the gateway retry test. X-Case picks the behaviour:
#   flaky:<id>  first request with this id: read it, then close the connection WITHOUT answering; later ones: 200
#   err503      always 503
#   slow        sleeps 7 s (longer than the gateway's 5 s response timeout), then 200
# GET /stats returns how many requests (and bodies) each case received.
import json, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
hits = {}; bodies = {}; lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode() if n else ""
        if self.path == "/stats": return self.reply(200, {"hits": hits, "bodies": bodies})
        case = self.headers.get("X-Case", "none"); key = f"{self.command} {case}"
        with lock:
            hits[key] = hits.get(key, 0) + 1; bodies.setdefault(key, []).append(body); first = hits[key] == 1
        if case.startswith("flaky") and first:
            self.close_connection = True
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            return
        if case == "err503": return self.reply(503, {"error": "upstream unavailable"})
        if case == "slow": time.sleep(7)
        self.reply(200, {"ok": True, "served": {"commit": "fake"}})
    do_GET = do_POST = handle_any
ThreadingHTTPServer(("127.0.0.1", 9099), H).serve_forever()
