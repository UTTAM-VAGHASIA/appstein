# Issue tracker: files in this repo

Specs and tickets for Appstein live as committed markdown files, one folder per slice, under `docs/project/slices/`. GitHub Issues holds outside reports only, never specs or tickets.

## Layout

- One slice per folder: `docs/project/slices/<folder>/`, named `<slice id without dots>-<slug>`, such as `1d2-code-checks`.
- The spec is `docs/project/slices/<folder>/spec.md`.
- Tickets are one file each at `docs/project/slices/<folder>/issues/<NN>-<slug>.md`, numbered from `01` in dependency order.
- A ticket's state is a `Status:` line near its top: `ready-for-agent`, `claimed` or `resolved`.
- Discussion on a ticket is appended under a `## Comments` heading at its end.
- `notes.md` is written last, when the slice's work is finished: what was built, the decisions made on the way, and what is carried to later slices. The guide check treats a folder with `notes.md` as a finished slice.

`docs/project/progress.yaml` names the folder as the slice's `spec`. Add that line in the commit that adds `spec.md`, then run `fvm dart run tool/gen_docs.dart`.

## When a skill says "publish to the issue tracker"

Write the file in the slice's folder, creating the folder if needed. The owner approves a spec and a ticket breakdown before either is committed.

## When a skill says "fetch the relevant ticket"

Read the file at the path or number the owner gives.

## A spec here quotes the product design

`docs/project/specs/2026-09-29-appstein-design.md` is the product design: what Appstein is and why. A slice's spec covers one slice and cites the design sections it implements (`§9.3`). Where the two disagree, stop and ask the owner; a slice's spec never overrides the design silently.

## Wayfinding operations

Used by `/wayfinder`. The map is a file with one child file per ticket.

- **Map**: `docs/project/slices/<folder>/map.md`.
- **Child ticket**: `docs/project/slices/<folder>/issues/<NN>-<slug>.md`, with the question in the body, a `Type:` line (`research`, `prototype`, `grilling` or `task`) and a `Status:` line.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every ticket it lists is `resolved`.
- **Frontier**: the tickets that are open, unblocked and unclaimed; lowest number first.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under `## Answer`, set `Status: resolved`, then add a pointer to it in the map's decisions.
