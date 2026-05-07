---
description: Show what's diverged in local repo from upstream template. Use when user wants to see "what's customized" or "what would sync from template change".
allowed-tools: Bash(git:*) Bash(diff:*) Read
context: fork
agent: Explore
---

# Template Diff

Compare local files vs upstream template.

T-managed files diverging:
!`git diff --name-only template/main..HEAD 2>/dev/null | head -30`

Last template sync commit (if any):
!`git log --oneline --grep="sync template" -5 2>/dev/null`

## Task

Categorize diverging files into:
- T-files with local edits (user customized — will conflict on next sync)
- P-files (expected divergence — never sync)
- Files added locally (new templates user authored — review whether to upstream)

Report concisely.
