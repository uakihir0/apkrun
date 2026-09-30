"""Static validation for the Linux-only Cuttlefish reference capture scripts."""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

TOOLS_ROOT = Path(__file__).parents[1]
CAPTURE_SCRIPT = TOOLS_ROOT / "reference/capture.sh"
GUEST_COMMANDS = TOOLS_ROOT / "reference/guest-capture.txt"


def test_guest_capture_has_one_shell_command_for_each_required_output() -> None:
    rows: list[tuple[str, str]] = []
    for line_number, line in enumerate(GUEST_COMMANDS.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t", maxsplit=1)
        assert len(parts) == 2, f"line {line_number} must be filename<TAB>command"
        filename, command = parts
        assert filename and "/" not in filename and ".." not in filename
        assert command.strip()
        rows.append((filename, command))

    filenames = [filename for filename, _ in rows]
    assert len(filenames) == len(set(filenames))
    assert {
        "cmdline.txt",
        "bootconfig.txt",
        "properties.txt",
        "by-name-list.txt",
        "block-sysfs.txt",
        "block-sizes.txt",
        "mounts.txt",
        "fstab.txt",
        "dmesg.txt",
        "modules.txt",
        "first-stage-init.txt",
        "hvc-devices.txt",
        "hvc-users.txt",
        "logcat.txt.gz",
        "lshal.txt",
        "services.txt",
        "apex.txt",
        "features.txt",
        "ip-addr.txt",
        "ip-route.txt",
        "ip-link.txt",
        "connectivity.txt",
        "audio-cards.txt",
        "selinux-mode.txt",
        "avc-denials.txt",
        "boot-markers.txt",
    } <= set(filenames)

    for filename, command in rows:
        result = subprocess.run(
            ["/bin/sh", "-n", "-c", command],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, f"{filename}: {result.stderr}"


def test_capture_script_has_valid_posix_shell_syntax() -> None:
    result = subprocess.run(
        ["/bin/sh", "-n", str(CAPTURE_SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert os.access(CAPTURE_SCRIPT, os.X_OK)
    assert os.access(TOOLS_ROOT / "reference/compare_boot.py", os.X_OK)


def test_unknown_profile_fails_before_touching_capture_paths(tmp_path: Path) -> None:
    result = subprocess.run(
        ["sh", str(CAPTURE_SCRIPT), "not-a-profile"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert "usage:" in result.stderr
    assert list(tmp_path.iterdir()) == []


@pytest.mark.skipif(sys.platform != "darwin", reason="platform guard is exercised on macOS")
def test_capture_script_refuses_to_run_on_macos() -> None:
    result = subprocess.run(
        [str(CAPTURE_SCRIPT), "default"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert "requires a Linux" in result.stderr


def test_compare_boot_can_be_invoked_directly_with_the_project_python() -> None:
    environment = os.environ.copy()
    environment["PATH"] = f"{TOOLS_ROOT / '.venv' / 'bin'}:{environment['PATH']}"
    result = subprocess.run(
        [str(TOOLS_ROOT / "reference/compare_boot.py"), "--help"],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert "Normalize a Cuttlefish capture" in result.stdout


@pytest.mark.parametrize(
    (
        "gpu_mode",
        "build_id",
        "launch_succeeds",
        "normalization_succeeds",
        "should_capture",
        "copy_fails",
        "requested_instance",
        "abort_command",
        "raw_cleanup_fails",
        "stop_timeout",
        "capture_lock_held",
        "lock_signal_during_acquire",
    ),
    (
        ("drm_virgl", "16373615", True, True, True, False, 3, None, False, False, False, False),
        (
            "guest_swiftshader",
            "16373615",
            True,
            True,
            True,
            False,
            3,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "wrong-build",
            True,
            True,
            False,
            False,
            3,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            False,
            True,
            False,
            False,
            3,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            True,
            False,
            False,
            False,
            3,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            True,
            True,
            False,
            True,
            3,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            True,
            True,
            True,
            False,
            None,
            None,
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            True,
            True,
            False,
            False,
            3,
            "cat /proc/cmdline",
            False,
            False,
            False,
            False,
        ),
        (
            "drm_virgl",
            "16373615",
            True,
            True,
            False,
            False,
            3,
            "logcat -d -b all",
            False,
            False,
            False,
            False,
        ),
        ("drm_virgl", "16373615", True, True, False, False, 3, None, True, False, False, False),
        (
            "drm_virgl",
            "16373615",
            True,
            True,
            False,
            False,
            3,
            "logcat -d -b all",
            "stage-fails",
            False,
            False,
            False,
        ),
        ("drm_virgl", "16373615", True, True, False, False, 3, None, False, True, False, False),
        ("drm_virgl", "16373615", True, True, False, False, 3, None, False, False, True, False),
        ("drm_virgl", "16373615", True, True, False, False, 3, None, False, False, False, True),
        pytest.param(
            "drm_virgl",
            "16373615",
            True,
            True,
            False,
            False,
            3,
            None,
            False,
            "real",
            False,
            False,
            marks=pytest.mark.skipif(
                sys.platform != "linux" or not Path("/usr/bin/timeout").is_file(),
                reason="requires GNU timeout on Linux",
            ),
            id="real-timeout-kills-stuck-stop",
        ),
    ),
)
def test_capture_script_collects_a_synthetic_linux_capture(
    tmp_path: Path,
    gpu_mode: str,
    build_id: str,
    launch_succeeds: bool,
    normalization_succeeds: bool,
    should_capture: bool,
    copy_fails: bool,
    requested_instance: int | None,
    abort_command: str | None,
    raw_cleanup_fails: bool | str,
    stop_timeout: bool | str,
    capture_lock_held: bool,
    lock_signal_during_acquire: bool,
) -> None:
    repo = tmp_path / "repo"
    reference_tools = repo / "Images/tools/reference"
    reference_tools.mkdir(parents=True)
    for name in ("capture.sh", "compare_boot.py", "normalize.yaml", "guest-capture.txt"):
        shutil.copy2(TOOLS_ROOT / "reference" / name, reference_tools / name)
    host_lock_root = tmp_path / "host-locks"
    host_lock_root.mkdir()
    capture_script = reference_tools / "capture.sh"
    capture_text = capture_script.read_text(encoding="utf-8")
    capture_text = capture_text.replace(
        "capture_lock_root=/tmp",
        f"capture_lock_root={shlex.quote(str(host_lock_root))}",
    )
    capture_script.write_text(capture_text, encoding="utf-8")
    if not normalization_succeeds:
        (reference_tools / "normalize.yaml").write_text("{invalid json\n", encoding="utf-8")

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            case "${1:-}" in
              -s) echo Linux ;;
              -m) echo aarch64 ;;
              -srmo) echo "Linux synthetic 6.0 aarch64 GNU/Linux" ;;
              *) echo aarch64 ;;
            esac
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "launch_cvd").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            runtime="$HOME/cuttlefish_runtime"
            printf '%s\\n' "$HOME" > "$CVD_HOME_LOG"
            printf '%s\\n' "$*" > "$LAUNCH_LOG"
            instance_num=1
            for argument in "$@"; do
              case "$argument" in
                --base_instance_num=*) instance_num=${argument#*=} ;;
              esac
            done
            instance="$runtime/instances/cvd-$instance_num"
            mkdir -p "$instance/internal"
            printf '%s\\n' "$*" > "$runtime/launch-args.txt"
            printf '%s\\n' "$instance_num" > "$runtime/instance-num.txt"
            python3 - "$instance/internal/bootconfig" <<'PY'
            import struct
            import sys
            from pathlib import Path
            body = b"androidboot.synthetic=1\\n"
            footer = struct.pack(">4sIIQQQ", b"AVBf", 1, 0, len(body), len(body), 0)
            Path(sys.argv[1]).write_bytes(body + footer + bytes(64 - len(footer)))
            PY
            cat > "$instance/cuttlefish_config.json" <<'JSON'
            {"disks":{"os_composite":{"partitions":["boot_a","system_a"]}}}
            JSON
            printf 'VIRTUAL_DEVICE_BOOT_COMPLETED\\n' > "$instance/kernel.log"
            printf 'launcher synthetic log\\n' > "$instance/launcher.log"
            if [ "${FAKE_LAUNCH_FAIL:-0}" = 1 ]; then
              exit 1
            fi
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "adb").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\\t%s\\n' "$HOME" "$*" >> "$ADB_COMMAND_LOG"
            if [ "$1" = devices ]; then
              echo "List of devices attached"
              instance_file="$HOME/cuttlefish_runtime/instance-num.txt"
              if [ -f "$instance_file" ]; then
                instance_num=$(cat "$instance_file")
                adb_port=$((6520 + instance_num - 1))
                echo "127.0.0.1:$adb_port device"
                echo "10.0.0.5:$adb_port device"
              fi
              exit 0
            fi
            if [ "$1" = -s ]; then
              shift 2
            fi
            if [ "$1" = shell ] && [ "$2" = getprop ]; then
              echo 1
              exit 0
            fi
            if [ "$1" = wait-for-device ]; then
              exit 0
            fi
            if [ "$1" = exec-out ]; then
              if [ "${FAKE_ABORT_CAPTURE:-0}" = 1 ] \
                && [ "$4" = "${FAKE_ABORT_CAPTURE_COMMAND:-}" ]; then
                printf 'token=raw-capture-secret\\n'
                kill -TERM "$APKRUN_CAPTURE_PID"
                exit 0
              fi
              printf 'synthetic output for %s\\n' "$4"
              exit 0
            fi
            exit 1
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "stop_cvd").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\\n' "$*" >> "$STOP_LOG"
            printf '%s\\n' "$HOME" > "$STOP_HOME_LOG"
            if [ "${FAKE_STOP_HANG:-0}" = 1 ]; then
              trap '' TERM
              while :; do sleep 1; done
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "timeout").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\\t%s\\n' "$HOME" "$*" >> "$TIMEOUT_LOG"
            if [ "${FAKE_USE_REAL_TIMEOUT:-0}" = 1 ]; then
              exec /usr/bin/timeout "$@"
            fi
            if [ "$1" = --kill-after=10s ]; then
              shift
            fi
            shift
            if [ "${FAKE_STOP_TIMEOUT:-0}" = 1 ]; then
              exit 124
            fi
            exec "$@"
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "mkdir").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            if [ "${FAKE_SIGNAL_DURING_LOCK:-0}" = 1 ] \
              && [ "${1:-}" = "${FAKE_CAPTURE_LOCK_PATH:-}" ]; then
              /bin/mkdir "$1" || exit
              kill -TERM "$APKRUN_CAPTURE_SCRIPT_PID"
              exit 0
            fi
            exec /bin/mkdir "$@"
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "rm").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            if [ "${FAKE_RM_FAIL_STAGE:-0}" = 1 ] && [ "$1" = -rf ]; then
              for argument in "$@"; do
                case "$argument" in
                  */.target.capture.*) exit 1 ;;
                esac
              done
            fi
            for argument in "$@"; do
              case "$argument" in
                */.logcat.raw)
                  if [ "${FAKE_RM_FAIL_LOGCAT_RAW:-0}" = 1 ]; then
                    exit 1
                  fi
                  ;;
              esac
            done
            exec /bin/rm "$@"
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "cp").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            case "${FAKE_CP_FAIL_NAME:-}" in
              '')
                ;;
              *)
                case "$2" in
                  */"$FAKE_CP_FAIL_NAME") exit 1 ;;
                esac
                ;;
            esac
            exec /bin/cp "$@"
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "ps").write_text(
        "#!/bin/sh\n"
        'cvd_home=$(cat "$CVD_HOME_LOG" 2>/dev/null || true)\n'
        'if [ -n "$cvd_home" ] && [ -f "$cvd_home/cuttlefish_runtime/launch-args.txt" ]; then\n'
        '  instance_num=$(cat "$cvd_home/cuttlefish_runtime/instance-num.txt")\n'
        "  other_instance=$((instance_num + 4))\n"
        "  printf 'PID COMMAND\\n'\n"
        '  printf "100 crosvm run --instance_num=%s --serial=OTHER\\n" "$other_instance"\n'
        '  printf "101 crosvm run --socket=%s/cuttlefish_runtime/instances/cvd-%s0/vsock.sock\\n" '
        '"$cvd_home" "$instance_num"\n'
        '  printf "123 crosvm run --instance_num=%s --serial=EXTERNAL-SAME-NUMBER\\n" '
        '"$instance_num"\n'
        '  printf "124 crosvm run --instance_num=%s --socket=%s/cuttlefish_runtime/'
        'instances/cvd-%s/vsock.sock\\n" '
        '"$instance_num" "$cvd_home" "$instance_num"\n'
        "fi\n",
        encoding="utf-8",
    )
    (fake_bin / "mv").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            [ "$1" = -T ] && shift
            [ ! -e "$2" ] || exit 1
            exec /bin/mv "$1" "$2"
            """
        ),
        encoding="utf-8",
    )
    for executable in fake_bin.iterdir():
        executable.chmod(0o755)

    product_out = tmp_path / "product-out"
    product_out.mkdir()
    boot_image = b"pinned synthetic boot image\n"
    (product_out / "boot.img").write_bytes(boot_image)
    manifest_dir = repo / "Images/manifests/16373615"
    manifest_dir.mkdir(parents=True)
    manifest = {
        "architecture": "arm64",
        "artifacts": [
            {
                "file": "boot.img",
                "sha256": hashlib.sha256(boot_image).hexdigest(),
                "size": len(boot_image),
            }
        ],
        "source": {
            "buildId": build_id,
            "target": "aosp_cf_arm64_only_phone-userdebug",
        },
    }
    (manifest_dir / "android-image.json").write_text(json.dumps(manifest), encoding="utf-8")
    home = tmp_path / "home"
    home.mkdir()
    adb_log = tmp_path / "adb-commands.txt"
    stop_log = tmp_path / "stop-command.txt"
    timeout_log = tmp_path / "timeout-command.txt"
    cvd_home_log = tmp_path / "cvd-home.txt"
    launch_log = tmp_path / "launch-command.txt"
    stop_home_log = tmp_path / "stop-home.txt"
    expected_instance = requested_instance or 1
    props_file = tmp_path / "drm-virgl-props.txt"
    props_file.write_text("androidboot.hardware.gralloc=gbm\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.update(
        {
            "ANDROID_PRODUCT_OUT": str(product_out),
            "APKRUN_CVD_PACKAGE_VERSION": "synthetic-cvd",
            "APKRUN_TARGET_GPU_MODE": gpu_mode,
            "FAKE_LAUNCH_FAIL": "0" if launch_succeeds else "1",
            "FAKE_CP_FAIL_NAME": "cuttlefish_config.json" if copy_fails else "",
            "FAKE_ABORT_CAPTURE": "1" if abort_command else "0",
            "FAKE_ABORT_CAPTURE_COMMAND": abort_command or "",
            "FAKE_RM_FAIL_LOGCAT_RAW": "1" if raw_cleanup_fails else "0",
            "FAKE_RM_FAIL_STAGE": "1" if raw_cleanup_fails == "stage-fails" else "0",
            "FAKE_STOP_TIMEOUT": "1" if stop_timeout is True else "0",
            "FAKE_STOP_HANG": "1" if stop_timeout == "real" else "0",
            "FAKE_USE_REAL_TIMEOUT": "1" if stop_timeout == "real" else "0",
            "FAKE_SIGNAL_DURING_LOCK": "1" if lock_signal_during_acquire else "0",
            "FAKE_CAPTURE_LOCK_PATH": str(host_lock_root / "apkrun-cvd-capture.lock"),
            "ADB_COMMAND_LOG": str(adb_log),
            "STOP_LOG": str(stop_log),
            "TIMEOUT_LOG": str(timeout_log),
            "STOP_HOME_LOG": str(stop_home_log),
            "CVD_HOME_LOG": str(cvd_home_log),
            "LAUNCH_LOG": str(launch_log),
            "HOME": str(home),
            "PATH": (f"{fake_bin}:{TOOLS_ROOT / '.venv' / 'bin'}:{os.environ['PATH']}"),
            "TMPDIR": "/tmp",
        }
    )
    if stop_timeout == "real":
        environment["APKRUN_CVD_STOP_TIMEOUT_SECONDS"] = "1"
    environment.pop("APKRUN_CVD_INSTANCE_NUM", None)
    if requested_instance is not None:
        environment["APKRUN_CVD_INSTANCE_NUM"] = str(requested_instance)
    if capture_lock_held:
        (host_lock_root / "apkrun-cvd-capture.lock").mkdir()
    if gpu_mode == "guest_swiftshader":
        environment["APKRUN_DRM_VIRGL_PROPS_FILE"] = str(props_file)
        environment["APKRUN_DRM_VIRGL_SOURCE_REVISION"] = "a" * 40

    result = subprocess.run(
        ["sh", str(reference_tools / "capture.sh"), "target"],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    if not should_capture:
        expected_status = (
            2
            if build_id != "16373615" or capture_lock_held
            else 143
            if abort_command or lock_signal_during_acquire
            else 1
        )
        assert result.returncode == expected_status
        assert not (repo / "Images/reference/16373615/target").exists()
        if build_id != "16373615":
            assert "pinned build 16373615" in result.stderr
            assert not launch_log.exists()
        elif lock_signal_during_acquire:
            assert not launch_log.exists()
            assert not (host_lock_root / "apkrun-cvd-capture.lock").exists()
            assert not (repo / "Images/reference/16373615/incomplete").exists()
        elif capture_lock_held:
            assert "another reference capture is active" in result.stderr
            assert not launch_log.exists()
            assert (host_lock_root / "apkrun-cvd-capture.lock").is_dir()
        elif not normalization_succeeds:
            assert "raw capture data was discarded" in result.stderr
            assert not list((repo / "Images/reference/16373615").glob(".target.capture.*"))
            assert not (repo / "Images/reference/16373615/incomplete").exists()
        elif raw_cleanup_fails:
            assert not (repo / "Images/reference/16373615/incomplete").exists()
            staging = list((repo / "Images/reference/16373615").glob(".target.capture.*"))
            if raw_cleanup_fails == "stage-fails":
                assert "unpublished staging data may remain" in result.stderr
                assert len(staging) == 1
                raw_log = staging[0] / ".logcat.raw"
                assert raw_log.read_text(encoding="utf-8") == "token=raw-capture-secret\n"
            else:
                assert "entire capture stage was discarded" in result.stderr
                assert staging == []
                assert not list(repo.rglob(".logcat.raw"))
        elif stop_timeout:
            assert "Cuttlefish HOME retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert "stop_cvd reported a shutdown failure" in missing
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert cvd_home.is_dir()
            assert stop_log.exists() is (stop_timeout == "real")
            if stop_timeout == "real":
                assert stop_home_log.read_text(encoding="utf-8").strip() == str(cvd_home)
                expected_stop_timeout = "--kill-after=10s 1 stop_cvd"
            else:
                expected_stop_timeout = "--kill-after=10s 120 stop_cvd"
            assert timeout_log.read_text(encoding="utf-8").strip().endswith(expected_stop_timeout)
        elif copy_fails:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert "cuttlefish_config.json\tcould not copy" in missing
            assert cvd_home_log.read_text(encoding="utf-8").strip() not in missing
            assert stop_log.read_text(encoding="utf-8").strip() == ""
            assert stop_home_log.read_text(encoding="utf-8").strip() == (
                cvd_home_log.read_text(encoding="utf-8").strip()
            )
        elif abort_command:
            assert "normalized incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert "process exited before normal capture completion" in missing
            captured = b"".join(
                path.read_bytes() for path in partials[0].rglob("*") if path.is_file()
            )
            assert b"raw-capture-secret" not in captured
            if abort_command == "cat /proc/cmdline":
                assert b"<REDACTED>" in (partials[0] / "cmdline.txt").read_bytes()
            else:
                assert not (partials[0] / "logcat.txt.gz").exists()
                assert not list(partials[0].rglob(".logcat.raw"))
            assert stop_log.read_text(encoding="utf-8").strip() == ""
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        else:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            assert "launch_cvd failed" in (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert stop_log.read_text(encoding="utf-8").strip() == ""
            assert stop_home_log.read_text(encoding="utf-8").strip() == (
                cvd_home_log.read_text(encoding="utf-8").strip()
            )
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert str(cvd_home) not in missing
        if not capture_lock_held:
            assert not (host_lock_root / "apkrun-cvd-capture.lock").exists()
        return

    assert result.returncode == 0, result.stderr
    capture = repo / "Images/reference/16373615/target"
    cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
    metadata = json.loads((capture / "host.json").read_text(encoding="utf-8"))
    assert metadata["profile"] == "target"
    assert metadata["cvdPackageVersion"] == "synthetic-cvd"
    assert metadata["cpuCount"] >= 1
    assert metadata["cvdInstanceNumber"] == expected_instance
    assert metadata["targetGpuMode"] == gpu_mode
    assert (capture / "MISSING.txt").read_text(encoding="utf-8") == ""
    assert (capture / "internal-bootconfig.txt").read_bytes() == b"androidboot.synthetic=1\n"
    assert json.loads((capture / "composite-disk-specs.json").read_text(encoding="utf-8"))
    crosvm_command = (capture / "crosvm-command-line.txt").read_text(encoding="utf-8")
    assert f"--instance_num={expected_instance}" in crosvm_command
    assert f"--instance_num={expected_instance + 4}" not in crosvm_command
    assert "EXTERNAL-SAME-NUMBER" not in crosvm_command
    assert f"/instances/cvd-{expected_instance}0/" not in crosvm_command
    launch_arguments = launch_log.read_text(encoding="utf-8")
    assert f"--gpu_mode={gpu_mode}" in launch_arguments
    assert "--secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure" in launch_arguments
    assert f"--base_instance_num={expected_instance}" in launch_arguments
    assert "--num_instances=1" in launch_arguments
    assert stop_log.read_text(encoding="utf-8").strip() == ""
    assert stop_home_log.read_text(encoding="utf-8").strip() == str(cvd_home)
    assert not cvd_home.exists()
    assert not (host_lock_root / "apkrun-cvd-capture.lock").exists()
    adb_calls = [
        tuple(line.split("\t", maxsplit=1))
        for line in adb_log.read_text(encoding="utf-8").splitlines()
    ]
    adb_serial = f"127.0.0.1:{6520 + expected_instance - 1}"
    assert any(arguments.startswith(f"-s {adb_serial} exec-out") for _, arguments in adb_calls)
    assert all(
        arguments.startswith("devices") or arguments.startswith(f"-s {adb_serial}")
        for _, arguments in adb_calls
    )
    assert all(
        home_path == str(cvd_home)
        for home_path, arguments in adb_calls
        if arguments.startswith(f"-s {adb_serial}")
    )
    if gpu_mode == "guest_swiftshader":
        assert (capture / "graphics-props-from-source.txt").read_text(
            encoding="utf-8"
        ) == props_file.read_text(encoding="utf-8")
        assert metadata["drmVirglSourceRevision"] == "a" * 40
