<!-- covers: none -->

# How to: add a guide page

These steps add a page to this guide. A new page usually comes with new code: the slice that builds something also writes its page ([spec §19.6](../../project/specs/2026-09-29-appstein-design.md#196-documentation-for-humans-working-on-appstein)). [docs-tooling](../docs-tooling.md) explains every rule the guide check applies.

## 1. Create the page

**File:** `docs/guide/<name>.md`, or `docs/guide/how-to/<name>.md` for a how-to.

Name it after what it explains, in lowercase words joined by `-`, such as `sdk-lookups.md`. Explain how the code works now, and why; link to the spec for what was decided, instead of repeating it. Don't describe code that doesn't exist yet.

Link to source files with relative links (`../../packages/...` from a top-level page, `../../../packages/...` from `how-to/`), or name them as backticked repo paths. The check verifies both. Don't paste Dart code: `dart` code blocks are refused, so link to the real code instead.

## 2. Put the covers comment first

The first line of the page lists the files it explains, as repo-relative globs:

```text
<!-- covers:
packages/appstein_engine/lib/src/sdk/**
packages/appstein_protocol/lib/src/sdk_info.dart
-->

# Finding Flutter, the JDK and the Android SDK
```

A page about one file can put it on one line, `<!-- covers: <path> -->`. A page that explains no particular file, such as a how-to about process, says `<!-- covers: none -->`.

Every glob must match at least one file. Covering a source file means a change to that file must also change this page, or confirm it with a `Docs-Checked` trailer.

## 3. Link it from the guide map

**File:** [README](../README.md)

Add a row to the "Guide map" table: the page, and what a reader learns from it. The check fails for a page that no chain of links reaches from the README.

## 4. Add generated sections, if the page shows code facts

If the page shows a fact the code already knows, such as a list of commands or checks, generate it instead of typing it:

- **Top-level pages only.** Generated links are written relative to `docs/guide/`, so a section in `how-to/` would get broken links.
- **To show an existing section,** put its empty marker pair on two lines of their own, `<!-- generated:<section> -->` and then `<!-- /generated:<section> -->`. [docs-tooling](../docs-tooling.md#generated-sections) lists the sections.
- **A new kind of section** needs a generator in [`generators.dart`](../../../tool/src/generators.dart), added to `renderSections`, with a test in [`generators_test.dart`](../../../test/generators_test.dart).

## 5. Run the tools

From the repo root:

```powershell
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

The first fills the generated sections; read them in place. The second must print `Guide check passed.`
