# On-device verification (T2/T3)

Status: active · Owners: everyone who merges a task with T2/T3 or gate steps

Most v1 tasks were implemented and reviewed against T0/T1 only: this
repository's pull-request CI runs on shared macOS runners that cannot boot
Virtualization.framework guests, so every check that needs a real VM, a real
Android image, the reference Mac, a signing identity, or a person is still
open. This document is the single list of what must run on hardware before
v1.0, and how to run it.

An issue whose code is on `main` but whose T2/T3 or gate steps have not run
carries the `needs-verification` label. Remove the label (and close the
issue per AGENTS.md §2 step 7) only after the listed runs pass on hardware.

## 1. Where things run

| What | Where | Entry point |
|---|---|---|
| T2 VM integration | `apkrun-lab` self-hosted runner or the reference Mac | `xcodebuild test -scheme IntegrationTests` ([docs/04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.4) |
| T3 acceptance | Reference Mac, network, credentials, long runs | `nightly.yml`, gate scripts ([docs/04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.5) |
| Gates G1–G9 | Reference Mac | the gate scripts in `scripts/gate/` per [docs/04-plan/roadmap.md](../04-plan/roadmap.md) §2 |
| Manual checks | A person on a real Mac | per-task `Check:` steps |

## 2. Procedure per issue

1. Pick an issue labeled `needs-verification`.
2. Read its entry in `docs/04-plan/issues/` — the `Tests` row lists the
   tiers and the named suites.
3. On the reference Mac (Apple silicon, macOS 27, provisioned with
   `scripts/bootstrap`):
   - T2: `xcodebuild test -scheme IntegrationTests -only-testing:<suite>`
   - T3/manual: run the entry's `Check:` steps and record evidence.
4. Post the result on the issue (runner, image version, pass/fail,
   artifacts path), then remove `needs-verification` when every listed
   run passed; on failure file a `bug` issue and keep the label.

## 3. Tracking list

Generated from the issue entries that list T2/T3 tests (84 issues).
Maintained in the repository via the `needs-verification` label rather
than duplicated here — `gh issue list --label needs-verification` is the
live view. Snapshot at writing:

- Boot/runtime core: #4, #5, #6, #7, #8, #12, #13, #14, #15, #16, #17,
  #18, #20
- Input, windows, runtime APIs: #26, #27, #28, #29, #30, #31, #32, #33,
  #35
- Packages and updates: #36, #37, #38, #39, #40, #41, #42, #43, #44, #45,
  #46, #47, #48, #49, #50, #51, #52, #53
- Desktop integration: #54, #55, #56, #57, #58, #59, #60, #61, #64, #66,
  #67, #68, #69, #70, #71, #72, #73, #74, #75, #76, #77, #78, #79, #80,
  #81, #82, #83, #84, #85, #86, #87, #88, #89, #90, #91, #92, #93, #94,
  #95, #96
- Bring-up follow-ups: #100, #101, #102, #103, #105, #116, #120

## Manual follow-ups that need repository admin rights

The session that maintains this list runs without GitHub API credentials. The
following items are policy decisions and bookkeeping that need a human with
write access to the repository, or a token in CI:

- Apply the `needs-verification` label to every open issue in the tracking
  list above. The label is the queue the on-device pass works from.
- Close pull requests superseded by the merge cascade (the re-created
  task branches and the user drafts whose issues shipped under the chain).
- Close each verified issue once its T2/T3 row is green on a reference Mac.

## Items that require physical hardware

These checks cannot run in CI. They need an Apple silicon Mac with the
reference image and, where marked, a signed build:

- Every `T2` row in the tracking list (VM boot, guest agent, input, display,
  clipboard, audio, power lifecycle, diagnostics capture).
- Every `T3` row (acceptance and manual flows: onboarding, wrap-and-install,
  update behind an unchanged wrapper, menu bar, notifications).
- Notarized `wrap --distribution` output and Gatekeeper first-run
  (Developer ID identity required).
- Performance markers in `perf/` collected on the reference Mac.
