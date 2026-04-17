# claude-costs

Generates department-level Claude spend reports by joining Anthropic cost exports with Okta group membership data.

## Requirements

- [Miller](https://miller.readthedocs.io/) (`mlr`) — `brew install miller`
- Python 3 (for date math in the Makefile)

## Setup

1. Export a **spend report** from Claude Enterprise analytics and drop it in `input/`
2. Export a **directory group membership** CSV from Okta and drop it in `input/`

The Makefile auto-detects the newest file matching each pattern.

## Usage

```bash
make all              # build all reports (auto-includes trend + forecast-growth when ≥ 2 spend files present)
make report           # spend by department/project
make by-model         # spend by department × model (Opus/Sonnet/Haiku)
make by-product       # spend by department × product (Claude Code, Chat, etc.)
make forecast         # flat run-rate projection through FORECAST_TO
make top-users        # top 10 users by spend with EOM forecast
make trend            # month-over-month spend trend per department (requires ≥ 2 spend files)
make forecast-growth  # growth-adjusted forecast using MoM trend (requires ≥ 2 spend files)
make list-inputs      # show all detected spend files with parsed date windows
make clean            # remove generated output files
```

Each target prints a table to the terminal and writes a Markdown file to `output/`.

### Multi-month workflow

Drop multiple spend exports into `input/` — the pipeline picks them all up automatically. Existing reports always reflect the **newest** file. `trend` and `forecast-growth` use all files to compute MoM growth rates.

```bash
# Drop last month's full export + this month's MTD, then:
make all

# Growth-adjusted EOY projection with conservative 30% monthly growth cap:
make forecast-growth FORECAST_TO=2026-12-31 MAX_GROWTH_PCT=30
```

## How billing groups work

When a user belongs to multiple groups, they are assigned to the **smallest group** (fewest members) by default — smaller groups are typically more specific (a project sub-group beats a broad department). Override with `GROUP_PREF=largest`. Ties are broken alphabetically.

```bash
make all                            # default: smallest-group wins
make all GROUP_PREF=largest         # assign to broadest group instead
make all EXCLUDE_GROUPS='^Bots$$'   # exclude a group from billing entirely
```

## Time window flexibility

The three rollup reports (`report`, `by-model`, `by-product`) are window-agnostic — they work on any export: partial month, full month, quarter, YTD, etc.

`make forecast` projects spend linearly to a configurable horizon. The default horizon is the last day of the month containing the export's end date. Override with `FORECAST_TO` for longer windows:

```bash
make forecast                           # default: project through end of current month
make forecast FORECAST_TO=2026-12-31    # YTD export → end-of-year projection
```

If `FORECAST_TO` falls on or before the window end date, the forecast reports actuals with no extrapolation.

Run `make verify-departments` to see group sizes and final assignment counts.

The directory input is documented as an Okta export, but **any CSV with `user.email` and `group.name` columns works** as the mapping source.

## Output files

| File | Contents |
|---|---|
| `output/by-department.md` | Total spend and requests per billing group |
| `output/by-department-model.md` | Breakdown by billing group × model family |
| `output/by-department-product.md` | Breakdown by billing group × product |
| `output/forecast.md` | Flat run-rate projection through `FORECAST_TO` |
| `output/top-users.md` | Top 10 users by spend with EOM forecast |
| `output/trend.md` | MoM daily rate and growth % per department |
| `output/forecast-growth.md` | Growth-adjusted projection (EOM + optional annual) |

> `input/` and `output/` are gitignored — they contain confidential cost data.
