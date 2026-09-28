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
    public var label: String // VZVirtualMachineConfiguration.label (macOS 27), e.g. "APKRun Android"
    public var cpuCount: Int
    public var memorySize: UInt64 // bytes, multiple of 1 MiB
    public var machineIdentifier: Data? // VZGenericMachineIdentifier.dataRepresentation; nil = create new
    public var boot: BootDefinition
    public var disks: [DiskDefinition] // attached in array order
    public var network: NetworkDefinition? // nil = no NIC
    public var vsockEnabled: Bool
    public var consolePorts: [ConsolePortDefinition] // attached in array order; index 0 must be the system console
    public var entropy: Bool // virtio-rng, default true
    public var memoryBalloon: Bool // default true (device present, not driven in v1)
    public var sound: SoundDefinition? // nil = no virtio-snd
    public var customDevices: [any VirtioDeviceModel] // from VirtioDeviceCore / GraphicsCore
}

public enum BootDefinition: Sendable {
    case linux(kernel: URL, initialRamdisk: URL?, commandLine: String)
}

public struct DiskDefinition: Sendable, Codable, Equatable {
    public var url: URL
    public var readOnly: Bool
    public var caching: DiskCaching //.automatic (default) |.cached |.uncached
    public var synchronization: DiskSync //.full (default for rw) |.fsync |.none (tests only)
    public var identifier: String? // VZVirtioBlockDeviceConfiguration.blockDeviceIdentifier (≤ 20 ASCII), visible as /sys/block/vdX/serial
    public var role: String // for logs only, e.g. "os", "persistent", "userdata"
}

public enum NetworkDefinition: Sendable, Codable, Equatable {
    case nat(macAddress: String) // locally administered, persisted per instance
}

public struct ConsolePortDefinition: Sendable, Codable, Equatable {
    public var role: ConsoleRole //.systemConsole |.log(name) |.silent(name) |.service(name)
}

public struct SoundDefinition: Sendable, Codable, Equatable {
    public var output: Bool // VZHostAudioOutputStreamSink
    public var input: Bool // VZHostAudioInputStreamSource (microphone, #084)
}
```

`VMDefinition` is a value. ImageCore's `AndroidBootPlanner` builds it as `AndroidBootPlan.definition` from the image manifest and `InstanceConfiguration` ([android-image.md](android-image.md) §9.1). RuntimeCore adds the GPU device, and the value is never mutated after validation. `VMDefinition.summary` (a `Codable` projection without device objects) is written to the log and to diagnostics bundles.

```swift
public actor VMController {
    public init(definition: ValidatedVMDefinition, diagnostics: DiagnosticsContext)

    public var state: VMState { get }
    public nonisolated let stateUpdates: AsyncStream<VMState>

    public func start async throws
    public func pause async throws
    public func resume async throws
    public func stop async throws // forced stop (VZ stop)
    public func requestGuestStop async throws // VZ requestStop (power-button event); see §9.3
    public func reset async throws // failed → stopped only; see §9.6

    public func connect(vsockPort: UInt32, timeout: Duration) async throws -> VsockConnection
    public nonisolated func console(_ role: ConsoleRole) -> ConsoleChannel // read stream + optional writer
}

public struct ValidatedVMDefinition: Sendable { /* only VMDefinitionValidator can create it */ }
```

  is followed literally: the controller is an actor, the state is explicit (`VMState`), and state is never inferred from a nil `VZVirtualMachine`.

## 3. Validation (`VMDefinitionValidator`, #002)

`VMDefinitionValidator.validate(_:) throws(VMConfigurationFailure) -> ValidatedVMDefinition` runs every rule below, then builds the `VZVirtualMachineConfiguration` and calls its `validate`. Errors are collected, not thrown on the first one, so `apkrun doctor` can print them all:

- One broken rule is thrown as its own case.
- Several broken rules are thrown as one `.configurationInvalid([VMConfigurationFailure])`, a flat list in rule order ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §5.2).
- `findings(_:) -> [VMConfigurationFailure]` returns the same list without throwing, for `apkrun doctor`.

| Rule | Failure case |
|---|---|
| `VZVirtualMachineConfiguration.minimumAllowedCPUCount ≤ cpuCount ≤ min(maximumAllowedCPUCount, host active processor count)` | `.cpuCountOutOfRange(requested, allowed)` |
| `memorySize` is a multiple of 1 MiB, within `minimumAllowedMemorySize…maximumAllowedMemorySize` | `.memoryOutOfRange` |
| `memorySize ≤ 50 %` of physical memory (NFR-RES-01) | `.memoryExceedsHostCap(cap)` |
| Kernel exists and is an **uncompressed arm64 `Image`**: bytes 0x38–0x3B are `ARM\x64`. gzip (`1f 8b`), lz4 (`02 21 4c 18` / `04 22 4d 18`), and EFI zboot (`MZ`, then `zimg` at offset 4) are rejected, and so is anything else, including other architectures (VZLinuxBootLoader has no decompressor on arm64; the VM would hang) | `.kernelMissing(url)`, `.kernelNotUncompressedImage(detected)` with `detected` one of `.gzip`, `.lz4`, `.zboot`, `.unknown` |
| initrd exists if given, size ≤ 512 MiB | `.initrdMissing`, `.initrdTooLarge` |
| Command line ≤ 2048 bytes, ASCII | `.commandLineInvalid` |
| Every disk URL exists and is a regular file. Android sparse images (magic `0xED26FF3A`) are rejected: VZ needs raw (or ASIF) images | `.diskMissing(role)`, `.diskIsAndroidSparse(role)` |
| Every disk is readable by the process | `.diskNotReadable(role)` |
| No disk URL appears twice, compared after resolving symlinks (VZ would open it twice) | `.duplicateDisk(role)` |
| A read-write disk is writable by the process; a read-only disk is opened read-only | `.diskNotWritable(role)` |
| `identifier` ≤ 20 ASCII characters | `.diskIdentifierInvalid` |
| `consolePorts` is non-empty and `[0]` is `.systemConsole` | `.missingSystemConsole` |
| MAC address is a valid locally administered unicast address | `.invalidMACAddress` |
| `machineIdentifier`, when present, decodes with `VZGenericMachineIdentifier(dataRepresentation:)` | `.machineIdentifierInvalid` |
| Custom device count ≤ what VZ accepts; each model's configuration validates (VirtioDeviceCore) | `.customDeviceInvalid(name, reason)` |
| `sound.input == true` only when `NSMicrophoneUsageDescription` is present in the host bundle | `.microphoneUsageDescriptionMissing` |
| `VZVirtualMachineConfiguration.validate` | `.frameworkRejected(underlying)` |

Tests (T0): one test per rule, including kernel magic detection with real gzip, lz4, and `Image` headers (fixture headers are 64 bytes, not whole kernels).

## 4. Mapping to Virtualization.framework

| `VMDefinition` | VZ configuration | Notes |
|---|---|---|
| platform | `VZGenericPlatformConfiguration` with `machineIdentifier` | The identifier is created once per instance and stored in `instance.json`. Nested virtualization stays off. |
| `boot` | `VZLinuxBootLoader(kernelURL:)`, `initialRamdiskURL`, `commandLine` | Direct kernel boot ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)) |
| `cpuCount`, `memorySize` | `cpuCount`, `memorySize` | |
| `disks[i]` | `VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:))`, `blockDeviceIdentifier` | Order preserved in `storageDevices` |
| `network` | `VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment`, `macAddress` | No bridged networking (restricted entitlement) |
| `vsockEnabled` | one `VZVirtioSocketDeviceConfiguration` | VZ allows one vsock device per VM |
| `consolePorts[i]` | one `VZVirtioConsoleDeviceSerialPortConfiguration` each, with `VZFileHandleSerialPortAttachment` | See §6 for why single-port devices are used |
| `entropy` | `VZVirtioEntropyDeviceConfiguration` | |
| `memoryBalloon` | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | Not driven in v1. Present so a later release can reclaim memory without an image change |
| `sound` | `VZVirtioSoundDeviceConfiguration` with output and/or input streams | [desktop-integration.md](desktop-integration.md) §8 |
| `customDevices` | `customVirtioDevices` (macOS 27) | Built by VirtioDeviceCore from each `VirtioDeviceModel` |
| (not used) | `graphicsDevices`, `keyboards`, `pointingDevices`, `directorySharingDevices`, `usbControllers` | Graphics is our own virtio-gpu; input is guest-side injection ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)); file sharing goes through the Guest Agent ([desktop-integration.md](desktop-integration.md) §6) |

All VZ objects are created and called on the controller's private serial `DispatchQueue` (`io.apkrun.vm.queue`), as VZ requires. The actor hops onto that queue with `withCheckedThrowingContinuation`.

## 5. Guest-visible topology

What the guest sees on VZ (from a captured VZ device tree; to be confirmed by #011 on our hardware):

- One `pci-host-ecam-generic` PCIe host bridge (ECAM at `0x40000000`). There are no virtio-mmio nodes, so every virtio device is a PCI function.
- GICv3, PSCI via `hvc`, the arm64 architected timer, PL031 RTC, a PL061 GPIO wired to `gpio-keys` as the power button.
- No PL011 UART. The console is `hvc0` (virtio-console).
- RAM starts at `0x70000000`.

Consequences for Android:

- `androidboot.boot_devices` must name the PCI host bridge's platform device (crosvm uses `10000.pci`; the VZ value is discovered in #011 from `readlink -f /sys/block/vda`). All virtio-blk disks sit under that one bridge, so a single value covers `os.img`, `persistent.img`, and `userdata.img` ([android-image.md](android-image.md) §5.3).
- Device order inside the bridge follows the configuration arrays, but nothing in APKRun relies on `vdX` letters or PCI slot numbers. Android finds partitions by GPT name, and our code finds disks by `blockDeviceIdentifier` if it ever needs to.
- The discovered topology (`lspci -nn`, `/sys/bus/pci/devices`, `/proc/device-tree` dump) is committed to `Images/reference/vz/<macOS build>/topology.txt` by #011 and re-checked by the T2 suite on each new macOS build (R-16).

## 6. Console ports

### 6.1 Why single-port devices

Cuttlefish's HALs open fixed device nodes (`/dev/hvc3` for keymaster and so on; the full map is in [android-image.md](android-image.md) §7). crosvm creates one single-port virtio-console device per port. Linux numbers them `hvc0…hvcN` in probe order. We do the same with `VZVirtioConsoleDeviceSerialPortConfiguration`, one per entry of `consolePorts`.

The alternative, one `VZVirtioConsoleDeviceConfiguration` with named multiport ports, gives `/dev/vportNpM` nodes, which the Cuttlefish HALs don't use. It stays available for our own future use (named ports would be self-describing).

### 6.2 Port numbering must be verified, not assumed

Apple does not document the order in which VZ assigns PCI functions to serial ports. So:

1. #004 (M0) attaches three ports to the test Linux guest: `[.systemConsole,.service("test-1"),.service("test-2")]`. The host writes `APKRUN-PORT-<i>\n` into the `.service` ports 1 and 2 only, because it never writes to the system console outside `apkrun dev console` (§6.3). Port 0 is identified by the kernel console output that arrives on its pipe. The guest's `/init` reads `/dev/hvc1` and `/dev/hvc2` and prints which marker it saw. The mapping is asserted in a T2 test.
2. #095 repeats this with all 20 ports, using a small guest-side probe run from the test initramfs, before the Android boot relies on it.
3. If VZ numbering is not the array order, `ConsolePortPlan` (RuntimeCore) re-orders the array so that the guest numbering matches the Cuttlefish map. The mapping is data, never scattered constants.

### 6.3 Attachments and sinks

Each port gets a `VZFileHandleSerialPortAttachment` built from two pipes:

- **Guest → host:** the guest writes into the pipe's write end. `ConsoleChannel` reads the read end with `DispatchIO` and publishes an `AsyncStream<Data>`.
- **Host → guest:** a second pipe. For `.systemConsole` and `.service` ports the host may write. For `.log` and `.silent` ports the host never writes and keeps the write end open, so guest reads block instead of seeing EOF.

| Role | Guest → host data goes to | Host writes |
|---|---|---|
| `.systemConsole` (hvc0) | `ConsoleLogWriter` → `~/Library/Logs/APKRun/vm/console.log` and `BootPhaseDetector` | Only in `apkrun dev console` (interactive debugging) |
| `.log(name)` (e.g. hvc2 logcat) | `ConsoleLogWriter(name)` → `~/Library/Logs/APKRun/guest/<name>-<timestamp>.log` (enabled in developer mode and diagnostics capture; otherwise discarded) | Never |
| `.silent(name)` | Discarded, counted in metrics | Never |
| `.service(name)` | A host-side service substitute ([android-image.md](android-image.md) §7) | Yes |

### 6.4 `ConsoleLogWriter`

- One line per record, prefixed with wall-clock time (ISO 8601, ms) and host monotonic time since `VM_START`.
- Rotation at 20 MiB, 5 generations (`console.log`, `console.1.log`, …).
- Also writes a per-boot copy `vm/boot-<timestamp>.log`; the last 5 boots are kept.
- Buffered writes are flushed and `fsync`ed every 250 ms or 64 KiB, whichever comes first, and on `VMState.failed`. Serial logs must survive a VM or host-process crash (NFR-REL-05).
- Invalid UTF-8 is written as-is (the file is bytes). The os_log mirror escapes it.
- Never parses or redacts. Redaction happens only when a diagnostics bundle is built ([diagnostics.md](diagnostics.md) §6).

## 7. Networking (#006)

- One virtio-net device with a NAT attachment. The guest gets an address from VZ's DHCP (typically `192.168.64.0/24`), and DNS is served by the host. No entitlement is needed.
- The MAC address is generated once (`VZMACAddress.randomLocallyAdministered`) and stored in `instance.json`, so the guest sees a stable interface across boots.
- No inbound port forwarding exists or is needed. Host → guest traffic uses vsock (§8).
- Cuttlefish expects particular interface names (for example, Wi-Fi via `virt_wifi` over a renamed ethernet interface). Whether the stock image brings up connectivity on VZ's single NIC is checked in #095 ([android-image.md](android-image.md) §7.4).
- Test (T2, #006): the Linux test guest gets a DHCP lease and fetches `http://<gateway>:<port>/generate_204` from an HTTP server that the test runs on the host (expects 204), and the attachment's disconnect delegate callback is logged. T2 needs no Internet access. Resolving a public name and fetching `https://connectivitycheck.gstatic.com/generate_204` is a T3 network check ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.5).

## 8. vsock (#007)

- One `VZVirtioSocketDevice`. Guest CID is 3, host CID is 2.
- **Outbound only in v1:** the host calls `connect(toPort:)` on the device ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- `VMController.connect(vsockPort:timeout:)` wraps the completion handler with a timeout (a `Task` race; VZ has no timeout parameter). A connection that completes after the timeout is closed immediately.
- `VsockConnection` keeps a strong reference to the `VZVirtioSocketConnection`. The file descriptor is only valid while that object lives, so the reference must not be dropped while `DispatchIO` uses the fd.
- Errors map to `VMFailure.vsockConnectFailed(port, underlying)`. A refused connection (nobody listening in the guest) is `.vsockPortNotListening(port)`. Callers treat it as "not ready yet" and retry with backoff.
- **`VsockLoopbackForwarder`** (generic, used for ADB): listens on `127.0.0.1:<hostPort>` with Network.framework (`NWListener`, `requiredLocalEndpoint` on the loopback address), and for each accepted TCP connection opens `connect(vsockPort:)` and splices both directions. RuntimeCore configures it as `guest 5555 ↔ 127.0.0.1:6520`. It never binds to a non-loopback interface (NFR-SEC-06).
- Test (T2, #007): the test guest runs a small vsock echo server (`socat VSOCK-LISTEN:7000,fork EXEC:cat` from the test initramfs). The test sends 1 MiB and compares, checks timeout behaviour against an unused port, and checks disconnect detection when the guest closes.

## 9. Lifecycle

### 9.1 Start

```text
start
state: stopped → starting (PerfMarker VM_START)
build VZVirtualMachine on the VM queue with the validated configuration
attach delegates: VZVirtualMachineDelegate, VZNetworkDeviceAttachment disconnect handling
vm.start { result }
success → state: running
failure → state: failed(.startFailed(underlying))
```

`KERNEL_START` is recorded by RuntimeCore's `BootPhaseDetector` when the first console line arrives (Linux prints `Booting Linux on physical CPU` first).

### 9.2 Delegate mapping

| VZ callback | Transition |
|---|---|
| `guestDidStop(_:)` | `running/paused/stopping → stopped` |
| `virtualMachine(_:didStopWithError:)` | `→ failed(.stoppedWithError(underlying))` |
| `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)` | stays `running`; logged; health `vm.network = degraded` |

### 9.3 Stopping Android correctly

`requestGuestStop` maps to `VZVirtualMachine.requestStop`, which delivers a **power-button press** through the PL061 GPIO. Android interprets a short power press as "screen off", not "shut down". Therefore:

- RuntimeCore stops Android through the Guest Agent (`Shutdown` RPC → `PowerManager.shutdown`) or, in development, `adb shell reboot -p`. Android powers off via PSCI `SYSTEM_OFF`, which VZ reports as `guestDidStop`.
- If `guestDidStop` has not arrived after 20 s, RuntimeCore calls `VMController.stop` (forced). A forced stop is logged as a warning, and the next boot runs normally (f2fs/ext4 recover; Android's userdata checkpointing handles the rest).
- A forced stop that has not completed after 10 s fails with `VMFailure.stopTimedOut`, and the state becomes `failed` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §1).
- `requestGuestStop` exists for the test Linux guest, whose init powers off on the power key.

### 9.4 Pause and resume

- `pause` / `resume` wrap `VZVirtualMachine.pause/resume`. Custom devices get `WillPause`/`WillResume` delegate callbacks; GraphicsCore stops presenting while paused ([graphics.md](graphics.md) §8).
- The guest clock does not advance correctly across a pause as far as Android is concerned. After `resume`, RuntimeCore asks the Guest Agent to resync wall-clock time ([desktop-integration.md](desktop-integration.md) §9). VirtualMachineCore only reports the pause duration.
- Host sleep: RuntimeCore's `PowerObserver` registers with `IORegisterForSystemPower` (apkrund has no NSApplication, so `NSWorkspace` notifications are not used). It pauses a running VM before acknowledging `kIOMessageSystemWillSleep` and resumes it on `kIOMessageSystemHasPoweredOn` ([runtime-daemon.md](runtime-daemon.md) §6). We don't rely on VZ's implicit behaviour during host sleep (FR-VM-11, #069).

### 9.5 Save and restore

Not used. The VirGL renderer state lives in host GL contexts and cannot be serialized, so the virtio-gpu device sets `supportsSaveRestore = false`, which makes the VM non-saveable (R-07). Cold-boot time is reduced by trimming the boot instead (NFR-PERF-02).

### 9.6 Reset

`failed → stopped` happens only through `reset`, after the diagnostics capture ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §1). `reset` releases the `VZVirtualMachine`, closes pipes, and flushes console logs.

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

- **Kernel:** a pinned, prebuilt arm64 kernel with virtio PCI, blk, net, console, vsock (`vmw_vsock_virtio_transport`), rng, and DRM virtio-gpu available as built-ins or modules. Candidate: Alpine `linux-virt` (pinned version and SHA-256 in `ThirdParty/ThirdParty.lock.json`). `scripts/fetch-test-linux.sh` downloads it, verifies the hash, and decompresses it if the kernel file is gzip-compressed (the validator rejects compressed kernels, §3).
- **initramfs:** built by `scripts/build-test-initramfs.sh` from a pinned Alpine minirootfs plus the needed kernel modules, `socat`, and our `/init` script (`Tests/Fixtures/linux/init`). `/init`:
  1. mounts proc/sys/dev, loads modules;
  2. prints `APKRUN-TEST: boot ok` to `hvc0`;
  3. runs the device checks requested on the command line (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl`; `rng` is added by #063, `gpu` by #019, `virgl` by the renderer integration step in [graphics.md](graphics.md) §12) and prints `APKRUN-TEST: <name> ok|fail <detail>` per check;
  4. prints `APKRUN-TEST: done` and either powers off (`apkrun.test.poweroff=1`) or starts a shell on hvc0.
- **Disks:** `Tests/Fixtures/linux/` scripts create a small raw test disk at test time (read-only and read-write variants with known content).
- The T2 test harness (`Tests/IntegrationTests/LinuxGuestTests`) boots this guest with `EmbeddedRuntimeService`-free plumbing (just VirtualMachineCore) and asserts on the `APKRUN-TEST:` lines. Timeout 60 s.

The same guest is reused by #063 (test virtio device) and #019 (virtio-gpu probing with the Linux DRM driver) before Android.

## 13. Errors

```swift
public enum VMConfigurationFailure: APKRunError {
    /* one case per §3 rule */
    case configurationInvalid([VMConfigurationFailure]) // several rules broken (§3)
}

public enum VMFailure: APKRunError {
    case invalidTransition(from: VMState, to: VMState)
    case startFailed(underlying: VZErrorInfo)
    case stoppedWithError(underlying: VZErrorInfo)
    case pauseFailed(underlying: VZErrorInfo)
    case resumeFailed(underlying: VZErrorInfo)
    case stopTimedOut
    case vsockConnectFailed(port: UInt32, underlying: VZErrorInfo)
    case vsockPortNotListening(port: UInt32)
    case vsockConnectTimedOut(port: UInt32)
    case virtualizationUnavailable // VZVirtualMachineConfiguration.isSupported == false or entitlement missing
    // health findings (§14), never thrown
    case networkAttachmentLost // vm.network: the NAT attachment was disconnected (§9.2)
    case consoleLogWriteFailed // vm.consoleWriter: writing a console log failed
}
```

Codes, messages, and remediations are listed in [../03-reference/error-catalog.md](../03-reference/error-catalog.md) (domain `vm`). `VZErrorInfo` is a `Sendable` copy of the `NSError` (domain, code, description).

## 14. Logging and metrics

- Subsystem `io.apkrun.vm`, categories `lifecycle`, `config`, `console`, `vsock`, `network`, and `virtio` (VirtioDeviceCore: `DRIVER_OK`, notifications, resets).
- Every transition is logged with the operation ID that caused it.
- `PerfMarker.vmStart` at `start`. Other boot markers come from RuntimeCore ([diagnostics.md](diagnostics.md) §4).
- Health (`HealthCheck` in DiagnosticsCore): `vm.state`, `vm.network` (warning `vm.networkAttachmentLost` after a disconnect), `vm.consoleWriter` (errors while writing logs: warning `vm.consoleLogWriteFailed`), `vm.virtualizationSupported`.

## 15. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | Validator rules (§3); state machine edges; MAC/identifier persistence | #002 |
| T0 | `ConsoleLogWriter` rotation and fsync policy (with an injected clock and file system) | #004 |
| T1 | `ConsoleChannel` with real pipes (`.log` and `.silent` ports are never written); `ConsoleLogWriter` against a real directory (file modes, rotation on disk) | #004 |
| T1 | the disk rules of §3 with real files and permissions | #005 |
| T1 | `VsockConnection` over a `socketpair` | #007 |
| T2 | Linux test guest: boot + console marker | #003, #004 |
| T2 | block read-only/read-write | #005 |
| T2 | network through a host-local server | #006 |
| T2 | vsock echo/timeout/disconnect | #007 |
| T2 | console port numbering | #004, #095 |
| T2 | pause/resume | #069 |
| T3 | Gate check G1 (`Tests/AcceptanceTests/G1LinuxBoot`, [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §5): the pass conditions of [../04-plan/roadmap.md](../04-plan/roadmap.md) §2, 10 boots in a row | #003 |
| T3 | Network check: the Linux test guest resolves a public name and fetches `https://connectivitycheck.gstatic.com/generate_204` (nightly) | #006 |

## 16. Open items

| Item | Plan |
|---|---|
| VZ serial port numbering is not documented (§6.2) | #004 checks three ports on the test Linux guest, #095 all 20 ports. If the order is not the array order, `ConsolePortPlan` re-orders the array |
| Device order and the PCI host bridge's platform device name (§5) | discovered by #011 and committed to `Images/reference/vz/<macOS build>/topology.txt`. Nothing relies on `vdX` letters or slot numbers |
| Whether `VZVirtualMachineConfiguration.validate` runs in an unentitled `swift test` process (§3) | #002 tries it. If it needs the virtualization entitlement, the T0 validator tests stop before the framework step, and the framework rule is tested in the `IntegrationTests` bundle hosted by the entitled `APKRunTestHost` ([../05-development/build-system.md](../05-development/build-system.md) §2.2) |
| How VZ reports a start failure: the `start` completion error, `didStopWithError`, or both (§9.1, §9.2) | #003 records it for a bad kernel and a missing disk. A second report of the same failure must not cause a second transition |
| Whether macOS shows the microphone prompt at VM start or at the first capture (OQ-29, §11) | #084. The input stream is attached only while a package uses it, so neither answer changes the design |
| Whether the stock Cuttlefish arm64 kernel carries `virtio_snd` (OQ-38, §11) | #083. If not, the custom image adds it ([android-image.md](android-image.md) §7.5) |
| Virtualization.framework behavior changes on new macOS builds (R-16) | the T2 suite and the topology check run on every new macOS build ([../04-plan/risks.md](../04-plan/risks.md)) |

## 17. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the guest (test Linux guest or Android image build), and the result.

| Question | Task | Result |
|---|---|---|
| `validate` without the virtualization entitlement | #002 | pending |
| Error reporting of a failed start (completion vs delegate) | #003 | pending |
| Serial port numbering with three ports | #004 | pending |
| Read-only disks are read-only in the guest | #005 | pending |
| NAT network: DHCP lease and a host-local HTTP fetch | #006 | pending |
| vsock echo, timeout, and disconnect detection | #007 | pending |
| Guest-visible topology and `androidboot.boot_devices` value | #011 | pending (§5) |
| Serial port numbering with 20 ports; network on the stock image | #095 | pending (§6.2, §7) |
| Pause and resume across host sleep | #069 | pending (§9.4) |
| `virtio_snd` in the stock kernel | #083 | pending (OQ-38) |
| Microphone prompt timing | #084 | pending (OQ-29) |
