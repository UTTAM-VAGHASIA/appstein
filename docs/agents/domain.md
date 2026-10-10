# Domain docs

Where Appstein's vocabulary and decisions are written, for skills that explore the repo.

## Read before exploring

- **The product design**, `docs/project/specs/2026-09-29-appstein-design.md`: the sections for the area you are working in. Its §23 is the glossary today.
- **`GLOSSARY.md`** at the repo root, once it exists.
- **`docs/adr/`**, once it exists: the decision records that touch your area.
- **`docs/guide/`**: how the area works now.

A missing `GLOSSARY.md` or `docs/adr/` is normal. `/domain-modeling` creates them when a term or a decision is actually settled.

## Use the project's words

Name a concept the way the design and the guide name it: slice, pack, check, finding, knowledge store, project map. A term you need that neither defines is a gap to raise with the owner.

## Decisions

A decision that changes the product design is the owner's. Record it as an ADR in `docs/adr/` and change the design text only with the owner's approval. Output that contradicts the design or an ADR says so in plain words.
