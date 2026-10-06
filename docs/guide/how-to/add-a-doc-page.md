<!-- covers: none -->

# Add a doc page

This adds a page to the human docs a project gets in its docs folder, or a section to an existing page. Read [human-docs](../human-docs.md) first for how pages are built.

1. **Decide who owns it.** Text about a stack or a platform belongs in that pack (`packages/appstein_engine/lib/src/packs/<pack>/`). Only a page that is the same for every stack and platform belongs in the engine (`packages/appstein_engine/lib/src/docs/pages/`). The engine core never imports a pack.

2. **Write the test first.** Build a small `DocsKnowledge` with `sampleKnowledge` and expect the exact Markdown. Cover the empty case (no routes, no features) and text that Markdown would misread: a `|`, a backtick, a `#` at the start, a file name with a space.

3. **Write the page source.** Implement `DocPage`: an `id` for error messages, and `sections`, which returns one `DocSection` per file it writes to.
   - Read only the `DocsKnowledge` it is given. No file access, no clock.
   - Sort everything, so the output never depends on the file system.
   - Escape every text that comes from the app: `mdText` in sentences and table cells, `mdCode` for names and paths, `mdQuote` for free text, `mermaidLabel` in diagrams. Link to project files with `projectLink` and to other pages with `pageLink`.
   - Never guess: a value the knowledge doesn't hold is shown as unknown, with the reason.
   - To add to an existing page, return a section with that page's path. Sections are joined in pack order.

4. **Register it.** Add it to the pack's `docPages`, or to `engineDocSource` for an engine page.

5. **Bump the template version** when you change the shape of pages that projects already have: the pack's `version`, or `docsEngineVersion` for an engine page. The marker of those pages then changes once.

6. **Update the goldens.** Run [`docs_run_test.dart`](../../../packages/appstein_engine/test/docs/docs_run_test.dart) with `APPSTEIN_UPDATE_GOLDENS=1`, then read every changed golden as a person would. If it reads badly, fix the page source.

7. **Update the guide**: the pages table in [human-docs](../human-docs.md), and spec §6.9 if the page is new (the owner approves spec text).
