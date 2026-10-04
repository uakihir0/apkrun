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
import time
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
        "profile",
        "expected_gpu_mode",
        "expected_secure_hals",
        "observer_enabled",
    ),
    (
        ("default", None, False, False),
        ("target", "drm_virgl", True, False),
        ("swiftshader", "guest_swiftshader", True, True),
    ),
)
def test_capture_script_uses_each_profile_launch_configuration(
    tmp_path: Path,
    profile: str,
    expected_gpu_mode: str | None,
    expected_secure_hals: bool,
    observer_enabled: bool,
) -> None:
    repo = tmp_path / "repo"
    reference_tools = repo / "Images/tools/reference"
    reference_tools.mkdir(parents=True)
    for name in (
        "capture.sh",
        "capture_cvd_start.py",
        "collect_composite_specs.py",
        "boot_observer.py",
        "compare_boot.py",
        "normalize.yaml",
        "guest-capture.txt",
    ):
        shutil.copy2(TOOLS_ROOT / "reference" / name, reference_tools / name)
    lock_root = tmp_path / "locks"
    lock_root.mkdir()
    capture_script = reference_tools / "capture.sh"
    capture_text = capture_script.read_text(encoding="utf-8")
    capture_text = capture_text.replace(
        "capture_lock_root=/tmp",
        f"capture_lock_root={shlex.quote(str(lock_root))}",
    )
    capture_script.write_text(capture_text, encoding="utf-8")

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        "#!/bin/sh\n"
        'case "${1:-}" in\n'
        "  -s) echo Linux ;;\n"
        "  -m) echo aarch64 ;;\n"
        '  -srmo) echo "Linux synthetic 6.0 aarch64 GNU/Linux" ;;\n'
        "  *) echo aarch64 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    (fake_bin / "cvd").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            if [ "${1:-}" = create ]; then
              shift
              base_directory="$HOME"
              instance_num=1
              for argument in "$@"; do
                case "$argument" in
                  --base_directory=*) base_directory=${argument#*=} ;;
                  --base_instance_num=*) instance_num=${argument#*=} ;;
                esac
              done
              printf '%s\\n' "$TMPDIR" > "$APKRUN_PROFILE_TMPDIR_LOG"
              printf '%s\\n' "$base_directory" > "$APKRUN_PROFILE_BASE_DIRECTORY_LOG"
              instance="$base_directory/501/123456789/home/cuttlefish/instances/cvd-$instance_num"
              mkdir -p "$instance/internal"
              ln -s "$instance" "$base_directory/cuttlefish_runtime"
              printf '%s\\n' "$*" > "$APKRUN_PROFILE_LAUNCH_LOG"
              printf '%s\\n' "$instance" > "$APKRUN_PROFILE_INSTANCE_FILE"
              python3 - "$instance/internal/bootconfig" <<'PY'
            import struct
            import sys
            from pathlib import Path
            body = b"androidboot.synthetic=1\\n"
            footer = struct.pack(">4sIIQQQ", b"AVBf", 1, 0, len(body), len(body), 0)
            Path(sys.argv[1]).write_bytes(body + footer + bytes(64 - len(footer)))
            PY
              printf '%s\\n' '{"instances":[]}' \\
                > "$instance/cuttlefish_config.json"
              printf '%s\\n' 'path=/var/tmp/cvd/host-501/os_composite.img' \\
                > "$instance/os_composite_disk_config.txt"
              printf '%s\\n' 'path=/var/tmp/cvd/host-501/persistent_composite.img' \\
                > "$instance/persistent_composite_disk_config.txt"
              printf '%s\\n' 'path=/var/tmp/cvd/host-501/ap_composite.img' \\
                > "$instance/ap_composite_disk_config.txt"
              printf 'synthetic kernel log\\n' > "$instance/kernel.log"
              printf 'synthetic launcher log\\n' > "$instance/launcher.log"
              printf 'synthetic assemble log\\n' > "$instance/assemble_cvd.log"
              exit 0
            fi
            for argument in "$@"; do
              if [ "$argument" = start ]; then
                printf '%s\\n' "$*" >> "$APKRUN_PROFILE_START_LOG"
                instance=$(cat "$APKRUN_PROFILE_INSTANCE_FILE")
                instance_num=${instance##*/cvd-}
                selected_gpu_mode=guest_swiftshader
                gpu_vhost_user_enabled=true
                for start_argument in "$@"; do
                  case "$start_argument" in
                    --gpu_mode=*) selected_gpu_mode=${start_argument#*=} ;;
                    --gpu_vhost_user_mode=off) gpu_vhost_user_enabled=false ;;
                  esac
                done
                printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"%s\",' \
                  "$instance_num" "$selected_gpu_mode" \
                  > "$instance/cuttlefish_config.json"
                printf '\"enable_gpu_vhost_user\":%s}}}\\n' \
                  "$gpu_vhost_user_enabled" >> "$instance/cuttlefish_config.json"
                exit 0
              fi
            done
            exit 0
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "adb").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            case "${1:-}" in
              connect|disconnect) exit 0 ;;
              devices)
                printf 'List of devices attached\\n'
                if [ "$HOME" != "$APKRUN_PROFILE_INITIAL_HOME" ]; then
                  printf '127.0.0.1:6520 device\\n'
                fi
                exit 0
                ;;
              -s) shift 2 ;;
            esac
            case "${1:-}" in
              shell)
                if [ "${2:-}" = getprop ]; then
                  echo 1
                fi
                exit 0
                ;;
              wait-for-device) exit 0 ;;
              exec-out) printf 'synthetic guest output\\n'; exit 0 ;;
              *) exit 1 ;;
            esac
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "ps").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            [ -f "$APKRUN_PROFILE_INSTANCE_FILE" ] || exit 0
            instance=$(cat "$APKRUN_PROFILE_INSTANCE_FILE")
            if [ "${2:-}" = -eo ] && [ "${3:-}" = pid= ]; then
              printf '      100\\n'
              exit 0
            fi
            if [ "${2:-}" = -p ] && [ "${3:-}" = 100 ]; then
              printf 'crosvm run --socket=%s/vsock.sock\\n' "$instance"
            fi
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "readlink").write_text(
        "#!/bin/sh\n"
        'if [ "$1" = -f ]; then\n'
        "  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \"$2\"\n"
        "  exit $?\n"
        "fi\n"
        '[ "$1" = /proc/100/exe ] || exit 1\n'
        "printf '/opt/crosvm\\n'\n",
        encoding="utf-8",
    )
    (fake_bin / "timeout").write_text(
        '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$TIMEOUT_LOG"\nshift 2\nexec "$@"\n',
        encoding="utf-8",
    )
    (fake_bin / "mv").write_text(
        '#!/bin/sh\n[ "$1" = -T ] && shift\n[ ! -e "$2" ] || exit 1\nexec /bin/mv "$1" "$2"\n',
        encoding="utf-8",
    )
    for executable in fake_bin.iterdir():
        executable.chmod(0o755)

    product_out = tmp_path / "product-out"
    product_out.mkdir()
    boot_image = b"synthetic boot image\n"
    (product_out / "boot.img").write_bytes(boot_image)
    manifest_dir = repo / "Images/manifests/16373615"
    manifest_dir.mkdir(parents=True)
    (manifest_dir / "android-image.json").write_text(
        json.dumps(
            {
                "architecture": "arm64",
                "artifacts": [
                    {
                        "file": "boot.img",
                        "sha256": hashlib.sha256(boot_image).hexdigest(),
                        "size": len(boot_image),
                    }
                ],
                "source": {
                    "buildId": "16373615",
                    "target": "aosp_cf_arm64_only_phone-userdebug",
                },
            }
        ),
        encoding="utf-8",
    )
    cvd_host = tmp_path / "cvd-host"
    host_bin = cvd_host / "bin"
    host_bin.mkdir(parents=True)
    (host_bin / "cvd").symlink_to(fake_bin / "cvd")
    (host_bin / "launch_cvd").symlink_to(fake_bin / "cvd")
    (host_bin / "adb").symlink_to(fake_bin / "adb")
    (host_bin / "crosvm").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (host_bin / "crosvm").chmod(0o755)
    launch_log = tmp_path / "launch-args.txt"
    start_log = tmp_path / "start-args.txt"
    tmpdir_log = tmp_path / "capture-tmpdir.txt"
    base_directory_log = tmp_path / "capture-base-directory.txt"
    timeout_log = tmp_path / "timeout-commands.txt"
    instance_file = tmp_path / "instance-path.txt"
    home = tmp_path / "home"
    home.mkdir()
    environment = os.environ.copy()
    environment.update(
        {
            "APKRUN_CVD_PACKAGE_VERSION": "synthetic-cvd",
            "APKRUN_CAPTURE_BOOT_OBSERVER": "1" if observer_enabled else "0",
            "APKRUN_BOOT_TIMEOUT_SECONDS": "321",
            "APKRUN_PROFILE_INSTANCE_FILE": str(instance_file),
            "APKRUN_PROFILE_INITIAL_HOME": str(home),
            "APKRUN_PROFILE_LAUNCH_LOG": str(launch_log),
            "APKRUN_PROFILE_START_LOG": str(start_log),
            "APKRUN_PROFILE_TMPDIR_LOG": str(tmpdir_log),
            "APKRUN_PROFILE_BASE_DIRECTORY_LOG": str(base_directory_log),
            "TIMEOUT_LOG": str(timeout_log),
            "CVD_HOST_DIR": str(cvd_host),
            "ANDROID_PRODUCT_OUT": str(product_out),
            "HOME": str(home),
            "PATH": f"{fake_bin}:{TOOLS_ROOT / '.venv' / 'bin'}:{os.environ['PATH']}",
            "TMPDIR": str(tmp_path),
        }
    )

    result = subprocess.run(
        ["sh", str(capture_script), profile],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    launch_arguments = launch_log.read_text(encoding="utf-8").split()
    group_argument = next(
        argument for argument in launch_arguments if argument.startswith("--group_name=")
    )
    expected_start_arguments = [
        group_argument,
        "start",
        "--boot_timeout_secs=321",
    ]
    if expected_gpu_mode is not None:
        expected_start_arguments.append(f"--gpu_mode={expected_gpu_mode}")
    expected_start_arguments.append("--gpu_vhost_user_mode=off")
    assert start_log.read_text(encoding="utf-8").split() == expected_start_arguments
    expected_tmp_root = Path("/tmp").resolve()
    assert tmpdir_log.read_text(encoding="utf-8") == f"{expected_tmp_root}\n"
    base_directory = Path(base_directory_log.read_text(encoding="utf-8").strip())
    assert base_directory.parent == expected_tmp_root
    assert str(tmp_path) not in str(base_directory)
    if expected_gpu_mode is None:
        assert not any(argument.startswith("--gpu_mode=") for argument in launch_arguments)
    else:
        assert f"--gpu_mode={expected_gpu_mode}" in launch_arguments
    assert "--gpu_vhost_user_mode=off" in launch_arguments
    assert "--gpu_vhost_user_mode=off" in expected_start_arguments
    secure_hals = "--secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure"
    assert (secure_hals in launch_arguments) is expected_secure_hals

    if observer_enabled:
        runner_calls = [
            shlex.split(line)
            for line in timeout_log.read_text(encoding="utf-8").splitlines()
            if "capture_cvd_start.py" in line
        ]
        observer_calls = [call for call in runner_calls if "--boot-observer-instance-path" in call]
        assert len(observer_calls) == 1
        observer_path_index = observer_calls[0].index("--boot-observer-instance-path")
        observer_path = Path(observer_calls[0][observer_path_index + 1])
        assert observer_path.name == "cuttlefish_runtime"
        assert ".unresolved-cvd-instance-" not in str(observer_path)

    capture = repo / f"Images/reference/16373615/{profile}"
    metadata = json.loads((capture / "host.json").read_text(encoding="utf-8"))
    assert metadata["profile"] == profile
    assert metadata["selectedGpuMode"] == (expected_gpu_mode or "guest_swiftshader")
    assert metadata["gpuVhostUserEnabled"] is False
    assert (capture / "MISSING.txt").read_text(encoding="utf-8") == ""
    if observer_enabled:
        observer_records = [
            json.loads(line)
            for line in (capture / "boot-observer.jsonl").read_text(encoding="ascii").splitlines()
        ]
        assert observer_records[0]["event"] == "observer_started"
        assert observer_records[-1]["event"] == "observer_stopped"
    else:
        assert not (capture / "boot-observer.jsonl").exists()
    assert "androidboot.synthetic=1\n" == (capture / "internal-bootconfig.txt").read_text(
        encoding="utf-8"
    )
    assert not Path(instance_file.read_text(encoding="utf-8").strip()).exists()


@pytest.mark.parametrize(
    ("product_symlink", "mutate_private_copy", "expected_status", "expected_error"),
    (
        (True, False, 2, "ANDROID_PRODUCT_OUT contains symbolic links"),
        (False, True, 1, "product output does not match pinned artifact boot.img"),
    ),
)
def test_capture_rejects_untrusted_product_images_before_starting_cuttlefish(
    tmp_path: Path,
    product_symlink: bool,
    mutate_private_copy: bool,
    expected_status: int,
    expected_error: str,
) -> None:
    repo = tmp_path / "repo"
    reference_tools = repo / "Images/tools/reference"
    reference_tools.mkdir(parents=True)
    for name in (
        "capture.sh",
        "capture_cvd_start.py",
        "collect_composite_specs.py",
        "boot_observer.py",
        "compare_boot.py",
        "normalize.yaml",
        "guest-capture.txt",
    ):
        shutil.copy2(TOOLS_ROOT / "reference" / name, reference_tools / name)

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        "#!/bin/sh\n"
        'case "${1:-}" in\n'
        "  -s) echo Linux ;;\n"
        "  -m) echo aarch64 ;;\n"
        '  -srmo) echo "Linux synthetic 6.0 aarch64 GNU/Linux" ;;\n'
        "  *) echo aarch64 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    (fake_bin / "uname").chmod(0o755)
    cvd_invocation_log = tmp_path / "cvd-invocations.txt"
    fake_cvd = fake_bin / "cvd"
    fake_cvd.write_text(
        '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$CVD_INVOCATION_LOG"\n',
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)
    fake_timeout = fake_bin / "timeout"
    fake_timeout.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_timeout.chmod(0o755)
    fake_cp = fake_bin / "cp"
    fake_cp.write_text(
        "#!/bin/sh\n"
        '/bin/cp "$@" || exit\n'
        'if [ "${FAKE_MUTATE_PRIVATE_COPY:-0}" = 1 ] && [ "${1:-}" = -a ]; then\n'
        '  printf "modified after copy\\n" >> "$3/boot.img"\n'
        "fi\n",
        encoding="utf-8",
    )
    fake_cp.chmod(0o755)
    fake_mv = fake_bin / "mv"
    fake_mv.write_text(
        '#!/bin/sh\n[ "$1" = -T ] && shift\n[ ! -e "$2" ] || exit 1\nexec /bin/mv "$1" "$2"\n',
        encoding="utf-8",
    )
    fake_mv.chmod(0o755)

    product_out = tmp_path / "product-out"
    product_out.mkdir()
    image_contents = b"verified image target\n"
    target_image = product_out / "boot-image-source.img"
    target_image.write_bytes(image_contents)
    if product_symlink:
        (product_out / "boot.img").symlink_to(target_image)
    else:
        (product_out / "boot.img").write_bytes(image_contents)

    manifest_dir = repo / "Images/manifests/16373615"
    manifest_dir.mkdir(parents=True)
    manifest = {
        "architecture": "arm64",
        "artifacts": [
            {
                "file": "boot.img",
                "sha256": hashlib.sha256(image_contents).hexdigest(),
                "size": len(image_contents),
            }
        ],
        "source": {
            "buildId": "16373615",
            "target": "aosp_cf_arm64_only_phone-userdebug",
        },
    }
    (manifest_dir / "android-image.json").write_text(json.dumps(manifest), encoding="utf-8")

    cvd_host = tmp_path / "cvd-host"
    host_bin = cvd_host / "bin"
    host_bin.mkdir(parents=True)
    for executable in ("cvd", "launch_cvd", "adb"):
        (host_bin / executable).symlink_to(fake_cvd)
    home = tmp_path / "home"
    home.mkdir()
    environment = os.environ.copy()
    environment.update(
        {
            "APKRUN_CVD_PACKAGE_VERSION": "synthetic-cvd",
            "CVD_HOST_DIR": str(cvd_host),
            "CVD_INVOCATION_LOG": str(cvd_invocation_log),
            "ANDROID_PRODUCT_OUT": str(product_out),
            "FAKE_MUTATE_PRIVATE_COPY": "1" if mutate_private_copy else "0",
            "HOME": str(home),
            "PATH": f"{fake_bin}:{TOOLS_ROOT / '.venv' / 'bin'}:{os.environ['PATH']}",
            "TMPDIR": str(tmp_path),
        }
    )

    result = subprocess.run(
        ["sh", str(reference_tools / "capture.sh"), "default"],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == expected_status
    assert expected_error in result.stderr
    cvd_calls = (
        cvd_invocation_log.read_text(encoding="utf-8").splitlines()
        if cvd_invocation_log.exists()
        else []
    )
    assert all(not {"create", "start"}.intersection(call.split()) for call in cvd_calls)
    assert target_image.read_bytes() == image_contents
    if not product_symlink:
        assert (product_out / "boot.img").read_bytes() == image_contents
    capture_root = repo / "Images/reference/16373615"
    assert not (capture_root / "default").exists()
    if mutate_private_copy:
        partials = list((capture_root / "incomplete").glob("default-*"))
        assert len(partials) == 1
        missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
        assert "private product copy does not match pinned build 16373615" in missing
    else:
        assert not capture_root.exists()


@pytest.mark.parametrize(
    (
        "gpu_mode",
        "build_id",
        "launch_succeeds",
        "normalization_succeeds",
        "should_capture",
        "config_oversized",
        "requested_instance",
        "abort_command",
        "raw_cleanup_fails",
        "stop_timeout",
        "capture_lock_held",
        "lock_signal_during_acquire",
        "boot_timeout_case",
    ),
    (
        (
            "drm_virgl",
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
            False,
        ),
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
            False,
        ),
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
            False,
            False,
            False,
            "gpu-mode-mismatch",
            id="selected-gpu-mode-mismatch-is-incomplete",
        ),
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
            False,
            False,
            False,
            "gpu-mode-mismatch-observed",
            id="observer-data-does-not-make-a-mode-mismatch-comparable",
        ),
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
            False,
            False,
            False,
            "gpu-vhost-user-enabled",
            id="selected-vhost-user-gpu-is-rejected",
        ),
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
            False,
            False,
            False,
            "gpu-vhost-user-invalid-type",
            id="selected-vhost-user-setting-must-be-a-json-boolean",
        ),
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
            False,
            False,
            False,
            "gpu-mode-missing",
            id="missing-selected-mode-skips-adb-capture",
        ),
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
            False,
            False,
            False,
            "gpu-mode-invalid",
            id="invalid-selected-mode-skips-adb-capture",
        ),
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
            False,
            False,
            False,
            "gpu-mode-oversized",
            id="oversized-selected-mode-skips-adb-capture",
        ),
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
            False,
            False,
            False,
            "gpu-mode-nonstandard-json",
            id="nonstandard-json-constant-does-not-validate-mode",
        ),
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
            False,
            False,
            False,
            "gpu-mode-duplicate-key",
            id="duplicate-gpu-mode-key-is-rejected-even-when-last-matches",
        ),
        pytest.param(
            "drm_virgl",
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
            "gpu-mode-staged-mismatch",
            id="staged-config-is-revalidated-before-publish",
        ),
        pytest.param(
            "drm_virgl",
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
            "gpu-vhost-user-staged-enabled",
            id="staged-vhost-user-gpu-change-invalidates-capture",
        ),
        pytest.param(
            "drm_virgl",
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
            "gpu-vhost-user-staged-invalid-type",
            id="staged-vhost-user-setting-must-be-a-json-boolean",
        ),
        pytest.param(
            "drm_virgl",
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
            "gpu-mode-staged-invalid",
            id="staged-invalid-config-invalidates-capture",
        ),
        pytest.param(
            "drm_virgl",
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
            "gpu-mode-staged-missing",
            id="staged-missing-config-invalidates-capture",
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
            None,
            True,
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
            "stage-fails",
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
            None,
            False,
            True,
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
            None,
            False,
            False,
            True,
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
            None,
            False,
            False,
            False,
            True,
            False,
        ),
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
            False,
            marks=pytest.mark.skipif(
                sys.platform != "linux" or not Path("/usr/bin/timeout").is_file(),
                reason="requires GNU timeout on Linux",
            ),
            id="real-timeout-kills-stuck-stop",
        ),
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
            False,
            False,
            False,
            "cvd-start",
            id="cvd-start-times-out",
        ),
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
            False,
            False,
            False,
            "cvd-start-no-crosvm",
            id="process-snapshot-does-not-claim-crosvm-never-ran",
        ),
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
            False,
            False,
            False,
            "adb-getprop",
            id="adb-getprop-times-out",
        ),
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
            False,
            False,
            False,
            "adb-preflight",
            id="adb-preflight-times-out",
        ),
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
            False,
            False,
            False,
            "adb-wait-for-device",
            id="adb-wait-for-device-failure-skips-guest-capture",
        ),
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
            False,
            False,
            False,
            "adb-no-device",
            id="adb-poll-sleep-stays-within-deadline",
        ),
        pytest.param(
            "drm_virgl",
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
            "shared-deadline",
            id="default-600-second-deadline-is-shared",
        ),
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
            False,
            False,
            False,
            "real-cvd-start",
            marks=pytest.mark.skipif(
                sys.platform != "linux" or not Path("/usr/bin/timeout").is_file(),
                reason="requires GNU timeout on Linux",
            ),
            id="real-timeout-kills-stuck-start",
        ),
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
            False,
            False,
            False,
            "real-adb-getprop",
            marks=pytest.mark.skipif(
                sys.platform != "linux" or not Path("/usr/bin/timeout").is_file(),
                reason="requires GNU timeout on Linux",
            ),
            id="real-timeout-kills-stuck-adb-getprop",
        ),
        pytest.param(
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
            "cvd-create-delayed-logs",
            id="create-failure-snapshots-logs-after-a-slow-listing",
        ),
        pytest.param(
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
            "cvd-create-124",
            id="cvd-create-exit-124-is-not-a-deadline",
        ),
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
            False,
            False,
            False,
            "composite-specs-interrupted",
            id="interrupted-composite-spec-collection-cleans-raw-temp",
        ),
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
            False,
            False,
            False,
            "crosvm-binary-override",
            id="diagnostic-crosvm-binary-override-is-passed-to-create",
        ),
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
            False,
            False,
            False,
            "crosvm-binary-override-relative",
            id="crosvm-binary-override-must-be-absolute",
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
    config_oversized: bool,
    requested_instance: int | None,
    abort_command: str | None,
    raw_cleanup_fails: bool | str,
    stop_timeout: bool | str,
    capture_lock_held: bool,
    lock_signal_during_acquire: bool,
    boot_timeout_case: bool | str,
) -> None:
    repo = tmp_path / "repo"
    reference_tools = repo / "Images/tools/reference"
    reference_tools.mkdir(parents=True)
    for name in (
        "capture.sh",
        "capture_cvd_start.py",
        "collect_composite_specs.py",
        "boot_observer.py",
        "compare_boot.py",
        "normalize.yaml",
        "guest-capture.txt",
    ):
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
    fake_python = fake_bin / "python3"
    fake_python.write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            if [ "${FAKE_INTERRUPT_COMPOSITE_COLLECTOR:-0}" = 1 ] \
              && [ "${1##*/}" = collect_composite_specs.py ]; then
              destination="$4"
              stage="${destination%/*}"
              printf 'private=/var/tmp/cvd/interrupted-raw-config\\n' \
                > "$stage/.composite-disk-specs.json.interrupted"
              kill -TERM "$PPID"
              exit 0
            fi
            exec "$APKRUN_REAL_PYTHON" "$@"
            """
        ),
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
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
    (fake_bin / "cvd").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            runtime="$HOME"
            base_directory="$runtime"
            if [ "${1:-}" = logs ]; then
              if [ "${FAKE_CVD_LOGS_EMPTY_FIRST:-0}" = 1 ] \
                && [ ! -f "$HOME/cvd-logs-empty-first.txt" ]; then
                : > "$HOME/cvd-logs-empty-first.txt"
                if [ "${FAKE_CVD_FIRST_LOGS_DELAY_SECONDS:-0}" != 0 ]; then
                  sleep "$FAKE_CVD_FIRST_LOGS_DELAY_SECONDS"
                fi
                exit 0
              fi
              instance_file="$HOME/instance-runtime.txt"
              [ -f "$instance_file" ] || exit 0
              instance=$(cat "$instance_file")
              listing="$HOME/cvd-logs-list-$$.txt"
              : > "$listing"
              for name in assemble_cvd.log kernel.log launcher.log; do
                if [ -f "$instance/$name" ]; then
                  printf '%s %s/%s\\n' "$name" "$instance" "$name" >> "$listing"
                fi
              done
              cat "$listing"
              if [ "${FAKE_CVD_LOGS_DELAY_SECONDS:-0}" != 0 ]; then
                sleep "$FAKE_CVD_LOGS_DELAY_SECONDS"
              fi
              rm -f "$listing"
              exit 0
            fi
            if [ "${1:-}" != create ]; then
              case "${1:-}" in
                --base_directory=*)
                  base_directory=${1#*=}
                  shift
                  ;;
              esac
            fi
            if [ "${1:-}" = create ]; then
              shift
              if [ "${FAKE_CVD_CREATE_DELAY_SECONDS:-0}" != 0 ]; then
                sleep "$FAKE_CVD_CREATE_DELAY_SECONDS"
              fi
              printf '%s\\n' "$HOME" > "$CVD_HOME_LOG"
              printf '%s\\n' "--base_directory=$base_directory $*" > "$LAUNCH_LOG"
              product_directory=
              instance_num=1
              for argument in "$@"; do
                case "$argument" in
                  --base_instance_num=*) instance_num=${argument#*=} ;;
                  --base_directory=*) base_directory=${argument#*=} ;;
                  --product_path=*) product_directory=${argument#*=} ;;
                esac
              done
              printf 'modified by synthetic Cuttlefish\\n' >> "$product_directory/boot.img"
              runtime="$base_directory"
              instance="$runtime/501/123456789/home/cuttlefish/instances/cvd-$instance_num"
              mkdir -p "$instance/internal"
              printf '%s\\n' "$*" > "$runtime/launch-args.txt"
              printf '%s\\n' "$instance_num" > "$runtime/instance-num.txt"
              printf '%s\\n' "$instance" > "$runtime/instance-runtime.txt"
              python3 - "$instance/internal/bootconfig" <<'PY'
            import struct
            import sys
            from pathlib import Path
            body = b"androidboot.synthetic=1\\n"
            footer = struct.pack(">4sIIQQQ", b"AVBf", 1, 0, len(body), len(body), 0)
            Path(sys.argv[1]).write_bytes(body + footer + bytes(64 - len(footer)))
            PY
              printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"guest_swiftshader\"}}}\\n' \
                "$instance_num" > "$instance/cuttlefish_config.json"
              printf 'image=/var/tmp/cvd/host-501/os_composite.img\\n' \\
                > "$instance/os_composite_disk_config.txt"
              printf 'image=/var/tmp/cvd/host-501/persistent_composite.img\\n' \\
                > "$instance/persistent_composite_disk_config.txt"
              printf 'image=/var/tmp/cvd/host-501/ap_composite.img\\n' \\
                > "$instance/ap_composite_disk_config.txt"
              printf 'VIRTUAL_DEVICE_BOOT_COMPLETED\\n' > "$instance/kernel.log"
              printf 'launcher synthetic log\\n' > "$instance/launcher.log"
              printf 'assemble synthetic log\\n' > "$instance/assemble_cvd.log"
              if [ "${FAKE_CVD_CREATE_FAIL_AFTER_LOGS:-0}" = 1 ]; then
                sleep "${FAKE_CVD_CREATE_FAILURE_DELAY_SECONDS:-0.75}"
                rm -f "$instance/assemble_cvd.log" \
                  "$instance/kernel.log" "$instance/launcher.log"
                exit "${FAKE_CVD_CREATE_EXIT_STATUS:-1}"
              fi
              if [ "${FAKE_LAUNCH_FAIL:-0}" = 1 ]; then
                exit 1
              fi
              exit 0
            fi
            for argument in "$@"; do
              if [ "$argument" = start ]; then
                printf '%s\\n' "$*" >> "$APKRUN_PROFILE_START_LOG"
                instance=$(cat "$HOME/instance-runtime.txt")
                instance_num=$(cat "$HOME/instance-num.txt")
                selected_gpu_mode=guest_swiftshader
                selected_gpu_vhost_user_enabled=true
                for start_argument in "$@"; do
                  case "$start_argument" in
                    --gpu_mode=*) selected_gpu_mode=${start_argument#*=} ;;
                    --gpu_vhost_user_mode=off) selected_gpu_vhost_user_enabled=false ;;
                  esac
                done
                if [ "${FAKE_CVD_CONFIG_GPU_MODE_MISMATCH:-0}" = 1 ]; then
                  selected_gpu_mode=guest_swiftshader
                fi
                if [ "${FAKE_CVD_CONFIG_GPU_VHOST_USER_ENABLED:-0}" = 1 ]; then
                  selected_gpu_vhost_user_enabled=true
                fi
                if [ "${FAKE_CVD_CONFIG_DUPLICATE_KEY:-0}" = 1 ]; then
                  duplicate_gpu_config='{"instances":{"'
                  duplicate_gpu_config="${duplicate_gpu_config}${instance_num}"
                  duplicate_gpu_config="${duplicate_gpu_config}"'":{"gpu_mode":"guest_swiftshader","gpu_mode":"'
                  duplicate_gpu_config="${duplicate_gpu_config}${selected_gpu_mode}"
                  duplicate_gpu_config="${duplicate_gpu_config}"'","enable_gpu_vhost_user":true,"enable_gpu_vhost_user":'
                  duplicate_gpu_config="${duplicate_gpu_config}${selected_gpu_vhost_user_enabled}"
                  duplicate_gpu_config="${duplicate_gpu_config}"'}}}'
                  printf '%s\\n' "$duplicate_gpu_config" \
                    > "$instance/cuttlefish_config.json"
                elif [ "${FAKE_CVD_CONFIG_GPU_VHOST_USER_INVALID_TYPE:-0}" = 1 ]; then
                  printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"%s\",' \
                    "$instance_num" "$selected_gpu_mode" \
                    > "$instance/cuttlefish_config.json"
                  printf '\"enable_gpu_vhost_user\":\"false\"}}}\\n' \
                    >> "$instance/cuttlefish_config.json"
                else
                  printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"%s\",' \
                    "$instance_num" "$selected_gpu_mode" \
                    > "$instance/cuttlefish_config.json"
                  printf '\"enable_gpu_vhost_user\":%s}}}\\n' \
                    "$selected_gpu_vhost_user_enabled" >> "$instance/cuttlefish_config.json"
                fi
                if [ "${APKRUN_CAPTURE_BOOT_OBSERVER:-0}" = 1 ]; then
                  printf 'Start event (5) received.\\n' >> "$instance/launcher.log"
                  attempt=0
                  while [ ! -f "$HOME/cuttlefish-start-event-observed.txt" ] \
                    && [ "$attempt" -lt 100 ]; do
                    sleep 0.05
                    attempt=$((attempt + 1))
                  done
                  if [ ! -f "$HOME/cuttlefish-start-event-observed.txt" ]; then
                    printf 'boot observer did not acknowledge launcher event\\n' >&2
                    exit 1
                  fi
                fi
                if [ "${FAKE_CVD_CONFIG_MISSING:-0}" = 1 ]; then
                  rm -f "$instance/cuttlefish_config.json"
                elif [ "${FAKE_CVD_CONFIG_INVALID:-0}" = 1 ]; then
                  printf '{' > "$instance/cuttlefish_config.json"
                elif [ "${FAKE_CVD_CONFIG_NONSTANDARD_JSON:-0}" = 1 ]; then
                  printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"%s\",\"invalid\":NaN}}}\\n' \
                    "$instance_num" "$selected_gpu_mode" \
                    > "$instance/cuttlefish_config.json"
                elif [ "${FAKE_CVD_CONFIG_OVERSIZED:-0}" = 1 ]; then
                  python3 - "$instance/cuttlefish_config.json" <<'PY'
            import sys
            from pathlib import Path
            with Path(sys.argv[1]).open("wb") as stream:
                stream.truncate(64 * 1024 * 1024 + 1)
            PY
                fi
                if [ "${FAKE_CVD_START_FAILURE:-0}" = 1 ]; then
                  exit 1
                fi
                : > "$HOME/cvd-started.txt"
                if [ "${FAKE_CVD_START_HANG:-0}" = 1 ]; then
                  instance=$(cat "$HOME/instance-runtime.txt")
                  trap 'rm -f "$instance/assemble_cvd.log" \
                    "$instance/kernel.log" "$instance/launcher.log"; exit 0' TERM
                  while :; do sleep 1; done
                fi
                exit 0
              fi
            done
            printf '%s\\n' "$*" >> "$CVD_REMOVE_LOG"
            printf 'cvd %s\\n' "$*" >> "$CAPTURE_EVENT_LOG"
            printf '%s\\n' "$HOME" > "$CVD_REMOVE_HOME_LOG"
            if [ "${FAKE_STOP_HANG:-0}" = 1 ]; then
              trap '' TERM
              while :; do sleep 1; done
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    (fake_bin / "adb").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\\t%s\\n' "$HOME" "$*" >> "$ADB_COMMAND_LOG"
            if [ "${APKRUN_CAPTURE_BOOT_OBSERVER:-0}" = 1 ] \
              && [ "$1" = -L ] && [ "${3:-}" = nodaemon ] && [ "${4:-}" = server ]; then
              : > "$HOME/cuttlefish-start-event-observed.txt"
              exit 0
            fi
            if [ "$1" = connect ] \
              && { [ "${FAKE_CVD_CONFIG_STAGED_MISMATCH:-0}" = 1 ] \
                || [ "${FAKE_CVD_CONFIG_STAGED_VHOST_USER_ENABLED:-0}" = 1 ] \
                || [ "${FAKE_CVD_CONFIG_STAGED_VHOST_USER_INVALID_TYPE:-0}" = 1 ] \
                || [ "${FAKE_CVD_CONFIG_STAGED_INVALID:-0}" = 1 ] \
                || [ "${FAKE_CVD_CONFIG_STAGED_MISSING:-0}" = 1 ]; } \
              && [ ! -f "$HOME/cuttlefish-config-changed.txt" ]; then
              instance=$(cat "$HOME/instance-runtime.txt")
              instance_num=$(cat "$HOME/instance-num.txt")
              if [ "${FAKE_CVD_CONFIG_STAGED_MISMATCH:-0}" = 1 ]; then
                printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"guest_swiftshader\",' \
                  "$instance_num" > "$instance/cuttlefish_config.json"
                printf '\"enable_gpu_vhost_user\":false}}}\\n' \
                  >> "$instance/cuttlefish_config.json"
              elif [ "${FAKE_CVD_CONFIG_STAGED_VHOST_USER_ENABLED:-0}" = 1 ]; then
                printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"drm_virgl\",' \
                  "$instance_num" > "$instance/cuttlefish_config.json"
                printf '\"enable_gpu_vhost_user\":true}}}\\n' \
                  >> "$instance/cuttlefish_config.json"
              elif [ "${FAKE_CVD_CONFIG_STAGED_VHOST_USER_INVALID_TYPE:-0}" = 1 ]; then
                printf '{\"instances\":{\"%s\":{\"gpu_mode\":\"drm_virgl\",' \
                  "$instance_num" > "$instance/cuttlefish_config.json"
                printf '\"enable_gpu_vhost_user\":\"false\"}}}\\n' \
                  >> "$instance/cuttlefish_config.json"
              elif [ "${FAKE_CVD_CONFIG_STAGED_INVALID:-0}" = 1 ]; then
                printf '{' > "$instance/cuttlefish_config.json"
              elif [ "${FAKE_CVD_CONFIG_STAGED_MISSING:-0}" = 1 ]; then
                rm -f "$instance/cuttlefish_config.json"
              fi
              : > "$HOME/cuttlefish-config-changed.txt"
            fi
            if [ "$1" = disconnect ]; then
              printf 'adb disconnect %s\\n' "$2" >> "$CAPTURE_EVENT_LOG"
            fi
            if [ "$1" = connect ] || [ "$1" = disconnect ]; then
              exit 0
            fi
            if [ "$1" = devices ]; then
              if [ "${FAKE_ADB_PREFLIGHT_TIMEOUT:-0}" = 1 ] \
                && [ ! -f "$HOME/instance-num.txt" ]; then
                exit 124
              fi
              echo "List of devices attached"
              instance_file="$HOME/instance-num.txt"
              if [ -f "$instance_file" ]; then
                if [ "${FAKE_ADB_NO_DEVICE:-0}" != 1 ]; then
                  instance_num=$(cat "$instance_file")
                  adb_port=$((6520 + instance_num - 1))
                  echo "127.0.0.1:$adb_port device"
                  echo "10.0.0.5:$adb_port device"
                fi
              fi
              exit 0
            fi
            if [ "$1" = -s ]; then
              shift 2
            fi
            if [ "$1" = shell ] && [ "$2" = getprop ]; then
              if [ "${FAKE_ADB_BOOT_HANG:-0}" = 1 ]; then
                trap '' TERM
                while :; do sleep 1; done
              fi
              echo 1
              exit 0
            fi
            if [ "$1" = wait-for-device ]; then
              if [ "${FAKE_ADB_WAIT_TIMEOUT:-0}" = 1 ]; then
                exit 124
              fi
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
    (fake_bin / "launch_cvd").symlink_to(fake_bin / "cvd")
    (fake_bin / "timeout").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            printf '%s\\t%s\\n' "$HOME" "$*" >> "$TIMEOUT_LOG"
            if [ "${FAKE_USE_REAL_TIMEOUT:-0}" = 1 ]; then
              exec /usr/bin/timeout "$@"
            fi
            case "$1" in
              --kill-after=*|--signal=*) shift ;;
            esac
            timeout_seconds=$1
            shift
            if [ "${FAKE_ADB_PREFLIGHT_TIMEOUT:-0}" = 1 ] \
              && [ "${1:-}" = adb ] && [ "${2:-}" = devices ] \
              && [ ! -f "$HOME/instance-num.txt" ]; then
              exit 124
            fi
            if [ "${1:-}" = adb ] && [ "${2:-}" = disconnect ] \
              && [ "${FAKE_ADB_DISCONNECT_TIMEOUT:-0}" = 1 ]; then
              "$@"
              exit 124
            fi
            if [ "${FAKE_CVD_START_TIMEOUT:-0}" = 1 ] \
              && [ "${1:-}" = cvd ] && [ "${3:-}" = start ]; then
              sleep "$timeout_seconds"
              exit 124
            fi
            if [ "${FAKE_ADB_BOOT_TIMEOUT:-0}" = 1 ] \
              && [ "${1:-}" = adb ] && [ "${5:-}" = getprop ]; then
              sleep "$timeout_seconds"
              exit 124
            fi
            if [ "${FAKE_STOP_TIMEOUT:-0}" = 1 ] \
              && [ "${1:-}" = cvd ] && [ "${3:-}" = remove ]; then
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
                  */"$FAKE_CP_FAIL_NAME"|*/."$FAKE_CP_FAIL_NAME".*) exit 1 ;;
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
        'if [ -n "$cvd_home" ] && [ -f "$cvd_home/launch-args.txt" ]; then\n'
        '  instance_num=$(cat "$cvd_home/instance-num.txt")\n'
        '  instance_runtime=$(cat "$cvd_home/instance-runtime.txt")\n'
        "  other_instance=$((instance_num + 4))\n"
        '  if [ "${1:-}" = -ww ] && [ "${2:-}" = -eo ] && [ "${3:-}" = pid= ]; then\n'
        '    printf "      125\\n      126\\n"\n'
        '    if [ -f "$cvd_home/cvd-started.txt" ]; then\n'
        '      printf "      100\\n      101\\n      123\\n      124\\n      127\\n      128\\n"\n'
        "    fi\n"
        "    exit 0\n"
        "  fi\n"
        '  if [ "${1:-}" = -ww ] && [ "${2:-}" = -p ] && [ "${4:-}" = -o ]; then\n'
        '    case "$3" in\n'
        '      100) printf "crosvm run --instance_num=%s --serial=OTHER\\n" "$other_instance" ;;\n'
        '      101) printf "crosvm run --socket=%s0/vsock.sock\\n" "$instance_runtime" ;;\n'
        '      123) printf "crosvm run --instance_num=%s --serial=EXTERNAL-SAME-NUMBER\\n" '
        '"$instance_num" ;;\n'
        '      124) printf "crosvm run --instance_num=%s --socket=%s/vsock.sock\\n" '
        '"$instance_num" "$instance_runtime" ;;\n'
        '      127) printf "crosvm run --label=x%s/vsock.sock\\n" "$instance_runtime" ;;\n'
        '      128) printf "crosvm run --label=x%s --socket=%s/vsock.sock\\n" '
        '"$instance_runtime" "$instance_runtime" ;;\n'
        '      125) printf "awk -v instance_path=%s \\"crosvm\\"\\n" "$instance_runtime" ;;\n'
        '      126) printf "crosvm helper --socket=%s/vsock.sock\\n" "$instance_runtime" ;;\n'
        "    esac\n"
        "    exit 0\n"
        "  fi\n"
        "fi\n",
        encoding="utf-8",
    )
    (fake_bin / "readlink").write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            case "${1:-}" in
              /proc/100/exe|/proc/101/exe|/proc/123/exe|/proc/124/exe|/proc/127/exe|/proc/128/exe)
                printf '/var/tmp/cvd/host_tools/bin/crosvm\\n'
                ;;
              /proc/125/exe)
                printf '/usr/bin/awk\\n'
                ;;
              /proc/126/exe)
                printf '/usr/bin/crosvm-helper\\n'
                ;;
              *)
                exit 1
                ;;
            esac
            """
        ),
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
    (fake_bin / "crosvm").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_crosvm_override = fake_bin / "crosvm-preload-wrapper"
    fake_crosvm_override.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    for executable in fake_bin.iterdir():
        executable.chmod(0o755)

    product_out = tmp_path / "product-out"
    product_out.mkdir()
    cvd_host_dir = tmp_path / "cvd-host"
    cvd_host_dir.mkdir()
    host_bin = cvd_host_dir / "bin"
    host_bin.mkdir()
    for executable in ("launch_cvd", "cvd", "adb", "crosvm"):
        (host_bin / executable).symlink_to(fake_bin / executable)
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
    cvd_remove_log = tmp_path / "cvd-remove-command.txt"
    timeout_log = tmp_path / "timeout-command.txt"
    capture_event_log = tmp_path / "capture-events.txt"
    cvd_home_log = tmp_path / "cvd-home.txt"
    launch_log = tmp_path / "launch-command.txt"
    start_log = tmp_path / "start-command.txt"
    cvd_remove_home_log = tmp_path / "cvd-remove-home.txt"
    expected_instance = requested_instance or 1
    props_file = tmp_path / "drm-virgl-props.txt"
    props_file.write_text("androidboot.hardware.gralloc=gbm\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.update(
        {
            "CVD_HOST_DIR": str(cvd_host_dir),
            "ANDROID_PRODUCT_OUT": str(product_out),
            "APKRUN_CVD_PACKAGE_VERSION": "synthetic-cvd",
            "APKRUN_TARGET_GPU_MODE": gpu_mode,
            "FAKE_LAUNCH_FAIL": "0" if launch_succeeds else "1",
            "FAKE_CVD_START_HANG": (
                "1" if boot_timeout_case in {"cvd-start", "real-cvd-start"} else "0"
            ),
            "FAKE_CVD_START_FAILURE": ("1" if boot_timeout_case == "cvd-start-no-crosvm" else "0"),
            "FAKE_CVD_CONFIG_GPU_MODE_MISMATCH": (
                "1"
                if boot_timeout_case in {"gpu-mode-mismatch", "gpu-mode-mismatch-observed"}
                else "0"
            ),
            "FAKE_CVD_CONFIG_GPU_VHOST_USER_ENABLED": (
                "1" if boot_timeout_case == "gpu-vhost-user-enabled" else "0"
            ),
            "FAKE_CVD_CONFIG_GPU_VHOST_USER_INVALID_TYPE": (
                "1" if boot_timeout_case == "gpu-vhost-user-invalid-type" else "0"
            ),
            "FAKE_CVD_CONFIG_MISSING": ("1" if boot_timeout_case == "gpu-mode-missing" else "0"),
            "FAKE_CVD_CONFIG_INVALID": ("1" if boot_timeout_case == "gpu-mode-invalid" else "0"),
            "FAKE_CVD_CONFIG_NONSTANDARD_JSON": (
                "1" if boot_timeout_case == "gpu-mode-nonstandard-json" else "0"
            ),
            "FAKE_CVD_CONFIG_DUPLICATE_KEY": (
                "1" if boot_timeout_case == "gpu-mode-duplicate-key" else "0"
            ),
            "FAKE_CVD_CONFIG_STAGED_MISMATCH": (
                "1" if boot_timeout_case == "gpu-mode-staged-mismatch" else "0"
            ),
            "FAKE_CVD_CONFIG_STAGED_VHOST_USER_ENABLED": (
                "1" if boot_timeout_case == "gpu-vhost-user-staged-enabled" else "0"
            ),
            "FAKE_CVD_CONFIG_STAGED_VHOST_USER_INVALID_TYPE": (
                "1" if boot_timeout_case == "gpu-vhost-user-staged-invalid-type" else "0"
            ),
            "FAKE_CVD_CONFIG_STAGED_INVALID": (
                "1" if boot_timeout_case == "gpu-mode-staged-invalid" else "0"
            ),
            "FAKE_CVD_CONFIG_STAGED_MISSING": (
                "1" if boot_timeout_case == "gpu-mode-staged-missing" else "0"
            ),
            "FAKE_CVD_CONFIG_OVERSIZED": (
                "1" if config_oversized or boot_timeout_case == "gpu-mode-oversized" else "0"
            ),
            "APKRUN_CAPTURE_BOOT_OBSERVER": (
                "1" if boot_timeout_case == "gpu-mode-mismatch-observed" else "0"
            ),
            "APKRUN_CROSVM_BINARY": (
                str(fake_crosvm_override)
                if boot_timeout_case == "crosvm-binary-override"
                else "relative/crosvm"
                if boot_timeout_case == "crosvm-binary-override-relative"
                else ""
            ),
            "FAKE_CVD_CREATE_FAIL_AFTER_LOGS": "1" if not launch_succeeds else "0",
            "FAKE_CVD_LOGS_EMPTY_FIRST": "1" if not launch_succeeds else "0",
            "FAKE_CVD_CREATE_EXIT_STATUS": (
                "124" if boot_timeout_case == "cvd-create-124" else "1"
            ),
            "FAKE_CVD_CREATE_FAILURE_DELAY_SECONDS": (
                "0.65" if boot_timeout_case == "cvd-create-delayed-logs" else "0.75"
            ),
            "FAKE_CVD_FIRST_LOGS_DELAY_SECONDS": (
                "0.4" if boot_timeout_case == "cvd-create-delayed-logs" else "0"
            ),
            "FAKE_ADB_BOOT_TIMEOUT": ("1" if boot_timeout_case == "adb-getprop" else "0"),
            "FAKE_ADB_BOOT_HANG": ("1" if boot_timeout_case == "real-adb-getprop" else "0"),
            "FAKE_ADB_PREFLIGHT_TIMEOUT": ("1" if boot_timeout_case == "adb-preflight" else "0"),
            "FAKE_ADB_WAIT_TIMEOUT": ("1" if boot_timeout_case == "adb-wait-for-device" else "0"),
            "FAKE_ADB_NO_DEVICE": "1" if boot_timeout_case == "adb-no-device" else "0",
            "FAKE_CVD_CREATE_DELAY_SECONDS": (
                "0.1"
                if boot_timeout_case == "cvd-create-delayed-logs"
                else "1"
                if boot_timeout_case == "cvd-start"
                else "2"
                if boot_timeout_case in {"adb-getprop", "shared-deadline", "adb-no-device"}
                else "0"
            ),
            "FAKE_USE_REAL_TIMEOUT": (
                "1"
                if stop_timeout == "real"
                or boot_timeout_case in {"real-cvd-start", "real-adb-getprop"}
                else "0"
            ),
            "FAKE_CP_FAIL_NAME": "",
            "FAKE_ABORT_CAPTURE": "1" if abort_command else "0",
            "FAKE_ABORT_CAPTURE_COMMAND": abort_command or "",
            "FAKE_INTERRUPT_COMPOSITE_COLLECTOR": (
                "1" if boot_timeout_case == "composite-specs-interrupted" else "0"
            ),
            "FAKE_RM_FAIL_LOGCAT_RAW": "1" if raw_cleanup_fails else "0",
            "FAKE_RM_FAIL_STAGE": "1" if raw_cleanup_fails == "stage-fails" else "0",
            "FAKE_STOP_TIMEOUT": "1" if stop_timeout is True else "0",
            "FAKE_STOP_HANG": "1" if stop_timeout == "real" else "0",
            "FAKE_ADB_DISCONNECT_TIMEOUT": "1" if abort_command else "0",
            "FAKE_SIGNAL_DURING_LOCK": "1" if lock_signal_during_acquire else "0",
            "FAKE_CAPTURE_LOCK_PATH": str(host_lock_root / "apkrun-cvd-capture.lock"),
            "ADB_COMMAND_LOG": str(adb_log),
            "CVD_REMOVE_LOG": str(cvd_remove_log),
            "CAPTURE_EVENT_LOG": str(capture_event_log),
            "TIMEOUT_LOG": str(timeout_log),
            "CVD_REMOVE_HOME_LOG": str(cvd_remove_home_log),
            "CVD_HOME_LOG": str(cvd_home_log),
            "LAUNCH_LOG": str(launch_log),
            "APKRUN_PROFILE_START_LOG": str(start_log),
            "HOME": str(home),
            "APKRUN_REAL_PYTHON": sys.executable,
            "PATH": (f"{fake_bin}:{TOOLS_ROOT / '.venv' / 'bin'}:{os.environ['PATH']}"),
            "TMPDIR": str(tmp_path),
        }
    )
    if stop_timeout == "real":
        environment["APKRUN_CVD_STOP_TIMEOUT_SECONDS"] = "1"
    if boot_timeout_case in {"real-cvd-start", "real-adb-getprop"}:
        environment["APKRUN_BOOT_TIMEOUT_SECONDS"] = "10"
    elif boot_timeout_case in {"cvd-start", "cvd-start-no-crosvm"}:
        environment["APKRUN_BOOT_TIMEOUT_SECONDS"] = "10"
    elif boot_timeout_case == "adb-getprop":
        environment["APKRUN_BOOT_TIMEOUT_SECONDS"] = "6"
    elif boot_timeout_case == "adb-no-device":
        environment["APKRUN_BOOT_TIMEOUT_SECONDS"] = "10"
    elif boot_timeout_case != "shared-deadline":
        environment["APKRUN_BOOT_TIMEOUT_SECONDS"] = "600"
    environment.pop("APKRUN_CVD_INSTANCE_NUM", None)
    if requested_instance is not None:
        environment["APKRUN_CVD_INSTANCE_NUM"] = str(requested_instance)
    if capture_lock_held:
        (host_lock_root / "apkrun-cvd-capture.lock").mkdir()
    if gpu_mode == "guest_swiftshader":
        environment["APKRUN_DRM_VIRGL_PROPS_FILE"] = str(props_file)
        environment["APKRUN_DRM_VIRGL_SOURCE_REVISION"] = "a" * 40

    capture_started_at = time.monotonic()
    result = subprocess.run(
        ["sh", str(reference_tools / "capture.sh"), "target"],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=25 if boot_timeout_case in {"real-cvd-start", "real-adb-getprop"} else None,
    )
    capture_elapsed_seconds = time.monotonic() - capture_started_at

    def assert_scoped_group_removal() -> None:
        launch_arguments = launch_log.read_text(encoding="utf-8").split()
        group_argument = next(
            argument for argument in launch_arguments if argument.startswith("--group_name=")
        )
        assert cvd_remove_log.read_text(encoding="utf-8").strip() == (f"{group_argument} remove")
        assert cvd_remove_home_log.read_text(encoding="utf-8").strip() == (
            cvd_home_log.read_text(encoding="utf-8").strip()
        )

    def assert_adb_disconnect_precedes_group_removal() -> None:
        events = capture_event_log.read_text(encoding="utf-8").splitlines()
        adb_serial = f"127.0.0.1:{6520 + expected_instance - 1}"
        disconnect_index = events.index(f"adb disconnect {adb_serial}")
        remove_index = next(
            index
            for index, event in enumerate(events)
            if event.startswith("cvd --group_name=") and event.endswith(" remove")
        )
        assert disconnect_index < remove_index

    if not should_capture:
        expected_status = (
            2
            if build_id != "16373615"
            or capture_lock_held
            or boot_timeout_case == "crosvm-binary-override-relative"
            else 143
            if abort_command
            or lock_signal_during_acquire
            or boot_timeout_case == "composite-specs-interrupted"
            else 1
        )
        assert result.returncode == expected_status
        assert not (repo / "Images/reference/16373615/target").exists()
        if boot_timeout_case == "adb-preflight":
            assert "ADB did not respond during the 10-second preflight" in result.stderr
            assert not launch_log.exists()
            assert not (repo / "Images/reference/16373615/incomplete").exists()
            timeout_calls = timeout_log.read_text(encoding="utf-8").splitlines()
            assert any(line.endswith("\t--kill-after=2s 10 adb devices") for line in timeout_calls)
        elif boot_timeout_case == "crosvm-binary-override-relative":
            assert (
                "APKRUN_CROSVM_BINARY must be an absolute path to an executable file."
                in result.stderr
            )
            assert not launch_log.exists()
            assert not (repo / "Images/reference/16373615/incomplete").exists()
        elif boot_timeout_case == "crosvm-binary-override":
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert (
                "diagnostic-only\tcrosvm binary override changes the host runtime; "
                "this capture is never a reference profile"
            ) in missing
            launch_arguments = launch_log.read_text(encoding="utf-8").split()
            assert f"--crosvm_binary={fake_crosvm_override}" in launch_arguments
            assert start_log.is_file()
            start_arguments = start_log.read_text(encoding="utf-8").split()
            assert any(argument == "start" for argument in start_arguments)
            adb_calls = [
                line.split("\t", maxsplit=1)[1]
                for line in adb_log.read_text(encoding="utf-8").splitlines()
            ]
            assert any(
                call.startswith("-s 127.0.0.1:6522 shell getprop sys.boot_completed")
                for call in adb_calls
            )
            assert any(call.startswith("-s 127.0.0.1:6522 exec-out") for call in adb_calls)
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        elif build_id != "16373615":
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
            assert "scoped cvd remove reported a shutdown failure" in missing
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert cvd_home.is_dir()
            assert cvd_remove_log.exists() is (stop_timeout == "real")
            if stop_timeout == "real":
                assert cvd_remove_home_log.read_text(encoding="utf-8").strip() == str(cvd_home)
                launch_arguments = launch_log.read_text(encoding="utf-8").split()
                group_argument = next(
                    argument
                    for argument in launch_arguments
                    if argument.startswith("--group_name=")
                )
                expected_remove_timeout = f"--kill-after=10s 1 cvd {group_argument} remove"
            else:
                expected_remove_timeout = "--kill-after=10s 120 cvd --group_name=apkrun_target_"
            timeout_command = timeout_log.read_text(encoding="utf-8").strip()
            if stop_timeout == "real":
                assert timeout_command.endswith(expected_remove_timeout)
            else:
                assert expected_remove_timeout in timeout_command
        elif config_oversized:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert (
                "cuttlefish_config.json\tnot a regular Cuttlefish config or exceeds 64 MiB"
            ) in missing
            assert "selected-gpu-mode\t" in missing
            adb_calls = [
                line.split("\t", maxsplit=1)[1]
                for line in adb_log.read_text(encoding="utf-8").splitlines()
            ]
            assert not any(call.startswith("connect ") for call in adb_calls)
            assert not any(" getprop " in f" {call} " for call in adb_calls)
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        elif boot_timeout_case in {
            "gpu-mode-mismatch",
            "gpu-mode-mismatch-observed",
            "gpu-vhost-user-enabled",
            "gpu-vhost-user-invalid-type",
            "gpu-mode-missing",
            "gpu-mode-invalid",
            "gpu-mode-oversized",
            "gpu-mode-nonstandard-json",
            "gpu-mode-duplicate-key",
        }:
            assert result.returncode == 1
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            partial = partials[0]
            missing = (partial / "MISSING.txt").read_text(encoding="utf-8")
            metadata = json.loads((partial / "host.json").read_text(encoding="utf-8"))
            assert metadata["targetGpuMode"] == "drm_virgl"
            if boot_timeout_case == "gpu-vhost-user-enabled":
                assert missing.count("selected-gpu-mode\t") == 0
                assert missing.count("selected-gpu-vhost-user\t") == 1
                assert (
                    "selected-gpu-vhost-user\tCuttlefish selected "
                    "enable_gpu_vhost_user=true instead of the requested off state; "
                    "do not use this capture for GPU-profile comparison"
                ) in missing
                assert metadata["selectedGpuMode"] == "drm_virgl"
                assert metadata["gpuVhostUserEnabled"] is True
                config = json.loads(
                    (partial / "cuttlefish_config.json").read_text(encoding="utf-8")
                )
                assert config["instances"][str(expected_instance)]["enable_gpu_vhost_user"] is True
            elif boot_timeout_case == "gpu-vhost-user-invalid-type":
                assert missing.count("selected-gpu-mode\t") == 1
                assert missing.count("selected-gpu-vhost-user\t") == 0
                assert (
                    "selected-gpu-mode\tCuttlefish did not record valid GPU settings "
                    "for the selected instance; do not use this capture for GPU-profile "
                    "comparison"
                ) in missing
                assert metadata["selectedGpuMode"] is None
                assert metadata["gpuVhostUserEnabled"] is None
                config = json.loads(
                    (partial / "cuttlefish_config.json").read_text(encoding="utf-8")
                )
                assert (
                    config["instances"][str(expected_instance)]["enable_gpu_vhost_user"] == "false"
                )
            else:
                assert missing.count("selected-gpu-mode\t") == 1
                assert metadata["gpuVhostUserEnabled"] is (
                    False
                    if boot_timeout_case
                    in {
                        "gpu-mode-mismatch",
                        "gpu-mode-mismatch-observed",
                    }
                    else None
                )
            if boot_timeout_case in {
                "gpu-mode-mismatch",
                "gpu-mode-mismatch-observed",
            }:
                assert (
                    "selected-gpu-mode\tCuttlefish selected guest_swiftshader instead of "
                    "requested drm_virgl; do not use this capture for GPU-profile comparison"
                ) in missing
                assert metadata["selectedGpuMode"] == "guest_swiftshader"
                config = json.loads(
                    (partial / "cuttlefish_config.json").read_text(encoding="utf-8")
                )
                assert (
                    config["instances"][str(expected_instance)]["gpu_mode"] == "guest_swiftshader"
                )
            elif boot_timeout_case not in {
                "gpu-vhost-user-enabled",
                "gpu-vhost-user-invalid-type",
            }:
                assert "do not use this capture for GPU-profile comparison" in missing
                assert metadata["selectedGpuMode"] is None
                if boot_timeout_case == "gpu-mode-missing":
                    assert "cuttlefish_config.json\tnot found" in missing
                elif boot_timeout_case == "gpu-mode-invalid":
                    assert (partial / "cuttlefish_config.json").read_text(encoding="utf-8") == "{"
                elif boot_timeout_case == "gpu-mode-nonstandard-json":
                    assert "NaN" in (partial / "cuttlefish_config.json").read_text(encoding="utf-8")
                elif boot_timeout_case == "gpu-mode-duplicate-key":
                    duplicate_config = (partial / "cuttlefish_config.json").read_text(
                        encoding="utf-8"
                    )
                    assert '"gpu_mode":"guest_swiftshader","gpu_mode":"drm_virgl"' in (
                        duplicate_config
                    )
                    assert '"enable_gpu_vhost_user":true,"enable_gpu_vhost_user":false' in (
                        duplicate_config
                    )
                else:
                    assert (
                        "cuttlefish_config.json\tnot a regular Cuttlefish config or exceeds 64 MiB"
                    ) in missing
                    assert not (partial / "cuttlefish_config.json").exists()
            adb_calls = [
                line.split("\t", maxsplit=1)[1]
                for line in adb_log.read_text(encoding="utf-8").splitlines()
            ]
            assert not any(call.startswith("connect ") for call in adb_calls)
            assert not any(" getprop " in f" {call} " for call in adb_calls)
            if boot_timeout_case == "gpu-mode-mismatch-observed":
                observer_records = [
                    json.loads(line)
                    for line in (partial / "boot-observer.jsonl")
                    .read_text(encoding="utf-8")
                    .splitlines()
                ]
                assert any(
                    record["event"] == "cuttlefish_start_event_5_observed"
                    for record in observer_records
                )
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
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
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
            adb_serial = f"127.0.0.1:{6520 + expected_instance - 1}"
            adb_calls = [
                arguments
                for _, arguments in (
                    line.split("\t", maxsplit=1)
                    for line in adb_log.read_text(encoding="utf-8").splitlines()
                )
            ]
            assert f"disconnect {adb_serial}" in adb_calls
            timeout_calls = timeout_log.read_text(encoding="utf-8").splitlines()
            assert any(
                line.endswith(f"\t--kill-after=2s 10 adb disconnect {adb_serial}")
                for line in timeout_calls
            )
            assert_adb_disconnect_precedes_group_removal()
            assert_scoped_group_removal()
        elif boot_timeout_case == "composite-specs-interrupted":
            assert "normalized incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            partial = partials[0]
            missing = (partial / "MISSING.txt").read_text(encoding="utf-8")
            assert "process exited before normal capture completion" in missing
            assert not list(partial.glob(".composite-disk-specs.json.*"))
            captured = b"".join(path.read_bytes() for path in partial.rglob("*") if path.is_file())
            assert b"interrupted-raw-config" not in captured
            assert b"/var/tmp/cvd/" not in captured
            assert_adb_disconnect_precedes_group_removal()
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        elif boot_timeout_case == "adb-wait-for-device":
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert "guest\tadb wait-for-device failed" in missing
            adb_calls = [
                line.split("\t", maxsplit=1)[1]
                for line in adb_log.read_text(encoding="utf-8").splitlines()
            ]
            assert any(call.endswith(" wait-for-device") for call in adb_calls)
            assert not any(" exec-out " in f" {call} " for call in adb_calls)
            assert_adb_disconnect_precedes_group_removal()
            assert_scoped_group_removal()
        elif boot_timeout_case == "adb-no-device":
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert any(
                diagnostic in missing
                for diagnostic in (
                    "sys.boot_completed did not become 1 within 10s",
                    "ADB did not respond before APKRUN_BOOT_TIMEOUT_SECONDS expired",
                    "ADB did not report sys.boot_completed before "
                    "APKRUN_BOOT_TIMEOUT_SECONDS expired",
                )
            )
            timeout_calls = [
                shlex.split(line.split("\t", maxsplit=1)[1])
                for line in timeout_log.read_text(encoding="utf-8").splitlines()
            ]
            sleep_calls = [call for call in timeout_calls if len(call) >= 4 and call[2] == "sleep"]
            assert sleep_calls
            assert all(
                call[0] == "--kill-after=2s"
                and call[1].isdigit()
                and 0 < int(call[3]) <= min(2, int(call[1]))
                for call in sleep_calls
            )
            adb_calls = [
                line.split("\t", maxsplit=1)[1]
                for line in adb_log.read_text(encoding="utf-8").splitlines()
            ]
            assert not any("getprop" in call or "exec-out" in call for call in adb_calls)
            assert_adb_disconnect_precedes_group_removal()
            assert_scoped_group_removal()
        elif boot_timeout_case in {
            "cvd-start",
            "cvd-start-no-crosvm",
            "real-cvd-start",
        }:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            if boot_timeout_case == "cvd-start-no-crosvm":
                assert "Cuttlefish group create or start failed" in missing
                assert not (partials[0] / "crosvm-command-line.txt").exists()
                assert (
                    "crosvm-command-line.txt\tno crosvm process matched the private "
                    "Cuttlefish HOME at artifact-collection time; this does not establish "
                    "whether crosvm ran earlier"
                ) in missing
            else:
                expected_timeout_seconds = "10"
                assert (
                    "Cuttlefish create or start exceeded the "
                    f"{expected_timeout_seconds}-second boot deadline"
                ) in missing
                assert "crosvm run" in (
                    (partials[0] / "crosvm-command-line.txt").read_text(encoding="utf-8")
                )
            timeout_calls = [
                shlex.split(line.split("\t", maxsplit=1)[1])
                for line in timeout_log.read_text(encoding="utf-8").splitlines()
            ]
            cvd_runner_calls = [
                call
                for call in timeout_calls
                if any("capture_cvd_start.py" in value for value in call)
            ]
            assert len(cvd_runner_calls) == 2
            assert cvd_runner_calls[0][cvd_runner_calls[0].index("--") + 1] == "cvd"
            assert cvd_runner_calls[0][cvd_runner_calls[0].index("--") + 2] == "create"
            start_command = cvd_runner_calls[1][cvd_runner_calls[1].index("--") + 1 :]
            assert start_command[0] == "cvd"
            assert start_command[1].startswith("--group_name=apkrun_target_")
            assert start_command[2] == "start"
            assert start_command[3].startswith("--boot_timeout_secs=")
            assert all(call[0] == "--kill-after=2s" for call in cvd_runner_calls)
            assert all(call[1].isdigit() and int(call[1]) > 0 for call in cvd_runner_calls)
            if boot_timeout_case == "cvd-start":
                assert capture_elapsed_seconds >= 10
                assert capture_elapsed_seconds < 18
            elif boot_timeout_case == "cvd-start-no-crosvm":
                assert capture_elapsed_seconds < 10
            else:
                assert capture_elapsed_seconds >= 10
                assert capture_elapsed_seconds < 25
            start_log_arguments = start_log.read_text(encoding="utf-8").split()
            assert start_log_arguments[0].startswith("--group_name=apkrun_target_")
            assert start_log_arguments[1] == "start"
            assert start_log_arguments[2] == start_command[3]
            assert (partials[0] / "kernel.log").read_text(encoding="utf-8") == (
                "VIRTUAL_DEVICE_BOOT_COMPLETED\n"
            )
            assert (partials[0] / "launcher.log").read_text(encoding="utf-8") == (
                "launcher synthetic log\n"
            )
            assert (partials[0] / "assemble_cvd.log").read_text(encoding="utf-8") == (
                "assemble synthetic log\n"
            )
            assert not any(
                f"{name}\t" in missing
                for name in ("kernel.log", "launcher.log", "assemble_cvd.log")
            )
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        elif boot_timeout_case in {"adb-getprop", "real-adb-getprop"}:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert (
                "ADB did not report sys.boot_completed before APKRUN_BOOT_TIMEOUT_SECONDS expired"
            ) in missing
            timeout_calls = [
                shlex.split(line.split("\t", maxsplit=1)[1])
                for line in timeout_log.read_text(encoding="utf-8").splitlines()
            ]
            getprop_calls = [
                call
                for call in timeout_calls
                if len(call) >= 8
                and call[2:]
                == [
                    "adb",
                    "-s",
                    "127.0.0.1:6522",
                    "shell",
                    "getprop",
                    "sys.boot_completed",
                ]
            ]
            assert len(getprop_calls) == 1
            assert getprop_calls[0][0] == "--kill-after=2s"
            assert getprop_calls[0][1].isdigit() and int(getprop_calls[0][1]) > 0
            cvd_runner_calls = [
                call
                for call in timeout_calls
                if any("capture_cvd_start.py" in value for value in call)
            ]
            assert len(cvd_runner_calls) == 2
            create_timeout = cvd_runner_calls[0][cvd_runner_calls[0].index("--timeout-seconds") + 1]
            start_timeout = cvd_runner_calls[1][cvd_runner_calls[1].index("--timeout-seconds") + 1]
            if boot_timeout_case == "adb-getprop":
                assert int(getprop_calls[0][1]) <= int(start_timeout) < int(create_timeout)
            else:
                assert capture_elapsed_seconds >= 10
                assert capture_elapsed_seconds < 25
            assert_adb_disconnect_precedes_group_removal()
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
        else:
            assert "Incomplete capture retained" in result.stderr
            partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
            assert len(partials) == 1
            assert "Cuttlefish group create or start failed" in (
                (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            )
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            if boot_timeout_case == "cvd-create-124":
                assert "exceeded the" not in missing
            assert (partials[0] / "kernel.log").read_text(encoding="utf-8") == (
                "VIRTUAL_DEVICE_BOOT_COMPLETED\n"
            )
            assert (partials[0] / "launcher.log").read_text(encoding="utf-8") == (
                "launcher synthetic log\n"
            )
            assert (partials[0] / "assemble_cvd.log").read_text(encoding="utf-8") == (
                "assemble synthetic log\n"
            )
            assert not any(
                f"{name}\t" in missing
                for name in ("kernel.log", "launcher.log", "assemble_cvd.log")
            )
            assert_scoped_group_removal()
            cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
            assert not cvd_home.exists()
            missing = (partials[0] / "MISSING.txt").read_text(encoding="utf-8")
            assert str(cvd_home) not in missing
        if not capture_lock_held:
            assert not (host_lock_root / "apkrun-cvd-capture.lock").exists()
        return

    if boot_timeout_case in {
        "gpu-mode-staged-mismatch",
        "gpu-vhost-user-staged-enabled",
        "gpu-vhost-user-staged-invalid-type",
        "gpu-mode-staged-invalid",
        "gpu-mode-staged-missing",
    }:
        assert result.returncode == 1, result.stderr
        partials = list((repo / "Images/reference/16373615/incomplete").glob("target-*"))
        assert len(partials) == 1
        partial = partials[0]
        missing = (partial / "MISSING.txt").read_text(encoding="utf-8")
        metadata = json.loads((partial / "host.json").read_text(encoding="utf-8"))
        assert metadata["targetGpuMode"] == "drm_virgl"
        if boot_timeout_case == "gpu-vhost-user-staged-enabled":
            assert missing.count("selected-gpu-mode\t") == 0
            assert missing.count("selected-gpu-vhost-user\t") == 1
            assert (
                "selected-gpu-vhost-user\tcaptured Cuttlefish config selected "
                "enable_gpu_vhost_user=true instead of the requested off state; "
                "do not use this capture for GPU-profile comparison"
            ) in missing
            assert metadata["selectedGpuMode"] == "drm_virgl"
            assert metadata["gpuVhostUserEnabled"] is True
            config = json.loads((partial / "cuttlefish_config.json").read_text(encoding="utf-8"))
            assert config["instances"][str(expected_instance)]["enable_gpu_vhost_user"] is True
        else:
            assert missing.count("selected-gpu-mode\t") == 1
            assert metadata["gpuVhostUserEnabled"] is False
        if boot_timeout_case == "gpu-mode-staged-mismatch":
            assert (
                "selected-gpu-mode\tcaptured Cuttlefish config selected guest_swiftshader "
                "instead of requested drm_virgl; do not use this capture for GPU-profile comparison"
            ) in missing
            assert metadata["selectedGpuMode"] == "guest_swiftshader"
            config = json.loads((partial / "cuttlefish_config.json").read_text(encoding="utf-8"))
            assert config["instances"][str(expected_instance)]["gpu_mode"] == "guest_swiftshader"
        elif boot_timeout_case == "gpu-mode-staged-invalid":
            assert (
                "selected-gpu-mode\tcaptured cuttlefish_config.json did not contain valid "
                "GPU settings for the selected instance; do not use this capture for "
                "GPU-profile comparison"
            ) in missing
            assert metadata["selectedGpuMode"] == "drm_virgl"
            assert (partial / "cuttlefish_config.json").read_text(encoding="utf-8") == "{"
        elif boot_timeout_case == "gpu-vhost-user-staged-invalid-type":
            assert (
                "selected-gpu-mode\tcaptured cuttlefish_config.json did not contain valid "
                "GPU settings for the selected instance; do not use this capture for "
                "GPU-profile comparison"
            ) in missing
            assert metadata["selectedGpuMode"] == "drm_virgl"
            config = json.loads((partial / "cuttlefish_config.json").read_text(encoding="utf-8"))
            assert config["instances"][str(expected_instance)]["enable_gpu_vhost_user"] == "false"
        elif boot_timeout_case == "gpu-mode-staged-missing":
            assert (
                "selected-gpu-mode\tcaptured cuttlefish_config.json is unavailable for the "
                "selected instance; do not use this capture for GPU-profile comparison"
            ) in missing
            assert metadata["selectedGpuMode"] == "drm_virgl"
            assert not (partial / "cuttlefish_config.json").exists()
        adb_calls = [
            line.split("\t", maxsplit=1)[1]
            for line in adb_log.read_text(encoding="utf-8").splitlines()
        ]
        assert any(" shell getprop sys.boot_completed" in f" {call}" for call in adb_calls)
        assert not (repo / "Images/reference/16373615/target").exists()
        assert_scoped_group_removal()
        assert_adb_disconnect_precedes_group_removal()
        cvd_home = Path(cvd_home_log.read_text(encoding="utf-8").strip())
        assert not cvd_home.exists()
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
    assert metadata["selectedGpuMode"] == gpu_mode
    assert metadata["gpuVhostUserEnabled"] is False
    assert (capture / "MISSING.txt").read_text(encoding="utf-8") == ""
    assert (capture / "internal-bootconfig.txt").read_bytes() == b"androidboot.synthetic=1\n"
    composite_specs = json.loads(
        (capture / "composite-disk-specs.json").read_text(encoding="utf-8")
    )
    assert set(composite_specs["files"]) == {
        "ap_composite_disk_config.txt",
        "os_composite_disk_config.txt",
        "persistent_composite_disk_config.txt",
    }
    assert all(
        "/var/tmp/cvd/" not in contents and str(cvd_home) not in contents
        for contents in composite_specs["files"].values()
    )
    assert all("<HOST_PATH>" in contents for contents in composite_specs["files"].values())
    crosvm_command = (capture / "crosvm-command-line.txt").read_text(encoding="utf-8")
    assert f"--instance_num={expected_instance}" in crosvm_command
    assert f"--instance_num={expected_instance + 4}" not in crosvm_command
    assert "EXTERNAL-SAME-NUMBER" not in crosvm_command
    assert "125 awk" not in crosvm_command
    assert "127 crosvm run --label=x" not in crosvm_command
    assert "128 crosvm run --label=x" in crosvm_command
    assert f"/instances/cvd-{expected_instance}0/" not in crosvm_command
    launch_arguments = launch_log.read_text(encoding="utf-8").split()
    assert f"--gpu_mode={gpu_mode}" in launch_arguments
    assert "--gpu_vhost_user_mode=off" in launch_arguments
    assert "--secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure" in launch_arguments
    assert f"--base_instance_num={expected_instance}" in launch_arguments
    assert "--num_instances=1" in launch_arguments
    assert f"--host_path={cvd_host_dir}" in launch_arguments
    assert f"--product_path={cvd_home}/product" in launch_arguments
    assert f"--base_directory={cvd_home}" in launch_arguments
    assert (product_out / "boot.img").read_bytes() == boot_image
    assert any(argument.startswith("--group_name=apkrun_target_") for argument in launch_arguments)
    group_argument = next(
        argument for argument in launch_arguments if argument.startswith("--group_name=")
    )
    assert group_argument == group_argument.lower()
    assert "-" not in group_argument.split("=", maxsplit=1)[1]
    start_arguments = start_log.read_text(encoding="utf-8").split()
    assert f"--gpu_mode={gpu_mode}" in start_arguments
    assert "--gpu_vhost_user_mode=off" in start_arguments
    assert_scoped_group_removal()
    assert not cvd_home.exists()
    assert not (host_lock_root / "apkrun-cvd-capture.lock").exists()
    adb_calls = [
        tuple(line.split("\t", maxsplit=1))
        for line in adb_log.read_text(encoding="utf-8").splitlines()
    ]
    adb_serial = f"127.0.0.1:{6520 + expected_instance - 1}"
    assert any(arguments.startswith(f"-s {adb_serial} exec-out") for _, arguments in adb_calls)
    assert any(arguments == f"connect {adb_serial}" for _, arguments in adb_calls)
    assert any(arguments == f"disconnect {adb_serial}" for _, arguments in adb_calls)
    assert all(
        arguments.startswith("devices")
        or arguments.startswith(f"connect {adb_serial}")
        or arguments.startswith(f"disconnect {adb_serial}")
        or arguments.startswith(f"-s {adb_serial}")
        for _, arguments in adb_calls
    )
    assert all(
        home_path == str(cvd_home)
        for home_path, arguments in adb_calls
        if arguments.startswith(f"-s {adb_serial}")
    )
    assert_adb_disconnect_precedes_group_removal()
    if boot_timeout_case == "shared-deadline":
        timeout_calls = [
            shlex.split(line.split("\t", maxsplit=1)[1])
            for line in timeout_log.read_text(encoding="utf-8").splitlines()
        ]
        cvd_runner_calls = [
            call for call in timeout_calls if any("capture_cvd_start.py" in value for value in call)
        ]
        getprop_calls = [
            call
            for call in timeout_calls
            if len(call) >= 8
            and call[2:]
            == [
                "adb",
                "-s",
                f"127.0.0.1:{6520 + expected_instance - 1}",
                "shell",
                "getprop",
                "sys.boot_completed",
            ]
        ]
        assert len(cvd_runner_calls) == 2
        assert len(getprop_calls) == 1
        create_timeout = cvd_runner_calls[0][cvd_runner_calls[0].index("--timeout-seconds") + 1]
        start_timeout = cvd_runner_calls[1][cvd_runner_calls[1].index("--timeout-seconds") + 1]
        assert cvd_runner_calls[0][0] == "--kill-after=2s"
        assert 0 < int(create_timeout) <= 600
        start_log_arguments = start_log.read_text(encoding="utf-8").split()
        assert start_log_arguments[0].startswith("--group_name=apkrun_target_")
        assert start_log_arguments[1] == "start"
        assert start_log_arguments[2].startswith("--boot_timeout_secs=")
        assert getprop_calls[0][0] == "--kill-after=2s"
        assert 0 < int(getprop_calls[0][1]) <= int(start_timeout) < int(create_timeout)
    if gpu_mode == "guest_swiftshader":
        assert (capture / "graphics-props-from-source.txt").read_text(
            encoding="utf-8"
        ) == props_file.read_text(encoding="utf-8")
        assert metadata["drmVirglSourceRevision"] == "a" * 40
