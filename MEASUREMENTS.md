# Measurements

Does `claude-tiered` actually reduce paid usage, or just move work around?

**This is not a benchmark.** It is two tasks, run once each through two profiles, on one machine, with one particular mix of providers. Reproduce it on your own setup before trusting the numbers — the method is below.

Measured 2026-09-06.

---

## Method

Both profiles were given a byte-identical prompt. Everything was counted from the gateway's own call logs (`~/.omniroute/call_logs/*/*.json`), which record the provider, model, and token counts of every upstream request.

`claude-pro` had all three model slots pointed at one chain headed by `claude/claude-opus-5-high`. `claude-tiered` split them:

| Slot | Combo | Head of chain |
|---|---|---|
| `opus` | `tier-heavy` | `claude/claude-opus-5-high` (paid) |
| `sonnet` | `tier-mid` | `antigravity/claude-sonnet-4-6-high` (free) |
| `haiku` | `tier-cheap` | `antigravity/gemini-3.7-flash-high` (free) |

"Paid" means requests served by the `claude` provider — a Claude Pro subscription. "Free" means everything else.

---

## Task 1 — small

> Read every `.md` and `.ps1` file in this repository and produce a markdown table: filename, then its purpose in under 10 words. Cover all of them.

Eight files.

| | Time | Paid calls | Paid input | Paid output | Free calls | Free input |
|---|---|---|---|---|---|---|
| `claude-pro` | **21 s** | **3** | **112,884** | 1,158 | 0 | 0 |
| `claude-tiered` | 100 s | 6 | 208,855 | 3,525 | 18 | 354,538 |

**`claude-tiered` lost on every axis.** Slower, more paid calls, more paid tokens, and 354k free tokens spent on top. The overhead of dispatching subagents and folding their results back in exceeded any saving, because there was not enough work to spread.

Both answers were correct.

---

## Task 2 — volume

> `vol_files.txt` lists 20 JSON call-log files. For EACH file, read it and summarise in at most 8 words what that request was trying to do. Output a numbered list of 20 lines. Do not use grep or scripts to shortcut — each needs reading and judgement.

Twenty documents, each needing to be read and judged individually.

| | Time | Paid calls | Paid input | Paid output | Free calls | Free input |
|---|---|---|---|---|---|---|
| `claude-pro` | **155 s** | 60 | 3,305,563 | 21,000 | 0 | 0 |
| `claude-tiered` | 529 s | **14** | **678,897** | **12,423** | 97 | 1,811,961 |

`claude-tiered` used **4.9× fewer paid input tokens** and **4.3× fewer paid calls**, and took **3.4× longer**.

Both answers were correct.

---

## The mechanism

The saving does not come from you asking for delegation.

Claude Code fans work out to subagents on its own when a task has parallel parts. Those subagents use whatever the `haiku` and `sonnet` aliases point at. If every alias points at your expensive model — which is what a single-model setup means — **every subagent is expensive**.

That is the whole gap. On task 2, `claude-pro` made **60 paid Opus calls** because its fan-out inherited Opus. `claude-tiered` made **14**, because the fan-out landed on `tier-cheap`.

You do not need this project to act on that. Plain Claude Code has `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL`; pointing either at something cheaper captures most of the effect.

---

## What this does not show

- **Single runs.** One sample per cell. The direction is consistent and the volume gap is large, but the exact multiples will move.
- **One environment.** One machine, one provider mix, one afternoon. Free-provider latency in particular varies a lot.
- **No cost claim.** Everything above is subscription usage, not money. How cache reads meter against a Claude Pro plan is not something these logs reveal, so no cache-adjusted arithmetic is attempted here.
- **No quality benchmark.** Both profiles answered both tasks correctly. Two tasks is not enough to claim anything about quality either way.
- **"Free" is not unlimited.** Task 2 pushed 1.8 M tokens onto free accounts, which have their own limits. Consumption moves; it does not disappear.

## Reproducing this

1. Note the time in UTC.
2. Run your task through one profile, then the other, with the same prompt.
3. Read `~/.omniroute/call_logs/<date>/*.json` and sum `summary.tokens` grouped by `summary.provider` for entries after your marker.

`summary.provider` tells you which account served each request, which is the number that matters.
