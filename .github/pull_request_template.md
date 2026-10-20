<!-- Title: "#N Title", the task's GitHub issue number and title. One task per pull request. -->

## Task

Closes #N <!-- or "Part of #N" when the task needs more pull requests -->

## What changed

-

## Tests

| Tier | What ran | Result |
|---|---|---|
| T0 | | |
| T1 | | |
| T2 | | |
| T3 / manual | | |

<!-- Paste gate and T2 evidence (summaries, links to logs) here, not into the repository. -->

## Checklist (AGENTS.md §12)

- [ ] Every `Done when` item of the task entry holds, or this pull request says which steps it covers.
- [ ] The tests the task lists pass. A test that could not run is named above.
- [ ] Errors are typed. New user-visible errors are in `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, regenerated with `swift scripts/errorgen.swift --markdown`.
- [ ] Every `TODO` is `TODO(#N): reason`.
- [ ] No readback in the frame path, and no shell command per input event.
- [ ] Follow-up work is filed as new issues: #…
- [ ] The documents describe what was built, and `scripts/check-docs.sh` passes.
