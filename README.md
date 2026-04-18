# claude-costs

Generates department-level Claude spend reports by joining Anthropic cost exports with a group-membership directory (Okta or any IdP).

## Requirements

- [Miller](https://miller.readthedocs.io/) (`mlr`) — `brew install miller`
- Python 3 (for date math in the Makefile)

## Setup

### 1. Claude spend report

Export a spend report from Claude Enterprise analytics and drop it in `input/`. The Makefile auto-detects files matching `input/spend-report-*.csv`.

### 2. Group-membership export

This is the most important step to get right. The pipeline needs a CSV that maps each user's email to the billing group (department or project) responsible for their Claude spend. **The export must include only the groups that represent billing units** — not every group in your IdP.

#### Why filtered?

Anthropic's cost export doesn't include group data. We reconstruct it from your IdP. If you export all groups unfiltered, the "smallest group" heuristic assigns users to narrow infrastructure groups (`aws-prod-admin`, `Snowflake Users`, etc.) rather than their billing department.

The correct source is the set of groups you've explicitly assigned to Claude roles in your IdP (Owner, Admin, custom roles). Export only those.

#### Okta: step-by-step

In Okta, groups are pushed to Claude Enterprise via the application's **Assignments** tab (one group per role). To export the membership of those groups:

1. Okta Admin Console → **Reports** → **Reports**
2. Click **Group Memberships**
3. Under **Filter by group**, select **includes**, then add each billing group one by one (see list below)
4. Run the report and download the CSV
5. Drop the file in `input/` — it will be named `directory-groups-memberships_<timestamp>_<uuid>.csv`

**Current billing groups at LF** (all assigned as custom roles in Claude):

| Group name |
|---|
| AAIF Claude |
| Claude Owners *(Owner role)* |
| Claude Security Team |
| Claude unapproved access |
| CNCF Claude |
| Creative Services |
| Education |
| Events |
| Fellows |
| IT Admins *(Admin role)* |
| IT Services |
| Marketing Operations |
| Products |
| Program Management Operations |
| Project Marketing & Communications |
| Research |
| Sales |
| Strategic Programs |

> **Note:** This list changes as new teams onboard. Update the Okta report filter and `config/billing-groups.csv` together whenever a new group is added.

#### Alternative: pipeline-side filtering

If you prefer to export all group memberships and let the pipeline filter, copy the billing-groups config:

```bash
cp config/billing-groups.example.csv config/billing-groups.csv
# Edit config/billing-groups.csv to match your current billing groups
```

When `config/billing-groups.csv` exists, the pipeline ignores groups not in that file before running group-resolution. See [Config files](#config-files) below.

#### Other IdPs / custom sources

Any CSV with `user.email` and `group.name` columns works — Okta is not required. The file just needs to map each user's email to their billing group. The `directory-groups-memberships_*.csv` filename pattern is preferred; `access-users-app-instances_*.csv` (Okta app-access exports) also work as a fallback.

> **Direct (non-group) assignments:** If a user was added to Claude individually rather than via a group, they will appear as `Unmapped`. Fix this in the IdP (add them to a billing group) or use `config/user-overrides.csv` as a stop-gap.

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
make verify-departments  # show group sizes and final billing assignments
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

When a user belongs to multiple billing groups, they are assigned to the **smallest group** (fewest members) by default — smaller groups are typically more specific (a project sub-group beats a broad department). Override with `GROUP_PREF=largest`. Ties are broken alphabetically.

```bash
make all                            # default: smallest-group wins
make all GROUP_PREF=largest         # assign to broadest group instead
make all EXCLUDE_GROUPS='^Bots$$'   # exclude a group from billing entirely
```

## Config files

Two optional CSV files in `config/` let you tune group resolution without changing the Okta export or the pipeline scripts. Copy the `.example.csv` files to activate:

```bash
cp config/billing-groups.example.csv config/billing-groups.csv
cp config/user-overrides.example.csv config/user-overrides.csv
```

Real config files are gitignored (they contain org-specific data). The `.example.csv` files serve as templates and are committed to the repo.

### `config/billing-groups.csv`

**Columns:** `group.name`

An allowlist of groups eligible for billing attribution. When present, the pipeline filters the group-membership export to only these groups before running group-resolution. This is an alternative to filtering at Okta export time.

Use this when:
- You want to export all group memberships and let the pipeline do the filtering
- You need to quickly add or remove a billing group without re-running the Okta report

```csv
group.name
Education
Products
Sales
```

### `config/user-overrides.csv`

**Columns:** `user_email`, `department_override`

Per-user department overrides applied as a final step, after all group-based resolution. Handles three cases:

1. **Tie-breaking**: a user belongs to two equal-sized billing groups and the alphabetical default picks the wrong one
2. **Policy exceptions**: a user's role means they should be billed to a different group than their Okta membership implies
3. **Unmapped catch-all**: a user has a direct (non-group) Okta assignment and can't be moved to a group right now

```csv
user_email,department_override
user@example.org,Engineering
another@example.org,Research
```

Overrides apply whether the user would otherwise map to a billing group or land in `Unmapped`.

## Time window flexibility

The three rollup reports (`report`, `by-model`, `by-product`) are window-agnostic — they work on any export: partial month, full month, quarter, YTD, etc.

`make forecast` projects spend linearly to a configurable horizon. The default horizon is the last day of the month containing the export's end date. Override with `FORECAST_TO` for longer windows:

```bash
make forecast                           # default: project through end of current month
make forecast FORECAST_TO=2026-12-31    # YTD export → end-of-year projection
```

If `FORECAST_TO` falls on or before the window end date, the forecast reports actuals with no extrapolation.

## Output files

| File | Contents |
|---|---|
| `output/by-department.md` | Active users, total spend, EOM-projected avg spend/user, and requests per billing group |
| `output/by-department-model.md` | Breakdown by billing group × model family |
| `output/by-department-product.md` | Breakdown by billing group × product |
| `output/forecast.md` | Flat run-rate projection through `FORECAST_TO` with projected avg spend/user |
| `output/top-users.md` | Top 10 users by spend with EOM forecast |
| `output/trend.md` | MoM spend trend per department: active users, avg spend/user, spend growth %, user growth % |
| `output/forecast-growth.md` | Growth-adjusted projection (EOM + optional annual) |

> `input/` and `output/` are gitignored — they contain confidential cost data. `config/*.csv` is also gitignored; only `.example.csv` templates are tracked.
