"""Run the G2 pass conditions (roadmap.md §2) against the spike harness.

Experiment only: the gate itself is `Tests/AcceptanceTests/G2/` (#014). This
resets the instance, then runs N cold boots in a row (VM stopped between
boots). For each boot it checks:

1. `VIRTUAL_DEVICE_BOOT_COMPLETED` on hvc0 within the boot timeout
   (900 s on the first boot, 180 s after);
2. `getprop sys.boot_completed` over the serial shell returns 1;
3. for the dwell time: `sys.system_server.start_count` stays 1, no
   Watchdog kill of system_server, and no init service exits three or more
   times (the #095 crash-loop definition).

The first boot also applies the first-boot settings (Bluetooth off, Wi-Fi on
VirtWifi) through standard Android commands on the serial shell.

Usage:
    python3 -I g2_spike.py --boot <boot dir> --name <run> [--boots 5] [--dwell 600]
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HARNESS_OPTIONS = [
    "--console-ports",
    "10",
    "--extra-console-ports",
    "10",
    "--gpu",
    "vz2d",
    "--sensors-port",
    "18",
    "--nics",
    "3",
    "--nic-macs",
    "02:a5:4b:00:00:01,02:a5:4b:00:00:02,02:15:b2:00:00:00",
]
EXIT_LINE = re.compile(r"init: Service '([^']+)' \(pid \d+\) (?:exited|received signal|killed)")
ONESHOT_OK = {"media.codeclist.generator", "apexd", "artd"}


def shell(run: Path, command: str, timeout: int = 60) -> str:
    result = subprocess.run(
        [str(HERE / "shell.sh"), str(run), command],
        capture_output=True,
        text=True,
        timeout=timeout + 10,
        env={"SHELL_TIMEOUT": str(timeout), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
    if result.returncode != 0:
        raise RuntimeError(f"shell command failed: {command}: {result.stderr.strip()}")
    return result.stdout.rsplit("__END_", 1)[0].strip()


def wait_for(path: Path, needle: str, timeout: float, start: int = 0) -> float | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and needle in path.read_text(errors="replace")[start:]:
            return time.monotonic()
        time.sleep(0.5)
    return None


def boot_once(args: argparse.Namespace, index: int) -> dict:
    run = REPO / "Images/work/16373615/vz-spike/runs" / args.name
    out = REPO / f"Images/work/16373615/vz-spike/{args.name}-boot{index}.out"
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "KEEP_DISKS": "0" if index == 1 else "1"}
    started = time.monotonic()
    with open(out, "w") as handle:
        process = subprocess.Popen(
            [
                str(HERE / "run.sh"),
                str(args.boot),
                args.name,
                "--timeout",
                str(args.dwell + 1200),
                *HARNESS_OPTIONS,
            ],
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=HERE,
        )
    record: dict = {"boot": index}
    timeout = 900 if index == 1 else 180
    seen = wait_for(out, "BOOT COMPLETED detected", timeout)
    record["bootCompletedSeconds"] = None if seen is None else round(seen - started, 1)
    if seen is None:
        process.terminate()
        process.wait(30)
        record["result"] = "fail: no VIRTUAL_DEVICE_BOOT_COMPLETED"
        return record
    record["sysBootCompleted"] = shell(run, "getprop sys.boot_completed")
    if index == 1:
        shell(run, "cmd bluetooth_manager disable")
        shell(
            run,
            "cmd wifi set-wifi-enabled enabled; sleep 6; cmd wifi connect-network VirtWifi open",
            timeout=90,
        )
    console_start = (run / "console.log").stat().st_size
    logcat_start = (run / "logcat.log").stat().st_size
    time.sleep(args.dwell)
    record["startCount"] = shell(run, "getprop sys.system_server.start_count")
    record["validatedWifi"] = "VALIDATED" in shell(
        run, "dumpsys connectivity | grep -E '^  NetworkAgentInfo' | grep WIFI"
    )
    console = (run / "console.log").read_text(errors="replace")[console_start:]
    logcat = (run / "logcat.log").read_text(errors="replace")[logcat_start:]
    exits = collections.Counter(EXIT_LINE.findall(console))
    record["serviceExits"] = dict(exits)
    record["crashLoops"] = sorted(
        name for name, count in exits.items() if count >= 3 and name not in ONESHOT_OK
    )
    record["watchdogKills"] = logcat.count("WATCHDOG KILLING SYSTEM PROCESS")
    record["tombstones"] = dict(
        collections.Counter(re.findall(r"F DEBUG   : Cmdline: (\S+)", logcat))
    )
    ok = (
        record["sysBootCompleted"] == "1"
        and record["startCount"] == "1"
        and not record["crashLoops"]
        and record["watchdogKills"] == 0
    )
    record["result"] = "pass" if ok else "fail"
    try:
        shell(run, "su 0 reboot -p", timeout=10)
    except (RuntimeError, subprocess.TimeoutExpired):
        pass
    try:
        process.wait(60)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(30)
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boot", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--boots", type=int, default=5)
    parser.add_argument("--dwell", type=int, default=600)
    args = parser.parse_args()
    args.boot = args.boot.resolve()
    records = []
    for index in range(1, args.boots + 1):
        record = boot_once(args, index)
        records.append(record)
        print(json.dumps(record), flush=True)
        if record["result"] != "pass":
            break
    passed = len(records) == args.boots and all(r["result"] == "pass" for r in records)
    print("G2 spike:", "PASS" if passed else "FAIL", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
