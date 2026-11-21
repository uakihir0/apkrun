# 0019. Apache License 2.0 for APKRun

- Status: Accepted
- Date: 2026-11-20
- Related: #90, OQ-40 ([../../04-plan/open-questions.md](../../04-plan/open-questions.md)), [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §1

## Context

OQ-40 asks which license covers APKRun's own code, including `APKRunLauncher`, which portable and distribution wrappers carry to other Macs ([wrapper.md](../../02-design/wrapper.md) §10, §11). The requirements in [legal-and-licensing.md](../../05-development/legal-and-licensing.md) §1.2:

| Requirement | Why |
|---|---|
| Anyone may redistribute the launcher binary inside a wrapper, without publishing their code or the wrapped app | portable and distribution wrappers contain `APKRunLauncher` |
| Compatible with every license of the app list ([legal-and-licensing.md](../../05-development/legal-and-licensing.md) §4.2) | those components are linked or embedded in APKRun.app |
| Usable next to GPL code in the image, as a separate program | the agents and `apkrun_vsockd` run in an image that holds the GPL kernel |
| States how contributions are licensed | the default is "contributions are under the project license" |

## Decision

APKRun is licensed under the **Apache License, Version 2.0** (`Apache-2.0`). The `LICENSE` file at the repository root holds the full text.

- Contributions are licensed under the same license (Apache-2.0 section 5); CONTRIBUTING and the pull-request template say so.
- Source files carry one line, `SPDX-License-Identifier: Apache-2.0`, in the file's comment style. Derived files keep their own header ([legal-and-licensing.md](../../05-development/legal-and-licensing.md) §3.1).
- The notices of [legal-and-licensing.md](../../05-development/legal-and-licensing.md) §6 and §7 name Apache-2.0 for APKRun's own components.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| MIT | Redistributable and compatible, but silent on patents and on how contributions are licensed; the requirements ask for an explicit contribution rule |
| BSD-3-Clause | Same gap as MIT, plus no express patent grant |
| GPL-3.0 / AGPL-3.0 | A wrapper binary containing `APKRunLauncher` would carry copyleft duties to anyone who redistributes it — publishing source and license texts with every wrapped app — which the first requirement forbids |
| LGPL-2.1 | Binary redistribution still imposes notice and relinking duties that a thin immutable launcher bundle is not built to satisfy |
| Proprietary | Blocks redistribution of the launcher inside wrappers, the core portable/distribution mechanism |

## Consequences

- Anyone may copy, modify, and redistribute APKRun or the `APKRunLauncher` binary inside a wrapper, under Apache-2.0's notice terms; no source publication is required.
- Apache-2.0's express patent grant and section 5 contribution terms cover contributions without a separate CLA.
- The components APKRun links or embeds are permissive (MIT, BSD, Apache-2.0); GPL and LGPL are never linked into APKRun's own executables ([legal-and-licensing.md](../../05-development/legal-and-licensing.md) §4.2), so no linking conflict exists. GPL code in the guest image runs as separate programs, which the license permits.
- Source files gain the SPDX header as they are touched, and in one mechanical pass; `scripts/check-licenses.sh` (#94) enforces it once it exists.
- The portable note and the ThirdPartyNotices template ([legal-and-licensing.md](../../05-development/legal-and-licensing.md) §9, §6) name Apache-2.0.

## Verification

`LICENSE` contains the unmodified Apache-2.0 text; legal-and-licensing.md §1.1 names Apache-2.0 and OQ-40 is marked decided. `scripts/check-licenses.sh` passes when it exists (#94).
