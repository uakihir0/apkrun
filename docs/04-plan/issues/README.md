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
| #001 | Bootstrap Xcode workspace | M0 | None |  |
| #002 | VMDefinition and VM validation | M0 | #001, #061 |  |
| #003 | Boot minimal ARM64 Linux | M0 | #002 | G1 |
| #004 | Serial console logging | M0 | #003 |  |
| #005 | virtio-blk storage | M0 | #003 |  |
| #006 | Guest networking | M0 | #003 |  |
| #007 | virtio-vsock | M0 | #003 |  |
| #061 | Diagnostics foundation | M0 | #001 |  |
| #062 | CI and module dependency checks | M0 | #001 |  |
| #063 | VirtioDeviceCore and test virtio device | M0 | #003 |  |
| #008 | Acquire and inventory ARM64 Cuttlefish artifacts | M1 | #001 |  |
| #064 | Reference boot capture | M1 | #008 |  |
| #009 | AndroidImageManifest | M1 | #008 |  |
| #010 | Extract Android kernel and ramdisk | M1 | #008, #009 |  |
| #011 | GPT disks and partition mapping | M1 | #005, #009, #010 |  |
| #012 | Boot the Android kernel | M1 | #010, #011 |  |
| #013 | Reach Android init | M1 | #012 |  |
| #095 | Cuttlefish host-service substitution | M1 | #013 |  |
| #014 | Reach system_server and boot_completed | M1 | #013, #095 | G2 |
| #015 | ADB debugging over vsock | M1 | #014, #007 |  |
| #016 | Install HelloText APK | M1 | #015 |  |
| #017 | Launch HelloText APK | M1 | #016 |  |
| #065 | Runtime image bundle | M1 | #014 |  |
| #018 | Analyze the RiftVM GPU prototype | M2 | #001 |  |
| #019 | virtio-gpu device layer | M2 | #018, #003, #063 |  |
| #020 | Build graphics dependencies | M2 | #018 |  |
| #021 | Android detects virtio-gpu | M2 | #019, #014 |  |
| #099 | Mesa-enabled VirGL guest image | M2 | #020, #021 |  |
| #022 | Android VirGL | M2 | #021, #020, #099 |  |
| #023 | Render SurfaceFlinger to Metal | M2 | #020, #022 | G3 |
| #105 | VirGL submit errors during app runs | M2 | #023 |  |
| #033 | Define GuestProtocol | M3 | #007 |  |
| #072 | Guest Agent bootstrap | M3 | #033, #015 |  |
| #024 | Pointer input | M3 | #023, #072 |  |
| #025 | Keyboard input | M3 | #024 |  |
| #101 | Input route rebinds after the guest agent is lost | M3 | #024 |  |
| #102 | A pointer tap reliably focuses a text field | M3 | #024 |  |
| #103 | Trace intermittent click loss during repeated presses | M3 | #023, #072 |  |
| #026 | HelloText in a native Mac window | M3 | #023, #024, #025 | G4 |
| #027 | RuntimeCore package operations | M3 | #026 |  |
| #067 | Retina, density, and resize | M3 | #026 |  |
| #028 | DisplayPool | M3 | #027, #067 |  |
| #029 | App on a secondary Android display | M3 | #028 |  |
| #030 | Two APKs in two native windows | M3 | #029 | G5 |
| #098 | Parallel VM test runs | M3 | #014 |  |
| #031 | Introduce apkrund | M4 | #030 | G6 (headless form) |
| #032 | XPC runtime API | M4 | #031 |  |
| #068 | Session client and IOSurface window over XPC | M4 | #032 | G6 (full form) |
| #044 | Launcher as a wrapper (APKRunLauncher) | M7 | #032, #068 |  |
| #045 | WrapperCore generator | M7 | #044 |  |
| #046 | Generate Hello.app | M7 | #045 |  |
| #047 | Launch Hello.app end to end | M7 | #046, #031 | G8 |
| #034 | Full Guest Agent protocol and vsock transport | M4 | #033, #027 |  |
| #066 | First-run provisioning | M4 | #032, #065, #068 |  |
| #069 | Idle policy and host sleep/wake | M4 | #031 |  |
| #070 | Performance harness | M4 | #031, #068 |  |
| #053 | Clipboard, plain text | M4 | #034, #068 |  |
| #071 | APKRun IME | M4 | #034, #068 |  |
| #035 | APKRun AOSP product | M5 | #034 |  |
| #036 | Store Agent | M5 | #035 |  |
| #073 | Host inspection and import formats | M6 | #036 |  |
| #037 | LocalUpdateProvider | M6 | #036 |  |
| #038 | PackageInstaller updates | M6 | #037, #073 |  |
| #039 | Update ownership | M6 | #038 |  |
| #040 | Gentle updates | M6 | #039 | G7 |
| #041 | Package and signature verification | M6 | #038, #073 |  |
| #042 | Split APK installation | M6 | #041, #073 |  |
| #043 | Update rollback | M6 | #041, #042 |  |
| #050 | DirectProvider | M6 | #037, #041 |  |
| #074 | Update scheduler | M6 | #037, #040, #050 |  |
| #055 | Android icon to macOS icon pipeline | M7 | #045, #036 |  |
| #056 | Finder, Dock, and Spotlight integration | M7 | #055 |  |
| #048 | Wrapper independent of the APK file | M7 | #047, #037 |  |
| #049 | Automatic update behind an unchanged wrapper | M7 | #043, #048 | G9 |
| #075 | `apkrun wrap` CLI | M7 | #046, #048 |  |
| #076 | Wrapper lifecycle and uninstall choices | M7 | #048 |  |
| #077 | Home and store UI | M7 | #048 |  |
| #078 | Add flow | M7 | #077, #073 |  |
| #079 | Per-app settings | M7 | #077, #039, #074 |  |
| #089 | Portable wrappers | M7 | #075 |  |
| #051 | F-Droid provider | M8 | #050 |  |
| #052 | GitHub provider | M8 | #050 |  |
| #054 | Notifications | M9 | #034, #035, #047 |  |
| #080 | Image and HTML clipboard | M9 | #053 |  |
| #081 | Links | M9 | #034, #035, #047 |  |
| #082 | Files | M9 | #034, #035 |  |
| #085 | Locale, time zone, clock format, and time | M9 | #034, #035, #069 |  |
| #086 | Menu bar | M9 | #032 |  |
| #057 | APKRun runtime updater | M10 | #031, #049 |  |
| #058 | Guest image versioning and migration | M10 | #035, #057 |  |
| #087 | Runtime image distribution | M10 | #058, #065 |  |
| #059 | `apkrun doctor` | M11 | #031, #034, #036 |  |
| #060 | Diagnostics bundle | M11 | #004, #059 |  |
| #083 | Audio output | M12 | #035 |  |
| #084 | Microphone | M12 | #083 |  |
| #088 | Developer ID signing, notarization, and distribution wrappers | M12 | #062, #046 |  |
| #090 | Compatibility database | M12 | #059 |  |
| #091 | Security hardening and fuzzing | M12 | #031, #034 |  |
| #092 | Localization and accessibility | M12 | #077 |  |
| #093 | Legal and licensing compliance | M12 | #020, #035 |  |
| #094 | v1.0 release readiness | M12 | every other v1.0 task |  |
| #096 | Vulkan track | Post-v1 | #023, #035 |  |
| #097 | Google Play authority | Post-v1 | #039, #049 |  |

---

## 4. Rules

- One task at a time per agent. Follow [../../../AGENTS.md](../../../AGENTS.md) §2.
- Follow the steps in order. If a step is wrong or impossible, fix the design document and the entry in the same commit, and say why in the commit message.
- Keep the scope. Work that is outside the entry becomes a new task: open a GitHub issue, then add its entry to the milestone file and its row to §3 in the same commit ([../../05-development/workflow.md](../../05-development/workflow.md) §2.4).
