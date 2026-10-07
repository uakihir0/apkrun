# Legal and Licensing

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [build-system.md](build-system.md), [coding-conventions.md](coding-conventions.md), [workflow.md](workflow.md), [../04-plan/risks.md](../04-plan/risks.md), [../04-plan/issues/M12-v1-release.md](../04-plan/issues/M12-v1-release.md), [../02-design/android-image.md](../02-design/android-image.md), [../02-design/wrapper.md](../02-design/wrapper.md), [../01-architecture/decisions/0001-real-android-in-vm.md](../01-architecture/decisions/0001-real-android-in-vm.md) |
| Tasks | #093 (compliance, every section); #018 (RiftVM analysis, §3); #020 (third-party builds, §4–§6); #035 (image notices, §7); #087 (image release, §2, §7.4); #088 (distribution wrappers, §9) |

This guide has the engineering rules for licenses: what APKRun may use, ship, and publish, how notices are produced, and what a release must carry. It is not legal advice. The #093 legal review confirms these rules before v1.0 and records the result in R-10 ([../04-plan/risks.md](../04-plan/risks.md)). Every SPDX value in this guide is a working value that #093 checks against the license files.

---

## 1. APKRun's own license

### 1.1 Status

- The project license is not chosen yet. It is decision OQ-40 ([../04-plan/open-questions.md](../04-plan/open-questions.md)): decided in an ADR before #089 gives the launcher binary to other people, and at the latest before the v0.4 public demo ([../04-plan/roadmap.md](../04-plan/roadmap.md) §3.4, [../../README.md](../../README.md), License).
- Until the ADR is accepted, source files carry no license header, and nothing from outside the project is added except under §3 and §4.
- #093 checks that the ADR exists and that the notices of §6 and §7 name the chosen license.

### 1.2 Requirements for the choice

| Requirement | Why |
|---|---|
| Anyone may redistribute the launcher binary inside a wrapper, without publishing their own code or the wrapped app | portable and distribution wrappers contain `APKRunLauncher` ([../02-design/wrapper.md](../02-design/wrapper.md) §10, §11) |
| Compatible with every license on the app list of §4.2 | those components are linked or embedded into APKRun.app |
| Usable next to GPL code in the image, as a separate program | the agents and `apkrun_vsockd` run in an image that also contains the GPL kernel (§7) |
| Says how contributions are licensed | contributors include AI agents and people; the default is "contributions are under the project license" |

The ADR also decides the header format. The proposal is one line `SPDX-License-Identifier: <id>` at the top of each source file, in the comment style of the language ([coding-conventions.md](coding-conventions.md)). Derived files keep their own header (§3.1).

---

## 2. Prebuilt Cuttlefish image

The `kind: stock` image comes from a ci.android.com build ([../02-design/android-image.md](../02-design/android-image.md) §2). It is for development only (M1–M4, [android-image.md](../02-design/android-image.md) §2.3).

| Allowed | Never |
|---|---|
| fetch it with `apkrun_image fetch` into `Images/work/<buildId>/` (git-ignored) | commit it, or any file extracted from it (`boot.img`, `super.img`, `os.img`, ramdisks, kernels) |
| build and install `stock` bundles on your own Mac, lab Macs, the reference host, and the private runner caches | attach it or a bundle made from it to an issue, a pull request, a GitHub release, or a CI artifact (artifacts of a public repository are public) |
| run the AndroidStock suite on it ([../04-plan/test-strategy.md](../04-plan/test-strategy.md)) | upload it to the updates host or put it in an image feed |
| commit text metadata about it: `Images/manifests/<buildId>/` (inventory, `android-image.json`) and `Images/reference/<buildId>/` captures | give it to another person, as a file, a bundle, or a disk image |

- The release image key never signs a `stock` bundle. `apkrun_image bundle` refuses to write, and the release workflow refuses to publish, a bundle with `kind: stock` signed with a release key ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.3).
- Clients never get feed updates while they run a `stock` image (C7, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.2).
- Every published image is `kind: apkrun`, built by us from AOSP source (#035, [android-image.md](../02-design/android-image.md) §11), so that we control its notices and source offer (§7).

---

## 3. Derived code and patches

### 3.1 RiftVM

RiftVM's repository source is MIT-licensed and is reviewed as a technical reference for the graphics path ([../02-design/graphics.md](../02-design/graphics.md) §2). #018 copies no RiftVM code, and the RiftVM package is never a build dependency or distributed component.

| Rule | Detail |
|---|---|
| Lock entry | `riftvm`: `kind: source`, `ships: reference`, commit `51f19193b1d3326b2e164d37a2a59e9970375170` (`riftvm-v0.6.1`), `license: MIT`, `licenseFiles: ["LICENSE"]` ([build-system.md](build-system.md) §6.5; IR-188) |
| Analysis first | #018 records in `docs/02-design/riftvm-analysis.md`, per file, its license header and whether we copy, adapt, or rewrite it ([graphics.md](../02-design/graphics.md) §2.2) |
| Copied or adapted file | keeps RiftVM's copyright and MIT permission notice at the top, then the line `Derived from RiftVM <commit> (MIT)` with the full pinned commit, in `//` comments ([coding-conventions.md](coding-conventions.md)) |
| Rewritten file | written from our own understanding without copying code; no RiftVM notice. If in doubt, treat it as adapted |
| File with another license | a RiftVM file whose header is not MIT is not copied. It is either rewritten, or its origin becomes its own lock entry under §4 |
| Notices | reference-only RiftVM source is excluded from `ThirdPartyNotices.html`; if APKRun later copies or adapts RiftVM code, change the lock entry to `ships: derived` and include its MIT text and marked file list (§6.2) |
| Check | `scripts/check-licenses.sh` fails when a file with the marker names a commit other than the pin, or when the MIT notice above it is missing |

### 3.2 Patches

- Patches in `ThirdParty/patches/<name>/` are under the license of the component they change ([build-system.md](build-system.md) §6.2).
- The patch header keeps the author, the reason, and whether it was sent upstream.
- A patch carried from RiftVM or from the Homebrew taps it used ([graphics.md](../02-design/graphics.md) §5) keeps the original `From:` author and adds the line `Carried from <source> <commit>`.
- A patch we send upstream is offered under the upstream project's license and contribution rules.

### 3.3 Vendored files

- `Images/tools/vendor/` holds `avbtool.py` (from `platform/external/avb`)
  and `mkbootimg.py`, `unpack_bootimg.py`, and the imported GKI certificate
  helper (from `platform/system/tools/mkbootimg`) unchanged
  ([build-system.md](build-system.md) §6.4). Each keeps its upstream license
  header, and the upstream license file is recorded in
  `ThirdParty/ThirdParty.lock.json`.
- The apksig test vectors keep the upstream `NOTICE` and license file in their resource directory.
- A vendored file is never edited ([build-system.md](build-system.md) §6.4), so its license never changes.

---

## 4. License policy

### 4.1 Where a component ends up

The `ships` value of the lock entry ([build-system.md](build-system.md) §6.1) decides which list applies:

| `ships` | Meaning | List |
|---|---|---|
| `app`, `derived` | linked, embedded, or copied into APKRun.app, the CLI, the launcher, or our source | app list (§4.2) |
| `image`, added by us | the agents, `apkrun_vsockd`, and what they contain | app list (§4.2) |
| `image`, from AOSP | everything the AOSP build installs, including the kernel | image rules (§4.3) |
| `reference` | pinned source consulted only for analysis; not built, copied, linked, or distributed | no redistribution list; license identity and source license files remain recorded for review |
| `tooling`, committed (`kind: vendored`, `gradle` for fixture apps) | files in the repository: vendored scripts, test vectors, fixture APKs, recorded streams | app list (§4.2) |
| `tooling`, downloaded (`kind: prebuilt`, `source`) | build and test inputs that are fetched, never committed, never published | tooling list (§4.4) |

A component that ships in more than one place has a list as its `ships` value (for example `["app", "image"]`). The strictest list applies.

### 4.2 App list

`scripts/check-licenses.sh` reads the lists from the code blocks of this section, the same way `check-module-deps.sh` reads [../01-architecture/modules.md](../01-architecture/modules.md) §3. A change to a list is a pull request that a maintainer approves.

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

- AOSP components are not individual lock entries. `Guest/product/manifest/pinned.xml` pins them, and their license data comes from the AOSP build (§7.2).
- The image may contain what AOSP ships, with its notices, including GPL and LGPL components (the kernel, some system tools), provided the corresponding source is published (§7.4).
- A module with no license metadata stops the image release. So does a module whose license has the AOSP condition `proprietary` or `by_exception_only`, until a maintainer decides in the image release issue (remove it, or record why it may ship).
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

The tooling list is allowed only for `ships: tooling` entries with `kind: prebuilt` or `kind: source`. These are downloaded by a script, pinned by hash or commit, and never committed, uploaded as a CI artifact, or published. The Alpine test guest is the main case ([../02-design/vm.md](../02-design/vm.md) §12). `ships: reference` entries are also pinned source inputs, but are neither build/test inputs nor redistributed; their licenses are recorded without applying a redistribution allow-list.

### 4.5 Expressions and unknown licenses

| Value | Rule |
|---|---|
| `A OR B` | passes if at least one side is allowed. For components included in a notice output, include every license file upstream ships |
| `A AND B` | passes if every part is allowed |
| `A WITH E` | passes only if the whole `A WITH E` is on the list |
| empty, missing, `NOASSERTION`, `LicenseRef-*` | fails |
| anything not on the list for a distributed or build/test tooling component | fails, for example AGPL, SSPL, BUSL, and non-commercial licenses |

The expression checks apply to components that APKRun distributes or uses as
build/test tooling. A `ships: reference` entry must still have an identified
license and a committed copy of the pinned source license, but it is not
evaluated against a redistribution allow-list.

### 4.6 A new or changed component

1. Runtime impact needs an ADR first ([../../AGENTS.md](../../AGENTS.md), [../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)).
2. The pull request adds the lock entry with `license`, `licenseFiles`, and `ships`, and the license file copies of §6.1 ([build-system.md](build-system.md) §6.8).
3. `scripts/check-licenses.sh` passes in the same pull request. After #093, this is required for every new component (M12 #093, Notes).
4. A pin update re-reads the upstream license files. If the license changed, the pull request updates `license` and says so in its description.
5. A component that APKRun distributes or uses as build/test tooling whose license is not allowed is replaced or removed. A reference-only source is not subject to this redistribution rule. Replacement needs an ADR and its own task (#093, Out of scope).

---

## 5. Component inventory

`ThirdParty/ThirdParty.lock.json` is the inventory ([build-system.md](build-system.md) §6.1). For `swiftpm`, `gradle`, and `cargo` entries, `name` is the identity the lock file uses: the package identity for SwiftPM, `group:artifact` for Gradle, the crate name for Cargo. One Gradle entry may cover a whole Maven group as `group:*` when every artifact in it has the same license (AndroidX, Compose).

| Component | Ships | License | Notes |
|---|---|---|---|
| virglrenderer | app | MIT | `Contents/Frameworks/VirGLRuntime/` |
| libepoxy | app | MIT | same |
| ANGLE | app | BSD-3-Clause | `angle-astc-encoder`, `angle-vulkan-headers`, and `angle-zlib` are separate pinned app entries; the native build checks their `gnTargetPrefixes` against `gn desc` for both Metal targets |
| aapt2 | app | Apache-2.0 | plus the notices of the libraries it links statically, as shipped with the Maven artifact |
| Sparkle 2 | app | MIT | plus the external licenses its `LICENSE` lists (ADR-0016) |
| swift-protobuf | app | Apache-2.0 WITH Swift-exception | GuestProtocol |
| swift-argument-parser | app | Apache-2.0 WITH Swift-exception | CLI |
| ZIPFoundation | app | MIT | APKStoreCore and UpdateCore, reading only (ADR-0017) |
| Kotlin stdlib, `org.jetbrains:annotations` | app, image | Apache-2.0 | inside the Guest Agent APK: `Resources/guest/` and the image |
| kotlinx-coroutines | app, image | Apache-2.0 | same |
| protobuf-javalite | app, image | BSD-3-Clause | same |
| RiftVM | reference | MIT | source-only analysis input; excluded from app notices unless later copied or adapted (§3.1) |
| `libc`, `log`, `android_logger`, and their `Cargo.lock` dependencies | image | MIT OR Apache-2.0 | `apkrun_vsockd`; the product build uses AOSP `external/rust/crates`, which carry their own AOSP metadata |
| AOSP, including the prebuilt kernel | image | many; kernel GPL-2.0-only | not lock entries (§4.3); notices and source offer in §7 |
| `avbtool.py` | tooling, committed | MIT | vendored (§3.3). `platform/external/avb` is MIT; #093 confirms the header of the pinned copy |
| `mkbootimg.py`, `unpack_bootimg.py` | tooling, committed | Apache-2.0 | vendored (§3.3) |
| apksig test vectors | tooling, committed | Apache-2.0 | §3.3 |
| AndroidX, Compose, Kotlin in the fixture apps | tooling, committed | Apache-2.0 | inside the committed APKs of `Tests/Fixtures/apks/`; locked in `Tests/Fixtures/AndroidApps/<module>/gradle.lockfile` |
| Mesa (virgl driver), `kmscube` | tooling | MIT | Alpine packages in the test initramfs; the recorded `kmscube` stream in `Tests/Fixtures/graphics/` is committed |
| Alpine `linux-virt` kernel | tooling, downloaded | GPL-2.0-only | never committed or published (§4.4) |
| Alpine minirootfs and Linux test packages (`socat`, `ssl_client`, `libcrypto3`, `libgpiod`, `libssl3`, `readline`, `libncursesw`, `ncurses-terminfo-base`) | tooling, downloaded | package component licenses, checked against Alpine metadata and upstream notices; the `socat` lock proposes GPL-2.0-only as a conservative policy basis, not its full Alpine expression `GPL-2.0-only WITH OpenSSL-Exception`; `COPYING` and `COPYING.OpenSSL` are retained, while the separate exception statement is in the upstream README (IR-241); `ssl_client` GPL-2.0-only; `libcrypto3` and `libssl3` Apache-2.0; `libgpiod` GPL-2.0-or-later AND LGPL-2.1-or-later; `readline` GPL-3.0-or-later; ncurses packages X11 | same |
| Alpine e2fsprogs packages (`e2fsprogs`, `e2fsprogs-libs`, `libcom-err`, `libblkid`, `libuuid`, `libeconf`) | tooling, downloaded | component-specific GPL, LGPL, BSD, and MIT terms recorded in `ThirdParty/ThirdParty.lock.json` | The e2fsprogs entries select `LGPL-2.1-only` under the upstream LGPL-2-or-later grant; this interpretation needs maintainer review (IR-195) |
| depot_tools | tooling, downloaded | BSD-3-Clause | ANGLE build only |

- Tools that only run (Xcode, protoc, buf, XcodeGen, ruff, ktfmt, bundletool, the Android SDK build tools) are not lock entries and are never committed or redistributed. Each developer accepts their terms when installing them ([environment-setup.md](environment-setup.md)).
- Generated code (the protobuf Swift and Kotlin classes) is APKRun code. The runtime parts it needs are the swift-protobuf and protobuf-javalite entries.

---

## 6. ThirdPartyNotices

### 6.1 License files

- `licenseFiles` lists paths inside the upstream source (for example `COPYING`, `LICENSE`, `NOTICE`).
- A copy of each is committed as `ThirdParty/licenses/<name>/<file>`. `scripts/release/generate-notices.py --refresh <name>` fetches the pinned source and refreshes the copies. For Gradle and Cargo packages whose artifact has no license file, the copy comes from the upstream repository at the pinned version.
- The `third-party` CI job runs `generate-notices.py --check`. For #020, it verifies that every shipped app notice has a committed license copy and compares `kind: source` app/derived copies byte-for-byte with their pinned source checkout. The full check of reference sources and resolved Swift, Gradle, and Cargo packages remains part of #093.

### 6.2 Generation

`scripts/release/generate-notices.py` runs as a build phase of the `APKRun` target in every configuration ([build-system.md](build-system.md) §11). It reads only committed files, so it works offline:

| Input | Used for |
|---|---|
| `ThirdParty/ThirdParty.lock.json` | the components, licenses, and repositories |
| `Package.resolved`, the Xcode package pins, `Guest/<module>/gradle.lockfile`, `Guest/vsockd/Cargo.lock` | the exact versions |
| `ThirdParty/licenses/` | the license texts |

The output `Contents/Resources/ThirdPartyNotices.html`:

- starts with APKRun's own copyright and license (§1), or identifies OQ-40 while the project license is undecided;
- has one section per entry with `ships` containing `app` or `derived`, sorted by name: name, version, repository, SPDX expression, the copyright lines found in the license files, and each license text in a `<pre>` block;
- for `derived` entries, also lists the files that carry the marker (§3.1);
- is deterministic: the same inputs give the same bytes (no dates, sorted keys);
- is one self-contained file: UTF-8, escaped text, inline CSS, no scripts, no remote resources.

The Guest Agent APK in `Resources/guest/` is covered by the Kotlin entries. The launcher has no third-party code ([wrapper.md](../02-design/wrapper.md) §11), so a wrapper needs only APKRun's own license notice (§9).

### 6.3 Checks

| Check | Where |
|---|---|
| every distributed/tooling entry has an allowed license; every lock entry has a committed license file copy; reference entries preserve an identified license; every resolved package has an entry; RiftVM markers name the pin | `scripts/check-licenses.sh` in the `lint` job ([build-system.md](build-system.md) §3); T0 tests with a sample lock that has one missing license, and the real lock ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §6.13) |
| the generator's output for a sample lock equals a golden file | T0 script test in the `lint` job |
| the Release build contains the notices with every `ships: app` and `derived` entry | `scripts/release/check-release-build.sh` (T1, [build-system.md](build-system.md) §3.1) |
| the notices are visible in APKRun.app and in the image | C10-8 ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.7) |

### 6.4 Where users see them

- APKRun.app's Help menu has the item **Third-Party Notices**. It opens `ThirdPartyNotices.html` with `NSWorkspace` in the default browser.
- The image notices are in Android (§7.1).

---

## 7. Image notices and source offers

### 7.1 Notices in Android

- The product build keeps AOSP's notice generation. Android shows the notices in Settings → About → Legal information.
- Everything we add declares its license metadata, so it appears there:
  - `Guest/product/Android.bp` has a `license` module with APKRun's license and uses it as the default for the product's modules;
  - the agent APK imports also name a second `license` module with the Kotlin stdlib, kotlinx-coroutines, and protobuf-javalite texts. `build-product.sh` copies these texts from `ThirdParty/licenses/` to `Guest/product/prebuilt/licenses/` (git-ignored) in the same step that copies the APKs ([build-system.md](build-system.md) §9), because Soong cannot read paths outside the product directory;
  - `Guest/vsockd/Android.bp` names APKRun's license; the crates keep their AOSP metadata.

### 7.2 License data of the image build

After `m dist`, `scripts/aosp/build-product.sh` reads the license metadata of the installed modules (from the AOSP build's SBOM or notice data; #093 fixes the exact command) and:

- fails if an installed module has no license metadata;
- lists modules with the condition `proprietary` or `by_exception_only` for the decision of §4.3;
- writes `source-offer.json` next to `build-info.json`: for each module with a GPL, LGPL, or MPL license, the module, its license, its project path, and its revision from `pinned.xml`. The kernel entry names the kernel source revision recorded with the prebuilt kernel.

The release manager uploads `source-offer.json` together with the image zip (image release step 3, [workflow.md](workflow.md) §10.3).

### 7.3 The notice file in the bundle

`python3 -m apkrun_image bundle` writes `legal/notice.html` into release bundles, names it in the manifest `legal.notice`, and lists it in `files`, so the signature covers it ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.2). It contains:

- the image version and the provenance values: `pinnedManifestSHA256`, `revisions.guest`, `builderImageDigest` ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md));
- a note that the full notices are in Android (§7.1), and APKRun's own license;
- the source offer: for each entry of `source-offer.json`, the component, its license, the project path and revision, and the URL where the source is published (§7.4).

A bundle without `source-offer.json` input is refused for a release key.

### 7.4 Corresponding source

- On the image build machine, `scripts/aosp/export-source.sh --offer source-offer.json --out <dir>` writes one archive per listed project at its pinned revision, `pinned.xml`, the kernel source with its build configuration, `Guest/` at the image tag, and `SHA256SUMS`. It is uploaded to the private release storage with the zip.
- The `beta` action of `image-release.yml` publishes it at `https://<updates host>/apkrun/source/<imageVersion>/` before it adds the feed entry, so the source is available from the same place and at the same time as the image (image release step 6, [workflow.md](workflow.md) §10.3). The host is OQ-01.
- The source stays published while the image is in any feed and for at least 3 years after it leaves the feeds. The `remove` action never deletes it.
- The Alpine test kernel is tooling and never distributed, so it needs no source offer (§4.4).

---

## 8. Google services and app content

- No Google Mobile Services, Google Play, or other Google apps are in any image or bundle (ADR-0001, [../00-product/scope.md](../00-product/scope.md) §3). Any Google Play work is #097 (post-v1), which starts with its own legal investigation.
- No ARM translation layer (houdini, ndk_translation) is added ([scope.md](../00-product/scope.md) §3).
- An integrity bypass (Play Integrity, SafetyNet) is never implemented ([scope.md](../00-product/scope.md) §3).
- Third-party APKs, from the F-Droid corpus or installed by hand, are never committed, attached to issues or pull requests, uploaded as CI artifacts, or put into bundles. The corpus lives in the runner cache with pinned SHA-256 values ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.1).
- The compatibility database holds package IDs, signer digests, version code ranges, levels, and our own issue texts, no APK files or app assets such as icons ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10.2).
- The only APKs in the repository are our fixture apps (§5).

---

## 9. Wrappers

| Wrapper | Contains | Rule |
|---|---|---|
| Local | the launcher and metadata | stays on the creator's Mac |
| Portable | also the APK set in `Contents/Resources/bootstrap/` ([wrapper.md](../02-design/wrapper.md) §10) | contains the app. The creator may share it only if they have the right to redistribute the APK. The GUI and `apkrun wrap --portable` show the portable note below (#089) |
| Distribution | a portable wrapper signed with Developer ID and notarized ([wrapper.md](../02-design/wrapper.md) §11) | `apkrun wrap --distribution` asks for the confirmation below; `--yes` skips it |

Confirmation text (#088 implements it, #093 reviews it):

```text
This app contains <App name> <version> (<package ID>). You are about to sign it with your
Developer ID so that other people can install it. Continue only if you have the right to
redistribute this app. You are responsible for that, not APKRun. [y/N]
```

Portable note (#089 implements it, #093 reviews it):

```text
This Mac app contains <App name> <version> (<package ID>) and is <size>. Share it with other
people only if you have the right to redistribute this app.
```

- The launcher has no third-party code. If APKRun's license requires its notice with binary copies, wrappers carry `Contents/Resources/LICENSE` with it (§1; the ADR decides).
- App names and icons in a wrapper belong to the app's owner (§10).

---

## 10. Names and trademarks

- Android, Google Play, and Google are trademarks of Google LLC. Mac and macOS are trademarks of Apple Inc.
- Use them only to describe what APKRun does ("runs Android apps on macOS"). Nothing may suggest that Google or Apple endorse or make APKRun.
- No Android robot, Google Play, or Apple logos in the app, the website, or the release notes, unless their brand terms are met and a maintainer approves.
- App names and icons shown by APKRun or in wrappers come from the apps and belong to their owners.

---

## 11. Compliance checklist (#093)

A maintainer copies this list into #093, ticks each line with evidence, and records the result in R-10.

- [ ] APKRun's license is chosen in an ADR and named in the notices (§1).
- [ ] Every distributed/tooling lock entry, Swift package, Gradle artifact, and crate has an allowed license; every lock entry has committed license files, and reference entries have identified licenses. `scripts/check-licenses.sh` passes (§4, §5, §6.1).
- [ ] `ThirdPartyNotices.html` ships in APKRun.app with every `ships: app` and `derived` component, including the virglrenderer, libepoxy, and ANGLE notices. The Help menu opens it (§6).
- [ ] Reference-only entries are excluded from `ThirdPartyNotices.html`; if RiftVM-derived files exist, they carry the notice and marker with the pinned commit (§3.1).
- [ ] The custom image shows its notices in Settings → About → Legal information, including the agents (§7.1).
- [ ] The image build has no module without license metadata, and every `proprietary` or `by_exception_only` module has a recorded decision (§7.2).
- [ ] Release bundles carry `legal/notice.html` with the source offers. The corresponding source is published for every release image (§7.3, §7.4).
- [ ] No `stock` image or bundle made from one was published (§2).
- [ ] No Google apps or services are in the image (§8).
- [ ] The distribution wrapper confirmation text is reviewed (§9).
- [ ] C10-8 passes ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.7).
- [ ] R-10 has its result in [../04-plan/risks.md](../04-plan/risks.md).

After #093, a new component gets its license entry in the same pull request and passes `scripts/check-licenses.sh` (§4.6).
