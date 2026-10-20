# 0007. apkrund as a per-user LaunchAgent with an XPC API

- Status: Accepted
- Date: 2026-09-28
- Related: #32, #33, #67, [../process-model-and-ipc.md](../process-model-and-ipc.md)

## Context

The VM must outlive any single app window, be shared by all wrappers, and not depend on APKRun.app running. It must run in the user's session (the VZ entitlement, per-user data, TCC for the microphone).

## Decision

apkrund is a **per-user LaunchAgent** embedded in APKRun.app. It is registered with `SMAppService.agent(plistName:)` using `BundleProgram`, is on-demand via its `MachServices` entry, and is restarted on crash. Clients talk to it over **NSXPC** with a broker + anonymous-endpoint scheme protected by code-signing requirements.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| The VM inside APKRun.app | Quitting the GUI would kill all apps. Wrappers would depend on the GUI being open |
| LaunchDaemon (root) | Not needed, a larger attack surface, VZ user-session concerns |
| Custom sockets / gRPC on localhost | No built-in peer code-signing verification. More code |

## Consequences

- There is a registration step at first launch. The user may need to approve it in System Settings → General → Login Items & Extensions.
- Sparkle doesn't manage agents. At the first launch after an APKRun update, APKRun.app re-registers the agent when its status is not `.enabled` or the embedded agent plist changed ([../process-model-and-ipc.md](../process-model-and-ipc.md) §1.1, [../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.7).
- The CLI and the development embedded mode share the `RuntimeService` protocol.

## Verification

G6 (runtime remains warm under apkrund), checked in stages: #32 (the VM in apkrund, quitting APKRun.app, crash restart), #33 (warm launch, and a client with another signing identity is rejected), and #69 (the full check with an app window). The #32 and #33 acceptance criteria also apply.
