SPEND_ALL := $(sort $(wildcard input/spend-report-*.csv))
SPEND     := $(lastword $(SPEND_ALL))
OKTA      := $(lastword $(sort $(wildcard input/directory-groups-memberships_*.csv)))
N_SPEND   := $(words $(SPEND_ALL))
TAGGED    := $(patsubst input/spend-report-%.csv,output/tagged-%.csv,$(SPEND_ALL))

# Cap on MoM growth rate applied to the growth-adjusted forecast.
# Trend report always shows raw growth. Override: make forecast-growth MAX_GROWTH_PCT=30
MAX_GROWTH_PCT ?= 100

WINDOW_START := $(shell basename "$(SPEND)" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
WINDOW_END   := $(shell basename "$(SPEND)" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
WINDOW_DAYS  := $(shell python3 -c "from datetime import date as D; print((D.fromisoformat('$(WINDOW_END)') - D.fromisoformat('$(WINDOW_START)')).days + 1)")

# Forecast horizon. Default: last day of the month containing WINDOW_END.
# Override for longer windows, e.g. YTD → end of year:
#   make forecast FORECAST_TO=2026-12-31
# If FORECAST_TO <= WINDOW_END, the forecast reports actuals (no extrapolation).
FORECAST_TO   ?= $(shell python3 -c "import calendar; from datetime import date as D; d=D.fromisoformat('$(WINDOW_END)'); print(D(d.year, d.month, calendar.monthrange(d.year, d.month)[1]).isoformat())")
FORECAST_DAYS := $(shell python3 -c "from datetime import date as D; print((D.fromisoformat('$(FORECAST_TO)') - D.fromisoformat('$(WINDOW_START)')).days + 1)")

# When a user belongs to multiple groups, assign them to the "smallest" group
# (fewest members — the most specific, e.g. a project group over a department)
# or "largest" (broadest). Override at runtime: make all GROUP_PREF=largest
GROUP_PREF ?= smallest

# Optional regex of group names to exclude from billing assignments entirely.
# Example: make all EXCLUDE_GROUPS='^Contractors$$'
EXCLUDE_GROUPS ?=

ifeq ($(GROUP_PREF),largest)
  GROUP_SORT_FLAG := -nr
else
  GROUP_SORT_FLAG := -n
endif

ifeq ($(strip $(EXCLUDE_GROUPS)),)
  EXCLUDE_FILTER :=
else
  EXCLUDE_FILTER := filter '!($${group.name} =~ "$(EXCLUDE_GROUPS)")' then
endif

.PHONY: all report by-model by-product forecast top-users trend forecast-growth list-inputs verify-departments clean

ifeq ($(shell test $(N_SPEND) -ge 2 && echo yes),yes)
  ALL_EXTRA := trend forecast-growth
endif

all: report by-model by-product forecast $(ALL_EXTRA)

list-inputs:
	@for f in $(SPEND_ALL); do \
	  base=$$(basename "$$f"); \
	  WS=$$(echo "$$base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); \
	  WE=$$(echo "$$base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1); \
	  WD=$$(python3 -c "from datetime import date as D; print((D.fromisoformat('$$WE')-D.fromisoformat('$$WS')).days+1)"); \
	  MO=$${WE:0:7}; \
	  printf "%-70s  month=%-7s  window=%s to %s  (%s days)\n" "$$base" "$$MO" "$$WS" "$$WE" "$$WD"; \
	done

report:     output/by-department.md
by-model:   output/by-department-model.md
by-product: output/by-department-product.md
forecast:   output/forecast.md

output:
	mkdir -p output

# Compute the number of members per group from the directory.
# Used to resolve users belonging to multiple groups (see dept_map target).
output/tagged-%.csv: input/spend-report-%.csv | output
	@WS=$$(echo "$*" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); \
	 WE=$$(echo "$*" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1); \
	 WD=$$(python3 -c "from datetime import date as D; print((D.fromisoformat('$$WE')-D.fromisoformat('$$WS')).days+1)"); \
	 MO=$${WE:0:7}; \
	 SRC=$$(basename "$<"); \
	 WINDOW_START=$$WS WINDOW_END=$$WE WINDOW_DAYS=$$WD MONTH=$$MO SRC=$$SRC \
	 mlr --csv put -f scripts/tag-window.mlr "$<" > $@

output/spend-all.csv: $(TAGGED)
	@for f in $^; do mlr --csv --ho head -n 1 then cut -f month "$$f"; done \
	  | sort | uniq -d \
	  | while read month; do echo "WARNING: multiple spend files for month $$month — keeping rows with latest window_end" >&2; done
	@mlr --csv sort -f month -r window_end $^ \
	  | mlr --csv head -n 1 -g month,user_email,product,model > $@

output/joined-all.csv: output/spend-all.csv output/dept_map.csv
	@mlr --csv \
	  put '$$user_email = tolower($$user_email)' \
	  then put -f scripts/normalize-models.mlr \
	  then join -j user_email -f output/dept_map.csv --ur \
	  then put -f scripts/fill-unmapped.mlr \
	  then reorder -f user_email,department,month,window_start,window_end,window_days \
	  then cut -x -f account_uuid,total_gross_spend_usd \
	  output/spend-all.csv > $@

output/group_sizes.csv: $(OKTA) | output
	@mlr --csv \
	  $(EXCLUDE_FILTER) stats1 -a count -f user.email -g group.name \
	  then rename user.email_count,member_count \
	  "$(OKTA)" > $@

# Build email→billing-group map.
# Strategy: join group sizes onto each (user, group) row, then sort so the
# winning group appears first per user (smallest or largest per GROUP_PREF,
# with alphabetical tiebreak), then keep only the first row per user.
# Any email→group CSV with user_email and department columns can replace this.
output/dept_map.csv: $(OKTA) output/group_sizes.csv | output
	@mlr --csv \
	  $(EXCLUDE_FILTER) join -j group.name -f output/group_sizes.csv \
	  then sort -f user.email $(GROUP_SORT_FLAG) member_count -f group.name \
	  then head -n 1 -g user.email \
	  then cut -f user.email,group.name \
	  then rename user.email,user_email,group.name,department \
	  then put '$$user_email = tolower($$user_email)' \
	  "$(OKTA)" > $@

# Join spend with billing-group map in a single mlr chain.
# reorder ensures consistent schema whether or not the user matched in the directory.
output/joined.csv: $(SPEND) output/dept_map.csv | output
	@mlr --csv \
	  put '$$user_email = tolower($$user_email)' \
	  then put -f scripts/normalize-models.mlr \
	  then join -j user_email -f output/dept_map.csv --ur \
	  then put -f scripts/fill-unmapped.mlr \
	  then reorder -f user_email,department \
	  then cut -x -f account_uuid,total_gross_spend_usd \
	  "$(SPEND)" > $@

output/by-department.csv: output/joined.csv
	@mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department \
	  then sort -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department.md: output/by-department.csv
	@echo "=== Spend by Department ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/by-department.csv
	@printf '## Spend by Department\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/by-department.csv >> $@

output/by-department-model.csv: output/joined.csv
	@mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department,model \
	  then sort -f department -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department-model.md: output/by-department-model.csv
	@echo "=== Spend by Department and Model ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/by-department-model.csv
	@printf '## Spend by Department and Model\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/by-department-model.csv >> $@

output/by-department-product.csv: output/joined.csv
	@mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department,product \
	  then sort -f department -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department-product.md: output/by-department-product.csv
	@echo "=== Spend by Department and Product ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/by-department-product.csv
	@printf '## Spend by Department and Product\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/by-department-product.csv >> $@

output/forecast.csv: output/by-department.csv
	@WINDOW_DAYS=$(WINDOW_DAYS) FORECAST_DAYS=$(FORECAST_DAYS) \
	  mlr --csv put -f scripts/forecast.mlr output/by-department.csv > $@

output/top-users.csv: output/joined.csv
	@mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g user_email,department \
	  then sort -nr total_net_spend_usd_sum \
	  then head -n 10 \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv | \
	WINDOW_DAYS=$(WINDOW_DAYS) FORECAST_DAYS=$(FORECAST_DAYS) \
	  mlr --csv put -f scripts/forecast.mlr > $@

output/top-users.md: output/top-users.csv
	@echo "=== Top 10 Users by Spend (through $(FORECAST_TO), window $(WINDOW_START) to $(WINDOW_END), $(WINDOW_DAYS)/$(FORECAST_DAYS) days) ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/top-users.csv
	@printf '## Top 10 Users by Spend (through $(FORECAST_TO))\n\nWindow: $(WINDOW_START) to $(WINDOW_END) ($(WINDOW_DAYS) of $(FORECAST_DAYS) days)\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/top-users.csv >> $@

top-users: output/top-users.md

output/trend.csv: output/joined-all.csv
	@mlr --csv \
	  stats1 -a sum,max -f total_net_spend_usd,total_requests,window_days -g month,department \
	  then cut -f month,department,total_net_spend_usd_sum,total_requests_sum,window_days_max \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests,window_days_max,window_days \
	  then sort -f department,month \
	  then put -f scripts/trend.mlr \
	  output/joined-all.csv > $@

output/trend.md: output/trend.csv
	@echo "=== Spend Trend by Month ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/trend.csv
	@printf '## Spend Trend by Month\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/trend.csv >> $@

trend: output/trend.md

CURRENT_MONTH := $(shell echo "$(WINDOW_END)" | cut -c1-7)

output/forecast-growth.csv: output/trend.csv
	@if [ "$(N_SPEND)" -lt 2 ]; then \
	  echo "WARNING: forecast-growth requires ≥ 2 spend files. Using flat run-rate instead." >&2; \
	  cp output/forecast.csv $@ 2>/dev/null || true; \
	else \
	  CURRENT_MONTH=$(CURRENT_MONTH) WINDOW_END=$(WINDOW_END) FORECAST_TO=$(FORECAST_TO) \
	  MAX_GROWTH_PCT=$(MAX_GROWTH_PCT) python3 scripts/growth-forecast.py > $@; \
	fi

output/forecast-growth.md: output/forecast-growth.csv
	@echo "=== Growth-Adjusted Forecast (through $(FORECAST_TO), MoM growth applied, MAX_GROWTH_PCT=$(MAX_GROWTH_PCT)%) ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/forecast-growth.csv
	@printf '## Growth-Adjusted Forecast (through $(FORECAST_TO))\n\nMax growth cap: $(MAX_GROWTH_PCT)%%\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/forecast-growth.csv >> $@

forecast-growth: output/forecast-growth.md

output/forecast.md: output/forecast.csv
	@echo "=== Spend Forecast (through $(FORECAST_TO), window $(WINDOW_START) to $(WINDOW_END), $(WINDOW_DAYS)/$(FORECAST_DAYS) days) ==="
	@mlr --icsv --opprint --ofmt '%.2f' cat output/forecast.csv
	@printf '## Spend Forecast (through $(FORECAST_TO))\n\nWindow: $(WINDOW_START) to $(WINDOW_END) ($(WINDOW_DAYS) of $(FORECAST_DAYS) days)\n\n' > $@
	@mlr --icsv --omd --ofmt '%.2f' cat output/forecast.csv >> $@

# Print group-size distribution and final billing assignment counts.
# Surfaces any groups that tied on member count (resolved alphabetically).
verify-departments: output/dept_map.csv output/group_sizes.csv
	@echo "=== Group sizes ==="
	@mlr --icsv --opprint sort -nr member_count output/group_sizes.csv
	@echo ""
	@echo "=== Billing assignments ==="
	@mlr --icsv --opprint \
	  stats1 -a count -f user_email -g department \
	  then sort -nr user_email_count \
	  output/dept_map.csv
	@ROWS=$$(mlr --csv count then cut -f count output/dept_map.csv | tail -1); \
	  test "$$ROWS" -gt 0 || (echo "ERROR: dept_map is empty"; exit 1)

clean:
	rm -f output/*.md output/*.csv output/tagged-*.csv
