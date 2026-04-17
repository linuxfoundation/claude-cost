# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Joins two CSV exports — an Anthropic Claude spend report and a group-membership directory (e.g. Okta) — to produce billing-group cost rollups, model breakdowns, product breakdowns, and a month-end forecast. The spend report has one row per `(user_email, product, model)` for a billing window; the directory provides the email → billing group mapping.

A user's billing group is determined by the **smallest group** they belong to (fewest members = most specific, e.g. a project group beats a department group). This is configurable — see `GROUP_PREF` below.

## Data contract

### Anthropic spend export (`input/spend-report-<uuid>-YYYY-MM-DD-to-YYYY-MM-DD.csv`)

| Column | Notes |
|---|---|
| `user_email` | Normalized to lowercase before joining |
| `product` | Browser Extension, Chat, Claude Code, Cowork, Office Agents, Voice Mode |
| `model` | Normalized to `Opus`/`Sonnet`/`Haiku` family names by `scripts/normalize-models.mlr` |
| `total_requests` | |
| `total_prompt_tokens` | |
| `total_completion_tokens` | |
| `total_net_spend_usd` | Used for all cost calculations |
| `account_uuid`, `total_gross_spend_usd` | Dropped at join time |

The billing window dates are **encoded in the filename** and parsed by the Makefile to compute `WINDOW_DAYS` and `FORECAST_DAYS` for forecasting. The window can span any range — partial month, full month, quarter, YTD, etc.

### Directory / group-membership export (`input/directory-groups-memberships_*.csv`)

The documented input is an Okta directory export, but **any CSV with `user.email` and `group.name` columns works**. Key columns used: `user.email`, `group.name`. All other columns are discarded at build time.

**Billing group resolution** — when a user belongs to multiple groups:

- By default, the group with the **fewest members** wins (most specific). Override with `GROUP_PREF=largest`.
- Ties in member count are broken alphabetically by group name (deterministic).
- Run `make verify-departments` to see group sizes and final assignment counts.
- Spend rows with no directory match land in the synthetic `Unmapped` group.

### Makefile knobs

| Variable | Default | Effect |
|---|---|---|
| `GROUP_PREF` | `smallest` | `largest` to assign users to their largest group instead |
| `EXCLUDE_GROUPS` | _(empty)_ | Regex of group names to exclude from assignments entirely (e.g. `'^Bot accounts$$'`) |
| `FORECAST_TO` | last day of `WINDOW_END`'s month | Override forecast horizon (e.g. `2026-12-31` for YTD → EOY projection) |

Examples:
```bash
make all GROUP_PREF=largest EXCLUDE_GROUPS='^Bot accounts$$'
make forecast FORECAST_TO=2026-12-31   # project YTD spend through year-end
```

## Common commands

```bash
make all                # build all four reports
make report             # output/by-department.md  — total spend per billing group
make by-model           # output/by-department-model.md  — spend by group × model family
make by-product         # output/by-department-product.md — spend by group × product
make forecast           # output/forecast.md  — daily run-rate and projected spend through FORECAST_TO
make verify-departments # print group sizes and billing assignment counts
make clean              # remove output/*.md and output/*.csv
```

Each `make <target>` prints a pretty terminal table to stdout AND writes a Markdown file to `output/`.

## Architecture

```
Makefile                     orchestrates the pipeline; auto-detects newest input files
scripts/normalize-models.mlr put: maps claude_opus*/sonnet*/haiku* → Opus/Sonnet/Haiku
scripts/fill-unmapped.mlr    put: sets $department = "Unmapped" (or known label) for unmatched spend rows
scripts/forecast.mlr         put: computes daily_rate and forecast_usd using ENV vars WINDOW_DAYS / FORECAST_DAYS
output/group_sizes.csv       intermediate: member count per group (drives assignment logic)
output/dept_map.csv          intermediate: email → billing group (one row per user)
output/joined.csv            intermediate: spend rows enriched with department
output/*.csv / *.md          final reports
```

The Makefile picks the **newest** file matching each input glob automatically:
```make
SPEND := $(lastword $(sort $(wildcard input/spend-report-*.csv)))
OKTA  := $(lastword $(sort $(wildcard input/directory-groups-memberships_*.csv)))
```

To update for a new month: drop new exports into `input/` and re-run `make all`.

## Forecasting math

The spend CSV is a pre-aggregated snapshot — there are no per-day rows. Forecast is linear run-rate:

```
daily_rate   = total_net_spend_usd / window_days
forecast_usd = total_net_spend_usd + daily_rate × max(0, forecast_days − window_days)
```

`window_days` = days from `WINDOW_START` to `WINDOW_END` (inclusive).
`forecast_days` = days from `WINDOW_START` to `FORECAST_TO` (inclusive).

Both are computed from the spend filename (and the optional `FORECAST_TO` override) via Python in the Makefile, then passed to `scripts/forecast.mlr` as environment variables `WINDOW_DAYS` / `FORECAST_DAYS`.

The `max(0, …)` clamp means: if the forecast horizon has already been reached or passed, the output reports actuals with no extrapolation (coefficient = 0). This handles full-month exports and past `FORECAST_TO` values gracefully.

The window can span any range — partial month, multi-month, YTD — without breaking the three rollup reports. Only `make forecast` changes meaning depending on window shape; use `FORECAST_TO` to set an appropriate horizon.

> **Note:** mlr 6.x does not support the `-s` flag for DSL variable injection; use `ENV["VAR"]` and export via `VAR=val mlr ...`.

## Gotchas

- Email addresses are `tolower()`-normalized in both the spend and directory pipelines before the join. If a join produces unexpectedly few matches, check for whitespace or encoding differences with `mlr --csv count-distinct -f user_email output/joined.csv`.
- The `join -j user_email -f dept_map.csv` verb must be chained **after** other `put` verbs (not as the first verb) to avoid mlr parsing `-f` as the global `--from` flag.
- `mlr sort -nr fieldname` is numeric-descending; `-rn` is not a valid flag and will cause mlr to treat the field name as a filename.
- `mlr uniq -g field` outputs only the group-by field. Use `head -n 1 -g field` to keep the full record of the first match per group.
