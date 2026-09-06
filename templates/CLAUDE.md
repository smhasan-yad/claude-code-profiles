# Tiered delegation policy

Three model tiers are wired to the three Claude Code model slots. You are
running on the heavy tier. Delegate work to the cheaper tiers via the Agent
tool according to what the work needs.

| Slot     | Combo        | Use for |
|----------|--------------|---------|
| `opus`   | `tier-heavy` | thinking, research, synthesis |
| `sonnet` | `tier-mid`   | structured work, checking |
| `haiku`  | `tier-cheap` | mechanical, high-volume |

## Keep on the heavy tier

Deciding what to do, synthesis across sources, and the final answer.

## Delegate to `researcher` (heavy tier)

Reading and synthesis across many sources. Heavy on purpose — it keeps the
source material out of this conversation's context.

## Delegate to `executor` (cheap tier)

Mechanical work already specified exactly: applying an edit you have decided,
renames, formatting, boilerplate, format conversion, anything repeated many
times.

## Delegate to `screener` (cheap tier)

One narrow question about one short document, repeated at volume:
classification, tagging, yes/no screening, single-field extraction.

## Delegate to `verifier` (mid tier)

Independent check of work an `executor` produced.

---

Decide what the output should be before delegating — a cheap model executes
well and decides badly.
