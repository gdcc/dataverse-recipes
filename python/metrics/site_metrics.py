#!/usr/bin/env python3
import urllib.request as urlrequest
import json
import sys
import argparse
from datetime import datetime


def main():
    parser = argparse.ArgumentParser(
        description="Show metrics for a Dataverse installation."
    )
    parser.add_argument("-d", "--date", help="A date in YYYY-MM format.", type=str)
    parser.add_argument(
        "-i",
        "--id",
        help="A dvHubID from https://hub.dataverse.org/api/installation",
        type=str,
    )
    parser.add_argument(
        "-l",
        "--list",
        help="A list of valid IDs (dvHubID) from https://hub.dataverse.org/api/installation",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    args = parser.parse_args()

    if args.list:
        sites = fetch_metrics("https://hub.dataverse.org/api/installation")
        for i in sorted(sites, key=lambda x: x["name"].lower()):
            print(f'{i["dvHubId"]} {i["name"]} {i["hostname"]}')
        sys.exit(0)

    dv_hub_id = None
    desired_month = None

    if args.id:
        dv_hub_id = args.id
    else:
        print(f"You put provide an ID. See -h for help.")
        sys.exit(1)

    if args.date:
        desired_month = parse_date(args.date)
    else:
        desired_month = datetime.now()

    url = construct_url(desired_month, dv_hub_id)

    if args.verbose:
        print(f"Fetching data from {url}")

    metrics_json = fetch_metrics(url)

    if not metrics_json:
        print(f"No metrics available. Add -v to see URL. Try -h for help.")
        sys.exit(1)

    for key, value in metrics_json[0].items():
        if key == "metrics":
            continue
        print(f"{key}: {value}")
    for key, value in metrics_json[0]["metrics"][0].items():
        print(f"{key}: {value}")


def parse_date(date_str):
    try:
        return datetime.strptime(date_str, "%Y-%m")
    except ValueError as e:
        print(f"Invalid date format: {date_str}. Expected format is YYYY-MM.")
        sys.exit(1)


def construct_url(desired_month, dv_hub_id):
    # Figure out next month, needed to pass to API
    year = desired_month.year
    month = desired_month.month + 1
    if month > 12:  # Handle year rollover
        month = 1
        year += 1
    next_month = datetime(year, month, 1)
    from_date = desired_month.strftime("%Y-%m")
    to_date = next_month.strftime("%Y-%m")
    # For March 2025 we use https://hub.dataverse.org/api/installation/metrics/monthly?fromDate=2025-03&toDate=2025-04&dvHubId=DVN_HARVARD_DATAVERSE_2008
    return f"https://hub.dataverse.org/api/installation/metrics/monthly?fromDate={from_date}&toDate={to_date}&dvHubId={dv_hub_id}"


def fetch_metrics(url):
    try:
        response = urlrequest.urlopen(url)
        return json.loads(
            response.read().decode(response.info().get_param("charset") or "utf-8")
        )
    except Exception as e:
        print(f"Error fetching metrics from {url}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
