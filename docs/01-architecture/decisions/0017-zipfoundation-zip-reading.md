# 0017. ZIPFoundation for reading ZIP archives

- Status: Accepted
- Date: 2026-09-28
- Related: #036, #073, #051, #091, #093, [../../02-design/package-store.md](../../02-design/package-store.md) §4.2, [../../02-design/update-system.md](../../02-design/update-system.md) §4.5, [../modules.md](../modules.md) §3

## Context

APKRun reads ZIP archives from untrusted sources in two places:

- APKStoreCore extracts APKs from `.apks`, `.xapk`, `.apkm`, and plain `.zip` containers ([../../02-design/package-store.md](../../02-design/package-store.md) §4.2).
- UpdateCore reads the F-Droid `entry.jar` to verify the repository index ([../../02-design/update-system.md](../../02-design/update-system.md) §4.5).

Both need deflate, ZIP64 (container files can be larger than 4 GiB), and streaming reads, so that the extraction limits can be checked while data is inflated. Foundation has no public ZIP API. `ditto` and `unzip` are processes, cannot enforce the limits during extraction, and have no stable error model.

The APK signature verifier is a different case. APK Signature Scheme v2 and later need the exact offsets of the central directory and the APK Signing Block, which a general ZIP library does not expose. It reads those structures directly ([../../02-design/package-store.md](../../02-design/package-store.md) §4.5).

## Decision

- Use ZIPFoundation (MIT) to read ZIP archives in APKStoreCore and UpdateCore. It is pinned with an `exact:` version in `Package.swift`, recorded in `Package.resolved`, and listed in the third-party notices (#093).
- Only the reading API is used, through one small wrapper per module (`ContainerReader` in APKStoreCore, `FDroidIndexVerifier` in UpdateCore). The wrapper enforces the extraction limits of [package-store.md](../../02-design/package-store.md) §4.2 itself, entry by entry and while streaming. It never calls the library's extract-to-directory functions, so names, symlinks, and paths are always checked by APKRun code.
- The APK signature verifier keeps its own reader of the ZIP structures it needs.
- The diagnostics bundle `ZipWriter` in DiagnosticsCore is a small writer on Compression.framework. DiagnosticsCore stays a leaf without third-party code.
- [../modules.md](../modules.md) §3 names the new edges: `APKStoreCore → ZIPFoundation` and `UpdateCore → ZIPFoundation`.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| An APKRun ZIP reader on Compression.framework | Possible, but a ZIP64 and deflate reader for untrusted input is new security-sensitive code. A maintained, widely used library is preferred (AGENTS §15) |
| `ditto -x -k` or `unzip` in a subprocess | Limits cannot be checked while extracting. Output parsing and error mapping would be fragile |
| libarchive (in the macOS SDK as a dylib, no public headers) | Not a supported API on macOS |

## Consequences

- One more pinned dependency to review in the release checks and the notices.
- #091 fuzzes the container reader through the wrapper (`ContainerReader`) and the `entry.jar` path, which covers the library code as used.
- A future change of the library is a new ADR, as for the other third-party components.

## Verification

#036 and #073 T0 tests of container detection and the extraction limits (zip bomb, path traversal, symlink entries, ZIP64 archive). #051 T0 tests of `entry.jar` verification. The #091 fuzz targets run with no open crash.
