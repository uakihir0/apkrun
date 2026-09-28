# 0016. Sparkle 2 for APKRun updates, coordinated with apkrund

- Status: Accepted
- Date: 2026-09-28
- Related: #057, #087, R-23, R-24, ADR-0007, ADR-0011, [../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md), [../security-model.md](../security-model.md) §7

## Context

APKRun is distributed outside the Mac App Store as a Developer ID signed, notarized app. It needs signed, verified updates for itself (FR-OPS-03, #057). An APKRun update is special in three ways:

- The bundle contains more than an app. apkrund runs from `Contents/Helpers/` as a LaunchAgent (ADR-0007) and owns the Android VM and its GPU renderer. APKRunMenuBar and the CLI run from the bundle too, and wrappers depend on apkrund's API.
- A plain "replace the bundle and relaunch" leaves apkrund running old code over new resources, or kills it in the middle of Android I/O.
- Updates must never touch installed Android apps, their data, or wrapper bundles (#057: "Updater must not modify Android application package metadata").

The Android guest image is a separate update system with its own feed and signing (ADR-0011, [../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4). This ADR covers the APKRun bundle only.

## Decision

1. **Sparkle 2** (MIT, SwiftPM, exact version pin) updates the APKRun.app bundle. Only APKRun.app links it. It uses EdDSA-signed archives (`SUPublicEDKey`), a signed appcast, phased rollouts for stable releases, a beta channel through `sparkle:channel`, deltas for the last three releases, and Sparkle's standard user interface.
2. **The whole bundle is the update unit.** apkrund, the menu bar, the CLI, the launcher template, and VirGLRuntime are never updated separately (one bundle, one build).
3. **Sparkle's relaunch is postponed** (`shouldPostponeRelaunchForUpdate`) until apkrund has prepared. apkrund blocks new work, ends sessions with `ended(.runtimeUpdating)`, stops Android, writes a marker (`Runtime/maintenance.json`), and exits. Only then does Sparkle replace the bundle.
4. **A frozen maintenance endpoint** (`.maintenance`, additive-only protocol) lets any APKRun.app build coordinate with any apkrund build, across RuntimeAPI majors.
5. **apkrund detects a replaced bundle** (`BundleWatcher`: an Info.plist build that differs from its own). It then finishes the update when no app is open (`restartPending`). This covers install on quit, DMG copies, Homebrew, and MDM.
6. **apkrund has a background probe** that checks the appcast and only notifies. Installs always go through Sparkle in APKRun.app, so nothing outside Sparkle installs code.
7. **Re-registration of the LaunchAgent** happens only when the embedded plist changed or the agent isn't enabled. It is keyed on the plist's SHA-256, not on every build.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Our own updater (download, verify with CryptoKit, swap the bundle) | Re-implements what Sparkle does, including the hard parts: atomic replacement, an installer that survives the app quitting, authorization prompts, deltas, and phased rollout. It is more code to secure, with no gain |
| Mac App Store | The VM needs entitlements and a LaunchAgent that don't fit App Store rules ([../security-model.md](../security-model.md)) |
| Homebrew cask as the only update channel | Most users don't have Homebrew. It is still supported, because a cask upgrade is just an external replacement (Decision 5) |
| apkrund installs updates itself | apkrund would replace the bundle it runs from and would need its own UI for consent. Sparkle's installer already handles the running app, and the user's consent belongs in APKRun.app |
| Separate update packages per component | Allows mixed versions that the compatibility contract forbids ([../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §2.2), and multiplies the test matrix |
| Let Sparkle relaunch without coordination and have apkrund notice later | Android I/O could be cut off by the re-registration, and apkrund would briefly run old code over new resources |

## Consequences

- APKRun takes a third-party runtime dependency in APKRun.app. It is pinned, is listed in [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md), and its nested helpers are signed in the build ([../../05-development/build-system.md](../../05-development/build-system.md)).
- The Sparkle EdDSA key becomes a release secret with the rotation rules of [../security-model.md](../security-model.md) §7. It is never rotated together with the Developer ID (release rule R6).
- An APKRun update closes open Android apps. The dialog says so, and wrappers reopen by themselves after the update (screen U).
- There is no automatic rollback of APKRun. A bad release is fixed by a newer release, or by installing an older one by hand. Data survives because schema migrations keep backups.
- The `.maintenance` protocol can never be changed incompatibly.

## Verification

- #057 step 1 checks the pinned Sparkle version: the Info.plist keys `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed`, the delegate methods used, the behavior of a postponed update when the app quits, and the signed appcast format. Differences are recorded here and in R-23.
- The #057 T2 test "APKRun N → N+1" ([../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §14) must pass. It checks that `Packages/`, the wrapper bundles, and app data are unchanged, and that the new apkrund runs. Its variant (d) and the unchanged-plist case settle R-24 (launchd picks up the new binary without re-registration).
