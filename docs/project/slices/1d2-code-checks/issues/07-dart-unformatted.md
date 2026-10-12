# 07: `dart.unformatted`

**What to build:** a file whose formatting `dart format` would change is a warning. The answer comes from the project's own SDK through the analysis server, so verify can never ask for a format the developer's tools would undo. Generated files are left out.

**Blocked by:** 06.

**Status:** ready-for-agent

- [ ] A Dart file that the formatter of the project's SDK would change is a `dart.unformatted` warning on the file, with a fix hint naming `appstein verify --apply`.
- [ ] A fast run reports it only for the unverified files; a full run for every file.
- [ ] The check agrees with `dart format --output=none --set-exit-if-changed` of the pinned SDK on a fixture with formatted and unformatted files, including the project's formatter settings in `analysis_options.yaml` (such as the page width).
- [ ] A file that `analysis_options.yaml` excludes is never reported. A file that starts with a `GENERATED CODE - DO NOT MODIFY` header is never reported.
- [ ] The check never writes a file.
- [ ] A file that can't be parsed gives no `dart.unformatted` finding: its `dart.error` already says why.
- [ ] The check can be overridden with `verify.severity` and hidden by a suppression.
- [ ] The guide page for the checks is updated; the guide check passes.
