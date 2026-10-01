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
Cuttlefish console and guest capture outputs together are limited to 64 MiB.
The three selected live host logs are capped at 64 MiB each and 384 MiB in
aggregate, including atomic replacement copies. The
reference capture has a 600-second boot deadline inside a 900-second hard
runner deadline, followed by up to 140 seconds of process cleanup. The runner
starts its 900-second budget before source verification and snapshot loading;
an outer watchdog sends TERM at the deadline, bounds that bootstrap, and passes
the remaining budget to the capture supervisor. The supervisor owns a separate
guest process session and completes its own bounded cleanup before returning.

The runner resolves `/tmp` to its physical directory and creates a random,
mode-0700 root with a short `h.XXXXXX` Cuttlefish HOME beneath it. The fleet
preflight uses a separate short `p.XXXXXX` HOME. The capture supervisor and
Cuttlefish temporary files use the short private path for both `HOME` and
`TMPDIR`; each Cuttlefish instance gets its own short `h.XXXXXX` HOME beneath
it. Before deleting either HOME, the runner checks same-user processes in
`/proc` for environment, command-line, current-directory, or open-file
descriptor references to the private paths. It excludes its own caller chain
only when each PID and start time still match. If `/proc` blocks environment
inspection, the only exception is `sd-pam` in the exact current-user
`init.scope` cgroup, with the `(sd-pam)` command-line marker and a verified
`systemd --user` parent whose executable matches the installed systemd binary.
That executable and every parent directory must be root-owned and not
group-writable or world-writable; the running executable is matched by device
and inode. When the `sd-pam` executable itself is readable, it must match that
binary too. Any other unreadable process blocks cleanup. On the real Linux
process table, the audit pins each same-UID process with a pidfd so a reused
numeric PID cannot alias the process being checked. A process that disappears
between `/proc` reads is ignored only after confirming its process directory
is gone or its state is `Z`/`X`; missing fields on a live process and PID
identity changes block cleanup. The current process ancestry is pinned and
each parent link is rechecked before classifying ancestors and after the full
process scan. Managed child signals also use pidfd-backed brokers; if a broker
cannot be verified as stopped, cleanup preserves the workspace instead of
signalling its numeric PID. The capture HOME is checked again after the socket
audit, immediately before removal. If a process remains or its identity cannot
be verified, the HOME and workspace are retained and the result is not
published.

Cuttlefish keeps some host state in a UID-wide directory under
`/var/tmp/cvd/<uid>` (with the legacy `/tmp/cvd/<uid>` location recognized).
The runner audits that directory and the private temporary tree without
changing or resetting the shared Cuttlefish state. It records counts and
maximum encoded path lengths for filesystem Unix sockets, counting the
terminating NUL against Linux's 108-byte `sun_path` limit. A failed or
over-limit audit preserves the private state and blocks publication. Separate
fleet and capture metrics are included in `experiment.json`; socket paths
themselves are not recorded. Cuttlefish may leave socket entries under the
private temporary tree after its group stops. Once the record has copied the
diagnostic logs and process checks pass, the runner removes only the
workspace-marked `/tmp/x.XXXXXX` tree through descriptor-relative,
no-follow cleanup, including when the `t/` directory is empty. Directory and
socket symlinks beneath an audit root block cleanup. Ordinary-file and dangling
symlinks are not followed by the audit or remover. The final root removal checks
the pinned directory identity and uses `rmdir` relative to the opened `/tmp`
directory. The runner never removes the UID-wide Cuttlefish state directory.

The supervised capture's combined stdout and stderr are capped at 1 MiB in a
private `capture-process-output.log`. If that log is truncated, the workspace
is retained and the result is not published. The supervisor's own stderr is
captured through a private FIFO into a separate 64 KiB bounded log; the reader
drains the FIFO after reaching its cap so it cannot stall process cleanup.
The capture supervisor and dedicated ADB server also wait at startup gates
until a signal broker verifies their process identities and pins pidfds.
Signals to those processes and the stderr reader go through their brokers,
never through numeric PIDs. If a broker's owner disconnects, the broker sends
TERM and then KILL if needed. Each broker watches its pidfd and records target
exit; the runner reaps each target only after verifying the exit record and
waits for the broker's stopped marker. If identity or cleanup verification
fails, the runner retains the private workspace and blocks publication. An
incomplete or truncated supervisor stderr log also blocks publication. These
logs are discarded with a successful capture and retained with a private
workspace when the capture exits nonzero. Host output is never published.
Startup signals are deferred until a target PID and its broker state are
recorded, then the startup gate is aborted or the pinned target is stopped.
Parent-held read/write gate descriptors keep a failed child from leaving the
launcher blocked while opening a FIFO. The signal handler disables the EXIT
cleanup trap before running cleanup so a failed stop cannot repeat its wait
budget. The background ADB watcher, stderr reader, and stderr broker close all
inherited descriptors numbered 3 and above before starting.
Startup abort waits are bounded. Once the broker is ready, closing the parent's
control channel makes its pidfd owner-disconnect cleanup terminate the gated
target if the abort token cannot be read. If the broker or target cannot be
verified as stopped, the runner preserves its workspace. Watcher startup defers
signals until its child PID is recorded. Shutdown uses a private done marker;
if that write fails, the runner uses bounded TERM/KILL checks on its unreaped
direct child, marks cleanup unverified, and retains the workspace and ADB
server. Signal cleanup removes the private ADB socket directory only after the
pinned ADB server has stopped. The runner also bounds broker reaping after the
broker publishes its stopped marker. The `mktemp` command substitution ignores
startup signals until its directory path is assigned, so a process-group
interrupt cannot leave an untracked socket directory. Cleanup traps are
installed before the per-run workspace is allocated, and startup signals stay
deferred until its ownership marker and the short Cuttlefish HOME marker are
recorded. Short HOME and fleet HOME setup masks startup signals in each
filesystem-changing command, rolls back only the expected private entries
after setup failures, and defers fleet-home signal handoff until its ownership
marker is recorded. Cleanup removes the fleet HOME before its containing
short HOME, masks signals through both deletion operations, then re-audits
socket paths immediately before removing the root.
If the capture supervisor receives a signal while finalizing its status, it
creates a private `.interrupted` marker beside that status, removes the status
file, and exits with the signal status (or a reserved failure status if either
invalidation operation fails). A fully completed supervisor returns zero and
records the guest command's separate exit code in the status file; the outer
runner rejects every nonzero supervisor exit and the interruption marker.
The Python supervisors enable Linux child-subreaper mode before launching
Cuttlefish commands. They terminate and reap orphaned descendants even if a
child creates a new session or keeps the output pipe open. A process tree that
cannot be verified as stopped blocks publication. They keep the supervised
leader unreaped while checking its process group and adopted descendants, so
its PID cannot be reused during cleanup. Empty trees return immediately instead
of waiting through the full cleanup grace. For a bounded stdin collector,
`cleanupComplete` means EOF was observed; reaching the byte limit early or
receiving a signal before EOF leaves cleanup unverified unless the caller
continues draining the producer.

The runner summarizes selected logcat signals, then removes all raw logcat
files before publication. Before launching the guest, it checks that each
private canonical-tool copy matches the recorded observed Git blob, and that
each experiment-tool copy matches its recorded SHA-256. Record creation repeats
those checks and validates the exact expected path sets and digest formats.
The two runtime Python helpers copied into the reference-tool directory are
checked separately. The first host verifier is loaded from committed `HEAD`
and its private copy must match those committed bytes.
The `run_capture.py` supervisor and its `capture_processes.py` dependency are
loaded from memory only after their SHA-256 values and committed `HEAD` sources
match the host identity. Before launch, the patched `capture.sh` is opened
without following symlinks or blocking on special files, checked as a bounded
regular file, and compared with its recorded SHA-256. The exact bytes are
copied into a sealed Linux memory file and passed to Bash, so replacing the
private script after verification cannot change what executes.
`APKRUN_CAPTURE_SCRIPT_DIR` preserves the private helper and manifest lookup
paths when Bash runs the script from that memory file. The script keeps a
separate unpatched copy for its Git-blob check. At publication, the runner
executes the digest-checked `compare_boot.py` and `experiment_support.py`
source snapshots from memory; normalization rules are read through a sealed
memory file before normalization.
The result records the Cuttlefish version and VCS revision, the commit and blob
IDs for both the historical baseline tools and the currently observed
committed tools, hashes of the experiment scripts and patched capture script,
actual GPU/CPU/memory settings, ADB state sample count, bounded output byte
counts, content-free logcat counts, and live-snapshot timeout, truncation, and
cleanup counts. The runner only accepts the pinned canonical baseline record.
That record is pinned to commit
`64da28a551b0b33e258c8f37057b9a8a6d90846d`.
Missing or incomplete cleanup status for any bounded helper, including live
snapshots, blocks publication. It does not update the three canonical #064
profiles.

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
