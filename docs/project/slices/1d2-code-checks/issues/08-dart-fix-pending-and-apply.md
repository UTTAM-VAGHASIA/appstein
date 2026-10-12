# 08: `dart.fix_pending` and `--apply`

**What to build:** a full run lists the fixes `dart fix` would apply. A full run with `--apply` applies them and formats the project first, then checks, and names each file it rewrote. Without `--apply`, `verify` changes no project file, so CI can run it on the code it checks.

**Blocked by:** 07.

**Status:** ready-for-agent

- [ ] A full run reports one `dart.fix_pending` warning per file and code, with the count (`deprecated_member_use: 6 fixes`), on the file with no line. The totals equal what `dart fix --dry-run` of the pinned SDK prints for the same project.
- [ ] A fast run never runs this check and doesn't name it as not run.
- [ ] `appstein verify --apply` (full run) applies the pending fixes to the whole project, formats the whole project, brings the knowledge up to date, then runs every check. A fix or a format it applied is no longer reported.
- [ ] Generated files (ticket 07's rule) are not formatted by `--apply`.
- [ ] The result names each file `--apply` rewrote: an `applied` list in the JSON output, and a list before the findings in the text output. Without `--apply` the list is empty and the text output has no such section.
- [ ] `--apply` with `--fast` is a usage error (exit 3) with a clear message.
- [ ] The `verify` MCP tool has an `apply` input for the full scope with the same behaviour; its result has `applied`, its reply's text tells the agent to read those files again, and its schemas say so. `apply` with the fast scope is refused.
- [ ] A test proves that a full run without `--apply` leaves every project file byte-identical, on a project with pending fixes and unformatted files.
- [ ] After `--apply` on the fixture, a second run reports no `dart.fix_pending` and no `dart.unformatted`, and rewrites nothing.
- [ ] The guide pages for the `verify` command, the tool and the checks are updated; the guide check passes.
