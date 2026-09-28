# Architecture Decision Records

An ADR records one significant decision: its context, the decision, the alternatives, and the consequences. ADRs are immutable once `Accepted`. To change a decision, write a new ADR that supersedes the old one and set the old one's status to `Superseded by NNNN`.

## When an ADR is required

- Changing module ownership or the dependency graph ([../modules.md](../modules.md))
- Changing a process boundary, IPC mechanism, or the guest protocol transport
- Choosing or replacing a third-party component with runtime impact (graphics stack, protobuf library, updater)
- Changing a persisted format in an incompatible way (wrapper.json, metadata.json, image manifest)
- Any deviation from [AGENTS.md](../../../AGENTS.md) rules

## Template

```markdown
# NNNN. Title

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD
- Related: tasks, risks, other ADRs

## Context
## Decision
## Alternatives considered
## Consequences
## Verification
```

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-real-android-in-vm.md) | Run real Android in a VM | Accepted |
| [0002](0002-virtualization-framework-macos27.md) | Virtualization.framework on macOS 27+ with custom virtio devices | Accepted |
| [0003](0003-cuttlefish-base-image.md) | AOSP Cuttlefish arm64 as the guest base | Accepted |
| [0004](0004-virgl-first-graphics.md) | VirGL (GLES) first via virglrenderer + ANGLE/Metal | Accepted |
| [0005](0005-multi-display-window-model.md) | One Android display per macOS window | Accepted |
| [0006](0006-wrapper-owned-window-iosurface.md) | Wrapper owns the window, apkrund renders into shared IOSurfaces | Accepted |
| [0007](0007-apkrund-launchagent-xpc.md) | apkrund as a per-user LaunchAgent with an XPC API | Accepted |
| [0008](0008-guest-agents.md) | Two Kotlin guest agents plus a native vsock bridge | Accepted |
| [0009](0009-thin-immutable-wrappers.md) | Thin, immutable wrappers | Accepted |
| [0010](0010-update-authority-provider-split.md) | Separate update authority from update provider | Accepted |
| [0011](0011-runtime-image-bundle.md) | Prebuilt runtime image bundle | Accepted |
| [0012](0012-module-set.md) | Module set and dependency rules | Accepted |
| [0013](0013-input-via-guest-injection.md) | Input via guest-side injection | Accepted |
| [0014](0014-protobuf-guest-protocol.md) | Protobuf guest protocol over host-initiated vsock | Accepted |
| [0015](0015-direct-kernel-boot.md) | Direct kernel boot without a bootloader | Accepted |
| [0016](0016-sparkle-host-updates.md) | Sparkle 2 for APKRun updates, coordinated with apkrund | Accepted |
| [0017](0017-zipfoundation-zip-reading.md) | ZIPFoundation for reading ZIP archives | Accepted |
| [0018](0018-retire-original-planning-notes.md) | Retire original planning notes | Accepted |
