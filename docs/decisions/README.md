# Architecture Decision Records

This directory captures load-bearing technical decisions in the AgentOS template — *why* a particular tool/pattern/architecture won over the alternatives, so future contributors don't re-litigate (or, if they do, they re-litigate with context).

## Format

We use a lightweight [Michael Nygard ADR](https://github.com/joelparkerhenderson/architecture-decision-record/blob/main/locales/en/templates/decision-record-template-by-michael-nygard/index.md) variant. Each ADR is one Markdown file named `NNNN-short-slug.md` where `NNNN` is a zero-padded sequence number.

Sections, in order:

1. **Status** — `Proposed | Accepted | Deprecated | Superseded by ADR-NNNN`
2. **Date** — ISO `YYYY-MM-DD`
3. **Context** — what problem prompted the decision, what constraints applied
4. **Decision** — what we chose, expressed in one or two paragraphs
5. **Alternatives considered** — table or sections comparing the rejected options on the criteria that mattered
6. **Consequences** — what becomes easier, what becomes harder, what we accepted as the trade-off
7. **When to revisit** — concrete triggers that would invalidate this decision

## Conventions

- **Don't edit accepted ADRs to change the decision.** Write a new ADR that supersedes the old one, and flip the old one's status to `Superseded by ADR-NNNN`. This keeps the historical trail readable.
- **Small decisions don't need an ADR.** A naming convention, a one-file refactor, a dependency bump — those go in commit messages or `CHANGELOG.md`. Reach for an ADR when the decision touches infrastructure choice, cross-cutting architecture, a public interface, or anything that affects how downstream forks operate.
- **Cite real numbers, not vibes.** "Heavier" / "more complex" by itself isn't useful — say "JVM heap 1-2GB minimum vs ~20MB Go binary" so the reader can sanity-check whether the trade-off still applies in their context.
- **One decision per file.** If you're tempted to bundle two, write two ADRs.

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [0001](0001-scheduling-layer-dagu.md) | Scheduling layer: Dagu over Kestra/Airflow/Windmill/n8n/cron-tools | Accepted | 2026-05-11 |
