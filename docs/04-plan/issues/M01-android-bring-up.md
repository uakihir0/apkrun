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
2. In parallel: #009 AndroidImageManifest and #064 Reference boot capture. Both need only #008. #064 runs on a Linux reference host.
3. #010 Extract Android kernel and ramdisk.
4. #011 GPT disks and partition mapping. It needs #005 from M0 and reads the #064 captures for blank partition sizes and the by-name list.
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
fetch provenance from the downloaded archive's adjacent `fetch.json`.
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

---

## #064 Reference boot capture

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #008 |
| Requirements | None named in requirements.md. Provides the ground truth for FR-VM-08 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §7.7, §8; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §3.3; [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Modules / paths | `Images/tools/reference/{capture.sh,capture_cvd_start.py,boot_observer.py,compare_boot.py,normalize.yaml,guest-capture.txt}`, `Images/reference/16373615/{default,target,swiftshader}/`, `Images/reference/16373615/expected-differences.yaml`, `Images/tools/tests/{test_boot_observer.py,test_capture_cvd_start.py,test_compare_boot.py,test_reference_capture.py}` |
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
- `Images/reference/16373615/<profile>/` for the three profiles, each with a `host.json` that records the host kind, OS, kernel, CVD package version and instance number, CPU count, and nested virtualization on or off.
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
   - Use the pinned host package's `cvd create --nostart` with the host and product paths, private base directory, unique group name, instance number, and profile flags of §8.2. Run both creation and named-group start through `capture_cvd_start.py` under the shared boot deadline; poll and atomically snapshot the three host logs, capped at 64 MiB each. Connect ADB on the instance's loopback port and wait for `sys.boot_completed=1`.
   - For long-start diagnosis only, `APKRUN_CAPTURE_BOOT_OBSERVER=1` records launcher-identified Android crosvm memory and private-socket ADB state during `cvd start`; leave it disabled for ordinary captures.
   - Collect the host side: the crosvm command line, `internal/bootconfig` with the AVB footer stripped, the composite disk specs, `cuttlefish_config.json`, `assemble_cvd.log`, `kernel.log`, and `launcher.log`.
  - Run `guest-capture.txt` through `adb exec-out`, disconnect the selected ADB serial with a bounded timeout, then remove only this group with a bounded timeout.
   - Run `compare_boot.py normalize <dir>`, which applies `normalize.yaml` to serial numbers, MAC addresses, host paths, and key-shaped secrets. Publish only a fully normalized capture under `Images/reference/16373615/<profile>/`; retain incomplete normalized captures under `Images/reference/16373615/incomplete/`.
   - Check: every §8.3 item is present in the directory, or a `MISSING.txt` there gives the reason. A search for the device serial, MAC addresses, and `/home/` finds nothing.
4. **Capture the three profiles.**
   - Capture `default`, `target`, and `swiftshader`.
   - If `drm_virgl` does not run on the reference host, explicitly set `APKRUN_TARGET_GPU_MODE=guest_swiftshader`, provide the matching `bootconfig_args.cpp` revision and source-derived properties file, and write them into `target/graphics-props-from-source.txt` (§8.2).
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
  - The capture script's loopback ADB connection, selection and cleanup, host-wide capture lock, private Cuttlefish HOME cleanup, instance-scoped host collection, all three profile flags, AVB footer stripping, and missing-item reporting are exercised without Cuttlefish.
  - Every profile starts the uniquely named group with the matching host package, a writable private copy of verified product output, and a private Cuttlefish base directory.
  - Product output with an absolute symbolic link is rejected, and any change to a manifest-pinned image during the copy is detected by the post-copy size and SHA-256 check before `cvd create`.
  - Fetched archive branch, build ID, and target metadata remain authoritative if both the manifest and recorded inventory are edited together. Missing `fetch.json` provenance fails closed, and manifest or inventory-derived diagnostics escape controls and bidi formatting characters.
  - Normal and interrupted capture disconnect the selected ADB serial with a bounded timeout before removing the group; cleanup continues if ADB hangs.
  - Startup snapshots `assemble_cvd.log`, `kernel.log`, and `launcher.log` while both CVD create and start are running; an integration fixture delays the first listing, then deletes create-time logs before the next poll under the old post-return schedule. A helper test deletes a listed log while `cvd logs` is still running and verifies the streamed path was snapshotted before the listing exits; duplicate listing rows trigger only one copy. Another test times out the listing after source deletion and checks that the valid snapshot remains. CVD child exit statuses 124 and 137 are distinguished from actual deadline expiry. Timed-out start deletion is covered too. FIFO sources do not block, paths with spaces parse, malformed log listings cannot skip process termination, incomplete snapshots do not replace complete copies, rejected final copies keep the last snapshot, and capture/comparison paths enforce 64 MiB log limits.
  - The optional boot observer resolves the private HOME's `cuttlefish_runtime` link during `cvd start`, validates the current UID, Cuttlefish-managed path, canonical private-HOME destination, and ADB instance number, then selects the staged crosvm executable through the launcher-identified Android restarter and its direct child. It rejects redirected `home` or `instances` links, checks the child's PPID and both procfs start times, and verifies `/proc/<pid>/exe` with `samefile` against the staged symlink. Tests reject a reused child PID and a different executable with the same basename. It fails closed if the runtime link changes, clears identities after a capped launcher log, and records no raw ADB output. Its background sampler and monotonic private-socket ADB schedule avoid drift from log collection and command duration, honor the cleanup reserve, and remove an ADB server that ignores SIGTERM.
  - The shutdown helper kills remaining process-group members after its TERM grace even when the command leader exits; a fixture verifies that a grandchild ignoring TERM is also terminated.
  - An interrupted capture is normalized into `incomplete/` or discarded if normalization fails; raw logcat that cannot be removed prevents publication and triggers stage deletion, and a failed launch still attempts bounded group-scoped cleanup.
  - Diagnostic Cuttlefish command-line capture trims right-aligned PIDs, verifies `/proc/<pid>/exe` resolves to `crosvm`, and matches the selected instance path using delimiters in `ps`-rendered text. This is a best-effort text heuristic, not proof of NUL-delimited argument boundaries; scanner text and similarly named helpers are excluded, and a missing process is recorded in `MISSING.txt`.
  - A Linux-only integration case runs the real GNU `timeout` against group removal that ignores TERM; it is skipped on macOS.
  - Compound quoted secrets and complete PEM private-key blocks are redacted; private-key marker scanning is linear; substitution growth is checked before allocation; plain/compressed input, rules files, normalized output, and capture-tree traversal are bounded; comparison indexes category files once, streams newline-dense category files, and caps each capture at 100,000 records or 64 MiB of key/value text across all categories; report symlinks cannot overwrite their targets.
  - Every guest command and `capture.sh` pass `sh -n`; the Linux-only guard is checked on macOS.
- **T3** (manual, on the reference host): the capture itself, with `host.json` attached to the pull request. It is repeated whenever the pinned build changes.

### Acceptance criteria

- [ ] The `default`, `target`, and `swiftshader` profiles are captured and committed with every item of §8.3, or with a recorded reason for each missing item.
- [ ] The captures are normalized and contain no serial numbers, MAC addresses, host paths, or keys.
- [x] `compare_boot.py` reports by the ten categories, fails on unexplained differences, and passes its T0 tests.
- [ ] `guest-capture.txt` runs unchanged over `adb shell` and over a plain `sh` console.
- [ ] The exact `VIRTUAL_DEVICE_*` strings and their timing are in [android-image.md](../../02-design/android-image.md) §7.7. The boot signals in [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3 are confirmed or corrected.
- [ ] Each profile has a `host.json`.

### Notes

- A TCG capture takes hours. Record its duration in `host.json` so that timing comparisons skip it.
- #012 copies each profile's normalized `kernel.log` into the BootSignals golden fixtures.
- **Reference-host verification (2026-09-30).** The nested-virtualization Ubuntu 24.04 arm64 VM has Cuttlefish 1.57.0 (VCS `9bb9c723`) and `adb`. The Lima project mount is read-only, so the capture script and manifest were copied to the VM's writable home; product images passed the pinned manifest's size and SHA-256 checks. Cuttlefish logged `Logical partition metadata has invalid geometry magic signature` twice, but continued through `simg2img` and Android service startup. Inspection of the converted `super.img` found the expected little-endian geometry magic at offset 4096. The guest became visible to ADB but stayed in Cuttlefish `Starting`; after 1,029 seconds, `cvd start` reported `VIRTUAL_DEVICE_BOOT_FAILED`, `run_cvd returned 10`, and exit status 255. No `sys.boot_completed=1` was observed. The evidence does not establish whether the geometry warning contributed to the later boot failure.
- **Incomplete capture.** The normalized record is committed under `Images/reference/16373615/incomplete/default-20260930T184542Z-7609/`. Cuttlefish removed its instance runtime after the failed start, before the capture script could copy `kernel.log`, `launcher.log`, or guest data. `MISSING.txt` records those unavailable items. Do not treat this as a reference profile. The record directory uses the equivalent UTC instant of the VM's Asia/Tokyo timestamp.
- **Bounded capture retry.** A later 30-second run is recorded under `Images/reference/16373615/incomplete/default-20260930T190436Z-10435/`. It ended after 32 seconds with a `MISSING.txt` entry naming the Cuttlefish startup deadline. `cvd fleet` showed no remaining groups and the capture lock had been removed. The Cuttlefish console also printed `timeout: the monitored command dumped core` while the command was being stopped; this did not prevent cleanup. The record is diagnostic only and is not a reference profile.
- **Diagnostic hardening verification (2026-10-01).** The isolated GPU-none runner now pins its baseline commit, derives experiment source provenance from committed Git objects, validates the exact private runtime copies, snapshots the capture script into a sealed memory file, and bounds both bootstrap and guest execution. It retains incomplete state when cleanup cannot be verified and leaves shared Cuttlefish state untouched. The diagnosis suite passed on macOS (107 passed, 39 skipped) and the Linux reference VM (146 passed); final hostile review reported no remaining findings. These host-side checks do not change the earlier `VIRTUAL_DEVICE_BOOT_FAILED` result or complete the reference capture acceptance criteria.
- **600-second live diagnosis.** The run recorded under `Images/reference/16373615/incomplete/default-20260930T201303Z-17984/` lasted 602 seconds and ended when the configured startup deadline sent a termination signal; it did not report the same natural `VIRTUAL_DEVICE_BOOT_FAILED` result as the earlier 1,029-second run. While the group was alive, live `cvd logs` showed Android init progressing through service-manager and HAL startup. `/metadata` initially had an invalid ext4 superblock and an early `aconfigd` write failed, but libfs_mgr later mounted `/metadata` and `system_aconfigd_platform_init` exited successfully. This does not establish that the transient errors caused the boot failure. The Cuttlefish ADB connector intermittently reported a connection to `127.0.0.1:6520`, followed by `device ... not found`; no usable ADB device or `sys.boot_completed=1` was observed. Host graphics checks also reported no GLES or accelerated ARM64 mode, but the selected guest graphics path and any effect on boot remain unknown. Cuttlefish removed its live instance logs during timeout cleanup, so the normalized record correctly lists them as missing. Do not treat these observations as a successful boot or a proven root cause.
- **120-second log-retention retry (2026-10-01).** The normalized incomplete capture at `Images/reference/16373615/incomplete/default-20261001T001530Z-48053/` was captured on Ubuntu 24.04.4 arm64 with Cuttlefish 1.57.0 and nested virtualization enabled. The product images again passed the pinned manifest checks. The shared deadline terminated startup after 120 seconds; cleanup removed the CVD group, left no ADB devices, and released the capture lock. Live snapshots retained `kernel.log` and `launcher.log`: the kernel log reached `Starting kernel ...`, while the launcher log showed unstable ADB and vsock connections. No `sys.boot_completed=1` was observed. `assemble_cvd.log` was not available in the selected instance runtime at final collection, and no crosvm process remained to capture. This is diagnostic evidence only, not a successful boot or a root-cause finding.
- **Composite disk-spec capture gap (2026-10-01).** The pinned Cuttlefish 1.57.0 `cuttlefish_config.json` in the same record has a top-level `instances` object and no `disks` object. The collector therefore records `composite-disk-specs.json` as missing instead of inferring composite topology from individual image paths. See IR-084.
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
- **U-Boot cache-maintenance match (2026-10-02).** The traced PC `0x000000017f63e1f4` matches a `dc civac, x0` instruction independently reproduced from the hash-verified `bootloader.crosvm` at file offset `0x21f4`; subtracting the offset yields aligned candidate base `0x000000017f63c000`. The nonce-framed live probe read `d50b7e20` at that address and `d53b0023` at the preceding loop instruction address while U-Boot was paused, corroborating the code window at the candidate runtime addresses. The pinned U-Boot source contains the matching virtual-address cache-maintenance loop and a conditional page-table walker that applies range operations to RAM mappings. This does not establish the earlier trace's execution context, the U-Boot build configuration, the runtime call path, or the cause of the delay. Slow cache maintenance remains consistent with the evidence, not an established root cause. See IR-133 and IR-137.
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

  `MISSING.txt` records the 3000-second guest deadline and notes that no crosvm process remained at artifact-collection time; that does not establish whether it ran earlier. It also records that `cuttlefish_config.json` had no composite-disk specifications, so that diagnostic file was unavailable; this is not the boot failure. The retained normalized logs establish slow progress through Linux and Android startup but not a successful boot or a root cause.
- **Completed 2400-second unpaused boot-observer retry (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T024733-676851/`).** The `default` profile used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no bootloader pause. The outer capture and `cvd start --boot_timeout_secs` used 2400 seconds; `host.json` records a 2404-second duration. “Unpaused” means the guest followed its normal U-Boot path without console commands or vCPU tracing; the opt-in observer still sampled crosvm memory and polled ADB during `cvd start`. The incomplete directory's timestamp is Lima local time (Asia/Tokyo); event times below are UTC. The U-Boot banner was logged at 17:07:35Z and Linux 6.12.74 at 17:11:01Z, an interval of 206 seconds. Android first-stage init appeared at guest uptime 21.65 seconds and zygote at 189.74 seconds. This is a fourth observed U-Boot-to-Linux interval alongside 190, 537, and 753 seconds; the four values do not support a deterministic scan-rate estimate.

  The observer recorded 479 valid five-second crosvm memory samples. The first at 17:07:39.975Z was 181,680 KiB VmRSS / 159,848 KiB RssShmem. The sample at 17:10:59.974Z was 4,193,260 / 4,171,596 KiB; the next at 17:11:04.974Z was 4,216,196 / 4,194,532 KiB. The latter first crossed 4 GiB for both measures, within the five-second sampling window that contains the launcher-recorded Linux banner. The last sample at 17:47:29.975Z was 4,233,556 / 4,205,908 KiB. Since the config and bootconfig specify 4915 MiB of DDR, 4 GiB RSS is a residency milestone, not proof that all guest RAM was resident or that U-Boot performed a full-RAM cache flush. This timing supports that hypothesis but does not establish the executing code, a stage-2 fault cause, or the reason for the later Android delay.

  Launcher event 5 occurred at 17:18:16.393Z and the private ADB server was ready at 17:18:20.026Z. Of 116 ADB polls, three initial polls had no device state and did not start a property query. One of those polls timed out; the other two had a successful `connect` exit status but still no device state. The other 113 polls reported `device`. All 113 attempted `getprop`: 112 timed out under this run's two-second command cap, while one returned exit status 0 without an accepted `sys.boot_completed` value. No poll reached the shared deadline, and `sysBootCompleted` remained null throughout. A separate bounded, read-only `getprop` query through the same private socket took about seven seconds and returned no property text under its 12-second limit. This run therefore verifies ADB transport discovery, not property availability or Android boot completion. It predates the ten-second `getprop` cap from IR-136.

  The kernel log records servicemanager calls attributed to the `system_server` SELinux domain around guest uptime 1795.5–1795.98 seconds. At 2038.179 seconds, init records an untracked zombie process named `system_server` (PID 2258) exiting with status 0, then notes that it has no associated service entry. These lines do not establish the relationship between that process and the earlier caller, why it exited, or whether it caused the incomplete boot. The log continues through guest uptime 2184 seconds with repeated audioserver `aidl/activity` lookup messages; those messages alone do not prove a fatal failure. Neither the kernel nor launcher log contains `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or `sys.boot_completed=1`.

  `MISSING.txt` records that the 2400-second deadline expired and that no crosvm process existed at artifact-collection time; it does not establish whether crosvm ran earlier. It also records the absence of composite-disk specifications in `cuttlefish_config.json`. Cleanup left the Cuttlefish fleet empty and no crosvm or private ADB server running. All nine normalized files were hash-checked against the Lima capture, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This is diagnostic evidence only, not a successful reference profile or a proven root cause.
- **Recovered 600-second inner-timeout capture (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261002T224455-600285/`).** This earlier `default` run had four guest CPUs, 4096 MiB, `guest_swiftshader`, console off, and no bootloader pause. Its outer deadline was 2400 seconds, but `cvd start` used Cuttlefish's 600-second default; `host.json` records a 634-second capture duration. `launcher.log` records the U-Boot banner at 22:34:27 Lima local time (13:34:27Z) and Linux 6.12.74 at 22:43:24 local (13:43:24Z), 537 seconds later. `kernel.log` records Android first-stage init at guest uptime 28.82 seconds, but no zygote start or later system-server evidence. `launcher.log` records `TimeoutThreadLoop: waiting for 10m`. `cvd-create-console.log` records `VIRTUAL_DEVICE_BOOT_FAILED` and `run_cvd returned 10`; the run did not reach launcher event 5, so ADB readiness was not measured. The observer wrote 127 memory events, but every candidate had `identity=unavailable` and `candidateCount=0`; this was the process-identification gap later fixed by IR-131. Cuttlefish cleanup completed. `MISSING.txt` says no crosvm process existed at artifact-collection time, which does not establish whether it ran earlier. The nine copied files match their Lima-side SHA-256 values, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This is diagnostic evidence, not a successful reference profile or a root-cause finding.
- **Completed 1200-second live verification of the ten-second `getprop` cap (2026-10-02 UTC; normalized result: `Images/reference/16373615/incomplete/default-20261003T031842-703886/`).** This `default` run used four guest CPUs, `memory_mb=4096`, `ddr_mem_mb=4915`, `guest_swiftshader`, console off, and no bootloader pause. It followed normal U-Boot progression without console commands or vCPU tracing; the opt-in observer sampled crosvm memory and polled ADB during `cvd start`. `host.json` records 1203 seconds. The directory timestamp and launcher log use Lima's Asia/Tokyo time; observer timestamps below are UTC. `cvd-create-console.log` contains two `Logical partition metadata has invalid geometry magic signature` errors at 02:58:40 Lima local time; this warning also appears in an earlier capture and is not established as the cause of the slow boot. The U-Boot banner was logged at 17:58:44Z and Linux 6.12.74 at 18:03:10Z, 266 seconds later. First-stage init appeared at guest uptime 22.34 seconds and zygote at 185.92 seconds; the last kernel lines reach guest uptime 924.25 seconds. No `VIRTUAL_DEVICE_BOOT_COMPLETED` event or positive `sys.boot_completed=1` value was recorded. At guest uptime 458.78 seconds, the kernel log records init setting `sys.bootstat.first_boot_completed` to `0`; that value does not indicate successful boot completion.

  The observer captured 239 valid five-second memory samples. VmRSS/RssShmem was 4,167,692/4,146,036 KiB at 18:03:05.265Z and 4,216,188/4,194,532 KiB at 18:03:10.265Z, the first sample at or above 4 GiB for both measures. The launcher timestamp for Linux is 18:03:10 with one-second resolution, inside that sample interval. The last sample at 18:18:35.265Z was 4,225,484/4,198,328 KiB. Because the guest config and bootconfig specify 4915 MiB of DDR, the 4 GiB crossing is a residency milestone, not proof that all RAM was resident or that cache maintenance caused the delay.

  Launcher event 5 occurred at 18:10:19.203Z and the private ADB server was ready at 18:10:20.316Z. Before launch, the Lima copy of `boot_observer.py` was SHA-256 checked against the local source (`d19b56edf45b7011a53b42ca4ab2d1c6c60d89b52163a9780ac49688d2702494`); that source sets the `getprop` cap to ten seconds. Of 33 polls, three initially had no device state and did not attempt `getprop`: one connection command timed out, while two completed `connect` with exit status 0. The remaining 30 polls reported `device` and attempted `getprop` with the ten-second cap. Twenty-nine timed out; one exited 0 without an accepted property value. One final poll reached the shared deadline, and `sysBootCompleted` remained null for all polls. A separate read-only `getprop sys.boot_completed` query and `logcat -d -t 1` query, each bounded to 12 seconds through the same private socket, both exited 124; their output was discarded.

  `MISSING.txt` records the 1200-second deadline and says no crosvm process existed at artifact-collection time, which does not establish whether it ran earlier. The config also has no composite-disk specifications. Cleanup left the Cuttlefish fleet empty and no crosvm or private ADB server running; the observer records private-server cleanup complete. All nine files match their Lima-side SHA-256 values, and scans found no private host paths, MAC/EUI-64 patterns, or PEM key markers. This confirms ADB transport state and execution of the longer property-query path, but not a property value, system-server readiness, or a successful reference boot.
- **Follow-up.** Establish a repeatable reference-host boot with `adb shell getprop sys.boot_completed` returning `1`; then capture all three profiles and verify T3, marker timings, guest command execution, and the design findings in step 6.

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

- **T0 Python:** every valid fixture passes. Every invalid fixture fails with exactly its expected message. A source vbmeta omitted from both `artifacts` and `roles.vbmeta` is rejected; generation follows the top-level descriptor order. The model round-trips: load, dump with sorted keys, load again, and the result is equal. File checks reject swapped boot roles, stale inventory archive fingerprints, directory inventory provenance substituted for the declared archive, manifest plus inventory provenance that disagrees with the fetched `fetch.json`, and jointly edited provenance when actual `fetch.json` metadata is missing. Schema, semantic, and file-backed diagnostics escape manifest-controlled newlines. Inventory rejects fetch-sidecar archive names containing control, format, surrogate, line-separator, or paragraph-separator characters; inventory-derived diagnostic values escape controls and are bounded. The no-file-names test.
- **T0 Swift** (`Packages/ImageCore/Tests/ImageCoreTests/AndroidImageManifestTests.swift`): decoding and encoding round trip. Every valid fixture and every committed manifest is accepted. The manifest-only invalid fixtures fail with the same message as in Python. JSON primitive type mismatches throw `ImageFailure.manifestInvalid`; input-derived paths and values are escaped and bounded, including control, quoting, and bidirectional-formatting characters. Trailing line feeds are rejected for every anchored string-pattern field.
- **T1:** `manifest --check Images/manifests/16373615/android-image.json` passes with the real archive. It is skipped when the archive is absent.

### Acceptance criteria

- [x] The schema describes the build ID, Android version, architecture, boot image, vendor boot, super/system, vendor, product, userdata, vbmeta, and metadata:
  - system, vendor, and product are `logicalPartitions` of `super`;
  - metadata is a `blankPartitions` entry.
- [x] JSON encode and decode work in Python and in Swift.
- [x] The committed manifest describes the #008 set. Every artifact matches its inventory entry in size, hash, and kind (M10).
- [x] Invalid manifests fail with actionable errors. Each message names the file or field, what was expected, what was found, and the fix. Each invalid fixture has its expected message.
- [x] Source origin and build ID agree, logical partition names are unique, archive provenance cannot be replaced by directory metadata or supplied without fetched metadata, and malformed or adversarial JSON values become safe typed manifest errors.
- [x] No Python or Swift code opens an image file by a literal name.

### Notes

- The `blankPartitions` sizes are placeholders until #011 replaces them with the sizes from the #064 `target` capture.
- The design sketch in [android-image.md](../../02-design/android-image.md) §3.2 is abbreviated. Reference §5 is the complete example.
- **Verification (2026-09-30):** Python tests cover M1–M15, including fetched-source provenance, diagnostic escaping, strict end-of-input matching for every schema pattern, source vbmeta completeness, descriptor-order generation and validation, deterministic generation, and file checks against the pinned archive. The full image-tools suite passed 299 tests; Swift ImageCore manifest tests passed 23 tests; `manifest --check` passed against the real pinned archive. A broader Swift package run also failed the unrelated `DiagnosticsCoreTests.logReaderFallsBackToPublicRotatingMirrorsOnTimeout` test, including when run alone. The manifest has 10 artifacts and all 9 non-empty liblp partitions.
- **Maintainer review pending:** the manifest is generated from the pinned inventory and its file checks pass, but a human maintainer still needs to review its source-derived values before treating the draft as approved; see IR-062.

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
- [ ] The layout file is committed. Every "(reference)" value traces to the #064 `target` capture.

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

---

## #011 GPT disks and partition mapping

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #005, #009, #010, #064 |
| Requirements | FR-IMG-04, FR-VM-03 ([../traceability.md](../traceability.md) §2.1), NFR-RES-02 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §4.2–§4.5, §5; [../../02-design/vm.md](../../02-design/vm.md) §4, §12; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1 |
| Modules / paths | `Images/tools/apkrun_image/{sparse,gpt,layout}.py`, the `disks` and `inspect` subcommands, the layout `disks` section, `Packages/ImageCore/Sources/ImageCore/Disks/{GPTDisk,InstanceDiskProvisioner}.swift`, `Tests/Fixtures/linux/init`, `Tests/IntegrationTests/LinuxGuestTests/`, `Images/reference/vz/<macOS build>/topology.txt` |
| Risks / questions | R-06, R-16 |

### Goal

Three raw GPT disks are built from the manifest and the layout. They attach to a VZ guest in a fixed order, and the guest sees the expected partition names and sizes. The VZ block topology that `androidboot.boot_devices` needs is recorded.

### Scope

- Sparse to raw conversion, the GPT writer, the disk plan in the layout, the `disks` command, and `disks.json`.
- Confirming the blank sizes, omissions, and fstab flags from the #064 captures.
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
- `Images/work/16373615/disks/{os.img,persistent.img,userdata.img,disks.json}` produced locally.
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
     - disk 1 `persistent`, read-write, with misc, metadata, and frp;
     - disk 2 `userdata`, read-write.
   - Replace the `blankPartitions` placeholders in `android-image.json` with the sizes from the #064 `target` sysfs capture.
   - `python3 -m apkrun_image disks --manifest Images/manifests/16373615/android-image.json --layout Images/tools/layouts/cuttlefish-phone-arm64.json --out Images/work/16373615/disks/` writes `os.img`, `persistent.img`, the blank formattable `userdata.img`, and `disks.json`.
   - `disks.json` has, per disk: the file, role, access, identifier, and sector size. Per partition it has the name, GUID, first and last LBA, size, and source SHA-256.
   - Check: `du -h` shows that `os.img` is allocated well below its logical size. The layout-check messages of reference §8 appear for a broken layout.
4. **Linux guest check.**
   - Add `apkrun.test=parts` to `Tests/Fixtures/linux/init`. It prints, per `/sys/class/block/vd*`, the `PARTNAME` from `uevent`, the size in sectors, and `blockdev --getss`. It also prints `readlink -f /sys/block/vda` (and `vdb`, `vdc`).
   - `LinuxGuestTests.testAndroidDiskLayout` attaches the three disks with the access and synchronization modes of [android-image.md](../../02-design/android-image.md) §9.2, then compares the output with `disks.json`.
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
   - Fill [android-image.md](../../02-design/android-image.md) §4.2 with the verified table: virtual device index, backing image, read-only or read-write, the guest name (`vda`–`vdc`), the partition labels, and the sizes.
   - Confirm the omitted partitions against `Images/reference/16373615/target/` (`by-name`, fstab): `uboot_env`, the persistent vbmeta, `bootconfig`, and the `_b` slots.
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

- [ ] The minimum disk mapping needed to boot is defined: the three disks of [android-image.md](../../02-design/android-image.md) §4.2.
- [ ] Each virtual device is documented with its backing image, read-only or read-write access, and the name the guest expects (the verified table in §4.2).
- [ ] The mapping is data-driven. It lives in the layout and the manifest, and no partition or file name appears in Python or Swift code.
- [ ] The Linux test guest sees three virtio block devices with the partition names and sizes of `disks.json`.
- [ ] The Android kernel detects the expected virtio block devices. The design moves this check to #012.
- [ ] `os.img` is read-only and `persistent.img` and `userdata.img` are read-write. Instance disks are APFS clones, and `userdata.img` grows sparse (NFR-RES-02).
- [ ] The `boot_devices` value is recorded in `topology.txt` and in [android-image.md](../../02-design/android-image.md) §5.3.

### Notes

- `clonefile` needs the source and the destination on the same volume. Tests and `apkrun-dev` must keep `APKRUN_HOME` on the volume of the bundle, or they get `cloneFailed(EXDEV)`.
- #064 is not listed as a dependency in [README.md](README.md) §3, but steps 3 and 6 read its captures. Plan #064 to finish before this task.

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

`apkrun-dev dev boot` starts a VM from four inputs: the Android kernel, the per-boot initrd with the merged bootconfig, the kernel command line, and the three disks. The captured serial log shows the kernel getting past early init and detecting the configured virtio devices.

### Scope

- An Android-specific `VMDefinition` built by ImageCore's `AndroidBootPlanner`.
- An unsigned development bundle and its Debug-only loader, until #065.
- Bootconfig layers 3 and 4, and the per-boot initrd.
- A first cut of `InstanceStore`.
- A first cut of `RuntimeSupervisor`: the `.kernel` phase and the immediate kernel-panic failure.
- Complete serial capture through the `ConsoleLogWriter` of #004.
- A provisional console port plan that attaches the §7.1 table as given, in array order.
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
  - Golden fixtures in `Packages/RuntimeCore/Tests/RuntimeCoreTests/Fixtures/console/cuttlefish-<profile>.log`, copied from #064.
- RuntimeHost: the embedded composition that `apkrun-dev` uses.
- CLI: `apkrun dev boot --bundle <dir> [--gpu none]`.
- The `apkrun.test=bootconfig` check in `Tests/Fixtures/linux/init`.

### Implementation steps

1. **Unsigned bundle.**
   - Run `python3 -m apkrun_image bundle --unsigned --manifest Images/manifests/16373615/android-image.json --layout Images/tools/layouts/cuttlefish-phone-arm64.json --reference Images/reference/16373615/target --image-version 2026.10.0 --out Images/work/16373615/bundle/`.
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
   - Check: T0 golden tests pass over the #064 kernel logs. `apkrun-dev dev boot --bundle Images/work/16373615/bundle/ --gpu none` prints `.kernel`.
5. **Bootconfig on the Linux guest.**
   - Add `apkrun.test=bootconfig`, which prints `/proc/bootconfig`.
   - `LinuxGuestTests.testBootconfigTrailer` boots the test kernel with an initrd that `BootconfigWriter` built from a golden input, then compares the output with the golden text.
   - If the pinned test kernel lacks `CONFIG_BOOT_CONFIG`, the test skips with that message, and #013 verifies `/proc/bootconfig` on Android.
   - Check: the T2 test passes or skips with the reason.
6. **Android kernel boot.**
   - `AndroidBootTests.testKernelBoot` boots the unsigned bundle with `--gpu none`. It waits up to 120 s for `init: init first stage started!`, then force-stops the VM.
   - It asserts these lines in `boot-<timestamp>.log`:
     - `Booting Linux on physical CPU`;
     - `Kernel command line:` with a value equal to `cmdline.txt`;
     - `virtio_blk` lines for `vda`, `vdb`, and `vdc` with 9, 3, and 1 partitions;
     - `rtc-pl031` registered as `rtc0`;
     - the virtio console, virtio-net, vsock, rng, and balloon devices probed;
     - no panic.
   - A second test boots a deliberately truncated ramdisk and expects `failed(.kernelPanic)`.
   - Record in [android-image.md](../../02-design/android-image.md) §6: the kernel version, the time to each line, and any missing device.
   - Check: both T2 tests pass.

### Tests

See [../test-strategy.md](../test-strategy.md).

- **T0 Swift:**
  - ImageCore: `ImageVersion` ordering, `RuntimeImageManifest` decoding, the `BootconfigWriter` golden vectors and conflicts, the `VMDefinition` mapping (§9.2), and the `serialno` format.
  - RuntimeCore: `BootSignals` golden tests.
- **T0 Python:** `bundle --unsigned` on the fixture set gives the expected file list.
- **T1:** `InstanceStore.provision` and the per-boot initrd on a temporary APFS volume. The initrd SHA-256 is stable for the same inputs.
- **T2:** `LinuxGuestTests.testBootconfigTrailer`, `AndroidBootTests.testKernelBoot`, and `AndroidBootTests.testKernelPanicDetected`.

### Acceptance criteria

- [ ] An Android-specific `VMDefinition` is created by `AndroidBootPlanner` and accepted by `VMDefinitionValidator`.
- [ ] The kernel command line is passed: the `Kernel command line:` log line equals `cmdline.txt`.
- [ ] The bootconfig is passed as the initrd trailer, and `/proc/bootconfig` equals the merged block. The check runs on the Linux guest, or on Android in #013.
- [ ] The complete serial output is captured in `~/Library/Logs/APKRun-Dev/vm/console.log` and in `boot-<timestamp>.log`.
- [ ] The kernel boots past early init and detects the configured virtio devices, including three virtio block devices with the expected partition counts (the #011 Android check).
- [ ] Successful init is not required.
- [ ] A kernel panic ends the boot at once with `.kernelPanic`.
- [ ] Every boot logs the image version, the bootconfig hash, and the disk identifiers (subsystem `io.apkrun.image`, category `boot`, §14.2).
- [ ] A bootconfig over 16 KiB fails the build. Conflicting keys fail with `bootconfigConflict`.

### Notes

- The development-only parts are `bundle --unsigned`, `DevelopmentImage`, and `--bundle`. #065 removes them.
- The `headless` GPU profile starts empty here. #014 fills it and verifies it.
- If `virtio_console` or `virtio_blk` are vendor modules rather than built in, hvc0 output starts only after first-stage init loads them. The kernel replays its buffer, but a panic before that point shows nothing. In that case, record the module list and compare it with the reference `lsmod`.
- The `virtio_blk` lines may appear after first-stage init has started. Wait for them with the same 120 s budget.

---

## #013 Reach Android init

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #012, #064 |
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
   - `init: init first stage started!` enters `.init` and emits `ANDROID_INIT`.
   - If init's kmsg lines do not reach hvc0 at the default log level, add a command-line addition (for example a log-level setting). Record it in the layout with a comment and as a §13 row.
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
   - Compare with `Images/reference/16373615/target/`.
   - Check: no `libfs_avb` error lines. The bootconfig matches, or each difference has an `expected-differences.yaml` entry.
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

- **T0 Swift:** the `.init` golden test over the #064 logs.
- **T2** (`AndroidBootTests.testReachesInit`):
  - The console log contains `init: init first stage started!`, `init: init second stage started!`, and at least one `init: starting service` line.
  - Over `AndroidShellConsole`, the test runs `getprop ro.build.fingerprint`, `cat /proc/bootconfig`, `ls -l /dev/block/by-name`, `cat /proc/mounts`, `getenforce`, and `lsmod`, and compares the output with the reference where a category exists.

### Acceptance criteria

- [ ] The debug ramdisk, fstab, dynamic partitions, boot device names, AVB, bootconfig, and SELinux are each checked, and each result is recorded in [android-image.md](../../02-design/android-image.md) §6.
- [ ] Every deviation from Cuttlefish is documented: a row in [android-image.md](../../02-design/android-image.md) §13, and an entry with a reason in `expected-differences.yaml`.
- [ ] The serial logs show init running and service startup beginning.
- [ ] `.init` and `ANDROID_INIT` are emitted.
- [ ] The Android serial shell answers commands in developer mode.
- [ ] The SELinux mode equals the reference, or a permissive workaround carries a TODO, a reason, and a tracking issue.

### Notes

- The candidate strings come from [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3 as confirmed by #064. Update `BootSignals.swift` and the document together.
- `/data` does not mount until #095 provides KeyMint. Failures after `post-fs-data` belong to #095 and #014.

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

- The 20-port numbering check and `ConsolePortPlan`.
- The final port roles of §7.1.
- In-guest KeyMint and Gatekeeper.
- The vsock service decisions of §7.3.
- Networking in the order of §7.4.
- The other guest expectations of §7.6.
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
- The final layout `consolePorts`.
- The `androidboot.vendor.apex.*` keys for KeyMint and Gatekeeper, and the `androidboot.wifi_impl` value, in the layout.
- The [android-image.md](../../02-design/android-image.md) §7 verification: one decision per port and per service, and the client behaviour when a host service is missing.
- New §13 rows and `expected-differences.yaml` entries.
- The R-12 result in [../risks.md](../risks.md).

### Implementation steps

1. **20-port numbering.**
   - Boot the Linux test guest with `apkrun.test=ports apkrun.test.portcount=20`. The host writes `APKRUN-PORT-<i>\n` into port *i*, and the guest prints which `/dev/hvcN` received which marker ([../../02-design/vm.md](../../02-design/vm.md) §6.2).
   - If the mapping is not the identity, `ConsolePortPlan` reorders the array so that the guest numbering matches the Cuttlefish map.
   - If VZ refuses 20 ports, apply the fallback of §7.1 and record R-12 as realized.
   - Check: `LinuxGuestTests.testTwentyConsolePorts` passes.
2. **Port roles.**
   - Finalize the layout `consolePorts` from the §7.1 table: hvc0 `.systemConsole`, hvc1 `.service("serial")` in developer mode, hvc2 `.log("logcat")`, and hvc3–hvc19 `.silent`.
   - On Android, list the holder of each `/dev/hvc*` through the serial shell and compare with the reference "hvc users" category.
   - Check: no HAL crash-loops on a silent port in the hvc2 logcat capture. A crash loop means the same service exits and restarts three or more times within 10 minutes.
3. **Security HALs.**
   - Set the `androidboot.vendor.apex.*` keys that select the in-guest insecure KeyMint and Gatekeeper. Copy the APEX names from `Images/reference/16373615/target/` (§7.2).
   - Check:
     - `service list` shows the KeyMint (`IKeyMintDevice/default`) and Gatekeeper services;
     - vold mounts `/data` with metadata encryption (`/proc/mounts` shows `/data`);
     - the first boot formats `userdata` (the `formattable` path of §5.2).
4. **vsock services and absent host services.**
   - Leave out the `androidboot.vsock_*` and `modem_simulator_ports` keys.
   - For each client that the reference bootconfig configures, record in [android-image.md](../../02-design/android-image.md) §7.3 whether it stays idle, exits once, or crash-loops. The clients include tombstone transmit, the RIL and modem simulator, camera, and audio control.
   - Do the same for RIL, Bluetooth, NFC, UWB, GNSS, and sensors (§7.6). Keep them unless they crash-loop, and record the findings for #035.
   - Check: `/dev/rtc0` exists and `date` is sane (§7.6, from #012).
5. **Network.**
   - Try option 1 of §7.4 first: one NAT NIC as Wi-Fi through `androidboot.wifi_impl` and the reference properties.
   - If it fails, use option 2: several NICs in Cuttlefish order. This makes `VMDefinition.network` an ordered list, a VirtualMachineCore change noted in [../../02-design/vm.md](../../02-design/vm.md) §7.
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

- [ ] All 20 console ports are attached. Their numbering is verified with the `APKRUN-PORT-<i>` markers, and `ConsolePortPlan` is applied if needed.
- [ ] Each hvc port has a recorded role. No HAL crash-loops on a silent port.
- [ ] In-guest insecure KeyMint and Gatekeeper are selected by bootconfig, and vold mounts `/data`.
- [ ] The behaviour of each vsock client whose key is left out is recorded in [android-image.md](../../02-design/android-image.md) §7.3.
- [ ] The guest has a working network: an address, a default route, DNS resolution, and a validated network in `dumpsys connectivity` (FR-VM-04).
- [ ] LockSettings does not wait for Weaver.
- [ ] RIL, Bluetooth, NFC, UWB, GNSS, and sensors are kept unless they crash-loop, and the findings are recorded.

### Notes

- Prefer in-guest implementations selected by configuration over host-side re-implementations (§7). Do not remove guest services unless they are shown to break boot, stability, or resource use.
- vsock ports 6120–6199 are reserved for future substitutes. v1 substitutes are host-initiated only (§7.3).

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
   - Check: T0 golden tests over the #064 logs, and timeout and stall tests with a test clock.
2. **Headless GPU profile.**
   - Fill `gpuProfiles.headless` with the graphics fragment that Cuttlefish's `bootconfig_args.cpp` produces for its no-GPU mode, at the revision of build 16373615. Record the file and the revision in the layout comment.
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
   - Then `python3 Images/tools/reference/compare_boot.py Images/reference/16373615/target Images/work/16373615/vz-capture/` compares the captures.
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

- [ ] The framework and service failures that blocked boot are resolved. Each fix is recorded in [android-image.md](../../02-design/android-image.md) §13 and in `expected-differences.yaml`.
- [ ] A host-side readiness monitor (`BootPhaseDetector`) emits `.kernel`, `.init`, `.systemServer`, and `.bootCompleted` with their PerfMarkers. It fails boots with typed errors on panic, boot failure, timeout, and stall.
- [ ] `sys.boot_completed` is read through an available debug channel, the Android serial shell, and its value is `1`.
- [ ] Android stays stable for 10 minutes: no `system_server` restart, no watchdog, and no HAL crash loop.
- [ ] `BOOT_COMPLETED` is logged as a boot phase marker, and each boot has a `perf/boots.jsonl` record.
- [ ] Five cold boots in a row pass.
- [ ] The reference diff has no unexplained difference.
- [ ] Gate G2 passes on the reference Mac with a clean build from `main`. The result is recorded in [android-image.md](../../02-design/android-image.md) §8 and in [../risks.md](../risks.md) (R-06, R-11, R-12).

### Notes

- If no headless configuration reaches `boot_completed`, stop and follow [../roadmap.md](../roadmap.md) §2, "When a gate does not pass". Record it in R-06 and R-12, and file a follow-up task (#098 or the next free number) that attaches the #019 virtio-gpu device for M1.
- A gate failure is recorded in the design document's verification log and in [../risks.md](../risks.md) (status `realized` if a fallback is taken).
- The console strings for `.systemServer` depend on the console log level ([runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3). If `starting service 'zygote'` is not visible, the ADB signal of #015 or the serial-shell reading covers it.

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
   - Record `ro.adb.secure` from the VZ boot and from the #064 capture.
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

- [ ] ADB is enabled for the development image in developer mode. With developer mode off, nothing listens on 6520.
- [ ] The connection is documented: `adb -s 127.0.0.1:6520`, `apkrun dev adb`, and the troubleshooting entry.
- [ ] ADB is not exposed beyond the host: it listens on `127.0.0.1` only, and connections to other addresses are refused (NFR-SEC-06).
- [ ] `adb shell getprop`, `adb shell ps -A`, `adb shell pm list packages`, and `adb logcat` succeed. `adb shell getprop sys.boot_completed` prints `1`.
- [ ] The ADB readiness signals feed `BootPhaseDetector`.
- [ ] Ctrl-C stops Android with `reboot -p` and falls back to a forced stop after 20 s.

### Notes

- The guest's own `socket_vsock_proxy` (6520 → tcp 5555) keeps running and is unused (§7.3).
- Use only `$ANDROID_HOME/platform-tools/adb`. A second adb server from another SDK causes `device offline` ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §8).

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

- [ ] HelloText has a single Activity with a `TextView`, a `Button`, and a counter that persists across process restarts.
- [ ] HelloText is installed through ADB, and the install is a PackageInstaller session (FR-PKG-01).
- [ ] PackageManager reports the correct package name, `versionCode`, and `versionName`.
- [ ] HelloText is uninstalled through ADB, and PackageManager no longer lists it.
- [ ] The fixture build is reproducible, `out/` is git-ignored, and the signing key is test-only.

### Notes

- The M3–M4 `ADBStoreAgentChannel` uses `adb install-multiple` ([package-store.md](../../02-design/package-store.md) §6.1). That is #027 and does not change this task.

---

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

- [ ] The Activity is launched explicitly by component name.
- [ ] The process and task state are inspected through ADB.
- [ ] No rendering is required: the tests pass with `--gpu none`.
- [ ] The process starts, and ActivityManager reports the Activity as active (resumed).
- [ ] `am force-stop` stops HelloText, and its process is gone.
- [ ] Install, launch, stop, and uninstall pass end to end in one T2 test.

### Notes

- The headless profile of #014 must still give Android a default display. If `am start` fails with a display error, record it in #014's verification and in R-12 before changing this task.
- "CLI launch" in the v0.1 Definition of Done is complete only with #027.

---

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

- [ ] The bundle contains every block of §10.1 and the files of [filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1.
- [ ] Two builds from the same inputs give identical `SHA256SUMS`.
- [ ] The bundle is signed. A bad or untrusted signature, an extra file, and a hash mismatch are each rejected with the matching `ImageFailure`.
- [ ] `apkrun dev image install` installs atomically, and an interrupted install is cleaned up.
- [ ] The installed stock bundle boots to `boot_completed` (§10.3).
- [ ] No private key is committed, and no stock bundle is published (R-10).
- [ ] The unsigned development path is removed.

### Notes

- #066, #058, and #087 build on `ImageStore`. Keep `install(from:)` open for `.archive`, which #058 adds.
