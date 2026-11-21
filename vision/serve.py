#!/usr/bin/env python3
"""The step finder as a small web service, for the glasses or the phone to send frames to.

    python3 vision/serve.py                 # http://127.0.0.1:8765, this Mac only
    python3 vision/serve.py --lan           # reachable on the Wi-Fi; prints a token senders must give

    POST /check?step=7[&view=1][&both=1]    body: a JPEG or PNG of the real build (at most 4096 x 4096)
         header X-Token: <token>            (only with --lan)
        -> {"step": 7, "p_done": 0.93, "done": true, "advance": false, "seconds": 2.4, ...}
           "advance" is the Follower's verdict: true once enough frames in a row say done.
           Each sender (address) has its own Follower.
    GET  /health                            -> {"ok": true, "steps": 23}

One check at a time (the model is the bottleneck); frames that arrive meanwhile wait.
"""
from __future__ import annotations

import argparse
import hmac
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stepvision as sv  # noqa: E402

MAX_BODY = 8 * 1024 * 1024
MAX_SENDERS = 16


def make_handler(build: sv.Build, threshold: float, frames: int, model: str, token: str | None):
    lock = threading.Lock()
    followers: dict[str, sv.Follower] = {}

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code: int, obj: dict):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if urlparse(self.path).path == '/health':
                return self._send(200, {'ok': True, 'steps': len(build)})
            self._send(404, {'error': 'not found'})

        def do_POST(self):
            url = urlparse(self.path)
            if url.path != '/check':
                return self._send(404, {'error': 'not found'})
            if token is not None and not hmac.compare_digest(self.headers.get('X-Token', ''), token):
                return self._send(403, {'error': 'wrong or missing X-Token'})
            q = {k: v[-1] for k, v in parse_qs(url.query).items()}
            try:
                step = int(q['step'])
                view = int(q['view']) if 'view' in q else None
                length = int(self.headers.get('Content-Length', 0))
                if not 0 < length <= MAX_BODY:
                    return self._send(400, {'error': 'send the picture as the request body (max 8 MB)'})
                photo = self.rfile.read(length)
                with lock:
                    r = sv.check_step(photo, step, build=build, view=view, both_orders=q.get('both') == '1', model=model)
                    sender = self.client_address[0]
                    if sender not in followers and len(followers) >= MAX_SENDERS:
                        followers.clear()
                    follower = followers.setdefault(sender, sv.Follower(threshold, frames))
                    r['advance'] = follower.update(step, r['p_done'])
                self._send(200, r)
            except (KeyError, ValueError) as e:
                self._send(400, {'error': f'bad request: {e}'})
            except Exception as e:  # the model or the picture failed; the caller just tries the next frame
                self._send(500, {'error': str(e)})

        def log_message(self, fmt, *args):
            sys.stderr.write('%s %s\n' % (self.address_string(), fmt % args))

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--port', type=int, default=8765)
    ap.add_argument('--lan', action='store_true', help='listen on all networks, not only this Mac (needs a token)')
    ap.add_argument('--token', help='with --lan: the token senders must give (default: a new random one, printed)')
    ap.add_argument('--model', default=sv.MODEL)
    ap.add_argument('--threshold', type=float, default=0.8)
    ap.add_argument('--frames', type=int, default=2, help='checks in a row needed to move on')
    a = ap.parse_args(argv)
    host = '0.0.0.0' if a.lan else '127.0.0.1'
    token = (a.token or secrets.token_urlsafe(16)) if a.lan else None
    handler = make_handler(sv.Build(), a.threshold, a.frames, a.model, token)
    server = ThreadingHTTPServer((host, a.port), handler)
    print(f'step finder on http://{host}:{a.port} (model {a.model})', flush=True)
    if token:
        print(f'senders must send the header  X-Token: {token}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    sys.exit(main())
