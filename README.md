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
make all          # build all reports
make report       # spend by department/project
make by-model     # spend by department × model (Opus/Sonnet/Haiku)
make by-product   # spend by department × product (Claude Code, Chat, etc.)
make forecast     # projected month-end spend based on daily run-rate
make clean        # remove generated output files
```

Each target prints a table to the terminal and writes a Markdown file to `output/`.

## How billing groups work

When a user belongs to multiple groups, they are assigned to the **smallest group** (fewest members) by default — smaller groups are typically more specific (a project sub-group beats a broad department). Override with `GROUP_PREF=largest`. Ties are broken alphabetically.

```bash
make all                            # default: smallest-group wins
make all GROUP_PREF=largest         # assign to broadest group instead
make all EXCLUDE_GROUPS='^Bots$$'   # exclude a group from billing entirely
```

Run `make verify-departments` to see group sizes and final assignment counts.

The directory input is documented as an Okta export, but **any CSV with `user.email` and `group.name` columns works** as the mapping source.

## Output files

| File | Contents |
|---|---|
| `output/by-department.md` | Total spend and requests per billing group |
| `output/by-department-model.md` | Breakdown by billing group × model family |
| `output/by-department-product.md` | Breakdown by billing group × product |
| `output/forecast.md` | Daily run-rate and projected month-end spend |

> `input/` and `output/` are gitignored — they contain confidential cost data.
