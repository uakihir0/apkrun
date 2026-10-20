# Filesystem Layout

This page lists every host path that APKRun reads or writes, and the layout of the guest disks. All paths come from one `APKRunPaths` value in DiagnosticsCore, so tests can relocate the root. No other code builds these paths.

`APKRUN_HOME` overrides the root for tests and development. With it set, the logs of §2 move to `$APKRUN_HOME/Logs/`. Debug builds use `~/Library/Application Support/APKRun-Dev/` and `~/Library/Logs/APKRun-Dev/` ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6), so they never touch a release installation.

---

## 1. Per-user data: `~/Library/Application Support/APKRun/`

```text
APKRun/
├── state.json                         # schema version, instance ID, lastRuntimeVersion + lastRuntimeBuild, `selfUpdate` probe state (runtime-maintenance.md §3.8, §9)
├── settings.json                      # global settings (configuration.md)
├── Diagnostics/
│   └── index.json                     # indexed host crash-report paths (runtime-daemon.md §2.5)
│
├── Images/                            # runtime images, read-only once installed
│   ├── <imageVersion>/                # e.g. 2026.10.0-cf16373615-arm64 (naming: runtime-image-manifest.md)
│   │   ├── manifest.json              # RuntimeImageManifest
│   │   ├── manifest.sig               # Ed25519 signature over manifest.json
│   │   ├── boot/
│   │   │   ├── kernel                 # uncompressed arm64 Image
│   │   │   ├── ramdisk.img            # vendor ramdisk fragments + generic ramdisk (no bootconfig)
│   │   │   ├── bootconfig.txt         # image-level bootconfig parameters (text)
│   │   │   └── cmdline.txt            # kernel command line
│   │   ├── disks/
│   │   │   └── os.img                 # read-only raw GPT disk (boot and vbmeta partitions, unsparsed super)
│   │   ├── templates/
│   │   │   └── userdata.img           # raw GPT template: misc, metadata, frp (blank), and userdata, last
│   │   │                              # (blank or pre-formatted; android-image.md §5)
│   │   └── SHA256SUMS
│   ├── current -> <imageVersion>      # symlink = A/B pointer
│   ├── previous -> <imageVersion>
│   ├── .installing-<name>/            # install in progress; <name> = imageVersion, or manual-<16 hex>; removed at startup when orphaned (runtime-image-manifest.md §8.3)
│   └── update-state.json              # Android system update state: feed sequence, candidate, phase, rejected versions (runtime-maintenance.md §4.3)
│
├── Runtime/
│   ├── instance.lock                  # flock held by the instance owner (apkrund or `apkrun dev`) (runtime-daemon.md §2.3)
│   ├── daemon.json                    # apkrund run record: clean-exit flag, unclean exits, boot history (runtime-daemon.md §2.5)
│   ├── maintenance.json               # present only while an APKRun update is being installed (runtime-maintenance.md §3.6)
│   └── instance/                      # the one Android VM instance (v1 has exactly one)
│       ├── instance.json              # VM sizing, MAC address, machine identifier, imageVersion in use, userdata schema version,
│       │                              # userdataGeneration (new UUID on provisioning, Reset Android, recovery point restore), last GuestFacts,
│       │                              # migration (from, to) while an image migration runs (android-image.md §12.3)
│       ├── boot/
│       │   └── initrd.img             # regenerated before every boot: ramdisk.img + merged bootconfig trailer
│       ├── userdata.img               # APFS clone of templates/userdata.img, read-write, grown sparse to the configured size
│       └── recovery-points/
│           └── <timestamp>-<imageVersion>/   # APFS clones (clonefile) of userdata.img + instance.json
│
├── Packages/
│   ├── journal.jsonl                  # transaction journal (append-only; recovered at startup)
│   ├── .trash/                        # directories moved out by committed transactions; purged in the background
│   └── <packageId>/                   # e.g. com.discord (case-collision rule: package-store.md §3.2)
│       ├── metadata.json              # PackageRecord (package-metadata-json.md)
│       ├── settings.json              # user preferences for this package (update mode, integrations, window)
│       ├── current/                   # installed artifact set (base.apk + split_*.apk + artifact.json)
│       ├── previous/                  # last known-good artifact set (kept until the next successful update)
│       ├── staged/                    # verified update waiting for a gentle install
│       ├── incoming/<ticket>/         # downloads and imports being inspected (deleted on failure, after 24 h, or at startup when orphaned)
│       ├── failed/<versionCode>/      # a rolled-back set, kept 7 days for diagnostics
│       └── icon/                      # rendered icon PNGs (1536 px layers, adaptive) from the Store Agent
│
├── Wrappers/
│   ├── registry.json                  # known wrappers: bundle ID → package ID, cdhash, path, bookmark, state (wrapper.md §7.2)
│   ├── icons/<bundleId>.png           # user-chosen custom icons, kept for refreshes
│   └── staging/<uuid>/                # bundles being generated or refreshed; cleaned by recovery at startup
│
├── Updates/
│   ├── state.json                     # per package: last/next check, backoff, cursor, available/staged candidate, skipped versions
│   └── history.jsonl                  # one line per update run; 365 days or 5 000 lines (update-system.md §10)
│
├── Providers/
│   └── cache/<type>/<key>/            # provider indexes (F-Droid entry + index-v2), GitHub release JSON, ETags; safe to delete
│
├── Shared/                            # the only host folder that can be shared with the guest, under the integration policy (off by default: security-model.md §6)
│
└── Cache/                             # safe to delete: download temp, derived previews
    └── images/                        # Android system update downloads (<imageVersion>.aar[.partial]; runtime-maintenance.md §4.4)
```

Rules:

- Nothing under `Images/<version>/` changes after installation. `SHA256SUMS` verifies it on install and on `doctor --deep`.
- `userdata.img` comes from `clonefile(2)` of the template, is extended with `ftruncate` (sparse), and its GPT backup header moves to the new end ([android-image.md](../02-design/android-image.md) §5). Never copy it with a non-clone copy.
- `boot/initrd.img` is derived data. It is rebuilt before every boot and may be deleted at any time.
- The read-only base plus writable overlay is realized as read-only `os.img` plus writable `userdata.img`. `userdata.img` holds the small instance partitions (misc, metadata, frp) and `/data`. Android never writes its system partitions, so no overlay image is needed. There is no third disk: the stock fstab gives the third virtio-blk disk (`vdc`) to vold ([android-image.md](../02-design/android-image.md) §4.2).
- Recovery points use `clonefile(2)`. They are deleted after the migration passes its health check, keeping only the last one.
- Swaps of `Packages/<id>/current`, `previous`, and `staged` are journaled renames ([package-store.md](../02-design/package-store.md) §5). Only apkrund (or `apkrun dev` in embedded mode) writes under `Packages/`.
- `Images/update-state.json` and `Cache/images/` are written only by `ImageUpdateCoordinator` and `ImageDownloader` in apkrund. `Runtime/maintenance.json` is written only by `MaintenanceService`. Neither APKRun updates nor Android system updates write under `Packages/`, except for schema migrations shipped in a release ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- A file migrated to a newer schema keeps its original as `<name>.v<old>.json` for 90 days ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- `Updates/` is written only by UpdateCore in apkrund. Losing `state.json` makes every package due for a check, and is otherwise harmless ([update-system.md](../02-design/update-system.md) §10). Provider tokens are in the Keychain, never under `Updates/` or `Providers/`.
- APKRun never writes inside a wrapper bundle after generation (FR-WRP-04).

## 2. Logs: `~/Library/Logs/APKRun/`

```text
Logs/APKRun/
├── vm/
│   ├── console.log                    # guest serial (hvc0), rotated at 20 MiB × 5
│   ├── console.<n>.log
│   └── boot-<timestamp>.log           # per-boot copy for the last 5 boots (survives crashes; fsync on each line batch)
├── guest/
│   └── logcat-<timestamp>.log         # logcat capture: developer mode, and the boot after a failed boot (diagnostics.md §8.3); last 5
├── crash/
│   └── <timestamp>-runtime/           # diagnostics snapshot captured when the runtime fails (runtime-daemon.md §3.6); last 10 kept
├── apkrund.log, apkrund.<n>.log       # public-text mirror of the daemon's os_log entries, 10 MiB × 3 (diagnostics.md §3.3)
└── perf/
    ├── launches.jsonl                 # one record per app launch, written by apkrund (diagnostics.md §4.3); newest 2,000
    └── boots.jsonl                    # one record per Android boot; newest 200
```

`os_log` (unified logging) is the primary sink. The files mirror it, so that diagnostics bundles include logs even when `log show` is unavailable or slow.

## 3. Caches: `~/Library/Caches/io.apkrun.APKRun/`

Thumbnails and UI caches only. Everything here is disposable.

## 4. APKRun.app bundle

```text
APKRun.app/Contents/
├── MacOS/APKRun
├── Helpers/
│   ├── apkrund                        # daemon executable (entitlement: com.apple.security.virtualization)
│   └── APKRunLauncher.app             # generic launcher (io.apkrun.APKRunLauncher); its executable is the wrapper template
├── Library/
│   ├── LaunchAgents/io.apkrun.apkrund.plist
│   └── LoginItems/APKRunMenuBar.app
├── Frameworks/
│   ├── VirGLRuntime/                  # libvirglrenderer, libepoxy, ANGLE libEGL + libGLESv2 (pinned builds)
│   ├── Sparkle.framework              # APKRun updates, linked by APKRun.app only (ADR-0016)
│   └── (Swift packages are statically linked)
├── Resources/
│   ├── bin/apkrun                     # CLI
│   ├── tools/aapt2                    # host preview metadata (Apache-2.0, pinned from Google Maven)
│   ├── guest/                         # Guest Agent dex/jar for development mode on stock images
│   ├── components.json                # version, build, API and protocol majors, data schemas, pinned components (runtime-maintenance.md §2.1)
│   ├── compatibility.json             # app compatibility database (diagnostics.md §10)
│   ├── ThirdPartyNotices.html
│   └── *.lproj / Localizable.xcstrings
└── Info.plist
```

The runtime image is **not** inside the app bundle. It is installed into `Images/` instead, because of its size, its independent update cadence, and notarization ([0011](decisions/0011-runtime-image-bundle.md)).

## 5. Wrapper bundle

```text
Discord.app/Contents/
├── MacOS/APKRunLauncher               # copy of the template, re-signed with the wrapper identifier
├── Resources/
│   ├── AppIcon.icns
│   ├── wrapper.json                   # identity + initial preferences (wrapper-json.md)
│   └── bootstrap/                     # portable and distribution wrappers only: bootstrap.json, base.apk, splits
├── Info.plist
├── PkgInfo
└── _CodeSignature/
```

Anatomy, Info.plist keys, and generation rules: [wrapper.md](../02-design/wrapper.md) §2.

## 6. Source-tree paths used at build and dev time

| Path | Purpose |
|---|---|
| `build/` | Xcode and SwiftPM outputs (git-ignored) |
| `ThirdParty/out/<name>/<rev>/` | Built third-party artifacts (git-ignored, cached in CI) |
| `Images/work/<buildId>/` | Derived artifacts from image tooling (git-ignored) |
| `Images/manifests/<buildId>/` | Committed `inventory.json` and `android-image.json` of each pinned build ([android-image-manifest.md](../03-reference/android-image-manifest.md)). Runtime image manifests are built into bundles and are not committed. |
| `Images/reference/` | Committed reference captures: `<buildId>/` and `vz/<macOS build>/topology.txt` |
| `Tests/Fixtures/AndroidApps/out/` | Built fixture APKs (git-ignored, reproducible) |
