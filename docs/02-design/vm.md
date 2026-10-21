# VM (VirtualMachineCore)

VirtualMachineCore turns a validated `VMDefinition` into a running `VZVirtualMachine` and reports its state. This document covers the definition and its validation, the mapping to Virtualization.framework, guest topology, console ports, networking, vsock, the lifecycle, and the test Linux guest.

---

## 1. Responsibilities

VirtualMachineCore handles CPUs, memory, disks, NAT, vsock, console ports, entropy, balloon, sound, and the custom virtio devices that other modules pass in. It knows nothing about Android, APKs, image file names, or disk contents.

Non-goals:

- Choosing which files to boot. ImageCore builds the Android parts of the definition ([android-image.md](android-image.md) §9).
- Implementing virtio devices. VirtioDeviceCore and GraphicsCore provide them. VirtualMachineCore only attaches them.
- Deciding when to pause or stop. The RuntimeCore idle policy does ([runtime-daemon.md](runtime-daemon.md) §5).

## 2. Public API

```swift
public struct VMDefinition: Sendable {
    public var label: String                      // VZVirtualMachineConfiguration.label (macOS 27)
    public var cpuCount: Int
    public var memorySize: UInt64                 // bytes, multiple of 1 MiB
    public var machineIdentifier: Data?           // VZGenericMachineIdentifier.dataRepresentation; nil = create new
    public var boot: BootDefinition
    public var disks: [DiskDefinition]            // attached in array order
    public var networks: [NetworkDefinition]      // NAT NICs in guest order; empty = no NIC
    public var vsockEnabled: Bool
    public var consolePorts: [ConsolePortDefinition]  // attached in array order; index 0 must be the system console
    public var entropy: Bool                      // virtio-rng, default true
    public var memoryBalloon: Bool                // default true (device present, not driven in v1)
    public var sound: SoundDefinition?            // nil = no virtio-snd
    public var customDevices: [any VirtioDeviceModel]  // from VirtioDeviceCore / GraphicsCore
    public var builtInDisplay: BuiltInDisplayDefinition?  // development only: VZ 2D virtio-gpu (§4)
}

public enum BootDefinition: Sendable {
    case linux(kernel: URL, initialRamdisk: URL?, commandLine: String)
}

public struct DiskDefinition: Sendable, Codable, Equatable {
    public var url: URL
    public var readOnly: Bool
    public var caching: DiskCaching               // .automatic (default) | .cached | .uncached
    public var synchronization: DiskSync          // .full (default for rw) | .fsync | .none (tests only)
    public var identifier: String?                // blockDeviceIdentifier (≤ 20 ASCII), visible as /sys/block/vdX/serial
    public var role: String                       // for logs only, e.g. "os", "persistent", "userdata"
}

public enum NetworkDefinition: Sendable, Codable, Equatable {
    case nat(macAddress: String)                  // locally administered, persisted per instance
}

public struct ConsolePortDefinition: Sendable, Codable, Equatable {
    public var role: ConsoleRole                  // .systemConsole | .log(name) | .silent(name) | .service(name)
}

public struct SoundDefinition: Sendable, Codable, Equatable {
    public var output: Bool                       // VZHostAudioOutputStreamSink
    public var input: Bool                        // VZHostAudioInputStreamSource (microphone, §11)
}

public actor VMController {
    public init(definition: ValidatedVMDefinition, diagnostics: DiagnosticsContext)

    public var state: VMState { get }
    public nonisolated let stateUpdates: AsyncStream<VMState>
    public nonisolated let networkHealthUpdates: AsyncStream<VMNetworkHealthState>

    public func start() async throws
    public func pause() async throws
    public func resume() async throws
    public func stop() async throws                    // forced stop (VZ stop)
    public func requestGuestStop() async throws        // VZ requestStop (power-button event); see §9.3
    public func reset() async throws                   // failed → stopped only; see §9.6

    public func connect(vsockPort: UInt32, timeout: Duration) async throws -> VsockConnection
    public nonisolated func console(_ role: ConsoleRole) -> ConsoleChannel
    public func consoleLogWriterHasFailed() async -> Bool
    public func consoleLogWriterDroppedByteCount() async -> UInt64
    public func waitForConsoleLogDrain() async
}

public struct ValidatedVMDefinition: Sendable { /* only VMDefinitionValidator can create it */ }
```

`VMDefinition` is a value. ImageCore's `AndroidBootPlanner` builds it as `AndroidBootPlan.definition` ([android-image.md](android-image.md) §9.1), and RuntimeCore adds the GPU device. It is never mutated after validation. `VMDefinition.summary` (a `Codable` projection without device objects) goes to logs and diagnostics bundles.

The controller is an actor. Its state is the explicit `VMState` enum ([state-machines.md](../01-architecture/state-machines.md) §1). Never infer state from a nil `VZVirtualMachine` ([AGENTS.md](../../AGENTS.md) §6.2).

## 3. Validation

`VMDefinitionValidator.validate(_:) throws(VMConfigurationFailure) -> ValidatedVMDefinition` checks every rule below. It calls `VZVirtualMachineConfiguration.validate()` only after the local rules pass. It collects all failures:

- One broken rule is thrown as its own case.
- Several broken rules are thrown as `.configurationInvalid([VMConfigurationFailure])`, in rule order ([error-catalog.md](../03-reference/error-catalog.md) §5.2).
- `findings(_:) -> [VMConfigurationFailure]` returns the same list without throwing. `apkrun doctor` uses it.

| Rule | Failure case |
|---|---|
| `minimumAllowedCPUCount ≤ cpuCount ≤ min(maximumAllowedCPUCount, host active processor count)`. An empty intersection allows no CPU count | `.cpuCountOutOfRange(requested, allowed)`; `allowed` is `none` if empty |
| `memorySize` is a multiple of 1 MiB, within `minimumAllowedMemorySize…maximumAllowedMemorySize` | `.memoryOutOfRange` |
| `memorySize ≤ 50 %` of physical memory (NFR-RES-01) | `.memoryExceedsHostCap(cap)` |
| Kernel exists and is an **uncompressed arm64 `Image`**: bytes 0x38–0x3B are `ARM\x64`. Reject gzip (`1f 8b`), lz4 (`02 21 4c 18` / `04 22 4d 18`), EFI zboot (`MZ`, `zimg` at offset 4), and anything else. VZLinuxBootLoader cannot decompress, and the VM would hang | `.kernelMissing(url)`, `.kernelNotUncompressedImage(detected)` with `.gzip`, `.lz4`, `.zboot`, or `.unknown` |
| initrd exists if given, size ≤ 512 MiB | `.initrdMissing`, `.initrdTooLarge` |
| Command line ≤ 2048 bytes, ASCII | `.commandLineInvalid` |
| Every disk URL exists and is a regular file. Reject Android sparse images (magic `0xED26FF3A`): VZ needs raw or ASIF | `.diskMissing(role)`, `.diskIsAndroidSparse(role)` |
| Every disk is readable by the process | `.diskNotReadable(role)` |
| No disk URL appears twice, compared after resolving symlinks | `.duplicateDisk(role)` |
| A read-write disk is writable by the process. A read-only disk is opened read-only | `.diskNotWritable(role)` |
| `.none` synchronization is rejected in production definitions | `.diskSyncModeTestOnly(role)` |
| `identifier` ≤ 20 ASCII characters | `.diskIdentifierInvalid` |
| `consolePorts` is non-empty and `[0]` is `.systemConsole` | `.missingSystemConsole` |
| MAC address is a valid locally administered unicast address | `.invalidMACAddress` |
| `machineIdentifier`, when present, decodes with `VZGenericMachineIdentifier(dataRepresentation:)` | `.machineIdentifierInvalid` |
| Each custom device has a nonempty name and at least one queue. VZ adapter checks are part of #64 | `.customDeviceInvalid(name, reason)` |
| `sound.input == true` only with `NSMicrophoneUsageDescription` in the host bundle | `.microphoneUsageDescriptionMissing` |
| `VZVirtualMachineConfiguration.validate()`, after the local rules pass | `.frameworkRejected(underlying)` |

## 4. Mapping to Virtualization.framework

| `VMDefinition` | VZ configuration | Notes |
|---|---|---|
| platform | `VZGenericPlatformConfiguration` with `machineIdentifier` | Created once per instance, stored in `instance.json`. Nested virtualization off |
| `boot` | `VZLinuxBootLoader(kernelURL:)`, `initialRamdiskURL`, `commandLine` | Direct kernel boot ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)) |
| `disks[i]` | `VZVirtioBlockDeviceConfiguration` with `VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:)` and `blockDeviceIdentifier` | Array order kept |
| `networks[i]` | One `VZVirtioNetworkDeviceConfiguration` and `VZNATNetworkDeviceAttachment` each, with its MAC, in array order | No bridged networking (restricted entitlement). Android uses three (§7) |
| `vsockEnabled` | One `VZVirtioSocketDeviceConfiguration` | VZ allows one per VM |
| `consolePorts[i]` | Ports 0–9: one `VZVirtioConsoleDeviceSerialPortConfiguration` each. Ports 10 and up: ports of one `VZVirtioConsoleDeviceConfiguration`, each with `isConsole = true` | §6.1 |
| `entropy` | `VZVirtioEntropyDeviceConfiguration` | |
| `memoryBalloon` | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | Not driven in v1, so a later release can reclaim memory without an image change |
| `sound` | `VZVirtioSoundDeviceConfiguration` with output and/or input streams | [desktop-integration.md](desktop-integration.md) §8 |
| `customDevices` | `customVirtioDevices` (macOS 27), built by VirtioDeviceCore | |
| `builtInDisplay` | `VZVirtioGraphicsDeviceConfiguration` with one scanout and no view | Development only, with the `headless` GPU profile of M1 bring-up ([android-image.md](android-image.md) §9.1). Never set with the GraphicsCore virtio-gpu device, and never in a release bundle |
| (not used) | `keyboards`, `pointingDevices`, `directorySharingDevices`, `usbControllers`, `graphicsDevices` | Graphics is our virtio-gpu. Input is guest-side injection ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)). File sharing goes through the Guest Agent ([desktop-integration.md](desktop-integration.md) §6) |

All VZ objects are created and called on the serial queue `io.apkrun.vm.queue`. The controller actor hops onto it with `withCheckedThrowingContinuation`.

## 5. Guest-visible topology

Observed on macOS 27.0.1 (build 26A434). The capture is `Images/reference/vz/<macOS build>/topology.txt`. The T2 suite re-checks it on each new macOS build (R-16).

- One `pci-host-ecam-generic` PCIe host bridge: ECAM at `0x40000000`, platform device `40000000.pci`. There are no virtio-mmio nodes, so every virtio device is a PCI function.
- GICv3, PSCI via `hvc`, the arm64 timer, a PL031 RTC, and a PL061 GPIO wired to `gpio-keys` as the power button.
- No PL011 UART. The console is `hvc0` (virtio-console). RAM starts at `0x70000000`.

Consequences:

- `androidboot.boot_devices` names the bridge's platform device: `40000000.pci` on VZ (crosvm uses `10000.pci`). All virtio-blk disks sit under it, so one value covers `os.img` and `userdata.img` ([android-image.md](android-image.md) §5.3).
- Nothing relies on `vdX` letters or PCI slot numbers. Android finds partitions by GPT name. Code finds a disk by `blockDeviceIdentifier`.

## 6. Console ports

### 6.1 Single-port devices

Cuttlefish HALs open fixed nodes such as `/dev/hvc3` ([android-image.md](android-image.md) §7). crosvm creates one single-port virtio-console device per port, and Linux numbers them `hvc0…hvcN` in probe order. VirtualMachineCore does the same for ports 0–9. Do not use named multiport ports for HAL ports: they appear as `/dev/vportNpM`, which the HALs do not open.

**VZ limit.** `validate()` rejects more than 10 single-port console devices. Android needs 20. Ports 10 and up are ports of one `VZVirtioConsoleDeviceConfiguration`, each with `isConsole = true`. The guest turns each into an hvc device, so they become hvc10, hvc11, … after the single-port devices. The split is internal to `VZConfigurationBuilder`. `VMDefinition.consolePorts` stays one ordered list.

### 6.2 Port numbering must be verified

Apple does not document the order in which VZ assigns PCI functions to serial ports. Therefore:

1. The test Linux guest attaches `[.systemConsole, .service("test-1"), .service("test-2")]`. The host writes `APKRUN-PORT-<i>\n` to ports 1 and 2 only, never to the system console outside `apkrun dev console` (§6.3). The guest `/init` reads `/dev/hvc1` and `/dev/hvc2` and prints the marker it saw. A T2 test asserts the mapping.
2. The T2 suite checks all 20 ports with markers, using a guest-side probe in the test initramfs. Android relies on the mapping only after this check (#96).
3. If VZ numbering is not the array order, `ConsolePortPlan` (RuntimeCore) reorders the array to match the Cuttlefish map. The map is data, not scattered constants.

The product must not depend on array order across macOS releases. Step 2 runs on each new macOS build (R-16).

### 6.3 Attachments and sinks

Each port gets a `VZFileHandleSerialPortAttachment` built from two pipes:

- **Guest → host:** `ConsoleChannel` reads the nonblocking read end with `DispatchSourceRead`, caps the work of one readiness callback at 1 MiB, and publishes an `AsyncStream<Data>`.
- **Host → guest:** for `.systemConsole` and `.service` ports the host may write. For `.log` and `.silent` ports the host never writes and keeps the write end open, so guest reads block instead of seeing EOF.

Host writes do not hold the lifecycle lock while they wait for pipe capacity. Detaching rejects new writes, closes the guest-readable end to release a blocked writer, waits for admitted writes, and then closes the other endpoints. The host input descriptor suppresses `SIGPIPE`, so a guest shutdown becomes a typed write failure.

Buffering rules:

- `ConsoleChannel` publishes chunks of at most 64 KiB through a bounded buffer of 64 chunks per subscriber. The default policy keeps the oldest chunks. A diagnostic tail selects the newest.
- Each `ConsoleByteStream` reports `droppedByteCount`, and the channel exposes the total. A nonzero count means incomplete output.
- A consumer that needs all output subscribes before the guest starts. A stream created before the first subscriber receives the buffered prefix.
- The log subscription has 64 data chunks plus one reserved control slot, so a full data buffer cannot displace the failure marker.
- When the VM is released, the channel closes the guest-output writer and drains the pipe to EOF before it ends the stream. A failure snapshot reads at most 4 MiB and waits at most 50 ms, stopping earlier at `EAGAIN`. A waiter that arrives after a queued marker waits for it and then gets a fresh snapshot and marker. This keeps a continuous guest writer from delaying failure publication.
- A channel is bound to its VM's serial queue and cannot be attached again after detachment.

| Role | Guest → host data goes to | Host writes |
|---|---|---|
| `.systemConsole` (hvc0) | `ConsoleLogWriter` → `~/Library/Logs/APKRun/vm/console.log`, and `BootPhaseDetector` | Only in `apkrun dev console` |
| `.log(name)` | `ConsoleLogWriter(name)` → `~/Library/Logs/APKRun/guest/<name>-<timestamp>.log` in developer mode and diagnostics capture; otherwise discarded | Never |
| `.silent(name)` | Discarded, counted in metrics | Never |
| `.service(name)` | A host-side service substitute ([android-image.md](android-image.md) §7) | Yes |

### 6.4 `ConsoleLogWriter`

- A bounded subscription feeds the writer asynchronously, so disk I/O never runs on the pipe reader. Dropped bytes include stream drops and bytes the writer cannot write to every required destination. Bytes awaiting a successful `fsync` after a sync error stay counted until a later sync succeeds. Either condition reports `vm.consoleWriter` (§14).
- Each record starts with the ISO 8601 wall-clock time (milliseconds) and the host monotonic time since `VM_START`: `yyyy-MM-dd'T'HH:mm:ss.SSSZ +<seconds>.<milliseconds> `. A partial line is written at the next 250 ms flush, and later bytes start a new record.
- Records are written in bounded batches that end before the 64 KiB threshold or a rotation boundary. A guest line longer than 64 KiB is split into newline-terminated records.
- Rotation at 20 MiB keeps five generations: `console.log`, `console.1.log` … `console.4.log`. A per-boot copy `vm/boot-<yyyyMMdd'T'HHmmss'Z'>.log` keeps the newest five boots.
- Buffered writes are flushed and `fsync`ed every 250 ms or 64 KiB, whichever comes first, and when the VM fails or its console closes during stop or reset. Before publishing `.failed`, the controller takes the failure snapshot (§6.3), waits for the bytes yielded to the log subscription, and then flushes and syncs both files. Serial logs must survive a VM or host-process crash (NFR-REL-05).
- The `vm/` directory is mode `0700`. Log files are mode `0600`. Invalid UTF-8 is written as is, and the os_log mirror escapes it.
- The writer never parses or redacts. Redaction happens only when a diagnostics bundle is built ([diagnostics.md](diagnostics.md) §6).

## 7. Networking

- `VMDefinition.networks` is an ordered list of NAT NICs, one virtio-net device each. The test guest uses one. The Android definition uses three, in Cuttlefish order: the mobile NIC, the ethernet NIC, and the `virt_wifi` backing NIC ([android-image.md](android-image.md) §7.4). Guests get a DHCP lease from VZ (typically `192.168.64.0/24`), and the host serves DNS. No entitlement is needed.
- Each MAC is generated once (`VZMACAddress.randomLocallyAdministered()`) and stored in `instance.json`. The exception is the `virt_wifi` NIC, whose MAC derives from `androidboot.wifi_mac_prefix`. The guest's `setup_wifi` rewrites the interface to that MAC, and vmnet drops frames from a source MAC it did not assign.
- `VMController.networkHealthUpdates` publishes the initial state, each attachment loss, and each recovery. A new start clears the failure. The live diagnostics service re-runs `vm.network` from these events ([diagnostics.md](diagnostics.md) §7.1).
- There is no inbound port forwarding. Host → guest traffic uses vsock (§8).

## 8. vsock

- One `VZVirtioSocketDevice`. Guest CID 3, host CID 2.
- Outbound only in v1: the host calls `connect(toPort:)` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- `VMController.connect(vsockPort:timeout:)` races the completion handler against a timeout, because VZ has no timeout parameter. A late completion is closed at once.
- `VsockConnection` keeps a strong reference to the `VZVirtioSocketConnection`. The file descriptor is valid only while that object lives.
- Reads: the stream reads in ordered 64 KiB chunks and caps unread buffered input at 1 MiB. At the cap it probes for peer EOF with a one-byte read. More data than the cap closes the connection, and reads throw `bufferedInputLimitExceeded` after the buffered bytes drain. Data and EOF keep their order. The low-water mark is one byte, so small reads are delivered promptly. `read(upTo:)` checks cancellation first. `write(_:)` writes the data. `closed` completes after peer EOF or local close.
- Errors: `NSPOSIXErrorDomain` `ECONNREFUSED` maps to `.vsockPortNotListening(port)`. Other VZ errors, including `ECONNRESET`, map to `VMFailure.vsockConnectFailed(port, underlying)`. With no listener, VZ may do nothing, so a caller may time out (`.vsockConnectTimedOut`). Connect with vsock disabled reports `.vsockDeviceNotConfigured`. If VZ does not expose the device, it reports `.vsockDeviceUnavailable`.
- The LinuxGuest readiness probe retries refused, timed-out, and startup `ECONNRESET` attempts with backoff for at most five seconds.
- **`VsockLoopbackForwarder`** (generic; ADB uses it, #16) listens on `127.0.0.1:<hostPort>` only, with a POSIX IPv4 socket. Each TCP connection opens `connect(vsockPort:)` and copies both directions. If the guest connection fails, the TCP connection closes at once. RuntimeCore configures `guest 5555 ↔ 127.0.0.1:<port>` in developer mode only, where `<port>` is `BootOptions.adbHostPort` (6520 in the product; `0` asks for a free port). It never binds a non-loopback address (NFR-SEC-06). Do not use Network.framework: on macOS 27 it cannot bind loopback only.
- Before binding, the forwarder connects to the port once. A listener on any address of that port is reported as `vm.loopbackPortInUse`. `SO_REUSEADDR` is set only after that probe, so a TIME_WAIT connection does not block a restart.

## 9. Lifecycle

### 9.1 Start

```text
start()
  state: stopped → starting                 (PerfMarker VM_START)
  build VZVirtualMachine on the VM queue with the validated configuration
  attach delegates: VZVirtualMachineDelegate, VZNetworkDeviceAttachment disconnect handling
  vm.start { result }
     completion failure → state: failed(.startFailed(underlying))
     completion success:
       buffered didStopWithError → state: failed(.startFailed(underlying))
       otherwise → state: running, then process buffered guest/device events
```

The delegate buffers callbacks on the VM queue (`VMStartupEventBuffer`) while `start` is pending, and returns them with the start completion, so callback order holds. If start succeeds, the first buffered stop error becomes `.startFailed`, and later reports are ignored after the terminal transition. If the start completion fails, its error is the cause, and buffered events are discarded.

RuntimeCore's `BootPhaseDetector` records `KERNEL_START` on the first console line (`Booting Linux on physical CPU`).

### 9.2 Delegate mapping

| VZ callback | Transition |
|---|---|
| `guestDidStop(_:)` | `running/paused/stopping → stopped` |
| `virtualMachine(_:didStopWithError:)` | `starting`: buffer for `failed(.startFailed(underlying))`. `running/paused/stopping`: `→ failed(.stoppedWithError(underlying))` |
| `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)` | Stays `running`. Logged. Health `vm.network = degraded` |

On a spontaneous `guestDidStop`, `VMController` records `.stopped` before it awaits VZ resource release. During an explicit forced stop, the event completes the stop request, but the controller stays `.stopping` until the VZ stop completion arrives. Only then are the driver and console attachments released and the state set to `.stopped`. A later `start()` waits for that release barrier.

### 9.3 Stopping Android

`requestGuestStop()` maps to `VZVirtualMachine.requestStop()`, a **power-button press** through the PL061 GPIO. Android reads a short press as "screen off", not shutdown. Therefore:

- RuntimeCore first stops Android through the Guest Agent `Shutdown` RPC (`PowerManager.shutdown`, [guest-protocol.md](guest-protocol.md) §7.1). If the Guest Agent explicitly refuses the operation, developer mode may fall back to `adb shell reboot -p`, then the serial shell. A lost reply is ambiguous: the host does not resend the shutdown request through another channel. Android powers off through PSCI `SYSTEM_OFF`, which VZ reports as `guestDidStop`.
- If `guestDidStop` has not arrived after 20 s, RuntimeCore calls `VMController.stop()` (forced) and logs a warning in every mode. The next boot runs normally: f2fs and ext4 recover, and Android's userdata checkpointing covers the rest.
- The 20 s post-request deadline starts after the Guest Agent request or a developer-mode fallback returns. The Guest Agent request itself may take up to 20 s, so a normal stop can take up to 40 s; host shutdown has its own 40 s overall deadline ([runtime-daemon.md](runtime-daemon.md) §2.4). The wait runs when a request may have reached Android, even if its reply was lost. A cancelled stop keeps the deadline, because the VM still has to stop. Outside developer mode, an unavailable or explicitly unsupported Guest Agent causes an immediate forced stop. The rule is `AndroidStopSequence` (RuntimeCore).
- A forced stop not completed after 10 s fails with `VMFailure.stopTimedOut` and the state becomes `failed` ([state-machines.md](../01-architecture/state-machines.md) §1).
- The test Linux guest needs `requestGuestStop()` (§12). Its `/init` maps a rising edge on GPIO offset 6 to `poweroff -f`.

### 9.4 Pause and resume

- `pause()` and `resume()` wrap `VZVirtualMachine.pause` and `resume`. Custom devices get `WillPause` and `WillResume` callbacks. GraphicsCore stops presenting while paused ([graphics.md](graphics.md) §8).
- After `resume()`, RuntimeCore asks the Guest Agent to resync wall-clock time ([desktop-integration.md](desktop-integration.md) §9). VirtualMachineCore only reports the pause duration.
- Host sleep: RuntimeCore's `PowerObserver` registers with `IORegisterForSystemPower`. apkrund has no NSApplication, so `NSWorkspace` notifications are not used. It pauses a running VM before acknowledging `kIOMessageSystemWillSleep` and resumes on `kIOMessageSystemHasPoweredOn` ([runtime-daemon.md](runtime-daemon.md) §6). The design does not rely on VZ's implicit behavior during host sleep (FR-VM-11).

### 9.5 Save and restore

Not used. VirGL renderer state lives in host GL contexts and cannot be serialized. The virtio-gpu device sets `supportsSaveRestore = false`, so the VM is not saveable (R-07). Cold-boot time is reduced by trimming the boot (NFR-PERF-02).

### 9.6 Reset

`failed → stopped` happens only through `reset()`, after the diagnostics capture ([state-machines.md](../01-architecture/state-machines.md) §1). `reset()` releases the `VZVirtualMachine`, closes pipes, and flushes console logs. If a forced-stop callback is pending, reset waits up to the forced-stop timeout (10 s). If it stays pending, reset returns `VMFailure.stopTimedOut`, keeps the failed VM and its resources, and the caller may retry. Releasing a VM while Virtualization.framework still owns a lifecycle call is unsafe.

## 10. Memory and CPU defaults

| Setting | Default | Limits | Source |
|---|---|---|---|
| vCPUs | 4 | 2 … min(8, host performance cores + efficiency cores) | `settings.json` `runtime.cpuCount`, copied into `instance.json` before each boot |
| Memory | 4 GiB | 3 GiB … 50 % of physical memory | `runtime.memoryGiB`, copied into `instance.json` before each boot |
| Balloon | present, idle | — | — |

A change takes effect at the next VM start, and the UI says so.

## 11. Sound

- Output: one `VZVirtioSoundDeviceStreamConfiguration` output stream with `VZHostAudioOutputStreamSink`, attached whenever audio is enabled globally (default on).
- Input: one stream with `VZHostAudioInputStreamSource`, attached only while at least one package has the microphone integration in effect ([desktop-integration.md](desktop-integration.md) §8.2). The configuration is fixed at start. Enabling the microphone for the first package, or disabling it for the last, needs a runtime restart. The UI offers **Restart Android Now** / **Later** ([host-ui.md](host-ui.md) §7.4).

## 12. Test Linux guest

The test Linux guest exercises every device before Android is involved.

- **Kernel:** a pinned arm64 kernel (Alpine `linux-virt`; version and SHA-256 in `ThirdParty/ThirdParty.lock.json`) with virtio PCI, blk, net, console, vsock (`vmw_vsock_virtio_transport`), rng, and DRM virtio-gpu, built in or as modules. `scripts/fetch-test-linux.sh` verifies the hash and decompresses gzip (the validator rejects compressed kernels, §3). `af_packet` must be available as a module for BusyBox `udhcpc`.
- **initramfs:** `scripts/build-test-initramfs.sh` builds it from a pinned Alpine minirootfs, the kernel modules, `socat`, `libgpiod`, `ssl_client`, `Tests/Fixtures/linux/init`, `Tests/Fixtures/linux/network-errors.sh`, and the Mesa virgl packages and kmscube in `Tests/Fixtures/linux/virgl-packages.list`. The virgl packages are pinned to Alpine v3.23, because v3.24 Mesa has no virgl driver. `scripts/tools/initramfs-manifest.py` checks the packages, the paths in `virgl-paths.list`, and the DT_NEEDED sonames, then writes `initramfs.manifest.json` next to the archive.
- **`/init`:**
  1. Mounts proc, sys, and dev, and loads modules.
  2. Unless the run powers off after the tests, finds the GPIO chip labeled `PL061` and starts `gpiomon` for rising edges on offset 6. It uses `gpioinfo` to confirm the monitor holds the line before reporting readiness. If the chip or line is unavailable, it reports an init failure and powers off, rather than boot without a stop path.
  3. Prints `APKRUN-TEST: boot ok` to `hvc0`, then `powerinput ok` once the line request is confirmed.
  4. Runs the checks named on the command line (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl,…`) and prints `APKRUN-TEST: <name> ok|fail <detail>` for each. `gpu-hotplug` runs the R-01 spike. The flood check prints `APKRUN-FLOOD <i>` lines and then `APKRUN-TEST: flood ok lines=<n>`.
  5. Prints `APKRUN-TEST: done`. It triggers `apkrun.test.panic=1` when requested. Otherwise it powers off when `apkrun.test.poweroff=1`, or keeps the serial shell open while it waits for the VZ power input. A rising GPIO edge powers it off.
- **Network check:** `/init` brings `eth0` up and runs `udhcpc` with `/etc/udhcpc/apkrun.script`, which delegates to Alpine's default script and atomically records the address, router, and DNS server. The guest fetches `/generate_204` from a host HTTP server. External output is capped at 4 KiB; output beyond it fails. Without an HTTP response, only a recognized BusyBox `wget` socket-connect line, or the exact `download timed out` line with no TLS or client diagnostic, is classified `external`. Socket-connect failures and timeouts keep distinct details, and only the same classified failure on one retry is skipped. Other HTTPS or TLS errors fail the test. The host harness rejects any failed check record before it accepts `done`.
- **Disks:** the `Tests/Fixtures/linux/` scripts create small raw read-only and read-write test disks with known content.
- **GPIO:** the pinned kernel has `CONFIG_GPIO_CDEV=y` and `CONFIG_GPIO_PL061=m`, but no `CONFIG_KEYBOARD_GPIO`. The initramfs uses the GPIO character-device API through `libgpiod`. It finds the chip by its PL061 label and monitors only offset 6.
- **Harness:** `Tests/IntegrationTests/LinuxGuestTests` boots the guest with VirtualMachineCore only, and asserts on `APKRUN-TEST:` lines with a 60 s timeout. Parsed records are capped at 256. Missing boot, check, or done records fail the test instead of growing memory. The harness reads the console with the oldest-chunks policy for records, and keeps the newest 4 MiB as its failure attachment.

`TestGuestLineParser` joins serial bytes across read boundaries and ignores non-marker kernel output. It recognizes `APKRUN-TEST: boot ok`, `APKRUN-TEST: <name> ok|fail <detail>`, and `APKRUN-TEST: done`. It accepts LF and CRLF, recognizes a marker appended to an unterminated final kernel line, and parses a final record at EOF. Records longer than 64 KiB are discarded through the next newline and counted.

## 13. Errors

```swift
public enum VMConfigurationFailure: APKRunError {
    /* one case per §3 rule */
    case configurationInvalid([VMConfigurationFailure])   // several rules broken (§3)
}

public enum VMFailure: APKRunError {
    case invalidTransition(from: VMState, to: VMState)
    case startFailed(underlying: VZErrorInfo)
    case stoppedWithError(underlying: VZErrorInfo)
    case pauseFailed(underlying: VZErrorInfo)
    case resumeFailed(underlying: VZErrorInfo)
    case stopTimedOut
    case vsockDeviceNotConfigured
    case vsockDeviceUnavailable
    case vsockConnectFailed(port: UInt32, underlying: VZErrorInfo)
    case vsockPortNotListening(port: UInt32)
    case vsockConnectTimedOut(port: UInt32)
    case virtualizationUnavailable          // VZVirtualMachineConfiguration.isSupported == false or entitlement missing
    // health findings (§14), never thrown
    case networkAttachmentLost              // vm.network: the NAT attachment was disconnected (§9.2)
    case consoleLogWriteFailed              // vm.consoleWriter: writing a console log failed
}
```

Codes, messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md) (domain `vm`). `VZErrorInfo` is a `Sendable` copy of the `NSError` (domain, code, description).

## 14. Logging and metrics

- Subsystem `io.apkrun.vm`. Categories `lifecycle`, `config`, `console`, `vsock`, `network`, and `virtio` (VirtioDeviceCore: `DRIVER_OK`, notifications, resets).
- Every transition is logged with the operation ID that caused it.
- `PerfMarker.vmStart` is recorded at `start()`. Other boot markers come from RuntimeCore ([diagnostics.md](diagnostics.md) §4).
- Health (`HealthCheck` in DiagnosticsCore): `vm.state`; `vm.network` (warning `vm.networkAttachmentLost`); `vm.consoleWriter` (warning `vm.consoleLogWriteFailed` on write errors or dropped bytes); `vm.virtualizationSupported`.

## 15. Tests

- **T0**, `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`: one test per validator rule with real gzip, lz4, and `Image` headers (`VMDefinitionValidatorTests`, `KernelImageInspectorTests`); state edges (`VMStateTests`); MAC and identifier persistence (`MachineIdentityTests`); start-callback buffering and the mapping of a buffered start failure (`VMStartupEventBufferTests`, `VMControllerTests`); console log rotation and fsync policy with an injected clock and file system (`ConsoleLogWriterTests`); line parsing (`TestGuestLineParserTests`); health checks (`VMHealthChecksTests`).
- **T0**, `Packages/RuntimeCore/Tests/RuntimeCoreTests/AndroidStopSequenceTests.swift`: the developer stop of §9.3, including the 20 s deadline, the forced stop after it, a cancelled stop keeping the deadline, and the channel choice.
- **T1**, `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/`: `ConsoleChannel` with real pipes (`.log` and `.silent` never written); `ConsoleLogWriter` on a real directory (modes, rotation); the §3 disk rules with real files and permissions; `VsockConnection` over a `socketpair`, including the 1 MiB cap and the EOF probe; `VsockLoopbackForwarder`; the entitlement probe of `validate()`.
- **T2**, `Tests/IntegrationTests/LinuxGuestTests/`, with the signed test host:
  - boot marker and power-off (`BootTests`);
  - persisted marker, three-port numbering, forced stop during flood, kernel panic capture (`ConsoleTests`);
  - all 20 ports with markers (`ConsolePortTests`, §6.2);
  - read-only and read-write disks, persistence across VMs, journal replay after forced stop (`BlockTests`);
  - the Android disk layout (`AndroidDiskLayoutTests`);
  - DHCP lease, host HTTP 204, live `vm.network` (`NetworkTests`);
  - vsock echo of 1 MiB, unused-port error, guest disconnect, readiness, VM-stop cleanup (`VsockTests`);
  - start completion versus delegate callback, with a guest-stop positive control (`StartFailureProbeTests`).
- **T3**, `Tests/AcceptanceTests/G1LinuxBoot/`: gate G1, ten boots in a row, each stopped through the guest power button ([roadmap.md](../04-plan/roadmap.md) §2).
- **T3, nightly**, `Tests/AcceptanceTests/Network/`: the guest resolves a public name and fetches `https://connectivitycheck.gstatic.com/generate_204`. Repeated DNS failures, recognized socket-connect failures, or the exact BusyBox timeout (§12) are classified `external` when no HTTP response arrived.
- **Manual:** SIGINT to `apkrun dev boot` takes the graceful `reboot -p` path. This runs outside the suite.

## 16. Open items

- Whether the microphone prompt appears at VM start or at first capture (OQ-29, §11). #85 decides.
- Whether the stock arm64 kernel carries `virtio_snd` (OQ-38, §11). If not, the custom image adds it ([android-image.md](android-image.md) §7.5). #84 decides.
- RuntimeCore sends the Guest Agent `Shutdown` RPC before stopping Android (§9.3). Stock-image shutdown behavior and VSOCK transport still require T2 validation in #35; custom-image provisioning of `apkrun_vsockd` is tracked by #36.
- Pause and resume across host sleep is not verified on hardware (§9.4). #70 holds it.
- Whether VZ reports a start failure through the start completion, `didStopWithError`, or both (§9.1, §9.2). The controller accepts either path and never makes a second transition. Not verified across macOS builds (R-16).
