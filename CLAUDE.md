@AGENTS.md

## Claude Code specifics

- To build or refresh the knowledge graph, use the `/graphify .` skill; `/graphify . --update` rebuilds changed files only.
- A slice runs through these skills in order: `/grill-with-docs`, `/to-spec`, `/to-tickets`, then `/implement` for each ticket.
- Build tickets in the main session with `/implement`. Subagents here never commit, so `/implement-spec`, which has subagents commit in worktrees, is not used in this repo.
