#!/usr/bin/env python3
"""Build and sign an image feed (runtime-maintenance.md §4.1, §4.9).

Writes `<channel>/feed.json` and `feed.json.sig` into a feed directory:

    image-feed.py --image-version 2026.11.1 --archive images/2026.11.1.aar \
        --channel stable --sequence 7 --key release-ed25519.pem \
        --out out/feed/apkrun/images

The release pipeline runs this after uploading the .aar; the resign workflow
runs it with `--sequence <n+1>` and the same entries to extend `expiresAt`.
Ed25519 signing uses the system `openssl` (the seed is a PEM private key).

Security review: this script signs release artifacts; changes to it need the
"Security review:" commit note (docs/05-development/workflow.md §7).
"""

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

SIGNATURE_TAG = "apkrun-signature-v1"
FEED_LIFETIME_DAYS = 30


def run(*args: str) -> bytes:
    return subprocess.run(args, check=True, capture_output=True).stdout


def public_key_bytes(key_pem: Path) -> bytes:
    der = run("openssl", "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER")
    # An Ed25519 SPKI DER blob is 44 bytes: a 12-byte header + the raw key.
    if len(der) != 44:
        sys.exit(f"unexpected Ed25519 public key DER length {len(der)}")
    return der[12:]


def key_id(public_key: bytes) -> str:
    return hashlib.sha256(public_key).digest()[:8].hex()


def sign(message: bytes, key_pem: Path) -> bytes:
    with tempfile.NamedTemporaryFile() as tmp:
        tmp.write(message)
        tmp.flush()
        return run(
            "openssl", "pkeyutl", "-sign", "-rawin",
            "-inkey", str(key_pem), "-in", tmp.name,
        )


def write_signature(message: bytes, key_pem: Path, out: Path) -> None:
    pub = public_key_bytes(key_pem)
    signature = sign(message, key_pem)
    out.write_text(
        f"{SIGNATURE_TAG}\n"
        f"key-id: {key_id(pub)}\n"
        f"algorithm: ed25519\n"
        f"signature: {base64.b64encode(signature).decode()}\n",
        encoding="ascii",
    )


def entry(args: argparse.Namespace, archive_url: str) -> dict:
    archive = Path(args.archive)
    return {
        "imageVersion": args.image_version,
        "kind": args.kind,
        "publishedAt": args.published_at
        or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "archive": {
            "url": archive_url,
            "size": archive.stat().st_size,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        },
        "expandedSize": args.expanded_size or archive.stat().st_size,
        "requirements": {
            "minimumRuntimeVersion": args.minimum_runtime_version,
            "guestProtocol": {"min": args.proto_min, "max": args.proto_max},
        },
        "userdata": {
            "schemaVersion": args.schema_version,
            "upgradableFrom": [int(v) for v in args.upgradable_from.split(",")],
        },
        "upgradeFrom": {"minimumImageVersion": args.minimum_source_version},
        "critical": args.critical,
        "rolloutPercent": args.rollout_percent,
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--resign", action="store_true",
                   help="only re-sign --keep feeds with a new sequence")
    p.add_argument("--image-version")
    p.add_argument("--archive", help="the .aar file")
    p.add_argument("--archive-url", help="download URL; default <base>/<name>")
    p.add_argument("--base-url", default="https://images.apkrun.io/apkrun/images")
    p.add_argument("--channel", default="stable", choices=["stable", "beta"])
    p.add_argument("--sequence", type=int, required=True)
    p.add_argument("--kind", default="apkrun")
    p.add_argument("--published-at")
    p.add_argument("--expanded-size", type=int, default=0)
    p.add_argument("--minimum-runtime-version", default="1.0")
    p.add_argument("--proto-min", type=int, default=1)
    p.add_argument("--proto-max", type=int, default=1)
    p.add_argument("--schema-version", type=int, default=1)
    p.add_argument("--upgradable-from", default="1")
    p.add_argument("--minimum-source-version", default="0.0")
    p.add_argument("--critical", action="store_true")
    p.add_argument("--rollout-percent", type=int, default=100)
    p.add_argument("--keep", action="append", default=[],
                   help="a previous feed.json whose entries stay in the feed")
    p.add_argument("--key", required=True, help="Ed25519 PEM private key")
    p.add_argument("--out", required=True, help="the feed output directory")
    args = p.parse_args()

    images = []
    if not args.resign:
        if not args.image_version or not args.archive:
            p.error("--image-version and --archive are required without --resign")
        archive = Path(args.archive)
        url = args.archive_url or f"{args.base_url}/{args.channel}/{archive.name}"
        images.append(entry(args, url))
    for keep in args.keep:
        images.extend(json.loads(Path(keep).read_text())["images"])
    if len(images) > 256:
        sys.exit("a feed holds at most 256 entries (§4.1)")

    now = datetime.now(timezone.utc)
    feed = {
        "schemaVersion": 1,
        "channel": args.channel,
        "sequence": args.sequence,
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": (now + timedelta(days=FEED_LIFETIME_DAYS))
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "images": images,
    }

    out_dir = Path(args.out) / args.channel
    out_dir.mkdir(parents=True, exist_ok=True)
    feed_bytes = json.dumps(feed, indent=2, sort_keys=True).encode() + b"\n"
    (out_dir / "feed.json").write_bytes(feed_bytes)
    write_signature(feed_bytes, Path(args.key), out_dir / "feed.json.sig")
    print(f"wrote {out_dir}/feed.json (sequence {args.sequence})")


if __name__ == "__main__":
    main()
