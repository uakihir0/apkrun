# VZ direct-kernel boot spike

This experiment boots the pinned stock Cuttlefish image (build 16373615) directly on
Virtualization.framework, without Cuttlefish host tools and without nested virtualization.
It answers one question before the #011–#015 production work: does the stock image reach
`sys.boot_completed=1` under VZ direct kernel boot (G2 condition 1), and which host-service
substitutes does it need?

Nothing here is imported by a production target (AGENTS.md §11). The production path is
`apkrun_image disks` (#011), `AndroidBootPlanner` and `VMController` (#012), and the
RuntimeCore substitutes (#095). Results are recorded in
[android-image.md](../../docs/02-design/android-image.md) §17.

## Files

| File | Purpose |
|---|---|
| `build_disks.py` | Writes `os.img`, `persistent.img`, and `userdata.img` (raw GPT, android-image.md §4.2) from the verified download zip. Unwritten ranges stay holes. |
| `make_initrd.py` | Merges the bootconfig layers (vendor, image from a #064 launcher capture, platform, instance) with the repository's `bootconfig.py` and `avb.py`, and appends the trailer to `ramdisk.img`. |
| `VZAndroidBoot.swift` | The VZ harness: 10 single-port consoles plus one multiport console device for hvc10–hvc19, vsock with a loopback ADB forwarder (127.0.0.1:6520 → vsock 5555), NAT NICs, optional VZ virtio-gpu, and the "no sensors" responder on hvc18. |
| `build.sh` | Builds and ad-hoc signs the harness with `com.apple.security.virtualization`. |
| `run.sh` | Clones the writable disks (APFS `clonefile`) into a fresh run directory and boots. |
| `shell.sh` | Sends one command to the Android serial shell on hvc1 and prints the answer. |

## Running

```bash
python3 -I Experiments/vz-android-boot/build_disks.py --two-disks \
  --manifest Images/manifests/16373615/android-image.json \
  --zip Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip \
  --out Images/work/16373615/vz-spike/disks2
python3 -I Experiments/vz-android-boot/make_initrd.py --repo . \
  --capture Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt \
  --boot-devices 40000000.pci --gpu swiftshader \
  --extra androidboot.cuttlefish_service_bluetooth_checker=false \
  --extra androidboot.wifi_impl=virt_wifi \
  --out Images/work/16373615/vz-spike/boot
Experiments/vz-android-boot/build.sh
cd Experiments/vz-android-boot
DISK_SET=disks2 ./run.sh ../../Images/work/16373615/vz-spike/boot run1 \
  --console-ports 10 --extra-console-ports 10 --gpu vz2d --sensors-port 18 --nics 3 \
  --nic-macs 02:a5:4b:00:00:01,02:a5:4b:00:00:02,02:15:b2:00:00:00
./shell.sh ../../Images/work/16373615/vz-spike/runs/run1 getprop sys.boot_completed
adb connect 127.0.0.1:6520
```

Without `--two-disks` and `DISK_SET`, the scripts build and boot the three-disk layout of
android-image.md §4.2. `g2_spike.py --boot <boot dir> --name <run> [--disk-set disks2]` runs the
G2 pass conditions: it resets the instance, then runs five cold boots and checks each for
10 minutes. On the first boot it turns Bluetooth off and joins `VirtWifi` over the serial shell.

## Results (2026-10-08 UTC, macOS 27.0.1 (26A434), Apple M5 Pro, build 16373615)

### The stall was the nested reference host

| Event | #064 nested reference (E1, guest uptime) | VZ direct boot (guest uptime) |
|---|---|---|
| Second-stage init | 8.4 s | 0.3 s |
| `zygote` start | 233 s | 1.3 s |
| `boot_progress_preload_end` | 863 s | 2.2 s |
| `boot_progress_pms_ready` | 1467 s | 3.6 s |
| `VIRTUAL_DEVICE_BOOT_COMPLETED` | never (Watchdog kills) | 7.5 s first boot, 4.7 s later boots |

The same image, kernel command line, and launcher bootconfig boot about 100 times faster without
nesting. The Watchdog kills in the reference were caused by guest-wide slowness. On VZ the one
real blocker was a host-service wait (sensors, below), not slowness.

### What the stock image needs on VZ

| Finding | Evidence | Handling in the spike |
|---|---|---|
| `androidboot.boot_devices` | `/sys/block/vda` → `/sys/devices/platform/40000000.pci/pci0000:00/0000:00:0f.0/virtio12/block/vda` | `40000000.pci`. Every §4.2 label appears in `/dev/block/by-name/` |
| VZ accepts at most 10 `VZVirtioConsoleDeviceSerialPortConfiguration`s | `validate()`: "Number of Virtio console serial port devices is greater than the maximum number supported" for 11 | hvc0–hvc9 are single-port devices; hvc10–hvc19 are the ports of one `VZVirtioConsoleDeviceConfiguration` with `isConsole = true`. The sensors HAL's traffic arrives on port 18, so the numbering is the array order |
| No GPU device | zygote and SurfaceFlinger abort: "couldn't find an OpenGL ES implementation"; `init.cutf_cvm.rc` waits for `/dev/dri/card0` in `early-init` | VZ's `VZVirtioGraphicsDeviceConfiguration` (one 720×1280 scanout, no view) with the launcher's `guest_swiftshader` graphics keys. SurfaceFlinger uses HWC display 0 over DRM |
| Sensors HAL blocks `system_server` | the HAL opens `/dev/hvc18` and `/dev/hvc19` and waits for the `list-sensors` reply; `SystemSensorManager.nativeCreate` blocks the main thread and the Watchdog kills `system_server` after 185 s | hvc18 answers `list-sensors` with mask 0 (`02 00 00 80 02 00 00 00 30 0a`, the frame the real `sensors_simulator` sends). Missing ports instead make the HAL abort in a loop |
| Guest-side servers need their keys | without them `light-service.cuttlefish` (`vsock_lights_*`), the OpenThread HAL (`openthread_node_id`), and audio control abort in a loop | the keys stay. Only `vsock_tombstone_port`, `vhal_proxy_server_port`, and `auto_eth_guest_addr` (automotive) are dropped |
| RIL | `radio-service.cf: 'ro.boot.modem_simulator_ports' must be an integer vsock port`, exit 1 every 5 s | the key stays. With it the RIL connects to host vsock 9600, gets a reset, and stays up reporting `RADIO_NOT_AVAILABLE` |
| OpenThread | the HAL forks `ot-rcp -Leth1` and exits with an I/O error when `eth1` is missing | three NAT NICs in Cuttlefish's order (eth0 mobile, eth1 ethernet, eth2 Wi-Fi backing) |
| Network | with `wifi_impl=mac80211_hwsim_virtio` there is no Wi-Fi; Ethernet gets no request | `androidboot.wifi_impl=virt_wifi`: `setup_wifi` puts `wlan0` on eth2 and rewrites eth2's MAC to `02:15:b2:00:00:00` (`wifi_mac_prefix` 5554). vmnet drops frames from a MAC it did not assign, so the VZ NIC gets that MAC. After `cmd wifi set-wifi-enabled enabled` and `cmd wifi connect-network VirtWifi open`, DHCP gives 192.168.64.x and the network is VALIDATED |
| Bluetooth | no rootcanal on hvc5: `com.android.bluetooth` aborts in `waitForInitialization` 7 times in about 3.5 minutes per boot, then the recovery limit stops it. `ro.boot.vendor.apex.com.google.cf.bt=none` makes it worse. The boot reporter waits for Bluetooth and reports `VIRTUAL_DEVICE_BOOT_FAILED` | `androidboot.cuttlefish_service_bluetooth_checker=false` (the automotive product sets it the same way), and `cmd bluetooth_manager disable` right after the first boot. The setting persists; later boots have no Bluetooth crash |
| vdc is claimed by vold | the stock fstab has `/devices/*/block/vdc ... voldmanaged=sdcard1:auto`; with three disks vold scans the userdata disk as `disk:253,32` (it fails to identify it and gives up) | two-disk layout: `os.img` and one writable `instance.img` (`misc`, `metadata`, `frp`, `userdata` last) |
| `/proc/bootconfig` | equals the merged block (49 keys, 2574 bytes) | — |
| SELinux | `Enforcing`, no AVC denials | — |
| ADB | adbd listens on vsock 5555; `adb root` works (userdebug) | loopback forwarder 127.0.0.1:6520 → vsock 5555 |
| Guest-initiated reboot | `reboot` restarts the guest inside the same `VZVirtualMachine`; `reboot -p` ends it with `guestDidStop` | — |

### G2 pass conditions on the spike

`g2_spike.py` with the three-disk layout, five cold boots in a row after an instance reset, 10 minutes
of dwell each (2026-10-08 UTC). Every boot passed: `VIRTUAL_DEVICE_BOOT_COMPLETED` on hvc0,
`sys.boot_completed=1` over the serial shell, `sys.system_server.start_count` 1 at the end of the
dwell, no `WATCHDOG KILLING SYSTEM PROCESS`, no tombstone, no init service exiting three times, and
a validated Wi-Fi network.

| Boot | Host seconds to `BOOT COMPLETED` | Guest uptime at `VIRTUAL_DEVICE_BOOT_COMPLETED` |
|---|---|---|
| 1 (fresh instance) | 8.1 | 7.49 s |
| 2 | 5.1 | 4.67 s |
| 3 | 4.6 | 4.05 s |
| 4 | 4.5 | 4.07 s |
| 5 | 4.6 | 3.95 s |

Services that exited during a dwell were one-shot or lazy services (`apexd`, `artd`, `gsid`,
`bugreportd`, `vendor.dumpstate-default`, `virtualizationservice`), at most twice each. With the
two-disk layout (`--disk-set disks2`), two cold boots passed the same checks (7.6 s and 5.1 s).

This is not the G2 gate: G2 runs `Tests/AcceptanceTests/G2/` against the product code from a clean
`main` (#014).
