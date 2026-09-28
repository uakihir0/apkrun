# Filesystem Layout

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../02-design/package-store.md](../02-design/package-store.md), [../02-design/wrapper.md](../02-design/wrapper.md), [../02-design/android-image.md](../02-design/android-image.md), [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md), [../03-reference/configuration.md](../03-reference/configuration.md) |

All paths are resolved through a single `APKRunPaths` value in `DiagnosticsCore` (so tests can relocate the root). Do not build these paths anywhere else. `APKRUN_HOME` overrides the root for tests and development. With `APKRUN_HOME` set, the logs of §2 move with it, to `$APKRUN_HOME/Logs/`. Debug builds default to `~/Library/Application Support/APKRun-Dev/` and `~/Library/Logs/APKRun-Dev/`, so they never touch a release installation ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).

---

## 1. Per-user data: `~/Library/Application Support/APKRun/`

```text
APKRun/
├── state.json # global schema version, instance ID, lastRuntimeVersion + lastRuntimeBuild, selfUpdate probe state (runtime-maintenance.md §3.8, §9)
├── settings.json # global settings (see configuration.md)
│
├── Images/ # runtime images (read-only once installed)
│   ├── <imageVersion>/ # e.g. 2026.10.0-cf16373615-arm64 (naming: 03-reference/runtime-image-manifest.md)
│   │   ├── manifest.json # RuntimeImageManifest (03-reference/runtime-image-manifest.md)
│   │   ├── manifest.sig # Ed25519 signature over manifest.json
│   │   ├── boot/
│   │   │   ├── kernel # uncompressed arm64 Image
│   │   │   ├── ramdisk.img # vendor ramdisk fragments + generic ramdisk (no bootconfig)
│   │   │   ├── bootconfig.txt # image-level bootconfig parameters (text)
│   │   │   └── cmdline.txt # kernel command line
│   │   ├── disks/
│   │   │   └── os.img # read-only raw GPT disk (boot/vbmeta partitions + unsparsed super)
│   │   ├── templates/
│   │   │   ├── persistent.img # raw GPT template: misc, metadata, frp (blank)
│   │   │   └── userdata.img # raw GPT template: userdata (blank or pre-formatted, see android-image.md §5)
│   │   └── SHA256SUMS
│   ├── current -> <imageVersion> # symlink = A/B pointer
│   ├── previous -> <imageVersion>
│   ├── .installing-<name>/ # install in progress; orphaned directories are removed at startup (runtime-image-manifest.md §8.3)
│   └── update-state.json # Android system update state: feed sequence, candidate, phase, rejected versions (runtime-maintenance.md §4.3)
│
├── Runtime/
│   ├── instance.lock # flock held by the instance owner (apkrund or `apkrun dev`), runtime-daemon.md §2.3
│   ├── daemon.json # apkrund run record: clean-exit flag, unclean exits, boot history (runtime-daemon.md §2.5)
│   ├── maintenance.json # present only while an APKRun update is being installed (runtime-maintenance.md §3.6)
│   └── instance/ # the one Android VM instance (v1 has exactly one)
│       ├── instance.json # VM sizing, MAC address, machine identifier, imageVersion, and userdata schema
│       │                 # userdataGeneration is reset on provisioning, Reset Android, and recovery restore;
│       │                 # migration records the from/to versions while an image migration runs (android-image.md §12.3)
│       ├── boot/
│       │   └── initrd.img # regenerated before every boot: ramdisk.img + merged bootconfig trailer
│       ├── persistent.img # APFS clone of templates/persistent.img, read-write
│       ├── userdata.img # APFS clone of templates/userdata.img, grown sparse to the configured size
│       └── recovery-points/
│           └── <timestamp>-<imageVersion>/ # APFS clones of persistent.img, userdata.img, and instance.json
│
├── Packages/
│   ├── journal.jsonl # transaction journal (append-only; recovered at startup)
│   ├── .trash/ # directories moved out by committed transactions; purged in the background
│   └── <packageId>/ # e.g. com.discord (case-collision rule: package-store.md §3.2)
│       ├── metadata.json # PackageRecord (03-reference/package-metadata-json.md)
│       ├── settings.json # user preferences for this package (update mode, integrations, window)
│       ├── current/ # installed artifact set
│       │   ├── artifact.json
│       │   ├── base.apk
│       │   └── split_*.apk
│       ├── previous/ # last known-good set, kept until the next successful update
│       ├── staged/ # verified update waiting for gentle install
│       ├── incoming/<ticket>/ # inspected downloads and imports; orphaned entries are removed
│       ├── failed/<versionCode>/ # rolled-back set; kept 7 days for diagnostics
│       └── icon/ # rendered icon layers from the Store Agent
│
├── Wrappers/
│   ├── registry.json # known wrappers: bundle ID → package ID, cdhash, path, bookmark, state (wrapper.md §7.2)
│   ├── icons/<bundleId>.png # user-chosen custom icons, kept for refreshes
│   └── staging/<uuid>/ # bundles being generated or refreshed; cleaned by recovery at startup
│
├── Updates/
│   ├── state.json # per package: last/next check, backoff, cursor, available/staged candidate, skipped versions
│   └── history.jsonl # one line per update run; 365 days or 5 000 lines (update-system.md §10)
│
├── Providers/
│   └── cache/<type>/<key>/ # provider indexes (F-Droid entry + index-v2), GitHub release JSON, ETags; safe to delete
│
├── Shared/ # the only host folder shared with the guest by default (policy-controlled)
│
└── Cache/ # safe to delete: download temp, derived previews
    └── images/ # Android system update downloads (<imageVersion>.aar[.partial]; runtime-maintenance.md §4.4)
```

Rules:

- Nothing under `Images/<version>/` is modified after installation. It is verified with `SHA256SUMS` on install and on `doctor --deep`.
- `persistent.img` and `userdata.img` are created by `clonefile(2)` from the image templates, then `userdata.img` is extended with `ftruncate` (sparse) and its GPT backup header is moved to the new end ([../02-design/android-image.md](../02-design/android-image.md) §5). They are never copied with a non-clone copy.
- `boot/initrd.img` is derived data. It is rebuilt before every boot and may be deleted at any time.
- ("read-only base + writable overlay + userdata") is realized as read-only `os.img` + writable `persistent.img` + `userdata.img`. Android never writes to its system partitions, so no overlay image is needed.
- Recovery points use `clonefile(2)`. They are cheap on APFS and are deleted after the migration passes its health check, keeping only the last one.
- `Packages/<id>/current|previous|staged` swaps are performed as journaled renames ([../02-design/package-store.md](../02-design/package-store.md) §5). Only apkrund (or `apkrun dev` in embedded mode) writes under `Packages/`.
- `Images/update-state.json` and `Cache/images/` are written only by `ImageUpdateCoordinator` and `ImageDownloader` in apkrund. `Runtime/maintenance.json` is written only by apkrund's `MaintenanceService`. Neither APKRun updates nor Android system updates write under `Packages/`, except for schema migrations shipped in a release ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- A file migrated to a newer schema keeps its original next to it as `<name>.v<old>.json` for 90 days ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- `Updates/` is written only by UpdateCore in apkrund. Losing `state.json` makes every package due for a check and is otherwise harmless ([../02-design/update-system.md](../02-design/update-system.md) §10). Provider tokens are in the Keychain, never under `Updates/` or `Providers/`.
- APKRun never writes inside a wrapper bundle after generation (FR-WRP-04).

## 2. Logs: `~/Library/Logs/APKRun/`

```text
Logs/APKRun/
├── vm/
│   ├── console.log # guest serial (hvc0), rotated at 20 MiB × 5
│   ├── console.<n>.log
│   └── boot-<timestamp>.log # per-boot copy for the last 5 boots (survives crashes; fsync on each line batch)
├── guest/
│   └── logcat-<timestamp>.log # logcat capture: developer mode, and the boot after a failed boot (diagnostics.md §8.3); last 5
├── crash/
│   └── <timestamp>-runtime/ # diagnostics snapshot captured when the runtime fails (runtime-daemon.md §3.6); last 10 kept
├── apkrund.log, apkrund.<n>.log # public-text mirror of the daemon's os_log entries, 10 MiB × 3 (diagnostics.md §3.3)
└── perf/
    ├── launches.jsonl # one record per app launch, written by apkrund (diagnostics.md §4.3); newest 2,000
    └── boots.jsonl # one record per Android boot; newest 200
```

`os_log` (unified logging) is the primary log sink. The file mirrors exist so that diagnostics bundles can include logs even when `log show` is unavailable or slow.

## 3. Caches: `~/Library/Caches/io.apkrun.APKRun/`

Thumbnails and UI caches only. Everything here is disposable.

## 4. APKRun.app bundle

```text
APKRun.app/Contents/
├── MacOS/APKRun
├── Helpers/
│   ├── apkrund # daemon executable (entitlement: com.apple.security.virtualization)
│   └── APKRunLauncher.app # generic launcher (io.apkrun.APKRunLauncher); its executable is the wrapper template
├── Library/
│   ├── LaunchAgents/io.apkrun.apkrund.plist
│   └── LoginItems/APKRunMenuBar.app
├── Frameworks/
│   ├── VirGLRuntime/ # libvirglrenderer, libepoxy, ANGLE libEGL + libGLESv2 (pinned builds)
│   ├── Sparkle.framework # APKRun updates, linked by APKRun.app only (ADR-0016)
│   └── (Swift packages are statically linked)
├── Resources/
│   ├── bin/apkrun # CLI
│   ├── tools/aapt2 # host preview metadata (Apache-2.0, pinned from Google Maven)
│   ├── guest/ # Guest Agent dex/jar for development mode on stock images
│   ├── components.json # version, build, API and protocol majors, data schemas, pinned components (runtime-maintenance.md §2.1)
│   ├── compatibility.json # app compatibility database (diagnostics.md §10)
│   ├── ThirdPartyNotices.html
│   └── *.lproj / Localizable.xcstrings
└── Info.plist
```

The runtime image is **not** inside the app bundle. It is downloaded or installed into `Images/` (size, independent update cadence, notarization; [decisions/0011-runtime-image-bundle.md](decisions/0011-runtime-image-bundle.md)).

## 5. Wrapper bundle

```text
Discord.app/Contents/
├── MacOS/APKRunLauncher # copy of the template, re-signed with the wrapper identifier
├── Resources/
│   ├── AppIcon.icns
│   ├── wrapper.json # identity + initial preferences (03-reference/wrapper-json.md)
│   └── bootstrap/ # portable and distribution wrappers only: bootstrap.json, base.apk, splits
├── Info.plist
├── PkgInfo
└── _CodeSignature/
    └── CodeResources
```

Anatomy, Info.plist keys, and generation rules: [../02-design/wrapper.md](../02-design/wrapper.md) §2.

## 6. Source-tree paths used at build and dev time

| Path | Purpose |
|---|---|
| `build/` | Xcode / SwiftPM outputs (git-ignored) |
| `ThirdParty/out/<name>/<rev>/` | built third-party artifacts (git-ignored, cached in CI) |
| `Images/work/<buildId>/` | derived artifacts from image tooling (git-ignored) |
| `Images/manifests/<buildId>/` | committed `inventory.json` and `android-image.json` of each pinned build ([../03-reference/android-image-manifest.md](../03-reference/android-image-manifest.md)). Runtime image manifests are built into bundles and are not committed |
| `Images/reference/` | committed reference captures: `<buildId>/` from #064, `vz/<macOS build>/topology.txt` from #011 |
| `Tests/Fixtures/AndroidApps/out/` | built fixture APKs (git-ignored, reproducible) |
