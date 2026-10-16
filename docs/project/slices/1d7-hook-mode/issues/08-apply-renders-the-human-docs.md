# `--apply` renders the human docs

**What to build:** `appstein verify --full --apply` also renders the human docs into `docs/app/` when `docs.enabled` is on, so the Stop hook can be one command (design §5.3, §9.2). The order is: apply `dart fix`, format the project, bring the knowledge up to date, render the human docs, then run every check. The files rendered are named with the files rewritten.

**Blocked by:** None (can start immediately).

Status: ready-for-agent

- [ ] On a project whose human docs are behind, a full run with `--apply` renders them, and the same run's `docs.stale` check finds nothing.
- [ ] The docs are rendered after the fixes, the formatting and the knowledge refresh, with the same code as `appstein docs`, so the pages match what `appstein docs` would write.
- [ ] Each page written is in the `applied` list of the JSON output and in the text output's list before the findings; a page that didn't change is not listed.
- [ ] With `docs.enabled: false`, nothing is rendered and nothing is listed.
- [ ] A docs render that can't be done (for example a person's file in the way) leaves that page alone and is reported by `docs.stale` as before; it is not Appstein failing.
- [ ] Without `--apply`, nothing is written, as before.
- [ ] The guide pages for the verifier and the human docs describe it; the guide check passes.
