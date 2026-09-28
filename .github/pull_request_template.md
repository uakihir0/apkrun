<!-- Title: "#NNN Title" of the task. One task per pull request (AGENTS.md §13). -->

## Task

Closes #NNN. Task entry: `docs/04-plan/issues/M<nn>-<name>.md`

## What changed

-

## Implementation steps covered

<!-- The step numbers of the task entry that this pull request completes. -->

-

## Tests

| Tier | What ran | Result |
|---|---|---|
| T0 | | |
| T1 | | |
| T2 | | |
| T3 / manual | | |

## Checklist (AGENTS.md §12)

- [ ] Every acceptance criterion of the task is met, or this pull request says which step it completes and what remains.
- [ ] The tests the task lists pass. Graphics work is verified on real hardware, not only with mocks.
- [ ] Logging goes through DiagnosticsCore; no secrets, clipboard contents, or private app data are logged.
- [ ] Errors are typed. New user-visible errors have an entry with a remediation in `docs/03-reference/error-catalog.md`, and from #061 on in `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, and the catalog tables are regenerated with `swift scripts/errorgen.swift --markdown`.
- [ ] No import outside the dependency graph (`docs/01-architecture/modules.md` §3).
- [ ] New third-party code is pinned in `ThirdParty/ThirdParty.lock.json`, with an ADR where one is required.
- [ ] Every `TODO` has `TODO(#NNN): reason`.
- [ ] No readback in the normal frame path, and no shell command per input event.
- [ ] The scope stayed within the task. Follow-ups are filed as new tasks: #…
- [ ] The documents describe what was built (design sections, reference formats, verification logs, risks, open questions, traceability).
- [ ] An ADR is included if an architectural decision changed.

## Verification results to record

<!-- Measurements, gate evidence, answers to open questions, risk results. Say where each was recorded. -->

## Notes for reviewers
