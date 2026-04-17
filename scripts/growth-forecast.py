"""
Growth-adjusted forecast. Reads output/trend.csv and writes forecast rows to stdout.

ENV vars (required):
  CURRENT_MONTH    YYYY-MM of the most recent spend window (e.g. 2026-04)
  WINDOW_END       Last date of the current window (YYYY-MM-DD)
  FORECAST_TO      Projection horizon (YYYY-MM-DD)
  MAX_GROWTH_PCT   Cap on MoM growth rate applied to projections (e.g. 100 = 100%)
"""
import csv, os, sys
from datetime import date, timedelta
import calendar

current_month = os.environ["CURRENT_MONTH"]
window_end    = date.fromisoformat(os.environ["WINDOW_END"])
forecast_to   = date.fromisoformat(os.environ["FORECAST_TO"])
max_growth    = float(os.environ["MAX_GROWTH_PCT"]) / 100.0

# Last day of the current window's month
cm_year, cm_month = int(current_month[:4]), int(current_month[5:7])
current_month_end = date(cm_year, cm_month, calendar.monthrange(cm_year, cm_month)[1])

# Load trend rows into a dict: {department: {month: row}}
trend_rows = {}
with open("output/trend.csv") as f:
    for row in csv.DictReader(f):
        dept  = row["department"]
        month = row["month"]
        trend_rows.setdefault(dept, {})[month] = row

writer = csv.DictWriter(sys.stdout, fieldnames=[
    "department", "prior_month", "current_month",
    "prior_daily_rate_usd", "current_daily_rate_usd",
    "mom_growth_pct", "growth_pct_applied",
    "eom_forecast_usd", "forecast_to_usd",
])
writer.writeheader()

departments = sorted(trend_rows.keys())
for dept in departments:
    months_for_dept = sorted(trend_rows[dept].keys())
    if current_month not in months_for_dept:
        continue

    cur = trend_rows[dept][current_month]
    cur_daily  = float(cur["daily_rate_usd"])
    cur_actual = float(cur["total_net_spend_usd"])

    # Find prior month (latest month before current_month)
    prior_months = [m for m in months_for_dept if m < current_month]
    if prior_months:
        pri = trend_rows[dept][prior_months[-1]]
        pri_daily  = float(pri["daily_rate_usd"])
        prior_month_label = pri["month"]
        if pri_daily > 0:
            raw_growth = cur_daily / pri_daily - 1
        else:
            raw_growth = 0.0
    else:
        pri_daily  = 0.0
        prior_month_label = ""
        raw_growth = 0.0

    growth_capped = min(max(raw_growth, 0.0), max_growth)

    # EOM forecast: remaining days at current daily rate (growth already reflected in current rate)
    days_remaining = (current_month_end - window_end).days
    eom_forecast   = cur_actual + cur_daily * days_remaining

    # Project forward from current_month_end+1 through forecast_to
    forecast_to_usd = eom_forecast
    if forecast_to > current_month_end:
        projected_daily = cur_daily  # start from current daily rate
        proj_date = current_month_end + timedelta(days=1)
        while proj_date <= forecast_to:
            # Apply one month of compounding at the start of each new month
            projected_daily = projected_daily * (1 + growth_capped)
            # Days in this projected month capped by forecast_to
            _, mdays = calendar.monthrange(proj_date.year, proj_date.month)
            month_end = date(proj_date.year, proj_date.month, mdays)
            actual_end = min(month_end, forecast_to)
            days_in_slice = (actual_end - proj_date).days + 1
            forecast_to_usd += projected_daily * days_in_slice
            proj_date = month_end + timedelta(days=1)

    writer.writerow({
        "department":            dept,
        "prior_month":           prior_month_label,
        "current_month":         current_month,
        "prior_daily_rate_usd":  f"{pri_daily:.4f}",
        "current_daily_rate_usd": f"{cur_daily:.4f}",
        "mom_growth_pct":        f"{raw_growth * 100:.2f}" if prior_month_label else "",
        "growth_pct_applied":    f"{growth_capped * 100:.2f}" if prior_month_label else "",
        "eom_forecast_usd":      f"{eom_forecast:.2f}",
        "forecast_to_usd":       f"{forecast_to_usd:.2f}" if forecast_to > current_month_end else "",
    })
