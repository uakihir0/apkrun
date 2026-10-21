# Implementation Tasks

Every unit of implementation work is one task. A task's number is its GitHub issue number. The milestone files in this directory hold the task text and are its source of truth. The GitHub issue holds the status and links to the entry (`scripts/dev/sync-task-issues.py` keeps the issue title, body, and milestone in step with the entry).

---

## 1. Files

| File | Milestone | Version |
|---|---|---|
| [M00-repository-and-vm-foundation.md](M00-repository-and-vm-foundation.md) | M0 Repository and VM foundation | v0.1 |
| [M01-android-bring-up.md](M01-android-bring-up.md) | M1 Android bring-up | v0.1 |
| [M02-graphics.md](M02-graphics.md) | M2 Graphics | v0.1 |
| [M03-input-and-basic-runtime.md](M03-input-and-basic-runtime.md) | M3 Input and basic runtime | v0.1, v0.2 |
| [M04-daemon-and-guest-protocol.md](M04-daemon-and-guest-protocol.md) | M4 Daemon and guest protocol | v0.2 |
| [M05-custom-android-image.md](M05-custom-android-image.md) | M5 Custom Android runtime image | v0.3 |
| [M06-update-system.md](M06-update-system.md) | M6 Update system | v0.3 |
| [M07-mac-app-wrappers.md](M07-mac-app-wrappers.md) | M7 Mac app wrappers | v0.4 |
| [M08-real-update-sources.md](M08-real-update-sources.md) | M8 Real update sources | v0.5 |
| [M09-macos-integration.md](M09-macos-integration.md) | M9 macOS integration | v0.5 |
| [M10-runtime-maintenance.md](M10-runtime-maintenance.md) | M10 Runtime maintenance | v0.5 |
| [M11-diagnostics.md](M11-diagnostics.md) | M11 Diagnostics | v0.5 |
| [M12-v1-release.md](M12-v1-release.md) | M12 v1.0 release | v1.0 |
| [post-v1.md](post-v1.md) | Post-v1 tracks | — |

Inside each file, tasks are in working order and separated by `---`.

---

## 2. Task entry format

### 2.1 Open task

````markdown
## #N Title

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #N, #N (or None) |
| Gate | G7 (only when the task closes a gate) |
| Design | [update-system.md](../../02-design/update-system.md) §5, §6 (at most six sections) |
| Code | `Packages/UpdateCore/`, `Tests/IntegrationTests/UpdateTests/` |

**Goal.** One or two sentences: the observable result.

**Out of scope.**
- What a reader might expect here, and the task that does it.

**Steps.**
1. **Short name.** What to do, naming the types and files. **Check:** the test or command that shows it works.

**Tests.**
- T0: what is tested, and where.
- T1, T2, T3: the same, or "none".

**Done when.**
- A checkable statement. All of them must hold to close the task.

**Pitfalls.**
- At most three.
````

- `Gate`, `Out of scope`, and `Pitfalls` are omitted when empty.
- Every `§N` names its document. The entry links to design sections instead of copying them.
- `Done when` is a plain list. Progress is not tracked in the file; the GitHub issue is open until every item holds.
- Keep an entry under 4 KB. A task that needs more is two tasks.

### 2.2 Closed task

When a task closes, its entry is shortened: the `Steps`, `Tests`, `Done when`, and `Pitfalls` blocks are replaced by one block.

````markdown
**Result.** What exists now (main types, commands, scripts) and where its tests are. Known limits, each with the task or open question that tracks it.
````

Keep a closed entry under 1.5 KB.

---

## 3. Task index

The tasks in working order ([../roadmap.md](../roadmap.md) §1.3). A task can start when every task it depends on is closed or labeled `needs-verification` ([../../05-development/workflow.md](../../05-development/workflow.md) §2.2). `scripts/dev/next-task.py` reads this table and GitHub, and prints the tasks that can start now.

| Task | Title | Milestone | Depends on | Gate |
|---|---|---|---|---|
| #2 | Bootstrap Xcode workspace | M0 | None |  |
| #3 | VMDefinition and VM validation | M0 | #2, #62 |  |
| #4 | Boot minimal ARM64 Linux | M0 | #3 | G1 |
| #5 | Serial console logging | M0 | #4 |  |
| #6 | virtio-blk storage | M0 | #4 |  |
| #7 | Guest networking | M0 | #4 |  |
| #8 | virtio-vsock | M0 | #4 |  |
| #62 | Diagnostics foundation | M0 | #2 |  |
| #63 | CI and module dependency checks | M0 | #2 |  |
| #64 | VirtioDeviceCore and test virtio device | M0 | #4 |  |
| #9 | Acquire and inventory ARM64 Cuttlefish artifacts | M1 | #2 |  |
| #65 | Reference boot capture | M1 | #9 |  |
| #10 | AndroidImageManifest | M1 | #9 |  |
| #11 | Extract Android kernel and ramdisk | M1 | #9, #10 |  |
| #12 | GPT disks and partition mapping | M1 | #6, #10, #11 |  |
| #13 | Boot the Android kernel | M1 | #11, #12 |  |
| #14 | Reach Android init | M1 | #13 |  |
| #96 | Cuttlefish host-service substitution | M1 | #14 |  |
| #15 | Reach system_server and boot_completed | M1 | #14, #96 | G2 |
| #107 | Update Android boot tests for runtime state snapshots | M1 | #15 |  |
| #16 | ADB debugging over vsock | M1 | #15, #8 |  |
| #17 | Install HelloText APK | M1 | #16 |  |
| #18 | Launch HelloText APK | M1 | #17 |  |
| #66 | Runtime image bundle | M1 | #15 |  |
| #19 | Analyze the RiftVM GPU prototype | M2 | #2 |  |
| #20 | virtio-gpu device layer | M2 | #19, #4, #64 |  |
| #21 | Build graphics dependencies | M2 | #19 |  |
| #22 | Android detects virtio-gpu | M2 | #20, #15 |  |
| #99 | Mesa-enabled VirGL guest image | M2 | #21, #22 |  |
| #23 | Android VirGL | M2 | #22, #21, #99 |  |
| #24 | Render SurfaceFlinger to Metal | M2 | #21, #23 | G3 |
| #105 | VirGL submit errors during app runs | M2 | #24 |  |
| #34 | Define GuestProtocol | M3 | #8 |  |
| #73 | Guest Agent bootstrap | M3 | #34, #16 |  |
| #25 | Pointer input | M3 | #24, #73 |  |
| #26 | Keyboard input | M3 | #25 |  |
| #101 | Input route rebinds after the guest agent is lost | M3 | #25 |  |
| #102 | A pointer tap reliably focuses a text field | M3 | #25 |  |
| #103 | Trace intermittent click loss during repeated presses | M3 | #24, #73 |  |
| #27 | HelloText in a native Mac window | M3 | #24, #25, #26 | G4 |
| #28 | RuntimeCore package operations | M3 | #27 |  |
| #68 | Retina, density, and resize | M3 | #27 |  |
| #29 | DisplayPool | M3 | #28, #68 |  |
| #30 | App on a secondary Android display | M3 | #29 |  |
| #31 | Two APKs in two native windows | M3 | #30 | G5 |
| #100 | Parallel VM test runs | M3 | #15 |  |
| #32 | Introduce apkrund | M4 | #31 | G6 (headless form) |
| #33 | XPC runtime API | M4 | #32 |  |
| #69 | Session client and IOSurface window over XPC | M4 | #33 | G6 (full form) |
| #45 | Launcher as a wrapper (APKRunLauncher) | M7 | #33, #69 |  |
| #46 | WrapperCore generator | M7 | #45 |  |
| #47 | Generate Hello.app | M7 | #46 |  |
| #48 | Launch Hello.app end to end | M7 | #47, #32 | G8 |
| #35 | Full Guest Agent protocol and vsock transport | M4 | #34, #28 |  |
| #67 | First-run provisioning | M4 | #33, #66, #69 |  |
| #70 | Idle policy and host sleep/wake | M4 | #32 |  |
| #71 | Performance harness | M4 | #32, #69 |  |
| #54 | Clipboard, plain text | M4 | #35, #69 |  |
| #72 | APKRun IME | M4 | #35, #69 |  |
| #36 | APKRun AOSP product | M5 | #35 |  |
| #37 | Store Agent | M5 | #36 |  |
| #74 | Host inspection and import formats | M6 | #37 |  |
| #38 | LocalUpdateProvider | M6 | #37 |  |
| #39 | PackageInstaller updates | M6 | #38, #74 |  |
| #40 | Update ownership | M6 | #39 |  |
| #41 | Gentle updates | M6 | #40 | G7 |
| #42 | Package and signature verification | M6 | #39, #74 |  |
| #43 | Split APK installation | M6 | #42, #74 |  |
| #44 | Update rollback | M6 | #42, #43 |  |
| #51 | DirectProvider | M6 | #38, #42 |  |
| #75 | Update scheduler | M6 | #38, #41, #51 |  |
| #56 | Android icon to macOS icon pipeline | M7 | #46, #37 |  |
| #57 | Finder, Dock, and Spotlight integration | M7 | #56 |  |
| #49 | Wrapper independent of the APK file | M7 | #48, #38 |  |
| #50 | Automatic update behind an unchanged wrapper | M7 | #44, #49 | G9 |
| #76 | `apkrun wrap` CLI | M7 | #47, #49 |  |
| #77 | Wrapper lifecycle and uninstall choices | M7 | #49 |  |
| #78 | Home and store UI | M7 | #49 |  |
| #79 | Add flow | M7 | #78, #74 |  |
| #80 | Per-app settings | M7 | #78, #40, #75 |  |
| #90 | Portable wrappers | M7 | #76 |  |
| #52 | F-Droid provider | M8 | #51 |  |
| #53 | GitHub provider | M8 | #51 |  |
| #55 | Notifications | M9 | #35, #36, #48 |  |
| #81 | Image and HTML clipboard | M9 | #54 |  |
| #82 | Links | M9 | #35, #36, #48 |  |
| #83 | Files | M9 | #35, #36 |  |
| #86 | Locale, time zone, clock format, and time | M9 | #35, #36, #70 |  |
| #87 | Menu bar | M9 | #33 |  |
| #58 | APKRun runtime updater | M10 | #32, #50 |  |
| #59 | Guest image versioning and migration | M10 | #36, #58 |  |
| #88 | Runtime image distribution | M10 | #59, #66 |  |
| #60 | `apkrun doctor` | M11 | #32, #35, #37 |  |
| #61 | Diagnostics bundle | M11 | #5, #60 |  |
| #84 | Audio output | M12 | #36 |  |
| #85 | Microphone | M12 | #84 |  |
| #89 | Developer ID signing, notarization, and distribution wrappers | M12 | #63, #47 |  |
| #91 | Compatibility database | M12 | #60 |  |
| #92 | Security hardening and fuzzing | M12 | #32, #35 |  |
| #93 | Localization and accessibility | M12 | #78 |  |
| #94 | Legal and licensing compliance | M12 | #21, #36 |  |
| #95 | v1.0 release readiness | M12 | every other v1.0 task |  |
| #97 | Vulkan track | Post-v1 | #24, #36 |  |
| #98 | Google Play authority | Post-v1 | #40, #50 |  |

---

## 4. Rules

- One task at a time per agent. Follow [../../../AGENTS.md](../../../AGENTS.md) §2.
- Follow the steps in order. If a step is wrong or impossible, fix the design document and the entry in the same commit, and say why in the commit message.
- Keep the scope. Work that is outside the entry becomes a new task: open a GitHub issue, then add its entry to the milestone file and its row to §3 in the same commit ([../../05-development/workflow.md](../../05-development/workflow.md) §2.4).

---

## 5. Old task numbers

Before 2026-10-21, tasks had their own three-digit numbers, which differed from their GitHub issue numbers. Commit messages, branch names, and `IR-NNNN` records from before that date use the old numbers. To convert an old number to the task number used now:

| Old number | Task number now | Example |
|---|---|---|
| `001`–`097` | old number + 1 | old `024` (Pointer input) is #25 |
| `098` | #100 | Parallel VM test runs |
| `099` | #99 | Mesa-enabled VirGL guest image |
| `101`–`103` | unchanged | #101, #102, #103 |

GitHub issue 1 and pull request 104 are not tasks. Tasks from #105 on were created with their final numbers.
