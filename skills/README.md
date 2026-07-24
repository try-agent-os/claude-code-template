# Skills

Live skills of this instance, in Claude Code skill format:
`skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`,
optionally `when_to_use`, `allowed-tools`).

Skills live here at the top level rather than under `.claude/skills/`
because the sync engine keeps `.claude/` out of the repo (see
`.gitignore`) — anything meant to persist has to live outside it.

Copy patterns from [`examples/skills/`](../examples/skills/) and adapt.
