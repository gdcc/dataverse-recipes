#!/usr/bin/env python3
import os
import sys
import urllib.request as urlrequest
import json
import argparse
from datetime import datetime


def main():
    parser = argparse.ArgumentParser(
        description="Download a Croissant file from a draft dataset in a Dataverse installation."
    )
    parser.add_argument(
        "-b",
        "--base_url",
        help="The base URL of the Dataverse installation such as https://beta.dataverse.org",
        type=str,
        required=True,
    )
    parser.add_argument(
        "-a",
        "--api_token",
        help="The API token to use for authentication. This is required for draft datasets. If not provided, it will be read from the API_TOKEN environment variable.",
        type=str,
        default=None,
    )
    parser.add_argument(
        "-p",
        "--pid",
        help="The persistent identifier (PID) of the draft dataset such as doi:10.5072/FK2/XXXXXX",
        type=str,
        required=True,
    )
    parser.add_argument(
        "-u",
        "--ugly",
        help="Don't pretty-print the JSON output.",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    args = parser.parse_args()

    # Check if API token is provided via argument or environment variable
    if not args.api_token:
        args.api_token = os.getenv("API_TOKEN")
        if not args.api_token:
            print(
                "Error: API token is required. Provide it via the --api_token argument or the API_TOKEN environment variable."
            )
            sys.exit(1)

    url = construct_url(args.base_url, args.pid)

    if args.verbose:
        print(f"Fetching Croissant from {url}")

    croissant_raw = fetch_croissant(url, args.api_token)
    croissant_pretty = json.dumps(croissant_raw, indent=2)
    croissant_final = ""

    if args.ugly:
        croissant_final = croissant_raw
    else:
        croissant_pretty = json.dumps(croissant_raw, indent=2)
        croissant_final = croissant_pretty

    # Save the Croissant file to a local file
    filename = f"croissant_{args.pid.replace(':', '_').replace('/', '_')}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(filename, "w") as f:
        f.write(croissant_final)
    print(f"Saved Croissant to {filename}")


def construct_url(base_url, pid):
    return f"{base_url.rstrip("/")}/api/datasets/export?exporter=croissant&persistentId={pid}&version=:draft"


def fetch_croissant(url, api_token):
    try:
        request = urlrequest.Request(url)
        request.add_header("X-Dataverse-key", api_token)
        try:
            response = urlrequest.urlopen(request)
        except urlrequest.URLError as e:
            print(
                f"Error: Unable to fetch URL {url}. Reason: {e.reason}. Message: {e.readlines()}"
            )
            sys.exit(1)
        return json.loads(
            response.read().decode(response.info().get_param("charset") or "utf-8")
        )
    except Exception as e:
        print(f"Error fetching Croissant from {url}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
