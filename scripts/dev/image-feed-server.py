#!/usr/bin/env python3
"""Serve an image feed directory for development (runtime-maintenance.md §4.2).

    image-feed-server.py --root out/feed/apkrun/images --port 8443 \
        [--cert dev.pem --key dev-key.pem]

Serves `<root>/<channel>/feed.json` and `feed.json.sig` with ETag + Last-Modified
so `If-None-Match` conditional GETs return 304 — the same semantics the
production feed uses. Plain HTTP without `--cert` is for `APKRUN_TEST_*`
overrides only; the production client requires HTTPS.
"""

import argparse
import hashlib
import http.server
import ssl
from pathlib import Path


class FeedHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler plus ETag conditional GETs."""

    def end_headers(self) -> None:
        etag = getattr(self, "_etag", None)
        if etag:
            self.send_header("ETag", etag)
        super().end_headers()

    def send_head(self):  # noqa: N802 - stdlib naming
        path = self.translate_path(self.path)
        file = Path(path)
        if file.is_file():
            etag = '"%s"' % hashlib.sha256(file.read_bytes()).hexdigest()
            self._etag = etag
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.end_headers()
                return None
        return super().send_head()

    def log_message(self, fmt, *args):
        print("feed-server:", fmt % args)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    args = parser.parse_args()

    import functools

    handler = functools.partial(FeedHandler, directory=args.root)
    server = http.server.HTTPServer(("127.0.0.1", args.port), handler)
    if args.cert and args.key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    scheme = "https" if args.cert else "http"
    print(f"serving {args.root} on {scheme}://127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
