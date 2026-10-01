# Cuttlefish boot diagnosis

This isolated experiment checks whether the Android boot stall changes when
Cuttlefish uses `gpu_mode=none`. It holds the pinned Android build, Cuttlefish
host tools, capture tools, CPU count, memory size, and boot deadline to the
2026-10-01 `guest_swiftshader` baseline. It passes `gpu_mode=none` to both
`cvd create` and `cvd start`, and checks the saved Cuttlefish configuration
before publication. It also requires the recorded Linux
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

Each generated workspace has a private ownership marker containing a
per-run random token and the exact workspace path. Cleanup validates the
diagnostic root, work directory, generated name, and marker before Python
removes a workspace or its output trees. Directory components are opened
without following symbolic links. The runner prepares the data root, `work/`,
and `results/` with mode `0700`, and rejects a writable ancestor unless a
root-owned or current-user-owned sticky directory protects it. If raw-log cleanup fails while
Cuttlefish still needs manual cleanup, the runner removes the capture record
and live ADB output trees while retaining the private runtime workspace and
content-free host metadata. If those removals fail, it keeps the runtime
intact and reports that manual cleanup is needed; raw logcat may remain in that
private workspace until cleanup succeeds. Once Cuttlefish is verified clean,
the runner attempts to discard the entire private workspace. The publication
gate repeats the symlink-aware scrub after normalization, verifies Cuttlefish
and ADB cleanup, checks that the destination is unused, and only then moves
the record into `results/` with Linux `renameat2(RENAME_NOREPLACE)`, anchored
to opened source and destination directories.

Logcat scrubbing also requires the workspace ownership token and validates the
generated data-root layout before deleting files. Data-root paths containing
control characters are rejected so the canonical path cannot be truncated by
shell command substitution. If final workspace removal fails after its
contents are deleted, cleanup restores the ownership marker. A retry can use
the generated path only while that path still identifies the same workspace;
if another same-user process changed it, cleanup preserves the original marker
in the opened workspace and reports that manual cleanup is needed.

Before deleting or publishing a named entry, the runner atomically moves it
to an unpredictable quarantine name in the already-open private parent and
checks the moved inode against the pinned identity. It restores an unexpected
entry without replacement and refuses the operation. Publication also checks
the destination inode after the move and attempts a no-replace rollback if it
changed. The data root and its children are private to the current user. Linux
does not provide inode-conditional `unlink` or `rmdir`, so a concurrently
malicious process running as the same user remains outside this runner's
protection boundary.

Workspace deletion removes the ownership marker last. If deleting another
entry fails, the marker remains available for a later cleanup retry.
