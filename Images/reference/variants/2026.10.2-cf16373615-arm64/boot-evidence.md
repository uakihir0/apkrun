# Variant boot evidence

| Field | Value |
|---|---|
| Run | 2026-10-16, 03:21 UTC |
| Image | `2026.10.2-cf16373615-arm64` |
| GPU | `virgl` |
| Stock manifest SHA-256 | `7c285ff0f550b87129efeec90249cfd38e376be3ebac2f5bad51c945058d3ce3` |
| Variant manifest SHA-256 | `c61d182eb93dc980ceb4dae2cd4d8b840aea060835b45507197b0fccbe507978` |
| Variant disk SHA-256 | `2b0fe6ddbe6031eeb60f309f0a4998db38d634d869d18b6715b63282333e3d3a` |
| Inject record SHA-256 | `d2c3ed58f2038953d87e6aa753d466632925bc29dfb98b7db0d81364f8c3a463` |
| Reseal record SHA-256 | `ddf4bfea65a193013a82a851324980e060f65c7076e44d1fde38be5c1a6687cc` |

## Result

The guest initialized `virtio_gpu` and mounted `/vendor`. SurfaceFlinger then
received a denial reading a sysfs `uevent` file, Mesa failed to open any DRM
device, `eglInitialize` returned `EGL_NOT_INITIALIZED`, and SurfaceFlinger
aborted after finding no suitable `EGLConfig`.

After 150 seconds, `sys.boot_completed` was still empty. The run was stopped
without reaching Android boot completion, and `apkrun.test=egl` did not run.
This run alone shows the AVC and EGL failure together but does not establish
causality. Earlier controls on the #099 Mesa vendor linked the SurfaceFlinger's
denied sysfs `uevent` read to the failed DRM probe: the no-overlay control
failed, while the experimental ODM policy overlay passed the EGL check
(IR-1277, IR-1279). Those controls support a policy cause for this failure,
but at the time of this boot the exact 2026.10.2 disk had not yet been tested
with the overlay. A later diagnostic control built from this source passed its
EGL probe; IR-1329 and the #099 task notes record that separate 2026.10.3
artifact and result. That control does not change the no-overlay result above.

## Sanitized excerpts

The following excerpts omit timestamps, process IDs, and audit envelope fields.
Their source line numbers and the full-log hashes below identify the records.

```text
boot-20261016T032152Z.log:30
[drm] Initialized virtio_gpu 0.1.0 for 0000:00:14.0 on minor 0

boot-20261016T032152Z.log:87
init: [libfs_mgr] __mount(source=/dev/block/dm-13,target=/vendor,type=erofs)=0: Success

logcat-20261016T032152Z.log:5552
avc: denied { read } for comm="surfaceflinger" name="uevent" dev="sysfs" ino=3405 scontext=u:r:surfaceflinger:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=0

logcat-20261016T032152Z.log:5570
W EGL-MAIN: Failed to open any DRM device

logcat-20261016T032152Z.log:5676-5679
W EGL-MAIN: egl: failed to create dri2 screen
W libEGL: eglInitialize(...) failed (EGL_NOT_INITIALIZED)
W SurfaceFlinger: no suitable EGLConfig found, trying a simpler query
F SurfaceFlinger: no suitable EGLConfig found, giving up
```

## Log integrity

Full logs remain outside the repository at
`/tmp/apkrun-099-home-2026102/Logs/`. Their hashes and byte counts are:

| Log | Bytes | SHA-256 |
|---|---:|---|
| `vm/boot-20261016T032152Z.log` | 2,712,596 | `d04971b97e93185a866d9a8df9522bf18c2b0aa76f668e1e0d389386151b0150` |
| `guest/logcat-20261016T032152Z.log` | 7,847,952 | `8f615957725aee96ee872f1623e68204c4bc221c6d26e4338aa3bc14cde1c55c` |

## Diagnostic rerun

The same exact variant was booted again at 2026-10-16 03:30 UTC. These
contemporaneous ADB command results record the guest's runtime configuration
and DRM nodes:

```text
$ adb -s 127.0.0.1:6520 shell getprop ro.hardware.egl
mesa

$ adb -s 127.0.0.1:6520 shell ls -lZ /dev/dri
crw-rw-rw- 1 system graphics u:object_r:graphics_device:s0 226, 0 card0
crw-rw-rw- 1 system graphics u:object_r:gpu_device:s0 226, 128 renderD128

$ adb -s 127.0.0.1:6520 shell ls -lZ /vendor/lib64/egl
libEGL_mesa.so       u:object_r:same_process_hal_file:s0
libGLESv1_CM_mesa.so u:object_r:same_process_hal_file:s0
libGLESv2_mesa.so    u:object_r:same_process_hal_file:s0
libgallium_dri.so    u:object_r:same_process_hal_file:s0

$ adb -s 127.0.0.1:6520 shell getprop sys.boot_completed
<empty after 150 seconds>
```

The rerun reported `ro.hardware.egl=mesa` and showed all four Mesa libraries
under `/vendor/lib64/egl` with the `same_process_hal_file` SELinux label. Both
DRM nodes existed with mode `0666`; this does not establish that SurfaceFlinger
successfully opened or used them. The rerun reproduced the sysfs denial and EGL
failure. The VM was stopped after the completion property remained empty at
150 seconds. At the time of this rerun, an overlay control for this exact image
was still outstanding. IR-1329 records the later control result; it used a
distinct 2026.10.3 diagnostic image.

The rerun log records the denied `uevent` read at lines 5233–5235, including a
failed syscall with `exit=-13`; the pathname is absent from that audit record,
so it does not identify which node SurfaceFlinger tried to open. Mesa reports
that it could not open a DRM device at line 5259, then reports the failed DRI2
screen and `eglInitialize` at lines 5343–5346. These events are close in time,
but this run alone does not establish that the denied sysfs read caused the DRM
probe failure.

The rerun's full logs remain outside the repository under the same directory:

| Log | Bytes | SHA-256 |
|---|---:|---|
| `vm/boot-20261016T033049Z.log` | 2,980,683 | `503410b6c666ae7cbceb6d0799e7f844ad1236d1095e7f730dbefb44d3b0aae6` |
| `guest/logcat-20261016T033049Z.log` | 9,552,891 | `be2b26387336fbc190d1be28d4e599d9202772c3e28f2c61631c511a4a028e77` |
