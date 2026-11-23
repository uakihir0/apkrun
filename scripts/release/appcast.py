#!/usr/bin/env python3
"""Builds the Sparkle appcast item for one release and signs the feed
(runtime-maintenance.md §3.3, workflow.md §9.4).

Usage:
    appcast.py add --version 1.2.0 --build 1200 --archive APKRun-1.2.0.zip \
        --signature <base64 EdDSA> --feed-base-url https://<updates host>/ \
        [--notes-url https://<updates host>/notes/1.2.0] \
        [--channel beta] [--critical-build <build>] [--dry-run-out DIR]

Writes `appcast.xml` (plus `appcast.xml.sig` when a signing key is in the
environment) into the output directory. In dry-run mode the enclosure URL is
relative to --feed-base-url and nothing is uploaded.
"""
import argparse
import base64
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def q(name: str) -> str:
    return "{%s}%s" % (SPARKLE_NS, name)


def sign_file(path: str) -> str:
    """Signs `path` with scripts/release/sign-update.swift."""
    script = os.path.join(os.path.dirname(__file__), "sign-update.swift")
    out = subprocess.run(
        ["xcrun", "swift", script, path],
        check=True, capture_output=True, text=True,
    )
    return out.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["add"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--archive", required=True, help="path to the signed zip")
    parser.add_argument("--signature", required=True, help="base64 EdDSA signature of the archive")
    parser.add_argument("--feed-base-url", required=True)
    parser.add_argument("--notes-url", default=None)
    parser.add_argument("--channel", default="stable", choices=["stable", "beta"])
    parser.add_argument("--critical-build", type=int, default=None)
    parser.add_argument("--phased-rollout-interval", type=int, default=86400)
    parser.add_argument("--minimum-system-version", default="27.0")
    parser.add_argument("--existing", default=None, help="merge into an existing appcast.xml")
    parser.add_argument("--out", default="build/release")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)

    if args.existing and os.path.exists(args.existing):
        tree = ET.parse(args.existing)
        root = tree.getroot()
        channel_el = root.find("channel")
    else:
        # Namespaces are registered above so ElementTree emits them on the
        # root at write time; setting them by hand duplicates the decls.
        root = ET.Element("rss", version="2.0")
        channel_el = ET.SubElement(root, "channel")
        ET.SubElement(channel_el, "title").text = "APKRun updates"
        ET.SubElement(channel_el, "link").text = args.feed_base_url

    item = ET.SubElement(channel_el, "item")
    ET.SubElement(item, "title").text = "APKRun %s" % args.version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, q("version")).text = str(args.build)
    ET.SubElement(item, q("shortVersionString")).text = args.version
    ET.SubElement(item, q("minimumSystemVersion")).text = args.minimum_system_version
    notes = args.notes_url or "%snotes/%s.html" % (args.feed_base_url.rstrip("/") + "/", args.version)
    ET.SubElement(item, q("releaseNotesLink")).text = notes
    if args.channel == "stable":
        ET.SubElement(item, q("phasedRolloutInterval")).text = str(args.phased_rollout_interval)
    else:
        ET.SubElement(item, q("channel")).text = args.channel
    if args.critical_build is not None:
        critical = ET.SubElement(item, q("criticalUpdate"))
        critical.set(q("version"), str(args.critical_build))
    archive_name = os.path.basename(args.archive)
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", "%s%s" % (args.feed_base_url.rstrip("/") + "/", archive_name))
    enclosure.set("length", str(os.path.getsize(args.archive)))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(q("edSignature"), args.signature)

    out_path = os.path.join(args.out, "appcast.xml")
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(out_path, encoding="utf-8", xml_declaration=True)

    if os.environ.get("APKRUN_SPARKLE_ED_PRIVATE_KEY"):
        signature = sign_file(out_path)
        with open(out_path + ".sig", "w") as handle:
            handle.write(signature + "\n")
        print("signed feed:", out_path + ".sig")
    print("appcast:", out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
