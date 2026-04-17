SPEND  := $(lastword $(sort $(wildcard input/spend-report-*.csv)))
OKTA   := $(lastword $(sort $(wildcard input/directory-groups-memberships_*.csv)))

WINDOW_START := $(shell basename "$(SPEND)" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
WINDOW_END   := $(shell basename "$(SPEND)" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
YEAR_MONTH   := $(shell echo "$(WINDOW_END)" | cut -c1-7)
WINDOW_DAYS  := $(shell python3 -c "from datetime import date as D; print((D.fromisoformat('$(WINDOW_END)') - D.fromisoformat('$(WINDOW_START)')).days + 1)")
MONTH_DAYS   := $(shell python3 -c "import calendar; y,m=map(int,'$(YEAR_MONTH)'.split('-')); print(calendar.monthrange(y,m)[1])")

.PHONY: all report by-model by-product forecast verify-departments clean

all: report by-model by-product forecast

report:     output/by-department.md
by-model:   output/by-department-model.md
by-product: output/by-department-product.md
forecast:   output/forecast.md

output:
	mkdir -p output

# Build email→billing-group map from Okta.
# Project groups (AAIF Claude, CNCF Claude) have priority 1 over department groups (priority 2).
# "Claude unapproved access" (priority 99) is excluded from billing entirely.
# After sorting by email+priority, head -n 1 keeps the highest-priority row per user.
output/dept_map.csv: $(OKTA) | output
	mlr --csv \
	  put -f scripts/tag-priority.mlr \
	  then filter '$$priority < 99' \
	  then sort -f user.email -n priority \
	  then head -n 1 -g user.email \
	  then cut -f user.email,group.name \
	  then rename user.email,user_email,group.name,department \
	  then put '$$user_email = tolower($$user_email)' \
	  "$(OKTA)" > $@

# Join spend with billing-group map in a single mlr chain.
# reorder ensures consistent schema whether or not the user matched in Okta.
output/joined.csv: $(SPEND) output/dept_map.csv | output
	mlr --csv \
	  put '$$user_email = tolower($$user_email)' \
	  then put -f scripts/normalize-models.mlr \
	  then join -j user_email -f output/dept_map.csv --ur \
	  then put -f scripts/fill-unmapped.mlr \
	  then reorder -f user_email,department \
	  then cut -x -f account_uuid,total_gross_spend_usd \
	  "$(SPEND)" > $@

output/by-department.csv: output/joined.csv
	mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department \
	  then sort -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department.md: output/by-department.csv
	@echo "=== Spend by Department ==="
	@mlr --icsv --opprint cat output/by-department.csv
	@printf '## Spend by Department\n\n' > $@
	@mlr --icsv --omd cat output/by-department.csv >> $@

output/by-department-model.csv: output/joined.csv
	mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department,model \
	  then sort -f department -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department-model.md: output/by-department-model.csv
	@echo "=== Spend by Department and Model ==="
	@mlr --icsv --opprint cat output/by-department-model.csv
	@printf '## Spend by Department and Model\n\n' > $@
	@mlr --icsv --omd cat output/by-department-model.csv >> $@

output/by-department-product.csv: output/joined.csv
	mlr --csv \
	  stats1 -a sum -f total_net_spend_usd,total_requests -g department,product \
	  then sort -f department -nr total_net_spend_usd_sum \
	  then rename total_net_spend_usd_sum,total_net_spend_usd,total_requests_sum,total_requests \
	  output/joined.csv > $@

output/by-department-product.md: output/by-department-product.csv
	@echo "=== Spend by Department and Product ==="
	@mlr --icsv --opprint cat output/by-department-product.csv
	@printf '## Spend by Department and Product\n\n' > $@
	@mlr --icsv --omd cat output/by-department-product.csv >> $@

output/forecast.csv: output/by-department.csv
	WINDOW_DAYS=$(WINDOW_DAYS) MONTH_DAYS=$(MONTH_DAYS) \
	  mlr --csv put -f scripts/forecast.mlr output/by-department.csv > $@

output/forecast.md: output/forecast.csv
	@echo "=== Month-End Forecast ($(YEAR_MONTH), window $(WINDOW_START) to $(WINDOW_END), $(WINDOW_DAYS)/$(MONTH_DAYS) days) ==="
	@mlr --icsv --opprint cat output/forecast.csv
	@printf '## Month-End Forecast ($(YEAR_MONTH))\n\nWindow: $(WINDOW_START) to $(WINDOW_END) ($(WINDOW_DAYS) of $(MONTH_DAYS) days)\n\n' > $@
	@mlr --icsv --omd cat output/forecast.csv >> $@

# Verify: flag any user assigned to both AAIF Claude and CNCF Claude simultaneously.
verify-departments: $(OKTA)
	@mlr --csv \
	  put -f scripts/tag-priority.mlr \
	  then filter '$$priority == 1' \
	  then count-distinct -f user.email \
	  then filter '$$count > 1' \
	  "$(OKTA)" | \
	awk -F, 'NR>1{n++} END{if(n>0){print n" user(s) in multiple project groups - review tag-priority.mlr";exit 1}else{print "OK: no ambiguous project-group assignments"}}'

clean:
	rm -f output/*.md output/*.csv
