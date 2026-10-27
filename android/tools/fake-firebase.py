#!/usr/bin/env python3
"""A local stand-in for the two Firebase surfaces Halo uses, so the Android app's whole sync path can be
driven on an emulator without a Firebase project:

  POST /identitytoolkit/v1/accounts:signInWithPassword   (Email/Password sign-in)
  POST /securetoken/v1/token                              (refresh)
  GET/PUT/DELETE /<path>.json?auth=<token>[&shallow=true] (Realtime Database REST)
  GET /<path>.json   Accept: text/event-stream            (live stream: put + keep-alive)
  GET /_dump                                              (inspection only: the whole tree, no auth)

It is a development tool, not a Firebase emulator: it implements exactly the calls Halo makes, requires a
valid token for every data call (an unauthenticated read is 401, like locked rules), and keeps everything in
memory. The emulator reaches the Mac as http://10.0.2.2:<port> (debug builds only allow that — DebugEndpoints).
"""
import json, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EMAIL, PASSWORD, UID = "me@halo.test", "halo-test-password", "uid-test-1"
LOCK = threading.Lock()
TREE = {}
TOKENS = set()
COUNTER = [0]

def parts(path): return [p for p in urllib.parse.unquote(path).split("/") if p]
def get(path):
    cur = TREE
    for p in path:
        if not isinstance(cur, dict) or p not in cur: return None
        cur = cur[p]
    return cur
def put(path, value):
    if not path:
        TREE.clear()
        if isinstance(value, dict): TREE.update(value)
        return
    cur = TREE
    for p in path[:-1]:
        if not isinstance(cur.get(p), dict): cur[p] = {}
        cur = cur[p]
    if value is None: cur.pop(path[-1], None)
    else: cur[path[-1]] = value
    # RTDB prunes empty parents
    for i in range(len(path) - 1, 0, -1):
        node = get(path[:i])
        if isinstance(node, dict) and not node: put(path[:i], None)
        else: break

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a): sys.stderr.write("[fake-firebase] " + (fmt % a) + "\n")

    def _json(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_POST(self):
        u = urllib.parse.urlparse(self.path); body = self._body()
        if u.path.endswith("accounts:signInWithPassword"):
            d = json.loads(body or b"{}")
            if d.get("email") != EMAIL or d.get("password") != PASSWORD:
                return self._json(400, {"error": {"message": "INVALID_LOGIN_CREDENTIALS"}})
            with LOCK: COUNTER[0] += 1; tok = "id-%d" % COUNTER[0]; TOKENS.add(tok)
            return self._json(200, {"idToken": tok, "refreshToken": "refresh-1", "localId": UID, "expiresIn": "3600"})
        if u.path.endswith("/token"):
            with LOCK: COUNTER[0] += 1; tok = "id-%d" % COUNTER[0]; TOKENS.add(tok)
            return self._json(200, {"id_token": tok, "refresh_token": "refresh-1", "user_id": UID, "expires_in": "3600"})
        self._json(404, {})

    def _auth(self, q):
        t = (q.get("auth") or [None])[0]
        if t not in TOKENS: self._json(401, {"error": "Permission denied"}); return False
        return True

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/_dump":
            with LOCK: return self._json(200, TREE)
        if not u.path.endswith(".json"): return self._json(404, {})
        if not self._auth(q): return
        path = parts(u.path[:-5])
        if "text/event-stream" in (self.headers.get("Accept") or ""): return self._stream(path)
        with LOCK: v = get(path)
        if q.get("shallow") == ["true"] and isinstance(v, dict): v = {k: True for k in v}
        self._json(200, v)

    def do_PUT(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); body = self._body()
        if not self._auth(q): return
        with LOCK: put(parts(u.path[:-5]), json.loads(body))
        self._json(200, json.loads(body))

    def do_DELETE(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); self._body()
        if not self._auth(q): return
        with LOCK: put(parts(u.path[:-5]), None)
        self._json(200, None)

    def _stream(self, path):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.send_header("Connection", "close"); self.end_headers()
        def emit(event, data):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data) if event != "keep-alive" else "null")).encode()); self.wfile.flush()
        try:
            with LOCK: snap = get(path)
            seen = set(snap.keys()) if isinstance(snap, dict) else set()
            emit("put", {"path": "/", "data": snap})
            beat = 0
            while True:
                time.sleep(0.25); beat += 1
                with LOCK: cur = get(path)
                if isinstance(cur, dict):
                    for k in list(cur.keys()):
                        if k not in seen: seen.add(k); emit("put", {"path": "/" + k, "data": cur[k]})
                    seen &= set(cur.keys())
                if beat % 20 == 0: emit("keep-alive", None)
        except (BrokenPipeError, ConnectionResetError): pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9199
    print("fake firebase on 0.0.0.0:%d  login %s / %s  uid %s" % (port, EMAIL, PASSWORD, UID), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
