#!/usr/bin/env python3
import argparse
import json
import re
import sys
import urllib.request as urlrequest


URL = "https://hub.dataverse.org/api/installations/status"


def main():
    parser = argparse.ArgumentParser(
        description="Show a count of Dataverse installations by version."
    )
    parser.add_argument(
        "-i",
        "--installations",
        help="Include installation hostnames for each version.",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    args = parser.parse_args()

    if args.verbose:
        print(f"Fetching data from {URL}", file=sys.stderr)

    statuses = fetch_statuses(URL)
    versions = collect_versions(statuses)

    for version, data in sort_versions(versions):
        if args.installations:
            print(f"{version}\t{data['count']}\t{','.join(data['installations'])}")
        else:
            print(f"{version}\t{data['count']}")


def fetch_statuses(url):
    try:
        response = urlrequest.urlopen(url)
        return json.loads(
            response.read().decode(response.info().get_param("charset") or "utf-8")
        )
    except Exception as e:
        print(f"Error fetching statuses from {url}: {e}", file=sys.stderr)
        sys.exit(1)


def collect_versions(statuses):
    versions = {}

    for status in statuses:
        version = normalize_version(status.get("version"))
        if version == "":
            continue

        if version not in versions:
            versions[version] = {"count": 0, "installations": []}

        versions[version]["count"] += 1

        hostname = status.get("installation", {}).get("hostname")
        if hostname:
            versions[version]["installations"].append(hostname)

    for data in versions.values():
        data["installations"].sort()

    return versions


def normalize_version(version):
        if version is None:
            return "null"
        if version == "":
            return ""
        return version


def sort_versions(versions):
    return sorted(versions.items(), key=lambda item: version_sort_key(item[0]), reverse=True)


def version_sort_key(version):
    if version == "null":
        return ((-1, "null"),)

    normalized = version.lower()

    if normalized.startswith("v"):
        normalized = normalized[1:]

    parts = []

    for piece in normalized.split("."):
        match = re.match(r"^(\d+)(.*)$", piece)
        if match:
            number = int(match.group(1))
            suffix = match.group(2)
            # Plain numeric releases sort ahead of suffixed variants
            # when compared in descending order.
            parts.append((1, number, 1 if suffix == "" else 0, suffix))
        else:
            parts.append((0, piece))

    return tuple(parts)


if __name__ == "__main__":
    main()
