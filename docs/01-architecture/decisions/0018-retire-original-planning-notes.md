# 0018. Retire original planning notes

- Status: Accepted
- Date: 2026-09-28
- Related: [documentation map](../../README.md), [traceability](../../04-plan/traceability.md)

## Context

The original planning notes have been superseded by the product requirements, architecture and design documents, task plan, and accepted ADRs in this repository. References to their section numbers are no longer useful to implementers and cannot be followed once the notes are removed.

## Decision

- Remove the two root-level planning note files.
- Treat the versioned documents under `docs/`, together with `AGENTS.md`, as the project specification.
- Keep traceability through requirement IDs, task numbers, design-section links, and ADRs. Retain the `D-01`–`D-30` identifiers as a register of current design decisions.
- Remove references and source mappings that depend on the retired notes.

## Alternatives considered

- Keep the notes as read-only historical files. Rejected because the current specification already contains the maintained requirements, design, and implementation plan, while the old section references create a second, stale navigation system.

## Consequences

- The original notes and their section numbering are no longer available in the repository.
- New documentation cites current requirements, tasks, design sections, risks, open questions, or ADRs.
- The requirements-to-design-to-verification matrix remains the canonical traceability index.

## Verification

Confirm that both files are absent and that the repository documentation contains no references to them or their section labels.
