# VM Design (VirtualMachineCore)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §1, [android-image.md](android-image.md), [graphics.md](graphics.md), [../01-architecture/decisions/0002-virtualization-framework-macos27.md](../01-architecture/decisions/0002-virtualization-framework-macos27.md), [../01-architecture/decisions/0015-direct-kernel-boot.md](../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Tasks | #002–#007, #011 (topology discovery), #063, #069, #083, #084, #095 |

---

## 1. Responsibilities

VirtualMachineCore turns a validated `VMDefinition` into a running `VZVirtualMachine` and reports its state. It knows about CPUs, memory, disks, NAT, vsock, console ports, entropy, balloon, sound, and custom virtio devices that other modules hand in. It knows nothing about Android, APKs, image file names, or what a disk contains.

Non-goals:

- Choosing *which* files to boot. That is ImageCore, which produces the Android-specific parts of the definition ([android-image.md](android-image.md) §9).
- Implementing virtio devices. VirtioDeviceCore provides the adapter and GraphicsCore provides virtio-gpu. VirtualMachineCore only attaches them.
- Deciding when to pause or stop. That is RuntimeCore's idle policy ([runtime-daemon.md](runtime-daemon.md) §5).

## 2. Public API

```swift
public struct VMDefinition: Sendable {
    public var label: String                      // VZVirtualMachineConfiguration.label (macOS 27), e.g. "APKRun Android"
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
    public var identifier: String?                // VZVirtioBlockDeviceConfiguration.blockDeviceIdentifier (≤ 20 ASCII), visible as /sys/block/vdX/serial
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
    public var input: Bool                        // VZHostAudioInputStreamSource (microphone, #084)
}
```

`VMDefinition` is a value. ImageCore's `AndroidBootPlanner` builds it as `AndroidBootPlan.definition` from the image manifest and `InstanceConfiguration` ([android-image.md](android-image.md) §9.1). RuntimeCore adds the GPU device, and the value is never mutated after validation. `VMDefinition.summary` (a `Codable` projection without device objects) is written to the log and to diagnostics bundles.

```swift
public actor VMController {
    public init(definition: ValidatedVMDefinition, diagnostics: DiagnosticsContext)

    public var state: VMState { get }
    public nonisolated let stateUpdates: AsyncStream<VMState>

    public func start() async throws
    public func pause() async throws
    public func resume() async throws
    public func stop() async throws                    // forced stop (VZ stop)
    public func requestGuestStop() async throws        // VZ requestStop (power-button event); see §9.3
    public func reset() async throws                   // failed → stopped only; see §9.6

    public func connect(vsockPort: UInt32, timeout: Duration) async throws -> VsockConnection
    public nonisolated func console(_ role: ConsoleRole) -> ConsoleChannel   // read stream + optional writer
}

public struct ValidatedVMDefinition: Sendable { /* only VMDefinitionValidator can create it */ }
```

[AGENTS.md](../../AGENTS.md) §6.2 is followed literally: the controller is an actor, the state is explicit (`VMState`), and state is never inferred from a nil `VZVirtualMachine`.

## 3. Validation (`VMDefinitionValidator`, #002)

`VMDefinitionValidator.validate(_:) throws(VMConfigurationFailure) -> ValidatedVMDefinition` runs every local rule below. It builds the `VZVirtualMachineConfiguration` and calls its `validate()` only when the local rules pass; this avoids secondary framework errors from invalid inputs. Errors are collected, not thrown on the first local failure, so `apkrun doctor` can print them all:

- One broken rule is thrown as its own case.
- Several broken rules are thrown as one `.configurationInvalid([VMConfigurationFailure])`, a flat list in rule order ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §5.2).
- `findings(_:) -> [VMConfigurationFailure]` returns the same list without throwing, for `apkrun doctor`.

| Rule | Failure case |
|---|---|
| `VZVirtualMachineConfiguration.minimumAllowedCPUCount ≤ cpuCount ≤ min(maximumAllowedCPUCount, host active processor count)`; if the intersection is empty, no CPU count is allowed | `.cpuCountOutOfRange(requested, allowed)` (`allowed` is the text `none` for an empty intersection) |
| `memorySize` is a multiple of 1 MiB, within `minimumAllowedMemorySize…maximumAllowedMemorySize` | `.memoryOutOfRange` |
| `memorySize ≤ 50 %` of physical memory (NFR-RES-01) | `.memoryExceedsHostCap(cap)` |
| Kernel exists and is an **uncompressed arm64 `Image`**: bytes 0x38–0x3B are `ARM\x64`. gzip (`1f 8b`), lz4 (`02 21 4c 18` / `04 22 4d 18`), and EFI zboot (`MZ`, then `zimg` at offset 4) are rejected, and so is anything else, including other architectures (VZLinuxBootLoader has no decompressor on arm64; the VM would hang) | `.kernelMissing(url)`, `.kernelNotUncompressedImage(detected)` with `detected` one of `.gzip`, `.lz4`, `.zboot`, `.unknown` |
| initrd exists if given, size ≤ 512 MiB | `.initrdMissing`, `.initrdTooLarge` |
| Command line ≤ 2048 bytes, ASCII | `.commandLineInvalid` |
| Every disk URL exists and is a regular file. Android sparse images (magic `0xED26FF3A`) are rejected: VZ needs raw (or ASIF) images | `.diskMissing(role)`, `.diskIsAndroidSparse(role)` |
| Every disk is readable by the process | `.diskNotReadable(role)` |
| No disk URL appears twice, compared after resolving symlinks (VZ would open it twice) | `.duplicateDisk(role)` |
| A read-write disk is writable by the process; a read-only disk is opened read-only | `.diskNotWritable(role)` |
| `.none` disk synchronization mode is reserved for tests and rejected in production definitions | `.diskSyncModeTestOnly(role)` |
| `identifier` ≤ 20 ASCII characters | `.diskIdentifierInvalid` |
| `consolePorts` is non-empty and `[0]` is `.systemConsole` | `.missingSystemConsole` |
| MAC address is a valid locally administered unicast address | `.invalidMACAddress` |
| `machineIdentifier`, when present, decodes with `VZGenericMachineIdentifier(dataRepresentation:)` | `.machineIdentifierInvalid` |
| Each custom-device descriptor has a nonempty name and at least one queue; VZ adapter count and configuration checks are in #063 | `.customDeviceInvalid(name, reason)` |
| `sound.input == true` only when `NSMicrophoneUsageDescription` is present in the host bundle | `.microphoneUsageDescriptionMissing` |
| `VZVirtualMachineConfiguration.validate()` after local rules pass | `.frameworkRejected(underlying)` |

Tests (T0): one test per rule, including kernel magic detection with real gzip, lz4, and `Image` headers (fixture headers are 64 bytes, not whole kernels).

**Opt-in unentitled `swift test` probe:** On 2026-10-07 UTC, the
`VirtualMachineCoreSystemTests.vzConfigurationValidationReportsProcessEntitlement`
test ran with
`APKRUN_TEST_LINUX_DIR=/tmp/apkrun-test-linux-codex swift test --scratch-path /tmp/apkrun-swiftpm-codex --filter vzConfigurationValidationReportsProcessEntitlement`
on arm64 Mac17,9 (macOS 27.0.1, build `26A434`; Xcode 27.0, build
`27A266a`). The probe uses `VMDefinitionBuilder` and the production
`VZConfigurationBuilder` with the pinned kernel
(`e31110ab7979cee4cddcb975b36ab4f1231e98114eb8c360aeeffa00a6adbbc4`) and
initramfs
(`5eaacf941c1ebd9e81699dfaa7e7583e50e559a33df3e2a82f5e8bd31cce5e7f`).
`SecTaskCopyValueForEntitlement` confirmed that the test process had no
`com.apple.security.virtualization` entitlement, while
`VZVirtualMachine.isSupported` was true. `validate()` returned
`VZErrorDomain` code 2, and `NSLocalizedFailureReasonErrorKey` explicitly said
the process lacked that entitlement; `NSDebugDescriptionErrorKey` was absent.
The test passed and did not create a `VZVirtualMachine`. The default
unentitled validation paths continue to use the framework-validator fake; this
opt-in system test probes the real validator, and #003's signed T2 test host
covers the entitled path.

## 4. Mapping to Virtualization.framework

| `VMDefinition` | VZ configuration | Notes |
|---|---|---|
| platform | `VZGenericPlatformConfiguration` with `machineIdentifier` | The identifier is created once per instance and stored in `instance.json`. Nested virtualization stays off. |
| `boot` | `VZLinuxBootLoader(kernelURL:)`, `initialRamdiskURL`, `commandLine` | Direct kernel boot ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)) |
| `cpuCount`, `memorySize` | `cpuCount`, `memorySize` | |
| `disks[i]` | `VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:))`, `blockDeviceIdentifier` | Order preserved in `storageDevices` |
| `network` | one `VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment` per entry, with its `macAddress`, in array order | No bridged networking (restricted entitlement). The Android definition has three entries in Cuttlefish's order (§7) |
| `vsockEnabled` | one `VZVirtioSocketDeviceConfiguration` | VZ allows one vsock device per VM |
| `consolePorts[i]` | ports 0–9: one `VZVirtioConsoleDeviceSerialPortConfiguration` each, with `VZFileHandleSerialPortAttachment`. Ports 10 and up: the ports of one `VZVirtioConsoleDeviceConfiguration`, each with `isConsole = true` | See §6.1 for the single-port devices and VZ's limit of 10 |
| `entropy` | `VZVirtioEntropyDeviceConfiguration` | |
| `memoryBalloon` | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | Not driven in v1. Present so a later release can reclaim memory without an image change |
| `sound` | `VZVirtioSoundDeviceConfiguration` with output and/or input streams | [desktop-integration.md](desktop-integration.md) §8 |
| `customDevices` | `customVirtioDevices` (macOS 27) | Built by VirtioDeviceCore from each `VirtioDeviceModel` |
| `builtInDisplay` (development only) | `VZVirtioGraphicsDeviceConfiguration` with one `VZVirtioGraphicsScanoutConfiguration`, and no view | Only the `headless` GPU profile of M1 bring-up sets it: the stock image cannot boot without a DRM device ([android-image.md](android-image.md) §9.1). Never set together with the GraphicsCore virtio-gpu device, and never in a release bundle |
| (not used) | `keyboards`, `pointingDevices`, `directorySharingDevices`, `usbControllers`, and `graphicsDevices` outside `builtInDisplay` | Graphics is our own virtio-gpu; input is guest-side injection ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)); file sharing goes through the Guest Agent ([desktop-integration.md](desktop-integration.md) §6) |

All VZ objects are created and called on the controller's private serial `DispatchQueue` (`io.apkrun.vm.queue`), as VZ requires. The actor hops onto that queue with `withCheckedThrowingContinuation`.

## 5. Guest-visible topology

What the guest sees on VZ (confirmed by #011 on macOS 27.0.1 (26A434); the capture is `Images/reference/vz/26A434/topology.txt`):

- One `pci-host-ecam-generic` PCIe host bridge (ECAM at `0x40000000`, platform device `40000000.pci`, host bridge `0000:00:00.0` with vendor `0x106b`). There are no virtio-mmio nodes, so every virtio device is a PCI function. The device tree has the top-level nodes `chosen`, `clock`, `cpus`, `gic`, `gpio-keys`, `hypervisor`, `memory`, `pci`, `pl031`, `pl061`, `psci`, and `timer`.
- GICv3, PSCI via `hvc`, the arm64 architected timer, PL031 RTC, a PL061 GPIO wired to `gpio-keys` as the power button.
- No PL011 UART. The console is `hvc0` (virtio-console).
- RAM starts at `0x70000000`.

Consequences for Android:

- `androidboot.boot_devices` must name the PCI host bridge's platform device (crosvm uses `10000.pci`; the VZ value is `40000000.pci`, observed on macOS 27.0.1 (26A434) from `readlink -f /sys/block/vda` and recorded by #011). All virtio-blk disks sit under that one bridge, so a single value covers `os.img` and `userdata.img` ([android-image.md](android-image.md) §5.3).
- The signed #005 T2 test on arm64 macOS 27.0 (26A428) observed guest-visible block-device serial order following the configuration arrays for both `[ro, rw]` and `[rw, ro]`. This is a measured result for that OS build, not a product dependency: nothing in APKRun relies on `vdX` letters or PCI slot numbers. Android finds partitions by GPT name, and our code finds disks by `blockDeviceIdentifier` if it ever needs to.
- The discovered topology (`lspci -nn`, `/sys/bus/pci/devices`, `/proc/device-tree` dump) is committed to `Images/reference/vz/<macOS build>/topology.txt` by #011 and re-checked by the T2 suite on each new macOS build (R-16).

## 6. Console ports

### 6.1 Why single-port devices

Cuttlefish's HALs open fixed device nodes (`/dev/hvc3` for keymaster and so on; the full map is in [android-image.md](android-image.md) §7). crosvm creates one single-port virtio-console device per port. Linux numbers them `hvc0…hvcN` in probe order. We do the same with `VZVirtioConsoleDeviceSerialPortConfiguration`, one per entry of `consolePorts`.

The alternative, one `VZVirtioConsoleDeviceConfiguration` with named multiport ports, gives `/dev/vportNpM` nodes, which the Cuttlefish HALs don't use. It stays available for our own future use (named ports would be self-describing).

**VZ's limit.** `validate()` rejects more than 10 `VZVirtioConsoleDeviceSerialPortConfiguration`s ("Number of Virtio console serial port devices is greater than the maximum number supported"; macOS 27.0.1, 26A434). Android needs 20 ports. VirtualMachineCore therefore attaches ports 0–9 as single-port devices and ports 10 and up as the ports of one multiport `VZVirtioConsoleDeviceConfiguration`, each with `isConsole = true`. The guest's virtio-console driver turns every port the host marks as a console into an hvc device, so those ports become hvc10, hvc11, …, after the ten single-port devices. In the 2026-10-08 Android boot, the sensors HAL's frames on `/dev/hvc18` arrived on port 18, so the order matched the array order there; #095 verifies all 20 ports with markers (§6.2). The split is internal to `VZConfigurationBuilder`: `VMDefinition.consolePorts` stays one ordered list.

### 6.2 Port numbering must be verified, not assumed

Apple does not document the order in which VZ assigns PCI functions to serial ports. So:

1. #004 (M0) attaches three ports to the test Linux guest: `[.systemConsole, .service("test-1"), .service("test-2")]`. The host writes `APKRUN-PORT-<i>\n` into the `.service` ports 1 and 2 only, because it never writes to the system console outside `apkrun dev console` (§6.3). Port 0 is identified by the kernel console output that arrives on its pipe. The guest's `/init` reads `/dev/hvc1` and `/dev/hvc2` and prints which marker it saw. The mapping is asserted in a T2 test.
2. #095 repeats this with all 20 ports, using a small guest-side probe run from the test initramfs, before the Android boot relies on it.
3. If VZ numbering is not the array order, `ConsolePortPlan` (RuntimeCore) re-orders the array so that the guest numbering matches the Cuttlefish map. The mapping is data, never scattered constants.

**Observed on the reference Mac.** On 2026-10-05 UTC, arm64 macOS 27.0
(26A428) reported `hvc1=APKRUN-PORT-1` and `hvc2=APKRUN-PORT-2` in the signed
#004 T2 test. This confirms array order on this OS build; #095 still verifies
all 20 ports, and the product must not depend on this observation across OS
releases.

### 6.3 Attachments and sinks

Each port gets a `VZFileHandleSerialPortAttachment` built from two pipes:

- **Guest → host:** the guest writes into the pipe's write end. `ConsoleChannel` reads the nonblocking read end with `DispatchSourceRead`, caps normal readiness work at 1 MiB per callback, and publishes an `AsyncStream<Data>`.
- **Host → guest:** a second pipe. For `.systemConsole` and `.service` ports the host may write. For `.log` and `.silent` ports the host never writes and keeps the write end open, so guest reads block instead of seeing EOF.

Host input writes do not hold the channel lifecycle lock while waiting for pipe
capacity. Detaching a channel rejects new writes, closes the guest-readable end
to release any blocked host writer, waits for admitted writes to finish, and
then closes the remaining pipe endpoints. The host input descriptor suppresses
`SIGPIPE` so a concurrent guest shutdown becomes a typed write failure instead
of terminating the host process.

`ConsoleChannel` publishes chunks of at most 64 KiB through a bounded buffer of
64 chunks per subscriber. The default policy preserves the oldest queued chunks;
a consumer that needs a diagnostic tail can select the newest chunks instead.
Each `ConsoleByteStream` reports its own `droppedByteCount`, and the channel
also exposes the total across subscribers. Consumers must treat a nonzero count
as incomplete output. The Linux test harness uses the oldest policy for parsing
test records and the newest policy for its bounded 4 MiB failure attachment,
which also includes both stream loss counts. Consumers that need the same
output subscribe before the guest starts; a stream created before the first
subscriber receives the buffered prefix. After the VZ driver releases the VM
on its queue, the channel closes the guest-output writer and lets the read
source drain the pipe to EOF before ending the stream. A stream drain barrier
runs on the read queue after one bounded failure snapshot: at most 4 MiB and
50 ms, stopping earlier at `EAGAIN`. The log subscription keeps its 64-chunk
data limit plus one reserved control slot for the marker, so a full data buffer
cannot reject or displace it. A waiter arriving after an earlier marker was
queued waits for that marker and then gets a fresh snapshot and marker of its
own. This keeps a continuous guest writer from delaying failure publication
indefinitely; later bytes continue through normal read callbacks and the
periodic log sync. Each channel is bound to its VM's serial queue and cannot be
attached again after detachment.

| Role | Guest → host data goes to | Host writes |
|---|---|---|
| `.systemConsole` (hvc0) | `ConsoleLogWriter` → `~/Library/Logs/APKRun/vm/console.log` and `BootPhaseDetector` | Only in `apkrun dev console` (interactive debugging) |
| `.log(name)` (e.g. hvc2 logcat) | `ConsoleLogWriter(name)` → `~/Library/Logs/APKRun/guest/<name>-<timestamp>.log` (enabled in developer mode and diagnostics capture; otherwise discarded) | Never |
| `.silent(name)` | Discarded, counted in metrics | Never |
| `.service(name)` | A host-side service substitute ([android-image.md](android-image.md) §7) | Yes |

### 6.4 `ConsoleLogWriter`

- A dedicated bounded `ConsoleChannel` subscription feeds the writer asynchronously, so disk I/O does not run on the pipe reader. The dropped-byte count includes stream drops and guest bytes the writer cannot confirm in every required destination. Bytes awaiting a successful `fsync` after a synchronization error remain counted until a later successful sync. Either condition reports an incomplete log through `vm.consoleWriter`.
- Each record is prefixed with wall-clock time (ISO 8601, milliseconds) and host monotonic time since `VM_START`: `yyyy-MM-dd'T'HH:mm:ss.SSSZ +<seconds>.<milliseconds> `. A partial line is terminated and written at the next 250 ms flush; subsequent bytes start a new record.
- Complete records are written in bounded batches, ending a batch before the 64 KiB guest-byte threshold or a rotation boundary. Each record retains its own timestamp. A guest line longer than the 64 KiB record limit is split into newline-terminated records.
- Rotation at 20 MiB keeps five generations (`console.log`, `console.1.log`, …, `console.4.log`).
- Also writes a per-boot copy `vm/boot-<yyyyMMdd'T'HHmmss'Z'>.log`; the newest five boots are kept.
- Buffered writes are flushed and `fsync`ed every 250 ms or 64 KiB, whichever comes first, and when the VM fails or its console stream closes during stop/reset. Before publishing `.failed`, the controller performs the bounded read-queue snapshot, waits for all bytes yielded to the log subscription through its ordered barrier, then flushes and synchronizes both files. Serial logs must survive a VM or host-process crash (NFR-REL-05).
- The `vm/` directory is mode `0700`; current, rotated, and per-boot log files are mode `0600`.
- Invalid UTF-8 is written as-is (the file is bytes). The os_log mirror escapes it.
- Never parses or redacts. Redaction happens only when a diagnostics bundle is built ([diagnostics.md](diagnostics.md) §6).

## 7. Networking (#006)

- `VMDefinition.network` is an ordered list of NAT NICs, one virtio-net device each. The test Linux guest uses one. The Android definition uses three in Cuttlefish's order: the mobile NIC, the ethernet NIC, and the `virt_wifi` backing NIC ([android-image.md](android-image.md) §7.4). The guest gets an address from VZ's DHCP (typically `192.168.64.0/24`), and DNS is served by the host. No entitlement is needed.
- Each MAC address is generated once (`VZMACAddress.randomLocallyAdministered()`) and stored in `instance.json`, so the guest sees stable interfaces across boots. The Android `virt_wifi` NIC is the exception: its MAC is derived from `androidboot.wifi_mac_prefix`, because the guest's `setup_wifi` rewrites the interface to that MAC and vmnet drops frames from a source MAC it did not assign (observed 2026-10-08).
- `VMController.networkHealthUpdates` publishes the initial network state, each attachment loss, and recovery when a new start clears the failure. The live diagnostics service re-runs `vm.network` from these events and publishes the resulting `healthChanged` event ([diagnostics.md](diagnostics.md) §7.1, #059).
- No inbound port forwarding exists or is needed. Host → guest traffic uses vsock (§8).
- Cuttlefish expects particular interface names (for example, Wi-Fi via `virt_wifi` over `eth2`). One NIC is not enough for the stock image; the three-NIC plan above gave a validated Wi-Fi network in the 2026-10-08 spike, and #095 verifies it ([android-image.md](android-image.md) §7.4).
- Test (#006): T0 uses the fake driver to verify that an attachment disconnect is logged, leaves the VM `running`, and degrades `vm.network`; the next start restores the check. T2 verifies that the Linux test guest gets a DHCP lease and fetches `http://<gateway>:<port>/generate_204` from a host HTTP server (204), while `vm.network` remains passing. T2 needs no Internet access. Resolving a public name and fetching `https://connectivitycheck.gstatic.com/generate_204` is a T3 network check ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.5).

## 8. vsock (#007)

- One `VZVirtioSocketDevice`. Guest CID is 3, host CID is 2.
- **Outbound only in v1:** the host calls `connect(toPort:)` on the device ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- `VMController.connect(vsockPort:timeout:)` wraps the completion handler with a timeout (a `Task` race; VZ has no timeout parameter). A connection that completes after the timeout is closed immediately.
- `VsockConnection` keeps a strong reference to the `VZVirtioSocketConnection`. The file descriptor is only valid while that object lives, so the reference must not be dropped while `DispatchIO` uses the fd. Its serial stream channel reads in ordered 64 KiB chunks and caps unread buffered input at 1 MiB. At the cap it issues a one-byte probe to detect peer EOF without growing the buffer; if the peer sends more data, the connection closes and reads throw `bufferedInputLimitExceeded` after buffered bytes are drained. A single event consumer preserves data and EOF order; the channel low-water limit is one byte so small reads are delivered promptly. `read(upTo:)` checks cancellation before returning buffered data, and pending-read cancellation is arbitrated against data delivery before bytes are consumed. It returns available bytes, `write(_:)` writes the supplied data, and `closed` completes after peer EOF or local close.
- A VZ error in `NSPOSIXErrorDomain` with `ECONNREFUSED` maps to `.vsockPortNotListening(port)`; other errors map to `VMFailure.vsockConnectFailed(port, underlying)`. Virtualization.framework documents that `connect(toPort:)` does nothing if the guest has no listener, so a caller may instead time out. On the reference macOS 27 host, the T2 unused-port probe returned `NSPOSIXErrorDomain` code 54 (`ECONNRESET`), so this case remains `.vsockConnectFailed`. The LinuxGuest readiness probe retries refused, timed-out, and observed startup `ECONNRESET` attempts with backoff for at most five seconds. Its T2 attachment records the typed unused-port outcome and VZ domain/code when the framework calls back with an error; if no callback arrives before the deadline, it records the timeout and that no VZ error was returned. Calling connect when vsock is disabled reports `.vsockDeviceNotConfigured`; if VZ does not expose the configured device, it reports `.vsockDeviceUnavailable`.
- **`VsockLoopbackForwarder`** (generic, used for ADB): listens on `127.0.0.1:<hostPort>` with Network.framework (`NWListener`, `requiredLocalEndpoint` on the loopback address), and for each accepted TCP connection opens `connect(vsockPort:)` and splices both directions. RuntimeCore configures it as `guest 5555 ↔ 127.0.0.1:6520`. It never binds to a non-loopback interface (NFR-SEC-06).
- Test (T2, #007): the test guest runs a small vsock echo server (`socat VSOCK-LISTEN:7000,fork EXEC:cat` from the test initramfs). The test sends 1 MiB and compares, checks the bounded typed result for an unused port, checks disconnect detection when the guest closes, and verifies that `VMController.stop()` closes a live host connection.

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

The VZ delegate uses `VMStartupEventBuffer` to buffer callbacks on the VM queue
while `start` is pending, then returns them with the start completion. This
preserves callback order even when the controller's event-stream consumer is
scheduled later. If start succeeds, the first buffered stop error is classified
as `.startFailed`; subsequent reports are ignored after the terminal
transition. If the start completion itself fails, its error is the
`startFailed` cause and buffered events are discarded.

`KERNEL_START` is recorded by RuntimeCore's `BootPhaseDetector` when the first console line arrives (Linux prints `Booting Linux on physical CPU` first).

### 9.2 Delegate mapping

| VZ callback | Transition |
|---|---|
| `guestDidStop(_:)` | `running/paused/stopping → stopped` |
| `virtualMachine(_:didStopWithError:)` | while `starting`, buffer for `failed(.startFailed(underlying))`; while `running/paused/stopping`, `→ failed(.stoppedWithError(underlying))` |
| `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)` | stays `running`; logged; health `vm.network = degraded` |

For a spontaneous `guestDidStop`, `VMController` records `.stopped` before it
awaits VZ resource release. During an explicit forced stop, the event completes
the stop request but the controller remains `.stopping` until the VZ stop
completion callback arrives; only then are the driver and console attachments
released and the state changed to `.stopped`. Public lifecycle calls therefore
cannot reach a machine that is being detached, and a later `start()` waits for
the release barrier before making a new driver.

The #063 LinuxGuest T2 probe on arm64 macOS 27.0 build 26A428 recorded the
guest console's first boot, reboot marker, and second boot in order. The
serialized VZ callback stream recorded `WillReset` between the custom device's
first and second `DRIVER_OK`; VZ did not report `guestDidStop` in that run. The
harness then explicitly stopped the VM. These are per-stream observations for
the tested OS build, not a cross-version promise.

### 9.3 Stopping Android correctly

`requestGuestStop()` maps to `VZVirtualMachine.requestStop()`, which delivers a **power-button press** through the PL061 GPIO. Android interprets a short power press as "screen off", not "shut down". Therefore:

- RuntimeCore stops Android through the Guest Agent (`Shutdown` RPC → `PowerManager.shutdown`) or, in development, `adb shell reboot -p`. Android powers off via PSCI `SYSTEM_OFF`, which VZ reports as `guestDidStop`.
- If `guestDidStop` has not arrived after 20 s, RuntimeCore calls `VMController.stop()` (forced). A forced stop is logged as a warning, and the next boot runs normally (f2fs/ext4 recover; Android's userdata checkpointing handles the rest).
- A forced stop that has not completed after 10 s fails with `VMFailure.stopTimedOut`, and the state becomes `failed` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §1).
- `requestGuestStop()` is required for the test Linux guest. Its initramfs discovers the PL061 GPIO chip with `gpiodetect`, confirms the active line request with `gpioinfo`, and maps a rising edge on offset 6 to `poweroff -f` (§12). The T2 log verified that event on `gpiochip0` offset 6 on macOS 27.0 (26A428).

### 9.4 Pause and resume

- `pause()` / `resume()` wrap `VZVirtualMachine.pause/resume`. Custom devices get `WillPause`/`WillResume` delegate callbacks; GraphicsCore stops presenting while paused ([graphics.md](graphics.md) §8).
- The guest clock does not advance correctly across a pause as far as Android is concerned. After `resume()`, RuntimeCore asks the Guest Agent to resync wall-clock time ([desktop-integration.md](desktop-integration.md) §9). VirtualMachineCore only reports the pause duration.
- Host sleep: RuntimeCore's `PowerObserver` registers with `IORegisterForSystemPower` (apkrund has no NSApplication, so `NSWorkspace` notifications are not used). It pauses a running VM before acknowledging `kIOMessageSystemWillSleep` and resumes it on `kIOMessageSystemHasPoweredOn` ([runtime-daemon.md](runtime-daemon.md) §6). We don't rely on VZ's implicit behaviour during host sleep (FR-VM-11, #069).

### 9.5 Save and restore

Not used. The VirGL renderer state lives in host GL contexts and cannot be serialized, so the virtio-gpu device sets `supportsSaveRestore = false`, which makes the VM non-saveable (R-07). Cold-boot time is reduced by trimming the boot instead (NFR-PERF-02).

### 9.6 Reset

`failed → stopped` happens only through `reset()`, after the diagnostics capture ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §1). `reset()` releases the `VZVirtualMachine`, closes pipes, and flushes console logs. If a forced-stop framework callback is still pending, reset waits up to the forced-stop timeout. If it remains pending, reset returns `VMFailure.stopTimedOut` and retains the failed VM and its resources; callers may retry after the callback completes. Releasing the VM while Virtualization.framework still owns an in-flight lifecycle call is unsafe.

## 10. Memory and CPU defaults

| Setting | Default | Limits | Source |
|---|---|---|---|
| vCPUs | 4 | 2 … min(8, host performance cores + efficiency cores) | `settings.json` `runtime.cpuCount`, copied into `instance.json` before each boot |
| Memory | 4 GiB | 3 GiB … 50 % of physical memory | `runtime.memoryGiB`, copied into `instance.json` before each boot |
| Balloon | present, idle | — | — |

Changing either takes effect on the next VM start. The UI states that. Measurements for NFR-RES-04 come from #070.

## 11. Sound (#083, #084)

- Output: one `VZVirtioSoundDeviceStreamConfiguration` output stream with `VZHostAudioOutputStreamSink`, attached whenever audio is enabled globally (default on).
- Input: one input stream with `VZHostAudioInputStreamSource`, attached only while at least one package has the microphone integration in effect ([desktop-integration.md](desktop-integration.md) §8.2). The VM configuration is fixed at start, so turning the microphone on for the first package, or off for the last one, needs a runtime restart. The UI says so and offers **Restart Android Now** / **Later** ([host-ui.md](host-ui.md) §7.4).
- Open question for #084 (OQ-29): whether macOS shows the microphone TCC prompt at VM start or only when the guest opens a capture stream. The attach-only-when-enabled rule is chosen so that neither case surprises users.
- Whether the Cuttlefish arm64 kernel carries `virtio_snd` is verified in #083 (OQ-38, [android-image.md](android-image.md) §7.5).

## 12. Test Linux guest (M0: #003–#007)

M0 needs a small Linux guest that exercises every device before Android is involved.

- **Kernel:** a pinned, prebuilt arm64 kernel with virtio PCI, blk, net, console, vsock (`vmw_vsock_virtio_transport`), rng, and DRM virtio-gpu available as built-ins or modules. Candidate: Alpine `linux-virt` (pinned version and SHA-256 in `ThirdParty/ThirdParty.lock.json`). `scripts/fetch-test-linux.sh` downloads it, verifies the hash, and decompresses it if the kernel file is gzip-compressed (the validator rejects compressed kernels, §3). In the pinned 6.18.54 build, `af_packet` is a module required by BusyBox `udhcpc`.
- **initramfs:** built by `scripts/build-test-initramfs.sh` from a pinned Alpine minirootfs plus the needed kernel modules, `socat`, `libgpiod`, `ssl_client` and its OpenSSL libraries, our `/init` script (`Tests/Fixtures/linux/init`), and the network-error classifier (`Tests/Fixtures/linux/network-errors.sh`). `/init`:
  1. mounts proc/sys/dev, loads modules;
  2. unless it will power off after the tests, finds the GPIO chip labeled PL061 and starts `gpiomon` for rising edges on offset 6. It uses `gpioinfo` to verify that the line is held by the monitor before reporting readiness. If the chip or line request is unavailable, it reports an init failure and attempts to power off rather than booting without a stop path;
  3. prints `APKRUN-TEST: boot ok` to `hvc0`, then reports `powerinput ok` after the GPIO line request is confirmed;
  4. runs the device checks requested on the command line (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl`; `rng` is added by #063, `gpu` by #019, and `gpu-hotplug` runs the R-01 spike (IR-256) by #019, `virgl` by the renderer integration step in [graphics.md](graphics.md) §12) and prints `APKRUN-TEST: <name> ok|fail <detail>` per check. The #004 flood check prints its requested `APKRUN-FLOOD <i>` lines followed by `APKRUN-TEST: flood ok lines=<n>`;
  5. prints `APKRUN-TEST: done`, then triggers `apkrun.test.panic=1` when requested. Otherwise it powers off when `apkrun.test.poweroff=1`, or keeps the serial shell available while waiting for the VZ power input. On the rising GPIO edge, it powers off.
- For the `net` check, `/init` brings `eth0` up and runs `udhcpc` with `/etc/udhcpc/apkrun.script`. That script delegates lease setup to Alpine's default udhcpc script and atomically records the assigned address, router, and DNS server. The guest fetches `/generate_204` from a host HTTP server; the T3 variant also resolves `connectivitycheck.gstatic.com` and fetches its HTTPS `generate_204` endpoint. External output is capped at 4 KiB; output beyond the cap fails and cannot be classified as `external`. With no HTTP response, only a recognized BusyBox `wget` socket-connect line or its exact `download timed out` line, without a TLS/client diagnostic, is eligible for `external` classification. Socket-connect failures and download timeouts retain distinct details; only the same classified failure on one retry is skipped. Other HTTPS-client/TLS errors remain test failures. The host harness rejects any failed check record before accepting `done`.
- **Disks:** `Tests/Fixtures/linux/` scripts create a small raw test disk at test time (read-only and read-write variants with known content).
- The T2 test harness (`Tests/IntegrationTests/LinuxGuestTests`) boots this guest with `EmbeddedRuntimeService`-free plumbing (just VirtualMachineCore) and asserts on the `APKRUN-TEST:` lines. Timeout 60 s.
- The pinned Alpine 6.18.54 kernel has `CONFIG_GPIO_CDEV=y` and `CONFIG_GPIO_PL061=m`, but no `CONFIG_KEYBOARD_GPIO`. The initramfs uses the GPIO character-device API through `libgpiod`; it does not depend on the keyboard input driver. A captured T2 console identified `gpiochip0 [20060000.pl061]` and showed a rising event on offset 6 after `requestGuestStop()`. `gpiochip` is resolved by its PL061 label; only the verified offset is monitored.
- The test harness caps parsed-record buffering at 256 records. If a guest emits faster than the consumer can read, missing boot/check/done records fail the test instead of growing host memory without limit.

`TestGuestLineParser` joins serial bytes across read boundaries, ignores
non-marker kernel output, and recognizes `APKRUN-TEST: boot ok`,
`APKRUN-TEST: <name> ok|fail <detail>`, and `APKRUN-TEST: done`. It accepts
LF and CRLF lines, recognizes a marker appended to the final unterminated
kernel message, and parses a final record at EOF. To bound memory when a guest
never terminates a line, records longer than 64 KiB are discarded through the
next newline and counted.

The same guest is reused by #063 (test virtio device) and #019 (virtio-gpu probing with the Linux DRM driver) before Android.

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

Codes, messages, and remediations are listed in [../03-reference/error-catalog.md](../03-reference/error-catalog.md) (domain `vm`). `VZErrorInfo` is a `Sendable` copy of the `NSError` (domain, code, description).

## 14. Logging and metrics

- Subsystem `io.apkrun.vm`, categories `lifecycle`, `config`, `console`, `vsock`, `network`, and `virtio` (VirtioDeviceCore: `DRIVER_OK`, notifications, resets).
- Every transition is logged with the operation ID that caused it.
- `PerfMarker.vmStart` at `start()`. Other boot markers come from RuntimeCore ([diagnostics.md](diagnostics.md) §4).
- Health (`HealthCheck` in DiagnosticsCore): `vm.state`, `vm.network` (warning `vm.networkAttachmentLost` after a disconnect), `vm.consoleWriter` (write errors or dropped log bytes: warning `vm.consoleLogWriteFailed`), `vm.virtualizationSupported`.

## 15. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | Validator rules (§3); state machine edges; MAC/identifier persistence | #002 |
| T0 | VZ delegate buffers start callbacks in order, resumes stream delivery after start completion, and discards buffered events when completion fails; controller maps a buffered start failure | #003 |
| T0 | `ConsoleLogWriter` rotation and fsync policy (with an injected clock and file system) | #004 |
| T1 | `ConsoleChannel` with real pipes (`.log` and `.silent` ports are never written); `ConsoleLogWriter` against a real directory (file modes, rotation on disk) | #004 |
| T1 | the disk rules of §3 with real files and permissions | #005 |
| T1 | `VsockConnection` over a `socketpair` | #007 |
| T2 | Linux test guest: boot + console marker | #003, #004 |
| T2 | Start completion versus delegate callback after VZ machine construction, with a successful guest-stop positive control | #003 |
| T2 | Linux test guest: persisted marker, three-port numbering, forced stop during flood, and kernel panic capture | #004 |
| T2 | block read-only/read-write | #005 |
| T2 | DHCP lease, host HTTP 204 endpoint, and live `vm.network` health | #006 |
| T2 | vsock echo, unused-port result, guest disconnect, readiness, VM-stop cleanup | #007 |
| T2 | console port numbering | #004, #095 |
| T2 | pause/resume | #069 |
| T3 | Gate check G1 (`Tests/AcceptanceTests/G1LinuxBoot`, [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §5): the pass conditions of [../04-plan/roadmap.md](../04-plan/roadmap.md) §2, 10 boots in a row | #003 |
| T3 | Network check: the Linux test guest resolves a public name and fetches `https://connectivitycheck.gstatic.com/generate_204`; after one retry, repeated DNS, recognized socket-connect failures, or the exact BusyBox `wget: download timed out` error without TLS/client diagnostics are classified as `external` when no HTTP response was received (nightly) | #006 |

## 16. Open items

| Item | Plan |
|---|---|
| VZ serial port numbering is not documented (§6.2) | #004 checks three ports on the test Linux guest, #095 all 20 ports. If the order is not the array order, `ConsolePortPlan` re-orders the array |
| Device order and the PCI host bridge's platform device name (§5) | discovered by #011 and committed to `Images/reference/vz/<macOS build>/topology.txt`. Nothing relies on `vdX` letters or slot numbers |
| Whether `VZVirtualMachineConfiguration.validate()` runs in an unentitled `swift test` process (§3) | #002 verified that validation returns an explicit missing-entitlement error on an unentitled process; T0 uses the framework-validator fake, and the signed `IntegrationTests` bundle hosted by `APKRunTestHost` exercises the entitled path ([../05-development/build-system.md](../05-development/build-system.md) §2.2) |
| How VZ reports a start failure: the `start` completion error, `didStopWithError`, or both (§9.1, §9.2) | #003 records the completion result and delegate events for configuration rejection and a missing kernel after VZ driver creation. If #005 introduces a start-failure case from disk attachment, record that separately there. A second report of the same failure must not cause a second transition |
| Whether macOS shows the microphone prompt at VM start or at the first capture (OQ-29, §11) | #084. The input stream is attached only while a package uses it, so neither answer changes the design |
| Whether the stock Cuttlefish arm64 kernel carries `virtio_snd` (OQ-38, §11) | #083. If not, the custom image adds it ([android-image.md](android-image.md) §7.5) |
| Virtualization.framework behavior changes on new macOS builds (R-16) | the T2 suite and the topology check run on every new macOS build ([../04-plan/risks.md](../04-plan/risks.md)) |

## 17. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the guest (test Linux guest or Android image build), and the result.

| Question | Task | Result |
|---|---|---|
| Alpine ARM64 Linux boot marker and guest power-off | #003 | 2026-09-29, MacBook Pro, macOS 27.0 (26A428): `LinuxGuestBootTests.testBootMarkerAndGuestPowerOff` passed on the pinned guest with an Apple Development-signed test host |
| LinuxGuest T2 suite using artifacts outside the checkout | #003 | 2026-09-30, MacBook Pro, macOS 27.0 (26A428): the signed test host read `/tmp/apkrun-test-linux-explicit-20260930` from its Info.plist without a file-access prompt; boot marker, failed-start/reset, forced-stop, and bounded-capture tests passed; `requestGuestStop()` timed out after 10 s, then forced stop succeeded |
| TCC path-guard checks for LinuxGuest artifact paths | #003 | 2026-09-30, MacBook Pro, macOS 27.0 (26A428): seven script tests rejected direct `~/Documents` paths, symlink aliases, a missing-component/parent-reference alias, and a caller-overridden `HOME`; three path-only `LinuxGuestArtifactDirectoryTests` XTests passed (no VM start) with artifacts, DerivedData, and xcresult under `/tmp`; the default-path symlink into Documents was rejected; no file-access prompt appeared |
| PL061 power input and G1 ten-boot behavior | #003 | 2026-09-30, MacBook Pro, macOS 27.0 (26A428): hvc0 showed a rising event on `gpiochip0` offset 6; after adding a line-owner readiness check, all LinuxGuest T2 tests and direct G1 acceptance on branch `codex` passed, including ten request-stop boots. The signed CLI smoke from `/tmp` printed boot/powerinput/done and exited 0 without a file-access prompt. The clean-`main` `scripts/run-gate.sh G1` run remains pending |
| G1 signed acceptance regression on branch `codex` | #003 | 2026-10-07 UTC, arm64 MacBook Pro, macOS 27.0.1 (26A434), commit `c497480`: the signed `AcceptanceTests` G1 configuration passed 4 tests, skipped 1 test assigned to the Network configuration, and had 0 failures. `testTenBootsStopThroughTheGuestPowerButton` and `testFailedStartCanBeReset` both passed. The skipped case was `testGuestResolvesDNSAndReachesExternalHTTPSProbe`. Result bundle `/tmp/apkrun-g1-codex-current.xcresult`. This was a direct test-plan run on `codex`; the clean-`main` `scripts/run-gate.sh G1` gate remains pending |
| Boot marker stability after one missing serial record | #003 | 2026-09-30, MacBook Pro, macOS 27.0 (26A428): one full T2 run's raw hvc0 attachment contained `APKRUN-TEST: done` but not `boot ok`; an isolated signed T2 run and 10 consecutive repetitions then passed, as did the boot test in the final full-suite rerun. The missing record was not reproduced; see IR-052 |
| `validate()` without the virtualization entitlement | #002 | 2026-10-07 UTC, arm64 Mac17,9, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a): the opt-in `swift test` probe used the production builder with the pinned kernel and initramfs (SHA-256 values recorded in §3); `SecTaskCopyValueForEntitlement` confirmed no virtualization entitlement and no query error; `validate()` returned `VZErrorDomain/2` with an explicit missing-entitlement failure reason; the test passed; no `VZVirtualMachine` was created |
| Error reporting of a failed start (completion vs delegate) | #003 | 2026-10-07 UTC, arm64 MacBook Pro, macOS 27.0.1 (26A434): signed T2 positive control completed `start` successfully, recorded `guestDidStop`, and reached VZ state `stopped`; after validating and constructing a VZ machine, deleting its kernel made `start` complete with `VZErrorDomain/2`, with no delegate callback observed during the following 2 seconds, and the VM reached terminal state `error`. The source probe and production configuration-rejection/reset test passed 2/2; result bundle `/tmp/apkrun-start-probe-final-3.xcresult`. This is a bounded observation for this build, not proof that no later callback can occur. T0 exercises production VZ delegate buffer/stream routing and separately verifies that buffered `didStopWithError` maps to `.startFailed` with one terminal transition |
| Full LinuxGuest regression after start-failure event buffering | #003 | 2026-10-07 UTC, arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), commit `d31e7e3`: the signed `LinuxGuest` T2 configuration passed 33/33 tests with `APKRUN_CI=1`; no failures or skips. Result bundle `/tmp/apkrun-linuxguest-full-final.xcresult`. This is branch verification; the clean-`main` G1 gate remains pending |
| Serial port numbering with three ports | #004 | 2026-10-06 UTC, arm64 MacBook Pro, macOS 27.0 (26A428): signed `LinuxGuestConsoleTests` passed; guest-visible hvc1/hvc2 numbering matched attachment-array order |
| Read-only disks are read-only in the guest | #005 | 2026-10-05 UTC, arm64 MacBook Pro, macOS 27.0 (26A428): `LinuxGuestBlockTests.testReadOnlyDiskAndReadWriteDiskPersistAcrossNewVM` passed; the guest verified the read-only image and rejected writes |
| Disk persistence, journal recovery, read-only enforcement, and guest-visible device order | #005 | 2026-10-05 UTC, arm64 MacBook Pro, macOS 27.0 (26A428): 80 `VirtualMachineCoreTests` and 18 `VirtualMachineCoreSystemTests` passed; the pinned initramfs SHA-256 is `0f50a6b9abcfa8229c7686180b8edf365e1f204bed4eeccc435b4f0e729b4f43`; signed `LinuxGuestBlockTests` passed 3/3, including token persistence after a new VM, forced-stop ext4 journal replay, and both normal and reversed guest-visible serial orders (`/tmp/apkrun-blk-signed-T2.xcresult` on the test host) |
| NAT network: DHCP lease and a host-local HTTP fetch | #006 | 2026-10-06, arm64 MacBook Pro, macOS 27.0 (26A428): signed `LinuxGuestNetworkTests` passed 3/3; `hvc0` showed a DHCP lease, `http=204`, and `done`; all captured `vm.network` updates were available and the health check passed |
| NAT network: external DNS and HTTPS fetch | #006 | 2026-10-06, arm64 MacBook Pro, macOS 27.0 (26A428): signed run `apkrun-network-t3-20261006-a.xcresult` returned public DNS, `http=204`, `ext=204`, and `done`; final run `apkrun-network-t3-20261006-g.xcresult` had 2 passed, 0 failed, and 1 `external` skip after `wget: download timed out` repeated on both attempts. The scheduled `main` nightly has not run |
| vsock echo, unused-port error, guest disconnect, listener readiness, and VM-stop cleanup | #007 | 2026-10-06, arm64 MacBook Pro, macOS 27.0 (26A428): 102 `VirtualMachineCoreTests`, 23 `VirtualMachineCoreSystemTests`, and the signed `LinuxGuestVsockTests` T2 suite (5/5) passed. T1 filled the 1 MiB read buffer before peer EOF and verified the one-byte probe detected closure; a separate case verified over-limit input closes with `bufferedInputLimitExceeded`. T2 echoed 1 MiB, connected to both readiness ports, observed guest close within 1 s, and confirmed `VMController.stop()` closes a live connection. Port 7999 returned `vm.vsockConnectFailed` with `NSPOSIXErrorDomain` code 54 (`ECONNRESET`); the test attachment records the typed result and VZ log. Initial `ECONNRESET` connect attempts to ports 7000/7001 recovered on retry. Final result bundle: `/private/tmp/apkrun-vsock-readiness-final.xcresult` |
| Signed LinuxGuest regression, log routing, and VZ queue confinement at the #003 acceptance commit | #003 | 2026-10-08 UTC, arm64 Mac17,9, macOS 27.0.1 (26A434), Xcode 27.0: the signed `LinuxGuest` suite passed 29 of 29 with `APKRUN_CI=1` at `ef9b729`, with no skips, and 29 of 29 at `d98823f` before the two fixes. Live unified-log transitions are `io.apkrun.vm` / `lifecycle` with operation IDs (`d98823f` had shown `health`). Result bundles `/tmp/apkrun-003-linuxguest.xcresult` and `/tmp/apkrun-003-linuxguest-2.xcresult`. Records: M00 #003 Notes, IR-281, IR-282 |
| Missing Linux test artifacts: skip without `APKRUN_CI`, fail with it | #003 | 2026-10-08 UTC, same host: with an empty `APKRUN_TEST_LINUX_DIR`, the `LinuxGuest` suite reported 29 tests with 24 skipped and 0 failures, and with `APKRUN_CI=1` the same 24 tests failed. Each message names `scripts/fetch-test-linux.sh` and `scripts/build-test-initramfs.sh` |
| G1 acceptance test plan on the `codex` branch | #003 | 2026-10-08 UTC, same host, commit `ef9b729`: 5 tests, 1 configuration-scoped skip (the Network case), 0 failures. `testTenBootsStopThroughTheGuestPowerButton` passed in 3.079 s and `testFailedStartCanBeReset` passed. This run does not close G1, which needs the reference Mac and a clean `main` (IR-283) |
| `apkrun dev linux` live exits and instance lock | #003 | 2026-10-08 UTC, same host, embedded CLI built with `EmbeddedRuntime` and signed with `apkrun-dev.entitlements`, at `ef9b729`: smoke exit 0 with `boot ok`, `powerinput ok`, `done`; `--tests rng` exit 0 with `rng ok`; a second instance started while the first held the lock exited 75 (`runtime.instanceLocked`); `--tests nosuchcheck` exited 1 (`runtime.devLinuxCheckFailed`), with the failing line on stdout only (IR-286) |
| VZ console device limit; Android on 10 + 10 ports; `boot_devices`; three NICs on the stock image | spike (IR-306) | 2026-10-08 UTC, arm64 Mac17,9 (M5 Pro), macOS 27.0.1 (26A434), build 16373615: `validate()` accepts 10 single-port console devices and rejects 11; 10 single-port devices plus one multiport device with 10 console ports validate and boot. Android saw hvc0–hvc19, and the sensors HAL's `/dev/hvc18` frames arrived on port 18. `/sys/block/vda` is under `40000000.pci`. With three NAT NICs and `virt_wifi`, `wlan0` got a DHCP lease and a validated network. Guest `reboot` restarts inside the same `VZVirtualMachine`; `reboot -p` ends in `guestDidStop`. Harness: `Experiments/vz-android-boot/` |
| Guest-visible topology and `androidboot.boot_devices` value | #011 | 2026-10-09 UTC, macOS 27.0.1 (26A434): signed `LinuxGuestAndroidDiskLayoutTests.testAndroidDiskLayout` passed with the two Android disks; both are under `/sys/devices/platform/40000000.pci/pci0000:00/`, with 512-byte logical blocks and the serials `apkrun-ro` and `apkrun-rw`. The capture is `Images/reference/vz/26A434/topology.txt` (§5) |
| Serial port numbering with 20 ports, verified with markers; network on the stock image | #095 | pending (§6.2, §7). The spike observation is in the first row |
| Pause and resume across host sleep | #069 | pending (§9.4) |
| `virtio_snd` in the stock kernel | #083 | pending (OQ-38) |
| Microphone prompt timing | #084 | pending (OQ-29) |
