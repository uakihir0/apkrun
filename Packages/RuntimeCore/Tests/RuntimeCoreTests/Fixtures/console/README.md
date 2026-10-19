# Console fixtures

`vz-headless-cold-boot.log` is the hvc0 output of a cold boot of an existing instance of the
stock image (build 16373615) on VZ with the `headless` profile, from the 2026-10-08 direct-boot spike
(`Experiments/vz-android-boot/`, IR-306), with CR removed. It keeps the first 40 lines
verbatim and then, in their original order, only the lines up to
`VIRTUAL_DEVICE_BOOT_COMPLETED` that carry an init service start, the root switches, the
module summary, a `VIRTUAL_DEVICE_*` token, or `zygote`. The full log is 412 KB.

The complete phase golden test uses this VZ capture. The 62 checked-in #064 crosvm records in
`Images/reference/16373615/incomplete/` never reached `sys.boot_completed=1`; their launcher logs
can contain `VIRTUAL_DEVICE_BOOT_FAILED`, but they are not a complete hvc0 phase sequence. The
detector's boot-failure token is therefore covered with a focused line-level test.
