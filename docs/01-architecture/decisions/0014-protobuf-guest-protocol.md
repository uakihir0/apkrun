# 0014. Protobuf guest protocol over host-initiated vsock

- Status: Accepted
- Date: 2026-09-28
- Related: #033–#036, #072, [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md), [../process-model-and-ipc.md](../process-model-and-ipc.md) §3

## Context

The host and guest agents need a versioned, efficient, cross-language (Swift ↔ Kotlin) protocol with streams for control, input, and bulk data. Android sepolicy forbids vsock for app and shell domains (research 2026-09-28).

## Decision

- **Schema:** Protocol Buffers (proto3). Generated with `swift-protobuf` on the host and the Java/Kotlin protobuf lite runtime in the guest.
- **Framing:** a 4-byte big-endian length followed by an `Envelope` (request ID, operation ID, oneof payload). The maximum frame size is 4 MiB.
- **Transport:** the host always connects.
  - Production: guest vsock ports 6100–6111, served by `apkrun_vsockd`, which splices each connection to the agents' abstract Unix sockets.
  - Development: `adb forward` to the same abstract sockets.
- **Versioning:** a `Hello`/`HelloAck` handshake. The major version must match; the minor version negotiates capabilities.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| JSON over sockets | No schema evolution guarantees, larger, slower for input streams |
| gRPC | Needs HTTP/2 stack on both sides. Heavy for app_process mode |
| FlatBuffers / Cap'n Proto | Less mature Kotlin/Swift tooling. Protobuf is good enough |
| Guest-initiated vsock | Would need vsock privileges in the connecting domain anyway, and would differ from the ADB-forward direction |

## Consequences

- There is one `.proto` source of truth in `Packages/GuestProtocol/proto/`, generated for both sides in the build.
- The native bridge is a small extra component that must be in the custom image.

## Verification

#033 codec tests (T0), #072 handshake over ADB forward (T2), #035/#034 over vsock through `apkrun_vsockd` on the custom image (T2).
