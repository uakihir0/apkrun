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

The guest initialized `virtio_gpu` and mounted `/vendor`. The run reported
`ro.hardware.egl=mesa`; all four Mesa libraries appeared under
`/vendor/lib64/egl` with the `same_process_hal_file` SELinux label. SurfaceFlinger
then received a denial reading a sysfs `uevent` file, Mesa failed to open any
DRM device, `eglInitialize` returned `EGL_NOT_INITIALIZED`, and SurfaceFlinger
aborted after finding no suitable `EGLConfig`.

After 150 seconds, `sys.boot_completed` was still empty. The run was stopped
without reaching Android boot completion, and `apkrun.test=egl` did not run.
These observations do not establish that the AVC caused the EGL failure.

## Sanitized excerpts

The following excerpts omit timestamps and process IDs from the original lines.
Their source line numbers and the full-log hashes below identify the records.

```text
boot-20261016T032152Z.log:30
[drm] Initialized virtio_gpu 0.1.0 for 0000:00:14.0 on minor 0

boot-20261016T032152Z.log:87
init: [libfs_mgr] __mount(source=/dev/block/dm-13,target=/vendor,type=erofs)=0: Success

logcat-20261016T032152Z.log:5552
avc: denied { read } for comm="surfaceflinger" name="uevent" dev="sysfs" scontext=u:r:surfaceflinger:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=0

logcat-20261016T032152Z.log:5570
W EGL-MAIN: Failed to open any DRM device

logcat-20261016T032152Z.log:5677-5679
W EGL-MAIN: egl: failed to create dri2 screen
W libEGL: eglInitialize(...) failed (EGL_NOT_INITIALIZED)
F SurfaceFlinger: no suitable EGLConfig found, giving up
```

## Log integrity

Full logs remain outside the repository at
`/tmp/apkrun-099-home-2026102/Logs/`. Their hashes and byte counts are:

| Log | Bytes | SHA-256 |
|---|---:|---|
| `vm/boot-20261016T032152Z.log` | 2,712,596 | `d04971b97e93185a866d9a8df9522bf18c2b0aa76f668e1e0d389386151b0150` |
| `guest/logcat-20261016T032152Z.log` | 7,847,952 | `8f615957725aee96ee872f1623e68204c4bc221c6d26e4338aa3bc14cde1c55c` |
