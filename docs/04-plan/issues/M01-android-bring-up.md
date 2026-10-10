# M1 Android bring-up

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.1 |
| Related | [README.md](README.md), [../roadmap.md](../roadmap.md) §2, [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../traceability.md](../traceability.md), [../../02-design/android-image.md](../../02-design/android-image.md), [../../05-development/workflow.md](../../05-development/workflow.md) |

## Milestone goal

The stock Cuttlefish arm64 userdebug build 16373615 (Android 17, API 37) boots on Virtualization.framework with direct kernel boot. It reaches `sys.boot_completed=1` and stays stable (gate G2). This is: kernel → init → zygote → system_server → boot_completed.

A developer then reaches the guest with ADB over vsock, on host loopback only. They install HelloText through PackageInstaller, launch its Activity, stop it, and uninstall it, all without a display.

The Python pipeline under `Images/tools/` turns the downloaded artifacts into a signed runtime image bundle, and ImageCore installs that bundle.

M1 delivers the "Android ARM64 boot" item of the v0.1 Definition of Done ([../roadmap.md](../roadmap.md) §3.1). It also delivers the ADB-level half of "CLI launch": #017 here, completed by #027.

## Exit criteria

- [ ] All 13 tasks below meet every acceptance criterion.
- [ ] Gate G2 passes on the reference Mac with a clean build from `main`, meeting all four conditions of [../roadmap.md](../roadmap.md) §2. The T3 reference diff reports no unexplained difference ([../../02-design/android-image.md](../../02-design/android-image.md) §8.4, §15).
- [ ] These files are committed:
  - `Images/manifests/16373615/inventory.json` and `android-image.json`.
  - `Images/reference/16373615/{default,target,swiftshader}/` and `Images/reference/16373615/expected-differences.yaml`.
  - `Images/reference/vz/<macOS build>/topology.txt`.
- [ ] A second inventory run is byte-identical. `manifest --check` passes in CI.
- [ ] `adb -s 127.0.0.1:6520` runs `getprop`, `ps -A`, `pm list packages`, and `logcat` against the guest. Nothing listens for ADB on a non-loopback address.
- [ ] HelloText is installed, launched, stopped, and uninstalled over ADB by a T2 test.
- [ ] A signed bundle built from the stock build installs with `apkrun-dev dev image install` and boots to `sys.boot_completed=1`.
- [ ] Each of these holds its verified results for build 16373615:
  - [../../02-design/android-image.md](../../02-design/android-image.md) §4.1, §4.2, §5.3, §6.2, §7, §7.7, and one §13 row per deviation found.
  - [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3.
- [ ] R-06, R-11, and R-12 in [../risks.md](../risks.md) each have a result and an updated status.
- [ ] Tests pass:
  - T0 and T1 on `main`.
  - T2 on the reference Mac: `LinuxGuestTests` (the new `parts`, `bootconfig`, and 20-port checks), `AndroidBootTests`, `AndroidADBTests`, and `AndroidPackageTests`.
  - The G2 check is in the nightly T3 run.
- [ ] The milestone review of [../roadmap.md](../roadmap.md) §4 is done.

## Task order

1. #008 Acquire and inventory ARM64 Cuttlefish artifacts.
2. In parallel: #009 AndroidImageManifest and #064 Reference boot capture. Both need only #008. #064 runs on a Linux reference host; since IR-305 it keeps the launcher captures as the reference and no longer blocks #010, #011, or #013.
3. #010 Extract Android kernel and ramdisk.
4. #011 GPT disks and partition mapping. It needs #005 from M0 and reads the #064 launcher captures (composite disk specs) and the VZ spike evidence for the blank partition sizes and the by-name list.
5. #012 Boot the Android kernel.
6. #013 Reach Android init.
7. #095 Cuttlefish host-service substitution.
8. #014 Reach system_server and boot_completed. This task closes G2.
9. In parallel: #015 ADB debugging over vsock (also needs #007 from M0) and #065 Runtime image bundle.
10. #016 Install HelloText APK.
11. #017 Launch HelloText APK.

Outside M1: once #014 is done, M2's #021 can start ([../roadmap.md](../roadmap.md) §1.4).

Conventions used by every task in this file:

- Dev commands. The `apkrun dev` commands of [../../02-design/cli.md](../../02-design/cli.md) §5 are run through the Debug CLI `apkrun-dev` ([../../05-development/build-system.md](../../05-development/build-system.md) §13). For example: `apkrun-dev dev boot`.
- Home directory. Debug builds use `APKRUN_HOME` = `~/Library/Application Support/APKRun-Dev/`, and logs go to `~/Library/Logs/APKRun-Dev/`.
- Where tests live.

  | Tier | Location |
  |---|---|
  | T0 Python | `Images/tools/tests/` |
  | T0 Swift | `Packages/<Module>/Tests/<Module>Tests/` |
  | T2 | `Tests/IntegrationTests/` |
  | T3 | `Tests/AcceptanceTests/` |

- Running T2 tests. T2 tests run with `xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -only-testing:IntegrationTests/<Suite>` inside the signed test host ([../../05-development/build-system.md](../../05-development/build-system.md) §12.4).
  - Android T2 suites skip with a message when `Images/work/16373615/` holds no bundle. With `APKRUN_CI=1`, a missing bundle fails the run.
  - Each suite uses a temporary `APKRUN_HOME` on the same APFS volume as the bundle.
- Reference build. Build ID `16373615` is the pinned M1–M4 build ([../../01-architecture/decisions/0003-cuttlefish-base-image.md](../../01-architecture/decisions/0003-cuttlefish-base-image.md)).

---

## #008 Acquire and inventory ARM64 Cuttlefish artifacts

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #001 |
| Requirements | FR-IMG-01 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §1.2, §2, §3.1; [../../03-reference/android-image-manifest.md](../../03-reference/android-image-manifest.md) §2–§4; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.1–§3.2 |
| Modules / paths | `Images/tools/pyproject.toml`, `Images/tools/apkrun_image/{__main__,fetch,inventory,sparse,lp}.py`, `Images/tools/vendor/`, `Images/tools/tests/`, `scripts/inventory-cuttlefish.py`, `Images/manifests/16373615/inventory.json`, `ThirdParty/ThirdParty.lock.json`, `.gitignore` |
| Risks / questions | R-10 |

### Goal

A developer fetches the pinned build 16373615. They get a committed, reproducible `inventory.json` that classifies every file by its content, not by its name.

### Scope

- The Python tooling skeleton: package, virtual environment, and command dispatch.
- `fetch` over the Android Build API v4, with resume, `fetch.json`, and the manual-download fallback.
- The content-based inventory of [../../02-design/android-image.md](../../02-design/android-image.md) §3.1, including sparse images and the liblp metadata inside `super`.
- Vendored `mkbootimg` and `avbtool`. They build the synthetic test images and are the cross-check for later tasks.
- Out of scope:
  - The manifest (#009) and extraction (#010).
  - `cvd-host_package.tar.gz`, which only the reference host needs (#064).
  - x86_64 targets.
  - Redistributing the prebuilt image (R-10).

### Deliverables

- `Images/tools/pyproject.toml`: Python 3.12, with pinned `lz4`, `cryptography`, `jsonschema`, and `pytest`.
- `Images/tools/apkrun_image/__main__.py` with the subcommands `fetch`, `inventory`, and `inspect`. Later tasks add their own subcommands.
- `fetch.py`, `inventory.py`, `sparse.py` (the streaming reader), and `lp.py` (the super metadata reader).
- `Images/tools/vendor/`: `mkbootimg.py`, `unpack_bootimg.py`, the imported GKI certificate helper, and `avbtool.py` at pinned AOSP commits, each listed with its file hash in `ThirdParty/ThirdParty.lock.json` (NFR-DEV-01).
- `Images/tools/tests/fixtures/build_fixtures.py` and the small synthetic images in `Images/tools/tests/fixtures/images/`.
- `scripts/inventory-cuttlefish.py`.
- `Images/manifests/16373615/inventory.json`.
- `Images/work/` added to `.gitignore`.

### Implementation steps

1. **Tooling skeleton.**
   - Create `Images/tools/pyproject.toml` and the `apkrun_image` package.
   - Add `__main__.py`, which dispatches subcommands.
   - Add `Images/work/` to `.gitignore`.
   - Set up with `python3 -m venv Images/tools/.venv && Images/tools/.venv/bin/pip install -e 'Images/tools[test]'`.
   - Check: `python3 -m apkrun_image --help` lists `fetch`, `inventory`, and `inspect`. `inspect` prints a content-based image summary and does not modify the input. The CI job `test-images` runs `pytest Images/tools/tests` and it passes ([../../05-development/build-system.md](../../05-development/build-system.md) §15).
2. **Vendored tools and synthetic fixtures.**
   - Copy `mkbootimg.py`, `unpack_bootimg.py`, the imported `gki/generate_gki_certificate.py` helper, and `avbtool.py` into `Images/tools/vendor/`, and pin them in the lock file as `kind: vendored` entries with the AOSP commit and the SHA-256 of each file. Add the vendored-file check to `scripts/tools/check-lock.swift`: a copied file whose hash differs from its entry fails ([../../05-development/build-system.md](../../05-development/build-system.md) §6.4).
   - `build_fixtures.py` uses them to write small synthetic images:
     - a boot image v4 and an init_boot image;
     - a vendor_boot v4 image with three ramdisk fragments (PLATFORM, RECOVERY, DLKM) and a bootconfig section;
     - a vbmeta with two chain descriptors;
     - a sparse ext4 image with all four chunk types;
     - a small super image with liblp metadata;
     - superblock stubs for erofs and f2fs;
     - `android-info.txt` and `fastboot-info.txt`;
     - one unknown file.
   - It also writes the fixture zip.
   - Check: two runs of `build_fixtures.py` give identical hashes. The hashes are committed in `Images/tools/tests/fixtures/images/SHA256SUMS`.
3. **`fetch.py`.**
   - Read the key from `APKRUN_ANDROID_BUILD_API_KEY`.
   - Resolve the `--artifact` glob with the v4 list endpoint, then fetch the signed URL from `…/artifacts/{name}/url` ([../../02-design/android-image.md](../../02-design/android-image.md) §2.2).
   - Download to `<name>.partial` with HTTP Range resume. Verify into a private, read-only staging file and atomically hard-link it to the final name; never expose partial bytes at the final path or overwrite an existing file.
   - Write `fetch.json` with name, size, and SHA-256.
   - A second run downloads nothing and re-verifies.
   - A file that was downloaded by hand, with no key set, is only verified.
   - With no key and no file, the tool exits 2 with a message that names [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.1.
   - Check: T1 against a fake API on `127.0.0.1`.
4. **`inventory.py`, `sparse.py`, `lp.py`.**
   - Read a zip (streamed) or a directory.
   - Classify each file by the magic numbers and offsets in the table of [../../02-design/android-image.md](../../02-design/android-image.md) §3.1. The liblp header is read at offset 4096 after a streamed unsparse. Nothing is written to disk.
   - Emit, per file: `path`, `size`, `sha256`, `kind`, `probablePurpose`, `details`, and `nameMismatch`. The format is [../../03-reference/android-image-manifest.md](../../03-reference/android-image-manifest.md) §4.
   - Unknown files are listed with kind `unknown` and are never dropped.
   - Output order is deterministic: sorted paths and sorted keys, and no timestamps ([../../03-reference/android-image-manifest.md](../../03-reference/android-image-manifest.md) §4.7).
   - Check: T0 classification tests pass for every kind.
5. **`scripts/inventory-cuttlefish.py`.**
   - A thin entry point that calls `apkrun_image.inventory.main`. It takes a zip or a directory, writes to `--out` or else to stdout, and has no logic of its own.
   - Check: `python3 scripts/inventory-cuttlefish.py Images/work/16373615/download/ --out Images/manifests/16373615/inventory.json` writes the file.
6. **Real build.**
   - Run the fetch command of [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.2, then step 5.
   - Review every `unknown` and `nameMismatch` entry, then commit `inventory.json`.
   - Run the commands of [environment-setup.md](../../05-development/environment-setup.md) §3.1–§3.2 exactly as written, and fix the document in the same pull request where they differ.
   - Check: a second run gives the same bytes (`cmp`). Record the file count and total size in the pull request.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0** (`Images/tools/tests/test_inventory.py`, `test_sparse.py`, `test_lp.py`):
  - Each kind of §3.1 is detected from the synthetic files.
  - A `boot.img` that is really a vendor boot image gets `nameMismatch: true`.
  - An unknown file is kept.
  - Every sparse chunk type (RAW `0xCAC1`, FILL `0xCAC2`, DONT_CARE `0xCAC3`, CRC32 `0xCAC4`) is parsed.
  - The liblp header is found after unsparse.
  - Two inventory runs over the fixture zip are byte-identical.
  - Oversized JSON integer tokens and deeply nested arrays in the editable `fetch.json` sidecar fail through both `fetch` and `inventory` CLIs with bounded diagnostics and no traceback.
- **T1** (`Images/tools/tests/test_fetch.py`, `test_inventory_real.py`):
  - A fake Build API on loopback: an interrupted download resumes, a second run downloads nothing, a hash mismatch is reported, and the manual-download path only verifies.
  - Artifact sizes above 16 GiB are rejected before transfer. Unsafe redirects, including HTTPS-to-HTTP downgrades, are rejected.
  - The inventory of the real archive equals the committed file. This test is skipped with a message when `Images/work/16373615/download/` is absent.
- **T3** (manual or nightly, needs the network and the key): `fetch` against the real Build API for build 16373615. It must match `fetch.json`.

### Acceptance criteria

- [x] How to obtain the artifact is documented: the API key, the fetch command, and the manual fallback, in [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.1–§3.2 and [../../02-design/android-image.md](../../02-design/android-image.md) §2.
- [x] `scripts/inventory-cuttlefish.py` outputs, for every file, its filename, size, SHA-256, and probable purpose. It also outputs `kind`, `details`, and `nameMismatch`.
- [x] The tools assume no fixed archive contents: files are classified by content, unknown files are listed, and a renamed file is detected.
- [x] Running the script on the selected build produces `Images/manifests/16373615/inventory.json`, which is committed. A second run is byte-identical.
- [x] `fetch` resumes, writes `fetch.json`, and downloads nothing on a second run.
- [x] The downloaded originals are never modified: they are opened read-only, and `fetch.json` hashes still match after the inventory.
- [x] The vendored tools are pinned in `ThirdParty/ThirdParty.lock.json`.

**Verification record (2026-09-30).** The Build API artifact is 1,101,175,103
bytes with SHA-256
`051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18`. The
inventory contains 12 files totaling 1,892,483,479 bytes; it has no unknown
files or name mismatches. A second inventory run is byte-identical.
The inventory validates vendor_boot v3 payload bounds for archive
classification; manifest and runtime support remain limited to v4 by gate M6.
Inventory schema v2 records the validated AVB footer size and version, plus
build metadata from the downloaded archive's adjacent `fetch.json` sidecar.
The EROFS block count is read from the documented superblock offset. ZIP64
record bounds, archive and directory size limits, the 64 MiB central-directory
and 1 MiB ZIP64-record caps, ZIP64 self-extracting prefix handling,
unsupported ZIP64 extensible-data rejection, bounded Build API metadata,
symlink-resistant directory reads, parent-directory fetch locking, and
replacement-safe partial cleanup are covered by regression tests.

**Final verification (2026-09-30).** `pytest Images/tools/tests -q` passed all
121 tests, including fake-API T1, bounded-size and redirect cases, and the real
archive inventory check. The rerun of `scripts/ci/run-checks.sh`, Ruff lint and
format checks, and `git diff --check` passed. Regenerating the inventory from
`Images/work/16373615/download/` produced bytes identical to the committed
`inventory.json`.

### Notes

- The API key is never committed, printed, or logged ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.1).
- The prebuilt image is for development only, M1–M4 ([../../02-design/android-image.md](../../02-design/android-image.md) §2.3, R-10).
- `super.img` may be sparse. Its liblp metadata must be found after unsparse, never by file name.
- **Additional parser-limit verification (2026-10-06; see IR-232):** `test_fetch.py` and `test_inventory.py` passed 86 tests, including bounded CLI failures for oversized integer and deeply nested JSON tokens in `fetch.json`; real-archive inventory also succeeded. The full image-tools suite passed 594 tests with four platform skips after both CLI fixes. Ruff lint and formatting checks passed.

---

## #064 Reference boot capture

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #008 |
| Requirements | None named in requirements.md. Provides the ground truth for FR-VM-08 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §7.7, §8; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.3; [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Modules / paths | `Images/tools/reference/{capture.sh,capture_guest_command.py,capture_cvd_start.py,check_virgl_crosvm.py,collect_composite_specs.py,boot_observer.py,boot_signals.py,compare_boot.py,elf_identity.py,normalize.yaml,guest-capture.txt}`, `Images/reference/16373615/{default,target,swiftshader}/`, `Images/reference/16373615/expected-differences.yaml`, `Images/reference/16373615/boot-signals.json`, `Images/tools/tests/{test_boot_observer.py,test_boot_signals.py,test_capture_guest_command.py,test_capture_cvd_start.py,test_collect_composite_specs.py,test_compare_boot.py,test_elf_identity.py,test_reference_capture.py}` |
| Risks / questions | R-06, R-11 |

### Goal

A committed, normalized record of how real Cuttlefish boots build 16373615 in three profiles. It comes with a comparison tool that diffs any later capture against that record.

### Scope

- Setting up the reference host.
- `capture.sh` for the profiles `default`, `target`, and `swiftshader`, collecting every host-side and guest-side item of [../../02-design/android-image.md](../../02-design/android-image.md) §8.3.
- Normalization with `normalize.yaml`. The committed captures contain no secrets.
- `compare_boot.py` with the ten report categories of §8.4, and the format of `expected-differences.yaml`.
- Recording the exact boot marker strings and their timing.
- Out of scope:
  - The VZ-side capture and the G2 diff (#014).
  - Fixing any difference (#011–#014, #095).
  - Running Cuttlefish on macOS.

### Deliverables

- `Images/tools/reference/guest-capture.txt`: one entry per guest-side item, as an output file name and a shell command. Both channels execute it: `adb shell` here, and the serial shell in #014.
- `Images/tools/reference/capture.sh`, `capture_cvd_start.py`, optional `boot_observer.py`, `compare_boot.py`, and `normalize.yaml`.
- `Images/reference/16373615/<profile>/` for the three profiles, each with a `host.json` that records the host kind, OS, kernel, CVD package version and instance number, CPU count, nested virtualization, selected GPU mode, vhost-user GPU state, EGL platform, path-free SHA-256/ELF Build ID identities for the configured crosvm command, expected executable, and adjacent gfxstream candidate, plus Virgl preflight status. `crosvm-runtime-identity.txt` records whether each matching running crosvm process used the preflighted ELF; these process identities are verified from `/proc/<pid>/exe`.
- `Images/reference/16373615/expected-differences.yaml`. Initially it contains a header comment and an empty array.
- Verified strings in [../../02-design/android-image.md](../../02-design/android-image.md) §7.7 and [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3.

### Implementation steps

1. **Reference host.**
   - Set it up as in [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.3. Preferred is a nested-virtualization arm64 Linux VM on an M3 or later Mac. The fallbacks are an arm64 Linux machine, then x86_64 with QEMU TCG (§8.1).
   - Check: `launch_cvd --cpus 4 --memory_mb 4096` boots, and `adb shell getprop sys.boot_completed` prints `1` on the reference host.
2. **Guest-side command list.**
   - Write `guest-capture.txt` with the right-hand column of §8.3:
     - `/proc/cmdline`, `/proc/bootconfig`, `getprop`, `ls -l /dev/block/by-name/`, `readlink -f /sys/block/vd*`;
     - partition sizes from sysfs, `/proc/mounts`, `/vendor/etc/fstab.*`, `dmesg`, `lsmod`;
     - the hvc holders from `/proc/*/fd`;
     - `logcat -d -b all` (gzip), `lshal`, `service list`, `ls /apex`, `pm list features`;
     - `ip addr`, `ip route`, `ip link`, the `dumpsys connectivity` summary;
     - `/proc/asound/cards`, `getenforce`, AVC denials, and the `VIRTUAL_DEVICE_*` lines with timestamps.
   - Commands that need root are prefixed with `su 0`. This works on userdebug over both `adb shell` and the serial console.
   - Use plain `sh` syntax and Android's built-in diagnostic commands, so the same list runs over `adb exec-out` and the serial shell in #014.
   - Check: every §8.3 guest item has exactly one tab-separated entry; T0 checks every command with `sh -n`.
3. **`capture.sh <profile>`.**
   - Use the pinned host package's `cvd create --nostart` with the host and product paths, private base directory, unique group name, instance number, and profile flags of §8.2. For `target` with `drm_virgl`, set `EGL_PLATFORM=surfaceless` for both CVD commands and record `eglPlatform` in `host.json`; clear inherited `EGL_PLATFORM` for every other profile and GPU-mode combination, recording null. Run creation and named-group start through `capture_cvd_start.py` under the shared boot deadline; pass `--gpu_vhost_user_mode=off` to both commands for every profile and pass the requested GPU mode to both commands for `target` and `swiftshader`. Before regular ADB boot polling, verify that the selected instance's actual `gpu_mode` in `cuttlefish_config.json` matches the requested mode where one is specified and that `enable_gpu_vhost_user` is `false`, rejecting duplicate JSON keys. Record the selected GPU mode and vhost-user GPU state in `host.json`. If either live check fails, retain an incomplete diagnostic capture and skip regular ADB polling and guest capture. Before publication, revalidate both settings in the staged config; if it is missing, invalid, or different, retain any ADB data already collected but mark the capture incomplete and non-comparable. Observer data never makes an incomplete capture valid for GPU-profile comparison. Poll and atomically snapshot the three host logs, capped at 64 MiB each. Connect ADB on the instance's loopback port and wait for `sys.boot_completed=1`.
   - For long-start diagnosis only, `APKRUN_CAPTURE_BOOT_OBSERVER=1` records launcher-identified Android crosvm memory and private-socket ADB state during `cvd start`, including the bounded numeric count and nullable non-empty presence of `sys.system_server.start_count`, the nullable non-empty presence and parsed Boolean signal of `sys.boot_completed`, both bounded getprop exit statuses, the bounded property-response byte count, and whether any expected response field parsed. It never stores raw property output. Once per uniquely verified crosvm process generation, it also hashes `/proc/<pid>/exe` and records a path-free identity event with PID, status, SHA-256, and GNU Build ID; it checks the child and parent restarter start times and executable identity before and after hashing. Ambiguous candidates are not hashed. On the first poll where `get-state` reports `device`, the observer runs a standalone bounded shell-marker command instead of that poll's property query; it resumes property queries on the next scheduled poll. Leave this observer disabled for ordinary captures.
   - The optional observer also summarizes four fixed `adb_connector` message counts from complete launcher-log lines, including when event 5 is absent. This summary stores no connector PID, device serial, address, or raw line. It does not establish ADB readiness. The private ADB observer starts on the first complete, source-qualified `adb_connector` connection-attempt line or event 5, whichever comes first. Before event 5 it polls every 60 seconds; event 5 wakes the same thread for an immediate poll outside the reserved final-probe window, and later regular polls use the normal 15-second interval. During that final window, regular shell and property polls stay paused while the observer preserves its bounded final state and logcat probe. It uses only the instance's loopback serial and private ADB socket, and runs shell diagnostics only after `get-state=device`.
   - Collect the host side: the crosvm command line, `internal/bootconfig` with the AVB footer stripped, the composite disk specs, `cuttlefish_config.json`, `assemble_cvd.log`, `kernel.log`, `launcher.log`, and the bounded Cuttlefish host `logcat` as `host-logcat.txt`. Poll and snapshot the first three live host logs only; copy logcat once after the CVD command returns. Normalize the host logcat before retaining it so crash summaries remain available when guest ADB is unresponsive.
  - For `target`/`drm_virgl`, identify the expected crosvm ELF separately from its launch command, reject the known IR-171 Build ID, hash the expected ELF before both CVD commands, and check each matching running crosvm process's `/proc/<pid>/exe` against that hash. A wrapper is allowed when `APKRUN_CROSVM_OBSERVER_EXECUTABLE` identifies its executed crosvm ELF; direct overrides default this setting to `APKRUN_CROSVM_BINARY`. Unknown builds may run for diagnosis but are marked uncertified and the capture remains incomplete. Record the preflight result in `host.json` and process results in `crosvm-runtime-identity.txt`.
  - Record SHA-256 and ELF Build ID for the configured crosvm command and expected executable, plus the adjacent gfxstream candidate, in `host.json` without absolute paths. If a SHA-256 is unavailable, add `host-tool-identities` to `MISSING.txt` and keep the capture incomplete. The gfxstream entry is a candidate, not proof of the library mapped by the dynamic loader.
  - Run every `guest-capture.txt` command through `capture_guest_command.py` with the remaining shared boot deadline. Cap aggregate raw guest output at 64 MiB and the compressed logcat artifact at 64 MiB; if a command times out or exceeds its remaining output budget, record it in `MISSING.txt` and keep the capture incomplete. Read `internal/bootconfig` only after confirming it is a regular file no larger than 64 MiB.
  - Disconnect the selected ADB serial with a bounded timeout, remove only this group with a bounded timeout, and remove the private Cuttlefish HOME before profile publication. If HOME cleanup fails, retain the capture as incomplete and report the retained path.
   - Run `compare_boot.py normalize <dir>`, which applies `normalize.yaml` to serial numbers, MAC addresses, host paths, and key-shaped secrets. Publish only a fully normalized capture under `Images/reference/16373615/<profile>/`; retain incomplete normalized captures under `Images/reference/16373615/incomplete/`.
   - Check: every §8.3 item is present in the directory, or a `MISSING.txt` there gives the reason. A search for the device serial, MAC addresses, and `/home/` finds nothing.
4. **Capture the three profiles.**
   - Capture `default`, `target`, and `swiftshader`.
   - If `drm_virgl` does not run on the reference host, explicitly set `APKRUN_TARGET_GPU_MODE=guest_swiftshader`, provide the matching Cuttlefish revision and source-derived `drm_virgl` properties from `CrosvmManager::ConfigureGraphics()` in `crosvm_manager.cpp`, and write them into `target/graphics-props-from-source.txt` (§8.2).
   - Check: the three directories are committed together with their `host.json`.
5. **`compare_boot.py <reference dir> <vz capture dir>`.**
   - Normalize both sides in memory and compare them in the categories cmdline, bootconfig, props, block devices, mounts, modules, HALs, hvc users, network, and SELinux. A category with no captured input is an unexplained difference.
   - Read `Images/reference/<buildId>/expected-differences.yaml`, a list of `{category, key, reason, design}` entries where `design` is a link to the section that explains the difference.
   - Write `report.json` and a text report.
   - Exit 1 on any unexplained difference. Warn about entries that no longer match a difference.
   - Check: T0 passes.
6. **Record the findings.**
   - The exact `VIRTUAL_DEVICE_*` strings and their timing go into [android-image.md](../../02-design/android-image.md) §7.7.
   - The boot-phase strings `Booting Linux on physical CPU`, `init: init first stage started!`, `init: starting service 'zygote'`, and `VIRTUAL_DEVICE_BOOT_COMPLETED` go into [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3, each confirmed or replaced, with median timings.
   - The `androidboot.*` keys that U-Boot and the launcher add (from `/proc/bootconfig` compared with `internal/bootconfig`) go into the source column of [android-image.md](../../02-design/android-image.md) §6.2.
   - The values for later tasks are noted in the pull request:
     - `ro.adb.secure` and `persist.adb.tcp.port`, for #015;
     - the by-name list, the partition sizes, and the fstab, for #011 and #013;
     - the hvc holders, for #095.
   - Check: the design-doc pull request marks each candidate "confirmed" or "changed".

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0** (`Images/tools/tests/test_capture_cvd_start.py`, `test_compare_boot.py`, and `test_reference_capture.py`), over synthetic capture pairs and fake Linux host tools:
  - Identical captures exit 0.
  - One unexplained difference per category exits 1 and names the category and the key.
  - An explained difference exits 0.
  - A stale entry produces a warning.
  - Normalization removes serials, MACs, host paths, and key-shaped secrets; it handles host roots attached to one-letter options, quoted or escaped paths, and ambiguous space-containing paths while preserving JSON structure. Comparison normalizes without modifying either capture.
  - ELF identity tests cover 32- and 64-bit files, byte order, GNU Build ID notes, malformed and absent notes, non-ELF files, missing paths, and non-regular inputs; capture integration checks verify that host JSON records hashes without exposing paths.
  - The capture script's exact known-incompatible Virgl crosvm Build ID preflight (for both an identified launch ELF and the expected crosvm ELF, before ADB or CVD launch), distinct wrapper/child identities, prelaunch hash rechecks, running `/proc/<pid>/exe` verification, loopback ADB connection, GPU mode and vhost-user settings on both CVD commands, selected-config validation and cleanup, host-wide capture lock, private Cuttlefish HOME cleanup, instance-scoped host collection, all three profile flags, AVB footer stripping, and missing-item reporting are exercised without Cuttlefish. Composite-spec collection also covers selected-instance path boundaries, root and descendant symlink races, matching-config symlink and non-regular-file rejection, file-descriptor leaks, inventory and content limits, atomic-write cleanup, host-path normalization, and overriding a custom `TMPDIR` with the resolved, normalizer-supported physical `/tmp` root.
  - Fake ADB commands that hang, exceed the output budget, close stdout while continuing, or leave descendants verify deadline enforcement, streaming caps, process-group cleanup, and incomplete-capture behavior. An oversized `internal/bootconfig` is rejected without an unbounded read; injected process-group and private-HOME cleanup failures cannot publish a canonical profile or leave hidden partial guest output.
  - Every profile starts the uniquely named group with the matching host package, a writable private copy of verified product output, and a private Cuttlefish base directory.
  - Product output with an absolute symbolic link is rejected, and any change to a manifest-pinned image during the copy is detected by the post-copy size and SHA-256 check before `cvd create`.
  - The archive's name, size, and SHA-256 are checked against `fetch.json`; branch, build ID, and target metadata are compared across the sidecar, inventory, and manifest. Missing sidecar metadata and inconsistent manifest or inventory edits fail closed. The sidecar is unsigned local metadata, so these checks do not prove that `fetch` created it or authenticate its asserted build fields. Manifest or inventory-derived diagnostics escape controls and bidi formatting characters.
  - Normal and interrupted capture disconnect the selected ADB serial with a bounded timeout before removing the group; cleanup continues if ADB hangs.
  - Startup snapshots `assemble_cvd.log`, `kernel.log`, and `launcher.log` while both CVD create and start are running; an integration fixture delays the first listing, then deletes create-time logs before the next poll under the old post-return schedule. A helper test deletes a listed log while `cvd logs` is still running and verifies the streamed path was snapshotted before the listing exits; duplicate listing rows trigger only one copy. Host logcat is excluded from live polling and copied once after the CVD command returns. Interruption tests create a nested unnormalized logcat temporary before signaling the capture and verify recursive cleanup removes it. Another test times out the listing after source deletion and checks that the valid snapshot remains. CVD child exit statuses 124 and 137 are distinguished from actual deadline expiry. Timed-out start deletion is covered too. FIFO sources do not block, paths with spaces parse, malformed log listings cannot skip process termination, incomplete snapshots do not replace complete copies, rejected final copies keep the last snapshot, and capture/comparison paths enforce 64 MiB log limits.
  - The optional boot observer resolves the private HOME's `cuttlefish_runtime` link during `cvd start`, validates the current UID, Cuttlefish-managed path, canonical private-HOME destination, and ADB instance number, then follows the Android restarter's direct child. It rejects redirected `home` or `instances` links and checks the child's PPID and both procfs start times. It preserves the supplied crosvm command basename, including for a symlink override, when matching the restarter's request under the private instance. By default, `/proc/<pid>/exe` must identify the staged command's target; a diagnostic launcher may provide its resulting executable path explicitly. The child's `argv[0]` must equal a known staged, supplied, or resolved command/executable path, and `/proc/<pid>/exe` must match the expected executable with `samefile`. It fails closed on mismatches. Tests reject a reused child PID and a different executable with the same basename. It clears identities after a capped launcher log and records no raw ADB output. Its background sampler and monotonic private-socket ADB schedule avoid drift from log collection and command duration, honor the cleanup reserve, and remove an ADB server that ignores SIGTERM. It also writes one bounded `cuttlefish_adb_connector_summary` with four fixed message counts and explicit launcher-log observation status; tests cover source qualification, count classification, log-gap reporting, and identifier privacy. These passive counts are Cuttlefish log evidence, not ADB readiness. The private ADB server and active polling start on the first complete, source-qualified `adb_connector` connection-attempt line or event 5. Pre-event polls use a 60-second interval; event 5 wakes the same thread for an immediate poll outside the reserved final-probe window before it switches to the 15-second interval. Regular polls remain paused within that final window so the observer can check fresh ADB state and run bounded `events` and `main`/`system`/`crash` logcat queries; it runs no shell or property probe there. All four final-probe ADB clients use private process groups and bounded output. Tests cover both startup triggers, the interval transition, wakeup races, final-window scheduling, no duplicate thread, and the private ADB socket. The regular `connect`, `get-state`, and property-poll clients use the same runner with a 4 KiB cap, record per-stage cleanup, truncation, and probe-error status, and stop polling after unverified child cleanup. The `adb_logcat_summary` record keeps process-event counts from the events buffer separate from Android diagnostic-marker counts from the other buffers; mentions do not identify a process targeted by an event or establish causation. Shutdown waits through the 40.5-second final-probe reservation. Tests cover buffer provenance, output limits, timeouts, descendant process-group cleanup, close-time waiting, deadline scheduling, payload privacy, offline behavior, and fail-closed cleanup.
  - On the first poll where ADB reports `device`, the observer runs a bounded `adb shell` probe instead of that poll's property query. After a fixed marker, it checks `service check activity`, `service list`, and `pidof system_server`; it emits only fixed result classifications and never persists service output or a PID. It validates service-list headers, row numbering, row shape, non-empty descriptors, and declared count; empty or malformed listings are `unknown`. The strict parser accepts complete ordered allowlisted lines and can preserve complete fields only before a timeout. The probe uses the existing ten-second timeout and output cap, and property queries resume on the next scheduled poll. The one-shot is retried only if its process could not be launched. Tests cover shell syntax, positive and negative classifications, malformed and empty listings, strict parsing, LF and CRLF framing, partial timeout output, PID and raw-output privacy, one-shot behavior, and fail-closed child cleanup without increasing the polling or final-logcat deadline reserves.
  - When `APKRUN_CROSVM_BINARY` selects a diagnostic command, the observer checks the restarter-requested command under the private instance while preserving its supplied basename. `APKRUN_CROSVM_OBSERVER_EXECUTABLE` optionally identifies the resulting child executable when a launcher executes a different file; otherwise the observer checks the staged crosvm executable. Capture tests cover the default, distinct-wrapper/executable, symlinked command, and invalid-relative-path cases. Runtime ELF identity tests verify one hash per process generation, a fresh record after restart, rejection of ambiguous candidates and process changes during hashing, unavailable results, and path-free output.
  - With the optional boot observer enabled, bounded incremental reads of the atomically replaced `kernel.log` detect a `system_server` D-state trace through `do_mprotect_pkey`. The observer records guest uptime and wakes its private ADB poller; a device-state response permits one bounded `su 0` read of every current SystemServer task's state, wait channel, and kernel stack. Tests cover growing log snapshots, trigger qualification, valid and timed-out thread probes, parser limits, shell syntax, and removal of PIDs, TIDs, thread names, addresses, and raw output.
  - The shutdown helper kills remaining process-group members after its TERM grace even when the command leader exits; a fixture verifies that a grandchild ignoring TERM is also terminated.
  - An interrupted capture is normalized into `incomplete/` or discarded if normalization fails; raw logcat or composite-spec temporary data that cannot be removed prevents publication and triggers staging-tree deletion, and a failed launch still attempts bounded group-scoped cleanup.
  - Diagnostic Cuttlefish command-line capture trims right-aligned PIDs, verifies `/proc/<pid>/exe` resolves to `crosvm`, and matches the selected instance path using delimiters in `ps`-rendered text. This is a best-effort text heuristic, not proof of NUL-delimited argument boundaries; scanner text and similarly named helpers are excluded, and a missing process is recorded in `MISSING.txt`.
  - A Linux-only integration case runs the real GNU `timeout` against group removal that ignores TERM; it is skipped on macOS.
  - Compound quoted secrets and complete PEM private-key blocks are redacted; private-key marker scanning is linear; substitution growth is checked before allocation; plain/compressed input, rules files, normalized output, and capture-tree traversal are bounded; comparison indexes category files once, streams newline-dense category files, and caps each capture at 100,000 records or 64 MiB of key/value text across all categories; report symlinks cannot overwrite their targets.
  - Every guest command and `capture.sh` pass `sh -n`; the Linux-only guard is checked on macOS.
- **T3** (manual, on the reference host): the capture itself, with `host.json` attached to the pull request. It is repeated whenever the pinned build changes.

### Acceptance criteria

Re-scoped on 2026-10-08 (IR-305). The criteria marked *deferred* need a complete crosvm boot, which needs a non-nested arm64 Linux host (§8.1); the project has none, and they no longer block #010, #011, #013, or G2.

- [ ] *Deferred.* The `default`, `target`, and `swiftshader` profiles are captured and committed with every item of §8.3, or with a recorded reason for each missing item.
- [ ] The captures are normalized and contain no serial numbers, MAC addresses, host paths, or keys. This applies to the retained launcher captures under `incomplete/` now, and to any later complete capture.
- [x] `compare_boot.py` reports by the ten categories, fails on unexplained differences, and passes its T0 tests.
- [ ] `guest-capture.txt` runs unchanged over `adb shell` and over a plain `sh` console. (2026-10-08: it ran unchanged over `adb exec-out` against the VZ boot; the serial-shell run is part of #014 step 5.)
- [x] The exact `VIRTUAL_DEVICE_*` strings and their timing are in [android-image.md](../../02-design/android-image.md) §7.7. The boot signals in [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3 are confirmed or corrected. (Observed on the VZ direct boot, IR-306.)
- [ ] *Deferred.* Each profile has a schema-version-3 `host.json` with path-free host-tool identities.

### Notes

- **Re-scope (2026-10-08; IR-305).** The nested-virtualization reference host never produced a complete boot: across 62 records the guest ran about 100 times slower than the same image on VZ, and `system_server` was killed by its Watchdog during startup. The VZ direct-boot spike (`Experiments/vz-android-boot/`, IR-306) booted the same image to `VIRTUAL_DEVICE_BOOT_COMPLETED` in 7.5 s. QEMU with HVF on macOS was considered as another reference host and rejected: the Cuttlefish host tools do not run on macOS, so it would need the same hand-built boot as VZ, and macOS QEMU has no vsock. What #064 keeps: the launcher captures under `Images/reference/16373615/incomplete/` (bootconfig, command line, composite disk specs, `cuttlefish_config.json`, kernel log up to `system_server`), `compare_boot.py`, and the boot markers observed on VZ. A complete capture remains possible on an arm64 Linux machine (option 1 of §8.1) and would then complete the deferred criteria.
- A TCG capture takes hours. Record its duration in `host.json` so that timing comparisons skip it.
- #012 copies each profile's normalized `kernel.log` into the BootSignals golden fixtures.
- **Reference-host verification (2026-09-30).** The nested-virtualization Ubuntu 24.04 arm64 VM has Cuttlefish 1.57.0 (VCS `9bb9c723`) and `adb`. The Lima project mount is read-only, so the capture script and manifest were copied to the VM's writable home; product images passed the pinned manifest's size and SHA-256 checks. Cuttlefish logged `Logical partition metadata has invalid geometry magic signature` twice, but continued through `simg2img` and Android service startup. Inspection of the converted `super.img` found the expected little-endian geometry magic at offset 4096. The guest became visible to ADB but stayed in Cuttlefish `Starting`; after 1,029 seconds, `cvd start` reported `VIRTUAL_DEVICE_BOOT_FAILED`, `run_cvd returned 10`, and exit status 255. No `sys.boot_completed=1` was observed. The evidence does not establish whether the geometry warning contributed to the later boot failure.
- **Incomplete capture.** The normalized record is committed under `Images/reference/16373615/incomplete/default-20260930T184542Z-7609/`. Cuttlefish removed its instance runtime after the failed start, before the capture script could copy `kernel.log`, `launcher.log`, or guest data. `MISSING.txt` records those unavailable items. Do not treat this as a reference profile. The record directory uses the equivalent UTC instant of the VM's Asia/Tokyo timestamp.
- **Bounded capture retry.** A later 30-second run is recorded under `Images/reference/16373615/incomplete/default-20260930T190436Z-10435/`. It ended after 32 seconds with a `MISSING.txt` entry naming the Cuttlefish startup deadline. `cvd fleet` showed no remaining groups and the capture lock had been removed. The Cuttlefish console also printed `timeout: the monitored command dumped core` while the command was being stopped; this did not prevent cleanup. The record is diagnostic only and is not a reference profile.
- **Diagnostic hardening verification (2026-10-01).** The isolated GPU-none runner now pins its baseline commit, derives experiment source provenance from committed Git objects, validates the exact private runtime copies, snapshots the capture script into a sealed memory file, and bounds both bootstrap and guest execution. It retains incomplete state when cleanup cannot be verified and leaves shared Cuttlefish state untouched. The diagnosis suite passed on macOS (107 passed, 39 skipped) and the Linux reference VM (146 passed); final hostile review reported no remaining findings. These host-side checks do not change the earlier `VIRTUAL_DEVICE_BOOT_FAILED` result or complete the reference capture acceptance criteria.
- **600-second live diagnosis.** The run recorded under `Images/reference/16373615/incomplete/default-20260930T201303Z-17984/` lasted 602 seconds and ended when the configured startup deadline sent a termination signal; it did not report the same natural `VIRTUAL_DEVICE_BOOT_FAILED` result as the earlier 1,029-second run. While the group was alive, live `cvd logs` showed Android init progressing through service-manager and HAL startup. `/metadata` initially had an invalid ext4 superblock and an early `aconfigd` write failed, but libfs_mgr later mounted `/metadata` and `system_aconfigd_platform_init` exited successfully. This does not establish that the transient errors caused the boot failure. The Cuttlefish ADB connector intermittently reported a connection to `127.0.0.1:6520`, followed by `device ... not found`; no usable ADB device or `sys.boot_completed=1` was observed. Host graphics checks also reported no GLES or accelerated ARM64 mode, but the selected guest graphics path and any effect on boot remain unknown. Cuttlefish removed its live instance logs during timeout cleanup, so the normalized record correctly lists them as missing. Do not treat these observations as a successful boot or a proven root cause.
- **120-second log-retention retry (2026-10-01).** The normalized incomplete capture at `Images/reference/16373615/incomplete/default-20261001T001530Z-48053/` was captured on Ubuntu 24.04.4 arm64 with Cuttlefish 1.57.0 and nested virtualization enabled. The product images again passed the pinned manifest checks. The shared deadline terminated startup after 120 seconds; cleanup removed the CVD group, left no ADB devices, and released the capture lock. Live snapshots retained `kernel.log` and `launcher.log`: the kernel log reached `Starting kernel ...`, while the launcher log showed unstable ADB and vsock connections. No `sys.boot_completed=1` was observed. `assemble_cvd.log` was not available in the selected instance runtime at final collection, and no crosvm process remained to capture. This is diagnostic evidence only, not a successful boot or a root-cause finding.
- **Composite disk-spec capture gap (2026-10-01).** The pinned Cuttlefish 1.57.0 `cuttlefish_config.json` in the same record has a top-level `instances` object and no `disks` object. The collector therefore recorded `composite-disk-specs.json` as missing. IR-151 supersedes that missing-item rule after identifying the dedicated instance config files; the prohibition on inferring topology from unrelated image paths remains.
- **Host-path normalization correction (2026-10-01).** The real `launcher.log` used short options attached directly to `/var/tmp/...` and `/tmp/...` paths (`-o/path` and `-u/path`). Normalization now redacts option-attached paths under the configured host roots while preserving the option prefix. Quoted JSON paths remain valid JSON, and escaped quotes inside a quoted plain-text path no longer expose its suffix. A linear token scan handles unquoted, space-containing paths attached to a short option only in Cuttlefish `command.cc` `Started (pid: …):` records; it redacts the ambiguous command suffix when any continuation follows, including dash-prefixed components and final components without `/`. A short-option token (`-v`, `-vv`, or `-v=1`) or `--` immediately followed by a recognized diagnostic phrase preserves it only with known connector words and configured host paths; arbitrary suffix tokens are redacted. This avoids a backtracking regular expression and does not materialize a list of every log line. The incomplete record was normalized again. A scan found no `/var/tmp/cvd`, `/tmp/cf_env`, `/home/lima`, `/Users/...`, or MAC-address matches.
- **Capture bounds and private-key scan (2026-10-01).** Rules and expected-difference inputs must be regular files opened without blocking and are read with a 1 MiB cap; normalization and comparison reject capture trees above 100,000 filesystem entries, and comparison indexes relevant files once. Repeated Cuttlefish log listing rows can trigger only one snapshot attempt per log name per poll, after a regular in-home path is validated so a bad row cannot suppress a later valid one. Complete PEM private-key blocks are found with a linear marker scan instead of a repeated lazy regular-expression search. Quoted-path matching uses disjoint escape alternatives, keeping malformed long inputs linear. T0 covers each boundary and failure mode.
- **Command-line capture correction.** The first three incomplete records contained the `awk` scanner's own command line as `crosvm-command-line.txt`: its source included both the word `crosvm` and the selected instance path. Those false captures were removed and `MISSING.txt` now says that no verified Cuttlefish crosvm command line was captured. The collector trims procps's right-aligned PIDs, verifies the `/proc/<pid>/exe` target, and applies a best-effort delimiter check to the selected instance path in `ps`-rendered text. Since commas and colons can occur inside an argument, this is not proof of NUL-delimited argument boundaries and remains diagnostic data only. T0 covers padded PIDs, scanner and similarly named helper decoys, and paths embedded in ordinary surrounding text.
- **Capture timeout fix.** One configurable deadline (600 seconds by default) now covers `cvd create`, named-group `cvd start`, ADB connection and discovery, `sys.boot_completed`, `wait-for-device`, and retry sleeps. The host-wide ADB preflight has a separate ten-second limit. GNU `timeout` gets a two-second TERM grace before KILL for boot-phase commands. If Android is not ready or `wait-for-device` fails, guest-log collection is skipped so the script can disconnect ADB, remove the group, and release its lock. Tests cover the shared default deadline, bounded polling, preflight timeout, guest-collection skip, and real GNU `timeout` termination of unresponsive CVD and ADB commands on Linux.
- **Local checks (2026-09-30).** The Python image-tools suite passed 305 tests; its three Linux-only GNU `timeout` integration cases were skipped on macOS. The full `scripts/ci/run-checks.sh` suite passed all six checks. On the Ubuntu 24.04 arm64 VM, the focused reference-capture run passed nine cases, including real GNU `timeout` termination of stuck CVD start, ADB boot-marker retrieval, and CVD group removal. The bounded polling-sleep regression case also passed independently on both macOS and the VM.
- **Local checks (2026-10-01).** Two adversarial-review rounds identified nine actionable findings; all were fixed, and the final review found none. The reference-capture, CVD-start helper, and boot-comparison suites passed 85 tests; three GNU `timeout` integration cases were skipped because the local host is macOS. Ruff lint and format checks passed. The full `scripts/ci/run-checks.sh` suite passed all six checks. The incomplete reference record normalized with zero files changed, and scans found no tested Lima/temporary host paths or MAC addresses.
- **Adversarial review (2026-09-30).** Previous reviews found and fixed cross-checkout lock ownership, interruption cleanup, raw logcat publication, shutdown timeout, documentation mismatches, and the manifest pattern end-anchor issue. The timeout review found an unbounded ADB preflight, guest collection after readiness failure, and gaps in shared-deadline and real process-termination coverage; all were addressed. Final hostile review of the bounded deadline, cleanup, and polling-sleep changes reported no findings.
- **600-second default retry and log-label fix (2026-10-01).** The normalized record at `Images/reference/16373615/incomplete/default-20261001T120904-49816/` lasted 603 seconds. The separate launch probe in `Images/reference/16373615/incomplete/default-20261001T120904-49816/host-tool-probe.txt` confirms that Cuttlefish 1.57.0 emits `cvd logs --nopretty` labels as `<group>:<instance>:<log-name>`, which the original live collector silently ignored. Bounded snapshots preserved the logs during this run; IR-085 updates both listing parsing paths to accept the observed prefix, while still restricting snapshots to known log names and regular files beneath the private CVD home. The focused capture-helper tests passed 15 cases; the reference-capture, helper, and comparison suites passed 85 tests, with three Linux-only GNU `timeout` integration cases skipped on macOS. Ruff lint and format checks passed, and adversarial review found no actionable issue. Adding EUI-64 redaction changed two files (`cuttlefish_config.json` and `launcher.log`); a second normalization pass changed zero files. Scans found no configured private host paths, MAC addresses, EUI-64-style IPv6 address patterns, or PEM private-key markers. The kernel log shows Linux 6.12.74 booting, Android init starting zygote at guest time 76.4 seconds, SurfaceFlinger and boot animation starting, and repeated `activity` service lookup failures from guest uptime 370.8 seconds; it contains no confirmed `system_server` start or boot-complete marker. The launcher log records an ADB transport in `device offline` state at 12:05:29; the capture deadline occurred at 12:09:02. The reset logged about 23 seconds after launch is from the auxiliary OpenWrt VM (`process_name=openwrt`, PID 50263), not the Android guest; the Android crosvm has a separate PID, 50271. This corrects the earlier ambiguous reset attribution under IR-089. Cuttlefish selected `guest_swiftshader` after reporting host EGL/GLES capability failures, so those checks do not establish the boot failure's cause. This remains diagnostic evidence, not a successful profile.
- **Full repository checks (2026-10-01).** After the Cuttlefish log-label, EUI-64 normalization, and test timing updates, `scripts/ci/run-checks.sh` passed all six checks.
- **Lima host-tool setup and launch probe (2026-10-01).** The `apkrun-cuttlefish` VM's login profile exports `CVD_HOST_DIR`, `ANDROID_HOST_OUT`, and `ANDROID_PRODUCT_OUT` for the extracted Cuttlefish 1.57.0 host package, and prepends its `bin/` directory to `PATH` once. A fresh login resolves `launch_cvd` and the package's `adb` (36.0.0-cuttlefish_common). The separate sanitized 45-second launch probe is preserved in `Images/reference/16373615/incomplete/default-20261001T120904-49816/host-tool-probe.txt`: it records a `Starting` Cuttlefish group, two `crosvm` processes, zero ADB devices, and timeout exit status 124. `cvd remove` left the fleet empty and no `crosvm` processes; the isolated probe HOME was also removed. This verifies host command availability and launch invocation only, not a successful Android boot.
- **EUI-64 normalization and final image-tools verification (2026-10-01).** The normalized capture originally retained a link-local IPv6 address encoding the virtual NIC's MAC. Normalization now replaces EUI-64-style interface identifiers in both capture normalization and comparison, while preserving ordinary IPv6 addresses. The sanitized capture now records `<EUI64_STYLE_IPV6>` in `cuttlefish_config.json` and `launcher.log`; a second normalization pass changed zero files, and the privacy scan found no raw MAC, EUI-64-style IPv6 address, private probe path, or PEM private-key marker. Tests cover compressed, expanded, and IPv4-embedded forms, a manually configured EUI-64-style address, and non-EUI-64 addresses that contain `ff:fe` outside the interface-identifier marker. The first full image-suite run exposed one scheduling-sensitive test deadline; its isolated rerun passed, so the test-only observation window was widened from one to three seconds under IR-087 without changing assertions. The final `Images/tools/tests` run passed 338 tests with three Linux-only GNU `timeout` cases skipped on macOS; Ruff lint and format checks passed. Captured Cuttlefish logs and `cuttlefish_config.json` retain their source trailing whitespace under the narrow Git attributes recorded in IR-088. Hostile review findings about IPv4-embedded notation and uncertain address provenance were addressed and recorded in IR-086; final adversarial review found no actionable findings.
- **GPU-none diagnosis runner (2026-10-01).** A real isolated run initially saved `guest_swiftshader` even though the patched `cvd create` used `--gpu_mode=none`. The pinned Cuttlefish CLI exposes a separate GPU mode on `cvd start`, so IR-090 now passes `--gpu_mode=none` to both commands and requires the saved config to match. The follow-up run recorded `gpu_mode=none`, four CPUs, and 4096 MiB, then exited with status 1 after 7 seconds. Its content-free summary has zero boot-complete/system-server lines and zero logcat bytes. Capture cleanup completed, no `crosvm` remained, and the private workspace was removed. The isolated record is outside the repository at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-none-20261001T070451Z-63366`; it is not a successful profile or a root-cause finding. The focused Linux diagnosis suites passed 36 tests, Ruff and shell syntax checks passed, and `scripts/ci/run-checks.sh` passed all six checks. #064 still needs a boot diagnosis, all three canonical profiles, and its remaining T3 findings.
- **Short Cuttlefish HOME and product-image recovery (2026-10-01).** A sanitized startup log from the isolated run reported a Unix socket `sun_path` request of 130 bytes, above Linux's 108-byte limit; this happened before Android boot and does not explain the guest boot stall. IR-090 first tried a random short `/tmp` symlink alias, but Cuttlefish canonicalized it and the same path-length error remained. A later attempt used a short physical HOME but left `TMPDIR` at the long workspace path. The runner now resolves physical `/tmp`, sets both `HOME` and `TMPDIR` to private short paths, and checks actual filesystem Unix socket paths—including the terminating NUL—under the temporary tree and UID-wide Cuttlefish state directory before removing generated HOME directories. It checks Cuttlefish process environment, command line, working directory, and open file descriptors before cleanup, and preserves state if process cleanup cannot be verified. Supervisor stderr is retained in a separate 64 KiB bounded log. Before that attempt, `super.img`, `userdata.img`, and four vbmeta images had source sizes different from the checked-in manifest, consistent with Cuttlefish's documented in-place image resizing. The checked-in archive matched its recorded SHA-256; all affected files were re-extracted, verified, and restored. No run so far provides Android boot evidence.
- **Cleanup hardening and repeat GPU-none capture (2026-10-01).** The Linux process audit now checks all same-UID processes and fails closed if references cannot be inspected. It skips Lima's environment-protected `sd-pam` only after verifying the exact current-user systemd service cgroup, and it excludes cleanup callers only when PID start times still match. Socket audits reject directory and socket symlinks; dangling and non-socket file links are not followed. Empty and populated per-run HOME roots use the same descriptor-relative cleanup. The stderr reader waits at a startup gate until its PID and start time are recorded, and shutdown uses a pidfd with an identity check before TERM or KILL. The repeat real run at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-none-20261001T165340Z-81386` measured 12 socket paths, maximum 59 bytes excluding NUL and 60 including NUL. Cuttlefish again reported `VIRTUAL_DEVICE_BOOT_FAILED`; no `system_server`, boot-complete, or logcat lines were captured. The child exited 1 without truncation, cleanup completed, no `crosvm` remained, and the marked private `/tmp` root was removed. The normalized diagnostic record was published, while its bounded host output remains in the private workspace. This provides no boot success or root-cause evidence. Linux focused tests passed 82 cases; macOS passed 61 with 21 platform-specific skips. Ruff, shell syntax, and whitespace checks passed. IR-090 records the remaining choices for maintainer review.
- **PID-safe stderr shutdown verification (2026-10-01).** Hostile review found that an exited stderr reader's numeric PID could be reused before shutdown sent TERM or KILL. The runner now blocks the reader at a startup FIFO until it records the process start time, then starts a broker that verifies the identity and pins a pidfd before releasing the reader. TERM and KILL requests use that retained descriptor. Regression tests verify that a changed start time is rejected and exercise broker TERM delivery through a real Linux pidfd. A real Linux retry published `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-none-20261001T170532Z-83150`; the supervisor recorded 12 filesystem sockets with a 59-byte maximum pathname (60 bytes including NUL), a capture exit code of 1, no logcat or boot-complete signals, and complete cleanup. This remains diagnostic evidence, not a successful boot or root-cause finding. Focused tests passed 85 cases on Linux and 63 on macOS with 22 platform-specific skips; all six repository checks passed. The final hostile re-review is pending, and IR-090 remains marked for maintainer review.
- **Pidfd-derived reader exit record (2026-10-01).** The broker now watches its pinned pidfd and atomically writes the reader-exited marker; the shell uses that marker to reap the original child and waits for the broker-stopped marker. A repeat real Linux run published `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-none-20261001T172756Z-88844`, with 12 filesystem sockets, maximum pathname 59 bytes (60 including NUL), capture exit 1, no timeout, and no logcat or boot-complete evidence. The reader exit record and broker stopped marker were present, bounded stderr cleanup completed without a signal, and the run-owned short HOME was removed. Focused tests passed 85 cases on Linux and 63 on macOS with 22 platform-specific skips; Ruff, formatting, shell syntax, and whitespace checks passed. Hostile re-review and the full repository check remain pending. The run does not establish boot success or root cause.
- **Lifecycle hardening verification (2026-10-01).** Follow-up hostile review found signal windows around ADB startup, missing signal-path socket cleanup, an unbounded broker wait after its stopped marker, and a watcher cleanup failure path. Startup bookkeeping and signal cleanup now cover those windows; broker and direct-child reaping use bounded waits, and unverified watcher cleanup retains the private workspace and ADB server. Regression tests cover the signal handoff, socket removal, stopped-marker broker hang, and watcher marker write failure. The focused diagnosis suites passed 121 tests on Linux and 89 on macOS (32 platform-specific skips); Ruff lint and format, shell syntax, whitespace checks, and all six `scripts/ci/run-checks.sh` checks passed. Final hostile re-review and the next isolated real-VM run are pending. This does not establish boot success or root cause.
- **Procfs exit-race follow-up (2026-10-01).** The isolated retry at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-retry/results/gpu-none-20261001T204448Z-121412` again recorded `VIRTUAL_DEVICE_BOOT_FAILED` (`run_cvd` returned 10, capture status 1). No guest boot-complete evidence was recorded, and the Cuttlefish fleet was empty with no `crosvm` process after cleanup. Cleanup conservatively retained the private short HOME because a short-lived `sleep` exited between `/proc` reads and its environment disappeared. IR-111 records the fix: ignore only a vanished `/proc/<pid>` entry or verified `Z`/`X` state, pin live same-UID processes with pidfds so same-tick PID reuse is detected, and fail closed for missing fields on a live process. The process ancestry is also pinned and each parent link is rechecked across the scan. The watcher is now pidfd-supervised from startup; numeric-PID signal fallbacks were removed, and broker failures retain the workspace. This capture remains incomplete and is not a successful profile or root-cause finding.
- **Pidfd cleanup verification (2026-10-01).** Final hostile review found that normal watcher shutdown waited for the child but skipped verifying and reaping its signal broker. The runner now finalizes the pinned watcher after its normal wait, and marks cleanup incomplete while retaining the workspace if broker finalization fails. A Linux regression test exercises that failure path. Final diagnosis suites passed 158 tests on Linux and 118 on macOS with 40 platform-specific skips; Ruff, formatting, Bash syntax, whitespace, all six repository checks, and final hostile review passed. The following isolated retry is recorded below.
- **GPU-none launch failure isolated (2026-10-01).** The post-cleanup retry at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-retry-3/results/gpu-none-20261001T213427Z-139362` recorded `gpu_mode=none`, four guest CPUs, and 4096 MiB, but no guest boot data. Cuttlefish 1.57.0 auto-enabled vhost-user GPU on arm64; `run_cvd` failed in `BuildVhostUserGpu` with `GPU mode none not yet supported with vhost user gpu`, returned 10, and caused `VIRTUAL_DEVICE_BOOT_FAILED`. The separate logical-partition geometry warnings are not established as causal. The run recorded 12 filesystem sockets (maximum pathname 60 bytes including NUL), complete capture cleanup, a stopped stderr broker, and no remaining `crosvm`; existing unrelated ADB servers were left untouched. IR-112 records the correction: pass `--gpu_vhost_user_mode=off` to both Cuttlefish commands and reject the result unless the saved config confirms it is disabled. Retry this corrected profile before attributing the earlier Android boot stall.
- **Corrected GPU-none retry and socket-audit fix (2026-10-01).** The run at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-retry-4/results/gpu-none-20261001T215602Z-145104` confirmed `gpu_mode=none` and the JSON boolean `enable_gpu_vhost_user=false`, with four guest CPUs and 4096 MiB. Cuttlefish 1.57.0 still exceeded the 600-second startup deadline after 603 seconds; `kernel.log` was empty, no crosvm command line was captured, ADB stayed unknown, and no system-server or boot-complete marker appeared. The saved launcher log contains repeated `127.0.0.1:6520` “device not found” messages, but does not establish why the guest failed to appear. This rules out the earlier vhost-user GPU startup error for this run; it does not establish the Android boot root cause. During cleanup, the audit found an in-root Cuttlefish socket symlink and retained the private temporary root. The updated FD-based audit measured 27 socket paths with a maximum of 81 bytes including NUL; the ownership-marked cleanup then removed the root and the normalized incomplete record was published. IR-113 records the choice. Hostile reviews exposed and drove fixes for directory, socket-target, direct-socket, and skipped-symlink races; the final review found no actionable findings. The full diagnosis suite passed on Linux (167 tests) and macOS (127 passed, 40 platform skips); Ruff lint and formatting passed. All six repository checks also passed. #064 still needs a boot diagnosis, all three canonical profiles, marker timings, guest command execution, and its T3 findings.
- **ADB polling deadline race (2026-10-01).** The full image suite found that a two-second ADB retry sleep could retain its original duration after the recalculated deadline had only one second remaining. `run_with_boot_deadline` now clamps the sleep argument to the freshly computed remaining time. The focused regression and full image suite passed; shell syntax, all six repository checks, and final hostile review passed. This fixes the host polling bound only; it does not explain the Android boot stall.
- **GPU-none configuration timing (2026-10-01).** A Cuttlefish 1.57.0 `cvd create --nostart` probe confirmed that the private runtime has no `cuttlefish_config.json` after creation; Cuttlefish creates it during `cvd start`. The isolated runner now keeps the exact `--gpu_mode=none` and `--gpu_vhost_user_mode=off` arguments on both commands, and an integration fixture checks their actual argument vectors and verifies the configuration appears during start. The record builder rejects a missing or mismatched saved GPU configuration before publishing any result. IR-114 records why this check cannot run before start. A current-code real retry at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-current/results/gpu-none-20261001T230006Z-170228` saved `gpu_mode=none`, `enable_gpu_vhost_user=false`, four CPUs, and 4096 MiB. Cuttlefish create/start exceeded its 600-second boot deadline; capture completed after cleanup in 603 seconds without reaching the separate 900-second runner deadline. No kernel output, ADB discovery, system-server evidence, or boot completion was captured. Cleanup left no Cuttlefish groups or `crosvm`; this is not a successful boot or a root-cause finding. The new launch-pipeline tests passed three cases on Linux; the full diagnosis suites passed 170 tests on Linux and 127 on macOS (43 platform skips). `Images/tools/tests` passed 343 tests with three Linux-only `timeout` skips on macOS. Ruff lint and formatting, shell syntax, whitespace checks, all six repository checks, and hostile re-review passed.
- **OpenWrt reset attribution and serial-console retry (2026-10-01).** The normalized launcher log from the current-code retry initially appeared to show a guest system reset about 15 seconds after launch. Process attribution identifies this as the auxiliary OpenWrt crosvm (`process_name=openwrt`), not the Android VM; see IR-089. The ADB connector repeatedly reported that `127.0.0.1:6520` was not found, and `kernel.log` remained empty. The Android boot failure therefore remained undiagnosed. The next isolated GPU-none retry enables Cuttlefish's serial console on both create and start and verifies the persisted `console=true` setting, because the pinned 1.57.0 CLI disables the serial console by default. IR-115 records this diagnostic choice; it does not alter the canonical profiles.
- **Serial-console follow-up (2026-10-02).** The isolated record `gpu-none-20261002T002315Z-204753` confirms `gpu_mode=none`, `enable_gpu_vhost_user=false`, `console=true`, and `enable_kernel_log=true`. Its normalized launcher log identifies the system reset about 18 seconds after launch as belonging to the auxiliary OpenWrt crosvm (`process_name=openwrt`); `process_restarter` starts its replacement. This is not evidence that the Android VM reset. Across 40 ADB samples, the device remained unknown; `kernel.log` was empty, and no guest or boot-complete data was captured. An initial 60-second Screen attempt and a later 25-second attachment from a pseudoterminal to Cuttlefish's advertised console endpoint showed no guest text. The first attempt left a detached Screen session, which was explicitly quit and verified gone. Cuttlefish create/start exceeded its 600-second boot deadline; capture completed after cleanup in 603 seconds without reaching the separate 900-second runner deadline. Cleanup left the Cuttlefish fleet empty. This confirms the console configuration was applied but provides no boot diagnosis. The experiment README clarifies that its runner does not save a Screen transcript.
- **Same-commit GPU-mode pair (2026-10-02).** The records `gpu-none-20261002T010755Z-222215` and `gpu-guest-swiftshader-20261002T011835Z-233820` use observed capture-tool commit `508658fea65ca701eea382f6720d3d91c15c65cc`, the same observed capture-tool blob map, host, build, and Cuttlefish 1.57.0 revision `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`. Both saved `console=true`, vhost-user GPU disabled, four CPUs, and 4096 MiB. The selected mode is embedded in the generated `patched-capture.sh`; saved config also differs in mode-derived ANGLE and hwcomposer settings and per-run WebRTC/group identifiers. `host.json` records `captureDurationSeconds` as 603 and 604. The `none` record has an empty `kernel.log`; the SwiftShader record has 10,308 bytes of U-Boot output across 158 lines, ending at `Starting kernel ...` with no Linux version or init marker. Both exceeded the 600-second boot deadline, exited 1, recorded 40/40 ADB samples as unknown, and have no guest logcat or Android boot evidence. Post-run checks found `cvd fleet` empty and no `crosvm` process. This pair does not explain the boot failure; the earlier SwiftShader capture that reached zygote and SurfaceFlinger used a different tool revision and is context only. See IR-116.
- **Same-commit console-setting pair (2026-10-02).** The records `gpu-guest-swiftshader-console-on-20261002T020749Z-266868` and `gpu-guest-swiftshader-console-off-20261002T021851Z-278509` use observed capture-tool commit `6ff41f8fd698f67958369a9dba8b86bb7dabbe13`, the same observed tool blobs, host, build, and Cuttlefish 1.57.0 revision. Both saved `gpu_mode=guest_swiftshader`, vhost-user GPU disabled, four CPUs, and 4096 MiB. The selected `console` value matches the metadata and result-directory name; experiment source hashes differ only in `patched-capture.sh`. The remaining config differences are per-run `group_uuid` and `webrtc_device_id`. Both runs took 604 seconds, exited 1 at the 600-second boot deadline, and completed cleanup. Each `kernel.log` contains 10,308 bytes across 158 lines of U-Boot output through `Starting kernel ...`, with no later Linux-kernel output. Both have 40/40 ADB samples unknown and no guest logcat. After the pair, `cvd fleet` was empty and no `crosvm` process remained. Changing the console selection did not change the observed log stage; these records do not establish whether the kernel started or why post-handoff evidence is absent. See IR-117.
- **Current-tool console-off repeat (2026-10-02).** The incomplete result at `$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-guest-swiftshader-console-off-20261002T023646Z-290359` uses observed tool commit `6ff41f8fd698f67958369a9dba8b86bb7dabbe13`, the same baseline capture-tool commit, host, build, and Cuttlefish 1.57.0 revision as IR-117. It saved SwiftShader, vhost-user GPU disabled, `console=false`, four CPUs, and 4096 MiB. The run took 605 seconds; Cuttlefish exited 1 at its 600-second boot deadline, and cleanup completed. Its 10,308-byte U-Boot log ends at `Starting kernel ...`; all 40 ADB samples are unknown and guest logcat is empty. A live `ps` sample showed the Android crosvm process at 99.9% CPU. A thread sample near eight minutes into the run showed `crosvm_vcpu0` at 99.9% and the other three vCPU threads at 0.0%; subsequent samples still reported 99.9% for vCPU0. These are sampled observations, not a continuous trace, and were not stored in the normalized result. After cleanup, `cvd fleet` was empty and no `crosvm` remained. The normalized bootconfig key/value set matches the older incomplete capture after excluding serial and Wi-Fi MAC identifiers. The saved Cuttlefish configuration also matches after excluding generated `group_uuid`, `webrtc_device_id`, `serialno`, and `wifi_mac_prefix` values and masking absolute paths. This run still has no post-handoff Linux or Android init evidence. The vCPU activity does not locate the hang or prove that Linux reached its first log point. See IR-118.
- **U-Boot-pause console retry (2026-10-02).** The normalized incomplete record `Images/reference/16373615/incomplete/gpu-none-console-on-20261002T062002Z-375629/` uses Ubuntu 24.04.4 arm64, Cuttlefish 1.57.0, and build 16373615; the run lasted 605 seconds and exited 1 at the 600-second boot deadline. The saved configuration has `pause_in_bootloader=true` and `console=true`; `cvd start --help` describes the flag as stopping in U-Boot until `boot` is typed at the device console. Cuttlefish created the private PTY endpoint and Screen started, but the status-only helper summary reports 83 observed bytes, no U-Boot prompt, no `boot` command, and no kernel handoff. The raw console bytes are intentionally not retained, so their source cannot be inferred from the byte count. All 40 ADB samples were unknown, the captured `kernel.log` is empty, and the launcher repeatedly reported the ADB transport missing. Cleanup completed, `cvd fleet` was empty, and no console helper remained. A local synthetic PTY check using the installed Screen executable passed the prompt → `boot` → kernel-marker flow; this validates the helper's Screen/PTY path only, not Cuttlefish boot. The record is diagnostic evidence only and does not identify a root cause or satisfy the reference-capture criteria. See IR-119.
- **U-Boot banner-status repeat (2026-10-02).** The normalized incomplete record `Images/reference/16373615/incomplete/gpu-none-console-on-20261002T070032Z-417640/` uses observed tool commit `ee60ce575deeea3f69d962d74c85e89110492449`, Ubuntu 24.04.4 arm64, Cuttlefish 1.57.0, and build 16373615. It took 605 seconds and exited 1 at the 600-second boot deadline. The schema-2 summary confirms the private PTY endpoint and Screen started, but `uBootBannerObserved=false`, with no prompt, `boot` command, or kernel handoff; 83 bytes were observed before the timeout. The raw console bytes were not retained, so this does not establish whether any guest text was among them. All 40 ADB samples were unknown, `kernel.log` was empty, and no guest logcat was captured. Cleanup completed, `cvd fleet` was empty, and no helper remained. The retry does not identify a root cause or qualify as a reference profile. See IR-119.
- **Screen terminal-byte interpretation (2026-10-02).** With no guest output, the installed Screen executable emitted exactly 83 bytes of terminal escape sequences to the helper's PTY, and escape stripping reduced that synthetic output to zero bytes. The earlier live run also counted 83 bytes, but its raw bytes were discarded, so equality of count does not prove equality of content. Schema 3 records both counts and whether an incomplete escape sequence caused the parser to discard a tail, while continuing to discard the transcript. A zero escape-stripped count with that flag set cannot establish that no text was present. This does not establish whether Cuttlefish forwarded guest output or explain the boot failure. See IR-120.
- **Capture-output interpretation (2026-10-02).** The retained U-Boot-pause records have no unnormalized `launcher.log` in their temporary work directories. Their normalized logs replaced complete `--serial=hardware=...` arguments, removing the UART/hvc mapping and endpoint filenames. The normalizer now retains the serial hardware, number, and type fields plus each endpoint basename while replacing private path prefixes. The records' `MISSING.txt` entry for `crosvm-command-line.txt` describes only the later artifact-collection process snapshot; the launcher log shows that crosvm had been launched, so the entry does not establish that crosvm never ran. The same-commit SwiftShader/GPU-none console-on pause pair recorded the mapping in normalized logs without retaining a console transcript. See IR-122 through IR-124.
- **Screen startup cleanup race (2026-10-02).** Hostile review found that `_stop_screen()` could signal an as-yet-unestablished process group during the short interval between `fork()` and `setsid()`, leaving the child or a later Screen descendant alive. Cleanup signals the known child PID, then repeats `SIGKILL` while bounded verification finds live process-group members. Linux regression tests cover the pre-`setsid()` child and a synchronized session-creation/fork race. See IR-121.
- **Same-commit U-Boot-pause GPU pair (2026-10-02).** The results `gpu-guest-swiftshader-console-on-20261002T081726Z-477707` and `gpu-none-console-on-20261002T082317Z-482634` use observed tool commit `0643f97c5f0290e62b34f0f853b4acaef2119fcd`, identical observed tool blob maps, Cuttlefish 1.57.0, build 16373615, `console=true`, `pause_in_bootloader=true`, 180-second boot deadlines, four CPUs, and 4096 MiB. The normalized launcher logs map the device console to `hardware=serial,num=1,type=file,path=<HOST_PATH>/console.out,input=<HOST_PATH>/console.in,earlycon=true` and the kernel log to `hardware=virtio-console,num=1,type=file,path=<HOST_PATH>/kernel-log-pipe,console=true`. In the SwiftShader record, Screen and `kernel.log` both contain the U-Boot banner, prompt, and `Starting kernel ...`; the helper sent `boot` and observed kernel handoff. Screen observed 19,226 PTY bytes, 19,143 after escape stripping; `kernel.log` has 18,870 bytes and no Linux version. In the GPU-none record, Screen observed 83 bytes, all stripped as terminal controls, with no banner or prompt; `kernel.log` is empty. Both Cuttlefish captures exited 1 at the boot deadline, recorded 13/13 ADB samples as unknown, no guest logcat, and completed cleanup. This shows that both console paths carried U-Boot output in the SwiftShader run, but a single pair does not prove GPU mode caused the difference, show that Linux began executing, or identify the Android boot root cause. Neither record satisfies the boot acceptance criteria. See IR-124 and IR-126.
- **Bounded vCPU trace after the handoff log marker (2026-10-02).** A direct Cuttlefish 1.57.0 launch of build 16373615 with four CPUs and 4096 MiB ended at its 120-second deadline (exit 124); the 10,308-byte `kernel.log` ended at `Starting kernel ...`, without Linux earlycon, version, or init. KVM traces selected Android crosvm PID 489124 and its `crosvm_vcpu0` TID 489213; a concurrent one-vCPU crosvm was excluded. Both PC windows reported `0x000000017f63e1f4`, a high guest-DRAM address that the trace itself did not symbolize. The separate fault window recorded 4,410 `kvm_guest_fault` events at that PC over sequential 4 KiB pages from `0xb37a9000` through `0xb48e2000`. Trace counts, fields, filters, timestamps, loss statistics, and HSR values are recorded in IR-127. A later nonce-framed read found the expected U-Boot instruction words at this address in a separate paused run; see IR-133 and IR-137. Neither capture establishes that cache maintenance caused the delay.
- **KVM fault-syndrome decode (2026-10-02).** Under Arm's `ESR_EL2` definition, HSR `0x92000147` and `0x92000146` both encode a Data Abort from a lower exception level with `CM=1`, meaning a cache-maintenance or address-translation operation. Their DFSC values `0x07` and `0x06` decode as translation faults at levels 3 and 2, respectively. This narrows the observed operation but does not identify its caller or explain the missing translation. A later direct memory read corroborates the instruction words at the candidate address, but does not explain the observed faults. See [Arm's ESR_EL2 definition](https://developer.arm.com/docs/ddi0601/latest/aarch64-system-registers/esr_el2) and IR-127, IR-133, and IR-137.
- **Pinned Cuttlefish source and runtime U-Boot environment (2026-10-02).** Review of the exact Cuttlefish 1.57.0 source commit `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d` confirmed the console routes, PTY packet handling, and `pause_in_bootloader` behavior described in IR-128. An inventoried runtime instance contained a 73,728-byte `uboot_env.img` and a 229-byte `mkenvimg_input`; the supplemental environment set only `ethprime` and `uenvcmd`, without overriding `bootcmd`, `bootdelay`, `stdin`, or `stdout`. The staged and packaged `bootloader.crosvm` files had the same SHA-256, `f464a92c6086fa876c0bc775397d20b7491b6b34e2260feb0e19b5ca97f2dd30`, and contained the version string `U-Boot 2024.04-g3fe964757589-ab15108624`. No symbol map was found in the bootloader architecture directory, so the earlier traced PC's execution context remains unresolved. The later live read corroborates the code window at that runtime address but does not locate the earlier trace within U-Boot's call path. The temporary CVD group, trace workspace, and product copy were removed; the pre-existing shared ADB server was left untouched. See IR-128 and IR-137.
- **U-Boot traced-word probe follow-up (2026-10-02).** The primary long, untraced capture recommended in the supplied diagnosis was already complete before this optional paused-U-Boot probe (C); see the 2400-second unpaused boot-observer retry below. The earlier schema-5 probe queried `bdinfo`, but the packaged bootloader exposed no `bdinfo` or relocation labels in its filtered strings, and the first live response contained no relocation fields. Following the supplied diagnostic advice and the instruction-address analysis in IR-133, the helper clears dedicated `w0`/`w1` variables and requires their empty-state marker before sending `setexpr.l w0 *0x17f63e1f4;setexpr.l w1 *0x17f63e1dc;echo ${w0} ${w1} <nonce>`, where each helper run creates a fresh seven-character nonce. The command and `=> ` prompt occupy 79 of the 80 console columns. It reads two 32-bit guest-memory words and does not write the inspected addresses. The expected values are `d50b7e20` and `d53b0023`; acceptance requires the exact echoed command, one response line with two 32-bit words and the same run's nonce, and the following prompt. Additional, malformed, duplicate, or delayed output from another run is rejected. This per-run marker prevents a delayed response from being mistaken for the current response, but does not authenticate the console endpoint. A rejected response with a prompt continues boot; a missing echo or prompt, or expiry of the shared five-second preparation/read timeout, leaves the VM paused. The timeout begins before the first command send, bounds both command transmissions and responses, and remains inside the overall Cuttlefish boot deadline. Schema 6 records preparation, response, and handoff states while still accepting schema 3–5 summaries. Both startup paths pass the bounded timeout to Cuttlefish. When publishing a capture after either probe command was sent, the publisher omits the mirrored `kernel.log` and records the omission. The full Linux experiment suite passes 349 tests. Adversarial review found a documentation mismatch and a stale-response test-ordering gap; both were fixed, and final follow-up review found no remaining findings. A prior pre-nonce live probe recorded the expected word pair and a kernel-handoff marker; the nonce-framed run below now validates the new response protocol. The live memory read corroborates that these instruction words occupy the candidate addresses in paused U-Boot, but does not establish the earlier trace's execution context or the boot delay's cause. See IR-129, IR-130, IR-133, and IR-137.
- **Nonce-framed live U-Boot probe (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T052650-788232/`).** The committed probe ran on the Ubuntu 24.04.4 arm64 nested-virtualization VM with Cuttlefish 1.57.0, four guest CPUs, 4096 MiB, SwiftShader, console enabled, and bootloader pause enabled. The boot deadline was 180 seconds; `host.json` records 185 seconds. The schema-6 `experiment.json` records that the U-Boot banner and exact preparation and read-command echoes were observed, along with the accepted nonce-framed words `d50b7e20` and `d53b0023`, `bootCommandSent=true`, and `kernelHandoffObserved=true`, with no probe rejection or timeout. The capture used commit `638a596`. Cuttlefish startup did not complete before the guest deadline; `captureExitCode` is 1 and the recorded `cvd-start` child exit code is null. All 13 ADB samples from 20:23:46Z through 20:26:48Z were `unknown`, and no positive `sys.boot_completed` value or guest logcat was captured. The publisher omitted `kernel.log` by design after the probe, so the record cannot establish whether Linux or Android booted after handoff. `MISSING.txt` records the guest deadline and absence of a crosvm process at artifact-collection time; it contains no false bootloader-console handoff failure. The normalized directory has nine capture files and a Lima-side `LIMA-SHA256SUMS` manifest; host-side `sha256sum -c` verified all nine files. Privacy scans found no private host paths, MAC addresses, or PEM key markers. The recorded helper and capture cleanup flags are complete. This live run verifies the nonce-framed console exchange and expected instruction words at the candidate addresses, not Linux or Android boot.
- **U-Boot cache-maintenance match (2026-10-02).** The traced PC `0x000000017f63e1f4` matches a `dc civac, x0` instruction independently reproduced from the hash-verified `bootloader.crosvm` at file offset `0x21f4`; subtracting the offset yields aligned candidate base `0x000000017f63c000`. The nonce-framed live probe read `d50b7e20` at that address and `d53b0023` at the preceding loop instruction address while U-Boot was paused, corroborating the code window at the candidate runtime addresses. A follow-up scan independently reproduced the unique offset among 174 aligned-base candidates; full disassembly found one dc civac, one dc ivac, and no set/way cache-maintenance instructions. The pinned source confirms the conditional handoff-to-cache-flush path, but no generated configuration is available and the option has no Kconfig default. This does not establish the earlier trace's execution context, the U-Boot build configuration, the runtime call path, or the cause of the delay. Slow cache maintenance remains consistent with the evidence, not an established root cause. See IR-133 and IR-137.
- **ADB readiness evidence gap (2026-10-02).** In `default-20261001T120904-49816`, the host `adb devices` preflight ran before Cuttlefish launch. The saved `launcher.log` records `adbd` startup and `Start event (5) received` at 12:05:16, followed by an internal connector `device offline` message at 12:05:29; the run has no external ADB-ready or `sys.boot_completed` measurement. A later `default` capture used a 2400-second outer deadline but ended after 600 seconds when Cuttlefish 1.57.0's own boot-state timeout expired. Its U-Boot-to-Linux interval was 537 seconds, with no launcher event 5, so ADB readiness remained unmeasured. The observer's first version produced 127 memory samples but identified no process: `--process_name=crosvm` was on `log_tee`, and the actual Android crosvm was its `process_restarter` child. A short direct `/proc` sample of that child rose from 2,986,004 to 3,147,880 KiB over 25 seconds. The observer now collects restarter PIDs from source-tagged log prefixes and filters them by private instance, Android serial role, and direct crosvm parent-child relationship. It resolves the selected instance directory and passes the configured timeout to Cuttlefish. The completed long retry below validated both corrections at runtime and observed ADB state `device`, but did not confirm `sys.boot_completed=1`; see IR-131 and IR-134.
- **Completed long unpaused boot-observer retry (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T014646-643687/`).** The `default` profile used four guest CPUs, 4096 MiB, `guest_swiftshader`, console off, and no bootloader pause. Both the capture and `cvd start --boot_timeout_secs` deadlines were 3000 seconds. `host.json` records a 3004-second capture duration. The outer deadline terminated startup; no reference profile was published. “Unpaused” means the guest followed its normal U-Boot path without console commands or vCPU tracing; the opt-in observer still sampled crosvm memory and polled ADB during `cvd start`.

  The normalized directory timestamp uses Lima's Asia/Tokyo local time; the event times below are UTC.

  `launcher.log` places the U-Boot banner at 15:56:45Z and Linux 6.12.74 at 16:09:18Z, an interval of 12 minutes 33 seconds. This refines the earlier snapshot window (16:07:47Z still ended at `Starting kernel ...`; Linux was visible by 16:12:17Z). Android first-stage init appeared at guest uptime 51.44 seconds, `ueventd` at 81.68 seconds, zygote at 349.52 seconds, and `adbd` at about 769 seconds. Vendor startup continued; the final kernel snapshot reaches guest uptime 2240.96 seconds and repeatedly shows audioserver looking up `aidl/activity`. As the attached diagnosis notes, that lookup alone does not establish a fatal failure.

  The first valid crosvm sample at 15:56:47Z was 90,928 KiB VmRSS /
  69,088 KiB RssShmem. Of the 600 five-second memory samples, VmRSS rose
  from 4,191,176 KiB at 16:09:12.534Z to 4,212,284 KiB at 16:09:17.533Z;
  this was the first sample at or above 4 GiB and immediately preceded the
  launcher-recorded Linux banner at 16:09:18Z (whose timestamp has one-second
  resolution). RssShmem first crossed 4 GiB at 16:09:22.534Z, the next
  sample after the banner. The Cuttlefish configuration records both
  `memory_mb=4096` and `ddr_mem_mb=4915`, and `internal-bootconfig.txt`
  reports `androidboot.ddr_size=4915MB`; treat 4 GiB as an RSS milestone,
  not evidence that all configured DDR was resident. The final sample at
  16:46:42.533Z was 4,233,156 / 4,205,908 KiB. The timing is consistent with
  substantial guest RAM becoming resident during the slow U-Boot-to-Linux
  transition and supports, but does not prove, the cache-maintenance
  hypothesis. RSS sampling does not identify the executing code, establish a
  stage-2 fault mechanism, confirm the bootloader configuration, or explain
  the later Android delay. A five-second host `/proc` sample showed each
  vCPU thread consume about five CPU seconds; this indicates active guest
  execution only and does not locate the code. Procfs checks confirmed the
  runtime link, current UID, ADB-port mapping, Android `process_restarter`
  parent, and staged crosvm executable identity.

  Launcher event 5 was observed at 16:22:11.114Z and the private ADB server became ready at 16:22:12.585Z. ADB state eventually reported `device`, but repeated polls had no `getpropExitCode` or `sys.boot_completed` value. The old observer format cannot tell whether `getprop` started or timed out (IR-136). A separate read-only `adb logcat -d -t 1` query through the private server timed out at its eight-second bound with exit 124; its output was discarded. A read-only search found no `system_server`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or `sys.boot_completed` marker.

  `MISSING.txt` records the 3000-second guest deadline and notes that no crosvm process remained at artifact-collection time; that does not establish whether it ran earlier. The JSON-only collector found no composite-named keys in `cuttlefish_config.json` and recorded the normalized composite-spec artifact as missing. This capture did not inventory the dedicated instance files later identified by IR-151, so their presence in this run is unknown; the missing artifact is not evidence of the boot failure. The retained normalized logs establish slow progress through Linux and Android startup but not a successful boot or a root cause.
- **Completed 2400-second unpaused boot-observer retry (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T024733-676851/`).** The `default` profile used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no bootloader pause. The outer capture and `cvd start --boot_timeout_secs` used 2400 seconds; `host.json` records a 2404-second duration. “Unpaused” means the guest followed its normal U-Boot path without console commands or vCPU tracing; the opt-in observer still sampled crosvm memory and polled ADB during `cvd start`. The incomplete directory's timestamp is Lima local time (Asia/Tokyo); event times below are UTC. The U-Boot banner was logged at 17:07:35Z and Linux 6.12.74 at 17:11:01Z, an interval of 206 seconds. Android first-stage init appeared at guest uptime 21.65 seconds and zygote at 189.74 seconds. This is a fourth observed U-Boot-to-Linux interval alongside 190, 537, and 753 seconds; the four values do not support a deterministic scan-rate estimate.

  The observer recorded 479 valid five-second crosvm memory samples. The first at 17:07:39.975Z was 181,680 KiB VmRSS / 159,848 KiB RssShmem. The sample at 17:10:59.974Z was 4,193,260 / 4,171,596 KiB; the next at 17:11:04.974Z was 4,216,196 / 4,194,532 KiB. The latter first crossed 4 GiB for both measures, within the five-second sampling window that contains the launcher-recorded Linux banner. The last sample at 17:47:29.975Z was 4,233,556 / 4,205,908 KiB. Since the config and bootconfig specify 4915 MiB of DDR, 4 GiB RSS is a residency milestone, not proof that all guest RAM was resident or that U-Boot performed a full-RAM cache flush. This timing supports that hypothesis but does not establish the executing code, a stage-2 fault cause, or the reason for the later Android delay.

  Launcher event 5 occurred at 17:18:16.393Z and the private ADB server was ready at 17:18:20.026Z. Of 116 ADB polls, three initial polls had no device state and did not start a property query. One of those polls timed out; the other two had a successful `connect` exit status but still no device state. The other 113 polls reported `device`. All 113 attempted `getprop`: 112 timed out under this run's two-second command cap, while one returned exit status 0 without an accepted `sys.boot_completed` value. No poll reached the shared deadline, and `sysBootCompleted` remained null throughout. A separate bounded, read-only `getprop` query through the same private socket took about seven seconds and returned no property text under its 12-second limit. This run therefore verifies ADB transport discovery, not property availability or Android boot completion. It predates the ten-second `getprop` cap from IR-136.

  The kernel log records servicemanager calls attributed to the `system_server` SELinux domain around guest uptime 1795.5–1795.98 seconds. At 2038.179 seconds, init records an untracked zombie process named `system_server` (PID 2258) exiting with status 0, then notes that it has no associated service entry. These lines do not establish the relationship between that process and the earlier caller, why it exited, or whether it caused the incomplete boot. The log continues through guest uptime 2184 seconds with repeated audioserver `aidl/activity` lookup messages; those messages alone do not prove a fatal failure. Neither the kernel nor launcher log contains `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or `sys.boot_completed=1`.

  `MISSING.txt` records that the 2400-second deadline expired and that no crosvm process existed at artifact-collection time; it does not establish whether crosvm ran earlier. The JSON-only collector found no composite-named keys in `cuttlefish_config.json` and recorded the normalized composite-spec artifact as missing. This capture did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. Cleanup left the Cuttlefish fleet empty and no crosvm or private ADB server running. All nine normalized files were hash-checked against the Lima capture, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This is diagnostic evidence only, not a successful reference profile or a proven root cause.
- **Recovered 600-second inner-timeout capture (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261002T224455-600285/`).** This earlier `default` run had four guest CPUs, 4096 MiB, `guest_swiftshader`, console off, and no bootloader pause. Its outer deadline was 2400 seconds, but `cvd start` used Cuttlefish's 600-second default; `host.json` records a 634-second capture duration. `launcher.log` records the U-Boot banner at 22:34:27 Lima local time (13:34:27Z) and Linux 6.12.74 at 22:43:24 local (13:43:24Z), 537 seconds later. `kernel.log` records Android first-stage init at guest uptime 28.82 seconds, but no zygote start or later system-server evidence. `launcher.log` records `TimeoutThreadLoop: waiting for 10m`. `cvd-create-console.log` records `VIRTUAL_DEVICE_BOOT_FAILED` and `run_cvd returned 10`; the run did not reach launcher event 5, so ADB readiness was not measured. The observer wrote 127 memory events, but every candidate had `identity=unavailable` and `candidateCount=0`; this was the process-identification gap later fixed by IR-131. Cuttlefish cleanup completed. `MISSING.txt` says no crosvm process existed at artifact-collection time, which does not establish whether it ran earlier. The nine copied files match their Lima-side SHA-256 values, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This is diagnostic evidence, not a successful reference profile or a root-cause finding.
- **Completed 1200-second live verification of the ten-second `getprop` cap (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T031842-703886/`).** This `default` run used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no bootloader pause. It followed normal U-Boot progression without console commands or vCPU tracing; the opt-in observer sampled crosvm memory and polled ADB during `cvd start`. `host.json` records 1203 seconds. The directory timestamp and launcher log use Lima's Asia/Tokyo time; observer timestamps below are UTC. `cvd-create-console.log` contains two `Logical partition metadata has invalid geometry magic signature` errors at 02:58:40 Lima local time; this warning also appears in an earlier capture and is not established as the cause of the slow boot. The U-Boot banner was logged at 17:58:44Z and Linux 6.12.74 at 18:03:10Z, 266 seconds later. First-stage init appeared at guest uptime 22.34 seconds and zygote at 185.92 seconds; the last kernel lines reach guest uptime 924.25 seconds. No `VIRTUAL_DEVICE_BOOT_COMPLETED` event or positive `sys.boot_completed=1` value was recorded. At guest uptime 458.78 seconds, the kernel log records init setting `sys.bootstat.first_boot_completed` to `0`; that value does not indicate successful boot completion.

  The observer captured 239 valid five-second memory samples. VmRSS/RssShmem was 4,167,692/4,146,036 KiB at 18:03:05.265Z and 4,216,188/4,194,532 KiB at 18:03:10.265Z, the first sample at or above 4 GiB for both measures. The launcher timestamp for Linux is 18:03:10 with one-second resolution, inside that sample interval. The last sample at 18:18:35.265Z was 4,225,484/4,198,328 KiB. Because the guest config and bootconfig specify 4915 MiB of DDR, the 4 GiB crossing is a residency milestone, not proof that all RAM was resident or that cache maintenance caused the delay.

  Launcher event 5 occurred at 18:10:19.203Z and the private ADB server was ready at 18:10:20.316Z. Before launch, the Lima copy of `boot_observer.py` was SHA-256 checked against the local source (`d19b56edf45b7011a53b42ca4ab2d1c6c60d89b52163a9780ac49688d2702494`); that source sets the `getprop` cap to ten seconds. Of 33 polls, three initially had no device state and did not attempt `getprop`: one connection command timed out, while two completed `connect` with exit status 0. The remaining 30 polls reported `device` and attempted `getprop` with the ten-second cap. Twenty-nine timed out; one exited 0 without an accepted property value. One final poll reached the ADB polling cutoff before the 15-second cleanup reserve, and `sysBootCompleted` remained null for all polls. A separate read-only `getprop sys.boot_completed` query and `logcat -d -t 1` query, each bounded to 12 seconds through the same private socket, both exited 124; their output was discarded.

  `MISSING.txt` records the 1200-second deadline and says no crosvm process existed at artifact-collection time, which does not establish whether it ran earlier. The JSON-only collector found no composite-named keys and recorded the normalized composite-spec artifact as missing; this capture did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. Cleanup left the Cuttlefish fleet empty and no crosvm or private ADB server running; the observer records private-server cleanup complete. All nine files match their Lima-side SHA-256 values, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This confirms ADB transport state and execution of the longer property-query path, but not a property value, system-server readiness, or a successful reference boot.
- **Later 2400-second unpaused boot-observer retry (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T062208-792872/`).** This `default` profile used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no bootloader pause. The outer capture and `cvd start --boot_timeout_secs` deadlines were 2400 seconds; `host.json` records 2403 seconds. The surviving Lima source copies were rechecked against the local files after capture; `post-run-verification.json` records the SHA-256 values and confirms that all three match. The directory name uses Lima's local clock: `capture.sh` constructs incomplete-record names with local `date`, without `-u`. Its `2026-10-03 06:22:08` timestamp is Lima local time (Asia/Tokyo); the sidecar records the observer stopping at `2026-10-02T21:22:06Z` and post-run verification completing at `2026-10-02T21:39:48Z`. The observer's first event is `2026-10-02T20:42:06Z`. These UTC timestamps establish that the capture and its verification occurred on October 2 UTC; the `2026-10-03` path component is not a UTC run date. Event times below are UTC. “Unpaused” means normal U-Boot progression without console commands or vCPU tracing; the opt-in observer still sampled crosvm memory and polled ADB during `cvd start`.

  The U-Boot banner was logged at 20:42:09Z and Linux 6.12.74 at 20:55:09Z, a 780-second interval. Android first-stage init started at guest uptime 34.83 seconds, and zygote started at 251.67 seconds. The capture contains no `system_server` start or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker. At guest uptime 592.51 seconds, init set `sys.bootstat.first_boot_completed` to `0`; this is not `sys.boot_completed=1`.

  The observer recorded 479 valid five-second crosvm memory samples out of 481 `crosvm_memory` events. The first sample at 20:42:11.142Z was 90,916 KiB VmRSS / 69,088 KiB RssShmem. VmRSS first crossed 4 GiB at 20:55:06.141Z (4,202,024 KiB), while RssShmem was still 4,180,364 KiB. RssShmem first crossed 4 GiB in the 20:55:11.141Z sample (4,194,532 KiB), when VmRSS was 4,216,192 KiB, two seconds after the launcher-recorded Linux banner. The last sample at 21:22:01.141Z was 4,229,344 / 4,202,120 KiB. Since configured DDR is 4915 MiB, this RSS crossing is a residency milestone; it does not prove that all guest DDR was resident or that cache maintenance caused the slow transition.

  Launcher event 5 occurred at 21:04:27.971Z and the private ADB server was ready at 21:04:31.193Z. Of 70 polls, the first three had no device state and did not attempt `getprop` (one connection command timed out and two `connect` commands exited 0). The other 67 reported `device` and attempted `getprop` with the ten-second cap: 55 timed out, and 12 exited 0 without an accepted property value. The final poll reached the ADB polling cutoff before the 15-second cleanup reserve. `sysBootCompleted` remained null, and no positive `sys.boot_completed=1` was observed.

  `host.json` records a 2403-second capture duration. `MISSING.txt` records the guest deadline, no crosvm command line at artifact-collection time, and a missing normalized composite-spec artifact. The JSON-only collector found no composite-named keys, and this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. The crosvm snapshot does not imply it never ran, as the observer captured 479 valid samples. `post-run-verification.json` preserves the observer's private-server cleanup event and external post-capture checks: the Cuttlefish fleet was empty, no crosvm or Screen process remained, private port 6520 had no listener, and a separate ADB server remained bound to loopback port 5037 and was left untouched. The nine normalized capture files and this sidecar are covered by the Lima-side `LIMA-SHA256SUMS`; host verification matched all ten entries. Privacy scans found no private host paths, MAC/EUI-64 addresses, or PEM private-key markers. This remains an incomplete diagnostic capture, not a successful reference profile or a confirmed boot root cause.
- **Current-tool guest-memory comparison (2026-10-02 UTC; normalized records: `Images/reference/16373615/incomplete/gpu-guest-swiftshader-console-off-memory-2g-20261002T231113Z-862770/` and `Images/reference/16373615/incomplete/gpu-guest-swiftshader-console-off-memory-4g-20261002T232950Z-874596/`).** Both runs used build 16373615, the same Ubuntu 24.04.4 arm64 nested-virtualization host, Cuttlefish 1.57.0, and capture-tool commit `27557ae44fba10cbf5e3a385ae94f64ce72ab369`. Each saved four guest CPUs, `guest_swiftshader`, vhost-user GPU disabled, console off, no U-Boot pause, and a 600-second boot deadline. Their verified Cuttlefish configurations differ in selected memory: 2048 MiB (`ddr_mem_mb=2457`) versus 4096 MiB (`ddr_mem_mb=4915`).

  In the 2 GiB run, `launcher.log` records U-Boot at 23:11:24Z and Linux 6.12.74 at 23:16:05Z, an interval of 281 seconds. `host.json` records 604 seconds. At the 600-second boot deadline, `cvd-start` logged that it received a termination signal and began cleanup. The capture command's recorded exit status is 1; no separate `cvd-start` exit code was recorded. In the same-tool 4 GiB control, U-Boot was recorded at 23:30:02Z, but no Linux banner was observed before the 600-second deadline; `host.json` records 603 seconds. Treat this U-Boot-to-Linux interval as right-censored, not as a measured 600-second interval. Neither run establishes Android boot completion; ADB and later Android signals are not used for this memory comparison.

  The older condition-matched 4 GiB record `default-20261001T120904-49816` reached Linux 190 seconds after U-Boot, but its metadata predates capture-tool provenance recording and does not identify the tool revision. Other 4 GiB captures already show substantial timing variation, including a 780-second U-Boot-to-Linux interval. These observations do not establish that 2 GiB improves boot time or prove or disprove the cache-maintenance hypothesis. Both new records have ten-file `LIMA-SHA256SUMS` manifests verified on the host, and scans found no private host paths, MAC/EUI-64 addresses, or PEM key markers. Each `experiment.json` records `captureRun.cleanupComplete=true`. The records do not preserve post-run Cuttlefish fleet, process, or shared-ADB checks; `MISSING.txt` only records that no crosvm process matched the private Cuttlefish HOME at artifact-collection time, which does not establish whether crosvm ran earlier.

  Running `compare_boot.py` on these two incomplete records yielded the expected `androidboot.ddr_size` values (2457 MiB and 4915 MiB), but the other nine comparison categories had no capture data in either record. It does not provide a full boot-profile comparison.
- **2400-second unpaused U-Boot/RSS/ADB follow-up (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T115618-900776/`).** This `default` run used build 16373615, four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no U-Boot pause or vCPU tracing. It kept the existing Cuttlefish configuration and used a 2400-second boot deadline; `host.json` records 2404 seconds. The Lima copy of the observer and capture sources matched the local sources recorded in `post-run-verification.json`. The U-Boot banner was logged at 02:16:18Z and Linux 6.12.74 at 02:18:14Z, 116 seconds later.

  The observer recorded 481 memory events, including 480 valid five-second crosvm samples. The first valid sample at 02:16:19.804Z was 25,716 KiB VmRSS / 4,044 KiB RssShmem. The first sample with both measures above 4 GiB was at 02:18:14.804Z (4,216,168 / 4,194,532 KiB), in the same second as the Linux banner. The last sample at 02:56:14.803Z was also the maximum (4,233,928 / 4,205,908 KiB). Since configured DDR is 4915 MiB, these RSS values are residency observations and do not prove that all guest RAM was resident or identify the code using it. The 116-second interval is another variable observation, not evidence of a deterministic scan rate or cache-maintenance cause.

  Android first-stage init appeared at guest uptime 12.882 seconds, followed by zygote at 142.693 seconds. Init set `sys.bootstat.first_boot_completed` to `0` at uptime 344.52 seconds; this is not `sys.boot_completed=1`. No `VIRTUAL_DEVICE_BOOT_COMPLETED` or `VIRTUAL_DEVICE_BOOT_FAILED` marker and no positive `sys.boot_completed` value were recorded. After launcher event 5 at 02:23:37.609Z, the private ADB server was ready at 02:23:39.854Z. Of 127 polls, 125 reported state `device` and attempted `getprop`; 18 property commands timed out and 107 exited successfully without an accepted value. The other two polls had no device state. No poll reported boot completion.

  The kernel log records servicemanager calls attributed to the `system_server` SELinux domain at guest uptimes around 1395–2259 seconds, as well as two untracked `(system_server)` processes exiting with status 0: PID 2086 at uptime 1581.577 and PID 4156 at 2255.427. At uptime 2263.712, a task named `watchdog` (PID 1857) issued a SysRq blocked-state dump. No blocked-task entries appear before the memory dump, which reports 620,318 free pages and 0 kB total/free swap. The all-CPU backtrace at uptime 2266.252 shows `system_server` PID 1700 on CPU 3, distinct from both zombie PIDs. These observations do not link either zombie exit to PID 1700, explain the exits, establish why the SysRq dump was triggered, or determine Android readiness. `kernel.log` ends during this dump at uptime 2266.256. The observer's final `logcat -d -b events` query at 02:55:37.703Z exited 0, read 21,100 bytes without timeout or truncation, and found zero recognized process events in its allowlist. Its private ADB server stopped at 02:55:37.707Z; RSS sampling continued through 02:56:14.803Z and the observer stopped at 02:56:15.906Z.

  A separate manually issued query of the same events buffer, capped at ten seconds and 64 KiB, timed out and was truncated; its exit code was -15, raw output was discarded, and its timestamp was not recorded. Its process-group cleanup was not verified. Post-capture inventory observed only the pre-existing loopback ADB server on port 5037, no listener on private port 6520, no crosvm or `process_restarter`, and an empty Cuttlefish fleet. The loopback server was left untouched. The nine normalized capture files and `post-run-verification.json` are covered by the ten-entry Lima-side `LIMA-SHA256SUMS`; all entries verified on the host. Privacy scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. `MISSING.txt` records the deadline and that no crosvm matched the private HOME at artifact-collection time; it does not establish whether crosvm ran earlier. This remains an incomplete diagnostic capture and does not establish Android boot completion or root cause. See IR-140.
- **Final logcat probe expansion (2026-10-03; see IR-141).** The observer now keeps the events-buffer query separate from a second main/system/crash query, preserving buffer provenance while collecting fixed counts for fatal-exception, fatal-signal, ANR-text, Watchdog, `system_server`, and `zygote` line mentions. Raw output remains in memory only. The extra bounded query extends the final-probe reservation to 40.5 seconds without changing the guest configuration or capture deadline. The Image tools suite passed 396 tests with four skips on macOS and 399 tests with one skip on Lima Linux; hostile review found no actionable issue. The live verification is recorded in the following run.
- **2400-second boot and logcat follow-up (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T131605-949526/`; see IR-142).** The `default` profile retained four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and normal U-Boot progression without vCPU tracing. `host.json` records 2402 seconds. `launcher.log` timestamps use Lima local time (Asia/Tokyo): it records the U-Boot banner at 12:36:05 and Linux 6.12.74 at 12:42:09, 364 seconds later (03:36:05Z and 03:42:09Z). Of 481 five-second memory events, 479 had valid RSS values. Both VmRSS and RssShmem first reached 4 GiB at 03:42:12.208Z (4,216,200 / 4,194,532 KiB), three seconds after the Linux banner; the last valid sample at 04:15:57.209Z was 4,233,192 / 4,205,908 KiB. This supports slow guest-memory residency around the U-Boot transition but does not establish a RAM-wide cache flush or its cause.

  Launcher event 5 occurred at 03:51:01.248Z and the private ADB server was ready at 03:51:02.259Z. The first `device` state appeared at 03:51:57.272Z. Of 96 polls, three had no device state and 93 reported `device`; the property query timed out in 56 polls and exited successfully without an accepted value in 37. No `sys.boot_completed` value was obtained.

  The terminal events query exited 0 with 23,984 bytes and zero recognized process events. The separate main/system/crash query exited 0 with 18,338 bytes, without timeout or truncation: fatal-exception, fatal-signal, ANR-text, and `system_server` mention counts were zero; Watchdog mentions were 10 and zygote mentions were 8. A separate manual bounded logcat query timed out after ten seconds with zero captured bytes and successful client cleanup. Its timestamp was not recorded, so its order relative to the terminal queries is unknown. These line counts do not identify a cause.

  `kernel.log` records zygote start at guest uptime 234.916 seconds and `sys.bootstat.first_boot_completed=0` at 557.083 seconds; the latter is not boot completion. Repeated audioserver lookups for `aidl/activity` continue through guest uptime 2029.731 seconds. No `VIRTUAL_DEVICE_BOOT_COMPLETED` marker or `sys.boot_completed=1` value was found. `cvd-create-console.log` also reports two `liblp` errors for invalid logical-partition geometry magic at 12:36:02.231 Lima local time; their relevance to the incomplete boot is unknown. `MISSING.txt` records the 2400-second deadline and a missing normalized composite-spec artifact. The JSON-only collector found no composite-named keys, and this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. The missing artifact prevents profile publication but does not by itself establish the cause of the guest state. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no private socket or port-6520 listener, and only the ADB server on loopback port 5037, whose process started before this capture and was left untouched. All ten entries in the Lima-side SHA-256 manifest verified on the host. Source-copy checks matched; privacy scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. The run remains incomplete and does not establish the U-Boot or Android failure cause.
- **2400-second SystemServer readiness capture (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T151738-1012957/`; see IR-143).** This untraced, unpaused `default` run used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, and console off. `host.json` records 2403 seconds. `launcher.log` records the U-Boot banner at 05:37:39Z and Linux 6.12.74 at 05:41:18Z, an interval of 219 seconds. Of 481 RSS events, 479 had valid samples; the first valid sample was 25,736 / 4,044 KiB VmRSS/RssShmem at 05:37:40.333Z. Both measures first reached 4 GiB at 05:41:20.333Z (4,216,192 / 4,194,532 KiB), two seconds after the Linux banner. The final valid sample was 4,234,040 / 4,205,908 KiB at 06:17:30.333Z. With configured DDR at 4915 MiB, this is a memory-residency observation near the Linux transition, not proof of a full-RAM cache flush, a deterministic scan rate, or its cause.

  `kernel.log` records first-stage init at guest uptime 23.015 seconds, the `zygote-start` init action at 98.229 seconds, the zygote service start request at 98.384 seconds, and the service process start at 98.473 seconds. `bootanim` started at 319.644 seconds. The log also records 38 service-manager lookups attributed to the `system_server` SELinux domain from uptime 994.970 through 2077.182 seconds. Repeated `aidl/activity` lookups continue through uptime 2013.637 seconds. These entries show framework-related activity but do not establish that SystemServer reached its runtime readiness milestone. No `VIRTUAL_DEVICE_BOOT_COMPLETED` marker or parsed `sys.boot_completed` value was recorded.

  Launcher event 5 occurred at 05:44:57.618Z and the private ADB server was ready at 05:45:00.385Z. The observer recorded 126 polls; 124 reported `device`, with the first at 05:45:40.392Z. Across the polls, `sys.system_server.start_count` returned exit status 0 in 81 polls, and every such result recorded the property as empty. The `sys.boot_completed` query returned exit status 0 in 54 polls, but no poll produced a parsed value or a positive completion result. The other property attempts include timeouts; raw property output was not retained. Both final logcat queries timed out with zero captured bytes, and their clients were cleaned up, so this run provides no logcat marker counts.

  `cvd-create-console.log` repeats the `liblp` invalid logical-partition geometry warning seen in earlier captures; its relevance is unknown. `MISSING.txt` records the 2400-second deadline, a missing normalized composite-spec artifact, and no crosvm command line at artifact collection. The JSON-only collector found no composite-named keys; this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. The missing artifact prevents profile publication but does not explain the guest state. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no listener on port 6520, the removed private socket HOME, and only the pre-existing ADB server on `127.0.0.1:5037`, which was left untouched. The ten-entry Lima-side SHA-256 manifest verified against the host copies; the five source-copy hashes matched. Privacy scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. This remains an incomplete diagnostic capture and does not establish Android boot completion or a root cause.

  This capture predates `sysBootCompletedPresent`; its `post-run-verification.json` records source revision `af7f5d4`. The 54 successful `sys.boot_completed` queries therefore cannot distinguish empty from unexpected non-empty output. The raw property output was not retained and cannot be recovered for this record.
- **2400-second unpaused follow-up (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T165948-1083660/`; see IR-144).** This `default` run retained four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and normal U-Boot progression without vCPU tracing. `host.json` records 2403 seconds. The U-Boot banner was logged at 07:19:50Z and Linux 6.12.74 at 07:21:31Z, 101 seconds later. Of 481 five-second memory events, 479 had valid RSS values; VmRSS first reached 4 GiB at 07:21:31.168Z and RssShmem at 07:21:36.168Z, five seconds after the Linux banner. This is a residency observation, not proof of a full-RAM cache flush or its cause.

  Android first-stage init appeared at guest uptime 26.998 seconds, zygote started at 111.284 seconds, and boot animation at 410.584 seconds. Init set `sys.bootstat.first_boot_completed` to `0` at 262.373 seconds; this is not `sys.boot_completed=1`. Init later killed and restarted zygote at about 2140 and 2147 seconds. The capture does not establish why. No `VIRTUAL_DEVICE_BOOT_COMPLETED` or `VIRTUAL_DEVICE_BOOT_FAILED` marker was recorded.

  Launcher event 5 occurred at 07:25:42.881Z and the private ADB server was ready at 07:25:46.220Z. Of 132 private-socket polls, 130 reported `device`; 113 property commands timed out and 17 outer shell commands exited 0. No per-property exit status or property value parsed in any poll. Raw property output was not retained, so the reason for those unparsed replies is unknown; this run does not establish that CRLF caused it. Final logcat queries exited 0 and completed cleanup: the events buffer had zero recognized process events, while the separate diagnostic buffers had two `system_server` mentions and zero ANR, fatal-exception, fatal-signal, Watchdog, or zygote mentions. These counts do not identify a cause.

  `MISSING.txt` records the 2400-second deadline, no crosvm command line at artifact-collection time, and a missing normalized composite-spec artifact. The JSON-only collector found no composite-named keys; this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no private ADB server or listener on port 6520, and only the pre-existing loopback ADB server on port 5037. One offline ADB entry was explicitly disconnected and the device list was then empty. All ten Lima manifest entries and all five source-copy hashes verified on the host; privacy scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. The run remains incomplete and does not establish Android boot completion or a root cause.
- **2400-second unpaused default follow-up (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T183619-1148306/`; see IR-148).** The Ubuntu 24.04.4 aarch64 Lima VM ran Cuttlefish 1.57.0 with nested virtualization, four guest CPUs, 4096 MiB memory, 4915 MiB DDR, `guest_swiftshader`, and console off. The guest boot deadline was 2400 seconds; `host.json` records a 3002-second total capture duration.

  The launcher log records the U-Boot banner at 17:46:21 Lima local time and Linux 6.12.74 at 17:52:00, 339 seconds later. Of 481 crosvm memory events, 480 contained valid RSS data. VmRSS first reached 4 GiB at 08:51:57.755Z (4,201,596 KiB); RssShmem did so at 08:52:02.755Z (4,194,532 KiB). The final valid sample at 09:36:15.960Z was 4,233,240 / 4,205,908 KiB. These are residency observations, not evidence of a full-RAM cache flush or its cause.

  Launcher event 5 occurred at 08:59:30.761Z and the private ADB server was ready 2.046 seconds later. Of 103 polls, 99 reported `device` and four had no parsed state. The combined property command was attempted in 99 polls; 96 timed out and three exited successfully without either property being parsed. No `sys.boot_completed` value, SystemServer start count, or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was recorded. The observer's events-buffer query completed with 23,687 bytes and zero recognized process events. Its main/system/crash query completed with 15,121 bytes and five Watchdog mentions; ANR, fatal-exception, fatal-signal, SystemServer, and zygote mention counts were zero. These observations do not identify a cause.

  `MISSING.txt` records the boot deadline, no crosvm command line at artifact collection, and a missing normalized composite-spec artifact. The JSON-only collector found no composite-named keys; this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. The missing artifact prevents profile publication but does not explain the guest state. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no private ADB server or port-6520 listener, removal of the private socket HOME, and only the pre-existing `127.0.0.1:5037` server, which was left untouched. All nine files in the Lima SHA-256 manifest verified on the host, all five source-copy hashes matched revision `736374602c7c64b67dbade2b78450758316e48e9`, and privacy scans found no tested private paths, MAC/EUI-64 addresses, or PEM keys. This observer predates IR-145–147, so the run does not live-verify those changes and remains an incomplete diagnostic capture.
- **ADB observer trigger latency (2026-10-03; see IR-145).** The reference observer now scans the launcher log on a one-second schedule while retaining the configured RSS interval (five seconds by default). It starts the private ADB observer as soon as event 5 is seen, without waiting for the next RSS sample. The regression test confirms the trigger occurs before the next memory-sample deadline and records no extra RSS sample. `test_boot_observer.py` passed 84 tests with one Linux-only skip; Ruff checks passed, and hostile review found no actionable issues. Live verification will be recorded with the next reference run.
- **Prioritize the boot-completion property (2026-10-03; see IR-146).** The combined ADB shell query now reads and emits `sys.boot_completed` before `sys.system_server.start_count`. If the latter query times out, the parser retains the complete boot-property pair even when the final output ends partway through the next field label; that exception is enabled only for a timed-out command. Complete malformed and out-of-order replies remain rejected. The timeout regression and related shell/parser tests passed (41 tests); the full observer test file passed 86 tests with one Linux-only skip. Ruff checks passed, and follow-up hostile review found no further issue.
- **Separate ADB transport-stage results (2026-10-03; see IR-147).** Each `adb_poll` now records whether `connect` and `get-state` started, their exit codes, and their timeout status independently. A fixed `getStateResult` classification distinguishes deadline/no-launch, timeout, command failure, probe errors, recognized device states, empty output, and other output without retaining raw responses. The staged poll tests passed 14 cases; the full observer test file passed 91 tests with one Linux-only skip. Ruff checks passed, and hostile review found no actionable issue. Live verification remains pending.
- **2400-second unpaused default observer follow-up (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/default-20261003T195146-1175735/`; see IR-149).** This `default` run used build 16373615, four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and normal U-Boot progression. The Ubuntu 24.04.4 aarch64 Lima host used nested virtualization and Cuttlefish 1.57.0; `host.json` records 2404 seconds. `launcher.log` records U-Boot at 10:11:46Z and Linux 6.12.74 at 10:15:07Z, 201 seconds later. Android first-stage init started at guest uptime 44.498 seconds; zygote started at 167.871 seconds. At 373.647 seconds init set `sys.bootstat.first_boot_completed=0`, which is not `sys.boot_completed=1`.

  The observer recorded 481 crosvm memory events, 480 with valid RSS. Both VmRSS and RssShmem first reached 4 GiB at 10:15:07.951Z (4,216,064 / 4,194,532 KiB); the last sample at 10:51:42.951Z was 4,233,200 / 4,205,908 KiB. These are residency observations, not evidence of a full-RAM cache flush or its cause.

  Launcher event 5 occurred at 10:20:55.277Z and the private ADB server was ready 51 ms later. Of 119 polls, 116 reported `device` and three returned a `get-state` command failure. The first `connect` timed out; the other 118 exited 0. Of the 116 property queries, 113 timed out and three outer shell commands exited 0, but no per-property status or value was parsed in any poll. No positive `sys.boot_completed` value or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was recorded. This live run confirms the event-5 observer trigger and the per-stage ADB record fields from IR-145 and IR-147. It does not live-verify property ordering from IR-146 because the guest produced no parseable property fields.

  The final events-buffer query captured 20,620 bytes with zero recognized process events. The separate main/system/crash query captured 17,148 bytes and counted 10 `system_server` mentions and five Watchdog mentions, with no ANR, fatal-exception, fatal-signal, or zygote mentions. These are bounded mention counts and do not identify a cause. The kernel log contains service-manager calls attributed to `system_server` PID 2139. Separately, an untracked process named `system_server` (PID 2739) exited with status 0 at uptime 2074.963 seconds; the log does not link these distinct PIDs. Repeated `audioserver` lookups for `aidl/activity` continue through uptime 2192.009 seconds. The only `VIRTUAL_DEVICE_*` lines are `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON` at uptimes 485.849 and 547.700 seconds; neither is a boot-completion marker. These observations do not explain the guest state.

  Cuttlefish received the deadline termination signal at 10:51:43Z. `MISSING.txt` records that no crosvm command line matched at artifact-collection time and that the normalized composite-spec artifact is missing. The JSON-only collector found no composite-named keys; this run did not inventory the dedicated instance files later identified by IR-151, so their presence is unknown. Neither observation establishes a boot cause. The observer's 480 valid samples confirm crosvm ran earlier. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no listener on private port 6520, removal of the private socket HOME, and only the pre-existing ADB server on `127.0.0.1:5037`, which was left untouched. All ten entries in `LIMA-SHA256SUMS` verified on the host, all five source-copy hashes matched revision `fa9c0ee1f7e4ab6a07e594e93264f371fbd96286`, and privacy scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. This remains an incomplete diagnostic capture, not a reference profile or a confirmed root cause.
- **Bound regular ADB poll clients (2026-10-03; see IR-150).** Ordinary `connect`, `get-state`, and property-query clients now use the same process-group cleanup and bounded-output runner as the final probe. Each stage records truncation, probe errors, and cleanup status; truncated replies are not accepted, and unverified child cleanup stops later ADB work and fails capture shutdown. The poll reserve now covers the command timeouts, per-client cleanup bounds, and scheduling margin. The full `Images/tools/tests` suite passed 445 tests with four platform skips; Ruff format and lint passed, and follow-up hostile review found no actionable issues. The 2026-10-03 live capture used the preceding source revision, so it does not verify this hardening.
- **Composite-disk config collector correction and live verification (2026-10-03; see IR-151).** A live Cuttlefish 1.57.0 instance generated three `*_composite_disk_config.txt` files under its selected `instances/cvd-1` runtime even though `cuttlefish_config.json` had no composite-named keys. The previous collector searched only JSON keys and incorrectly marked the artifact missing; earlier runs did not inventory the separate files, so their presence then is unknown. The fix reads the selected-instance files through no-follow directory descriptors, caps entries and bytes, rejects matching config symlinks and special files plus invalid UTF-8, and removes temporary output on interruption. Hostile review found two additional issues: caller-selected `TMPDIR` values outside the normalizer's known roots could leak into captured files, and resolving `/tmp` differently during startup and removal could make those phases use different HOME spellings. The capture now resolves `/tmp` physically, requires a supported normalization root, and uses that same path for Cuttlefish HOME and `TMPDIR`. Synthetic captures check normalization of the physical `/private/tmp` alias on macOS, interrupted cleanup, and the temp-root override. This is a capture-tool defect, not evidence about Android boot.

  The corrected collector was live-verified in `Images/reference/16373615/incomplete/default-20261003T224217-1230017/`. This 2403-second `default` capture ran Cuttlefish 1.57.0, build 16373615, on Ubuntu 24.04.4 LTS/aarch64 under nested virtualization. It collected `ap_composite_disk_config.txt`, `os_composite_disk_config.txt`, and `persistent_composite_disk_config.txt` from the selected instance; normalization retained each `crosvm` backend and redacted its host path. The 11-entry Lima manifest (ten normalized capture files plus `post-run-verification.json`) verified on the host. Privacy scans of the ten capture files found no tested host paths, MAC/EUI-64 addresses, or PEM private-key markers.

  The observer recorded 481 crosvm memory events, 479 with valid RSS values. VmRSS first reached 4 GiB at 13:12:05.191Z and peaked at 4,219,608 KiB; samples ran from 13:02:20.191Z through 13:42:10.191Z. The kernel log records Linux 6.12.74 and first-stage init at guest uptime 86.783 seconds. Init imported `init.zygote64.rc` at 136.998 seconds; the zygote service actually started at 635.936 seconds. `sys.bootstat.first_boot_completed=0` appeared at 1537.007 seconds; that is not boot completion. Event 5 occurred at 13:35:52.881Z, and the private ADB server was ready 51 ms later. Of 21 polls, 12 reported `device` and nine `get-state` commands exited 1. Twelve property queries timed out with exit -15 and produced no parsed values. The final logcat query also timed out with zero captured bytes. No `sys.boot_completed=1` or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was observed. The 2400-second deadline expired, so the run remains incomplete and is not published as a reference profile. `MISSING.txt` notes that no crosvm command line matched at artifact-collection time; the observer's earlier memory events confirm that crosvm had run. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no listener on private port 6520, removal of the private HOME, and no composite-spec temporary files. The memory residency and boot timings do not establish a full-RAM cache flush or an Android boot cause.
- **`target` profile with requested `drm_virgl` (2026-10-03; normalized record: `Images/reference/16373615/incomplete/target-20261003T233118-1257055/`; see IR-151 and IR-156).** Cuttlefish 1.57.0 ran build 16373615 on the Ubuntu 24.04.4 LTS/aarch64 nested-virtualization host. `host.json` records a 2405-second capture and `targetGpuMode=drm_virgl`, which is the requested mode. Inspection of `cuttlefish_config.json` shows the selected instance actually used `gpu_mode=guest_swiftshader`. The capture therefore does not demonstrate `drm_virgl` and must not be compared as the target GPU profile. The normalized composite artifact contains the same three selected-instance config files as the `default` run. The 11-entry Lima manifest (ten normalized capture files plus `post-run-verification.json`) verified on the host. Privacy scanning of the ten capture files found no tested host paths, MAC/EUI-64 addresses, or PEM private-key markers.

  The observer recorded 481 crosvm memory events, 480 with valid RSS values. VmRSS first reached 4 GiB at 13:59:49.902Z and peaked at 4,233,192 KiB. The kernel log records Linux 6.12.74, first-stage init at guest uptime 24.127 seconds, and the zygote service start at 200.780 seconds. `sys.bootstat.first_boot_completed=0` appeared at 515.150 seconds; that is not boot completion. Event 5 occurred at 14:07:47.059Z and the private ADB server was ready 51 ms later. Of 89 polls, 86 reported `device` and three `get-state` commands exited 1. Of 86 property queries, 85 timed out with exit -15 and one exited 0; no property value was parsed. The final events-buffer query exited 0 with 23,987 bytes and zero recognized process events. The separate Android diagnostic logcat query exited 0 with 20,611 bytes; its fixed line counts were two SystemServer mentions, ten Watchdog mentions, and zero ANR, fatal-exception, fatal-signal, or zygote mentions. These counts do not establish process state or a cause. No boot-completion property or `VIRTUAL_DEVICE_BOOT_COMPLETED`/`VIRTUAL_DEVICE_BOOT_FAILED` marker was observed. The deadline expired, so this is not a reference profile and does not establish a boot cause. `MISSING.txt` notes that no crosvm command line matched at artifact-collection time, while the memory samples confirm earlier crosvm execution. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no listener on private port 6520, removal of the private HOME, and no composite-spec temporary files.
- **2400-second `swiftshader` capture (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T004040-1283934/`; see IR-151).** The Ubuntu 24.04.4 LTS/aarch64 Lima host ran Cuttlefish 1.57.0 with nested virtualization and Linux 6.8.0-134-generic. `host.json` records the `swiftshader` profile and a 2405-second capture. The normalized composite artifact contains `ap_composite_disk_config.txt`, `os_composite_disk_config.txt`, and `persistent_composite_disk_config.txt`; each retains the `crosvm` backend and redacts its host path. All 11 entries in the Lima manifest (ten normalized capture files plus `post-run-verification.json`) verified on the host. The seven reference-tool source hashes matched, and privacy scans of all ten capture files found no tested host paths, MAC/EUI-64 addresses, or PEM private-key markers.

  `launcher.log` records U-Boot at 15:00:40Z. `kernel.log` records Linux 6.12.74-android16 and first-stage init at guest uptime 41.572 seconds. Init requested the zygote service at 198.816 seconds and logged it started with PID 609 at 198.962 seconds. At 475.263 seconds, init successfully ran `setprop sys.bootstat.first_boot_completed 0`; this is not `sys.boot_completed=1` and does not establish full boot. The observer recorded 481 crosvm memory events, 480 with valid RSS. VmRSS first reached 4 GiB at 15:10:46.896Z (4,215,460 KiB; RssShmem 4,193,788 KiB), peaked at 4,233,140 KiB, and remained at that value in the final sample at 15:40:36.896Z. These are residency observations, not proof of a full-RAM cache flush or its cause.

  The observer recorded Cuttlefish start event 5 at 15:18:07.987Z; its private ADB server was ready 51 ms later. Of 85 polls, three `get-state` commands exited 1 and 82 reported `device`. The first `connect` timed out; the remaining 84 exited 0. All 82 property queries timed out with exit -15 and produced no parsed values. The final events-buffer and Android diagnostic logcat queries each timed out with zero captured bytes; both clients completed cleanup. No `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or `sys.boot_completed=1` result was recorded. The 2400-second deadline expired, so the run remains incomplete and does not establish a boot cause. `MISSING.txt` notes that no crosvm command line matched at artifact-collection time, while the observer's earlier memory events confirm that crosvm had run. Post-run checks found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no listener on private port 6520, removal of the private HOME, and no composite-spec temporary files.
- **SwiftShader shell-marker follow-up (2026-10-03 UTC; normalized incomplete record: `Images/reference/16373615/incomplete/swiftshader-20261004T021050-1310893/`; see IR-152).** This run used Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4 LTS/aarch64, nested virtualization, and the `swiftshader` profile, with capture source revision `1f204c5e30a3017e234b0167b1ead99e2e43bfdc`. `host.json` records `captureDurationSeconds=2406`; this field excludes the later ADB and Cuttlefish teardown. The observer start-to-stop interval was 2400.118 seconds. The directory timestamp is Lima local time in Asia/Tokyo (`2026-10-04 02:10:50`), equivalent to `2026-10-03 17:10:50Z`.

  `kernel.log` records Linux `6.12.74-android16-6-g3ec022196c4e-ab15076761-4k`, first-stage init at guest uptime 22.412 seconds, zygote requested at 267.661 seconds and started at 683.660 seconds, and `sys.bootstat.first_boot_completed=0` at 602.524 seconds. The latter is not `sys.boot_completed=1`. The observer recorded 481 crosvm memory samples, 479 with valid RSS; RSS first reached 4 GiB at 16:34:02.400Z (4,216,204 KiB) and peaked at 4,233,284 KiB.

  Of 103 ADB polls, 100 reported `device` and three `get-state` commands exited 1. All 100 property queries had no parsed property values: 96 timed out with exit -15 and four exited 0. The first launched property query at 16:44:36.085Z also carried the one-shot shell marker; its client timed out with exit -15 before a matching marker was received. Its absence does not identify whether the shell reached the command or explain the timeout. The final events-buffer query exited 0 with 22,873 bytes and zero recognized process events. The separate Android diagnostic logcat query exited 0 with 19,779 bytes and counted four `system_server` mentions, 15 Watchdog mentions, and no ANR, fatal-exception, fatal-signal, or zygote mentions. These bounded counts do not establish process state or a cause. No `sys.boot_completed=1`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, or `VIRTUAL_DEVICE_BOOT_FAILED` marker was observed, so the run remains incomplete and is not a reference profile.

  Post-run checks found an empty Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`, no listener on private ADB port 6520, removal of the private HOME, and no capture-staging or composite-spec temporary files. At post-capture inspection, the separate shared ADB port 5037 had a listener; its pre-capture state was not recorded. All 11 entries in the Lima-side `LIMA-SHA256SUMS` verified both on Lima and the Mac; all seven reference-tool source hashes matched the recorded revision. Privacy scanning of the ten capture files found no tested host paths, MAC/EUI-64 addresses, or PEM private-key markers, and a second normalizer pass changed zero files. The missing shell marker and property replies do not establish a boot root cause.
- **Standalone SwiftShader shell-probe capture (2026-10-03 UTC; normalized incomplete record: `Images/reference/16373615/incomplete/swiftshader-20261004T034715-1337678/`; see IR-153).** This Cuttlefish 1.57.0 run used build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization and the `swiftshader` profile. Its source revision was `f2a152421003701302ceb64c9e2812221e839a33`; `host.json` records a 2404-second capture. The directory timestamp is Lima local time in Asia/Tokyo (`2026-10-04 03:47:15`), equivalent to `2026-10-03 18:47:15Z`.

  `kernel.log` records Linux 6.12.74, first-stage init at guest uptime 25.868 seconds, zygote requested at 197.258 seconds and started at 197.418 seconds, and `sys.bootstat.first_boot_completed=0` at 510.643 seconds. The latter is not `sys.boot_completed=1`. The observer recorded 481 crosvm memory samples, 480 with valid VmRSS; the maximum VmRSS was 4,233,228 KiB and maximum RssShmem was 4,205,908 KiB.

  Of 94 ADB polls, 91 reported `device` and three `get-state` commands exited 1. The poll record stamped `2026-10-03T18:23:27.943Z` records the one standalone shell-probe attempt; it timed out with exit -15, returned no marker, and completed process-group cleanup. The probe's start time was not recorded. Of 90 property queries, 88 timed out with exit -15 and two exited 0; none produced an accepted `sys.boot_completed` or `sys.system_server.start_count` value. The result shows that this timeout was not limited to the `getprop` query, but does not establish whether the guest shell began executing the probe.

  The final events-buffer query exited 0 with 23,714 bytes and zero recognized process events. The separate Android diagnostic logcat query exited 0 with 19,825 bytes and counted two `system_server` mentions, ten Watchdog mentions, and seven zygote mentions; it recorded zero ANR, fatal-exception, or fatal-signal lines. These bounded counts do not establish process state or a cause. No `sys.boot_completed=1`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, or `VIRTUAL_DEVICE_BOOT_FAILED` marker was observed, so the capture remains incomplete and is not a reference profile. `MISSING.txt` notes that no crosvm command line matched at artifact-collection time; the observer's earlier memory samples confirm that crosvm had run.

  Post-run checks found an empty Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`, no listener on private ADB port 6520, removal of the private HOME, and no capture-staging or composite-spec temporary files. The post-run process scan found one host `adb` process in Linux state `S` with a `server` argument and procfs start time `2026-09-30T22:51:38Z`, before this capture. It had no capture-private path or local-socket argument, and neither port 5037 nor 6520 had a listener. No pre-capture process inventory was recorded; the verification left this process running and does not attribute it to this capture. All 11 Lima manifest entries and all seven source-file hashes matched on the Mac; privacy scans of the ten capture files found no tested host paths, MAC/EUI-64 addresses, PEM private-key markers, or oversized files. A second normalization pass changed zero files. The marker timeout and property results do not establish a boot root cause.
- **Pre-IR-156 target-mode mismatch (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261004T043330-1364484/`).** This 42-second Cuttlefish 1.57.0 run recorded `targetGpuMode=drm_virgl`, but its selected-instance config recorded `gpu_mode=guest_swiftshader` and `enable_gpu_vhost_user=false`; the launcher used the 2D GPU backend. The 10,308-byte kernel log ended at U-Boot's `Starting kernel ...`. The launcher logged transient ADB connections to `127.0.0.1:6520` followed by `device ... not found`; it did not establish a stable ADB-ready transport. `cvd-create-console.log` says `capture_cvd_start` could not confirm that the Cuttlefish process leader exited after SIGKILL. The artifact has no final process audit, so the cleanup state for this run is unknown. It is not `drm_virgl` evidence. The later selected-mode validation in IR-156 rejects this kind of mismatch.
- **2400-second requested-`drm_virgl` shell-probe capture (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261004T051544-1366201/`; see IR-156).** Cuttlefish 1.57.0 ran build 16373615 on the Ubuntu 24.04.4 LTS/aarch64 nested-virtualization host with source revision `61e5529ecac8545e81d3d9b3ecf1b57d8e67954c`. The Lima-local directory timestamp is 2026-10-04 05:15:44 in Asia/Tokyo, or 2026-10-03 20:15:44Z. `host.json` records the requested `targetGpuMode=drm_virgl`; the selected-instance config records `gpu_mode=guest_swiftshader`, so this run is not a `drm_virgl` comparison. Its pre-IR-156 capture tool passed the GPU flag only to `cvd create`.

  `cvd start` exceeded the 2400-second deadline; `host.json` records 2403 seconds. The observer recorded 481 crosvm memory samples, 97 ADB polls (94 `device`, three `commandFailed`), and one standalone shell probe. The probe timed out with exit -15 and no marker. Of 93 property queries, 91 timed out, two exited 0, and none produced an accepted boot or SystemServer property. The final events-buffer query captured 23,398 bytes with zero recognized events; the Android logcat summary counted one SystemServer mention and ten Watchdog mentions, with no ANR, fatal-exception, or fatal-signal lines. These observations do not establish a boot cause.

  Post-run checks found an empty Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`, no listener on port 6520, and no private CVD HOME or staging directory. All 11 Lima manifest entries verified on Lima and the Mac; all seven copied reference-tool hashes matched the recorded revision. Normalization changed zero files. Privacy scans of the ten capture files found no tested host paths, MAC/EUI-64 addresses, PEM private-key markers, or oversized files. The record remains incomplete and must not be compared with the SwiftShader capture.
- **`drm_virgl` host-graphics and backend diagnostics (2026-10-03 UTC; normalized records: `Images/reference/16373615/incomplete/target-20261004T060430-1393505/`, `target-20261004T061407-1394457/`, and `target-20261004T061552-1395715/`; see IR-157).** All three runs used Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4 LTS/aarch64, nested virtualization, and the capture-tool source at `780e620`. The selected config recorded `gpu_mode=drm_virgl` in each run. The first run, without `EGL_PLATFORM=surfaceless`, logged `Failed to initialize display`; all three logs also show that Cuttlefish auto-enabled vhost-user GPU on arm64 and `run_cvd` rejected `drm_virgl` with that backend. On the second run, `EGL_PLATFORM=surfaceless` let the EGL availability check pass, but Cuttlefish logged that `libGLESv2.so` could not be loaded by its direct GLES checks. The Lima VM then received `libgles2-mesa-dev` 25.2.8-0ubuntu0.24.04.4; on the third run, with the same EGL setting, Cuttlefish reported GLES 3.2 from Mesa 25.2.8 llvmpipe. `cvd start` still failed in `BuildVhostUserGpu` with `GPU mode drm_virgl not yet supported with vhost user gpu`, returned 10, and cleaned up the group. Each capture lasted six or seven seconds, so none contains guest-boot evidence or supports a GPU-profile comparison. The host graphics checks do not establish that the guest VirGL renderer works.
- **Corrected `drm_virgl` capture and crosvm crash (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261004T064521-1396609/`; see IR-157 and IR-158).** The capture used tool commit `7d555e7` (SHA-256 `49a2c93b2d8518b236c500e1f7b8e50a162f81089e17fab4c8d3a54ab3968f14`), Cuttlefish 1.57.0, build 16373615, `EGL_PLATFORM=surfaceless`, and `APKRUN_TARGET_GPU_MODE=drm_virgl`. `host.json` and the selected-instance config both record `drm_virgl` with `enable_gpu_vhost_user=false`; Mesa EGL/GLES availability checks passed. At 21:45:18Z, the launcher records `process_restarter` PID 1397147 starting crosvm PID 1397163 with `backend=virglrenderer`; it reports that child's unexpected exit at 21:45:20Z. The Apport report names `/usr/lib/cuttlefish-common/bin/crosvm`, is dated 21:45:18Z, and its unpacked `ProcStatus` lists `Name=crosvm`, `Pid=1397163`, and `PPid=1397147`, matching the launcher child and parent. Cuttlefish reported `VIRTUAL_DEVICE_BOOT_FAILED`. Apport recorded SIGSEGV; GDB 15.1 located the fault at `unw_get_reg+68` in `libgfxstream_backend.so`, with `si_addr=0x10` and a null-pointer read. The stripped crosvm frames leave the trigger unresolved, so this does not establish that Virgl caused the crash. `kernel.log` is empty and there is no stable ADB-ready transport or Android boot evidence. The repository retains only a sanitized backtrace summary; the raw core dump remains on the Lima reference host.
- **Short SwiftShader progress capture (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T065400-1398228/`).** This capture used a 180-second boot deadline and recorded 184 seconds total, with the same Cuttlefish build, host, guest resources, and capture-tool hash as the corrected target run. The selected config records `guest_swiftshader` and vhost-user GPU disabled. At the deadline, `kernel.log` contained 10,308 bytes/158 lines and ended at U-Boot's `Starting kernel ...`; the observer's final crosvm VmRSS sample was 3,025,596 KiB. The launcher log records repeated transient ADB connections followed by `device ... not found`, so it did not establish a stable ADB-ready transport; no successful guest command or Android boot-completion marker was recorded. After cleanup, `cvd fleet` was empty, no crosvm, `run_cvd`, or `process_restarter` remained, and port 6520 had no listener. The pre-existing loopback ADB server on port 5037 was left running. This shortened run does not establish a SwiftShader boot failure: the separate 2400-second capture `swiftshader-20261004T034715-1337678` reached Linux 6.12.74 and first-stage init, but also remained incomplete without `sys.boot_completed=1`. See IR-153.
- **2400-second SwiftShader Zygote-preload capture (2026-10-03 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T081603-1401833/`; see IR-159).** Cuttlefish 1.57.0 ran build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization, four guest CPUs, 4096 MiB memory, 4915 MiB DDR, `guest_swiftshader`, and `enable_gpu_vhost_user=false`. `host.json` records a 2403-second total capture. ADB shell commands returned, but `sys.boot_completed` and `init.svc.system_server` were empty while `init.svc.bootanim` was `running`; a sampled process list showed zygote and bootanimation but no `system_server` or `dex2oat`. Guest logcat recorded `boot_progress_preload_start` at uptime 1152.371 seconds and `Zygote: begin preload` at displayed guest-log time 23:01:46.350 (timezone not recorded). Later bounded logcat samples did not show preload completion or SystemServer start, while kernel logs continued to record failed lookups for `aidl/activity` through uptime 2017.375 seconds. Later host samples showed Android guest crosvm PID 1402437 using about 3.2–3.3 CPU equivalents. Separately, launcher records show the Cuttlefish OpenWrt crosvm sidecar reported a reset at 22:36:31Z, exited with reset, and was restarted by `process_restarter` at 22:36:33Z; this does not establish an Android crosvm crash or explain the boot state. `MISSING.txt` notes that no crosvm command line matched at artifact-collection time; the launcher and sampled processes identify Android crosvm separately from the sidecar. The capture expired before `sys.boot_completed=1` and remains incomplete, non-comparable, and without an established root cause. The sanitized summary notes that `APKRUN_CAPTURE_BOOT_OBSERVER` was not enabled, so the ADB/logcat observations are bounded manual samples rather than a complete time-series. After cleanup, `cvd fleet` was empty, no crosvm remained, ADB port 6520 had no listener, and the stale offline transport was disconnected; the ADB server on port 5037 remained listening and was not stopped.
- **Back off timed-out Android property probes (2026-10-04; see IR-160, IR-162, and IR-163).** In an interim snapshot of the active SwiftShader observer capture through guest uptime 1388.713 seconds, all 17 guest `SIGHUP` entries for untracked `(sh)` and `(printf)` processes aligned with ADB shell-query poll times within 0.85 seconds after one guest-to-host uptime alignment. This strongly associates repeated remote shell timeouts with those guest process entries but does not prove the origin of every process. The observer now retains 15-second `connect` and `get-state` checks while deferring property queries for 30 seconds after the first consecutive timeout and 60 seconds after the second and later timeouts; a property command that returns without timing out clears the backoff. `getpropRetryInSeconds` records the selected or remaining delay. On this Mac, the full Image tools suite passed 492 tests with four platform-specific skips, and the focused observer suite passed 108 tests with one Linux-only skip. Ruff lint and formatting, `git diff --check`, and all six repository checks passed. Final follow-up hostile review found no further actionable findings. The pre-change 3600-second capture used the original query cadence. The 1200-second post-change capture verified the recorded delay values while transport checks continued. A later 3600-second post-change capture recorded 40 timed-out property queries with the 30/60-second backoff and ongoing transport polling; see IR-163 for its boot evidence and limitations.
- **3600-second SwiftShader observer capture (2026-10-03/04 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T093436-1428464/`; see IR-161).** Cuttlefish 1.57.0 ran build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization. `host.json` records `guest_swiftshader`, vhost-user GPU disabled, four guest CPUs, 4096 MiB memory, 4915 MiB DDR, and a 3605-second duration. The Lima-local launcher log records U-Boot at 08:34:35 and Linux 6.12.74 at 08:39:30 (Asia/Tokyo local time); guest first-stage init started at uptime 42.457 seconds, second-stage init at 51.068 seconds, and zygote at 163.192 seconds. Kernel records include a `system_server` SELinux caller in servicemanager activity at guest uptimes spanning 1500.448 to 3220.737 seconds. Init records untracked `system_server` exits with status 0 at 1728.170, 3171.194, and 3286.382 seconds; the first two fall within the observed caller span and the third follows it. Zygote received SIGKILL at 2657.735 and 3290.371 seconds and restarted at 2674.477 and 3295.952 seconds. Repeated `aidl/activity` lookups continued through uptime 2875.698 seconds. These observations do not establish why `system_server` or zygote stopped; no boot-complete marker appeared.

  The observer saw start event 5 at 2026-10-03T23:45:14.204Z and its private ADB server ready 50 ms later. Of 192 polls, 189 reported `device`; 188 property queries ran, 168 timed out with exit status -15 and 20 exited 0, but none yielded an accepted system-server or boot-complete value. The one-shot shell-ready probe timed out. Final bounded logcat counts were zero recognized process events, 18 `system_server` mentions, ten Watchdog mentions, and zero ANR, fatal-exception, or fatal-signal lines; these counts do not identify a cause. The kernel log contains 174 `Untracked process` lines and 41 SIGHUP events (22 `sh`, 19 `printf`). The first 17 SIGHUP events, through guest uptime 1388.713 seconds, aligned with timed-out observer shell-query polls within 0.843 seconds after one guest-to-host time alignment. The later events do not all align within one second, so this does not establish that every untracked process came from the observer. Of 721 crosvm memory samples, 720 had valid RSS; VmRSS first reached 4 GiB at 2026-10-03T23:39:31.797Z and peaked at 4,234,368 KiB. The observer records that its private ADB server stopped with `cleanupComplete=true`; `MISSING.txt` says no crosvm command line matched the private Cuttlefish HOME at artifact-collection time. The artifact does not retain a complete fleet, process, or listener audit, so no broader host cleanup state is asserted here. The normalized capture and summary remain incomplete and non-comparable, with no established boot cause.
- **1200-second post-change SwiftShader observer capture (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T102250-1468492/`; see IR-162).** Cuttlefish 1.57.0 ran build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization and selected `guest_swiftshader`; vhost-user GPU was disabled. `host.json` records a 1205-second pre-teardown capture duration. The guest reached first-stage init at uptime 51.195 seconds and zygote startup at 199.255 seconds, but kernel logs contain no `system_server` line or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker. All property queries timed out, so the guest's `sys.boot_completed` value at the deadline is unknown.

  Observer start event 5 was recorded at 2026-10-04T01:11:38.543Z and the private ADB server became ready 51 ms later. Across 40 polls, 37 `get-state` results were `device` and three were `commandFailed`; all polls attempted `connect`, with 39 returning 0 and one timing out. Eight property queries all timed out with exit status -15. The first timeout recorded `getpropRetryInSeconds=30`; the next seven recorded 60. Twenty-eight scheduled polls deferred property queries while transport checks continued. Property-query-attempt poll records were about 45 seconds apart after the first timeout and about 75 seconds apart thereafter; these timestamps are emitted after bounded commands return, so they do not establish query-start intervals. The final Android logcat query timed out; the bounded summary counted zero recognized process events and ten Watchdog mentions, which do not establish a cause.

  The kernel log contains six untracked-process lines, including two SIGHUP events for `sh` at guest uptimes 458.934 and 810.116 seconds. Their source is unconfirmed, so this shorter run does not prove that backoff reduced guest shell activity. The observer records its private ADB server stopped with `cleanupComplete=true`. A read-only host audit at 2026-10-04T01:24:52Z found no Cuttlefish groups, `crosvm`, `run_cvd`, `process_restarter`, or `cvd_server` processes, and no listener on port 6520. At audit time, loopback port 5037 had an ADB listener at PID 2704; no stop command was issued for it. No pre-capture identity check was retained, so the audit does not establish continuity during the capture. The deadline expired without a successful boot-completion observation; the guest property value is unknown. The record remains diagnostic, incomplete, and non-comparable.
- **3600-second post-change SwiftShader observer capture (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T114734-1483038/`; see IR-163).** Cuttlefish 1.57.0 ran build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization and selected `guest_swiftshader`; vhost-user GPU was disabled. The selected instance config records four guest CPUs and 4096 MiB of memory. `host.json` records a 3603-second pre-teardown capture duration. Cuttlefish start event 5 appeared at 2026-10-04T01:57:37.270Z, and the private ADB server became ready 51 ms later. The shared deadline expired while the Cuttlefish create/start command was still running; the capture was retained as incomplete and no guest command list was run.

  The observer recorded 195 transport polls: 192 `get-state=device`, three `commandFailed`; all attempted `connect`, with 194 exit status 0 and one timeout. Forty-eight property queries ran: 40 timed out with exit status -15, while eight returned exit status 0 but yielded no accepted parsed property fields. The guest's `sys.boot_completed` value is therefore unknown. On timed-out property queries, the observer recorded a 30-second retry delay for the first timeout in each consecutive-timeout streak and 60 seconds for later timeouts; 147 poll records did not attempt a property query. The one-shot shell-ready probe timed out. The bounded events-buffer query returned 17,948 bytes but recognized no process events; the separate Android logcat query timed out with zero captured bytes.

  Kernel logs record first-stage init at uptime 47.496 seconds and zygote startup at 209.251 seconds. Servicemanager records system_server callers from uptime 1737.851 through 3345.618 seconds. Init recorded untracked `system_server` exits with status 0 at 1940.390, 2759.823, and 3186.678 seconds; zygote received SIGKILL at 2767.776 and restarted at 2775.947 seconds. These events do not establish why the processes exited or why zygote was killed. The capture contains no `VIRTUAL_DEVICE_BOOT_COMPLETED` marker.

  The kernel contains five untracked-process SIGHUP events: four for `sh` and one for `printf`, at guest uptimes 939.071, 2049.115, 2273.782, 2633.587, and 3278.964 seconds. Their source is unconfirmed. Through uptime 800 seconds, the pre-change 3600-second run recorded five such events, the 1200-second post-change run recorded one, and this post-change run recorded none. This pattern is consistent with reduced guest shell activity after the property-query backoff, but the independent runs do not establish causation.

  The observer records its private ADB server stopping with `cleanupComplete=true`. A read-only audit at 2026-10-04T02:52:12Z found an empty Cuttlefish fleet, no `crosvm`, `run_cvd`, `process_restarter`, or `cvd_server` processes, and no listener on port 6520. Loopback port 5037 had an ADB listener at PID 2704; no stop command was issued for it. The audit is point-in-time and has no pre-capture PID observation. `MISSING.txt` separately records that no crosvm command line matched the private Cuttlefish HOME at artifact-collection time. The normalized record remains incomplete and non-comparable, with no established boot cause.
- **3600-second SwiftShader bounded property-response capture (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T133202-1522663/`; see IR-165).** Cuttlefish 1.57.0 ran build 16373615 on Ubuntu 24.04.4 LTS/aarch64 with nested virtualization, four guest CPUs, 4096 MiB memory, `guest_swiftshader`, and vhost-user GPU disabled. The capture source was `f73bb3a`. Because Lima mounted the checkout read-only, the seven reference-tool files and pinned manifest were copied into a writable VM-local staging tree; all eight staged hashes matched the checkout. The eight digests are retained in `capture-source-sha256.txt`, and a fresh writable Lima staging copy reproduced them. The shared 3600-second deadline expired while Cuttlefish create/start was still running, so no guest command list ran and the record remains incomplete and non-comparable.

  The observer recorded 197 ADB polls: 195 `get-state=device` and two `commandFailed`; its private ADB server became ready 51 ms after Cuttlefish start event 5. Of 54 property queries, 39 timed out with exit status -15 and 15 exited 0. Response sizes were 31 at 0 bytes, seven at 46 bytes, and 16 at 90 bytes. All 54 were unparsed; neither `sys.boot_completed` nor `sys.system_server.start_count` was accepted, so both values remain unknown. Raw property output was discarded. The shell-ready probe also timed out. The final events query captured 22,862 bytes with zero recognized events. The separate logcat query returned 18,289 bytes and counted two `system_server` mentions and six Watchdog mentions, with no ANR, fatal-exception, or fatal-signal lines; these bounded counts do not establish a cause.

  `kernel.log` shows Linux first-stage init at uptime 57.672 seconds and zygote startup at 206.374 seconds. Servicemanager records `system_server` callers from 1597.582 through 3454.868 seconds. Init recorded an untracked `system_server` exit with status 0 at 1798.486 seconds. A watchdog-issued SysRq at uptime 2465.850 requested blocked-state and memory dumps; zygote received SIGKILL at 2487.490 seconds and restarted at 2497.959. Init recorded another untracked `system_server` exit with status 0 at 2886.400 seconds. At 3245.973 seconds the watchdog task issued another SysRq. The 3247.400-second blocked-state dump shows `system_server` in D state with a stack through `rwsem_down_write_slowpath`, `down_write_killable`, and `do_mprotect_pkey`. At the captured kernel revision, [`do_mprotect_pkey`](https://android.googlesource.com/kernel/common/+/3ec022196c4e9d5c1434599cdda63f622dd6f586/mm/mprotect.c#744) calls `mmap_write_lock_killable(current->mm)`, so this operation was waiting for that address space's mmap write lock; the dump does not identify its holder. A concurrent memory snapshot reports 232,172 kB free in Normal and 1,989,308 kB in DMA32, which does not show low free memory at that instant. An all-CPU NMI snapshot at 3248.822 records the same PID 4364 as the current CPU 1 task with a user-space program counter, so this capture does not show that the D-state persisted. Zygote received SIGKILL again at 3271.995 seconds; libprocessgroup removed PID 4364's cgroup at 3274.415, and untracked `system_server` PID 5070 received SIGKILL during that cleanup at 3277.543, before zygote restarted at 3277.772. No `VIRTUAL_DEVICE_BOOT_COMPLETED` marker appears. This run reached Linux and Android startup and does not reproduce a halt in U-Boot; it does not establish a causal link between U-Boot and the later stall.

  The observer recorded 721 crosvm memory samples, 720 with valid VmRSS, peaking at 4,234,536 KiB. Its private ADB server stopped with `cleanupComplete=true`. The read-only post-capture audit found an empty Cuttlefish fleet, no listed Cuttlefish processes, no private CVD HOME matching the capture prefix under `/tmp`, and no port 6520 listener. A loopback ADB listener remained on port 5037; it was not stopped, and the point-in-time audit does not establish whether it predated this run. The normalized record contains 14 files; all ten captured-artifact hashes and eight capture-source hashes verify, a second normalization pass changed zero files, and the tested host-path, private-key, EUI-48, and EUI-64 scans passed. It remains diagnostic evidence, not a reference profile.
- **Unresolved SystemServer investigation from IR-165.** The 3247.400-second D-state sample was followed 1.4 seconds later by a user-space CPU snapshot, so it does not establish a persistent lockup. The observed `mprotect` path waits on `current->mm`'s mmap write lock, but the owner remains unknown. Keep this separate from the later guest EGL failure; neither observation establishes the cause of the other.
- **Early SwiftShader boot failure after IR-166 (2026-10-04; normalized record: `Images/reference/16373615/incomplete/swiftshader-20261004T174319-1563170/`; see IR-167).** The capture used source commit `ef70045`, build 16373615, Cuttlefish 1.57.0, Ubuntu 24.04.4 arm64 with nested virtualization, `guest_swiftshader`, and vhost-user GPU disabled. After 447 seconds, `cvd start` reported `VIRTUAL_DEVICE_BOOT_FAILED`, `run_cvd returned 10`, and exit status 255. `kernel.log` contains U-Boot, Linux, and init service startup through guest uptime 317.057 seconds, but no `system_server`, blocked `do_mprotect_pkey` trace, kernel panic, or OOM marker. The observer matched the `Start event (5) received.` marker emitted by `socket_vsock_proxy`; all three ADB `get-state` probes returned `commandFailed`, so no property or SystemServer thread snapshot was collected. The launcher records the proxy failing to bind TCP port 6520 ten times and aborting with `SIGABRT`; the critical-process monitor then stopped the remaining monitored processes, followed by `run_cvd` and `VIRTUAL_DEVICE_BOOT_FAILED`. An ADB fork-server listener had started at 17:41:29 JST, before the bind retries from 17:42:41 through 17:42:52; launcher entries also show ADB connections to `127.0.0.1:6520` during that window. A port collision is likely, but the log reports bind error `0`, and the listener's provenance and exact bind errno remain unknown. This failure sequence does not establish an Android root cause. Cuttlefish also logged the known logical-partition geometry warning, whose causal role remains unproven. Keep this as incomplete, non-comparable evidence; it neither satisfies the reference-profile criteria nor identifies the Android boot failure's cause. The observer's private Unix-socket ADB cleanup reported success. The separate port 6520 listener remained after CVD cleanup; no pre-run port inventory exists. After verifying the fleet and listed Cuttlefish processes were empty, `adb -P 6520 kill-server` was issued and a follow-up audit found no 6520 listener. The listener's process command identifies it as an ADB fork-server, but its parent and provenance are unknown. The separate port 5037 listener was left running. `LIMA-SHA256SUMS` preserves all ten captured-artifact hashes; the post-run audit and port start-time evidence are in `post-run-verification.json`. A second normalization pass changed zero files.
- **Target `drm_virgl` prerequisite failure (2026-10-04; normalized record: `Images/reference/16373615/incomplete/target-20261004T180433-1573318/`; see IR-168).** The capture used source commit `ef70045`, build 16373615, Cuttlefish 1.57.0, Ubuntu 24.04.4 arm64 with nested virtualization, `drm_virgl`, and vhost-user GPU disabled. `host.json` records an 8-second capture duration; Cuttlefish reported `VIRTUAL_DEVICE_BOOT_FAILED`, `run_cvd returned 10`, and exit status 255. `assemble_cvd.log` records `PopulateEglAndGlesAvailability: Failed to initialize display` and Cuttlefish's warning that `drm_virgl` prerequisites were not detected. The host inventory found no `virglrenderer` executable or library visible to `ldconfig`, and no virglrenderer pkg-config module. A read-only check before changing the VM confirmed `libgles2-mesa-dev` was installed, but `libvirglrenderer1` was not installed; the capture invocation also did not set `EGL_PLATFORM=surfaceless`. The tested Lima VM has no `/dev/dri`, which [environment setup](../../05-development/environment-setup.md) §3.3 documents as expected; that absence alone does not show VirGL is unavailable. Section 3.3 prescribes installing `libgles2-mesa-dev` and setting `EGL_PLATFORM=surfaceless` to let Cuttlefish initialize Mesa off-screen EGL and pass its host GLES check, while explicitly noting this does not guarantee the guest or backend will start. This attempt preceded the documented `EGL_PLATFORM=surfaceless` setting. The package check and linker-cache inventory do not establish whether a compatible library existed elsewhere on the host or whether the VM can run `target` after those prerequisites are completed. Launcher logs identify the monitored process role as `process_restarter` configured for `crosvm run` with the virglrenderer backend; the `crosvm` executable path is redacted. The launcher logs record `si_code: 3` and the `process_restarter` exit code 1, but do not identify the child signal. The sanitized Apport/GDB summary records SIGSEGV and the fault site for this first attempt (IR-170), while the original trigger remains unknown. The graphics warnings and inventory are consistent with a graphics setup failure, but do not prove what caused the monitored process to exit. `kernel.log` is empty, the observer saw no start event 5, and no ADB poll ran, so this provides no guest boot evidence. The documented `guest_swiftshader` target fallback was not attempted because the required pinned `bootconfig_args.cpp` revision and source-derived graphics-properties file were unavailable in the checkout. The post-run audit found an empty Cuttlefish fleet, no listed Cuttlefish processes or temporary CVD HOME, and no port 6520 listener; the separate port 5037 listener remained running and was not stopped. `LIMA-SHA256SUMS` verifies all ten captured artifacts and the post-run audit, a second normalization pass changed zero files, and the tested host-path, PEM-header, EUI-48, and EUI-64 scans found no matches. Keep the record incomplete and non-comparable; it is evidence about this reference-host attempt, not a valid target profile or a proven Android/GPU root cause.
- **3600-second default observer capture (2026-10-04; normalized record: `Images/reference/16373615/incomplete/default-20261004T192056-1574666/`; see IR-169).** The capture used source commit `ef70045`, Cuttlefish 1.57.0 on Ubuntu 24.04.4 arm64 with nested virtualization, selected `guest_swiftshader`, and vhost-user GPU disabled. The create/start deadline expired at 3600 seconds; `host.json` records a 3604-second duration at `capture_finished_at`, before the script's explicit ADB disconnect and Cuttlefish group removal. `cvd-create-console.log` records Cuttlefish receiving a termination signal during cleanup, and `MISSING.txt` records the deadline. The observer detected `socket_vsock_proxy`'s `Start event (5)` at 2026-10-04T09:33:09.044Z for the TCP 6520 to vsock 3:5555 proxy; subsequent log lines show connection failures to vsock 3:5555. This is a proxy event, not Android boot readiness. The private ADB server became ready 51 ms after the marker. Across 185 ADB polls, 183 returned `device` and two returned `commandFailed`. Of 44 property queries, 36 timed out with exit status -15 and eight exited 0, but none parsed an expected field; responses were 0 bytes (35), 46 bytes (1), and 90 bytes (8). `sys.boot_completed` and `sys.system_server.start_count` remain unknown. The one-shot shell marker timed out. No thread snapshot was attempted, and the kernel log has no `do_mprotect_pkey`, panic, or OOM marker. It reaches guest uptime 3309.094 seconds; untracked `system_server` processes exited with status 0 at uptimes 1761.684 and 2842.050, while 36 `crash_dump64` mentions and later SystemServer service lookups do not establish why either process exited or whether either exit was causal. The bounded Android logcat query captured 17754 bytes with two SystemServer mentions and no ANR or fatal exception/signal lines; the separate events query captured 23067 bytes and recognized no process events. The startup logical-partition geometry warning remains unconnected to the later state. No `VIRTUAL_DEVICE_BOOT_COMPLETED` or `VIRTUAL_DEVICE_BOOT_FAILED` marker was captured, so the run is incomplete and non-comparable. The post-run audit found an empty Cuttlefish fleet, no checked Cuttlefish processes or temporary HOME, and no port 6520 listener. The existing port 5037 ADB listener (PID 2704) remained running and was not stopped. `LIMA-SHA256SUMS` verifies all ten captured artifacts and the post-run audit; a second normalization pass changed zero files, and the tested host-path, PEM-header, EUI-48, and EUI-64 scans found no matches. `MISSING.txt` also notes that no crosvm process matched the private HOME at artifact-collection time, which does not establish whether it ran earlier.
- **Post-setup target `drm_virgl` retry (2026-10-04; normalized record: `Images/reference/16373615/incomplete/target-20261004T192939-1614388/`; see IR-170).** The retry used source commit `ef70045`, Cuttlefish 1.57.0, Ubuntu 24.04.4 arm64 with nested virtualization, `drm_virgl`, and vhost-user GPU disabled. It ran after installing `libvirglrenderer1` and setting `EGL_PLATFORM=surfaceless`; `libEGL.so`, `libGLESv2.so`, and `libvirglrenderer.so.1` were visible to `ldconfig`. Unlike the earlier attempt, `assemble_cvd.log` contains no EGL initialization failure or missing-prerequisite warning, and `launcher.log` starts crosvm with `backend=virglrenderer`, `egl=true`, `surfaceless=true`, and `gles=true`. `host.json` records a 9-second capture duration; the retry failed with `VIRTUAL_DEVICE_BOOT_FAILED`, `run_cvd returned 10`, and exit status 255. The observer saw one crosvm memory sample for PID 1614918 at 19,780 KiB VmRSS, but no start event 5 or ADB poll; `kernel.log` is empty. `process_restarter` PID 1614891 logged `si_code: 3` for its child and exited with code 1. This Linux code is `CLD_DUMPED`, but the log does not provide the child signal number. `/var/log/apport.log` records that Apport suppressed a new report because the first crosvm report still existed and was unseen. The capture therefore provides no guest boot evidence and does not establish the crosvm crash cause. The post-run audit found an empty Cuttlefish fleet, no checked Cuttlefish processes or temporary HOME, and no port 6520 listener. The existing port 5037 ADB listener (PID 2704) remained running and was not stopped. All ten capture artifacts and the post-run audit verify against `LIMA-SHA256SUMS`; the record remains incomplete and non-comparable.
- **Panic-hook diagnosis and Virgl build-feature failure (2026-10-04; normalized records: `Images/reference/16373615/incomplete/target-20261004T211540-1617589/`, `.../target-20261004T212141-1619115/`, and `.../target-20261004T212512-1620453/`; see IR-171).** The first unpreloaded run records a SIGSEGV in `unw_get_reg+68` while the crosvm panic hook was collecting a backtrace; its sanitized summary records relative offsets for that run's stripped crosvm caller frames. These offsets belong to PID 1618196 and do not identify the callers for PID 1573779 in the separate IR-170 capture. The second run did not apply the wrapper: `cvd create` received the override, but `cvd start` used its default, and the log marker and `LD_PRELOAD` are absent. `capture.sh` now passes the override to both commands. The third run records the marker and recovered the panic `Failed to create virtio gpu worker thread: invalid rutabaga build parameters`, followed by SIGABRT. Pinned Cuttlefish/crosvm/Rutabaga source confirms that the host package disables crosvm's `virgl_renderer` feature while requesting `backend=virglrenderer`; see IR-171 for source references and reasoning. The third run produced no guest kernel output or Android boot evidence. A read-only Lima audit at 2026-10-04T12:43:14Z found an empty Cuttlefish fleet, no checked crosvm, `run_cvd`, `process_restarter`, or `cvd_server` process, and no port 6520 listener. The existing loopback ADB listener on port 5037 (PID 2704) remained running and was not stopped. All nine captured artifact hashes in each record match the Lima originals; raw Apport reports and cores were kept private on Lima.
- **Feature-enabled Virgl target attempts (2026-10-04; normalized records: `Images/reference/16373615/incomplete/target-20261004T232534-1622675/`, `target-20261004T233833-1630294/`, and `target-20261004T235047-1637967/`; see IR-171).** A diagnostic crosvm was built from the pinned Cuttlefish/crosvm source with `virgl_renderer` enabled. Its build used temporary dependency/cache adjustments and is not a reproducible canonical host package. The first attempt omitted `EGL_PLATFORM=surfaceless` and logged that host EGL/GLES prerequisites were not detected. Although the Virgl backend was configured and the kernel reached init, that run does not establish a valid Virgl guest path. The following two explicitly set that variable and reached Android init/APEX work, but each hit the 600-second deadline without ADB readiness, a confirmed zygote process start, `system_server`, or boot completion. The third kernel log imports and parses zygote init configuration files; that alone does not show the zygote process started. Its final retained init records show `odsign` starting at guest uptime 200.727 seconds, receiving PID 594 at 200.832 seconds, and the `start odsign` action succeeding after 116 ms at 200.836 seconds. No later kernel-log line establishes the service's eventual outcome, so this does not show that `odsign` caused the stall. Its observer made 121 crosvm memory polls, all with `candidateCount=0` and `identity=unavailable`, so no crosvm memory measurements were recorded; it also recorded no ADB state events. The older Lima checkout produced schema-version-1 `host.json` records without an `eglPlatform` field, even though the setting was explicit in the latter two invocations. The current capture script now sets and records `EGL_PLATFORM=surfaceless` automatically for `target`/`drm_virgl` and clears inherited `EGL_PLATFORM` for other profile and GPU-mode combinations. The nine, nine, and ten files in these records match their Lima-side `LIMA-SHA256SUMS` manifests; a second normalization pass changed zero files in each record. Post-run checks found an empty Cuttlefish fleet, no crosvm, `process_restarter`, or `run_cvd` process, no port 6520 listener, and no private capture HOME. The pre-existing ADB server PID 2704 remained running and was not stopped. All three records remain incomplete and non-comparable.
- **Feature-enabled target run and guest EGL failure (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261004T161206Z-1646389/`; see IR-172).** The 1200-second target run used the current capture tools from commit `74de6953ede33f0bbad6e0a330609f4ee6603f1d`, Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4 arm64 with nested virtualization, `gpu_mode=drm_virgl`, `enable_gpu_vhost_user=false`, and `EGL_PLATFORM=surfaceless`. The diagnostic crosvm launcher v4 had Build ID `faf3eaf415ce2d1fc6c90f5090a9e82ba8abccab` and SHA-256 `d09e4a87ac8d174d9925bcedd0ff2d77f138f63f00c6eff9bbc1c7865e33c819`; the crosvm and gfxstream hashes and Build IDs are in IR-172. This build is diagnostic-only and not reproducible as the canonical Cuttlefish host package.

  The guest kernel initialized `virtio_gpu` with `+virgl`; Android first-stage
  init ran and zygote was requested at approximately guest uptime 184.5
  seconds. The guest reported `ro.hardware.egl=mesa`; pinned Cuttlefish source
  commit `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d` intentionally sets
  `androidboot.hardware.egl=mesa` for `GpuMode::DrmVirgl`, matching the saved
  internal bootconfig. The inspected `/vendor/lib64/egl` directory contained
  only emulator EGL/GLES libraries and `/system/lib64/egl` was absent.
  `libEGL` reported that it could not load
  drivers for `mesa` and could not find an OpenGL ES implementation. Manual
  ADB logcat samples showed SurfaceFlinger repeatedly aborting during EGL/
  Skia GL renderer creation, followed by zygote restarts, from approximately
  guest uptime 434 through 849 seconds. The saved `kernel.log` records a
  later SurfaceFlinger SIGABRT at guest uptime 983.431 seconds, its
  "exited 4 times before boot completed" event at 983.714 seconds, and a
  restart at 988.033 seconds; those later kernel records do not retain the
  EGL error from the ADB samples. The sampled `sys.boot_completed` query
  returned an empty value, and no `sys.boot_completed=1` value was observed
  or accepted. No successful `system_server` startup or
  `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was established. The sanitized
  guest-side observations are in `guest-egl-diagnostic.txt`; this is a
  manual partial diagnostic, not the scripted guest capture.

  Treat the guest EGL selection and available libraries as an observed mismatch and the best current explanation for the SurfaceFlinger aborts, pending image-source confirmation. The log does not establish why the image has that configuration, prove that Virgl produced frames, or explain every remaining boot issue. Do not change the canonical target profile or claim G3 from this run. Before post-capture serial redaction, all nine copied capture artifacts matched `LIMA-SHA256SUMS`; the original manifest remains unchanged. After redaction, the other eight artifacts still match that manifest, the original launcher input hash is recorded in `post-capture-normalization.json`, and all 14 entries in `POST-NORMALIZATION-SHA256SUMS` verify. The capture-source manifest matches the recorded checkout, and a second normalization pass changed zero files. The tested host-path, private-key, and MAC-address scans found no matches. A post-run audit found an empty Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`, no private CVD HOME or capture staging directory, and no listener on port 6520. The post-run audit found the shared ADB server PID 2704 listening on port 5037; the later device inventory was empty. The record remains incomplete and non-comparable.
- **SwiftShader target fallback after IR-172 (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261004T165409Z-1660660/`; see IR-173).** The 1200-second capture selected `guest_swiftshader` with vhost-user GPU disabled and recorded Cuttlefish revision `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`. Linux first-stage init began at guest uptime 50.532 seconds, `virtio_gpu` initialized at 54.189 seconds, zygote started at 170.018 seconds, and SurfaceFlinger started at 304.618 seconds. `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` appeared at 418.578 and 454.875 seconds. The kernel log continued through guest uptime 1070.062 seconds, repeatedly recording `servicemanager` and init failures to find `aidl/activity` after audioserver requests; these lines do not establish the state or cause of `system_server`. Cuttlefish `cvd start` exceeded the 1200-second deadline, so regular ADB polling and guest capture did not run. No `sys.boot_completed` query was made, and no `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was captured. The selected SwiftShader bootconfig has `androidboot.hardware.egl=angle` and `androidboot.opengles.version=196609`; the separate source-derived `drm_virgl` properties file records `mesa` and `196608`. This is expected for the fallback and does not show that the `drm_virgl` property file was applied to the SwiftShader guest. Keep the run incomplete and non-comparable; it does not establish guest rendering or a boot-completion result. After capture, the fleet and checked Cuttlefish processes were empty, the private CVD HOME and capture staging path were absent, and port 6520 had no listener. The post-run audit found shared ADB PID 2704 listening on 5037, and `adb devices` listed no devices. The 11 copied capture artifacts matched their Lima-side SHA-256 values before post-capture normalization repaired the loopback ADB serial in `launcher.log`; capture-source hashes were verified against checkout `74de6953ede33f0bbad6e0a330609f4ee6603f1d` before the post-capture normalization fix. The normalization repair and post-run audit are detailed in IR-174. Keep the incomplete record out of reference comparisons.
- **Observer-enabled SwiftShader target retry (2026-10-04 UTC; record: `Images/reference/16373615/incomplete/target-20261004T173358Z-1674431/`; see IR-175).** The 1200-second target capture ran for 1204 seconds with `guest_swiftshader` selected and vhost-user GPU disabled. First-stage init began at guest uptime 48.191 seconds, `virtio_gpu` initialized at 50.657, init started zygote at 178.792 and SurfaceFlinger at 366.012, and boot animation at 591.812. The kernel log records two display power-mode events and 162 `aidl/activity` interface-not-found requests from uptime 823.435 through 1071.385; it contains no `system_server`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, or `VIRTUAL_DEVICE_BOOT_FAILED` line. The observer received 36 ADB `device` states and three `commandFailed` states, but the one shell-readiness probe and eight property queries timed out without parsed properties; its final logcat query timed out before reading bytes. Its private ADB server stopped cleanly. No guest capture was produced, so this is incomplete evidence and does not establish boot completion or rendering. The post-run audit found an empty fleet, no checked Cuttlefish processes, no private HOME or staging directory, no port 6520 listener, and the shared ADB server PID 2704 still listening on 5037. The later review also found and repaired a missed ADB serial in the earlier Virgl record; both record repairs are in IR-174.
- **2400-second observer-enabled SwiftShader target capture (2026-10-04 UTC; record: `Images/reference/16373615/incomplete/target-20261004T182603Z-1688586/`; see IR-176).** This already-running capture completed with `host.json` recording 2404 seconds, but Cuttlefish exceeded the deadline and no guest command list ran. It selected `guest_swiftshader` with vhost-user GPU disabled. The kernel log records first-stage init at 61.569 seconds, `virtio_gpu` initialization from 61.954 to 63.564 seconds, init logging a request to start zygote at 212.081, followed by later start requests at 578.507 and 1972.653 seconds that reported zygote was already running. It contains two `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` markers and no boot-completed or boot-failed marker. The log records 751 `aidl/activity` interface-not-found requests from uptime 856.826 to 2048.362 seconds and eight `system_server` mentions from 1678.093 to 1906.001 seconds, including one exit-related line; neither establishes SystemServer readiness or a cause. The observer recorded 102 ADB polls (99 `device`, three without a state), 23 property queries (21 timed out: 20 captured zero bytes and one 46 bytes; two exited successfully with 90 bytes each), no parsed properties, a timed-out shell-readiness probe, and a final logcat timeout with zero bytes. The post-run audit found an empty fleet, no checked Cuttlefish processes, no private HOME or staging directory, no port 6520 listener, and no ADB devices; shared ADB PID 2704 remained running on port 5037. All 12 Lima artifact hashes, eight source hashes, JSON/JSONL parsing, normalization idempotence, and tested privacy scans verify. The crosvm binary identity was not captured. Do not repeat the same configuration without a material host or guest code/configuration change.
- **600-second observer-enabled SwiftShader profile capture (2026-10-04 UTC; record: `Images/reference/16373615/incomplete/swiftshader-20261005T055130-1716760/`; see IR-181).** The run selected `guest_swiftshader` with vhost-user GPU disabled and used capture source `fe08df8`. Cuttlefish exceeded the 600-second start deadline; the capture lasted 604 seconds. The observer identified crosvm in 119 memory samples, with `VmRSS` rising from 25,884 KiB to 3,073,168 KiB. It did not see start event 5, so its private ADB poller did not start. The retained `kernel.log` has no Linux version marker. `MISSING.txt` says guest capture and a crosvm command-line snapshot were unavailable at artifact collection; this does not establish that crosvm never ran or why the deadline expired. All 11 Lima-side artifact hashes match the local files, eight tracked source hashes match `fe08df8`, and the tested privacy scans found no matches. Keep the record incomplete and out of reference comparisons; it does not establish Android boot, rendering, an out-of-memory event, or a cause.
- **1200-second feature-enabled Virgl target retry (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261005T061754-1724643/`; see IR-179 and IR-180).** The run used capture source `fe08df8`, Cuttlefish 1.57.0 / VCS `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`, build 16373615, Ubuntu 24.04.4 arm64 with nested virtualization, `drm_virgl`, vhost-user disabled, and `EGL_PLATFORM=surfaceless`. It used the feature-enabled diagnostic crosvm override, so the run is not a canonical reference profile. The kernel log records `virtio_gpu` initialization at guest uptime 37.854 seconds, zygote startup at 294.205, and SurfaceFlinger startup at 625.092. It has no `system_server`, `aidl/activity`, or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker; no `sys.boot_completed` query was made. Cuttlefish start event 5 arrived late, at 2026-10-04T21:16:37.076Z, about 18 minutes 45 seconds after observer startup. No regular ADB polls followed. The final ADB connect timed out, `get-state` was not attempted, no logcat bytes were collected, and the activity-service probe did not run. This does not establish that the guest never reached ADB `device` state or identify why Cuttlefish startup exceeded the 1200-second deadline. All 241 crosvm memory samples were unattributed: a read-only process sample during the run showed the restarter requesting `crosvm-built-virgl-launcher`, while this capture's observer expected `crosvm`. The retained artifacts do not establish the child executable basename. Source inspection showed that the launcher sets `argv[0]` to adjacent `crosvm` before `fexecve`. IR-179 now supplies the staged command and resulting process executable as separate observer identities; the fix is covered by dedicated tests, but this older capture cannot validate it. After cleanup, the CVD fleet and checked processes were empty, the private CVD HOME and capture staging directories were absent, and port 6520 had no listener. The existing shared ADB server PID 2704 remained on loopback port 5037; no ADB command was issued to that shared server. All ten Lima-side artifact hashes matched the local files, the eight tracked source hashes matched `fe08df8`, four generated bytecode hashes matched, a second normalization pass changed zero files, and the tested privacy scans found no matches. See `post-run-verification.json` for the audit fields. Keep the record incomplete and non-comparable; it shows guest startup progress but not SystemServer readiness, boot completion, or rendered frames.


- **2400-second feature-enabled Virgl target capture (2026-10-04 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261005T082217-1740702/`; see IR-171 and IR-182).** The diagnostic-only `target` run used source commit `e5854d6`, Cuttlefish 1.57.0 / VCS `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`, build 16373615, `drm_virgl`, vhost-user disabled, and `EGL_PLATFORM=surfaceless`; its 2400-second deadline expired at 2403 seconds. Linux booted, `virtio_gpu` initialized at guest uptime 94.226 seconds, and zygote received PID 614 at 487.232 seconds. The retained kernel log reaches guest uptime 1030.825, and its last retained init record begins to start `misctrl` at 1027.830; it contains no SurfaceFlinger start, `system_server`, `sys.boot_completed` query, or virtual-device boot-complete/failure marker. No Cuttlefish start event 5 was observed, so the main observer made no ADB polls. Separately, `launcher.log` records 160 Cuttlefish `adb_connector` connection attempts, 160 connector log entries stating that an ADB connect message was successfully sent, and 159 each of `device not found` warnings and disconnects, interleaved across retries. The final attempt and message-send entry are logged at 23:22:03Z and 23:22:08Z; no warning or disconnect follows before `run_cvd` logs cancellation at 23:22:13Z. The log records 2285 WebRTC `Failed to connect:` messages from `vsock_connection.cpp`: 819 end in `OK`, 1466 report `UNAVAILABLE` with `Connection reset by peer`. It also has 2285 WebRTC `shared_fd.cpp` failures to connect to CID 3, port 6900. These helper logs do not show Android ADB `device` readiness or explain the failures; see IR-183. Its 481 crosvm memory samples all had `candidateCount=0` and `identity=unavailable`. A separately stored live sample from the patched observer at `7a2f7ff` identified PID 1741301 with 4,320,616 KiB VmRSS at 2026-10-04T23:11:56.607Z; it is not merged into the main observer log and does not retroactively validate that observer's samples. After cleanup the fleet and checked processes were empty, the private CVD HOME and staging directory were absent, and port 6520 had no listener. The dedicated ADB server on loopback port 5038 (PID 1740549) was stopped after its PID was verified; shared ADB PID 2704 on port 5037 remained running and was not queried or stopped. All 14 Lima-side manifest entries verify locally, eight tracked source hashes match `e5854d6`, the supplemental observer source hash matches `7a2f7ff`, a second normalization pass changed zero files, and privacy scans found no private paths, keys, EUI addresses, ADB endpoints, or oversized files. Keep this diagnostic run incomplete and non-comparable; it does not establish Android boot completion, rendering, or a boot failure cause.

- **Follow-up.** Keep #064 open for its pinned build 16373615 target. The recovered stock-crosvm panic matches its omitted `virgl_renderer` feature and required no matching debug symbols. The earlier SIGSEGV's occurrence during panic-hook backtrace collection is strongly supported, but its precise libgcc_s/LLVM binding and the proposed vtable-slot interpretation remain unproven; see IR-171. The feature-enabled diagnostic build passes that panic and reaches Android userspace, but its mutable dependency environment prevents treating it as a canonical host package. The `mesa` property is intentional for `drm_virgl` in the pinned Cuttlefish source, but IR-185 confirms this image lacks Mesa drivers in the preferred vendor directory and corresponding system EGL directory. Keep this target capture incomplete. A run with a corrected guest image is separate scope and needs independently recorded source provenance and tracked packaging work; do not substitute it for the pinned target. The SwiftShader target observations are recorded in IR-173, IR-175, and IR-176. The 2400-second IR-176 run extended the `aidl/activity` requests to guest uptime 2048.362 seconds and recorded eight `system_server` mentions, but neither result explains the stalled guest commands or establishes a causal link. A read-only inventory of build 16373615 found no `interface aidl activity` init declaration in the nine non-empty logical partitions, 93 bundled APEX payloads, or the combined `init_boot` and `vendor_boot` ramdisk; see IR-177 and [`aidl-init-inventory.json`](../../../Images/reference/16373615/aidl-init-inventory.json). The captured servicemanager warning explicitly allows that an unconfigured lazy service may still be starting, so the repeated `ctl.interface_start` failures do not establish a missing component or explain SystemServer readiness. If a later capture obtains guest shell access, start bounded guest logcat early enough to cover the first requests, then collect `service check activity`, `service list`, `pidof system_server`, and boot properties as soon as shell commands succeed. If shell readiness arrives after the first requests, those snapshots cannot establish the earlier service state. Do not repeat the same SwiftShader configuration without a material host or guest code/configuration change. Keep all diagnostic captures incomplete and non-comparable; do not change the canonical GPU profile or claim boot completion from an ADB `device` state, a Cuttlefish start event, or display power markers. Do not expand #064 into controlling the full Cuttlefish build environment; file a separate task if reproducible host-build work remains necessary. Do not compare diagnostic captures to canonical profiles. For IR-170's 2026-10-04 crash (PID 1573779), the exact Apport `ExecutablePath` is not retained in the sanitized summary; the non-root Lima check on 2026-10-05 found no crosvm report in the six visible `/var/crash` entries or crosvm entry in `/var/log/apport.log`, so that process's path remains unconfirmed. The separate 2026-10-03 report for PID 1397163 names `/usr/lib/cuttlefish-common/bin/crosvm`; do not generalize that path to PID 1573779. If the original private report for PID 1573779 becomes available, record only its `ExecutablePath` field. Keep raw Apport data and core files private. After complete captures for the three profiles are available, verify T3, marker timings, guest command execution, and the design findings in step 6.

- **Host-tool identity recording (2026-10-05; see IR-184).** `capture.sh` now writes SHA-256 and ELF Build IDs for the configured crosvm command and expected executable, plus the adjacent gfxstream candidate, to schema-version-3 `host.json`. The records contain no absolute paths, distinguish the configured executable from a live process, and label the shared library as a candidate rather than claiming it was loaded. A missing SHA-256 records `host-tool-identities` in `MISSING.txt` and prevents complete publication. The parser is tested with synthetic 32- and 64-bit ELF files in both byte orders.

- **Guest Mesa payload inspection (2026-10-05; see IR-185).** The manifest-pinned `super.img` was read-only inspected by logical partition. `vendor_a:/lib64/egl` contains only the three emulator EGL/GLES modules. In `system_a`, both `/lib64/egl` and `/system/lib64/egl` are absent, covering the possible `/system` and `/` mount locations; its `/system/lib64` contains no Mesa-named driver. This confirms the absence of Mesa drivers from the preferred vendor directory and corresponding system EGL directory in the pinned image, consistent with the live guest's EGL loader failure. Keep this target capture incomplete. Any run using a corrected guest image is separate scope and needs independently recorded source provenance and tracked packaging work.

- **Pinned Android shell syntax check (2026-10-05; see IR-186).** On the arm64 Lima host, the manifest-matching `system_a` and its `com.android.runtime` APEX were mounted read-only, and the image's actual `/system/bin/sh` parsed all 27 outer commands in `guest-capture.txt` plus its nine nested `su 0 sh -c` bodies with `-n -c`. An invalid-syntax control was rejected. The linker warned that the generated `/linkerconfig/ld.config.txt` was absent from the temporary chroot; the parser checks still succeeded. This verifies syntax compatibility only. It does not execute the commands or complete the acceptance criterion requiring live ADB and serial-shell runs.

- **Runtime libunwind binding check (2026-10-05; see IR-187).** The installed Cuttlefish package binaries match the Build IDs in the earlier crosvm crash record. In a `crosvm --help` process with `LD_BIND_NOW=1 LD_DEBUG=bindings`, the runtime loader binds crosvm's `_Unwind_GetIP` to `libgfxstream_backend.so` and `_Unwind_Backtrace` to `libgcc_s.so.1`; in a second process with the same settings and `LD_PRELOAD=libgcc_s.so.1`, it binds `_Unwind_GetIP` references from both crosvm and gfxstream to libgcc_s. This confirms the loader's symbol-binding change for those processes, but does not execute the panic hook or GPU worker. Together with the earlier crash's unwinder stack frames, this is consistent with a secondary fault during panic backtrace collection, but does not establish where the earlier SIGSEGV occurred. The preload capture in IR-171 already recovered the `invalid rutabaga build parameters` panic and ended with SIGABRT before guest kernel output; no duplicate VM boot was run.

- **Core availability check for the first crosvm crash (2026-10-06; see IR-224).** IR-170 records that the original Apport report and embedded core were retained on Lima at the time of capture. A non-root check found no crosvm report among six visible files in `/var/crash` and no files in `/var/lib/systemd/coredump`; `coredumpctl` was unavailable. Saved `ProcStatus` and `SignalName` files identify later crosvm PIDs 1618196 (SIGSEGV), 1620954 (SIGABRT), and 1619678 (SIGSEGV); IR-171 records caller offsets for the separate 1618196 capture. The attempted matching-name search under `/tmp` and `/var` was incomplete because protected directories denied access. This does not establish that the original report or core never existed or was deleted. No `crosvm+0x…` offsets are inferred for PID 1573779 from another process's core. The preload capture recovered the panic for a later run only; it does not identify the first crash's missing callers.

- **Passive Cuttlefish ADB connector summary (2026-10-06; see IR-225).** `boot_observer.py` aggregates four fixed `adb_connector` log messages into one shutdown summary, without retaining PIDs, serials, addresses, or raw lines. The parser runs without event 5 and makes no ADB connection. IR-225 originally gated active ADB polling on event 5; IR-233 supersedes that trigger while preserving the passive parser. Parsing the retained `target-20261005T082217-1740702/launcher.log` reproduced 160 connection attempts, 160 “message sent” records, 159 “device not found” responses, and 159 disconnect requests, with no detected log gap or event 5. These are Cuttlefish log counts and do not establish Android ADB readiness or explain the guest boot state.
- **Pre-event ADB transport observation (2026-10-06; see IR-233, IR-235).** The optional observer starts its private ADB server on the first complete, source-qualified connector attempt or event 5. It samples every 60 seconds before event 5; event 5 wakes the same poller and changes subsequent regular polls to 15 seconds. The final-probe reservation still suppresses regular shell and property polls. Shell diagnostics run only after `get-state=device`, and none of these signals establishes boot completion. `test_boot_observer.py` passed 175 tests with one Linux-only skip; Ruff lint and format checks passed. The first full image-tools run encountered `No space left on device`; after host space recovered, one complete-suite run exposed a timestamp-sensitive substring assertion, which IR-235 removes while retaining the focused PID allowlist and parser checks. The final full suite passed 597 tests with four platform-specific skips. Lima's guest SSH remained unavailable after a graceful restart, so no new reference capture or T2 guest verification was completed.
- **Installed crosvm package and exported unwinder symbols (2026-10-06; see IR-231).** Read-only `readelf` checks confirmed crosvm Build ID `d724bf54f045b0ec7dbe14049b0fed9a16e52a23` and gfxstream Build ID `6b8f3105442da5c66988881a1fa76e812b13c3e8`. The backend exports `unw_get_reg` and `_Unwind_GetIP`; crosvm lists both `libgfxstream_backend.so` and `libgcc_s.so.1` as dependencies. Three saved retry Apport metadata records identify `/usr/lib/cuttlefish-common/bin/crosvm` and `cuttlefish-base 1.57.0 [origin: android-cuttlefish]`; they concern later PIDs, not PID 1573779. These checks support the loader-interaction investigation but do not prove the first crash's exact runtime binding or root cause. No Cuttlefish boot or core-file access was performed.
- **Lima SSH retry after reported VPN disconnect and cache cleanup (2026-10-06 UTC; see IR-236).** After the user reported disconnecting the VPN, Lima's hostagent continued to probe `192.168.5.15:22`; its SSH forward at `127.0.0.1:61056` then logged `no route to host` for that address. Adding the per-instance `vzNAT` network did not change the hostagent's SSH destination. The route lookup for candidate `192.168.64.2` selected `en0`, and TCP probes both with the default source and bound to `192.168.64.1` timed out; the assigned guest IP was not verified. The `bootpd` firewall rule reports incoming connections permitted, while `serialv.log` is empty. `limactl start` reported that it did not receive its `running` status event, while `limactl list` continued to report the instance as running. These observations do not distinguish a guest boot failure from the hostagent's selected-address or route behavior; no Cuttlefish capture or T2 test ran. At the initial space check, `df -g` reported 148 GiB free, below the 150 GiB setup minimum. `lsof +D ThirdParty/out/work` reported no open files; that 70 GiB generated work cache was removed, while `ThirdParty/out/src`, `patched-src`, and `virgl-runtime` remain. The final disk check reported 351 GiB free and `ThirdParty/out` occupied 561 MiB. A later route check, with the VM stopped, sent `192.168.5.15`, `192.168.64.2`, `192.168.105.2`, and `192.168.104.2` through gateway `10.142.128.64` on `utun5`; the earlier `en0` route did not persist.
- **VZ NAT retry after reported VPN disconnect and host-route conflict (2026-10-07; see IR-236).** `scutil --nc list` reported Tailscale as disconnected, but global lookups for `192.168.5.15`, `192.168.64.2`, `192.168.105.2`, and `192.168.104.2` selected `utun5` via `10.142.128.64`. VZ NAT created `bridge100` at `192.168.64.1/24`; an interface-scoped lookup selected `bridge100`, while the ordinary lookup for `192.168.64.0/24` selected `utun5`. The owner of `utun5` and the guest's assigned address remain unknown. A TCP probe bound to `192.168.64.1` timed out against candidate `192.168.64.2:22`, which does not establish that the candidate is the guest's address. VZ reported the VM running, but `limactl start --timeout=180s` exited without receiving the `running` status event; `limactl list` still reported `Running`, the hostagent kept waiting for SSH at `192.168.5.15:22`, `serialv.log` remained empty, and `arp` showed no guest on `bridge100`. No guest boot state, SSH access, capture, or T2 result was established. The latest `df -g` check reported 390 GiB available; `ThirdParty/out` remains 561 MiB after removal of the 70 GiB generated work cache.
- **VPN-off SSH retry (2026-10-07; see IR-236).** An earlier route lookup for `192.168.5.15` selected gateway `100.64.0.1` on `en0`; the latest selected gateway `10.253.56.1`, also on `en0`. Candidate `192.168.64.2` selected `bridge100`. `limactl restart` exited without receiving its `running` status event, although `limactl list` reported the instance as `Running` with SSH forward `127.0.0.1:54899`. The latest `limactl shell apkrun-cuttlefish -- uname -a` ended with `kex_exchange_identification: read: Connection reset by peer`. The host-agent log still records no route to `192.168.5.15:22`, repeated SSH resets, and closed guest-agent events; `serialv.log` remains empty. These checks do not establish guest boot state or whether the fault is in the guest or Lima networking. No reference capture or T2 test ran, and no host route was changed.
- **Bounded guest capture and process cleanup (2026-10-07; see IR-237).** Guest ADB commands now share the remaining boot deadline and a cumulative 64 MiB raw-output budget; the compressed logcat artifact has a separate 64 MiB ceiling. Successful command output is staged atomically, and process groups are cleaned up after both normal and abnormal leader exits. Oversized bootconfig files are rejected before an unbounded read, and a private Cuttlefish HOME must be removed before a profile can be published. The final image-tools suite passed 610 tests with four platform-specific skips; focused guest-command and process-supervision tests passed 30 cases; Ruff, shell syntax, `git diff --check`, and `scripts/tests/run.sh` passed. No live reference capture or T2 guest test was possible because Lima SSH remained unavailable.
- **Lima root-filesystem recovery (2026-10-07; see IR-238).** The displayed initramfs reported an ext4 inconsistency on `/dev/vda1` and requested manual repair. A verified copy of the stopped Lima disk was attached to a separate rescue VM; its root partition was unmounted before `fsck.ext4 -f -y`. The repair corrected the orphan list and filesystem counters, and a forced read-only fsck then completed cleanly. The repaired disk image was byte-compared with the promoted Lima disk. The pre-repair backup remains preserved. `limactl start apkrun-cuttlefish` now reaches `READY`; systemd reports `running`, SSH and the Lima guest agent respond, and `launch_cvd` plus Cuttlefish `adb` are present. A stale Cuttlefish group is still listed as `Starting`, but its runtime directory and logs are absent and no Cuttlefish VM processes were found. This resolves the Lima SSH outage; it does not establish Android boot or complete any #064 profile.


- **Post-recovery Android boot captures and Virgl preflight (2026-10-07; see IR-239).**
  The first `default` capture could not create Cuttlefish instance 1 because the persisted registry
  reports an existing `apkrun_target_whuuql/1`; targeted removal failed with an invalid home and an
  active-instance error. To avoid the destructive global `cvd reset`, subsequent captures used
  instance 2. The 600-second `default` and `swiftshader` profiles both selected `guest_swiftshader`;
  neither exposed an ADB device. Their logs record 203 and 154 `aidl/activity` lookup failures
  attributed to `audioserver`, but do not establish why those requests failed or the cause of the
  boot stall.

  The stock `target`/`drm_virgl` capture stopped after seven seconds. Its crosvm Build ID
  `d724bf54f045b0ec7dbe14049b0fed9a16e52a23` matches the Cuttlefish 1.57.0 build diagnosed in IR-171
  as omitting Rutabaga's `virgl_renderer` feature. `process_restarter` reported its monitored child
  dumped (`si_code: 3`); `run_cvd` reports the monitored `process_restarter` exited with code 1.

  The feature-enabled diagnostic crosvm reached an ADB `device` state in 18 of 23 polls. The earlier
  provisional zygote diagnosis is corrected: the guest kernel log records 17 SurfaceFlinger starts,
  16 SIGABRT receipts, and no `system_server` start. After SurfaceFlinger aborts, init sends SIGKILL
  to the zygote process group as part of cleanup and the `surfaceflinger` `onrestart` action; there
  are 32 SIGKILL send records and 16 receipts. The `default` and `swiftshader` captures each show one
  SurfaceFlinger start and no SurfaceFlinger SIGABRT or zygote SIGKILL. The target log records one
  apexd revert attempt at uptime 309.221, which failed because no sessions were active. At that stage,
  the abort cause was still unknown. Guest graphics feature negotiation and discovery of the
  `drm_hwcomposer` APEX do not prove successful rendering.

  That earlier diagnostic did not retain Cuttlefish's host `logcat`; a later query against the Lima
  guest's default CVD home had no entries after the capture-specific home was removed. The new
  instance-2 capture at
  `Images/reference/16373615/incomplete/target-20261007T193655-32887/` confirms the real Cuttlefish
  1.57.0 `<group>:<instance>:logcat` listing and `instances/cvd-N/logcat` path. Its normalized
  `host-logcat.txt` contains five `libEGL` messages that the `mesa` driver selected by
  `ro.hardware.egl` could not be loaded, five SurfaceFlinger SIGABRTs, and five explicit abort
  messages saying that no OpenGL ES implementation could be found. This confirms the immediate
  guest-side cause: EGL could not load a GLES implementation. It is consistent with the pinned-image
  inventory in [IR-185](../implementation-review.md#ir-185-verify-mesa-driver-payload-in-the-pinned-cuttlefish-image),
  which found no Mesa EGL/GLES driver in the preferred vendor or system EGL paths. It does not prove
  that the host Virgl renderer initialized or that Android rendered a frame.

  The new run lasted 600 seconds without boot completion. The boot observer recorded 121
  `crosvm_memory` events, 119 for PID 33476 and two `unavailable` observations around runtime-path
  resolution and teardown. ADB reported `device` on 12 of 20 polls; no poll parsed
  `sys.boot_completed` or `system_server`, and three property probes timed out. `host.json` records
  the expected crosvm Build ID `1f6c03321061aa58e1d1ec0d0a1ff54f` and SHA-256
  `48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7`. The launcher log records
  the staged-input hash, and valid observer samples passed `/proc/<pid>/exe` `samefile` checks.
  `crosvm-runtime-identity.txt` contains only its header because no crosvm remained when artifacts
  were collected. The new observer code now records the live identity once per process generation,
  but this capture predates that instrumentation; a later live capture must verify the event.

  `capture.sh` identifies the expected crosvm ELF separately from its launch command, rejects the
  exact IR-171 Build ID when found in the expected ELF or an identifiable launch ELF, rehashes the
  expected ELF before both CVD commands, and compares each matching running process's
  `/proc/<pid>/exe` to the preflight hash. A launcher wrapper is allowed when its resulting crosvm
  ELF is configured explicitly; an observed mismatch keeps the capture incomplete. Other builds are
  diagnostic-only until reviewed, and the denylist makes no claim about other architectures or Build
  IDs. The guard does not infer Virgl support from a missing or present `libvirglrenderer.so.1`
  dynamic dependency.

  The six captures from this post-recovery sequence remain under `Images/reference/16373615/incomplete/`;
  host-logcat normalization redacts attestation identifier arrays as well as host paths, MAC addresses,
  and secrets. Port 5038's temporary ADB server and task-created Cuttlefish processes were stopped. The
  stale instance-1 registry entry remains untouched. #064 is still open and no profile is comparable.

- **Live crosvm identity and Mesa EGL diagnostic (2026-10-07 UTC; normalized record: `Images/reference/16373615/incomplete/target-20261008T030306-2167/`; see IR-244).** This 604-second run used capture source commit `3c0e413ddc49e18f684c55306d607f1c8ead906a`, the pinned Android build 16373615, Cuttlefish 1.57.0 / VCS `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`, Ubuntu 24.04.4 arm64 with nested virtualization, `drm_virgl`, and `EGL_PLATFORM=surfaceless`. The diagnostic crosvm override is uncertified for Virgl, so the capture remains incomplete and non-comparable. The observer recorded one live `crosvm_runtime_identity` event for PID 2677 with status `identified`, SHA-256 `48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7`, and Build ID `1f6c03321061aa58e1d1ec0d0a1ff54f`; both values match the preflighted expected executable. The separate `crosvm-runtime-identity.txt` contains only its header because the process had exited before artifact collection. `host.json` is schema version 3 and records path-free identities for the launch command, expected executable, and gfxstream candidate.

  Cuttlefish exceeded the 600-second startup deadline. ADB reported `device` in 13 of 20 observer polls; all three property probes timed out, and none parsed `sys.boot_completed` or a SystemServer value. The retained kernel log has no `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or `system_server` marker. `MISSING.txt` also records `crosvm-command-line.txt` as unavailable because no matching process remained at artifact collection. The normalized host logcat contains eight `libEGL` failures to load the `mesa` driver selected by `ro.hardware.egl`, eight fatal-signal/abort records, and eight abort messages stating that no OpenGL ES implementation could be found. This confirms the immediate guest EGL failure again; it does not show that the host Virgl renderer initialized or that Android rendered a frame.

  All 12 copied files matched their Lima-side SHA-256 values; per-file hashes and the post-capture verification receipt are in [`target-20261008T030306-2167.verification.txt`](../../../Images/reference/16373615/incomplete/target-20261008T030306-2167.verification.txt). A second normalization pass changed zero files. The tested scans found no host paths, loopback ADB endpoints, MAC addresses, unmasked serial/IMEI/MEID arrays, raw IMEI/MEID values, or private-key markers; all 16 guest serial-property occurrences are `<SERIAL>` placeholders. Per IR-122, 48 Cuttlefish virtual UART endpoint tokens in `launcher.log` remain intentionally visible to preserve the UART mapping. The JSON/JSONL artifacts parsed. After capture, its Cuttlefish group, private HOME, staging directory, and lock were removed; the pre-existing stale instance-1 registry entry remains untouched. The dedicated ADB server on port 5038 was stopped, and no listener remained on ports 5038 or 6521. Keep this record in `incomplete/`; it verifies the new live ELF-identity event but does not complete #064.

- **Acceptance audit (2026-10-08; see IR-269 to IR-271).** This pass checked the remaining criteria against existing evidence and started no capture. `Images/tools/reference/boot_signals.py` summarizes the 62 incomplete records into `Images/reference/16373615/boot-signals.json` (T0 tests in `Images/tools/tests/test_boot_signals.py`). Of those records, 54 contain `kernel.log`, 13 contain a host-side `VIRTUAL_DEVICE_BOOT_FAILED` line, and none contains `VIRTUAL_DEVICE_BOOT_COMPLETED` or a positive `sys.boot_completed` value. Every `sysBootCompleted` field in the observer logs (2,524 entries) is null.

  Criterion status:
  - Criteria 1, 2, and 6 (profiles, normalization across profiles, per-profile `host.json`) remain open. No profile reached boot completion, and `capture.sh` collects guest items only after readiness. `target` is also blocked by the guest Mesa EGL load failure, which is outside #064 (IR-240, IR-244). The three profile directories do not exist.
  - Criterion 4 (guest-command equivalence) remains open. Syntax parity under the pinned `/system/bin/sh` is recorded in IR-186. A live `adb shell` run needs a booted guest, and the plain-console channel is the serial shell of #014 (IR-271).
  - Criterion 5 (boot signals) is partly done. §7.7 lists the observed exact strings, and §3.3 marks `.kernel`, `.init`, and `.systemServer` as confirmed or corrected (IR-270). `VIRTUAL_DEVICE_BOOT_COMPLETED` has no timing, so the criterion stays open.

  The privacy scan of the 62 incomplete records found no host path, MAC or EUI address, or PEM marker in any capture file. Step 6's `androidboot.*`, `ro.adb.secure`, by-name, and hvc-holder notes remain open, because they need guest-side data from a booted guest.

- **Stall diagnosis (2026-10-08; see IR-279 and IR-280).** Two live `default` runs on the reference host separated the candidate causes. A 600-second run ended while zygote was still preloading. A 3000-second run reached the system server twice and then ended during a third start. In each start, the framework Watchdog killed `system_server` after its main thread stopped answering for about 185 seconds (`WATCHDOG KILLING SYSTEM PROCESS`), so `sys.boot_completed` never became 1. The host did not stall, the `target` SurfaceFlinger EGL abort did not occur, and zygote did not hang. The root cause of the guest-wide slowness is not established. The receipt, with the guest timeline and SHA-256 values of the retained raw records, is [default-20261008-diagnosis.txt](../../../Images/reference/16373615/incomplete/default-20261008-diagnosis.txt). The raw records are kept outside git. Criteria 1, 2, and 6 remain open, and no profile is published.

- **Boot ladder (2026-10-08; see IR-298 to IR-301 and the [ladder receipt](../../../Images/reference/16373615/incomplete/ladder-064-20261008.txt)).** Launch variants with the pinned build: 8192 MiB (four vCPUs), `--gpu_mode=none`, and `--enable_audio=false`. None reached `sys.boot_completed=1`. The 8 GiB run stayed up to its 2400-second deadline with adb in state `device` and the property unset. The headless run never started its Android VM. The audio-off receipt was lost (IR-298). The Watchdog timeout is not host-settable (IR-301). No profile candidate is recorded, and #064 stays open.
---

## #009 AndroidImageManifest

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #008 |
| Requirements | FR-IMG-02. Constraints: NFR-DEV-03 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §3.2–§3.3; [../../03-reference/android-image-manifest.md](../../03-reference/android-image-manifest.md) §5–§12 |
| Modules / paths | `Images/tools/apkrun_image/manifest.py`, `Images/tools/schemas/android-image-manifest.schema.json`, `Images/tools/tests/fixtures/manifests/{valid,invalid}/`, `Images/manifests/16373615/android-image.json`, `Packages/ImageCore/Sources/ImageCore/Manifest/`, `Packages/ImageCore/Tests/ImageCoreTests/` |
| Risks / questions | None |

### Goal

One reviewed, schema-validated `android-image.json` describes build 16373615. Every later tool takes file names and roles from it.

### Scope

- The JSON Schema, copied byte for byte from reference §7.
- The draft generator (`manifest`) and the checker (`manifest --check`) with checks M1–M15 of reference §8 and the complete schema constraints.
- The Swift `AndroidImageManifest` (`Codable`) in ImageCore, which accepts exactly the same documents.
- The invalid-manifest fixtures, shared by Python and Swift.
- The committed manifest for 16373615.
- Out of scope:
  - `RuntimeImageManifest` (first cut in #012, full in #065).
  - The layout file (#010, #011).
  - Reading `android-image.json` at run time: ImageCore never does that (reference §9).

### Deliverables

- `Images/tools/schemas/android-image-manifest.schema.json` and `manifest.py`.
- `Images/tools/tests/fixtures/manifests/valid/*.json`, and `invalid/<name>.json` with `<name>.expected.txt`.
- `Images/manifests/16373615/android-image.json`.
- `AndroidImageManifest.swift` and `AndroidImageManifestValidator.swift` in `Packages/ImageCore/Sources/ImageCore/Manifest/`.

### Implementation steps

1. **Schema and model.**
   - Commit the schema.
   - `manifest.py` loads the file. It runs M1 first, then the schema, then M2–M15 (reference §8).
   - `manifest --check` reports every failure. The other commands stop at the first one.
   - Each invalid fixture is a pair: `<name>.json` and `<name>.expected.txt` (the exact message).
   - Check: T0 passes over all pairs.
2. **Draft generator.**
   - `python3 -m apkrun_image manifest --inventory Images/manifests/16373615/inventory.json --out Images/manifests/16373615/android-image.json` fills in:
     - `source`;
     - `android` (from the boot header `os_version` and the SDK table, where 17 maps to 37);
     - `artifacts` from the inventory kinds, including `vbmeta_system`, `vbmeta_system_dlkm`, `vbmeta_vendor_dlkm`, and `custom` (reference §5);
     - `roles`;
     - `logicalPartitions` from the super metadata;
     - `blankPartitions` with the placeholders misc 1 MiB, metadata 64 MiB, and frp 1 MiB.
   - Check: `manifest --check` passes on the draft.
3. **Review and commit.**
   - A maintainer reviews the draft and commits it.
   - CI runs `manifest --check --no-files` on every committed manifest.
   - Check: T1 `manifest --check` passes with the real archive. That run includes the file checks M4, M6, and M10–M13.
4. **Swift model.**
   - `AndroidImageManifest` (`Codable`, `Sendable`) rejects unknown fields and newer `schemaVersion` values.
   - `AndroidImageManifestValidator` runs the checks that need only the manifest (M1–M3, M5, M7–M9, M14–M15). It uses the same message text and throws `ImageFailure.manifestInvalid(path, reason)`. JSON primitive type errors are converted to this typed failure without including input values. Regex validation requires full-string matches.
   - Checks that read image files stay in Python. Their fixtures are listed in `invalid/python-only.txt`, and the Swift test skips them.
   - The Swift tests find the shared fixture directory through a path relative to `#filePath`.
   - Check: T0 Swift tests pass.
5. **No hard-coded names.**
   - Add `Images/tools/tests/test_no_file_names.py`. It fails on any string literal that ends in `.img` or `.zip` in `apkrun_image/`. Tests and fixtures are exempt.
   - Check: the test passes. It stays in the suite so that later tasks keep the rule.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Python:** every valid fixture passes. Every invalid fixture fails with exactly its expected message. A source vbmeta omitted from both `artifacts` and `roles.vbmeta` is rejected; generation follows the top-level descriptor order. The model round-trips: load, dump with sorted keys, load again, and the result is equal. File checks reject swapped boot roles, stale inventory archive fingerprints, directory inventory metadata substituted for the declared archive, manifest plus inventory metadata that disagrees with the local `fetch.json` sidecar, and jointly edited metadata when the sidecar is missing. Schema, semantic, and file-backed diagnostics escape manifest-controlled newlines. Inventory rejects fetch-sidecar archive names containing control, format, surrogate, line-separator, or paragraph-separator characters; inventory-derived diagnostic values escape controls and are bounded. The no-file-names test.
- **T0 Swift** (`Packages/ImageCore/Tests/ImageCoreTests/AndroidImageManifestTests.swift`): decoding and encoding round trip. Every valid fixture and every committed manifest is accepted. The manifest-only invalid fixtures fail with the same message as in Python. JSON primitive type mismatches throw `ImageFailure.manifestInvalid`; input-derived paths and values are escaped and bounded, including control, quoting, and bidirectional-formatting characters. Trailing line feeds are rejected for every anchored string-pattern field.
- **T1:** `manifest --check Images/manifests/16373615/android-image.json` passes with the real archive. It is skipped when the archive is absent.

### Acceptance criteria

- [x] The schema describes the build ID, Android version, architecture, boot image, vendor boot, super/system, vendor, product, userdata, vbmeta, and metadata:
  - system, vendor, and product are `logicalPartitions` of `super`;
  - metadata is a `blankPartitions` entry.
- [x] JSON encode and decode work in Python and in Swift.
- [x] The committed manifest describes the #008 set. Every artifact matches its inventory entry in size, hash, and kind (M10).
- [x] Invalid manifests fail with actionable errors. Each message names the file or field, what was expected, what was found, and the fix. Each invalid fixture has its expected message.
- [x] Source metadata is internally consistent with the archive fingerprint and logical partition names are unique. Archive metadata cannot be replaced by directory inventory metadata or omitted. The unsigned `fetch.json` sidecar is not cryptographic proof of source origin; see IR-230. Malformed or adversarial JSON values become safe typed manifest errors.
- [x] No Python or Swift code opens an image file by a literal name.

### Notes

- The `blankPartitions` sizes are placeholders until #011 replaces them with the sizes from the #064 `target` capture.
- The design sketch in [android-image.md](../../02-design/android-image.md) §3.2 is abbreviated. Reference §5 is the complete example.
- **Verification (2026-09-30):** Python tests cover M1–M15, including fetched-source provenance, diagnostic escaping, strict end-of-input matching for every schema pattern, source vbmeta completeness, descriptor-order generation and validation, deterministic generation, and file checks against the pinned archive. The full image-tools suite passed 299 tests; Swift ImageCore manifest tests passed 23 tests; `manifest --check` passed against the real pinned archive. A broader Swift package run also failed the unrelated `DiagnosticsCoreTests.logReaderFallsBackToPublicRotatingMirrorsOnTimeout` test, including when run alone. The manifest has 10 artifacts and all 9 non-empty liblp partitions.
- **Maintainer review pending:** the manifest is generated from the pinned inventory and its file checks pass, but a human maintainer still needs to review its source-derived values before treating the draft as approved; see IR-062.
- `fetch.json` is unsigned local metadata. Its archive fingerprint and build fields are checked for consistency, but a locally fabricated sidecar cannot be distinguished from one written by `fetch`; see IR-230.
- **Supplemental verification (2026-10-06):** `pytest Images/tools/tests/test_manifest.py Images/tools/tests/test_no_file_names.py -q` passed 41 tests; the Swift `AndroidImageManifestTests` suite passed 26 tests. Both cover integral floating-form JSON numbers and the largest valid signed-64-bit sizes. The real-archive `manifest --check` passed. After all parser-boundary regressions were added, the full image-tools suite passed 594 tests with four platform skips.

---

## #010 Extract Android kernel and ramdisk

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #008, #009 |
| Requirements | FR-IMG-03 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §4.1, §6.1–§6.4; [../../03-reference/android-image-manifest.md](../../03-reference/android-image-manifest.md) §9; [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Modules / paths | `Images/tools/apkrun_image/{bootimg,kernel,bootconfig,avb}.py`, the `extract` subcommand, `Images/tools/layouts/cuttlefish-phone-arm64.json`, `Images/tools/tests/fixtures/bootconfig/`, `Images/work/<buildId>/boot/` |
| Risks / questions | R-11 |

### Goal

`extract` derives five outputs from the manifest and leaves the originals untouched: the uncompressed kernel, the combined ramdisk, the vendor bootconfig, the kernel command line, and the extraction metadata.

### Scope

- Parsing boot, init_boot, and vendor_boot v4.
- Kernel decompression and header checks.
- The ramdisk fragment policy.
- The vendor bootconfig and the command line. The DTB is recorded, not used.
- `extraction.json` with hashes.
- `bootconfig.py`: layer merge, serialization, the trailer, and the golden vectors.
- `avb.py`: the `androidboot.vbmeta.*` values.
- The layout file with the layer-2 bootconfig baseline and the command-line additions.
- Out of scope:
  - Disks (#011).
  - The Swift per-boot initrd and bootconfig layers 3 and 4 (#012).
  - Confirming the fragment policy on a real boot (#013).

### Deliverables

- `bootimg.py`, `kernel.py`, `bootconfig.py`, `avb.py`, and the `extract` subcommand.
- `Images/tools/tests/fixtures/bootconfig/*.txt` with the matching `*.bin` golden vectors.
- `Images/tools/layouts/cuttlefish-phone-arm64.json` with `deviceFamily`, `bootconfig.image` (layer 2), and `cmdline.additions`. #011 adds `disks` and #012 adds `consolePorts`.
- `Images/work/16373615/boot/` produced locally. It is not committed.

### Implementation steps

1. **`bootimg.py`.**
   - Parse the boot v4 and init_boot headers: header version at offset 40, kernel and ramdisk sizes, `os_version`, and cmdline.
   - Parse vendor_boot v4: page size, vendor cmdline, DTB size, the ramdisk table (types NONE, PLATFORM, RECOVERY, DLKM), and the bootconfig size.
   - Check: T0 results equal the vendored `unpack_bootimg.py` output on the fixtures.
2. **`kernel.py`.**
   - Detect and decompress gzip (`1f 8b`), LZ4 legacy (`02 21 4c 18`), and LZ4 frame (`04 22 4d 18`).
   - Require `ARM\x64` at offset 0x38.
   - Record `text_offset`, `image_size`, and flags bits 1–2.
   - Check: T0 passes for each compression. A wrong magic is rejected with a message.
3. **`extract`.**
   - Run `python3 -m apkrun_image extract --manifest Images/manifests/<buildId>/android-image.json --out Images/work/<buildId>/boot/`.
   - It opens inputs read-only and re-hashes them against the manifest (M4). It writes:
     - `kernel`;
     - `ramdisk.img`: the vendor fragments in table order without RECOVERY, then the init_boot ramdisk;
     - `vendor-bootconfig.txt`;
     - `cmdline.txt`: the vendor cmdline, then the boot cmdline, then `cmdline.additions` from the layout;
     - `dtb`;
     - `extraction.json`: input and output SHA-256 values, sizes, header fields, and each fragment with its type and whether it was included.
   - Check: T1 on the fixture set. The outputs equal the expected bytes, the original hashes are unchanged, and a second run gives identical outputs.
4. **`bootconfig.py`.**
   - Parse and serialize bootconfig.
   - Implement the merge rules of §6.1:
     - one layer per key;
     - a conflict unless `overrides` is set;
     - key regex `[A-Za-z0-9_.-]+`;
     - printable ASCII values without `"`, backslash, or newline, always double-quoted;
     - the build fails above 16 KiB or 1024 key/value tree nodes.
   - Implement the trailer of §6.3.
   - Golden vectors cover: empty input, one key, many keys, values with spaces, a block exactly at 16 KiB, and a conflict whose message is `bootconfigConflict(key, layerA, layerB)`.
   - Check: T0 passes.
5. **`avb.py`.**
   - Read the top-level vbmeta chain descriptors in descriptor order. `roles.vbmeta` lists the raw vbmeta artifacts in that same relative order. For another chained artifact, such as `boot` or `init_boot`, read the vbmeta blob at the AVB footer offset.
   - Hash the AVB0 header, authentication block, and auxiliary block for each image; exclude partition padding and the AVB footer.
   - Reject a top-level vbmeta with `VERIFICATION_DISABLED`, which causes libavb to omit all AVB-derived `androidboot.*` options.
   - Compute `androidboot.vbmeta.{digest,hash_alg,size,avb_version,invalidate_on_error}`.
   - `hash_alg` follows the top-level signature algorithm (`NONE` uses SHA-256); `size` is the sum of the vbmeta metadata blob sizes; `avb_version` follows the pinned AVB toolchain. `invalidate_on_error` follows the explicit hashtree error mode.
   - Check: the digest equals `avbtool calculate_vbmeta_digest` from the vendored tool, in T0 on chained raw/footer fixtures and in T1 on the real build.
6. **Layout file and real run.**
   - Commit `cuttlefish-phone-arm64.json` with the layer-2 keys of §6.2. Values marked "(reference)" are taken from `Images/reference/16373615/target/` (#064). Each command-line addition of §6.4 gets a `comment` field.
   - Run `extract` on 16373615.
   - Record in [android-image.md](../../02-design/android-image.md) §4.1: the kernel compression, the fragment list, and the command-line length.
   - Check: `cmdline.txt` is at most 2048 bytes and never contains `androidboot.`. Layers 1 and 2 merged are at most 16 KiB.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0** (`Images/tools/tests/test_bootimg.py`, `test_kernel.py`, `test_bootconfig.py`, `test_avb.py`): header parsing, each compression, the merge rules and conflict messages, the trailer golden vectors, and the vbmeta digest on chained raw/footer fixtures.
- **T1** (`test_extract.py`): extraction end to end on the synthetic fixture set. The original hashes are the same before and after. The outputs are deterministic. With the real archive (skipped when absent), `extract` succeeds and the digest equals `avbtool`.

### Acceptance criteria

- [x] `boot.img`, `init_boot.img`, and `vendor_boot.img` are inspected, and the kernel and the ramdisks are extracted. The roles come from the manifest.
- [x] The originals are never altered, silently or otherwise: they are opened read-only, and their SHA-256 values are the same before and after, as checked in T1.
- [x] The output goes to the derived build directory `Images/work/<buildId>/boot/`.
- [x] The output contains the kernel, the ramdisk (the initrd input), the extraction metadata, and hashes.
- [x] The kernel is an uncompressed arm64 `Image` that meets the VM validation rules ([../../02-design/vm.md](../../02-design/vm.md) §3).
- [x] The bootconfig merge and the trailer golden vectors pass. Conflicting keys produce the `bootconfigConflict` message.
- [ ] The layout file is committed. Every "(reference)" value traces to the launcher capture `Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt` or to a VZ observation recorded in [android-image.md](../../02-design/android-image.md) §6.2 (IR-305).

### Notes

- `extract` does not write the bundle's `boot/bootconfig.txt`. The `bundle` command (#012, #065) writes it: the `[vendor]` section from `vendor-bootconfig.txt`, and the `[image]` section from the layout plus the `avb.py` values.
- #013 confirms that leaving out the RECOVERY fragment is correct, using `lsmod` and the first-stage init log.
- **Step 1 verification (2026-09-30):** `bootimg.py` parses boot/init_boot v4 and vendor_boot v4 headers, bounds all exposed sections, enforces pinned AOSP page/table dimensions, verifies exact fragment coverage, and decodes fragment names and command lines as UTF-8 while preserving table order. Seventeen focused tests passed: fixture payloads matched the vendored AOSP unpacker, temporary non-empty-DTB/UTF-8-name/UTF-8-command-line images matched AOSP parsing, malformed layouts were rejected, and the pinned archive parsed via seekable ZIP streams. The full Python image suite passed 138 tests, and `scripts/ci/run-checks.sh` passed. The remaining #010 steps and acceptance criteria are still open.
- **Step 2 verification (2026-09-30):** `kernel.py` streams raw, gzip, LZ4 legacy, and LZ4 frame inputs; decodes concatenated members/frames; validates the arm64 magic; records `text_offset`, `image_size`, and flags/page-size metadata; and rejects malformed streams and unsupported flags. Hostile review found and fixed rejection of valid concatenated streams and a gzip member replay at a 1 MiB read boundary; final hostile review reported no findings. The pinned archive produced an uncompressed 42,031,616-byte kernel section with `image_size` 42,795,008, `text_offset` 0, and flags 10. All 31 focused tests and the 169-test Python suite pass. A 1 GiB decompressed-output ceiling is an implementation choice recorded in [implementation-review.md](../implementation-review.md) IR-066. Remaining #010 steps and acceptance criteria are still open.
- **Step 3 verification (2026-09-30):** `extract` resolves inputs from manifest roles, verifies M4 before and after extraction, writes the five documented artifacts plus SHA-256/size metadata, and restores the prior output set after a failed publish. Fixture tests compare exact output bytes, verify the archive hash is unchanged, exclude the RECOVERY fragment, and compare two complete runs byte for byte. The pinned build produced a raw 42,031,616-byte kernel and one included PLATFORM fragment (empty table name, 18,816,072 bytes). Its command line is 157 bytes with only the required `console=hvc0` addition; this is provisional because `Images/reference/16373615/target/` is absent and #064-derived additions are not yet known. Hostile review found and fixed directory-source duplication, a NUL-prefixed `androidboot.*` bypass, mixed outputs after a publish failure, and invalid-UTF-8 tracebacks; a second review found no further issues. The focused extraction/CLI/manifest tests passed (37 tests), the full Python suite passed (185 tests), and `scripts/ci/run-checks.sh` passed. The output rollback policy and provisional measurement are recorded in [implementation-review.md](../implementation-review.md) IR-067 and IR-068. Remaining #010 steps and acceptance criteria are still open.
- **Step 4 verification (2026-09-30):** `bootconfig.py` parses and merges ordered scalar layers, enforces the documented key/value syntax and the 16 KiB/1024-node build limits, serializes deterministic text, and creates the kernel trailer with its checksum and padding. Five golden vectors cover empty input, one key, many keys, values with spaces, and the exact 16 KiB boundary. Tests also cover conflicts and overrides, duplicate values, inline comments, invalid syntax, structural node counting, command-line separator handling, and the trailer's 32 KiB kernel bound. Hostile review found and fixed the 1024-node bound, bootconfig-token placement, and inline-comment handling; the final hostile review reported no findings. The focused bootconfig suite passed 36 tests, the full Python suite passed 221 tests, and `scripts/ci/run-checks.sh` passed. The conservative node bound, scalar-only layer model, and command-line token rule are recorded in [implementation-review.md](../implementation-review.md) IR-069. Remaining #010 steps and acceptance criteria are still open.
- **Step 5 verification (2026-09-30):** `avb.py` hashes the top-level vbmeta plus every chained metadata blob in descriptor order, including AVB footer payloads in `boot`/`init_boot`; raw vbmeta children are checked against `roles.vbmeta`. The digest and aggregate metadata size match vendored `avbtool` for a synthetic raw/footer chain and the pinned 16373615 archive. Tests cover SHA-256/SHA-512 selection, the pinned AVB 1.4 tool version, footer bounds and truncation, missing/misordered chain artifacts, disabled hashtrees, and rejection of `VERIFICATION_DISABLED`. The focused AVB suite passed 16 tests, the full Python suite passed 237 tests, and `scripts/ci/run-checks.sh` passed. Hostile review findings about footer-backed chain images, malformed/truncated inputs, and disabled verification were fixed; the final hostile review reported no findings. The version and hashtree-policy choices are recorded in [implementation-review.md](../implementation-review.md) IR-070. Step 6 and the remaining #010 acceptance criteria are still open pending #064 reference values.
- **Step 6 partial (2026-09-30):** Added the default phone layout with only the ADR-decided or source-verified image bootconfig keys and the mandatory `console=hvc0` argument. Reference-only keys remain omitted until #064 provides evidence; AVB values remain computed by `avb.py`. The default CLI extraction is covered against the pinned archive. This layout is intentionally incomplete for Android boot, and #010 remains open. See [implementation-review.md](../implementation-review.md) IR-074.
- **Partial acceptance verification (2026-10-01):** On macOS 27.0 (build 26A428), re-running extraction against the pinned 16373615 archive produced the same six outputs and SHA-256 values as before; the archive SHA-256 remained `051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18`. The kernel bytes at offset `0x38` are `ARM\x64`, the kernel is uncompressed, and the current 157-byte command line contains no `androidboot.*` key and is below 2048 bytes. The non-ASCII extraction rejection and exact 2048-byte acceptance are tested. The reference-derived layer-2 values and final command line remain blocked on #064's target capture; #010 stays open.
- **Final verification (2026-10-01):** `pytest Images/tools/tests -q` passed 343 tests with 3 platform skips (the reference-capture tests require GNU `timeout` on Linux). `manifest --check` and the default real-archive extraction passed; the six output hashes were unchanged and the pinned archive hash still matched. Ruff, format, `sh -n`, `git diff --check`, all six repository checks, and hostile review passed. The extraction implementation now rejects non-ASCII layout and source command lines and accepts an exact 2048-byte ASCII command line. #010 remains open for the reference-derived layout values and final command-line verification from #064's `target` capture.
- **Reference source changed (2026-10-08; IR-305).** No #064 capture reached a complete boot, and none will on the nested reference host. The layer-2 "(reference)" values come from the `default` launcher capture (`internal-bootconfig.txt`) and are confirmed by the VZ direct-boot spike (IR-306), whose bootconfig is listed key by key in [android-image.md](../../02-design/android-image.md) §6.2. The 157-byte command line needed no addition beyond `console=hvc0`: the crosvm-only `earlycon` and `ramoops` parameters do not apply on VZ.
- **Supplemental T1 verification (2026-10-06; see IR-234):** On macOS 27.0 (build 26A428), the real-archive `extract` command and `manifest --check` passed. `Images/tools/tests/test_extract.py` passed all 19 tests, and the archive SHA-256 remained `051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18`. The real-archive test parses the extracted vendor bootconfig, computes the five AVB bootconfig values, merges both with the committed layer-2 layout through `bootconfig.py`, and asserts the complete serialized layer 1 + 2 block stays within 16 KiB. The full `Images/tools/tests` suite passed 597 tests with four platform-specific skips in 301.48 seconds. The reference-derived layout values and 157-byte command line remain provisional pending #064's `target` capture.
- **Layer-2 trace and tests (2026-10-10; IR-400 to IR-406).** The layout's image layer matches the committed launcher capture `Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt` and the VZ record of android-image.md §6.2. Of its 25 keys, 18 equal the capture; `androidboot.wifi_impl` is the VZ-verified `virt_wifi` that replaces the capture's `mac80211_hwsim_virtio` (§7.4); six are absent from the capture and are decided or VZ-verified (§6.2). The 11 graphics keys of the guestSwiftshader and headless profiles equal the capture, and the 8 omitted keys are pinned by name. `Images/tools/tests/test_layout.py` checks all of this. Mutation checks (a changed value, a moved key, a changed GPU key, a missing headless key, a reordered command line, and a cited section that does not exist) each failed the intended test. No layout value changed. The command line is 172 bytes: the 144-byte vendor line, `console=hvc0`, and `log_buf_len=2M` (android-image.md §4.1). The full `Images/tools/tests` suite passed 795 tests with four platform-specific skips in 461.75 seconds, and `ruff check` passed. `scripts/tests/run.sh` does not reference the layout, so it was not run for this change. The criterion above stays unchecked: the eight `drm_virgl` values have no capture or VZ evidence (IR-400), and `display_framebuffer_format` is missing from that set (IR-401).

---

## #011 GPT disks and partition mapping

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #005, #009, #010 |
| Requirements | FR-IMG-04, FR-VM-03 ([../traceability.md](../traceability.md) §2.1), NFR-RES-02 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §4.2–§4.5, §5; [../../02-design/vm.md](../../02-design/vm.md) §4, §12; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1 |
| Modules / paths | `Images/tools/apkrun_image/{sparse,gpt,layout}.py`, the `disks` and `inspect` subcommands, the layout `disks` section, `Packages/ImageCore/Sources/ImageCore/Disks/{GPTDisk,InstanceDiskProvisioner}.swift`, `Tests/Fixtures/linux/init`, `Tests/IntegrationTests/LinuxGuestTests/`, `Images/reference/vz/<macOS build>/topology.txt` |
| Risks / questions | R-06, R-16 |

### Goal

Two raw GPT disks are built from the manifest and the layout. They attach to a VZ guest in a fixed order, and the guest sees the expected partition names and sizes. The VZ block topology that `androidboot.boot_devices` needs is recorded.

### Scope

- Sparse to raw conversion, the GPT writer, the disk plan in the layout, the `disks` command, and `disks.json`.
- Confirming the blank sizes, omissions, and fstab flags from the #064 launcher captures and the VZ spike (IR-305, IR-306).
- The Swift minimal GPT support and clone-based instance disk provisioning, with userdata growth.
- Discovering the topology with the Linux test guest.
- The verified mapping table in [android-image.md](../../02-design/android-image.md) §4.2.
- Out of scope:
  - Booting Android (#012). The Android-kernel acceptance check for this task runs in #012.
  - Image install (#065) and first-run provisioning UI (#066).
  - `_b` slots and crosvm composite disks.
  - Pre-formatted userdata, which is fallback A or B of §5.2 and only if #013 needs it.

### Deliverables

- `sparse.py` (writer path), `gpt.py`, `layout.py`, and the `disks` and `inspect` subcommands.
- The layout `disks` section, from the §4.2 table.
- `Images/work/16373615/disks/{os.img,userdata.img,disks.json}` produced locally.
- ImageCore `GPTDisk` and `InstanceDiskProvisioner`, which is internal to ImageCore and wrapped by `InstanceStore` in #012.
- The `apkrun.test=parts` check in `Tests/Fixtures/linux/init`.
- `Images/reference/vz/<macOS build>/topology.txt`.
- The verified tables in [android-image.md](../../02-design/android-image.md) §4.2 and §5.3.

### Implementation steps

1. **Unsparse.**
   - Write the unsparsed data straight into `os.img` at the partition offset. DONT_CARE chunks and zero FILL chunks become holes, and the CRC32 chunk is checked (§4.3).
   - Check: T1 hashes equal the committed `simg2img` hashes in `Images/tools/tests/fixtures/sparse/expected-sha256.txt`.
2. **`gpt.py`.**
   - Write and read GPT as in §4.4:
     - 512-byte sectors;
     - a protective MBR;
     - the primary header at LBA 1, entries in LBA 2–33, and the backup at the end;
     - CRC32 checksums;
     - 1 MiB alignment;
     - type GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4`;
     - UUIDv5 values over (imageVersion, disk role, label);
     - UTF-16LE names of at most 36 units.
   - `python3 -m apkrun_image inspect <file>` prints the table.
   - Check: T0 round trip and CRC tests pass. T1: macOS reads the table, and `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount os.img` followed by `diskutil list` shows the partition names.
3. **Disk plan and `disks`.**
   - Add the §4.2 plan to the layout:
     - disk 0 `os`, read-only, with its nine partitions;
     - disk 1 `userdata`, read-write, with misc, metadata, frp, and a last `userdata` partition (IR-308).
   - Confirm the `blankPartitions` sizes in `android-image.json` against the composite disk specs of the #064 launcher captures; the VZ spike booted with the current values.
   - `python3 -m apkrun_image disks --manifest Images/manifests/16373615/android-image.json --layout Images/tools/layouts/cuttlefish-phone-arm64.json --out Images/work/16373615/disks/` writes `os.img`, the blank formattable `userdata.img` template, and `disks.json`.
   - `disks.json` has, per disk: the file, role, access, identifier, and sector size. Per partition it has the name, GUID, first and last LBA, size, and source SHA-256.
   - Check: `du -h` shows that `os.img` is allocated well below its logical size. The layout-check messages of reference §8 appear for a broken layout.
4. **Linux guest check.**
   - Add `apkrun.test=parts` to `Tests/Fixtures/linux/init`. It prints, per `/sys/class/block/vd*`, the `PARTNAME` from `uevent`, the size in sectors, and `blockdev --getss`. It also prints `readlink -f /sys/block/vda` (and `vdb`).
   - `LinuxGuestTests.testAndroidDiskLayout` attaches the two disks with the access and synchronization modes of [android-image.md](../../02-design/android-image.md) §9.2, then compares the output with `disks.json`.
   - The same run writes the topology capture of [../../02-design/vm.md](../../02-design/vm.md) §5 to `Images/reference/vz/<macOS build>/topology.txt`: `lspci -nn`, the `/sys/bus/pci/devices` listing, a `/proc/device-tree` dump, and the `/sys/block/vd*` paths. Derive the `boot_devices` value from the platform component (for example `40000000.pci`, [android-image.md](../../02-design/android-image.md) §5.3).
   - Check: the T2 test passes, and `topology.txt` is committed.
5. **Swift instance disks.**
   - `GPTDisk` reads and verifies the header and entries. It rewrites the disk and partition GUIDs, moves the backup header and entries to a new end, updates `alternate_lba` and `last_usable_lba`, extends the last partition's `ending_lba`, and recomputes the CRCs.
   - `InstanceDiskProvisioner` does four things:
     - clones the templates with `clonefile`;
     - derives the new GUIDs from the instance UUID;
     - grows `userdata.img` to `runtime.userdataGiB` (default 32) with `ftruncate` plus `GPTDisk`;
     - calls `fsync`.
   - Errors: `ImageFailure.cloneUnsupported(volume)`, `cloneFailed(errno)`, and `insufficientSpace(required, available)`.
   - Check: T0 tests against the Python GPT fixtures in `Images/tools/tests/fixtures/gpt/` pass. The T1 tests pass.
6. **Documentation.**
   - Fill [android-image.md](../../02-design/android-image.md) §4.2 with the verified table: virtual device index, backing image, read-only or read-write, the guest name (`vda`, `vdb`), the partition labels, and the sizes.
   - Confirm the omitted partitions against the #064 launcher captures (composite disk specs) and the VZ boot's `by-name` list and fstab: `uboot_env`, the persistent vbmeta, `bootconfig`, and the `_b` slots.
   - Confirm `formattable` and `keydirectory=/metadata/vold/metadata_encryption` in the fstab (§5.2).
   - Put the discovered `boot_devices` value in §5.3, and add a §13 row for every new difference.
   - Check: the review of the document pull request.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Python** (`test_gpt.py`, `test_sparse.py`, `test_layout.py`): the GPT round trip, CRCs, UUIDv5 stability, name encoding, and layout validation messages.
- **T0 Swift** (`Packages/ImageCore/Tests/ImageCoreTests/GPTDiskTests.swift`): backup relocation and GUID rewrite. The result must equal the Python fixture after the same operation.
- **T1:**
  - Unsparse hashes against `simg2img`.
  - macOS parses the GPT.
  - `InstanceDiskProvisioner` on a temporary APFS volume (`hdiutil create -size 2g -fs APFS -volname apkrun-t1`): the clone works, the grown `userdata.img` has a logical size of 32 GiB, and its allocated size stays near the template's (NFR-RES-02).
  - On an HFS+ volume the result is `cloneUnsupported`.
- **T2** (`Tests/IntegrationTests/LinuxGuestTests/`): the `parts` check against `disks.json`, and the topology output.

### Acceptance criteria

- [x] The minimum disk mapping needed to boot is defined: the two disks of [android-image.md](../../02-design/android-image.md) §4.2.
- [x] Each virtual device is documented with its backing image, read-only or read-write access, and the name the guest expects (the verified table in §4.2).
- [x] The mapping is data-driven. It lives in the layout and the manifest, and no partition or file name appears in Python or Swift code.
- [x] The Linux test guest sees two virtio block devices with the partition names and sizes of `disks.json`.
- [x] The Android kernel detects the expected virtio block devices. The design moves this check to #012.
- [x] `os.img` is read-only and `userdata.img` is read-write. The instance disk is an APFS clone, and `userdata.img` grows sparse (NFR-RES-02).
- [x] The `boot_devices` value is recorded in `topology.txt` and in [android-image.md](../../02-design/android-image.md) §5.3.

### Notes

- `clonefile` needs the source and the destination on the same volume. Tests and `apkrun-dev` must keep `APKRUN_HOME` on the volume of the bundle, or they get `cloneFailed(EXDEV)`.
- Steps 3 and 6 read the #064 launcher captures under `Images/reference/16373615/incomplete/` (composite disk specs, `cuttlefish_config.json`) and the VZ spike capture; a complete #064 reference is not needed (IR-305).
- **Verification (2026-10-09, macOS 27.0.1 26A434, branch `task/011-gpt-disks`).**
  - Step 1: `sparse.expand_into` writes RAW and non-zero FILL chunks and leaves the rest as holes. Its output equals `simg2img` 1.1.5 for the three fixture images and for the real `super.img` (8 GiB, SHA-256 `7dd80d27…85e3b5`), and the real expansion is allocated below half its size.
  - Step 2: `gpt.py` and `inspect` are in place; T0 covers the round trip, CRCs, UUIDv5 stability, names, and layout rejections, and the T1 case attaches a GPT with `hdiutil` and finds both partitions in `diskutil list`.
  - Step 3: the layout `disks` section and `disks` command are in place. For build 16373615 the command took 20 s; `os.img` is 8,739,880,960 bytes with 1.8 GiB allocated, and the `userdata.img` template is 85,983,232 bytes with 64 KiB allocated. The `blankPartitions` sizes (1, 64, and 1 MiB) are unchanged: they booted in the spike, and the launcher captures have no sysfs listing. The reference §8 layout messages are tested.
  - Step 4: `scripts/build-test-android-disks.sh` writes the disks outside `~/Documents`, and the signed `LinuxGuestAndroidDiskLayoutTests.testAndroidDiskLayout` passed. `topology.txt` is committed under `Images/reference/vz/26A434/`.
  - Step 5: `GPTDisk` equals the Python provisioning fixture byte for byte; `InstanceDiskProvisioner` clones, grows a 32 GiB disk to less than 16 MiB allocated, keeps the 10 GiB margin, and refuses a non-APFS volume. The volume checks use an injected volume probe rather than `hdiutil` scratch volumes (IR-311).
  - Python: 72 new or changed tests pass; ImageCore: 36 tests; the error catalog test covers the new `image.*` codes.
  - The Android-kernel check of this task runs in #012. It passed on 2026-10-09 with `apkrun dev boot`: the console shows `[vda]` with `vda1`–`vda9` (`os.img`) and `[vdb]` with `vdb1`–`vdb4` (`userdata.img`, 32 GiB logical).
- The disk count changed from three to two after the VZ spike: the stock fstab has `/devices/*/block/vdc auto auto defaults voldmanaged=sdcard1:auto`, and vold scanned the third disk (the userdata disk, mounted as `/data`) as removable storage `disk:253,32` (IR-308).

---

## #012 Boot the Android kernel

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #010, #011 |
| Requirements | FR-VM-08 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §5.1, §5.3, §6, §9, §10.1, §14.2; [../../02-design/vm.md](../../02-design/vm.md) §2–§4, §6.4, §9, §10; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.1–§3.3, §10; [../../02-design/cli.md](../../02-design/cli.md) §5; [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Modules / paths | `Images/tools/apkrun_image/bundle.py`; ImageCore `Version/ImageVersion.swift`, `Bundle/{RuntimeImageManifest,DevelopmentImage}.swift`, `Boot/{AndroidBootPlanner,BootconfigWriter,VZPlatformProfile}.swift`, `Instance/InstanceStore.swift`; RuntimeCore `Supervisor/RuntimeSupervisor.swift`, `Boot/{BootPhaseDetector,BootSignals}.swift`; `Packages/RuntimeHost/`; `CLI/apkrun/Dev/`; `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/AndroidBootTests/` |
| Risks / questions | R-06, R-11 |

### Goal

`apkrun-dev dev boot` starts a VM from four inputs: the Android kernel, the per-boot initrd with the merged bootconfig, the kernel command line, and the two disks. The captured serial log shows the kernel getting past early init and detecting the configured virtio devices.

### Scope

- An Android-specific `VMDefinition` built by ImageCore's `AndroidBootPlanner`.
- An unsigned development bundle and its Debug-only loader, until #065.
- Bootconfig layers 3 and 4, and the per-boot initrd.
- A first cut of `InstanceStore`.
- A first cut of `RuntimeSupervisor`: the `.kernel` phase and the immediate kernel-panic failure.
- Complete serial capture through the `ConsoleLogWriter` of #004.
- A provisional console port plan that attaches the §7.1 table as given, in array order.
- The VirtualMachineCore changes the Android definition needs ([../../02-design/vm.md](../../02-design/vm.md) §4, §6.1, §7): ports 10 and up on one multiport console device, `network` as an ordered list of NAT NICs, and the development-only `builtInDisplay`.
- The `headless` GPU profile placeholder for `--gpu none`.
- Out of scope:
  - Reaching init (#013).
  - Verifying the port numbering (#095).
  - The GPU (#021).
  - Signing and `ImageStore` (#065).
  - apkrund (#031).

### Deliverables

- `python3 -m apkrun_image bundle --unsigned` (development only). It writes the tree of [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1 under `Images/<imageVersion>/`, but without `manifest.sig` and `SHA256SUMS`.
- The `manifest.json` blocks needed to boot: `schemaVersion`, `imageVersion`, `kind: stock`, `provenance`, `boot`, `disks`, `templates`, `userdataStrategy: blankFormattable`, `consolePorts`, `gpuProfiles`, and `files`. #065 completes them.
- ImageCore:
  - `ImageVersion`, `InstalledImage`, and a first cut of `RuntimeImageManifest`.
  - `DevelopmentImage.load(directory:) -> InstalledImage`, Debug only. It checks that the listed files exist with the listed sizes, and does no signature check.
  - `BootconfigWriter`, `VZPlatformProfile` (with `bootDevices` from `topology.txt`), `AndroidBootPlanner`, `BootOptions`, and `AndroidBootPlan`, with the API of [android-image.md](../../02-design/android-image.md) §9.1.
  - `InstanceStore` (`load`, `provision`, `resetAndroid`) over `InstanceDiskProvisioner`.
- RuntimeCore:
  - A first cut of `RuntimeSupervisor`, which takes `Runtime/instance.lock`.
  - `BootPhaseDetector` and `BootSignals.swift`.
  - Golden fixtures in `Packages/RuntimeCore/Tests/RuntimeCoreTests/Fixtures/console/`: VZ console logs from the direct-boot spike (IR-306), plus one #064 crosvm `kernel.log` for the U-Boot banner case.
- RuntimeHost: the embedded composition that `apkrun-dev` uses.
- CLI: `apkrun dev boot --bundle <dir> [--gpu none]`.
- The `apkrun.test=bootconfig` check in `Tests/Fixtures/linux/init`.
- VirtualMachineCore: `VZConfigurationBuilder` splits `consolePorts` at the 10-device limit, `VMDefinition.network` becomes `[NetworkDefinition]`, and `VMDefinition.builtInDisplay` maps to `VZVirtioGraphicsDeviceConfiguration`, with T0 tests in `VZConfigurationBuilderTests`.

### Implementation steps

1. **Unsigned bundle.**
   - Run `python3 -m apkrun_image bundle --unsigned --manifest Images/manifests/16373615/android-image.json --layout Images/tools/layouts/cuttlefish-phone-arm64.json --reference Images/reference/16373615/incomplete/default-20261001T120904-49816 --image-version 2026.10.0 --out Images/work/16373615/bundle/`.
   - It runs `extract` and `disks`, then writes:
     - `boot/{kernel,ramdisk.img,bootconfig.txt,cmdline.txt}`;
     - `disks/os.img`;
     - `templates/{persistent.img,userdata.img}`;
     - `manifest.json`, with `consolePorts` from a provisional layout `consolePorts` section ([android-image.md](../../02-design/android-image.md) §7.1) and `gpuProfiles.headless`.
   - Check: the tree matches [filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1, except for the two signature files.
2. **ImageCore data types.**
   - `ImageVersion` parses and orders versions.
   - `RuntimeImageManifest` is `Codable`.
   - `DevelopmentImage.load(directory:)` works only when the build defines `DEBUG`. Otherwise it throws.
   - `BootconfigWriter` ports the merge and the trailer to Swift.
   - Check: T0 passes, including the shared golden vectors of `Images/tools/tests/fixtures/bootconfig/`.
3. **Instance and boot plan.**
   - `InstanceStore.provision(image:sizing:)` creates `$APKRUN_HOME/Runtime/instance/` as in §5.1:
     - `instance.json` holds the UUID, the `VZGenericMachineIdentifier`, the MAC address, the sizing (4 vCPU and 4 GiB, [../../02-design/vm.md](../../02-design/vm.md) §10), `imageVersion`, `userdataSchemaVersion`, and `userdataGeneration`. It is written last.
   - `AndroidBootPlanner.prepareBoot(image:instance:options:)` merges the layers in this order:
     - layer 1, vendor: `[vendor]` from `boot/bootconfig.txt`;
     - layer 2, image: `[image]` plus the selected GPU profile;
     - layer 3, platform: `boot_devices`;
     - layer 4, instance: `serialno` (`APKRUN` plus 10 uppercase hex digits), `lcd_density`, `ddr_size`, and `apkrun.instance`, `apkrun.devmode`, `apkrun.image`.
   - It then builds the initrd: `clonefile` of `boot/ramdisk.img` to `Runtime/instance/boot/initrd.img.tmp`, append the trailer, `fsync`, rename, and record the SHA-256.
   - It returns an `AndroidBootPlan` whose `VMDefinition` follows §9.2:
     - the label;
     - `.linux(kernel:initialRamdisk:commandLine:)`;
     - the disks;
     - `.nat(macAddress:)`;
     - vsock, `consolePorts`, entropy, and balloon;
     - no sound in M1.
   - Check: the T0 mapping test passes, and the definition passes `VMDefinitionValidator`.
4. **Supervisor, detector, CLI.**
   - `RuntimeSupervisor.ensureReady(.cli, operation:)` implements steps 0–2, 4, and 5 of [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2.
   - `BootSignals.swift` holds the pattern table:
     - `.kernel` is entered on the first console byte after `VM_START`, with PerfMarker `KERNEL_START`;
     - `Kernel panic - not syncing` gives `failed(.kernelPanic)` at once.
   - `apkrun dev boot --bundle <dir> [--gpu none]` runs in the embedded runtime (`APKRUN_EMBEDDED_RUNTIME`, [runtime-daemon.md](../../02-design/runtime-daemon.md) §10). It provisions the instance when there is none, streams the phases, and stops the VM on Ctrl-C with `VMController.stop()`.
   - Check: T0 golden tests pass over the captured console logs. `apkrun-dev dev boot --bundle Images/work/16373615/bundle/ --gpu none` prints `.kernel`.
5. **Bootconfig on the Linux guest.**
   - Add `apkrun.test=bootconfig`, which prints `/proc/bootconfig`.
   - `LinuxGuestBootconfigTests.testBootconfigTrailer` (IR-362) boots the test kernel with an initrd that `BootconfigWriter` built from a golden input, then compares the output with the golden text.
   - If the pinned test kernel lacks `CONFIG_BOOT_CONFIG`, the test skips with that message, and #013 verifies `/proc/bootconfig` on Android.
   - Check: the T2 test passes or skips with the reason. It skips on the pinned test kernel, which is built without `CONFIG_BOOT_CONFIG`; the reason carries the kernel's warning (IR-362).
6. **Android kernel boot.**
   - `AndroidBootTests.testKernelBoot` boots the unsigned bundle with `--gpu none`. It waits up to 120 s for the first `init: ` line on hvc0, then force-stops the VM.
   - It asserts these lines in `boot-<timestamp>.log`:
     - `virtio_blk` lines for `vda` and `vdb` with 9 and 4 partitions;
     - the virtio-gpu probe (`[drm] pci: virtio-gpu-pci detected`) of the `headless` profile;
     - the first-stage module load of `vmw_vsock_virtio_transport` (the `virtio_console` and `virtio_net` loads are not on hvc0, see below);
     - no panic.
   - On VZ, hvc0 starts only when first-stage init has loaded `virtio_console` (about 0.18 s of uptime), and the earlier kernel lines are not replayed (IR-306). `Booting Linux on physical CPU`, `Kernel command line:`, the PL031 RTC, and the rng and balloon probes are therefore checked in #013 over the serial shell (`su 0 dmesg`, `/proc/cmdline`, `/dev/rtc0`, `/sys/bus/virtio/drivers/`).
   - A second test boots a deliberately truncated ramdisk and expects `failed(.kernelPanic)`. The observed outcome is `failed(.bootStalled(phase: .kernel))`, because the panic text is written before hvc0 exists (IR-361).
   - Record in [android-image.md](../../02-design/android-image.md) §6: the kernel version, the time to each line, and any missing device.
   - Check: both T2 tests pass (`AndroidBootTests`, `AndroidBoot` configuration).

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:**
  - ImageCore: `ImageVersion` ordering, `RuntimeImageManifest` decoding, the `BootconfigWriter` golden vectors and conflicts, the `VMDefinition` mapping (§9.2), and the `serialno` format.
  - RuntimeCore: `BootSignals` golden tests.
- **T0 Python:** `bundle --unsigned` on the fixture set gives the expected file list.
- **T1:** `InstanceStore.provision` and the per-boot initrd on a temporary APFS volume. The initrd SHA-256 is stable for the same inputs.
- **T2:** `LinuxGuestBootconfigTests.testBootconfigTrailer`, `AndroidBootTests.testKernelBoot`, and `AndroidBootTests.testTruncatedRamdiskStallsBoot` (its outcome is `bootStalled`, IR-361).

### Acceptance criteria

- [x] An Android-specific `VMDefinition` is created by `AndroidBootPlanner` and accepted by `VMDefinitionValidator`.
- [x] The kernel command line is passed: `/proc/cmdline` ends with `cmdline.txt` unchanged, and the tokens before it are the kernel's built-in command line and the bootconfig `kernel.*` key (IR-365). The `Kernel command line:` log line is not the check, because it never reaches hvc0 on VZ (IR-360). `AndroidBootTests.testReachesInit` (#013) checks it over the serial shell.
- [x] The bootconfig is passed as the initrd trailer, and `/proc/bootconfig` equals the merged block. The Linux guest check skips on the pinned test kernel (IR-362); `AndroidBootTests.testReachesInit` (#013) checks `/proc/bootconfig` on Android.
- [x] The complete serial output is captured in `~/Library/Logs/APKRun-Dev/vm/console.log` and in `boot-<timestamp>.log`.
- [x] The kernel boots past early init and detects the configured virtio devices, including two virtio block devices with the expected partition counts (the #011 Android check).
- [x] Successful init is not required.
- [x] A kernel panic ends the boot at once with `.kernelPanic`.
- [x] Every boot logs the image version, the bootconfig hash, and the disk identifiers (subsystem `io.apkrun.image`, category `boot`, §14.2).
- [x] A bootconfig over 16 KiB fails the build. Conflicting keys fail with `bootconfigConflict`.

### Notes

- The development-only parts are `bundle --unsigned`, `DevelopmentImage`, and `--bundle`. #065 removes them.
- The `headless` GPU profile starts empty here. #014 fills it and verifies it.
- If `virtio_console` or `virtio_blk` are vendor modules rather than built in, hvc0 output starts only after first-stage init loads them. The kernel replays its buffer, but a panic before that point shows nothing. In that case, record the module list and compare it with the reference `lsmod`.
- The `virtio_blk` lines may appear after first-stage init has started. Wait for them with the same 120 s budget.
- **Product-code verification (2026-10-09, macOS 27.0.1 26A434, build 16373615, branch `task/012-android-kernel-boot`).**
  - `apkrun dev boot --bundle <dir>` boots the stock image through `AndroidBootPlanner`, `VMDefinitionValidator`, `RuntimeSupervisor`, and `VMController`: a first boot was ready in 12.6 s, a later cold boot in 5.4 s. G2 then ran on this code (#014).
  - The console log and the per-boot copies are written to `~/Library/Logs/APKRun-Dev/vm/` (`console.log`, `boot-<timestamp>.log`). They show `[vda]` with nine partitions and `[vdb]` with four.
  - Each boot logs `Prepared boot <id> of image 2026.10.0-cf16373615-arm64 bootconfig sha256 <hash> disks apkrun-os,apkrun-data gpu headless` (category `boot`).
  - T0: `BootPhaseDetectorTests` covers the panic and the boot-failed detail over a captured VZ console log; `AndroidBootPlannerTests` covers the definition, the initrd trailer, the shared bootconfig golden vectors, and `bootconfigConflict`. The 16 KiB build limit is `bootconfig.MAX_BUILD_BOOTCONFIG_SIZE` in `apkrun_image`.
  - Command-line criterion (IR-360, IR-365): on VZ, `Kernel command line:` is printed before hvc0 exists, so it is never in the console log. The criterion compares `/proc/cmdline` with `cmdline.txt` as a suffix, and `AndroidBootTests.testReachesInit` checks it (2026-10-09, passed).
  - Bootconfig criterion (IR-362): `LinuxGuestBootconfigTests.testBootconfigTrailer` is written. The pinned test kernel has no `CONFIG_BOOT_CONFIG`, so it skips with the kernel's warning. `AndroidBootTests.testReachesInit` checks `/proc/bootconfig` on Android (2026-10-09, passed).
  - T2 `AndroidBootTests` (2026-10-09, branch `task/012-android-kernel-boot-closure`): `testKernelBoot` passes in 1.1 s (nine partitions on `vda`, four on `vdb`, the virtio-gpu probe, the vsock module load, no panic). `testTruncatedRamdiskStallsBoot` passes with the outcome of IR-361: `failed(.bootStalled(phase: .kernel))` after 30 s, with no init line, because the unpacking failure happens before hvc0 exists.
  - Still open for #014: `testBootCompleted`, `testPhasesInOrder`, and `testDevConsoleShell`. `testReachesInit` (#013) passes. The G2 acceptance test covers the boot path until then.
  - A forced stop about one second into the boot can leave VZ in `failed` and the stop does not return (IR-363). The `testKernelBoot` stop is bounded at 60 s; the `testTruncatedRamdiskStallsBoot` boot is bounded at 120 s.


---

## #013 Reach Android init

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #012 |
| Requirements | FR-VM-08, NFR-DEV-04 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §4.1, §5.2, §5.3, §6, §7.1, §13; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3; [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Modules / paths | `Images/tools/layouts/cuttlefish-phone-arm64.json`, `Images/tools/apkrun_image/{bootconfig,avb}.py`, ImageCore `Boot/VZPlatformProfile.swift`, RuntimeCore `Boot/BootSignals.swift`, `Tests/IntegrationTests/Support/AndroidShellConsole.swift`, `Tests/IntegrationTests/AndroidBootTests/`, `Images/reference/16373615/expected-differences.yaml` |
| Risks / questions | R-06, R-11 |

### Goal

First-stage init finds the boot devices, maps the dynamic partitions, and switches to second-stage init, which starts services. The serial log shows this, and the Android serial shell answers.

### Scope

- Checking the debug ramdisk, fstab, dynamic partitions, boot device names, AVB, bootconfig, and SELinux.
- Adding the `.init` phase to the detector.
- Using the hvc1 serial shell as the debug channel before ADB exists, with a T2 helper.
- Documenting every deviation from Cuttlefish.
- Out of scope:
  - `system_server` and `boot_completed` (#014).
  - Host-service substitutes (#095).
  - Networking and ADB.

### Deliverables

- The `.init` signal and PerfMarker `ANDROID_INIT` in `BootSignals.swift`.
- `AndroidShellConsole` in `Tests/IntegrationTests/Support/`.
- The corrected layer-2 values in the layout.
- New §13 rows in android-image.md.
- `expected-differences.yaml` entries, each with a reason.

### Implementation steps

1. **`.init` phase.**
   - The first `init: ` line on hvc0 enters `.init` and emits `ANDROID_INIT`. `init: init first stage started!` is printed before hvc0 exists on VZ ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3).
   - If init's kmsg lines do not reach hvc0 at the default log level, add a command-line addition (for example a log-level setting). Record it in the layout with a comment and as a §13 row. (On the spike they did reach hvc0 without one.)
   - Over the serial shell, check what #012 cannot see on hvc0: `su 0 dmesg` contains `Booting Linux on physical CPU` and `Kernel command line:` equal to `cmdline.txt`, `/dev/rtc0` exists, and the console, net, vsock, rng, and balloon drivers are bound under `/sys/bus/virtio/drivers/`.
   - Check: T0 golden test, and a T2 assertion.
2. **Serial shell.**
   - hvc1 becomes `.service("serial")` in developer mode. `apkrun-dev dev boot` always boots with `BootOptions.developerMode = true`.
   - `AndroidShellConsole` sends `<command>; echo __APKRUN_END_<n>__ $?` and reads until the sentinel. It returns stdout and the exit code, and prefixes root commands with `su 0`.
   - Ctrl-C in `apkrun dev boot` now sends `reboot -p` on the serial shell first, and forces `VMController.stop()` after 20 s ([../../02-design/vm.md](../../02-design/vm.md) §9.3).
   - Check: T2 runs `getprop ro.build.fingerprint` and gets the build's fingerprint.
3. **Boot devices, fstab, dynamic partitions.**
   - Confirm the `/dev/block/by-name/*` links that `androidboot.boot_devices` creates, and the fstab chosen by `androidboot.fstab_suffix`.
   - Confirm that first-stage init reads the super metadata and creates the logical partitions for slot `_a` (`slot_suffix`, `force_normal_boot=1`).
   - If the by-name labels are wrong, try the `androidboot.boot_part_uuid` fallback of §5.3.
   - Check: the first-stage log shows the logical partitions created and the switch to the second stage. `ls -l /dev/block/by-name` equals the reference list, minus the §4.2 omissions.
4. **AVB and bootconfig.**
   - Verify that first-stage init accepts `verifiedbootstate=orange`, `vbmeta.device_state=unlocked`, and the `avb.py` digest values.
   - Verify that `cat /proc/bootconfig` over the serial shell equals the merged block of #012.
   - Compare with the launcher capture `Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt` plus the vendor and U-Boot keys of [android-image.md](../../02-design/android-image.md) §6.2.
   - If live VZ evidence shows that direct boot needs a different layer-2 value, update the VZ layout to the observed value and record the key and reason in `expected-differences.yaml`; the original value remains in the #064 capture.
   - Check: no `libfs_avb` error lines, except the messages of the unsigned development vbmeta (CF-16, IR-364). The bootconfig matches, or each difference has an `expected-differences.yaml` entry.
5. **Debug ramdisk and SELinux.**
   - Build 16373615 is userdebug and already debuggable, so the debug ramdisk (`boot-debug.img` or `vendor_boot-debug.img`, if the inventory lists one) is not used. Record this decision in [android-image.md](../../02-design/android-image.md) §6.
   - `getenforce` must equal the reference (`Enforcing`). If `androidboot.selinux=permissive` is needed to make progress, it goes into the layout with `TODO(#NNN)`, a reason, and a tracking issue (NFR-DEV-04). G2 cannot pass while it is set.
   - Check: T2 `getenforce`, and a count of AVC denials compared with the reference.
6. **Fragment policy and documentation.**
   - Compare `lsmod` and the first-stage module-load lines with the reference to confirm that leaving out the RECOVERY fragment is correct (§4.1).
   - Confirm the by-name labels for §5.3.
   - Add one [android-image.md](../../02-design/android-image.md) §13 row, and one `expected-differences.yaml` entry with a reason, for each difference found.
   - Check: the document pull request.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:** the `.init` golden test over the captured VZ console logs.
- **T2** (`AndroidBootTests.testReachesInit`):
  - The console log contains `init: init first stage started!`, `init: init second stage started!`, and at least one `init: starting service` line.
  - Over `AndroidShellConsole`, the test runs `getprop ro.build.fingerprint`, `cat /proc/bootconfig`, `ls -l /dev/block/by-name`, `cat /proc/mounts`, `getenforce`, and `lsmod`, and compares the output with the reference where a category exists.

### Acceptance criteria

- [x] The debug ramdisk, fstab, dynamic partitions, boot device names, AVB, bootconfig, and SELinux are each checked, and each result is recorded in [android-image.md](../../02-design/android-image.md) §6.6.
- [x] Every deviation from Cuttlefish is documented: rows CF-16 to CF-19 in [android-image.md](../../02-design/android-image.md) §13, and the entries with reasons in `expected-differences.yaml` (25 bootconfig and 5 cmdline entries).
- [x] The serial logs show init running and service startup beginning.
- [x] `.init` and `ANDROID_INIT` are emitted.
- [x] The Android serial shell answers commands in developer mode.
- [x] The SELinux mode equals the reference: `getenforce` is `Enforcing` and the boot has no AVC denial. No permissive workaround is set.

### Notes

- The strings come from [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3, observed on VZ (IR-306). Update `BootSignals.swift` and the document together.
- `/data` does not mount until #095 provides KeyMint. Failures after `post-fs-data` belong to #095 and #014.
- **Product-code status (2026-10-09).** `AndroidBootTests.testReachesInit` passes in 15.3 s on the product path, in developer mode. It checks the `dmesg` lines, `/proc/cmdline` and `/proc/bootconfig` (the planner's merged block), the bound virtio devices, `/dev/rtc0`, `getenforce`, AVC denials, every GPT label in `/dev/block/by-name`, the fstab, the boot properties, and the AVB messages. The results are in [android-image.md](../../02-design/android-image.md) §6.6. Two findings changed the plan: the kernel log buffer wraps before the shell answers, so `log_buf_len=2M` is added (CF-18, IR-366), and the balloon device has no driver (IR-369). The `expected-differences.yaml` file holds the reference differences, which the #014 capture diff checks.

---

## #095 Cuttlefish host-service substitution

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #013 |
| Requirements | FR-VM-04, FR-VM-08 ([../traceability.md](../traceability.md) §2.1) |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §7; [../../02-design/vm.md](../../02-design/vm.md) §6.2, §6.3, §7, §8; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §3 |
| Modules / paths | the layout `consolePorts` and `bootconfig.image` sections; RuntimeCore `Boot/ConsolePortPlan.swift`; `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/{LinuxGuestTests,AndroidBootTests}/`; [android-image.md](../../02-design/android-image.md) §7 and §13 |
| Risks / questions | R-12 |

### Goal

Every Cuttlefish host dependency has a decided and verified substitute. Android userspace does not block or crash-loop on a missing host service, and the guest network works.

### Scope

- The 20-port numbering check and `ConsolePortPlan`, with ports 10–19 on one multiport device ([../../02-design/vm.md](../../02-design/vm.md) §6.1).
- The final port roles of §7.1, including the "no sensors" responder on hvc18.
- In-guest KeyMint and Gatekeeper.
- The vsock service decisions of §7.3.
- Networking in the order of §7.4.
- The other guest expectations of §7.6, including the first-boot settings (Bluetooth off, Wi-Fi joined to `VirtWifi`).
- The Weaver and LockSettings check.
- Out of scope:
  - The ADB forwarder (#015).
  - Audio (#083).
  - A host-side KeyMint.
  - Input (#024).
  - The GPU (#021).
  - Custom-image changes (#035).

### Deliverables

- The `apkrun.test=ports` check with `apkrun.test.portcount=20` in `Tests/Fixtures/linux/init`.
- `ConsolePortPlan`, as a data table in RuntimeCore.
- The sensors responder in RuntimeCore, attached to the `.service("sensors")` port (§7.1).
- The first-boot settings step in RuntimeCore (§7.6).
- The final layout `consolePorts`.
- The `androidboot.vendor.apex.*` keys for KeyMint and Gatekeeper, and the `androidboot.wifi_impl` value, in the layout.
- The [android-image.md](../../02-design/android-image.md) §7 verification: one decision per port and per service, and the client behaviour when a host service is missing.
- New §13 rows and `expected-differences.yaml` entries.
- The R-12 result in [../risks.md](../risks.md).

### Implementation steps

1. **20-port numbering.**
   - Boot the Linux test guest with `apkrun.test=ports apkrun.test.portcount=20`. The host writes `APKRUN-PORT-<i>\n` into port *i*, and the guest prints which `/dev/hvcN` received which marker ([../../02-design/vm.md](../../02-design/vm.md) §6.2).
   - If the mapping is not the identity, `ConsolePortPlan` reorders the array so that the guest numbering matches the Cuttlefish map.
   - VZ refuses more than 10 single-port devices (observed 2026-10-08), so ports 10–19 are the console ports of one multiport device ([../../02-design/vm.md](../../02-design/vm.md) §6.1). The check covers all 20 ports across both device kinds.
   - Check: `LinuxGuestTests.testTwentyConsolePorts` passes.
2. **Port roles.**
   - Finalize the layout `consolePorts` from the §7.1 table: hvc0 `.systemConsole`, hvc1 `.service("serial")` in developer mode, hvc2 `.log("logcat")`, hvc18 `.service("sensors")` with the responder of §7.1, and the other ports `.silent`.
   - On Android, list the holder of each `/dev/hvc*` through the serial shell and compare with the reference "hvc users" category.
   - Check: no HAL crash-loops on a silent port in the hvc2 logcat capture. A crash loop means the same service exits and restarts three or more times within 10 minutes.
3. **Security HALs.**
   - Set the `androidboot.vendor.apex.*` keys that select the in-guest insecure KeyMint and Gatekeeper: `com.android.hardware.keymint.rust_nonsecure` and `com.android.hardware.gatekeeper.nonsecure`, as in the launcher capture (§7.2).
   - Check:
     - `service list` shows the KeyMint (`IKeyMintDevice/default`) and Gatekeeper services;
     - vold mounts `/data` with metadata encryption (`/proc/mounts` shows `/data`);
     - the first boot formats `userdata` (the `formattable` path of §5.2).
4. **vsock services and absent host services.**
   - Leave out the keys of host-side clients (`vsock_tombstone_port`, `vhal_proxy_server_port`) and the automotive `auto_eth_guest_addr`. Keep `modem_simulator_ports` and the keys of guest-side servers (`vsock_lights_*`, `vendor.audiocontrol.server.*`, `openthread_node_id`): the spike showed their HALs abort without them (§7.3).
   - For each client that the reference bootconfig configures, record in [android-image.md](../../02-design/android-image.md) §7.3 whether it stays idle, exits once, or crash-loops. The clients include tombstone transmit, the RIL and modem simulator, camera, and audio control.
   - Do the same for RIL, Bluetooth, NFC, UWB, GNSS, and sensors (§7.6). Keep them unless they crash-loop, and record the findings for #035.
   - Check: `/dev/rtc0` exists and `date` is sane (§7.6, from #012).
5. **Network.**
   - Option 1 of §7.4 (one NAT NIC as Wi-Fi) cannot work with the stock image: `setup_wifi` uses `eth2`, and the OpenThread HAL needs `eth1` (spike, IR-306).
   - Use option 2: three NICs in Cuttlefish order, `androidboot.wifi_impl=virt_wifi`, and the `eth2` MAC derived from `wifi_mac_prefix` (§7.4). This makes `VMDefinition.network` an ordered list, a VirtualMachineCore change noted in [../../02-design/vm.md](../../02-design/vm.md) §7.
   - Option 3 (Ethernet) exists only on the custom image. Record it and do not implement it here.
   - Check: `ip addr` shows an address, a default route exists, and `ping -c 1 connectivitycheck.gstatic.com` resolves the name. `dumpsys connectivity` shows a VALIDATED network, which means NetworkMonitor's `generate_204` probe passed.
6. **Checks that need system_server.**
   - As soon as the boot reaches `.systemServer`, check two things: that LockSettings does not wait for Weaver on hvc13 (`logcat -s LockSettingsService`), and the `dumpsys connectivity` result of step 5.
   - If the boot does not reach `system_server` by the end of this task, move these checks and their acceptance criteria to #014 in the same pull request ([README.md](README.md) §4).
   - Then write the §7 verification, the §13 rows, the `expected-differences.yaml` entries, and the R-12 result.
   - Check: the document pull request.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:** `ConsolePortPlan` reordering for an identity mapping and for a permuted mapping.
- **T2:**
  - `LinuxGuestTests.testTwentyConsolePorts`.
  - `AndroidBootTests.testHostServiceSubstitutes`: the KeyMint and Gatekeeper services are present, `/data` is mounted, the hvc holders match, and there is no crash loop within 10 minutes.
  - `AndroidBootTests.testNetwork`: address, route, DNS, and a validated network.

### Acceptance criteria

- [ ] All 20 console ports are attached. Their numbering is verified with the `APKRUN-PORT-<i>` markers, and `ConsolePortPlan` is applied if needed. Open (IR-372): the pinned test kernel creates eight `hvc` nodes, so the marker check passes for eight ports (`testConsolePortMarkersMatchTheirNumbers`) and the 20-port check skips with that reason. The Android kernel creates `hvc0` through `hvc19` with the 20 ports, and the VZ capture shows their holders; no marker test runs there.
- [x] Each hvc port has a recorded role. No HAL crash-loops on a silent port.
- [x] In-guest insecure KeyMint and Gatekeeper are selected by bootconfig, and vold mounts `/data`.
- [x] The behaviour of each vsock client whose key is left out is recorded in [android-image.md](../../02-design/android-image.md) §7.3.
- [ ] The guest has a working network: an address, a default route, DNS resolution, and a validated network in `dumpsys connectivity` (FR-VM-04). Open (IR-374): on the current first boot Wi-Fi reads as disabled after the first-boot settings, `wlan0` has no carrier, and no IPv4 address or DNS follows. `testNetwork` checks the design's configuration and records the state.
- [x] LockSettings does not wait for Weaver. `testHostServiceSubstitutes` passes on the stock image: KeyMint and Gatekeeper are registered, `/data` is mounted, and `logcat` has no Weaver timeout or failure line.
- [x] RIL, Bluetooth, NFC, UWB, GNSS, and sensors are kept unless they crash-loop, and the findings are recorded.

### Notes

- Prefer in-guest implementations selected by configuration over host-side re-implementations (§7). Do not remove guest services unless they are shown to break boot, stability, or resource use.
- vsock ports 6120–6199 are reserved for future substitutes. v1 substitutes are host-initiated only (§7.3).
- **Product-code status (2026-10-09, #095).** The layout's `consolePorts` give every port a role, `VZConfigurationBuilder` attaches ports 10–19 on one multiport device, and `RuntimeSupervisor` runs the sensors responder on `sensors_control` (hvc18). The port test (`apkrun.test.portcount`) passes for eight ports, the identity mapping. The test kernel exposes only `hvc0`–`hvc7` (IR-372), so the 20-port check skips. `testHostServiceSubstitutes` passes. `testNetwork` fails on the Wi-Fi join (IR-374, a follow-up). The results are in [android-image.md](../../02-design/android-image.md) §7.8.
- **Spike findings (2026-10-08; IR-306).** The direct-boot spike settled most decisions of this task before the production code exists: the 10-port limit and the multiport device, the sensors wait and its responder, the keys that must stay, three NICs with `virt_wifi`, and Bluetooth. The handling is in [android-image.md](../../02-design/android-image.md) §7. This task builds it into RuntimeCore, the layout, and VirtualMachineCore, and verifies it with the tests above. The sensors responder is a host-side substitute: no configuration selects another sensors implementation in this build (§7.1).

---

## #014 Reach system_server and boot_completed

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #013, #095 |
| Gate | G2 |
| Requirements | FR-VM-08 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §6–§8, §13, §14.2; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2, §3.3; [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §4; [../../02-design/cli.md](../../02-design/cli.md) §5; [../roadmap.md](../roadmap.md) §2 (G2) |
| Modules / paths | RuntimeCore `Boot/{BootPhaseDetector,BootSignals}.swift`, `Supervisor/RuntimeSupervisor.swift`; RuntimeHost dev console service; `CLI/apkrun/Dev/`; the layout `gpuProfiles.headless`; `Images/tools/reference/compare_boot.py`; `Images/reference/16373615/expected-differences.yaml`; `Tests/IntegrationTests/AndroidBootTests/`; `Tests/AcceptanceTests/G2/`; `scripts/run-gate.sh` |
| Risks / questions | R-06, R-11, R-12 |

### Goal

The stock image reaches `sys.boot_completed=1`, the host detects it, and Android stays up for 10 minutes. The VZ boot differs from the reference only in explained ways. Gate G2 passes.

### Scope

- Resolving framework and service failures.
- Completing the host-side readiness monitor: all phases, timeouts, stall detection, markers, and `boots.jsonl`.
- Reading `sys.boot_completed` through the serial shell, which is the debug channel available before #015.
- The development-only `headless` GPU profile.
- `apkrun dev console --android-shell`.
- The VZ capture and the reference diff.
- The G2 acceptance check.
- Out of scope:
  - ADB (#015), the GPU (#021), agents (#072), and apkrund (#031).
  - Boot-time tuning.

### Deliverables

- The complete `BootSignals.swift` for console signals. #015 adds the ADB signals.
- The completed `gpuProfiles.headless` in the layout.
- The RuntimeHost dev console service and `apkrun dev console [--android-shell]`.
- The VZ-capture mode of `compare_boot.py`, and a complete `expected-differences.yaml`.
- `Tests/AcceptanceTests/G2/` and `scripts/run-gate.sh G2`.
- Verification entries in [android-image.md](../../02-design/android-image.md) §6–§8 and §13, and results for R-06, R-11, and R-12 in [../risks.md](../risks.md).

### Implementation steps

1. **Readiness monitor.**
   - Add the console signals:
     - `.systemServer` on `init: starting service 'zygote'`, with PerfMarker `SYSTEM_SERVER_READY`;
     - `.bootCompleted` on `VIRTUAL_DEVICE_BOOT_COMPLETED`, with PerfMarker `BOOT_COMPLETED`;
     - `VIRTUAL_DEVICE_BOOT_FAILED` gives `failed(.androidBootFailed)`.
   - Add the whole-boot timeouts of 180 s and 900 s (`runtime.bootTimeoutSeconds`, `runtime.firstBootTimeoutSeconds`) and the stall limits of 90 s and 600 s, which give `.bootTimedOut(phase)` and `.bootStalled(phase)`.
   - Write one record per boot to `perf/boots.jsonl`.
   - In M1, `ready` is entered at `.bootCompleted`, because steps 3 and 7–9 of [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2 do not exist yet.
   - Check: T0 golden tests over the captured console logs, and timeout and stall tests with a test clock.
2. **Headless GPU profile.**
   - Fill `gpuProfiles.headless` with the launcher's `guest_swiftshader` graphics keys from the `default` capture, and set `VMDefinition.builtInDisplay` for it ([../../02-design/android-image.md](../../02-design/android-image.md) §9.1). Cuttlefish's no-GPU set does not boot the stock image: zygote and SurfaceFlinger abort without EGL, and `init.cutf_cvm.rc` waits for `/dev/dri/card0` (IR-307).
   - Add `.headless` to `GPUProfileID`. `apkrun-dev dev boot --gpu none` selects it. It is never written into a release bundle.
   - Check: SurfaceFlinger does not crash-loop, and the boot animation exits.
3. **Resolve failures.**
   - Iterate over the hvc2 logcat capture (`guest/logcat-<timestamp>.log`) and the console until `sys.boot_completed=1`.
   - Every fix is a bootconfig, layout, or command-line change. The originals are never modified.
   - Each fix is recorded as a §13 row and an `expected-differences.yaml` entry.
   - Check: `AndroidBootTests.testBootCompleted` passes.
4. **`apkrun dev console [--android-shell]`.**
   - While `apkrun-dev dev boot` owns the VM, RuntimeHost serves hvc0, and hvc1 in developer mode, on Unix sockets `$APKRUN_HOME/Runtime/dev-console/<port>.sock`. The sockets have mode 0600 and are removed at stop.
   - `apkrun-dev dev console` attaches to hvc0. With `--android-shell` it attaches to hvc1. It fails with a typed error when no `apkrun dev boot` process owns the instance.
   - Check: `apkrun-dev dev console --android-shell`, then `getprop sys.boot_completed`, prints `1`.
5. **VZ capture and diff.**
   - `python3 Images/tools/reference/compare_boot.py capture-vz --shell $APKRUN_HOME/Runtime/dev-console/hvc1.sock --out Images/work/16373615/vz-capture/` runs `guest-capture.txt` over the serial shell.
   - Then `python3 Images/tools/reference/compare_boot.py Images/reference/16373615/incomplete/default-20261001T120904-49816 Images/work/16373615/vz-capture/` compares the categories the launcher capture holds (cmdline and bootconfig); the other categories have no booted reference (IR-305) and are recorded, not compared.
   - Explain every difference in `expected-differences.yaml`. Graphics differences get the reason "M1 headless; GPU from #021".
   - Check: exit 0 with no unexplained difference.
6. **G2 acceptance.**
   - `scripts/run-gate.sh G2` runs `Tests/AcceptanceTests/G2/` on the reference Mac with a clean build from `main`. It resets the instance, then runs five cold boots in a row. The first boot uses the first-boot timeout.
   - For each boot, it asserts:
     - `.bootCompleted` is detected and `BOOT_COMPLETED` is logged;
     - `getprop sys.boot_completed` over the serial shell returns `1`;
     - over 10 minutes, `sys.system_server.start_count` stays `1`, the logcat has no watchdog kill of system_server, and there is no HAL crash loop (as defined in #095);
     - after the last boot, the reference diff passes.
   - Record the result in [android-image.md](../../02-design/android-image.md) §8 and in R-06, R-11, and R-12.
   - Check: the gate passes, and the nightly T3 run includes it.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:** `BootSignals` golden tests for every phase. Monotonic phases and first-signal-wins. Timeouts and stall with a test clock. `boots.jsonl` record encoding.
- **T0 Python:** `compare_boot.py capture-vz` against a fake socket that replays a recorded session.
- **T1:** the dev console socket: mode 0600, removal at stop, and the typed error without an owner.
- **T2:** `AndroidBootTests.testBootCompleted`, `testPhasesInOrder`, and `testDevConsoleShell`.
- **T3:** `Tests/AcceptanceTests/G2/`.

### Acceptance criteria

- [x] The framework and service failures that blocked boot are resolved. Each fix is recorded in [android-image.md](../../02-design/android-image.md) §13 (CF-16 to CF-19 and the bootconfig and command-line rows) and in `expected-differences.yaml`.
- [x] A host-side readiness monitor (`BootPhaseDetector`) emits `.kernel`, `.init`, `.systemServer`, and `.bootCompleted` with their PerfMarkers. It fails boots with typed errors on panic, boot failure, timeout, and stall. `BootWatch` decides the timeouts and stalls with a test clock (8 T0 tests), and `BootPhaseDetector` has 6 T0 tests over the console log.
- [x] `sys.boot_completed` is read through an available debug channel, the Android serial shell, and its value is `1`.
- [x] Android stays stable for 10 minutes: no `system_server` restart, no watchdog, and no HAL crash loop.
- [x] `BOOT_COMPLETED` is logged as a boot phase marker, and each boot has a `perf/boots.jsonl` record (the five G2 boots each wrote one, with `BOOT_COMPLETED` and `outcome` `ready`).
- [x] Five cold boots in a row pass.
- [x] The reference diff has no unexplained difference: 30 differences, all explained, exit 0 (the G2 run at `691e114`; `expected-differences.yaml` is read beside `Images/reference/16373615/`).
- [x] Gate G2 passes on the reference Mac with a clean build from `main`. The result is recorded in [android-image.md](../../02-design/android-image.md) §8 and in [../risks.md](../risks.md) (R-06, R-11, R-12). Passed on clean `main` at `70d81f3` on 2026-10-10 with `scripts/run-gate.sh G2`: five cold boots, each stable for 600 s, `sys.boot_completed=1` five times, 3062.7 s, 6 run / 3 skipped / 0 failures, report status passed (IR-376). The earlier pass on the task branch at `691e114` is superseded. Passed again on `4961787`, the final `main` with #072 and #022 (2026-10-10, 3060.3 s, five cold boots, 600 s dwell each, 6 run / 3 skipped / 0 failures, status passed).

### Notes

- If no headless configuration reaches `boot_completed`, stop and follow [../roadmap.md](../roadmap.md) §2, "When a gate does not pass". Record it in R-06 and R-12, and file a follow-up task (#098 or the next free number) that attaches the #019 virtio-gpu device for M1.
- A gate failure is recorded in the design document's verification log and in [../risks.md](../risks.md) (status `realized` if a fallback is taken).
- The console strings for `.systemServer` depend on the console log level ([runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3). If `starting service 'zygote'` is not visible, the ADB signal of #015 or the serial-shell reading covers it.
- **VZ direct-boot spike (2026-10-08; IR-306).** The stock image reached `VIRTUAL_DEVICE_BOOT_COMPLETED` on VZ in 7.5 s on a first boot, and `Experiments/vz-android-boot/g2_spike.py` passed the G2 conditions over five cold boots (each stable for 10 minutes, no `system_server` restart, no Watchdog kill, no crash loop). The one framework failure was the sensors wait of [android-image.md](../../02-design/android-image.md) §7.1: `system_server` blocked in `SystemSensorManager.nativeCreate` and its Watchdog killed it after 185 s. The headless profile needs VZ's 2D virtio-gpu (step 2). This task builds the same result into the product code and runs the gate.
- **G2 with the product code (2026-10-09, arm64 Mac17,9, macOS 27.0.1 26A434, build 16373615, branch `task/012-android-kernel-boot` at `ec72fa2`).**
  - `G2AndroidBootTests.testFiveColdBootsReachBootCompletedAndStayStable` passed in 3046.6 s (`xcodebuild test … -testPlan AcceptanceTests -only-test-configuration G2`, the default 600 s dwell). It resets the instance, then boots five times through `RuntimeSupervisor` with the `headless` profile.
  - `BOOT_COMPLETED` came 12.4 s after the start on the first boot and 5.2–6.0 s on the four cold boots. `ready`, after the serial-shell confirmation and the first-boot settings, came at 13.7 s, then 5.8, 5.3, 5.6, and 6.1 s.
  - On every boot, `getprop sys.boot_completed` over the serial shell was `1`. After 10 minutes `sys.system_server.start_count` was still `1`, neither logcat nor the console had `WATCHDOG KILLING SYSTEM PROCESS`, and no init service exited more than twice (`apexd` twice per boot; `artd` and `media.codeclist.generator` twice on the first boot only).
  - The first attempt was stopped by XCTest's default 10-minute execution time allowance during boot 2. The plan's `maximumTestExecutionTimeAllowance` only caps the allowance, so the test now sets its own (`ec72fa2`).
  - Ticked from this run: the serial-shell reading, the 10-minute stability, and the five cold boots.
  - Closed since the 2026-10-09 run above (the branch is rebased onto `main` at `0770318`):
    - `perf/boots.jsonl`: each boot writes a record with its markers and outcome.
    - The `compare_boot.py capture-vz` diff: 30 explained, 0 unexplained (`expected-differences.yaml` beside `Images/reference/16373615/`).
    - The dev console sockets: `DevConsoleSocketTests` (mode 0600 in a 0700 directory, removal at stop, a second client refused, `devConsoleNotRunning` without an owner) and `testDevConsoleShell`.
    - The T0 timeout and stall decisions: `BootWatch` (8 tests with a test clock). The `waitForBootCompletion` loop itself has no T0 test; the stale `.stopped` replay that ended every boot was found by `testBootCompleted` and the gate (`b2aa305`).
  - **G2 at the rebased tip (2026-10-09, `691e114`, default dwell).** LinuxGuest: 49 run, 16 skipped, 0 failed. G2: passed in 3063 s, 6 run, 3 skipped, 0 failed. The five cold boots: `BOOT_COMPLETED` at 11.65 s (first boot), then 6.35, 7.41, 5.36, and 5.35 s; ready at 12.8, 6.4, 7.4, 5.4, and 5.4 s; `sys.boot_completed` read as `1` on each; ten minutes stable each (`sys.system_server.start_count` 1, no watchdog, no crash loop). The reference diff: 30 explained, 0 unexplained, exit 0.
  - **The T2 suites on the review-fixed tip.** `AndroidBoot` at `022b154`: 50 run, 9 skipped, 0 failed, the skipped ones being `AndroidNetworkTests` and the other configurations' tests. `AndroidPackage` at `3099d9a`: 49 run, 16 skipped, 0 failed; the four `AndroidPackageTests` skip because `Tests/Fixtures/AndroidApps/out/HelloText.apk` needs Android build-tools 37.0.0, which this host does not have. Earlier `AndroidBoot` counts at `3099d9a`: `testBootCompleted`, `testPhasesInOrder`, `testReachesInit`, `testKernelBoot`, `testTruncatedRamdiskStallsBoot`, `testHostServiceSubstitutes`, and `testDevConsoleShell` pass. `testNetwork` moved to its own `AndroidNetwork` configuration (#095, IR-374). `AndroidADB` (with `APKRUN_ANDROID_HOME` set): 49 run, 14 skipped, 0 failed; `testDevelopmentBootServesADBOnLoopbackOnlyAndStopsGracefully` passes. `testNetwork` is #095's and is intermittent on the validated stage (IR-374).
  - **Independent review of `0c5ad6c`, fixed on the branch:** a stop during the VM start never returned, and the VM kept running (the controller refuses to stop a starting VM, and the drain waited for it); the supervisor now detaches the controller before it waits, and the boot stops the VM after the start returns (`e8e0c34`). `fail()` stops a VM that is not stopped after a stop request. A second `ensureReady` during a boot is refused (`e8e0c34`). `testStopDuringStartReturnsAndStopsTheVM` (T2, `29eedb2`, timing in `022b154`) covers the window; the log of the run shows the rejected stop from `starting`. It is T2 rather than T0 because a T0 test would need a fake image and a driver seam in `RuntimeSupervisor`. `testKernelPanicDetected` is renamed `testTruncatedRamdiskStallsBoot` (IR-361). The IntegrationTests plan no longer retries a failed test (`57a3d5f`). The skip-counts-as-pass decision is recorded in IR-376.
  - **Gate bugs found by re-runs, fixed on the branch:** the VM controller's initial `.stopped` ended every boot (`b2aa305`); the reference diff did not find the expected-differences file (`6da60d7`); the test homes of read-only images were left behind (`bd3845c`); the dmesg count read a root-only file as the shell user (`365dc0a`); two catalog and extraction expectations were stale (`3275171`, `00fa1a2`).
  - **Still open:**
    - The clean-`main` G2 run after the merge: `scripts/run-gate.sh G2` in the main checkout. The gate closes only from `main` (IR-376).
    - The network's validated stage (IR-374, #095; run with `-only-test-configuration AndroidNetwork`, not part of this task).
    - The 20-port marker check: the test kernel exposes eight `hvc` nodes (IR-372).
- **DevConsoleSocket flake (2026-10-10, #072 review).** `devConsoleSocketRelaysBothWaysAndRefusesASecondClient()` failed in 2 of 5 full `swift test` runs (the root package, 621 tests each): the first RuntimeCore run and the first RuntimeHost run. The assertion was `Expectation failed: readUntil(client, containing: "guest output").contains("guest output")` at `DevConsoleSocketTests.swift:90:5`. The test passed in the other three full runs and alone (3 of 3). The #072 change does not touch the dev console, and the test is unchanged. Its wait is the likely source; a fix belongs to a separate task.
- **Launch-option ladder (2026-10-08; see IR-298 to IR-301).** In this host configuration `--gpu_mode=none`, the design's headless profile, did not start the Android VM (IR-300), so `gpuProfiles.headless` has no boot evidence yet. The `system_server` Watchdog timeout is a DeviceConfig key, not a host bootconfig key (IR-301). This task stays open.

---

## #015 ADB debugging over vsock

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #014, #007 |
| Requirements | FR-RT-05, NFR-SEC-06 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §7.3; [../../02-design/vm.md](../../02-design/vm.md) §8, §9.3; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2 (step 6), §3.3; [../../02-design/cli.md](../../02-design/cli.md) §5; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.5; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §4 |
| Modules / paths | RuntimeCore `Android/AdbClient.swift`, `Boot/BootSignals.swift`, `Supervisor/RuntimeSupervisor.swift`; `CLI/apkrun/Dev/`; `Tests/IntegrationTests/AndroidADBTests/` |
| Risks / questions | None |

### Goal

In developer mode, `adb -s 127.0.0.1:6520` reaches the guest's adbd through vsock 5555, only from host loopback, and the standard ADB commands work.

### Scope

- Configuring the #007 `VsockLoopbackForwarder` at step 6 of [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2.
- `AdbClient` in RuntimeCore.
- The ADB readiness signals.
- The development stop through `adb shell reboot -p`.
- `apkrun dev adb`.
- Checking the connection documentation.
- Out of scope:
  - The ADB `AndroidControlChannel` implementation and package operations (#027).
  - The Guest Agent (#072).
  - Shipping `adb` (the developer's `platform-tools` is used).

### Deliverables

- `AdbClient`: resolution, connect, typed errors, a count of `adb shell` invocations, and helper methods.
- The forwarder setup in `RuntimeSupervisor`.
- The ADB signals in `BootSignals.swift`.
- `apkrun dev adb [<args>…]`.
- `Tests/IntegrationTests/AndroidADBTests/`.

### Implementation steps

1. **Guest side.**
   - Confirm that adbd listens on vsock 5555 (`persist.adb.tcp.port=5555`). `VMController.connect(vsockPort: 5555)` must succeed after `.bootCompleted`; before that it returns `.vsockPortNotListening`.
   - Record `ro.adb.secure` from the VZ boot. (Spike, 2026-10-08: `ro.adb.secure` is unset on build 16373615, `persist.adb.tcp.port` is `5555`, adbd accepted a connection through a loopback → vsock 5555 forwarder without a key prompt, and `adb root` worked.)
   - If `ro.adb.secure=1`, developer mode appends the developer's `~/.android/adbkey.pub` to `/data/misc/adb/adb_keys` over the serial shell before the first connect.
   - Check: T2 connect succeeds.
2. **Forwarder.**
   - `RuntimeSupervisor` starts `VsockLoopbackForwarder` with guest 5555 ↔ `127.0.0.1:6520`, only when `BootOptions.developerMode` is true (`androidboot.apkrun.devmode=1`).
   - If port 6520 is in use, the boot continues without ADB, and the error is logged with its domain and code.
   - Check: `lsof -nP -iTCP:6520 -sTCP:LISTEN` shows only `127.0.0.1`.
3. **`AdbClient`.**
   - Resolve `adb` from `$ANDROID_HOME/platform-tools/adb`, then from `PATH`.
   - Run `adb connect 127.0.0.1:6520` with backoff, then pass `-s 127.0.0.1:6520` to every command.
   - Apply per-command timeouts and typed errors, and count `adb shell` invocations ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15, #034).
   - All command strings live inside helper methods: `getprop`, `shell`, `install`, `uninstall`, `listPackages`, `dumpsysPackage`, `startActivity`, `forceStop`, `pidof`, `dumpsysActivities`, `logcat`, and `rebootPowerOff`. This way the #027 lint needs no exceptions.
   - Check: T0 builds the command lines, parses the output, and maps errors, using a fake `adb` executable.
4. **ADB signals and stop.**
   - Once `adb` connects, poll every 500 ms:
     - `getprop sys.system_server.start_count` non-empty enters `.systemServer`;
     - `getprop sys.boot_completed` = `1` enters `.bootCompleted`.
   - The first signal wins ([runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3).
   - Ctrl-C now runs `adb shell reboot -p` and forces `VMController.stop()` after 20 s ([../../02-design/vm.md](../../02-design/vm.md) §9.3).
   - Check: T0 detector tests with mixed console and ADB signals. T2 graceful stop.
5. **`apkrun dev adb [<args>…]`.**
   - Run `adb -s 127.0.0.1:6520 <args>` and pass the exit code through.
   - If `adb` is missing, fail with a message that names [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §2.5.
   - Check the connection documentation in [cli.md](../../02-design/cli.md) §5, [android-image.md](../../02-design/android-image.md) §7.3, and [environment-setup.md](../../05-development/environment-setup.md) §8 against the behaviour, and fix it in the same pull request where it differs.
   - Check: `apkrun-dev dev adb shell getprop sys.boot_completed` prints `1`.
6. **Loopback-only check.**
   - T2 connects to port 6520 on every non-loopback address of the Mac and expects the connection to be refused.
   - With `BootOptions.developerMode = false` (set in the test through `RuntimeSupervisor`), nothing listens on 6520.
   - Check: T2 passes.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:** `AdbClient` against a fake `adb` script. The detector with ADB signals.
- **T2** (`AndroidADBTests`):
  - `adb shell getprop`, `adb shell ps -A`, `adb shell pm list packages`, and `adb logcat -d`.
  - `getprop sys.boot_completed` = `1`.
  - Loopback only, and developer mode on and off.
  - Graceful stop.

### Acceptance criteria

- [x] ADB is enabled for the development image in developer mode. With developer mode off, nothing listens on 6520. (T2 `AndroidADBTests`: `testDevelopmentBootServesADBOnLoopbackOnlyAndStopsGracefully` and `testDeveloperModeOffListensOnNoPort`, passed on 2026-10-09.)
- [x] The connection is documented: `adb -s 127.0.0.1:6520`, `apkrun dev adb`, and the troubleshooting entry. ([cli.md](../../02-design/cli.md) §5, [android-image.md](../../02-design/android-image.md) §7.3, [environment-setup.md](../../05-development/environment-setup.md) §8.)
- [x] ADB is not exposed beyond the host: it listens on `127.0.0.1` only, and connections to other addresses are refused (NFR-SEC-06). The T2 check reads `lsof` and tries every non-loopback IPv4 address; T1 `VsockLoopbackForwarderSystemTests` checks the same `lsof` result.
- [x] `adb shell getprop`, `adb shell ps -A`, `adb shell pm list packages`, and `adb logcat` succeed. `adb shell getprop sys.boot_completed` prints `1`. (T2, and `apkrun dev adb shell getprop sys.boot_completed` printed `1` on a live boot.)
- [x] The ADB readiness signals feed `BootPhaseDetector` (`BootPhaseDetectorTests`: ADB-only, mixed, and never-reentering sequences).
- [ ] Ctrl-C stops Android with `reboot -p` and falls back to a forced stop after 20 s. The graceful path is verified: the stop took 2 s, the guest logged `reboot: Power down`, and the T2 check asserts that the stop takes under 20 s. The forced fallback is not exercised by any test, because no check makes the guest ignore `reboot -p`. Follow-up: a test or fault hook that keeps Android running.

### Notes

- The guest's own `socket_vsock_proxy` (6520 → tcp 5555) keeps running and is unused (§7.3).
- Use only `$ANDROID_HOME/platform-tools/adb`. A second adb server from another SDK causes `device offline` ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §8). On this host the default adb server on port 5037 was started by the Homebrew cask, so the T2 configuration uses its own server on port 15037 ([IR-323](../implementation-review.md#ir-323-give-the-adb-tests-a-private-adb-server-and-drop-stale-transports-before-connecting)).
- `ro.adb.secure` is unset on build 16373615 (checked 2026-10-09), so the key-append branch of step 1 is not implemented ([IR-322](../implementation-review.md#ir-322-do-not-implement-the-adb-key-append-on-the-stock-image)).
- The forwarder is a POSIX socket, not `NWListener` ([IR-315](../implementation-review.md#ir-315-bind-the-adb-loopback-forwarder-with-a-posix-socket-not-nwlistener)). The port-in-use and listen-failure paths are IR-316 and IR-321.
- Step 5 writes `apkrun-dev`. The embedded CLI is the `apkrun` binary built with `--traits EmbeddedRuntime`, so the check runs as `apkrun dev adb shell getprop sys.boot_completed`.
- Verification (2026-10-09): T0 `AdbClientTests` (15 tests with the stale-transport case), `BootPhaseDetectorTests`, and `DevAdbTests` (3) passed; T1 `VsockLoopbackForwarderSystemTests` (6) passed; T2 `AndroidADBTests` passed 2 of 2 (`xcodebuild`, AndroidADB configuration, under `lockf -k /tmp/apkrun-vm.lock`).
- Adversarial review (2026-10-09) fixed the descriptor race in the forwarder, the listener left open after `stop()`, the accept spin on descriptor exhaustion, the connect deadline overrun, the timeout path without SIGKILL, the mislabelled timeout errors, the event order between the console and ADB sources, a stop during the VM start, and the power-off deadline. The review's remaining findings are IR-325 (half-close), IR-326 (`AdbClient.shell` stays public), and IR-327 (a stop during the start leaves the boot failed). The T2 suite was run again after those fixes and passed 2 of 2.

---

## #016 Install HelloText APK

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #015 |
| Requirements | FR-PKG-01, NFR-CMP-01 |
| Design | [../../02-design/package-store.md](../../02-design/package-store.md) §6.1; [../../02-design/cli.md](../../02-design/cli.md) §5; [../../05-development/build-system.md](../../05-development/build-system.md) §8, §8.1, §14; [../../01-architecture/modules.md](../../01-architecture/modules.md) §5 |
| Modules / paths | `Tests/Fixtures/AndroidApps/` (Gradle project, module `HelloText`), `Tests/Fixtures/signing/test-fixture-a.jks`, `scripts/build-fixtures.sh`, RuntimeCore `Android/AdbClient.swift`, `Tests/IntegrationTests/AndroidPackageTests/` |
| Risks / questions | None |

### Goal

HelloText builds reproducibly. `adb install` installs it through a PackageInstaller session, and PackageManager reports the expected metadata. It can be uninstalled.

### Scope

- The fixture Gradle project and HelloText.
- The build script.
- Install and uninstall over ADB.
- The metadata checks.
- Out of scope:
  - Launch (#017).
  - APKStoreCore and `apkrun install` (#027).
  - Split APKs (#042).
  - Rendering and input (#026).

### Deliverables

- `Tests/Fixtures/AndroidApps/` (`settings.gradle.kts`, AGP and Kotlin versions as in `Guest/`) with the module `HelloText`. Its spec:
  - package `io.apkrun.fixture.hellotext`, `versionCode` 1, `versionName` "1.0", `minSdk` 29, `targetSdk` 37;
  - one exported launcher Activity `MainActivity`, with a `TextView` that shows a counter and a `Button` that increments it;
  - the counter persists in `SharedPreferences`;
  - each click logs `APKRUN-FIXTURE: click <n>`;
  - an `EditText` and a context menu for G4 ([../roadmap.md](../roadmap.md) §2).
- `Tests/Fixtures/signing/test-fixture-a.jks`: committed and for tests only.
- `scripts/build-fixtures.sh`, which writes `Tests/Fixtures/AndroidApps/out/HelloText.apk` (git-ignored).

### Implementation steps

1. **Fixture project.**
   - Create the Gradle project and HelloText as specified.
   - Add a JVM unit test for the counter store.
   - Check: `./gradlew -p Tests/Fixtures/AndroidApps :HelloText:testReleaseUnitTest` passes.
2. **Build script.**
   - `scripts/build-fixtures.sh` runs `./gradlew -p Tests/Fixtures/AndroidApps :HelloText:assembleRelease`, signs with the test key, and copies the result to `out/HelloText.apk`.
   - Check: two clean builds have the same content, meaning the same `aapt2 dump badging` output and the same dex hashes ([../../05-development/build-system.md](../../05-development/build-system.md) §14).
3. **Install.**
   - `AdbClient.install(apk:)` runs `adb -s 127.0.0.1:6520 install -r <apk>`. On the device this is a PackageInstaller session. Nothing is ever copied into `/data/app` (FR-PKG-01).
   - The manual path is `apkrun-dev dev adb install -r Tests/Fixtures/AndroidApps/out/HelloText.apk`.
   - Check: the output is `Success`.
4. **Metadata.**
   - `AdbClient.listPackages` (`pm list packages --show-versioncode io.apkrun.fixture.hellotext`) returns `package:io.apkrun.fixture.hellotext versionCode:1`.
   - `AdbClient.dumpsysPackage` shows `versionCode=1`, `minSdk=29`, `targetSdk=37`, and `versionName=1.0`.
   - Check: the T2 assertions pass.
5. **Uninstall.**
   - `AdbClient.uninstall` (`adb uninstall io.apkrun.fixture.hellotext`) returns `Success`. The package is then no longer listed, and a second install succeeds.
   - Check: T2 passes.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0:** the Gradle JVM test of the counter store, and the `AdbClient` output parsers.
- **T1:** the fixture build content check (two builds).
- **T2** (`AndroidPackageTests.testInstallHelloText`, `testUninstallHelloText`).

### Acceptance criteria

- [ ] HelloText has a single Activity with a `TextView`, a `Button`, and a counter that persists across process restarts. The Activity, the `Button`, and the counter are built into the APK, and the persistence contract (a new store over the same preferences sees the count) is a JVM test. On the device the click cannot be driven yet: the headless profile draws no window, `uiautomator dump` shows SystemUI rather than HelloText, and `input keyevent 66` produced no click line while HelloText was the top resumed activity. The device check of the counter across a restart waits for rendering and input (#026). Leave open until then.
- [ ] HelloText is installed through ADB, and the install is a PackageInstaller session (FR-PKG-01). T2 `testInstallHelloText` checks the `Success` reply and the metadata. It does not assert the PackageInstaller session itself: the guest shows `initiatingPackageName=com.android.shell` and `packageSource=1`, and the design maps `adb install` to a PackageInstaller session. The mapping is recorded in [IR-332](../implementation-review.md#ir-332-take-the-packageinstaller-path-of-fr-pkg-01-from-adbs-install-command-and-the-devices-metadata), which is open for maintainer review, so this box waits for it.
- [x] PackageManager reports the correct package name, `versionCode`, and `versionName`. (T2 `testInstallHelloText`: `versionCode 1`, `versionName 1.0`, `minSdk 29`, `targetSdk 37` on a booted guest, 2026-10-09.)
- [x] HelloText is uninstalled through ADB, and PackageManager no longer lists it. (T2 `testUninstallHelloText`, which also checks that a second uninstall is refused and that a reinstall succeeds.)
- [x] The fixture build is reproducible, `out/` is git-ignored, and the signing key is test-only. `scripts/build-fixtures.sh --check-reproducible` matched badging, dex hashes, and archive listing on 2026-10-09; `Tests/Fixtures/AndroidApps/out/` is in `.gitignore`; the key is [IR-328](../implementation-review.md#ir-328-commit-one-test-only-fixture-keystore-with-its-password-in-the-gradle-file).

### Notes

- The M3–M4 `ADBStoreAgentChannel` uses `adb install-multiple` ([package-store.md](../../02-design/package-store.md) §6.1). That is #027 and does not change this task.

---
- Review (2026-10-09): the adversarial review found that a reason code could carry command output, that the T2 tests could leave a guest running after a failure, that a failed counter save was silent, that the build script copied an unverified APK, and that the `listPackages` doc disagreed with its guard. All five are fixed. The T2 suites use `AndroidBootSession.withBoot`, which stops the guest on every path, and both were run again after the fixes (`AndroidPackage` 2 of 2 and `AndroidADB` 2 of 2). The adapter `PreferencesKeyValueStore` has no automated test ([IR-333](../implementation-review.md#ir-333-leave-the-sharedpreferences-path-of-the-counter-without-a-jvm-test)).
- Verification (2026-10-09): the JVM test `:HelloText:testReleaseUnitTest` passed (5 tests, IR-329); `scripts/build-fixtures.sh` wrote the APK and checked its signer; `--check-reproducible` passed; T2 `AndroidPackageTests` passed 2 of 2 (`xcodebuild`, AndroidPackage configuration, under `lockf -k /tmp/apkrun-vm.lock`). Replies recorded from the guest are in the T0 parser tests.
- `adb install` leaves `installerPackageName=null` and `initiatingPackageName=com.android.shell` on the device ([IR-332](../implementation-review.md#ir-332-take-the-packageinstaller-path-of-fr-pkg-01-from-adbs-install-command-and-the-devices-metadata)).

## #017 Launch HelloText APK

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #016 |
| Requirements | FR-CLI-01 ([../traceability.md](../traceability.md) §2.10) |
| Design | [../../02-design/cli.md](../../02-design/cli.md) §5; [../roadmap.md](../roadmap.md) §3.1 ("CLI launch") |
| Modules / paths | RuntimeCore `Android/AdbClient.swift`; `Tests/IntegrationTests/AndroidPackageTests/` |
| Risks / questions | None |

### Goal

HelloText's `MainActivity` is started explicitly over ADB, and the process and ActivityManager state show it as running. It can then be stopped. No rendering is required.

### Scope

- Explicit launch.
- Inspecting the process and task state.
- Stopping.
- The end-to-end T2 path: install, launch, stop, uninstall.
- Out of scope:
  - `apkrun launch` through RuntimeCore (#027).
  - A window (#026).
  - Input.

### Deliverables

- The `AdbClient` helpers `startActivity`, `pidof`, `dumpsysActivities`, and `forceStop`.
- `AndroidPackageTests.testLaunchHelloText` and `testInstallLaunchStopUninstall`.

### Implementation steps

1. **Launch.**
   - `AdbClient.startActivity(component:)` runs `am start -W -n io.apkrun.fixture.hellotext/.MainActivity`.
   - Check: the output contains `Status: ok`.
2. **Process state.**
   - `AdbClient.pidof("io.apkrun.fixture.hellotext")` returns a PID, and `ps -A` lists the process.
   - Check: T2 passes.
3. **ActivityManager state.**
   - `AdbClient.dumpsysActivities()` parses `dumpsys activity activities`. The resumed activity (`topResumedActivity`, or `mResumedActivity` on older formats) is `io.apkrun.fixture.hellotext/.MainActivity`.
   - Check: T2 passes.
4. **Stop.**
   - `AdbClient.forceStop` runs `am force-stop io.apkrun.fixture.hellotext`. Afterwards `pidof` returns nothing, and the Activity is no longer resumed.
   - Check: T2 passes.
5. **End to end.**
   - `testInstallLaunchStopUninstall` runs install, launch, stop, and uninstall on one boot with `--gpu none`.
   - Check: T2 passes.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0:** the parser for `dumpsys activity activities`, over recorded outputs from the reference and VZ captures.
- **T2** (`AndroidPackageTests`): as above.

### Acceptance criteria

- [x] The Activity is launched explicitly by component name. (`am start -W -n io.apkrun.fixture.hellotext/.MainActivity`; T2 `testLaunchHelloText`, `testInstallLaunchStopUninstall`.)
- [x] The process and task state are inspected through ADB. (`pidof`, `ps -A`, and `dumpsys activity activities`; the same tests.)
- [x] No rendering is required: the tests pass with `--gpu none`. (The headless profile runs both tests; `am start -W` reported `Status: ok` and `LaunchState: COLD`.)
- [x] The process starts, and ActivityManager reports the Activity as active (resumed). (`dumpsysActivities().resumedComponent` equals the component after `am start`.)
- [x] `am force-stop` stops HelloText, and its process is gone. (After `forceStop`, `pidof` returns nil, and the resumed activity is the launcher.)
- [x] Install, launch, stop, and uninstall pass end to end in one T2 test. (`testInstallLaunchStopUninstall`.)

### Notes

- The headless profile of #014 must still give Android a default display. If `am start` fails with a display error, record it in #014's verification and in R-12 before changing this task.
- "CLI launch" in the v0.1 Definition of Done is complete only with #027.

---
- Verification (2026-10-09): T0 `AdbLaunchParserTests` (6 tests) and the `AdbClientTests` launch cases passed; T2 `AndroidPackageTests` passed 4 of 4 (`xcodebuild`, AndroidPackage configuration, under `lockf -k /tmp/apkrun-vm.lock`). The T2 run covers the whole package suite, which includes the install and uninstall checks of #016.
- Adversarial review (2026-10-09) found that `pidof` read a dropped endpoint as "no process", that `dumpsys` returned an empty answer for an unknown dump, and that the T0 tests had a tautology. All three are fixed; the recorded replies are committed under `Packages/RuntimeCore/Tests/RuntimeCoreTests/Fixtures/adb/`, and the `$` in a class name is refused ([IR-336](../implementation-review.md#ir-336-refuse-a-in-an-activity-class-name-instead-of-quoting-it)). After the fixes, the T2 package suite passed 4 of 4.
- The headless default display of #014 did not block `am start`. No display error was seen, so the note in the entry did not apply.
- Resumed-activity forms and the `pidof` reply are recorded as IR-334 and IR-335.
- `apkrun dev launch` (the CLI launch) belongs to #027, and no CLI command was added here.

## #065 Runtime image bundle

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #014 |
| Requirements | None named in requirements.md. Implements [../../01-architecture/decisions/0011-runtime-image-bundle.md](../../01-architecture/decisions/0011-runtime-image-bundle.md) |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §9.1, §10.1–§10.3, §14; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1; [../../03-reference/runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md); [../../05-development/build-system.md](../../05-development/build-system.md) §3.1, §10.1 |
| Modules / paths | `Images/tools/apkrun_image/{bundle,sign}.py`, the `keygen` subcommand, `Images/tools/schemas/runtime-image-manifest.schema.json`; ImageCore `Store/{ImageStore,ImageTrustStore}.swift`, `Bundle/RuntimeImageManifest.swift`; `CLI/apkrun/Dev/`; `Packages/ImageCore/Tests/ImageCoreTests/`; `scripts/release/check-release-build.sh` (the image rows) |
| Risks / questions | R-10 |

### Goal

One signed, deterministic bundle built from the stock build installs with `apkrun-dev dev image install` into `Images/<imageVersion>/` and boots to `boot_completed`. The unsigned development path is removed.

### Scope

- The complete manifest (§10.1), `SHA256SUMS`, and determinism.
- Ed25519 signing and `keygen`.
- `ImageTrustStore` and the verification order.
- The `ImageStore` directory install.
- `apkrun dev image install`.
- Out of scope:
  - `.aar` archives (#058) and the image feed (#087).
  - First-run provisioning UI (#066).
  - Release keys and publishing: stock bundles are never published (R-10).

### Deliverables

- The full `bundle` output (the image version gets the suffix `-cf16373615-arm64`), `sign.py`, `keygen`, and the runtime manifest schema.
- ImageCore: the full `RuntimeImageManifest`, `ImageTrustStore`, and `ImageStore` (`install(from: .directory)`, `verify(_:depth:)`, `current()`, `previous()`, `setCurrent`, `garbageCollect`).
- `apkrun dev image install <dir>`.
- Signing test vectors in `Images/tools/tests/fixtures/signing/`.

### Implementation steps

1. **Full manifest.**
   - Write every block of §10.1, `files`, and `SHA256SUMS`.
   - Output is deterministic: sorted keys, fixed GUIDs, no timestamps, and a sparse `os.img`.
   - Check: T1 builds the fixture bundle twice, and the two `SHA256SUMS` files are identical.
2. **Signing.**
   - `python3 -m apkrun_image keygen --out ~/.config/apkrun/dev-image-key` writes the private key and `dev-image-key.pub`.
   - `sign.py` writes `manifest.sig` (Ed25519 with a key-ID header).
   - Check: T0 vectors are shared by Python and Swift.
3. **`ImageTrustStore`.**
   - Release keys are compiled in. Debug builds also trust the developer key read from `~/.config/apkrun/dev-image-key.pub` ([../../05-development/build-system.md](../../05-development/build-system.md) §2.4).
   - Verification runs in this order: signature, schema, files. An extra file gives `unexpectedFile`.
   - Add the image trust and image manifest rows to `scripts/release/check-release-build.sh` ([../../05-development/build-system.md](../../05-development/build-system.md) §3.1): the Release `ImageTrustStore` holds only release key IDs, with no ID of `test-image-ed25519` and no per-developer key, and a release image manifest has no `androidboot.apkrun.test.*` key.
   - Check: T0 and T1 rejection tests pass. A fixture Release build that trusts the test key fails the release check, and so does a fixture manifest with an `androidboot.apkrun.test.*` key.
4. **`ImageStore`.**
   - `install(from: .directory)` verifies the bundle, clones it into `Images/.installing-<v>/`, renames it into place, and sets `current`.
   - Orphaned `.installing-*` directories are removed at startup.
   - Check: T1 on a temporary APFS volume covers an interrupted install, a bad signature, an extra file, and a hash mismatch. It also checks that holes are kept, by comparing allocated and logical sizes.
5. **Development install.**
   - `apkrun dev image install <dir>` installs the bundle and provisions the instance when there is none.
   - `apkrun dev boot` now boots `current`. Remove `bundle --unsigned`, `DevelopmentImage`, and `--bundle`.
   - Check: the command sequence of [build-system.md](../../05-development/build-system.md) §10.1 works exactly as written.
6. **Boot from the installed image.**
   - Switch the Android T2 suites to the installed signed bundle.
   - Record the result in [android-image.md](../../02-design/android-image.md) §10.
   - Check: `AndroidBootTests.testBootCompleted` passes on the installed image.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0:** Ed25519 vectors in both languages, `RuntimeImageManifest` decoding, and the verification-order errors.
- **T1:** the double build, and `ImageStore` install, rejection, and cleanup tests ([android-image.md](../../02-design/android-image.md) §15).
- **T2:** boot to `boot_completed` from the installed bundle.

### Acceptance criteria

- [x] The bundle contains every block of §10.1 and the files of [filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1. The real stock bundle validates, with no `legal` block (optional, and absent from stock bundles).
- [x] Two builds from the same inputs give identical `SHA256SUMS`. Verified on the real stock image (two builds, same `SHA256SUMS`, `manifest.json`, and `manifest.sig`) and in `test_two_builds_are_identical`.
- [x] The bundle is signed. A bad or untrusted signature, an extra file, and a hash mismatch are each rejected with the matching `ImageFailure` (`ImageStoreTests`, T1).
- [x] `apkrun dev image install` installs atomically, and an interrupted install is cleaned up (`anInterruptedInstallLeavesNothingBehind`, `anInstallLeftBehindByACrashIsRemovedAtStartup`).
- [x] The installed stock bundle boots to `boot_completed` (§10.3): `apkrun dev boot` from `current` reached `ready` in 13.7 s, and `G2AndroidBootTests` passed five cold boots from the installed bundle, each with `sys.boot_completed=1`. The dwell was 60 s, not the gate's 600 s (IR-350).
- [x] No private key is committed, and no stock bundle is published (R-10). The only private key in the repository is the test key `Tests/Fixtures/signing/test-image-ed25519`. Release builds refuse image test and developer keys (`check-release-build.sh` rows).
- [x] The unsigned development path is removed.

### Notes

- #066, #058, and #087 build on `ImageStore`. Keep `install(from:)` open for `.archive`, which #058 adds.
- Implemented: `RuntimeImageManifest` (typed, strict), `RuntimeImageManifestRules` (schema value rules and S1–S14), `ImageSignature`, `ImageTrustStore`, `ImageStore`, `keygen`, `sign.py`, `runtime_manifest.py`, `apkrun dev image install`, the release-check image rows, and the T0, T1, and T2 tests. The shared fixtures are in `Images/tools/tests/fixtures/runtime-manifests/` and `…/signing/`.
- Verified on 2026-10-09, macOS 27.0.1 (26A434), stock build 16373615: the installed image of `apkrun dev boot` booted to `ready`; `os.img` allocates 1.8 GB for 8.7 GB logical (after the sparse fix, IR-348); the two builds are identical. The Python suite (771 passed, 4 skipped), `scripts/tests/run.sh`, and the Swift ImageCore tests passed. The full 600-second G2 gate is for the maintainer to run from clean `main` (IR-350).
- The review of the store's install path is recorded in IR-359: downgrade checks against every installed image, symlinks refused before a read, read-only installed trees, and a private developer key file.
- Not done, with the reason:
  - Compatibility checks (`incompatibleRuntime`, `incompatibleProtocol`) are not checked at install or boot (IR-352). Follow-up: #066 and #058.
  - Release image keys do not exist, so Release builds refuse every bundle (IR-341). Follow-up: #093.
  - `ReleaseUpdateTest` builds do not trust the developer key (IR-342). Follow-up: the maintenance tests that need a lab-signed image.
  - Archive install (`.aar`) is #058. Rollback to an older image has no command yet (IR-347).
