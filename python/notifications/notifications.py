#!/usr/bin/env python3
import os
import sys
import urllib.request as urlrequest
import json
import argparse
import re
from datetime import datetime


def main():
    parser = argparse.ArgumentParser(
        description="Display your notifications from a Dataverse installation."
    )
    parser.add_argument(
        "-b",
        "--base_url",
        help="The base URL of the Dataverse installation such as https://demo.dataverse.org",
        type=str,
        required=True,
    )
    parser.add_argument(
        "-a",
        "--api_token",
        help="The API token to use for authentication. If not provided, it will be read from the API_TOKEN environment variable.",
        type=str,
        default=None,
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    parser.add_argument(
        "-u",
        "--ugly",
        help="Don't pretty-print the JSON output.",
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

    url = construct_url(args.base_url)

    if args.verbose:
        print(f"Fetching notifications from {url}")

    json_raw = fetch_notifications(url, args.api_token)
    json_pretty = json.dumps(json_raw, indent=2)
    json_final = ""

    if args.ugly:
        json_final = json_raw
    else:
        json_pretty = json.dumps(json_raw, indent=2)
        json_final = json_pretty

    if args.verbose:
        print(json_final)

    for notification in json_raw["data"]["notifications"]:
        # print(notification)
        # print(notification["type"])
        message = "The dataverse, dataset, or file for this notification has been deleted."
        if "messageText" in notification:
            print(notification)
            message = notification["messageText"]
            print(f"{message} {notification['sentTimestamp']}")
            print()
            # message = "Philip Durbin Dataverse was created in Demo Dataverse . To learn more about what you can do with your dataverse, check out the User Guide."
            # print(f"{message} {notification['sentTimestamp']}")
            print()
            # message = """<div class="notification-item-cell">
            #                                         <span class="icon-dataverse text-icon-inline text-muted"></span>
            #                                                 <a href="/dataverse/pdurbin" title="Philip Durbin Dataverse">Philip Durbin Dataverse</a> was created in 
            #                                                 <a href="/dataverse/demo" title="Demo Dataverse">Demo Dataverse</a> . To learn more about what you can do with your dataverse, check out the 
            #                                                 <a href="https://guides.dataverse.org/en/6.7/user/dataverse-management.html" title="Dataverse Management - Dataverse User Guide" target="_blank">User Guide</a>. <span class="text-muted small">Sep 13, 2015, 6:31:54 PM EDT</span>
            #                             </div>"""
            # message = """<a href="/dataverse/pdurbin" title="Philip Durbin Dataverse">Philip Durbin Dataverse</a> was created in <a href="/dataverse/demo" title="Demo Dataverse">Demo Dataverse</a> . To learn more about what you can do with your dataverse, check out the <a href="https://guides.dataverse.org/en/6.7/user/dataverse-management.html" title="Dataverse Management - Dataverse User Guide" target="_blank">User Guide</a>.\
# """
            message = """You have been granted the Admin/Dataverse + Dataset Creator role for <a href="/dataverse/root" title="Root">Root</a>.\
"""
            print(f"{message} {notification['sentTimestamp']}")
            print()
            message = re.sub('<[^<]+?>', '', message)
            print(f"{message} {notification['sentTimestamp']}")
            print()
            print()


def construct_url(base_url):
    return f"{base_url}/api/notifications/all"


def fetch_notifications(url, api_token):
    # print(f"Fetching notifications from {url} with API token: {api_token}")
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
        print(f"Error fetching notifications from {url}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
