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
python3 -I Experiments/vz-android-boot/build_disks.py \
  --manifest Images/manifests/16373615/android-image.json \
  --zip Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip \
  --out Images/work/16373615/vz-spike/disks
python3 -I Experiments/vz-android-boot/make_initrd.py --repo . \
  --capture Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt \
  --boot-devices 40000000.pci --gpu swiftshader \
  --extra androidboot.cuttlefish_service_bluetooth_checker=false \
  --out Images/work/16373615/vz-spike/boot
Experiments/vz-android-boot/build.sh
cd Experiments/vz-android-boot
./run.sh ../../Images/work/16373615/vz-spike/boot run1 --console-ports 10 \
  --extra-console-ports 10 --gpu vz2d --sensors-port 18 --nics 2
./shell.sh ../../Images/work/16373615/vz-spike/runs/run1 getprop sys.boot_completed
adb connect 127.0.0.1:6520
```
