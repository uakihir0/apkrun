# Variant boot evidence

| Field | Value |
|---|---|
| Run | 2026-10-16, 02:21 UTC |
| Image | `2026.10.1-cf16373615-arm64` |
| GPU | `virgl` |
| Stock manifest SHA-256 | `7c285ff0f550b87129efeec90249cfd38e376be3ebac2f5bad51c945058d3ce3` |
| Variant manifest SHA-256 | `c648d01caf6c96c5b50890277007adbc4d511d7f65e560d049a1f757c3cad2df` |
| Variant disk SHA-256 | `1d9b887b33c905ab916507b5c30489e7f9ebee7ec6bed4d17cedee6a4a36c049` |
| Inject record SHA-256 | `9d12474e864d1099a9c9f9231b63c15ebd3779cf0c059092d5f084cf76e693ac` |
| Reseal record SHA-256 | `34c0ccc0998e0541257aa105756ff6a1684770ce5501f6398ad6e076f67a2677` |

The variant record at `variant/variant.json` carries the same inject and
reseal record hashes as the files in `inject/` and `reseal/`. Its manifest and
signature are retained under `variant/`; the large disk image is not committed.
The reference build's source and manifest paths remain unchanged.

## Result

The guest loaded `virtio_gpu` (`Logs/vm/boot-20261016T022117Z.log:30`) and
mounted `/vendor` successfully (`:87`). SurfaceFlinger then received a
SELinux denial reading a sysfs `uevent` file, labeled `sysfs`
(`Logs/guest/logcat-20261016T022116Z.log:5526`). Mesa reported that it could
not open a DRM device (`:5551`); `eglInitialize` returned
`EGL_NOT_INITIALIZED` (`:5671`), and SurfaceFlinger aborted after finding no
suitable `EGLConfig` (`:5673`). The guest did not reach
`sys.boot_completed=1`; `apkrun.test=egl` was not run.

These observations do not establish that the SELinux denial caused the EGL
failure. The successful EGL result recorded in IR-997 used a separate
ODM-overlay variant and does not pass this variant's T2 check.

## Sanitized excerpts

The following excerpts omit process IDs from the original lines. The full-log
hashes and original line numbers above and below identify the source records.

```text
boot-20261016T022117Z.log:30
[drm] Initialized virtio_gpu 0.1.0 for 0000:00:14.0 on minor 0

boot-20261016T022117Z.log:87
init: [libfs_mgr] __mount(source=/dev/block/dm-13,target=/vendor,type=erofs)=0: Success

logcat-20261016T022116Z.log:5526
avc: denied { read } for comm="surfaceflinger" name="uevent" dev="sysfs" scontext=u:r:surfaceflinger:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=0

logcat-20261016T022116Z.log:5551
W EGL-MAIN: Failed to open any DRM device

logcat-20261016T022116Z.log:5671-5673
W EGL-MAIN: egl: failed to create dri2 screen
W libEGL: eglInitialize(...) failed (EGL_NOT_INITIALIZED)
F SurfaceFlinger: no suitable EGLConfig found, giving up
```

## Log integrity

Full logs remain outside the repository at
`/tmp/apkrun-099-boot-evidence-20261016/`. Their SHA-256 values are recorded
here so the sanitized excerpts can be checked against the original run:

| Log | Bytes | SHA-256 |
|---|---:|---|
| `boot-20261016T022117Z.log` (`console.log`) | 1,003,983 | `0b87d2240f7ff6256ec67883f47ec254e4d2cebf54788a2e20e722ed13f81fa5` |
| `logcat-20261016T022116Z.log` | 2,631,940 | `faf039291a276f302f6844b75fcfa573d4acfc8f34b422f1b3ff7c1748ff9d84` |
