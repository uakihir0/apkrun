# 0012. Module set and dependency rules

- Status: Accepted
- Date: 2026-09-28
- Related: [../modules.md](../modules.md), #062

## Context

The first module sketch listed the modules VirtualMachineCore, GraphicsCore, RuntimeCore, APKStoreCore, UpdateCore, WrapperCore, and IntegrationCore. Implementation needs more precise boundaries: the custom virtio plumbing, XPC contract, composition root, guest protocol, image handling, input model, windowing, and diagnostics.

## Decision

Adopt the module set and dependency graph in [../modules.md](../modules.md):

- Original modules: VirtualMachineCore, GraphicsCore, RuntimeCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore.
- Additions: DiagnosticsCore, VirtioDeviceCore, InputCore, WindowingCore, GuestProtocol, ImageCore, RuntimeAPI, RuntimeClient, RuntimeHost.

CI enforces the graph (#062).

## Alternatives considered

- **Fewer, larger modules:** faster to start, but they blur ownership. AGENTS §4 explicitly requires clear ownership.
- **One module per feature:** too granular for the team size.

## Consequences

- There are more targets in `Package.swift`, but compile-time boundaries make ownership mechanical.
- APKRun.app depends only on RuntimeClient (fixes the edge `APKRun.app → RuntimeCore`).
