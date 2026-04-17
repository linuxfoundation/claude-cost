# claude-costs

Generates department-level Claude spend reports by joining Anthropic cost exports with Okta group membership data.

## Requirements

- [Miller](https://miller.readthedocs.io/) (`mlr`) — `brew install miller`
- Python 3 (for date math in the Makefile)

## Setup

1. Export a **spend report** from the [Anthropic Console](https://console.anthropic.com) and drop it in `input/`
2. Export a **directory group membership** CSV from Okta and drop it in `input/`

The Makefile auto-detects the newest file matching each pattern.

## Usage

```bash
make all          # build all reports
make report       # spend by department/project
make by-model     # spend by department × model (Opus/Sonnet/Haiku)
make by-product   # spend by department × product (Claude Code, Chat, etc.)
make forecast     # projected month-end spend based on daily run-rate
make clean        # remove generated output files
```

Each target prints a table to the terminal and writes a Markdown file to `output/`.

## How billing groups work

Users are assigned to a billing group in priority order:

1. **Project group** (AAIF Claude, CNCF Claude) — takes precedence over department
2. **Department group** (Education, Sales, Products, etc.)
3. Known org-level entries (e.g. `(org service usage)` → Claude Code Review)

Run `make verify-departments` to check for data quality issues (a user assigned to multiple project groups).

## Output files

| File | Contents |
|---|---|
| `output/by-department.md` | Total spend and requests per billing group |
| `output/by-department-model.md` | Breakdown by billing group × model family |
| `output/by-department-product.md` | Breakdown by billing group × product |
| `output/forecast.md` | Daily run-rate and projected month-end spend |

> `input/` and `output/` are gitignored — they contain confidential cost data.
