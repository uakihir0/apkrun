# Cuttlefish boot diagnosis

This isolated experiment checks whether the Android boot stall changes when
Cuttlefish uses `gpu_mode=none`. It holds the pinned Android build, Cuttlefish
host tools, capture tools, CPU count, memory size, and boot deadline to the
2026-10-01 `guest_swiftshader` baseline. It also requires the recorded Linux
distribution, kernel, architecture, host CPU count, nested-virtualization
state, and Cuttlefish instance number to match. It verifies those inputs before
launching and checks the resulting Cuttlefish configuration before publishing.

Run `capture-gpu-none.sh` on the Linux reference VM after setting
`CVD_HOST_DIR` and `ANDROID_PRODUCT_OUT` as described in
`docs/05-development/environment-setup.md`. The default output root is
`$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis`; set
`APKRUN_DIAGNOSTIC_ROOT` to choose another absolute, writable directory.
Published records go under that root's `results/`, outside the repository.

The runner uses a dedicated ADB server process on a unique private
`localfilesystem` socket under `/tmp`; its directory has mode `0700`, avoiding
TCP port races. The guest remains addressed through its loopback ADB endpoint.
Guest capture commands have 30-second timeouts and per-file byte limits;
Cuttlefish console output is capped at 8 MiB per phase. Live ADB control output
is bounded before parsing. Cuttlefish fleet preflight combines stdout and
stderr under a 30-second, 1 MiB cap. Live logcat is capped at 40 MiB total. All
Cuttlefish console and guest capture outputs together are limited to 64 MiB. The
reference capture has a 600-second boot deadline inside a 900-second hard
runner deadline, followed by up to 140 seconds of process cleanup.

The runner summarizes selected logcat signals, then removes all raw logcat
files before publication. The result records the Cuttlefish version and VCS
revision, baseline tool blob IDs, hashes of the experiment scripts and patched
capture script, actual GPU/CPU/memory settings, ADB state sample count, bounded
output byte counts, content-free logcat counts, and live-snapshot timeout,
truncation, and cleanup counts. Missing or incomplete cleanup status for any
bounded helper, including live snapshots, blocks publication. It does not
update the three canonical #064 profiles.
