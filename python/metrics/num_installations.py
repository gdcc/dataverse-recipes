#!/usr/bin/env python3
import urllib.request as urlrequest
import json
import sys
import argparse
from datetime import datetime


def main():
    parser = argparse.ArgumentParser(
        description="Show a count or a list of Dataverse installations."
    )
    parser.add_argument("-d", "--date", help="A date in YYYY-MM format.", type=str)
    parser.add_argument(
        "-l",
        "--list",
        help="Print the installations instead of a count.",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    args = parser.parse_args()
    base_url = "https://hub.dataverse.org/api/installation/metrics/monthly"
    date = ""
    if args.date:
        desired_month = parse_date(args.date)
        # Figure out next month, needed to pass to API
        year = desired_month.year
        month = desired_month.month + 1
        if month > 12:  # Handle year rollover
            month = 1
            year += 1
        next_month = datetime(year, month, 1)
        from_date = desired_month.strftime("%Y-%m")
        to_date = next_month.strftime("%Y-%m")
        date = f"?fromDate={from_date}&toDate={to_date}"

    # For March 2025 we use https://hub.dataverse.org/api/installation/metrics/monthly?fromDate=2025-03&toDate=2025-04
    url = base_url + date
    if args.verbose:
        print(f"Fetching data from {url}")

    metrics_json = fetch_metrics(url)

    if args.list:
        for i in metrics_json:
            print(i["name"])
    else:
        print(len(metrics_json))


def parse_date(date_str):
    try:
        return datetime.strptime(date_str, "%Y-%m")
    except ValueError as e:
        print(f"Invalid date format: {date_str}. Expected format is YYYY-MM.")
        sys.exit(1)


def fetch_metrics(url):
    response = urlrequest.urlopen(url)
    return json.loads(
        response.read().decode(response.info().get_param("charset") or "utf-8")
    )


if __name__ == "__main__":
    main()
