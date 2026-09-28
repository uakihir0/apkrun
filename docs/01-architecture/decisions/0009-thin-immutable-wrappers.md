# 0009. Thin, immutable wrappers

- Status: Accepted
- Date: 2026-09-28
- Related: #044–#049, #055–#056, #075–#076, #089, [../../02-design/wrapper.md](../../02-design/wrapper.md)

## Context

Each Android app is represented by a `.app` bundle on macOS. If wrappers contained the APK or runtime, every update would modify signed bundles (breaking signatures and TCC grants, and invalidating Gatekeeper assessments) and duplicate large files.

## Decision

Wrappers contain only the launcher executable, `wrapper.json` (identity + initial preferences), the icon, and `Info.plist`. **After generation, APKRun never modifies a wrapper.** App updates (type A) change only the package store. Wrapper changes (type D: a new icon or name) happen only on explicit user action ("Refresh wrapper"), which regenerates the bundle.

A **portable wrapper** additionally embeds a bootstrap APK set for first import on a new Mac. It is still never modified after generation.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Fat wrappers (APK inside) | Updates modify signed bundles, duplicate storage, and complicate integrity |
| No wrappers (APKRun.app launches everything) | Loses Dock/Launchpad/Spotlight identity, which is the core UX goal |

## Consequences

- Wrapper identity is stable across app updates (Dock position, notification permissions).
- User settings live in the package store, not in wrapper.json (a deviation from; wrapper.json holds defaults only).
- Wrappers depend on APKRun being installed. The launcher explains this when it isn't.

## Verification

G9 (the wrapper stays unchanged while the APK is updated automatically, #049), using the wrapper integrity test: the SHA-256 of every file in the wrapper is unchanged after the app update.
