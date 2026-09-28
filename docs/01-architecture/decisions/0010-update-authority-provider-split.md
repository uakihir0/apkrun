# 0010. Separate update authority from update provider

- Status: Accepted
- Date: 2026-09-28
- Related: #037–#040, #050–#052, #074, [../../02-design/update-system.md](../../02-design/update-system.md)

## Context

A package may be updatable from several sources (a local file, a direct URL, F-Droid, GitHub, maybe Google Play inside Android). If two systems update the same package automatically, they fight (downgrades, signature conflicts, surprise changes).

## Decision

- **UpdateAuthority** (`apkrun`, `googlePlay`, `external`, `manual`): *who* may update the package automatically. Exactly one per package.
- **UpdateProvider** (`local`, `direct`, `fdroid`, `github`): *where* APKRun gets candidates when the authority is `apkrun`.
- When the authority is `apkrun` or `manual`, the Store Agent requests Android update ownership at first install (`setRequestUpdateOwnership(true)`, API 34+), so other installers cannot update silently. A move to `googlePlay` or `external` gives it up first (`RelinquishUpdateOwnership`).
- The authority changes only by an explicit user action: the update choice, **Updated by**, `apkrun update authority`, or adopting a package. A move to another installer asks for confirmation.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Provider implies authority | Can't express "another installer updates this; APKRun keeps out" or "APKRun installs only the files the user picks, and keeps the provider for later" |
| Let multiple updaters coexist | Race conditions, inconsistent versions |

## Consequences

- The metadata stores both fields. The UI explains the difference.
- `notifyOnly` is a mode of the `apkrun` authority. APKRun keeps update ownership and tells the user about a new version instead of installing it.

## Verification

G7 (APK v1 → v2 automatic update with the local provider, #037–#040), plus rollback in #043.
