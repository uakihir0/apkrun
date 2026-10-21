# Legal and Licensing

This guide holds the engineering rules for licenses: what APKRun may use, ship, and publish; how notices are produced; and what a release must carry. It is not legal advice. The legal review of these rules is tracked in R-10 ([risks.md](../04-plan/risks.md)). `scripts/check-licenses.sh` (planned, #94) checks the SPDX values of this guide against the license files.

---

## 1. APKRun's own license

### 1.1 Status

- The project license is open question OQ-40 ([open-questions.md](../04-plan/open-questions.md)). It is decided in an ADR before the launcher binary is given to other people (#90), and before the v0.4 public demo at the latest ([roadmap.md](../04-plan/roadmap.md) §3.4).
- Until the ADR is accepted, source files carry no license header, and nothing from outside the project is added except under §3 and §4.
- The notices of §6 and §7 name the chosen license.

### 1.2 Requirements for the choice

| Requirement | Why |
|---|---|
| Anyone may redistribute the launcher binary inside a wrapper, without publishing their code or the wrapped app | portable and distribution wrappers contain `APKRunLauncher` ([wrapper.md](../02-design/wrapper.md) §10, §11) |
| Compatible with every license of the app list (§4.2) | those components are linked or embedded in APKRun.app |
| Usable next to GPL code in the image, as a separate program | the agents and `apkrun_vsockd` run in an image that holds the GPL kernel (§7) |
| States how contributions are licensed | the default is "contributions are under the project license" |

The ADR also decides the header format. The proposal is one line, `SPDX-License-Identifier: <id>`, in each source file's comment style ([coding-conventions.md](coding-conventions.md)). Derived files keep their own header (§3.1).

---

## 2. Prebuilt Cuttlefish image

The `kind: stock` image comes from a ci.android.com build ([android-image.md](../02-design/android-image.md) §2). It is for development only (M1–M4; [android-image.md](../02-design/android-image.md) §2.3).

| Allowed | Never |
|---|---|
| fetch it with `apkrun_image fetch` into `Images/work/<buildId>/` (git-ignored) | commit it, or any file extracted from it (`boot.img`, `super.img`, `os.img`, ramdisks, kernels) |
| build and install `stock` bundles on your Mac, lab Macs, the reference host, and private runner caches | attach it, or a bundle made from it, to an issue, pull request, release, or CI artifact (artifacts of a public repository are public) |
| run the AndroidStock suite on it ([test-strategy.md](../04-plan/test-strategy.md)) | upload it to the updates host or put it in a feed |
| commit its text metadata: `Images/manifests/<buildId>/` and `Images/reference/<buildId>/` | give it to another person, as a file, bundle, or disk image |

- The release image key never signs a `stock` bundle. `apkrun_image bundle` refuses to write one, and the release workflow refuses to publish one ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.3).
- Clients get no feed updates while they run a `stock` image (C7, [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.2).
- Every published image is `kind: apkrun`, built from AOSP source (#36; [android-image.md](../02-design/android-image.md) §11), so APKRun controls its notices and source offer (§7).

---

## 3. Derived code and patches

### 3.1 RiftVM

RiftVM's source is MIT-licensed and serves as a technical reference for the graphics path ([graphics.md](../02-design/graphics.md) §2). #19 copies no RiftVM code. The RiftVM package is never a build dependency or a distributed component.

| Rule | Detail |
|---|---|
| Lock entry | `riftvm`: `kind: source`, `ships: reference`, commit `51f19193b1d3326b2e164d37a2a59e9970375170` (`riftvm-v0.6.1`), `license: MIT`, `licenseFiles: ["LICENSE"]` ([build-system.md](build-system.md) §6.5) |
| Analysis | #19 records each file's license header and whether it is copied, adapted, or rewritten, in `docs/02-design/riftvm-analysis.md` ([graphics.md](../02-design/graphics.md) §2.2) |
| Copied or adapted file | keeps RiftVM's copyright and MIT notice at the top, then the line `Derived from RiftVM <commit> (MIT)` with the full pinned commit, in `//` comments |
| Rewritten file | written from our own understanding, with no RiftVM notice. When in doubt, treat the file as adapted |
| Other license | not copied: rewritten, or its origin becomes its own lock entry (§4) |
| Notices | reference-only source is excluded from `ThirdPartyNotices.html`. If RiftVM code is later copied, change the entry to `ships: derived` and include its MIT text and marked-file list (§6.2) |
| Check | `scripts/check-licenses.sh` fails when a marked file names a commit other than the pin, or lacks its MIT notice |

### 3.2 Patches

- Patches in `ThirdParty/patches/<name>/` carry the license of the component they change ([build-system.md](build-system.md) §6.2).
- A patch header keeps the author, the reason, and whether it went upstream.
- A patch carried from RiftVM, or from the Homebrew taps the graphics build used ([graphics.md](../02-design/graphics.md) §5), keeps the original `From:` author and adds `Carried from <source> <commit>`.
- A patch sent upstream is offered under the upstream project's license and contribution rules.

### 3.3 Vendored files

- `Images/tools/vendor/` holds `avbtool.py` (from `platform/external/avb`) and `mkbootimg.py`, `unpack_bootimg.py`, and the GKI certificate helper (from `platform/system/tools/mkbootimg`), unchanged, with their upstream license headers. Their license files are recorded in `ThirdParty/ThirdParty.lock.json` ([build-system.md](build-system.md) §6.4).
- `Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem` is the pinned AOSP AVB test key. It signs only the development image variant. It is public test material, not a production credential.
- The apksig test vectors keep the upstream `NOTICE` and license file in their resource directory.
- Vendored files are never edited, so their licenses never change ([build-system.md](build-system.md) §6.4).

---

## 4. License policy

### 4.1 Where a component ends up

The lock entry's `ships` value decides which list applies ([build-system.md](build-system.md) §6.1):

| `ships` | Meaning | List |
|---|---|---|
| `app`, `derived` | linked, embedded, or copied into APKRun.app, the CLI, the launcher, or our source | app list (§4.2) |
| `image` added by us | the agents, `apkrun_vsockd`, and their contents | app list (§4.2) |
| `image` from AOSP | everything the AOSP build installs, including the kernel | image rules (§4.3) |
| `reference` | analysis source; not built, copied, linked, or distributed | no redistribution list; license identity and source license files recorded |
| `tooling`, committed (`kind: vendored`, `gradle` for fixture apps) | repository files: vendored scripts, test vectors, fixture APKs, recorded streams | app list (§4.2) |
| `tooling`, downloaded (`kind: prebuilt`, `source`) | build and test inputs fetched by a script; never committed, uploaded, or published | tooling list (§4.4) |

A component that ships in more than one place has a list as `ships`; the strictest list applies.

### 4.2 App list

`scripts/check-licenses.sh` reads the lists in the code blocks of this section, as `scripts/check-module-deps.sh` reads [modules.md](../01-architecture/modules.md) §3. A change to a list follows the review rules of [workflow.md](workflow.md) §6.

```text
app:
MIT
MIT-0
BSD-2-Clause
BSD-3-Clause
Apache-2.0
Apache-2.0 WITH LLVM-exception
Apache-2.0 WITH Swift-exception
ISC
Zlib
libpng-2.0
BSL-1.0
0BSD
```

- GPL, LGPL, AGPL, MPL, EPL, and CDDL code is never linked into, embedded in, or copied into APKRun.app, the CLI, the launcher, the agents, or `apkrun_vsockd`.
- An Apache-2.0 component with a `NOTICE` file lists it in `licenseFiles`, and the notices reproduce it.

### 4.3 Image rules

- AOSP components are not lock entries. `Guest/product/manifest/pinned.xml` pins them, and their license data comes from the AOSP build (§7.2).
- The image may contain what AOSP ships, including GPL and LGPL components (kernel, some system tools), if their corresponding source is published (§7.4).
- A module without license metadata stops the image release. So does a module with the AOSP condition `proprietary` or `by_exception_only`, until the decision is recorded: remove the module, or record why it may ship.
- Google apps and services are never in the image (§8).

### 4.4 Tooling list

```text
tooling:
(everything on the app list)
GPL-2.0-only
GPL-2.0-or-later
GPL-3.0-only
GPL-3.0-or-later
LGPL-2.1-only
LGPL-2.1-or-later
LGPL-3.0-only
LGPL-3.0-or-later
MPL-2.0
X11
```

The tooling list applies only to `ships: tooling` entries of `kind: prebuilt` or `kind: source`. Those are downloaded by a script, pinned by hash or commit, and never committed, uploaded as a CI artifact, or published. The Alpine test guest is the main case ([vm.md](../02-design/vm.md) §12).

### 4.5 Expressions and unknown licenses

| Value | Rule |
|---|---|
| `A OR B` | passes if one side is allowed. For components in a notice output, include every license file upstream ships |
| `A AND B` | passes if every part is allowed |
| `A WITH E` | passes only if the whole expression is on the list |
| empty, missing, `NOASSERTION`, `LicenseRef-*` | fails |
| anything else, for a distributed or tooling component | fails (AGPL, SSPL, BUSL, non-commercial licenses) |

These rules apply to components APKRun distributes or uses as build or test tooling. A `ships: reference` entry must still have an identified license and a committed copy of its source license, but is not checked against a redistribution list.

### 4.6 A new or changed component

1. A component with runtime impact needs an ADR first ([AGENTS.md](../../AGENTS.md) §6.6; [decisions/README.md](../01-architecture/decisions/README.md)).
2. The pull request adds the lock entry with `license`, `licenseFiles`, and `ships`, and the license copies of §6.1 ([build-system.md](build-system.md) §6.8).
3. `scripts/check-licenses.sh` passes in the same pull request (planned, #94; required for every new component).
4. A pin update re-reads the upstream license files. A changed license updates `license`, and the pull request says so.
5. A distributed or tooling component whose license is not allowed is replaced or removed. Replacement needs an ADR and its own task.

---

## 5. Component inventory

`ThirdParty/ThirdParty.lock.json` is the inventory ([build-system.md](build-system.md) §6.1). For `swiftpm`, `gradle`, and `cargo` entries, `name` is the lock identity: the package identity, `group:artifact`, or the crate name. A Gradle entry may cover a Maven group as `group:*` when all its artifacts share a license.

| Component | Ships | License | Notes |
|---|---|---|---|
| virglrenderer, libepoxy | app | MIT | `Contents/Frameworks/VirGLRuntime/` |
| ANGLE | app | BSD-3-Clause | `angle-astc-encoder`, `angle-vulkan-headers`, `angle-zlib` are separate app entries; the native build checks their `gnTargetPrefixes` against `gn desc` |
| aapt2 (planned, #28) | app | Apache-2.0 | with the notices of the libraries it links, as shipped with the Maven artifact |
| Sparkle 2 (planned, #58) | app | MIT | with the external licenses its `LICENSE` lists (ADR-0016) |
| swift-protobuf, swift-argument-parser | app | Apache-2.0 WITH Swift-exception | GuestProtocol; CLI |
| ZIPFoundation | app | MIT | APKStoreCore and UpdateCore, reading only (ADR-0017) |
| Kotlin stdlib, `org.jetbrains:annotations`, kotlinx-coroutines | app, image | Apache-2.0 | the Guest Agent APK (`Resources/guest/`) and the image |
| protobuf-javalite | app, image | BSD-3-Clause | same |
| RiftVM | reference | MIT | analysis input only (§3.1) |
| `libc`, `log`, `android_logger` and their dependencies | image | MIT OR Apache-2.0 | `apkrun_vsockd`; the product uses AOSP `external/rust/crates`, which carry their own metadata |
| AOSP, including the prebuilt kernel | image | many; kernel GPL-2.0-only | not lock entries (§4.3); notices and source offer in §7 |
| `avbtool.py`, AOSP AVB test key | tooling, committed | MIT | vendored, test only (§3.3) |
| `mkbootimg.py`, `unpack_bootimg.py` | tooling, committed | Apache-2.0 | vendored (§3.3) |
| apksig test vectors | tooling, committed | Apache-2.0 | §3.3 |
| AndroidX, Compose, Kotlin in the fixture apps | tooling, committed | Apache-2.0 | inside the committed APKs of `Tests/Fixtures/apks/` |
| Mesa (virgl), `kmscube`, and their closure | tooling | MIT, with the closure's own licenses (SGI-B-2.0, BSL-1.0, Apache-2.0, LGPL, GPL) | Alpine packages of the test initramfs. License texts come from upstream tarballs whose SHA-512 matches the Alpine APKBUILD. libdrm has no license file; its `xf86drm.c` notice is copied |
| Alpine `linux-virt` kernel | tooling, downloaded | GPL-2.0-only | never committed or published |
| Alpine minirootfs and test packages (`socat`, `ssl_client`, `libcrypto3`, `libgpiod`, `libssl3`, `readline`, ncurses) | tooling, downloaded | per package; checked against Alpine metadata and upstream notices | `alpine-socat` uses `GPL-2.0-only` as a conservative basis, not the Alpine expression `GPL-2.0-only WITH OpenSSL-Exception`; `COPYING` and `COPYING.OpenSSL` are kept. `libgpiod` is `GPL-2.0-or-later AND LGPL-2.1-or-later`; `readline` is `GPL-3.0-or-later`; ncurses is X11 |
| Alpine e2fsprogs packages | tooling, downloaded | GPL, LGPL, BSD, MIT, as in the lock | the e2fsprogs entries select `LGPL-2.1-only` from the upstream LGPL-2-or-later grant; open for legal review (R-10) |
| depot_tools | tooling, downloaded | BSD-3-Clause | ANGLE build only |

- Tools that only run (Xcode, protoc, buf, XcodeGen, ruff, ktfmt, bundletool, the Android SDK build tools) are not lock entries. They are never committed or redistributed. Each developer accepts their terms when installing them ([environment-setup.md](environment-setup.md)).
- Generated code is APKRun code. Its runtime parts are the swift-protobuf and protobuf-javalite entries.

---

## 6. ThirdPartyNotices

### 6.1 License files

- `licenseFiles` lists paths inside the upstream source (`COPYING`, `LICENSE`, `NOTICE`).
- A copy of each is committed as `ThirdParty/licenses/<name>/<file>`. `scripts/release/generate-notices.py --refresh <name>` fetches the pinned source and refreshes the copies. For Gradle and Cargo packages without a license file in the artifact, the copy comes from the upstream repository at the pinned version.
- The `third-party` CI job runs `scripts/release/generate-notices.py --check`: every shipped app notice has a committed copy, and each `kind: source` app or derived copy matches its pinned source byte for byte. The full check of reference sources and resolved Swift, Gradle, and Cargo packages is planned (#94).

### 6.2 Generation

`scripts/release/generate-notices.py` runs as a build phase of the `APKRun` target in every configuration ([build-system.md](build-system.md) §11). It reads only committed files, so it works offline:

| Input | Used for |
|---|---|
| `ThirdParty/ThirdParty.lock.json` | components, licenses, repositories |
| `Package.resolved`, `Guest/<module>/gradle.lockfile`, `Guest/vsockd/Cargo.lock` | exact versions |
| `ThirdParty/licenses/` | license texts |

The output `Contents/Resources/ThirdPartyNotices.html`:

- starts with APKRun's own license (§1), or names OQ-40 while the project license is undecided;
- has one section per entry whose `ships` contains `app` or `derived`, sorted by name: name, version, repository, SPDX expression, copyright lines from the license files, and each license text in a `<pre>` block;
- lists, for `derived` entries, the files that carry the marker (§3.1);
- is deterministic (no dates, sorted keys) and self-contained: UTF-8, escaped text, inline CSS, no scripts, no remote resources.

The Guest Agent APK is covered by the Kotlin entries. The launcher has no third-party code ([wrapper.md](../02-design/wrapper.md) §11), so a wrapper needs only APKRun's own notice (§9).

### 6.3 Checks

| Check | Where |
|---|---|
| allowed license per distributed or tooling entry; a committed copy per lock entry; identified reference licenses; every resolved package listed; RiftVM markers name the pin | `scripts/check-licenses.sh` (planned, #94); T0 tests with a sample lock that lacks one license, and with the real lock |
| generator output for a sample lock equals a golden file | T0 script test in `lint` |
| Release build contains the notices of each `ships: app` and `derived` entry | `scripts/release/check-release-build.sh` ([build-system.md](build-system.md) §3.1) |
| notices visible in APKRun.app and in the image | test C10-8 ([test-strategy.md](../04-plan/test-strategy.md) §8.7) |

### 6.4 Where users see them

APKRun.app's Help menu has **Third-Party Notices**, which opens `ThirdPartyNotices.html` in the default browser through `NSWorkspace`. The image notices are in Android (§7.1).

---

## 7. Image notices and source offers

### 7.1 Notices in Android

- The product build keeps AOSP's notice generation. Android shows the notices in Settings → About → Legal information.
- APKRun's additions declare license metadata, so they appear there:
  - `Guest/product/Android.bp` (planned, #36) has a `license` module with APKRun's license, the default for the product's modules;
  - the agent APK imports name a second `license` module with the Kotlin stdlib, kotlinx-coroutines, and protobuf-javalite texts. `build-product.sh` copies the texts from `ThirdParty/licenses/` to `Guest/product/prebuilt/licenses/` (git-ignored), because Soong cannot read paths outside the product directory ([build-system.md](build-system.md) §9);
  - `Guest/vsockd/Android.bp` names APKRun's license; the crates keep their AOSP metadata.

### 7.2 License data of the image build

After `m dist`, `scripts/aosp/build-product.sh` reads the license metadata of the installed modules from the AOSP SBOM or notice data (exact command fixed by #94). It then:

- fails if an installed module has no license metadata;
- lists modules with `proprietary` or `by_exception_only` for the decision of §4.3;
- writes `source-offer.json` next to `build-info.json`: for each module with a GPL, LGPL, or MPL license, the module, its license, its project path, and its `pinned.xml` revision. The kernel entry names the kernel source revision of the prebuilt kernel.

The release manager uploads `source-offer.json` with the image zip ([workflow.md](workflow.md) §10).

### 7.3 The notice file in the bundle

`python3 -m apkrun_image bundle` writes `legal/notice.html` into release bundles. The manifest names it in `legal.notice` and lists it in `files`, so the signature covers it ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.2). It contains:

- the image version and the provenance values `pinnedManifestSHA256`, `revisions.guest`, and `builderImageDigest` ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md));
- a note that the full notices are in Android (§7.1), and APKRun's own license;
- the source offer: for each `source-offer.json` entry, the component, license, project path, revision, and the URL of its source (§7.4).

A release bundle without `source-offer.json` is refused for a release key.

### 7.4 Corresponding source

- On the image build machine, `scripts/aosp/export-source.sh --offer source-offer.json --out <dir>` (planned, no task yet) writes one archive per listed project at its pinned revision, `pinned.xml`, the kernel source with its build configuration, `Guest/` at the image tag, and `SHA256SUMS`. It is uploaded with the zip to private release storage.
- The `beta` action of `image-release.yml` publishes the source at `https://<updates host>/apkrun/source/<imageVersion>/` before it adds the feed entry, so source and image appear together ([workflow.md](workflow.md) §10). The host is OQ-01.
- The source stays published while the image is in any feed, and for at least 3 years after it leaves the feeds. The `remove` action never deletes it.
- The Alpine test kernel is tooling and is never distributed, so it needs no source offer (§4.4).

---

## 8. Google services and app content

- No Google Mobile Services, Google Play, or other Google apps are in any image or bundle (ADR-0001, [scope.md](../00-product/scope.md) §3). Google Play work is #98 (post-v1) and starts with its own legal investigation.
- No ARM translation layer (houdini, ndk_translation) is added, and no integrity bypass (Play Integrity, SafetyNet) is implemented ([scope.md](../00-product/scope.md) §3).
- Third-party APKs (from the F-Droid corpus or installed by hand) are never committed, attached, uploaded as CI artifacts, or put in bundles. The corpus lives in the runner cache with pinned SHA-256 values ([test-strategy.md](../04-plan/test-strategy.md) §4.1).
- The compatibility database holds package IDs, signer digests, version code ranges, levels, and APKRun's own issue texts. It holds no APK files and no app assets such as icons ([diagnostics.md](../02-design/diagnostics.md) §10.2).
- The only APKs in the repository are APKRun's fixture apps (§5).

---

## 9. Wrappers

| Wrapper | Contains | Rule |
|---|---|---|
| Local | the launcher and metadata | stays on the creator's Mac |
| Portable | also the APK set in `Contents/Resources/bootstrap/` ([wrapper.md](../02-design/wrapper.md) §10) | contains the app. Share it only with the right to redistribute the APK. The GUI and `apkrun wrap --portable` show the portable note below (implemented by #90) |
| Distribution | a portable wrapper signed with Developer ID and notarized ([wrapper.md](../02-design/wrapper.md) §11) | `apkrun wrap --distribution` shows the confirmation below; `--yes` skips it |

Confirmation text (implemented by #89):

```text
This app contains <App name> <version> (<package ID>). You are about to sign it with your
Developer ID so that other people can install it. Continue only if you have the right to
redistribute this app. You are responsible for that, not APKRun. [y/N]
```

Portable note (implemented by #90):

```text
This Mac app contains <App name> <version> (<package ID>) and is <size>. Share it with other
people only if you have the right to redistribute this app.
```

- The launcher has no third-party code. If APKRun's license requires its notice with binary copies, wrappers carry `Contents/Resources/LICENSE` (the ADR decides).
- App names and icons in a wrapper belong to the app's owner (§10).

---

## 10. Names and trademarks

- Android, Google Play, and Google are trademarks of Google LLC. Mac and macOS are trademarks of Apple Inc.
- Use the names only to describe what APKRun does ("runs Android apps on macOS"). Nothing may suggest that Google or Apple endorses or makes APKRun.
- No Android robot, Google Play, or Apple logo appears in the app, the website, or the release notes, unless their brand terms are met and the decision is recorded.
- App names and icons that APKRun shows, or a wrapper contains, belong to their owners.

---

## 11. Compliance checklist

Each release meets every item below. The legal review result is tracked in R-10 ([risks.md](../04-plan/risks.md)).

- APKRun's license is chosen in an ADR and named in the notices (§1).
- Every distributed or tooling lock entry, Swift package, Gradle artifact, and crate has an allowed license; every lock entry has committed license files; reference entries have identified licenses. `scripts/check-licenses.sh` passes (§4, §5, §6.1).
- `ThirdPartyNotices.html` ships in APKRun.app with every `ships: app` and `derived` component, including the virglrenderer, libepoxy, and ANGLE notices. The Help menu opens it (§6).
- Reference entries are excluded from the notices; any RiftVM-derived file carries the notice and marker with the pinned commit (§3.1).
- The custom image shows its notices in Settings → About → Legal information, including the agents (§7.1).
- The image build has no module without license metadata, and each `proprietary` or `by_exception_only` module has a recorded decision (§7.2).
- Release bundles carry `legal/notice.html` with the source offers, and the source is published for every release image (§7.3, §7.4).
- No `stock` image, and no bundle made from one, is published (§2). No Google apps or services are in the image (§8).
- The distribution wrapper confirmation text matches §9. Test C10-8 passes ([test-strategy.md](../04-plan/test-strategy.md) §8.7).

A new component gets its license entry in the same pull request and passes `scripts/check-licenses.sh` (§4.6).
