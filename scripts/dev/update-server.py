#!/usr/bin/env python3
"""Local update test service for the DirectProvider (Debug builds only).

Serves Tests/Fixtures/update-repos/ on http://127.0.0.1:<port>:

  /local/<package>/<versionCode>/manifest.json   synthesized Direct manifest
  /local/<package>/<versionCode>/<file>          artifact bytes
  /direct/<path>                                  fixtures under direct/
  /fdroid/<path>                                  the F-Droid v2 fixture repo
  /github/<owner>/<name>/releases                 GitHub Releases fixture JSON
  /github-limited/...                             403 with an exhausted rate limit
  /github-assets/<file>                           release asset bytes
  /github-needauth/<owner>/<name>/releases        releases only with Authorization
  /github-probe-listing                           releases only without Authorization
  /github-probe-asset                             asset bytes only without Authorization
  /github-redirect/releases                       302 to the no-auth probe (localhost)
  /status/<code>                                  empty reply with that status
  /redirect/<code>/<path>                         3xx to /<path>

The /github JSON fixtures substitute `__BASE__` and `__BASE_LOCALHOST__`
(same server, different host) so asset URLs and redirects exercise the
provider's cross-host Authorization handling.

If-None-Match is honored: synthesized manifests and fixture files carry a
weak ETag, and a matching request answers 304. `--delay <seconds>` holds
every response, for the slow-provider tests (update-system.md §3.4).
"""

import argparse
import hashlib
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


def find_repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", ".."))


def etag_for(data: bytes) -> str:
    return '"%s"' % hashlib.sha256(data).hexdigest()[:16]


def safe_join(root: str, rel: str) -> str:
    path = os.path.normpath(os.path.join(root, rel))
    if not (path == root or path.startswith(root + os.sep)):
        return ""
    return path


def split_artifact(name: str) -> dict:
    """Maps a stored filename to a manifest artifact object."""
    artifact = {"name": name}
    if name == "app.apk" or name == "base.apk":
        artifact["type"] = "apk"
    elif name.startswith("split_") and name.endswith(".apk"):
        artifact["type"] = "split"
        artifact["splitName"] = name[len("split_"):-len(".apk")]
    elif name.endswith(".apks"):
        artifact["type"] = "apks"
    else:
        return {}
    return artifact


def local_manifest(root: str, package: str, version: str, base_url: str):
    """Builds a Direct manifest for update-repos/local/<pkg>/<ver>/."""
    directory = safe_join(root, os.path.join("local", package, version))
    if not directory or not os.path.isdir(directory):
        return None
    try:
        version_code = int(version)
    except ValueError:
        return None
    artifacts = []
    for name in sorted(os.listdir(directory)):
        shape = split_artifact(name)
        if not shape:
            continue
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            data = handle.read()
        entry = {
            "type": shape["type"],
            "url": "%s/local/%s/%s/%s" % (base_url, package, version, name),
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        }
        if "splitName" in shape:
            entry["splitName"] = shape["splitName"]
        artifacts.append(entry)
    if not artifacts:
        return None
    manifest = {
        "schemaVersion": 1,
        "packageId": package,
        "versionCode": version_code,
        "artifacts": artifacts,
    }
    return json.dumps(manifest).encode("utf-8")


def read_file(root: str, rel: str):
    path = safe_join(root, rel)
    if not path or not os.path.isfile(path):
        return None
    with open(path, "rb") as handle:
        return handle.read()


class Handler(BaseHTTPRequestHandler):
    root = "."
    delay = 0.0
    base_url = ""
    base_localhost = ""

    def log_message(self, *_args):  # quiet
        pass

    def github_listing(self, rel: str):
        """A releases JSON fixture with __BASE__/__BASE_LOCALHOST__ filled in."""
        data = read_file(self.root, rel)
        if data is None:
            return None
        text = data.decode("utf-8")
        text = text.replace("__BASE_LOCALHOST__", self.base_localhost)
        text = text.replace("__BASE__", self.base_url)
        return text.encode("utf-8")

    def do_GET(self):
        if self.delay:
            time.sleep(self.delay)
        if_none_match = self.headers.get("If-None-Match")
        parts = [unquote(p) for p in urlsplit(self.path).path.split("/") if p]

        body = None
        status = 200
        headers = {"Content-Type": "application/octet-stream"}

        if parts[:1] == ["status"] and len(parts) == 2:
            try:
                status = int(parts[1])
            except ValueError:
                status = 400
            body = b""
            if status in (429, 503):
                headers["Retry-After"] = "30"
        elif parts[:1] == ["redirect"] and len(parts) >= 3:
            try:
                status = int(parts[1])
            except ValueError:
                status = 400
            target = "/" + "/".join(parts[2:])
            headers["Location"] = target
            body = b""
        elif parts[:1] == ["local"] and len(parts) == 4 and parts[3] == "manifest.json":
            body = local_manifest(self.root, parts[1], parts[2], self.base_url)
            headers["Content-Type"] = "application/json"
        elif parts[:1] == ["local"]:
            body = read_file(self.root, os.path.join(*parts))
        elif parts[:1] == ["direct"]:
            body = read_file(self.root, os.path.join(*parts))
            if parts[-1].endswith(".json"):
                headers["Content-Type"] = "application/json"
        elif parts[:1] == ["fdroid"]:
            body = read_file(self.root, os.path.join(*parts))
            if parts[-1].endswith(".json"):
                headers["Content-Type"] = "application/json"
        elif parts[:1] == ["github-limited"]:
            status = 403
            headers["x-ratelimit-remaining"] = "0"
            headers["x-ratelimit-reset"] = str(int(time.time()) + 3600)
            body = b""
        elif parts == ["github-probe-listing"]:
            if self.headers.get("Authorization"):
                status = 403
                body = b""
            else:
                body = self.github_listing(os.path.join("github", "probe", "releases.json"))
                headers["Content-Type"] = "application/json"
        elif parts == ["github-probe-asset"]:
            if self.headers.get("Authorization"):
                status = 403
                body = b""
            else:
                body = read_file(self.root, os.path.join("github-assets", "probe.apk"))
        elif parts[:1] == ["github-needauth"] and parts[1:2] == ["repos"] \
                and parts[-1] == "releases" and len(parts) == 5:
            if not self.headers.get("Authorization"):
                status = 403
                body = b""
            else:
                body = self.github_listing(os.path.join("github", parts[2], parts[3], "releases.json"))
                headers["Content-Type"] = "application/json"
        elif parts[:1] == ["github-assets"]:
            body = read_file(self.root, os.path.join(*parts))
        elif parts[:2] == ["github", "repos"] and parts[2] == "redirect" \
                and parts[-1] == "releases":
            status = 302
            headers["Location"] = "%s/github-probe-listing" % self.base_localhost
            body = b""
        elif parts[:2] == ["github", "repos"] and parts[-1] == "releases" and len(parts) == 5:
            body = self.github_listing(os.path.join("github", parts[2], parts[3], "releases.json"))
            headers["Content-Type"] = "application/json"
        else:
            body = None

        if body is None:
            self.send_response(404)
            self.end_headers()
            return

        etag = etag_for(body)
        headers["ETag"] = etag
        if status == 200 and if_none_match == etag:
            status = 304
            body = b""

        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    do_HEAD = do_GET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=os.path.join(find_repo_root(), "Tests", "Fixtures", "update-repos"),
        help="fixture root (default: %(default)s)")
    parser.add_argument("--port", type=int, default=0, help="listen port (0 = random)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--delay", type=float, default=0.0,
        help="seconds to hold every response")
    args = parser.parse_args()

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        sys.exit("update-server.py only serves loopback")

    Handler.root = os.path.abspath(args.root)
    Handler.delay = args.delay

    # Bind manually: HTTPServer.server_bind resolves the host with
    # socket.getfqdn, which hangs on hosts without reverse DNS.
    server = ThreadingHTTPServer(
        (args.host, args.port), Handler, bind_and_activate=False)
    server.socket.bind((args.host, args.port))
    server.socket.listen(server.request_queue_size)
    server.server_name = args.host
    host, port = server.socket.getsockname()[:2]
    server.server_port = port
    server.server_address = (host, port)
    Handler.base_url = "http://%s:%d" % (
        "127.0.0.1" if host == "localhost" else host, port)
    Handler.base_localhost = "http://localhost:%d" % port
    print("update-server.py: %s serving %s" % (Handler.base_url, Handler.root), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
